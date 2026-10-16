## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
============================  SOLUTION (spoiler)  ========================== #
=========================================================================== #

SYMPTOM RECAP
  * Grafana panel / the recording rules 'pca:http_requests:rate' and
    'pca:head_series:deriv' show "No data".
  * rate(prometheus_http_requests_total[15s]) -> empty vector
    BUT rate(prometheus_http_requests_total[5m]) -> a real number.
  * No error anywhere. An empty range vector is silent.

ROOT CAUSE
  rate(), irate(), increase(), delta(), idelta(), deriv() and predict_linear()
  all consume a RANGE VECTOR (metric[window]) and need >= 2 samples inside that
  window to compute anything. Samples land once per scrape_interval. The lab
  scrape_interval is 30s, so a [15s] window holds at most ONE sample -> no pair
  of points -> the function yields nothing (empty), which downstream reads as
  "No data". The wide [5m] window works precisely because it spans several
  scrapes. The metric was never the problem; the window was.

STEP-BY-STEP FIX  (recommended: widen the window per query — scrape_interval is
                   a fleet-wide cost decision, not something to shrink per graph)

  1. Confirm the resolution you are working against:
       grep scrape_interval ${LAB_DIR:-$HOME/pca-lab-1.2-rates}/prometheus.yml
       # -> scrape_interval: 30s

  2. Edit the rules file and widen BOTH windows to >= 4 x scrape_interval.
     30s * 4 = 120s, so use [2m]:
       # in rates.rules.yml
       - record: pca:http_requests:rate
         expr: sum(rate(prometheus_http_requests_total[2m]))
       - record: pca:head_series:deriv
         expr: deriv(prometheus_tsdb_head_series[2m])

  3. Validate before loading it (never reload an unparsed rules file):
       promtool check rules ${LAB_DIR:-$HOME/pca-lab-1.2-rates}/rates.rules.yml
       # -> SUCCESS: 2 rules found

  4. Hot-reload without restarting (needs --web.enable-lifecycle, already set):
       curl -X POST http://127.0.0.1:9099/-/reload

  5. Wait one 15s evaluation cycle, then grade:
       ./rates_and_derivatives_breakfix.sh check
       # -> PASS — both rate() and deriv() now return data.

ALTERNATIVE FIX (shrink the resolution instead of widening the window)
  Edit prometheus.yml:  scrape_interval: 30s  ->  5s   (a [15s] window now holds
  3 samples), then reload and re-check. This also passes, but in production you
  normally keep scrape_interval stable and tune the window per query, because
  scrape frequency multiplies storage and target load across the whole fleet.

GOING DEEPER (what the exam wants you to distinguish)
  * rate()  = per-second AVERAGE over the window; smooths spikes; use in alerts
              and dashboards. Handles counter resets automatically.
  * irate() = per-second INSTANT rate from only the last two samples; twitchy;
              use for fast-moving graphs, never for slow-moving alert thresholds.
  * increase(metric[w]) == rate(metric[w]) * w ; the raw growth over the window.
  * rate/irate/increase are for COUNTERS only. Applying them to a gauge is
    meaningless (they assume monotonic-up-with-resets).
  * deriv()  = per-second slope of a GAUGE via least-squares linear regression.
  * predict_linear(gauge[w], t) extrapolates that regression t seconds ahead —
    the classic "disk full in 4h" alert:
       predict_linear(node_filesystem_avail_bytes[6h], 4*3600) < 0
  * delta()/idelta() are the gauge analogues of increase()/irate difference.
  In every one of these, the same trap applies: window < 2 x scrape_interval
  => empty vector. Aim for window >= 4 x scrape_interval for resilience to a
  missed scrape.

CLEAN UP
  ./rates_and_derivatives_breakfix.sh stop     # leave data, stop the process
  ./rates_and_derivatives_breakfix.sh clean    # remove ${LAB_DIR} entirely
=========================================================================== #
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/pca/1.2/lab)
