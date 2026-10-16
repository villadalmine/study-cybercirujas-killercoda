## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
>>> SOLUTION ==================================================================
>>> LAB 702.1 - Application Container Management :: STEP-BY-STEP SOLUTION
>>> ==========================================================================

Do not read this until you have tried. Container debugging is a muscle, and the
only way to build it is to sit with a confusing log line for ten minutes.

STEP 0 - TRIAGE: get the four error strings before changing anything
  cd /opt/lab-702.1
  docker compose -p lab702 ps -a
  docker compose -p lab702 logs --tail=40 api worker web
  for c in lab702-cache lab702-api lab702-worker lab702-web; do
      docker inspect -f '{{.Name}} status={{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}}' "$c"
  done

Expected output (abridged):
  lab702-api     exec /usr/local/bin/entrypoint.sh: no such file or directory
  lab702-worker  sh: can't create /var/lib/worker/heartbeat: Permission denied
  lab702-web     [emerg] host not found in upstream "api-svc" in /etc/nginx/conf.d/default.conf:6
  lab702-cache   Ready to accept connections tcp

Production note: `restart: unless-stopped` turned three hard crashes into a
quiet "Restarting" column. A restart policy is a resilience feature, not a
health signal - always read RestartCount and the logs, never just `docker ps`.

FAULT 1 - api: ENOENT on an entrypoint that demonstrably exists (CRLF)
Symptom : exec /usr/local/bin/entrypoint.sh: no such file or directory
          (exit code 127, endless restart loop)
Proof   : the file is present, executable, and still fails:
            docker run --rm --entrypoint sh lab702/api:1.0 \
              -c 'ls -l /usr/local/bin/entrypoint.sh; head -1 /usr/local/bin/entrypoint.sh | od -c'
          -> 0000000   #   !   /   b   i   n   /   s   h  \r  \n

Mechanics: exec() reads the shebang and executes the interpreter named there.
          With CRLF endings the interpreter path is literally "/bin/sh\r",
          which does not exist - so the kernel returns ENOENT and the runtime
          reports "no such file or directory" ABOUT THE SCRIPT, not about the
          interpreter. This is the single most misdiagnosed container error;
          it usually arrives via a Windows checkout or a CI job without
          `.gitattributes`/`core.autocrlf` discipline.

Fix:
  sed -i 's/\r$//' /opt/lab-702.1/api/entrypoint.sh
  file /opt/lab-702.1/api/entrypoint.sh        # must NOT say "CRLF line terminators"
  docker compose -f /opt/lab-702.1/compose.yaml -p lab702 build api
  docker compose -f /opt/lab-702.1/compose.yaml -p lab702 up -d api

Hardening for real pipelines: add a build-time guard so the image can never
ship a CRLF entrypoint again -
  RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && chmod 0755 /usr/local/bin/entrypoint.sh
  RUN sh -n /usr/local/bin/entrypoint.sh

FAULT 2 - worker: Permission denied on a bind mount (uid mismatch)
Symptom : sh: can't create /var/lib/worker/heartbeat: Permission denied, exit 1,
          restart loop.
Proof   :
  docker inspect -f '{{.Config.User}}' lab702-worker      # -> 10001:10001
  stat -c '%U:%G %a %n' /opt/lab-702.1/state              # -> root:root 755 ...

Mechanics: a bind mount exposes the host inode as-is. There is no ownership
          mapping (that is what userns-remap or rootless Docker would provide),
          so the container's uid 10001 hits a root-owned 0755 directory and is
          denied write. Note the container is NOT misconfigured - the host is.

Fix (host side, keeps the container non-root, which is what you want):
  chown -R 10001:10001 /opt/lab-702.1/state
  docker compose -f /opt/lab-702.1/compose.yaml -p lab702 up -d worker
  ls -l /opt/lab-702.1/state/heartbeat        # refreshes every 5s

WRONG fixes and why:
  * removing `user: "10001:10001"`  -> the process becomes root in the container
    and, on a bind mount, root on the host filesystem too. Graded as a failure.
  * chmod 0777                       -> world-writable state directory; works,
    fails any security review.
  Structurally better in production: use a NAMED VOLUME instead of a bind mount
  (Docker initialises its ownership from the image path), or pre-create the
  directory with the right uid in the image and mount the volume there:
      volumes: [ workerstate:/var/lib/worker ]

FAULT 3 - api cannot resolve 'cache': disjoint user-defined networks
Symptom : once api finally starts, /healthz returns 503 with
          "cache": {"state":"error","detail":"gaierror: [Errno -2] Name does not resolve"}
Proof   :
  docker inspect -f '{{json .NetworkSettings.Networks}}' lab702-api    # lab702_frontend
  docker inspect -f '{{json .NetworkSettings.Networks}}' lab702-cache  # lab702_backend
  docker exec lab702-api getent hosts cache                            # empty
  docker network inspect lab702_backend --format '{{json .Containers}}'

Mechanics: Docker's embedded DNS server (127.0.0.11) only answers for names of
          containers attached to a network the QUERYING container is also
          attached to. Default-bridge legacy `--link` behaviour does not apply
          to user-defined networks; membership IS the service discovery.

Fix - attach api to both networks (proxy tier + data tier is a legitimate
segmentation; the api is the only thing allowed to talk to the cache):
  in compose.yaml, service api:
      networks: [frontend, backend]
  docker compose -f /opt/lab-702.1/compose.yaml -p lab702 up -d api
  docker exec lab702-api getent hosts cache      # now returns 172.x.y.z cache

FAULT 4 - web: nginx [emerg] host not found in upstream "api-svc"
Symptom : lab702-web never binds; exit 1 on every restart.
Mechanics: names inside an `upstream {}` block are resolved ONCE, during
          configuration parsing. An unresolvable name is fatal - you get no
          listener at all, not a 502. (The runtime-resolution alternative is
          `resolver 127.0.0.11 valid=10s;` plus a variable in proxy_pass:
             set $up api; proxy_pass http://$up:8000;
          which survives an upstream that is temporarily down - worth knowing
          for rolling restarts.)
Fix:
  sed -i 's/server api-svc:8000;/server api:8000;/' /opt/lab-702.1/web/nginx.conf
  docker compose -f /opt/lab-702.1/compose.yaml -p lab702 up -d web
  docker exec lab702-web nginx -t          # syntax is ok - test AFTER the fix

Order matters: fix FAULT 1 first. If lab702-api is not running, the name 'api'
still does not resolve and nginx will keep dying with the same [emerg].

FAULT 5 - published port does not match the listening port
Symptom : curl -v http://127.0.0.1:8080/healthz -> "Empty reply from server"
          or connection reset, while `docker ps` proudly shows 0.0.0.0:8080->8080/tcp.
Proof   :
  docker port lab702-web                              # 8080/tcp -> 0.0.0.0:8080
  docker exec lab702-web grep -n listen /etc/nginx/conf.d/default.conf   # listen 80;
  docker exec lab702-web netstat -ltnp 2>/dev/null || docker exec lab702-web ss -ltn

Mechanics: "HOST:CONTAINER". The mapping 8080:8080 forwards to container port
          8080, where nothing listens; the proxy is bound on 80. Docker happily
          publishes a port that no process serves - publishing is a NAT rule
          (see `iptables -t nat -L DOCKER -n`), not a health check.
Fix (either is acceptable; the first keeps the image's convention):
  in compose.yaml, service web:  ports: [ "8080:80" ]
  -- or -- change `listen 80;` to `listen 8080;` in web/nginx.conf.
  docker compose -f /opt/lab-702.1/compose.yaml -p lab702 up -d web

FINAL - bring it all up and confirm
  cd /opt/lab-702.1
  docker compose -p lab702 build api
  docker compose -p lab702 down
  docker compose -p lab702 up -d
  docker compose -p lab702 ps
  curl -s http://127.0.0.1:8080/healthz | python3 -m json.tool

Expected:
  {
    "status": "ok",
    "service": "lab702-api",
    "uid": 10001,
    "cache":  { "state": "ok", "detail": "PONG from cache:6379" },
    "worker": { "state": "ok", "detail": "heartbeat is 3s old" }
  }

  sudo /path/to/lab-702.1-break-fix.sh verify
  sudo /path/to/lab-702.1-break-fix.sh cleanup

WHAT TO CARRY INTO PRODUCTION (and into the 701 exam)
* A restart policy without a healthcheck is a blindfold. Add to every service:
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8000/healthz"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 10s
  then `depends_on: { api: { condition: service_healthy } }` makes start order
  mean something instead of merely ordering process launches.
* "no such file or directory" on an existing file = interpreter problem
  (CRLF shebang, missing dynamic loader in a scratch/distroless image, or an
  architecture mismatch - `docker image inspect --format '{{.Architecture}}'`).
* Bind mounts inherit host uid/gid. Non-root containers plus bind mounts means
  you own the ownership problem; named volumes or an init step remove it.
* On user-defined networks, network membership IS service discovery; there is
  no cross-network DNS. Segment deliberately, then attach deliberately.
* A published port proves a NAT rule exists, nothing more. Always verify what
  is actually listening INSIDE the container.

Sources:
  https://www.lpi.org/our-certifications/exam-701-objectives/
  https://docs.docker.com/reference/cli/docker/container/run/
  https://docs.docker.com/reference/compose-file/services/
  https://docs.docker.com/engine/network/drivers/bridge/
  https://docs.docker.com/engine/storage/bind-mounts/
  https://docs.docker.com/engine/containers/start-containers-automatically/
  https://nginx.org/en/docs/http/ngx_http_upstream_module.html
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpi-devops/702.1/lab)
