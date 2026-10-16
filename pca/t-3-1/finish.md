## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
===========================  SOLUTION (SPOILER)  ==========================
Do not read this until you have attempted the fix. Everything below is a
comment; nothing here executes.

STEP 1 — Confirm the symptom precisely.

    curl -s http://localhost:9100/metrics \
      | grep -E '^app_|^node_textfile_scrape_error'

  Expected while broken:
    node_textfile_scrape_error 1
  ...and zero app_* lines. The "1" tells you a textfile failed to parse; the
  total absence of app_* tells you the failure took the whole file with it.

STEP 2 — Ask the exporter what it rejected (read the actual error, don't
         guess).

    docker logs pca-node-exporter  | grep -i textfile     # or 'podman logs'

  You will see a message similar to:
    level=error ... collector=textfile ... msg="failed to collect textfile
      data" file=app_metrics.prom err="text format parsing error in line 8:
      expected float as value, got \"21,7\""

  That line/column pinpoints the offending sample value.

STEP 3 — Understand WHY it failed (the exam-relevant concept).

  The Prometheus text exposition format defines each sample line as:
      metric_name[{label="value",...}]  VALUE  [timestamp]
  VALUE must be a float64 as parsed by Go's strconv.ParseFloat: an optional
  sign, decimal digits with a '.' separator, optional exponent, or the
  special tokens +Inf, -Inf, NaN. A locale decimal comma ("21,7") is NOT a
  valid float, so the parser aborts.

  Crucially, the textfile collector parses each *file* as one unit. A single
  malformed line invalidates the ENTIRE file, so the healthy counter series
  (app_requests_total) disappear as collateral damage. That is why the
  symptom was "all metrics from this file gone", not "one metric wrong".

  Ref: https://prometheus.io/docs/instrumenting/exposition_formats/
       https://prometheus.io/docs/concepts/data_model/

STEP 4 — Fix the file. Edit /tmp/pca-3.1-metrics-lab/textfile/app_metrics.prom
         and change the comma to a decimal point:

         -   app_temperature_celsius 21,7
         +   app_temperature_celsius 21.7

  One-liner:
    sed -i 's/^app_temperature_celsius 21,7$/app_temperature_celsius 21.7/' \
      /tmp/pca-3.1-metrics-lab/textfile/app_metrics.prom

  Also make sure the file still ends with a trailing newline — the textfile
  collector requires files to end in '\n' or it will report a parse error on
  the final line. ('cat -A file' should show the last line ending in '$'.)

STEP 5 — Verify (no restart needed; node_exporter re-reads on every scrape).

    curl -s http://localhost:9100/metrics \
      | grep -E '^app_|^node_textfile_scrape_error'

  Expected once fixed:
    node_textfile_scrape_error 0
    app_requests_total{method="GET",status="200"} 1027
    app_requests_total{method="POST",status="201"} 342
    app_temperature_celsius 21.7

  Or simply:  ./pca_3.1_metrics_breakfix.sh --verify   (prints PASS/FAIL)

STEP 6 — Tear the lab down when finished:

    ./pca_3.1_metrics_breakfix.sh --cleanup

TAKEAWAYS FOR THE EXAM
  * The exposition format is strict: metric_name, optional {labels}, a single
    float64 value, optional timestamp. Values use '.', never ',' — and
    special values are +Inf / -Inf / NaN only.
  * node_textfile_scrape_error is your first-line signal that a target is
    serving a malformed textfile; when it is 1, expect whole files (not
    single samples) to be missing.
  * Instrumentation correctness is upstream of everything: PromQL, alerting
    and dashboards cannot query a series the exporter refused to expose.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/pca/3.1/lab)
