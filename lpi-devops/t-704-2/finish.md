## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION -- STEP BY STEP
 Stop here unless you have already fought with the four faults.

 STEP 0 -- TRIAGE. Establish what is running before you change anything.
   # systemctl status lab-prometheus --no-pager
     * lab-prometheus.service - Lab Prometheus (LPI 701-100 topic 704.2)
        Active: failed (Result: exit-code) since ...; 20s ago
       Process: 1423 ExecStart=/usr/local/bin/prometheus ... (code=exited, status=1/FAILURE)

   # systemctl status lab-node-exporter --no-pager
        Active: active (running)          <-- the exporter is fine, Prometheus is not

   Rule: the collector that will not start hides every downstream fault.
   Fix the process first, then the targets, then the data.

 FAULT 1 -- Invalid alerting rule: Prometheus refuses to start
 Diagnose:
   # journalctl -u lab-prometheus -n 20 --no-pager
     level=ERROR ... msg="loading failed" file=/etc/prometheus/rules/node.rules.yml
         err="unmarshal errors: line 15: cannot unmarshal !!int `30` into model.Duration"
     level=ERROR ... msg="Error loading config (--config.file=/etc/prometheus/prometheus.yml)"

   Confirm without touching the service (free, instant, no restart loop):
   # promtool check rules /etc/prometheus/rules/node.rules.yml
     Checking /etc/prometheus/rules/node.rules.yml
       FAILED: ... cannot unmarshal !!int `30` into model.Duration

 Why it happens: `for:` takes a Prometheus duration string. A bare integer is
 not a duration. Rule files are parsed at startup and at every reload; a
 parse error there is fatal at startup and rejected on reload (in which case
 the previous, still-valid rule set stays in memory -- which is exactly why a
 reload can "succeed" in your shell yet leave stale rules running).
 Reference: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/

 Fix:
   # sed -i 's/^\( *for: *\)30$/\130s/' /etc/prometheus/rules/node.rules.yml
   # promtool check rules /etc/prometheus/rules/node.rules.yml
     SUCCESS: 2 rules found
   # systemctl reset-failed lab-prometheus       # clear the start-limit counter
   # systemctl start lab-prometheus
   # curl -s -o /dev/null -w '%{http_code}\n' localhost:9090/-/healthy
     200

 FAULT 2 -- Wrong target address: the `node` job is DOWN
 Diagnose:
   # curl -s 'localhost:9090/api/v1/targets?state=active' \
       | jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.health)\t\(.lastError)"'
     node    down    Get "http://localhost:9110/metrics": dial tcp 127.0.0.1:9110: connect: connection refused

   Where does the exporter actually listen?
   # ss -lntp | grep node_exporter
     LISTEN 0 4096 *:9100 *:* users:(("node_exporter",pid=1391,fd=3))

   9100 exposed, 9110 scraped. The exporter is healthy; the config lies.
   ("connection refused" = nothing listening. Contrast with "context deadline
    exceeded" = something listening but too slow -- a scrape_timeout problem,
    not an address problem. Read the lastError, do not guess.)

 Fix:
   # sed -i "s/localhost:9110/localhost:9100/" /etc/prometheus/prometheus.yml
   # promtool check config /etc/prometheus/prometheus.yml
     SUCCESS: 1 rule file found, 0 rule errors
   # curl -sX POST localhost:9090/-/reload     # hot reload; no restart needed
   # curl -s --get --data-urlencode 'query=up{job="node"}' localhost:9090/api/v1/query | jq '.data.result[0].value[1]'
     "1"

 FAULT 3 -- A relabel_configs drop rule deletes the self-scrape target
 Diagnose:
   # curl -s --get --data-urlencode 'query=up{job="prometheus"}' localhost:9090/api/v1/query | jq '.data.result'
     []                                   <-- empty, not 0. The series never existed.

   An absent target is invisible in /targets. Use the service discovery view,
   which shows discovered targets AND the ones relabeling dropped:
     Web UI -> Status -> Service Discovery -> job "prometheus" -> "0 / 1 active targets"
   # curl -s localhost:9090/api/v1/targets | jq '.data.droppedTargetCounts'
     { "prometheus": 1, "node": 0 }

   Then read the config:
   # sed -n '/job_name: prometheus/,/job_name: node/p' /etc/prometheus/prometheus.yml
     relabel_configs:
       - source_labels: [__address__]
         regex: 'localhost:9090'
         action: drop

 Why it matters: relabel_configs runs on discovered targets BEFORE the scrape.
 `action: drop` discards every target whose concatenated source labels match
 the regex, so the target is never scraped and no `up` series is produced.
 An alert written as `up{job="prometheus"} == 0` can therefore NEVER fire --
 the vector is empty, not zero. This is the classic silent blind spot; the
 defensive pattern is `absent(up{job="prometheus"}) == 1` (or the standard
 meta-alert on `count(up) < expected`) alongside the `up == 0` alert.
 Reference: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config

 Fix -- delete the three-line relabel block (it has no legitimate purpose here):
   # python3 - <<'PY'
   import re, pathlib
   p = pathlib.Path("/etc/prometheus/prometheus.yml")
   s = p.read_text()
   s = re.sub(r"\n *relabel_configs:\n(?: *- source_labels.*\n| *regex:.*\n| *action: drop\n)+", "\n", s)
   p.write_text(s)
   PY
   # promtool check config /etc/prometheus/prometheus.yml && curl -sX POST localhost:9090/-/reload
   # curl -s --get --data-urlencode 'query=up{job="prometheus"}' localhost:9090/api/v1/query | jq -r '.data.result[0].value[1]'
     1
   (Editing the file by hand with vi is perfectly fine -- the point is that
    the block is removed and the config revalidated before reloading.)

 FAULT 4 -- node_exporter started with --collector.disable-defaults
 Diagnose -- the target is UP and yet there is no data:
   # curl -s localhost:9100/metrics | grep -c '^node_'
     0
   # curl -s localhost:9100/metrics | awk '{print $1}' | grep -v '^#' | cut -d'{' -f1 | sort -u | head
     go_gc_duration_seconds
     process_cpu_seconds_total
     promhttp_metric_handler_requests_total

   The exporter answers HTTP 200 with only its own runtime metrics, which is
   why `up == 1`: `up` records whether the scrape succeeded, never whether it
   returned anything meaningful. Find out how the process was launched:
   # systemctl cat lab-node-exporter | grep ExecStart
     ExecStart=/usr/local/bin/node_exporter --web.listen-address=0.0.0.0:9100 --collector.disable-defaults

 Fix:
   # sed -i 's/ --collector.disable-defaults//' /etc/systemd/system/lab-node-exporter.service
   # systemctl daemon-reload && systemctl restart lab-node-exporter
   # curl -s localhost:9100/metrics | grep -c '^node_'
     1100          (exact number varies by kernel, filesystems and NICs)

   Prometheus needs no reload here: the target address did not change, and the
   next scrape (5s) picks the series up. Wait ~15s for the rate() window to
   have two samples, then:
   # curl -s --get --data-urlencode 'query=job:node_cpu_seconds:rate5m' \
       localhost:9090/api/v1/query | jq -r '.data.result[0].value[1]'
     0.0731...

 STEP 5 -- VERIFY, then verify the alert path too
   # sudo ./704.2-break-fix.sh check         # all six lines must read PASS

   Prove the alerting rule actually works, end to end:
   # systemctl stop lab-node-exporter        # simulate the failure it watches
   # sleep 45
   # curl -s localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | "\(.labels.alertname) \(.state)"'
     NodeExporterDown firing
   # systemctl start lab-node-exporter       # and watch it resolve

   An alerting rule you have never seen fire is a hypothesis, not a control.

 WHAT TO TAKE TO THE EXAM AND TO PRODUCTION
   * Triage order: process up -> target up -> series present -> rule firing.
     Each layer can be green while the next is broken.
   * `up` has exactly three states and they are not interchangeable:
       1        scrape succeeded
       0        scrape attempted and failed (read `lastError`)
       absent   the target does not exist -- discovery or relabeling killed it.
     Only the first two are alertable with `up == 0`; the third needs
     `absent()` or a count-based meta-alert.
   * Validate before restarting: `promtool check config`, `promtool check
     rules`, and `promtool test rules` for unit-testing alert logic. All free.
   * Prefer `curl -X POST /-/reload` (needs --web.enable-lifecycle) over a
     restart: no gap in the time series, no cold TSDB head block. But a
     rejected reload keeps the OLD configuration in memory -- always confirm
     with `prometheus_config_last_reload_successful == 1`.
   * Exporters are dumb HTTP endpoints. When a panel is empty, `curl` the
     exporter directly before you suspect Prometheus, PromQL or the dashboard.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpi-devops/704.2/lab)
