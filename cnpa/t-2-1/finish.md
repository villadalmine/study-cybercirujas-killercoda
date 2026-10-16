## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION  -  do not read until you have genuinely tried, or after passing.

STEP 0 - TRIAGE BEFORE TOUCHING ANYTHING
The single most valuable minute is spent deciding WHICH BOX is broken:

    kubectl -n obs-lab get pods
    NAME                                  READY   STATUS             RESTARTS
    event-storm-6c9f7d8b4-x2k9p           0/1     ImagePullBackOff   0
    otel-collector-7d5c6b9f8-abcde        0/1     CrashLoopBackOff   4
    prometheus-5f8d9c7b6-fghij            1/1     Running            0
    telemetry-producer-8b7c6d5f4-klmno    1/1     Running            0

Read that table as a signal map:
  - producer Running          -> telemetry IS being GENERATED.
  - collector CrashLoopBackOff-> the COLLECT/PROCESS box is dead.
  - prometheus Running        -> the STORE/QUERY box is alive.
  - event-storm ImagePullBackOff -> unrelated workload emitting EVENTS.

Conclusion in 20 seconds: the service is fine, the collector is the fault
domain, and there is a second, independent problem (event-storm) that is
noise for THIS incident but must be tracked separately. Resisting the urge
to fix the loud-but-irrelevant thing first is most of the skill.


STEP 1 - FAULT 2: THE TRACES PIPELINE (fix this first; nothing else can
         work while the collector will not start)
    kubectl -n obs-lab logs deploy/otel-collector --tail=30

  Expected:
    Error: failed to build pipelines: failed to create "traces" pipeline:
    processor "nonexistent_sampler" is not configured
    2026/xx/xx main.go:115 collector server run finished with error

  The collector validates its ENTIRE configuration at startup and refuses
  to run partially. One bad reference in one pipeline takes down all three.
  That is deliberate: a collector silently dropping a signal is worse than
  a collector that will not boot.

  Fix - remove the phantom processor from the traces pipeline:

    kubectl -n obs-lab edit cm otel-collector-config
    # under service.pipelines.traces.processors change:
    #     [memory_limiter, nonexistent_sampler, batch]
    # to:
    #     [memory_limiter, resource, batch]

  Non-interactive equivalent:

    kubectl -n obs-lab get cm otel-collector-config \
      -o jsonpath='{.data.collector\.yaml}' > /tmp/col.yaml
    sed -i 's/nonexistent_sampler/resource/' /tmp/col.yaml
    kubectl -n obs-lab create cm otel-collector-config \
      --from-file=collector.yaml=/tmp/col.yaml \
      --dry-run=client -o yaml | kubectl apply -f -


STEP 2 - FAULT 1: THE MISSING EXPORTER
  Compare the metrics pipeline against the known-good snapshot:

    diff <(kubectl -n obs-lab get cm otel-collector-config \
             -o jsonpath='{.data.collector\.yaml}') \
         <(yq '.data."collector.yaml"' \
             /tmp/cnpa-2.1-lab/otel-collector-config.good.yaml)

  The broken config has:
      metrics:
        receivers: [otlp]
        processors: [memory_limiter, resource, batch]
        exporters: [debug]            <-- 'prometheus' was removed

  This is the subtle one. The 'prometheus' EXPORTER block is still defined
  under exporters:, and the config is perfectly valid YAML and perfectly
  valid collector config -- an exporter that is declared but not wired into
  any pipeline is simply never instantiated. Nothing errors. Nothing warns
  loudly. Port 8889 never opens. Metrics arrive, get batched, get written
  to the debug exporter (stdout) and are then discarded.

  This is why you saw the producer logging success and the dashboard flat
  at the same time: DELIVERY SUCCEEDED, EXPOSURE DID NOT.

  Fix:
    kubectl -n obs-lab edit cm otel-collector-config
    # service.pipelines.metrics.exporters: [prometheus, debug]

  Then force the pods to pick up the new ConfigMap. A ConfigMap mounted as
  a volume DOES eventually refresh on disk (kubelet sync ~60s), but the
  collector does not hot-reload its config file, so a restart is required:

    kubectl -n obs-lab rollout restart deploy/otel-collector
    kubectl -n obs-lab rollout status  deploy/otel-collector

  Confirm the pipelines built:
    kubectl -n obs-lab logs deploy/otel-collector | grep -E 'Everything is ready|Starting'
    # Expected:
    #   info  service@v0.104.0/service.go:169  Starting otelcol-contrib...
    #   info  otlpreceiver@v0.104.0/otlp.go:102 Starting GRPC server {"endpoint": "0.0.0.0:4317"}
    #   info  otlpreceiver@v0.104.0/otlp.go:152 Starting HTTP server {"endpoint": "0.0.0.0:4318"}
    #   info  service@v0.104.0/service.go:195  Everything is ready. Begin running and processing data.

  Confirm exposure:
    kubectl -n obs-lab exec deploy/prometheus -- \
      wget -qO- http://otel-collector:8889/metrics | grep checkout_requests_total
    # Expected:
    #   # HELP checkout_requests_total
    #   # TYPE checkout_requests_total counter
    #   checkout_requests_total{deployment_environment="lab",http_route="/checkout",
    #     job="checkout-api",service_name="checkout-api"} 37


STEP 3 - FAULT 3: THE SCRAPE TARGET
  Even with the collector healthy, Prometheus still shows no data.
  Distinguish "not exposed" from "not collected":

    kubectl -n obs-lab exec deploy/prometheus -- \
      wget -qO- 'http://localhost:9090/api/v1/targets?state=active' | head -c 600

  Expected while broken:
    "scrapeUrl":"http://otel-collector.obs-lab.svc.cluster.local:8899/metrics",
    "health":"down",
    "lastError":"Get \"http://...:8899/metrics\": dial tcp 10.96.31.7:8899:
                 connect: connection refused"

  Port 8899 was never a real port. The collector exposes 8889 (prometheus
  exporter) and 8888 (its own internal telemetry). A single transposed
  digit is one of the most common real-world causes of a flat dashboard,
  and it is invisible unless you actually read /targets.

  Fix:
    kubectl -n obs-lab edit cm prometheus-config
    # scrape_configs[0].static_configs[0].targets:
    #   ['otel-collector.obs-lab.svc.cluster.local:8889']

  Prometheus supports hot reload, so no restart is needed if
  --web.enable-lifecycle is set (it is, in this lab):

    kubectl -n obs-lab exec deploy/prometheus -- \
      wget -qO- --post-data='' http://localhost:9090/-/reload

  Note the timing caveat: the ConfigMap volume on disk can lag the API
  object by up to the kubelet sync period. If the reload does not take,
  wait ~60s and retry, or restart the Deployment. Verify:

    kubectl -n obs-lab exec deploy/prometheus -- \
      wget -qO- 'http://localhost:9090/api/v1/query?query=up'
    # Expected: up{job="otel-collector-app-metrics"} -> "1"
    #           up{job="otel-collector-internal"}    -> "1"


STEP 4 - FAULT 4: THE EVENTS (understand, do not necessarily "fix")
    kubectl -n obs-lab get events --field-selector type=Warning \
      --sort-by=.lastTimestamp

  Expected:
    LAST SEEN  TYPE     REASON   OBJECT                 MESSAGE
    10s        Warning  Failed   pod/event-storm-x2k9p  Failed to pull image
               "registry.invalid/does-not-exist:v0": ... no such host
    10s        Warning  BackOff  pod/event-storm-x2k9p  Back-off pulling image

  The teaching point: this failure produced ZERO application logs (the
  container never started, so there is no stdout to read) and ZERO
  application metrics (nothing ever registered a meter). The ONLY evidence
  is a Kubernetes Event, and Events expire (kube-apiserver
  --event-ttl, default 1h). Fifty-one minutes later this incident is
  forensically invisible.

  That is why production platforms run an Event exporter -- for example the
  OpenTelemetry Collector's k8sobjects receiver, which turns Events into
  OTLP logs and ships them to durable storage:

      receivers:
        k8sobjects:
          objects:
            - name: events
              mode: watch
              group: events.k8s.io

  For the lab, either fix the image reference or remove the workload:
    kubectl -n obs-lab set image deploy/event-storm ghost=busybox:1.36
    kubectl -n obs-lab patch deploy event-storm --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/command",
           "value":["sh","-c","sleep infinity"]}]'
  or:
    kubectl -n obs-lab delete deploy event-storm


STEP 5 - WRITE THE ANSWER AND GRADE YOURSELF
    cat > /tmp/cnpa-2.1-lab/ANSWER.txt <<'TXT'
    Kubernetes Events are control-plane assertions about the lifecycle of
    API objects (scheduling, image pulls, probe failures) held in the API
    server with a ~1h TTL and authoritative for WHY the platform did or did
    not run my workload; the collector's stdout logs are application-level
    records emitted by a process that is already running and are
    authoritative for what that process did once alive. A container that
    never starts produces Events and no logs, which is exactly why a
    platform must ship both.
    TXT

    ./this-script.sh verify

  Expected output:
    [ OK ]  otel-collector has 1 ready replica(s).
    [ OK ]  Collector reports 'Everything is ready. ...'
    [ OK ]  Series advancing: 37 -> 39. Metrics are flowing end to end.
    [ OK ]  Prometheus is successfully scraping the collector.
    [ OK ]  ANSWER.txt found: ...
    SCORE 5/5  -  LAB PASSED.


STEP 6 - THE PREVENTION WORK (what a Principal Engineer writes in the
         post-mortem action items, and what the exam actually rewards)
  a) Alert on telemetry absence, not just on bad values:
       - alert: TelemetryPipelineSilent
         expr: absent(up{job="otel-collector-app-metrics"} == 1)
         for: 5m
       - alert: CollectorDroppingData
         expr: rate(otelcol_processor_dropped_metric_points_total[5m]) > 0

  b) Validate collector config in CI before it ever reaches a cluster:
       otelcol-contrib validate --config=collector.yaml
     This catches FAULT 2 (undefined processor) at merge time, for free.

  c) Treat "exporter declared but not wired" as a lint failure. FAULT 1 was
     undetectable at runtime precisely because it was valid config. Config
     validity is not config correctness.

  d) Ship Kubernetes Events to durable storage (k8sobjects receiver, or
     kubernetes-event-exporter) so post-mortems are possible after the TTL.

  e) Correlate the pillars: exemplars link a Prometheus histogram bucket to
     a trace_id; structured logs carry trace_id/span_id. Without correlation
     you own three disconnected tools instead of one observability system.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpa/2.1/lab)
