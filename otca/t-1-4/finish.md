## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
#                         SOLUTION  (do not peek early)                   #
###########################################################################

ROOT CAUSE
  The traces pipeline contains an extra stage:

      processors: [filter/outcomes, batch]
                    ^^^^^^^^^^^^^^^

  whose definition is:

      filter/outcomes:
        error_mode: ignore
        traces:
          span:
            - 'name != ""'

  The filter processor DROPS any span for which a listed OTTL condition is
  true. The condition 'name != ""' is true for every span that has a name —
  i.e. all of them. So 100% of the checkout spans are discarded before they
  ever reach the debug/file exporters, and the analysis surface stays empty.
  The Collector is perfectly healthy; the *outcome* is destroyed by an
  over-broad filter. This is exactly how a well-meant "drop health-check
  noise" rule silently deletes production traffic.

DIAGNOSIS PATH (what a student should actually do)
  1. Prove the emitter is innocent:
         ./otca_1_4_break_fix.sh logs
     The Collector shows it started and is listening; the load generator got
     HTTP 200. So the loss is INSIDE the Collector, not before it.

  2. Read the pipeline top-to-bottom:
         cat /tmp/otca-1.4-lab/collector.yaml
     Walk every processor in service.pipelines.traces.processors IN ORDER.
     Anything that can drop/sample/route data is a suspect: filter,
     probabilistic_sampler, tail_sampling, routing, transform (with a drop).

  3. Turn the Collector's own telemetry into evidence. Raise verbosity or add
     the count connector to see per-processor throughput. Quick check: bump
     the debug exporter and watch that 0 spans are exported while spans are
     received — the gap sits at the filter stage.

  4. Read the offending stage's intent vs. effect: 'name != ""' matches
     everything. That is the bug — an inverted / too-broad predicate.

THE FIX  (edit /tmp/otca-1.4-lab/collector.yaml)
  Option A — remove the fault entirely (correct here, since nothing needs
  dropping in this lab). Delete the filter/outcomes processor block AND remove
  it from the pipeline list:

      processors:
        batch: {}
      ...
      service:
        pipelines:
          traces:
            receivers: [otlp]
            processors: [batch]          # <- filter/outcomes removed
            exporters: [debug, file]

  Option B — keep a filter but fix the predicate so it only drops what you
  actually intend (e.g. real health-check spans), never real traffic:

      filter/outcomes:
        error_mode: ignore
        traces:
          span:
            - 'name == "/healthz"'       # narrow, intentional

VERIFY
      ./otca_1_4_break_fix.sh check
  Expected:
      [otca-1.4] Sent 1000 spans to http://localhost:4318/v1/traces -> HTTP 200 (expected 200).
      [otca-1.4] outcome: 1000 / 1000  -> PASS  ✅  Analysis now matches reality.
  (Or run ./otca_1_4_break_fix.sh solution to apply Option A automatically.)

THE OUTCOMES LESSON (why 1.4 cares)
  * "Green pipeline" is not "correct outcome." Liveness of the Collector says
    nothing about whether your analysis surface received the data.
  * Every drop/sample/route stage is part of your analysis, not a detail
    beneath it. A 10% probabilistic_sampler would have shown ~100/1000 here —
    a *plausible* number that is silently wrong, which is more dangerous than
    a zero. Under sampling you must interpret counts via adjusted_count, or
    your rates and SLIs are off by the sampling ratio.
  * Always validate outcomes end-to-end (emit N, expect N on the surface the
    analysis reads) — the counts-must-reconcile check this lab automates.

SOURCES (official)
  - OpenTelemetry Collector — Filter processor (drop semantics, OTTL):
    https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/filterprocessor/README.md
  - OpenTelemetry Collector — configuration, pipelines & processor ordering:
    https://opentelemetry.io/docs/collector/configuration/
  - OpenTelemetry — Sampling (head/tail, adjusted_count and its effect on outcomes):
    https://opentelemetry.io/docs/concepts/sampling/
  - OpenTelemetry — Debug exporter (pipeline observability):
    https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/debugexporter/README.md
  - OTLP/HTTP protocol (traces endpoint, JSON encoding):
    https://opentelemetry.io/docs/specs/otlp/
  - CNCF — OTCA curriculum:
    https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
###########################################################################
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/otca/1.4/lab)
