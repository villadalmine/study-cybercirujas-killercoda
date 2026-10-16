## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
==== SOLUTION START ====

 SOLUTION -- 701.2 Standard Components and Platforms for Software

 Read this only after you have tried. The three faults are peeled in order:
 each one hides the next, so fixing them out of order is not possible.

 FAULT 1 -- the application runtime lost its configuration source

 Triage. The gateway answers, so the gateway is not the problem; it is
 reporting that the thing behind it is gone.

   $ curl -s http://127.0.0.1:8080/_gw/status
   {"pool_size": 2, "healthy": 0, "members": [...]}

   $ systemctl --failed
     UNIT                    LOAD   ACTIVE SUB    DESCRIPTION
   * shopfront-api@1.service loaded failed failed shopfront application runtime, instance 1
   * shopfront-api@2.service loaded failed failed shopfront application runtime, instance 2

 Read the journal. A process that dies in milliseconds is failing in its
 startup path, and it usually says why:

   $ journalctl -u shopfront-api@1 -n 20 --no-pager
   ... shopfront.py[1421]: FATAL: OBJECT_URL is not set. Backing services are
                           attached resources; their addresses must be supplied
                           through the environment.
   ... systemd[1]: shopfront-api@1.service: Main process exited, code=exited, status=78/CONFIG
   ... systemd[1]: shopfront-api@1.service: Failed with result 'exit-code'.
   ... systemd[1]: shopfront-api@1.service: Start request repeated too quickly.

 status=78/CONFIG is EX_CONFIG from sysexits.h: the program started, looked at
 its configuration, and refused. Compare what the unit provides against what
 the runtime needs:

   $ systemctl cat shopfront-api@.service | grep -iE 'environment|execstart'
   Environment=INSTANCE_ID=%i
   Environment=PORT=920%i
   Environment=LISTEN_ADDR=127.0.0.1
   ExecStart=/usr/bin/python3 /opt/shopfront/shopfront.py api

   $ systemctl show shopfront-api@1 -p Environment
   Environment=INSTANCE_ID=1 PORT=9201 LISTEN_ADDR=127.0.0.1

 The EnvironmentFile= line is gone, so OBJECT_URL / CACHE_URL / QUEUE_URL
 never reach the process. The file itself is intact:

   $ cat /etc/shopfront/backing-services.env
   OBJECT_URL=http://127.0.0.1:9101
   CACHE_URL=http://127.0.0.1:9102
   QUEUE_URL=http://127.0.0.1:9103

 Fix -- put the reference back. Editing the unit in place is fine:

   $ sudo systemctl edit --full shopfront-api@.service
     # under [Service], above the Environment= lines, add:
     EnvironmentFile=/etc/shopfront/backing-services.env

 or, equivalently and without touching the shipped unit, use a drop-in --
 which is what you would do on a machine where the unit comes from a package:

   $ sudo mkdir -p /etc/systemd/system/shopfront-api@.service.d
   $ printf '[Service]\nEnvironmentFile=/etc/shopfront/backing-services.env\n' \
       | sudo tee /etc/systemd/system/shopfront-api@.service.d/10-config.conf

 Then reload, clear the start-rate limit (the units hit it while crash-looping,
 and until it is cleared systemd answers "Start request repeated too quickly"),
 and start them:

   $ sudo systemctl daemon-reload
   $ sudo systemctl reset-failed shopfront-api@1.service shopfront-api@2.service
   $ sudo systemctl restart shopfront-api@1.service shopfront-api@2.service
   $ systemctl is-active shopfront-api@1.service shopfront-api@2.service
   active
   active

 Why this is the objective and not systemd trivia: the runtime is stateless and
 identical in both instances. Its knowledge of every backing service arrives
 from outside. That is what lets you run N copies behind a load balancer, move
 the same artifact from staging to production, and swap the object store for
 S3 without a rebuild -- and it is why one missing line took down both
 instances at once.

 FAULT 2 -- the object store cannot write, only read

 With the runtimes back, half the traffic flows. Reads work:

   $ SEED=$(cat /var/lib/shopfront/.seed-id)
   $ curl -s http://127.0.0.1:8080/orders/$SEED
   {"instance": "1", "source": "object-store", "order": {"order_id": "ord-...", ...}}

 Writes do not:

   $ curl -s -X POST -H 'Content-Type: application/json' \
       -d '{"sku":"LPI-701-100","qty":2}' http://127.0.0.1:8080/orders
   {"error": "object store write failed", "upstream": "http://127.0.0.1:9101",
    "upstream_status": 500,
    "upstream_detail": "{\"error\": \"object write failed\", \"key\": \"ord-...\",
     \"detail\": \"[Errno 13] Permission denied: '/var/lib/shopfront/objects/ord-...'\"}"}

 A read that works while a write fails is never connectivity. Confirm from the
 component's own health endpoint and from the filesystem:

   $ curl -s http://127.0.0.1:9101/healthz
   {"role": "object", "status": "ok", "dir": "/var/lib/shopfront/objects", "writable": false}

   $ journalctl -u shopfront-object -n 10 --no-pager
   ... shopfront.py[1502]: object write failed: PermissionError(13, 'Permission denied')

   $ ls -ld /var/lib/shopfront/objects
   drwxr-xr-x. 2 root root 4096 ... /var/lib/shopfront/objects

   $ systemctl show shopfront-object -p User
   User=shopfront

 The service runs as 'shopfront'; the directory belongs to root with 0755, so
 the process can traverse and read it but cannot create entries in it.

 Fix -- give the component back its own state directory. Do NOT run the
 service as root, and do NOT chmod 0777:

   $ sudo chown -R shopfront:shopfront /var/lib/shopfront
   $ sudo -u shopfront test -w /var/lib/shopfront/objects && echo writable
   writable

 No restart is required -- the permission is evaluated per open(2) -- but
 restarting is harmless:

   $ curl -s -X POST -H 'Content-Type: application/json' \
       -d '{"sku":"LPI-701-100","qty":2}' http://127.0.0.1:8080/orders
   {"order_id": "ord-4f2a1c9b0d", "instance": "1", "persisted": true,
    "queued": true, "cache_warm": true}

 Note which components cared. The object store is the system of record, so its
 failure aborted the request with 502. The cache failing would only have set
 "cache_warm": false -- a cache is an optimisation, and treating it as
 mandatory turns an optional component into a single point of failure. The
 queue is mandatory here because a dropped order event is a lost business
 fact. Those contracts are a design decision per component, not a default.

 FAULT 3 -- the load-balancer pool points at a member that does not exist

 Now the stack works exactly half the time:

   $ for i in $(seq 1 6); do curl -s -o /dev/null -w '%{http_code} ' \
       http://127.0.0.1:8080/healthz; done; echo
   200 502 200 502 200 502

 Alternating, not flapping. A round-robin balancer that fails every other
 request is faithfully sending every other request somewhere wrong. Ask it:

   $ curl -s http://127.0.0.1:8080/_gw/status
   {"pool_size": 2, "healthy": 1, "members": [
     {"upstream": "http://127.0.0.1:9201", "healthz_status": 200, "reachable": true, ...},
     {"upstream": "http://127.0.0.1:9209", "healthz_status": 0, "reachable": false,
      "detail": "[Errno 111] Connection refused"}]}

 Cross-check what is actually listening:

   $ ss -ltnp | grep -E ':(8080|910[1-3]|920[0-9])'
   LISTEN 0 5 127.0.0.1:9201 ... users:(("python3",pid=1601,fd=3))
   LISTEN 0 5 127.0.0.1:9202 ... users:(("python3",pid=1608,fd=3))
   LISTEN 0 5 127.0.0.1:9101 ...
   LISTEN 0 5 127.0.0.1:8080 ...

 Instance 2 is healthy on 9202. The pool is asking for 9209 -- one transposed
 digit in configuration, nothing wrong with any service:

   $ cat /etc/shopfront/gateway.env
   UPSTREAMS=http://127.0.0.1:9201,http://127.0.0.1:9209

 Fix -- correct the pool and restart the gateway. The gateway reads its
 environment file at startup, so an edit alone changes nothing:

   $ sudo sed -i 's|9209|9202|' /etc/shopfront/gateway.env
   $ sudo systemctl restart shopfront-gw.service

   $ curl -s http://127.0.0.1:8080/_gw/status | head -c 120
   {"pool_size": 2, "healthy": 2, "members": [...

   $ for i in $(seq 1 4); do curl -s http://127.0.0.1:8080/healthz \
       | grep -o '"instance": "[0-9]*"'; done
   "instance": "1"
   "instance": "2"
   "instance": "1"
   "instance": "2"

 Do not "fix" this by deleting the unreachable member. A pool of one is not a
 load balancer; it is a single point of failure with extra latency. The point
 of two runtimes is that either may die without an outage -- which you can
 prove, and should:

   $ sudo systemctl stop shopfront-api@2.service
   $ for i in $(seq 1 4); do curl -s -o /dev/null -w '%{http_code} ' \
       http://127.0.0.1:8080/healthz; done; echo
   200 502 200 502
   $ sudo systemctl start shopfront-api@2.service

 That 502 is the honest behaviour of a balancer doing pure round-robin with no
 health checking and no retry. Real front ends -- HAProxy, NGINX, an ELB, a
 Kubernetes Service with readiness probes -- close that gap by removing a
 failing member from rotation until its health check passes again. Recognising
 that active health checking, not the round-robin itself, is what makes a
 pool fault-tolerant is the 701.2 lesson here.

 VERIFY

   $ sudo ./break_fix.sh verify
   [+] 1/3 all six units are active (both application runtimes included)
   [+] 2/3 POST /orders -> 201, order persisted to the object store and queued
   [+] 3/3 8/8 requests succeeded and both instances served traffic (seen: 12121212)
   ALL CHECKS PASSED. The stack is repaired.

 Optional, to see the message queue component do its job -- every order you
 created is still waiting to be consumed:

   $ curl -s http://127.0.0.1:9103/stats
   {"queues": {"orders": 3}}
   $ curl -s http://127.0.0.1:9103/queues/orders
   {"queue": "orders", "message": "{\"order_id\": \"ord-4f2a1c9b0d\", ...}"}

 And the cache, which is empty after a restart by design and fills on demand:

   $ curl -s http://127.0.0.1:9102/stats
   {"hits": 4, "misses": 2, "stores": 5, "entries": 5}

 Tear the lab down with:  sudo ./break_fix.sh cleanup

 MAPPING BACK TO THE EXAM OBJECTIVE

  Component in this lab   Standard component     Typical production form
  ---------------------   --------------------   ----------------------------
  shopfront-object        object storage         S3, MinIO, Swift, GCS, Blob
  shopfront-cache         cache                  Redis, Memcached
  shopfront-queue         message queue/broker   RabbitMQ, Kafka, SQS, NATS
  shopfront-api@N         application runtime    a 12-factor process, a Pod
  shopfront-gw            LB / API gateway       HAProxy, NGINX, ELB, Ingress
  backing-services.env    config as environment  ConfigMap/Secret, Parameter
                                                 Store, Vault, PaaS bindings

 On a PaaS (Cloud Foundry, OpenShift) or on Kubernetes the same three faults
 wear different clothes and behave identically: a missing ConfigMap key or an
 unbound service instance crash-loops the Pod (fault 1); a read-only or
 wrongly-owned PersistentVolume lets reads through and rejects writes
 (fault 2); a Service selector matching the wrong label sends a share of the
 traffic nowhere (fault 3). The platform changes, the component taxonomy and
 the failure modes do not.

 Reference: https://www.lpi.org/our-certifications/exam-701-objectives/
==== SOLUTION END ====
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpi-devops/701.2/lab)
