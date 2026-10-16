## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — do not read until you have tried, or until --verify passes

 TRIAGE ORDER MATTERS. Restore service, then measure, then remove the defect,
 then close the detection gap. Root-causing while customers are down is the
 classic novice inversion.

 -- STEP 0: SEE THE WHOLE BOARD ---------------------------------------------

    teach-lab-status

 Expected output while broken:
      teach-lab-app            inactive   enabled   restart=no
      teach-lab-collector      inactive   disabled  restart=always
    load balancer view:
      state=HEALTHY last_probe=200 at=2026-09-09T...
    live probes:
      GET /        -> 000        <-- the process is gone
      GET /healthz -> 000
    SLO report:
      SLI (availability)    : 100.000%   <-- a lie: 0 valid requests collected
      *** TELEMETRY STALE - THIS REPORT IS NOT EVIDENCE OF HEALTH ***

 Read the crash reason before restarting anything — the evidence is in the
 journal and it is destroyed by nothing, but read it while it is in front of
 you:

    journalctl -u teach-lab-app -n 20 --no-pager | tail -5

 Expected, the last line the process ever wrote:
      {"exitCode": 137, "leaked_mib": 64, "limit_mib": 64, "message":
       "container memory limit exceeded - terminating", "severity": "CRITICAL", ...}

 Exit 137 = 128 + 9 = killed for memory. That is fault 3, and it tells you the
 restart will only buy you about a minute until you also fix the leak.

 -- STEP 1 (O1): MITIGATE ---------------------------------------------------

    systemctl start teach-lab-app.service
    curl -i http://127.0.0.1:8080/

 Expected: HTTP/1.1 503 Service Unavailable
      {"error": "data tier unavailable", "detail": "URLError: <urlopen error
       [Errno 111] Connection refused>"}

 The process is up and still cannot serve: the crash was a consequence, not
 the customer-facing cause. Two independent faults, which is normal.

 -- STEP 2 (O2): ROOT CAUSE OF THE 503 --------------------------------------

    curl -s http://127.0.0.1:8080/debug | python3 -m json.tool

 Expected:
      { "backend_url": "http://127.0.0.1:9099/data",
        "healthz_mode": "shallow", "leak": true, "release": "v1.4.0" }

 Now confirm where the dependency actually listens — never assume:

    ss -ltnp | grep -E '9090|9099'
    # 127.0.0.1:9090 is LISTEN (python3, teach-lab-backend); 9099 is nothing.
    curl -s http://127.0.0.1:9090/data | head -c 80
    # {"source": "data-tier", "items": [{"sku": "GG-0001", ...

 The data tier is healthy. v1.4.0 shipped a wrong port. Fix the configuration:

    sed -i 's|^BACKEND_URL=.*|BACKEND_URL=http://127.0.0.1:9090/data|' /etc/teach-lab/app.env

 -- STEP 3 (O3 + O4a): FIX THE PROBE AND THE LEAK IN THE SAME EDIT ----------

    sed -i 's|^HEALTHZ_MODE=.*|HEALTHZ_MODE=deep|' /etc/teach-lab/app.env
    sed -i 's|^LEAK=.*|LEAK=0|'                    /etc/teach-lab/app.env
    cat /etc/teach-lab/app.env

 Why deep: a shallow check answers "is the process alive?" A load balancer is
 not asking that — it is asking "should I send a customer here?" When the two
 questions have different answers, the balancer keeps a broken instance in the
 serving pool and the outage becomes invisible to every routing decision you
 own. A health check used for routing must exercise the critical path,
 including the dependencies without which the instance cannot serve. (Keep the
 cost bounded: short timeout, no fan-out to third parties, or a slow dependency
 turns one incident into a cascading failure across every instance at once.)

 -- STEP 4 (O4b): AUTOHEALING ------------------------------------------------

 systemd's restart policy is the single-VM analogue of a managed instance
 group autohealing policy. Use a drop-in so the change is visible and revertible:

    mkdir -p /etc/systemd/system/teach-lab-app.service.d
    cat > /etc/systemd/system/teach-lab-app.service.d/10-autoheal.conf <<'EOF'
    [Service]
    Restart=always
    RestartSec=5
    StartLimitIntervalSec=0
    EOF
    systemctl daemon-reload
    systemctl restart teach-lab-app.service
    systemctl show -p Restart --value teach-lab-app.service     # -> always

 Note the ordering discipline: the leak was removed in step 3 BEFORE
 autohealing was enabled. Reversed, you get a crash loop that hides the defect
 behind a green-looking service — availability restored, root cause buried.

 -- STEP 5 (O5): RESTORE OBSERVABILITY, PERMANENTLY -------------------------

    systemctl enable --now teach-lab-collector.service
    systemctl is-enabled teach-lab-collector.service    # -> enabled

 `--now` starts it; `enable` is what makes it survive the next reboot. The
 original fault was not "the agent stopped", it was "the agent stopped and
 nothing noticed for hours". Prove the signal is alive again:

    sleep 20 && teach-lab-slo --window-minutes 5

 Expected, once traffic has been clean for a couple of minutes:
      valid requests        : 60
      good requests (<500)  : 60
      SLI (availability)    : 100.000%
      error budget          : 0.500% of requests may fail
      burn rate             : 0.00x
      telemetry age         : 3s
    and NO staleness banner.

 -- STEP 6: VERIFY ----------------------------------------------------------

    sudo ./break-fix-6.2-operations-reliability.sh --verify

 Expected: six PASS lines. The grader stops the data tier to prove your probe
 is deep, and SIGKILLs the process to prove autohealing works — both restore
 themselves, so the lab stays usable.

 -- WHAT THIS MAPS TO ON THE EXAM -------------------------------------------

 * Reliability is measured, not asserted. An SLI is a ratio of good events to
   valid events; the SLO is the target; 100% is never the target, because the
   error budget is what buys you the right to ship changes at all. A team with
   budget left ships; a team that has burned it freezes features and spends
   the next cycle on reliability. That is the whole negotiation between
   velocity and stability, in one number.
 * Burn rate is the alerting primitive. Do not page on "an error happened";
   page on "at this rate the budget is gone in N hours". Fast-burn and
   slow-burn windows exist so that a two-minute blip does not wake anyone and
   a slow bleed does not go unnoticed for a month.
 * Absence of telemetry is an incident. Fault 4 is the one students
   consistently under-rate: it did not cause the outage, it caused the outage
   to be invisible, which is what turned minutes of MTTR into hours. Alert on
   the freshness of your signals, not only on their values.
 * Resilience is designed in, not bolted on. Autohealing, health-check-driven
   load balancing, multi-zone instance groups, autoscaling and graceful
   degradation are the same idea at different blast radii: assume the
   component fails, and make recovery automatic. Google Cloud gives you
   regional managed instance groups, health checks, Cloud Load Balancing and
   autoscaling precisely so that a single instance dying is a non-event.
 * Recovery objectives frame the trade-off. RTO is how long you may be down;
   RPO is how much data you may lose. Backup/restore is cheap with a long RTO;
   warm standby is faster and costlier; active-active multi-region is fastest
   and costliest. The right answer is the cheapest pattern that meets the
   objective the business actually funded — never the most redundant one
   available.
 * Toil is the target of automation. The manual nightly restart you replaced
   with Restart=always is textbook toil: manual, repetitive, automatable, no
   enduring value, and it grows with traffic. SRE caps toil (~50%) so that
   engineering time survives operational load.
 * Postmortems are blameless because there was no single culprit here: a typo
   in a config, a probe that was weakened for a good-sounding reason, a leak in
   a dependency, and an agent left disabled after maintenance. Four ordinary
   decisions, one outage. You fix systems, not people.

 -- CLEAN UP ----------------------------------------------------------------

    sudo ./break-fix-6.2-operations-reliability.sh --clean

 Official reference for this objective:
   https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/gcp-cdl/6.2/lab)
