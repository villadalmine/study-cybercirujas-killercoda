## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
==== SOLUTION (step by step) ==============================================

The endpoint serves bytes fine (HTTP 200), which is why "curl works" fools
people. Prometheus does not scrape bytes — it scrapes a strict line-based
TEXT EXPOSITION FORMAT, and this payload breaks four of its rules. Fix them
in ${METRICS_FILE}; the server re-reads on each scrape, so no restart.
Re-run `bash pca_2_5_break_fix.sh verify` after each edit — promtool reports
ONE error at a time (by line), so you will peel them off one by one.

The broken payload:
    1  # HELP http_requests_total Total number of HTTP requests handled.
    2  # TYPE http_requests_total counter
    3  # TYPE http_requests_total counter          <-- (1) duplicate TYPE
    4  http_requests_total{method=GET,code="200"} 1027   <-- (2) unquoted value
    5  http_requests_total{method="POST",code="200"} 3
    6  # HELP http_requests_total Duplicate description sneaked in.  <-- (3) dup HELP
    7  # HELP app_temperature_celsius Current probe temperature in Celsius.
    8  # TYPE app_temperature_celsius gauge
    9  app_temperature_celsius 0.provided          <-- (4) non-numeric value

FIX 1 — Duplicate metadata line.
  A metric family may carry exactly one '# TYPE' (and one '# HELP') line.
  Symptom: "second TYPE line for metric name http_requests_total".
  Action:  delete line 3.

FIX 2 — Unquoted label value.
  Every label value is a double-quoted string; bare words are a syntax error.
  Symptom: parse error, expected '"' at the '=' after method.
    -  http_requests_total{method=GET,code="200"} 1027
    +  http_requests_total{method="GET",code="200"} 1027

FIX 3 — Duplicate HELP line.
  Same one-per-family rule as TYPE.
  Symptom: "second HELP line for metric name http_requests_total".
  Action:  delete line 6.

FIX 4 — Non-numeric sample value.
  A sample value must be a Go float64 literal: 1027, 21.4, 1.6e9, +Inf, -Inf,
  NaN — never a word. '0.provided' is not a number.
  Symptom: "expected float as value, got \"0.provided\"".
    -  app_temperature_celsius 0.provided
    +  app_temperature_celsius 21.4

CORRECTED /metrics payload (what verify must lint to exit 0):
    # HELP http_requests_total Total number of HTTP requests handled.
    # TYPE http_requests_total counter
    http_requests_total{method="GET",code="200"} 1027
    http_requests_total{method="POST",code="200"} 3
    # HELP app_temperature_celsius Current probe temperature in Celsius.
    # TYPE app_temperature_celsius gauge
    app_temperature_celsius 21.4

One-shot repair an SRE would actually run (overwrite with the good payload):
    cat > "$HOME/pca-lab-2.5/broken_metrics.prom" <<'FIXED'
    # HELP http_requests_total Total number of HTTP requests handled.
    # TYPE http_requests_total counter
    http_requests_total{method="GET",code="200"} 1027
    http_requests_total{method="POST",code="200"} 3
    # HELP app_temperature_celsius Current probe temperature in Celsius.
    # TYPE app_temperature_celsius gauge
    app_temperature_celsius 21.4
    FIXED

Or surgically, preserving the rest of the file:
    f="$HOME/pca-lab-2.5/broken_metrics.prom"
    sed -i '3d' "$f"                                   # drop duplicate TYPE
    sed -i 's/method=GET,/method="GET",/' "$f"         # quote the label value
    sed -i '/^# HELP http_requests_total Duplicate/d' "$f"   # drop duplicate HELP
    sed -i 's/^app_temperature_celsius .*/app_temperature_celsius 21.4/' "$f"
  (Note: delete the duplicate TYPE first, because that shifts line numbers.)

CONFIRM:
    bash pca_2_5_break_fix.sh verify     # -> "VALID ... Objective achieved. ✔", exit 0
TEAR DOWN:
    bash pca_2_5_break_fix.sh down

WHY THIS MATTERS (production takeaway)
  A target can be network-reachable, return HTTP 200, and STILL be up=0 in
  Prometheus because a single malformed line rejects the whole scrape. When a
  target flaps to "down" with no obvious network cause, pipe the raw endpoint
  through the parser — `curl -s <target>/metrics | promtool check metrics` —
  before you touch firewalls or scrape_configs.

Sources:
  https://prometheus.io/docs/instrumenting/exposition_formats/
  https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md
  https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
==== END SOLUTION =========================================================
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/pca/2.5/lab)
