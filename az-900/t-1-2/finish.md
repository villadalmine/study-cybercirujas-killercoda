## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — do not read until `verify` reports 5/5, or until you are stuck.

 STEP 0 — Establish what is actually broken before changing anything.

   $ sudo ./az900-1.2-break-fix.sh status
   $ sudo ./az900-1.2-break-fix.sh verify

 Expected on the broken lab: CHECK-1..5 all FAIL, 0 PASS / 5 FAIL.
 Read `status` carefully — it already shows three of the four faults:
 a one-line backend pool, `Restart=no`, and MIN=MAX=1 with an unreachable
 SCALE_OUT_RPM. This mirrors the real diagnostic order in Azure: read the
 resource configuration before you touch the workload.

 STEP 1 — FAULT-2, reliability / self-healing (fix this first: it makes every
          later step stable).

 Find the override. `systemctl cat` prints the unit file AND every drop-in;
 the last assignment wins:

   $ systemctl cat az900-app@1 | tail -n 5
   # /etc/systemd/system/az900-app@.service.d/override.conf
   [Service]
   # Injected by the AZ-900 1.2 break & fix lab.
   Restart=no

   $ systemctl show -p Restart --value az900-app@1
   no

 Remove the drop-in and reload the manager:

   $ sudo rm -rf /etc/systemd/system/az900-app@.service.d
   $ sudo systemctl daemon-reload
   $ sudo systemctl restart az900-app@1
   $ systemctl show -p Restart --value az900-app@1
   always

 Prove the repair loop works:

   $ sudo systemctl kill --signal=SIGKILL az900-app@1; sleep 4
   $ systemctl is-active az900-app@1
   active

 AZ-900 mapping: this is VMSS automatic instance repair / platform-managed
 reliability. Without it you own the pager.
 https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-automatic-instance-repairs

 STEP 2 — FAULT-3, manageability: unblock the health probe.

 First isolate the layer. The backend is healthy, the front end is not:

   $ curl -s http://127.0.0.1:8081/health
   OK node-1
   $ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/health
   403

 A 403 from nginx with a working backend is an access rule, not an app bug:

   $ cat /etc/nginx/az900-health-acl.conf
   deny all;

 Restore an allow rule for the probe source (loopback here; in Azure it is
 the platform probe address 168.63.129.16 that your NSG must allow):

   $ sudo tee /etc/nginx/az900-health-acl.conf >/dev/null <<'ACL'
   allow 127.0.0.1;
   allow ::1;
   deny all;
   ACL
   $ sudo nginx -t && sudo systemctl reload nginx
   nginx: configuration file /etc/nginx/nginx.conf test is successful

   $ /opt/az900-lab/probe.sh
   HEALTHY (HTTP 200)

 AZ-900 mapping: a blocked probe is indistinguishable from a dead instance to
 the load balancer — it removes the instance from rotation and you lose
 capacity you are still paying for.
 https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-custom-probe-overview

 STEP 3 — FAULT-4, elasticity: bring the autoscale engine back.

 Two independent problems: the engine is masked, and the rule can never fire.

   $ systemctl is-enabled az900-autoscale.timer
   masked
   $ grep -v '^#' /etc/az900-lab/scale.conf
   MIN_REPLICAS=1
   MAX_REPLICAS=1
   SCALE_OUT_RPM=999999
   TICK_SECONDS=15

 `masked` is a symlink to /dev/null — `systemctl start` on a masked unit fails
 and `enable` will not resurrect it. Unmask first:

   $ sudo systemctl unmask az900-autoscale.timer
   $ sudo systemctl enable --now az900-autoscale.timer
   $ systemctl is-active az900-autoscale.timer
   active

 Then restore an autoscale profile that can actually trigger. MIN_REPLICAS=2
 is the availability floor (Step 4 depends on it); MAX above MIN is what makes
 the deployment elastic; the threshold must sit inside the real traffic range:

   $ sudo sed -i 's/^MIN_REPLICAS=.*/MIN_REPLICAS=2/;
                  s/^MAX_REPLICAS=.*/MAX_REPLICAS=4/;
                  s/^SCALE_OUT_RPM=.*/SCALE_OUT_RPM=120/' /etc/az900-lab/scale.conf

 Watch one evaluation cycle:

   $ sudo systemctl start az900-autoscale.service
   $ journalctl -u az900-autoscale.service -n 3 --no-pager
   observed=0rpm desired_replicas=2
   backend pool updated to 2 instance(s)

 AZ-900 mapping: elasticity is the benefit; scaling back in when the load
 drops is where the cost benefit and the consumption-based pricing model
 actually materialise.
 https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-autoscale-overview

 STEP 4 — FAULT-1, high availability: restore the backend pool.

 If Step 3 is done correctly this repairs itself within one 15s tick, because
 the autoscaler converges instances to MIN_REPLICAS and regenerates the pool:

   $ sleep 20; cat /etc/nginx/az900-upstream.conf
   server 127.0.0.1:8081 max_fails=1 fail_timeout=5s;
   server 127.0.0.1:8082 max_fails=1 fail_timeout=5s;

 Manual equivalent, if you want to do it by hand:

   $ sudo systemctl start az900-app@2
   $ sudo tee /etc/nginx/az900-upstream.conf >/dev/null <<'POOL'
   server 127.0.0.1:8081 max_fails=1 fail_timeout=5s;
   server 127.0.0.1:8082 max_fails=1 fail_timeout=5s;
   POOL
   $ sudo nginx -t && sudo systemctl reload nginx

 Confirm both the spread and the failover:

   $ for i in 1 2 3 4; do curl -s http://127.0.0.1:8080/; done
   node-1
   node-2
   node-1
   node-2

   $ sudo systemctl stop az900-app@2
   $ for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code} ' http://127.0.0.1:8080/; done; echo
   200 200 200 200 200 200 200 200 200 200
   $ sudo systemctl start az900-app@2

 The zero-error result is `proxy_next_upstream` retrying on a healthy peer —
 the same behaviour Azure Load Balancer gives you when a probe marks an
 instance down. Redundancy is what makes an SLA meaningful; two instances in
 one Availability Set are a different SLA from two across Availability Zones,
 which is a different SLA again from a single VM.
 https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview

 STEP 5 — Grade the repair.

   $ sudo ./az900-1.2-break-fix.sh verify
   [ OK ] 20 requests served by 2 distinct instances
   [ OK ] instance 2 down, 20/20 requests still returned HTTP 200
   [ OK ] az900-app@1 was SIGKILLed and came back automatically in 3s (Restart=always)
   [ OK ] GET http://127.0.0.1:8080/health -> HTTP 200
   [ OK ] scaled out to 4 instances under load; pool now: server 127.0.0.1:8081 ... 8084 ...
     5 PASS / 0 FAIL

 If CHECK-5 fails while CHECK-1..4 pass, the autoscaler is running but the
 rule still cannot trigger. Read what it observed rather than guessing:

   $ journalctl -u az900-autoscale.service -n 10 --no-pager
   observed=232rpm desired_replicas=4

 observed >= SCALE_OUT_RPM and desired still 1 means MAX_REPLICAS was never
 raised; observed near 0 under load means the access log path or TICK_SECONDS
 no longer matches the timer interval.

 STEP 6 — Tear the lab down.

   $ sudo ./az900-1.2-break-fix.sh cleanup

 EXAM TAKEAWAYS (AZ-900 1.2)

  * High availability is redundancy you can point at: instances in more than
    one fault domain, published through a load balancer. An SLA number is the
    consequence of an architecture, never a substitute for one.
  * Fault tolerance is what the client experiences during that failure —
    measured in failed requests, not in dashboards.
  * Reliability includes self-healing: the platform must replace a failed
    instance without a human. Verify the mechanism is enabled, not merely
    documented.
  * Scalability is capacity you *can* add; elasticity is capacity that arrives
    and then leaves automatically. Autoscale needs an engine, a threshold that
    can be crossed, and a maximum above the minimum — all three.
  * Manageability includes the management plane's ability to observe the
    workload. A healthy application that cannot answer a probe is treated as
    down; the fault is usually a network rule, so always test the backend
    directly before blaming the application.
  * Governance and predictability follow from the same configuration surface:
    every fault in this lab was one line in a declarative file, which is why
    Azure Policy, ARM/Bicep templates and infrastructure-as-code exist.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/az-900/1.2/lab)
