## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
============================ SOLUTION (SPOILER) ==============================

Do not read this until `verify` has beaten you at least twice. Print it with:
    ./704.4-tracing-breakfix.sh solution

STEP 0 - Establish what kind of incident this is
    curl -s http://127.0.0.1:18081/buy | python3 -m json.tool
    ./704.4-tracing-breakfix.sh load 5
    ./704.4-tracing-breakfix.sh traces        # -> no traces stored (0)

The application returns 200. Availability is fine. What is down is the
OBSERVABILITY PIPELINE, and it is down in three places at once. Work the
pipeline in the order data flows through it:
    create span -> sample -> export -> receive -> assemble by context.

STEP 1 - Fault 3: the exporter is pointed at the wrong OTLP port
Symptom: payments-api spans never reach the backend, and the service log is
shouting about it. This is the loudest fault, so it is the cheapest one to fix.

    ./704.4-tracing-breakfix.sh logs payments-api 20
      -> OTLP EXPORT FAILED endpoint=http://127.0.0.1:14317/v1/traces
         error=URLError: <urlopen error [Errno 111] Connection refused>
    curl -s http://127.0.0.1:18082/-/stats | python3 -m json.tool
      -> "spans_sampled": N, "spans_exported_ok": 0, "span_export_failures": N

Read that pair of counters carefully: spans ARE being created and sampled, the
transport is what fails. Confirm nothing listens on the configured port:
    ss -lntp | grep -E '1431[78]'

Root cause: an HTTP/JSON exporter aimed at the gRPC port. In the real world
that is OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4317 with
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf. The two OTLP transports do not share
a port: 4317 is gRPC, 4318 is HTTP.
    https://opentelemetry.io/docs/specs/otlp/

Fix:
    sed -i 's|^OTEL_EXPORTER_OTLP_ENDPOINT=.*|OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:14318|' \
        ~/lpi-704.4-tracing-lab/etc/payments-api.env
    ./704.4-tracing-breakfix.sh restart
    ./704.4-tracing-breakfix.sh load 3
    ./704.4-tracing-breakfix.sh traces

New state: traces appear, but every one of them contains ONLY payments-api
spans, and each has payments-api as the root. The frontend is still invisible.

STEP 2 - Fault 1: head sampling set to zero in the entry service
Symptom: checkout-frontend never appears anywhere, and its log is completely
silent - no export errors at all. Silence is the diagnosis: an exporter that is
failing complains; a sampler that decided NOT to record produces nothing to
complain about.

    curl -s http://127.0.0.1:18081/-/stats | python3 -m json.tool
      -> "sampler": "parentbased_traceidratio(ratio=0.000)"
         "spans_started": N, "spans_sampled": 0, "spans_dropped_by_sampler": N
         "span_export_failures": 0
    grep SAMPLER ~/lpi-704.4-tracing-lab/etc/checkout-frontend.env

Root cause: OTEL_TRACES_SAMPLER_ARG=0.0. This is head-based sampling: the
decision is taken when the root span starts, it is recorded in the `sampled`
bit of the traceparent flags, and every downstream service running a
parentbased_* sampler obeys it. One wrong ratio at the edge blanks out the
whole distributed trace, not just one service's spans - which is exactly why a
sampling ratio belongs in reviewed configuration, not in an ad-hoc override.
    https://opentelemetry.io/docs/concepts/sampling/

Fix (1.0 = keep everything; in production you would use a value your backend
can afford, or move to tail sampling in the Collector):
    sed -i 's|^OTEL_TRACES_SAMPLER_ARG=.*|OTEL_TRACES_SAMPLER_ARG=1.0|' \
        ~/lpi-704.4-tracing-lab/etc/checkout-frontend.env
    ./704.4-tracing-breakfix.sh restart
    ./704.4-tracing-breakfix.sh load 3
    ./704.4-tracing-breakfix.sh traces

New state: both services now produce spans, but ONE user request yields TWO
trace ids - one holding the two frontend spans, one holding the two payments
spans, each with its own root. The data is there; the causality is not.

STEP 3 - Fault 2: the gateway strips the context headers
Symptom: broken/orphan traces. payments-api logs the smoking gun on every call:

    ./704.4-tracing-breakfix.sh logs payments-api 20
      -> no usable traceparent on inbound request: starting a NEW root trace (raw=None)
    ./704.4-tracing-breakfix.sh logs edge-proxy 10
      -> POST /pay -> ... forwarded=['content-type', 'x-request-id', ...]
                      stripped=['traceparent', 'tracestate']
    curl -s http://127.0.0.1:18080/-/config

Prove it from the outside, bypassing the gateway to isolate the hop:
    curl -s -X POST -H 'traceparent: 00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01' \
         http://127.0.0.1:18082/pay      # direct  -> "had_parent": true
    curl -s -X POST -H 'traceparent: 00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01' \
         http://127.0.0.1:18080/pay      # gateway -> "had_parent": false

Root cause: the gateway forwards only an explicit header allowlist and
`traceparent` / `tracestate` were dropped from it. Trace context is carried in
ordinary HTTP headers (W3C Trace Context, section 3), so any hop that filters
headers can sever a trace without producing a single error, a single dropped
request, or a single failed health check. The same bug appears as: an nginx
`proxy_set_header` block that does not pass the header, `underscores_in_headers
off`, an AWS ALB/CloudFront policy, a Kong/Envoy filter, or an application
HTTP client built without the propagator installed.
    https://www.w3.org/TR/trace-context/

Fix:
    sed -i 's|^PROXY_FORWARD_HEADERS=.*|PROXY_FORWARD_HEADERS=host,content-type,accept,user-agent,x-request-id,traceparent,tracestate|' \
        ~/lpi-704.4-tracing-lab/etc/edge-proxy.env
    ./704.4-tracing-breakfix.sh restart

STEP 4 - Verify the end state, and read the trace you repaired
    ./704.4-tracing-breakfix.sh verify         # must exit 0, five PASS lines
    ./704.4-tracing-breakfix.sh traces
    ./704.4-tracing-breakfix.sh trace last

Expected waterfall - one trace id, one root, four spans, two services:

    Trace 9f2c...  spans=4  duration=41.2ms  services=checkout-frontend,payments-api
    [SERVER  ] checkout-frontend  GET /buy            +   0.0ms   41.2ms
      [CLIENT  ] checkout-frontend  POST /pay         +   1.1ms   39.0ms
        [SERVER  ] payments-api     POST /pay         +   3.4ms   33.0ms
          [INTERNAL] payments-api   db.query ledger   +   5.2ms   14.7ms

The CLIENT/SERVER pair around one network hop is the point of the whole
exercise: the difference between those two durations is the time the request
spent in the network and in the gateway, and you can only measure it when the
context survives the hop.

    ./704.4-tracing-breakfix.sh clean          # remove the lab

WHAT TO CARRY INTO THE EXAM AND INTO PRODUCTION
 * A trace is not a log stream. It is a causal tree assembled from a trace id
   plus parent-child span ids, propagated in-band over the request itself.
 * Three distinct silent failure modes, each with a different signature:
     not created/sampled -> spans_dropped_by_sampler > 0, no errors anywhere
     not exported        -> export failures in the producer's log, backend empty
     not correlated      -> data present, but multiple roots / orphan spans
 * Head sampling is decided once, at the edge, and is binding for the whole
   trace via the traceparent sampled flag. Mixed ratios across services produce
   permanently incomplete traces.
 * Every hop is a chance to lose the context. Gateways, meshes, message queues,
   cron-triggered jobs and thread pools all need explicit propagation.
 * Instrument the instrumentation. Export SDK and Collector self-telemetry
   (otelcol_receiver_accepted_spans, otelcol_exporter_send_failed_spans) and
   alert on it; otherwise a broken pipeline looks exactly like a quiet system.

EXTRA CREDIT (not injected - break them yourself)
 1. Set OTEL_TRACES_SAMPLER_ARG=0.5 on the frontend only, send 20 requests, and
    confirm you get ~10 COMPLETE traces, never 20 half-traces. That is what
    parentbased_* buys you.
 2. Set OTEL_TRACES_SAMPLER=always_on on payments-api while the frontend stays
    at 0.0, and observe the orphan-root spans that a non-parent-based sampler
    creates downstream.
 3. Corrupt the propagated context by hand (traceparent with a 31-hex trace id,
    or an all-zero span id) and watch the receiver correctly refuse it and start
    a new root - W3C Trace Context requires exactly that.
 4. Re-point both services at a real backend and confirm the payloads are
    genuinely OTLP: docker run --rm -p 4318:4318 -p 16686:16686 \
    jaegertracing/all-in-one, then set OTEL_EXPORTER_OTLP_ENDPOINT=
    http://127.0.0.1:4318 in both etc/*.env and open the Jaeger UI on :16686.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpi-devops/704.4/lab)
