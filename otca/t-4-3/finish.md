## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
============================  SOLUTION (spoiler)  ===========================

STEP 1 — Reproduce and read the evidence
  $ ./this_script.sh inspect

  You will see, side by side:
    - local-sink.json growing              -> the pipeline itself is healthy;
                                              the problem is ONE exporter, not
                                              the receiver or processors.
    - Collector log lines such as:
        "Exporting failed. Rejecting data. ... connect: connection refused"
        "Dropping data because sending_queue is disabled"  (or "Permanent error")
    - otelcol_exporter_send_failed_spans{exporter="otlphttp/backend"} rising,
      and NO otelcol_exporter_queue_size series at all.

  Diagnosis: the backend is unreachable (transient outage), but the exporter
  has retry_on_failure.enabled=false and sending_queue.enabled=false, so the
  first failure is treated as terminal and the batch is discarded. This is the
  classic OpenTelemetry error-handling failure: silent, permanent data loss on
  a recoverable error.

STEP 2 — Fix the error handling in the exporter
  Edit ${LAB_DIR}/collector.yaml and replace the otlphttp/backend block with:

    otlphttp/backend:
      endpoint: http://127.0.0.1:4999
      retry_on_failure:
        enabled: true          # retry transient errors ...
        initial_interval: 1s    # ... starting at 1s ...
        max_interval: 10s       # ... capped at 10s per attempt ...
        max_elapsed_time: 120s  # ... giving up only after 2 minutes.
      sending_queue:
        enabled: true          # buffer instead of drop; apply backpressure
        num_consumers: 4
        queue_size: 1000       # bound the buffer so memory stays predictable
        # For crash-safe delivery, back the queue with disk:
        #   storage: file_storage       (add the file_storage extension)

  Notes on the mechanics (why this is the *correct* answer, not just "turn it on"):
    * retry_on_failure only retries errors the exporter classifies as RETRYABLE
      (connection refused, 503, DEADLINE_EXCEEDED). A PERMANENT error (e.g. 400
      bad request) is NOT retried by design — retrying it would loop forever.
    * sending_queue decouples the pipeline from the exporter. Without it, retry
      backoff blocks the consumer and creates backpressure to the receiver.
    * queue_size bounds memory: when the queue is FULL the Collector still drops
      (and increments otelcol_exporter_enqueue_failed_spans) — but now that is a
      deliberate, observable capacity limit, not an accident on the first error.
    * For guaranteed delivery across Collector restarts, persist the queue with
      the file_storage extension (storage: file_storage).

STEP 3 — Reload and confirm
  $ ./this_script.sh restart
  $ ./this_script.sh gen
  $ ./this_script.sh inspect

  Now the logs show retry/backoff ("... will retry ...") instead of immediate
  drops, and otelcol_exporter_queue_size is > 0 (data is buffered). Optionally,
  bring the backend UP (any listener on port 4999) and watch the queue flush —
  the previously "lost" ERROR spans are delivered once the backend recovers.

  $ ./this_script.sh verify     # -> PASS

STEP 4 — Relate it back to the exam
  OpenTelemetry error handling is layered, and 4.3 expects you to know all of it:
    API/SDK layer .... never throw into user code; route problems to a global
                       error handler; ERROR is expressed as Span Status code=2
                       plus RecordException, NOT as a crash.
    Collector layer .. the exporter helper (sending_queue + retry_on_failure) is
                       the resilience boundary; failures are LOGGED and COUNTED
                       (send_failed_spans / enqueue_failed_spans), never hidden.
  The bug in this lab was a Collector-layer error-handling misconfiguration that
  converted a recoverable, transient failure into silent permanent data loss.

  References:
    https://opentelemetry.io/docs/specs/otel/error-handling/
    https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/exporterhelper/README.md
    https://opentelemetry.io/docs/collector/troubleshooting/
    https://opentelemetry.io/docs/specs/otel/trace/api/#set-status
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/otca/4.3/lab)
