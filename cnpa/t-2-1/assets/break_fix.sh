#!/usr/bin/env bash
#
# ============================================================================
#  CNPA - Cloud Native Platform Associate
#  Domain 2: Observability  |  Topic 2.1: Observability Fundamentals
#  (Traces, Metrics, Logs, and Events)  -  Exam weight: 4.0%
#
#  BREAK & FIX LABORATORY  -  "The Silent Pipeline"
#
#  WARNING: This script INTENTIONALLY BREAKS a running system.
#           Run it ONLY on a disposable lab VM / throwaway kind cluster.
#           NEVER run it against a shared, staging or production cluster.
#
#  Reference sources:
#    - CNPA Curriculum (CNCF):
#        https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
#    - OpenTelemetry Collector configuration:
#        https://opentelemetry.io/docs/collector/configuration/
#    - OpenTelemetry Signals (traces, metrics, logs):
#        https://opentelemetry.io/docs/concepts/signals/
#    - Prometheus scrape configuration:
#        https://prometheus.io/docs/prometheus/latest/configuration/configuration/
#    - Kubernetes Events API:
#        https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/event-v1/
#    - kubectl debugging reference:
#        https://kubernetes.io/docs/tasks/debug/debug-application/
# ============================================================================

set -o pipefail

# ---------------------------------------------------------------------------
# Global configuration
# ---------------------------------------------------------------------------
NS="${LAB_NAMESPACE:-obs-lab}"
KUBECTL="${KUBECTL:-kubectl}"
LAB_STATE_DIR="${LAB_STATE_DIR:-/tmp/cnpa-2.1-lab}"
TIMEOUT="${TIMEOUT:-180s}"

# Container images. Pin digests in real production work; tags are fine in a lab.
IMG_OTEL_COLLECTOR="otel/opentelemetry-collector-contrib:0.104.0"
IMG_PROMETHEUS="prom/prometheus:v2.53.0"
IMG_APP="ghcr.io/open-telemetry/opentelemetry-demo:1.11.1-frontend"
IMG_BUSYBOX="busybox:1.36"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
c_reset=$'\033[0m'; c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'
c_yel=$'\033[1;33m'; c_blu=$'\033[1;34m'; c_mag=$'\033[1;35m'

say()   { printf '%s\n' "$*"; }
info()  { printf '%s[INFO]%s  %s\n'  "$c_blu" "$c_reset" "$*"; }
ok()    { printf '%s[ OK ]%s  %s\n'  "$c_grn" "$c_reset" "$*"; }
warn()  { printf '%s[WARN]%s  %s\n'  "$c_yel" "$c_reset" "$*"; }
err()   { printf '%s[FAIL]%s  %s\n'  "$c_red" "$c_reset" "$*" >&2; }
break_() { printf '%s[BREAK]%s %s\n' "$c_mag" "$c_reset" "$*"; }

hr() { printf '%s\n' "------------------------------------------------------------------------"; }

banner() {
  hr
  printf '  %s\n' "$*"
  hr
}

die() { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Safety guard: refuse to run against anything that smells like production
# ---------------------------------------------------------------------------
safety_check() {
  local ctx
  command -v "$KUBECTL" >/dev/null 2>&1 || die "kubectl not found in PATH."

  "$KUBECTL" cluster-info >/dev/null 2>&1 \
    || die "No reachable Kubernetes cluster. Start a kind/minikube cluster first."

  ctx="$("$KUBECTL" config current-context 2>/dev/null || echo unknown)"
  info "Current kubectl context: ${ctx}"

  case "$ctx" in
    *prod*|*production*|*prd*)
      die "Context '${ctx}' looks like PRODUCTION. Refusing to run. Switch context." ;;
  esac

  if [ "${I_UNDERSTAND_THIS_BREAKS_THINGS:-no}" != "yes" ]; then
    warn "This lab creates namespace '${NS}' and deliberately breaks the telemetry"
    warn "pipeline inside it. It touches NOTHING outside that namespace."
    printf '\nType exactly: BREAK IT  -> '
    read -r confirm
    [ "$confirm" = "BREAK IT" ] || die "Aborted by user."
  fi

  mkdir -p "$LAB_STATE_DIR" || die "Cannot create state dir ${LAB_STATE_DIR}"
  ok "Safety checks passed."
}

# ---------------------------------------------------------------------------
# STAGE 1 - Build a healthy, observable baseline
#
# Architecture we stand up (the classic three-pillar path):
#
#   [ workload pod ]                     Kubernetes Events
#     |  OTLP/gRPC :4317                       |
#     v                                        v
#   [ otel-collector ]  --- prometheus exporter :8889 ---> [ prometheus ]
#     |    receivers: otlp                                    (scrapes)
#     |    processors: batch, memory_limiter
#     |    exporters: prometheus, debug
#     v
#   stdout logs (debug exporter)  -> kubectl logs
#
# The student must understand that these are FOUR DISTINCT SIGNALS with
# different lifecycles:
#   - Metrics: numeric, aggregated, cheap, pre-aggregated at the source.
#   - Traces:  causal, per-request, sampled, expensive, carry context propagation.
#   - Logs:    unstructured/structured lines, high cardinality, no aggregation.
#   - Events:  Kubernetes control-plane facts about OBJECTS, TTL ~1h, NOT logs.
# ---------------------------------------------------------------------------
deploy_baseline() {
  banner "STAGE 1/3  -  Deploying a healthy observability baseline in ns/${NS}"

  "$KUBECTL" create namespace "$NS" --dry-run=client -o yaml | "$KUBECTL" apply -f - >/dev/null
  ok "Namespace ${NS} ready."

  info "Applying OpenTelemetry Collector (receivers -> processors -> exporters)..."
  cat <<'YAML' | sed "s/__NS__/${NS}/g; s#__IMG_COL__#${IMG_OTEL_COLLECTOR}#g" | "$KUBECTL" apply -f - >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: __NS__
data:
  collector.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      # memory_limiter MUST be first in every pipeline: it applies
      # backpressure before the batcher accumulates unbounded data.
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25
      batch:
        timeout: 5s
        send_batch_size: 512
      # Attributes added here become resource-level dimensions on every
      # signal leaving this collector. Keep cardinality bounded.
      resource:
        attributes:
          - key: deployment.environment
            value: lab
            action: upsert

    exporters:
      # Renders received metrics in Prometheus text format on :8889/metrics
      prometheus:
        endpoint: 0.0.0.0:8889
        resource_to_telemetry_conversion:
          enabled: true
      # debug replaced the old 'logging' exporter (deprecated in 0.86+)
      debug:
        verbosity: detailed

    service:
      telemetry:
        logs:
          level: info
        metrics:
          # The collector's OWN metrics. Observability of the observer.
          address: 0.0.0.0:8888
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, resource, batch]
          exporters: [debug]
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, resource, batch]
          exporters: [prometheus, debug]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, resource, batch]
          exporters: [debug]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: __NS__
  labels:
    app.kubernetes.io/name: otel-collector
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: otel-collector
  template:
    metadata:
      labels:
        app.kubernetes.io/name: otel-collector
    spec:
      containers:
        - name: collector
          image: __IMG_COL__
          args: ["--config=/conf/collector.yaml"]
          ports:
            - { name: otlp-grpc,  containerPort: 4317 }
            - { name: otlp-http,  containerPort: 4318 }
            - { name: prom-exp,   containerPort: 8889 }
            - { name: self-tel,   containerPort: 8888 }
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 512Mi }
          volumeMounts:
            - name: config
              mountPath: /conf
          livenessProbe:
            httpGet: { path: /, port: 13133 }
            initialDelaySeconds: 5
            failureThreshold: 6
      volumes:
        - name: config
          configMap:
            name: otel-collector-config
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: __NS__
  labels:
    app.kubernetes.io/name: otel-collector
spec:
  selector:
    app.kubernetes.io/name: otel-collector
  ports:
    - { name: otlp-grpc, port: 4317, targetPort: 4317 }
    - { name: otlp-http, port: 4318, targetPort: 4318 }
    - { name: prom-exp,  port: 8889, targetPort: 8889 }
    - { name: self-tel,  port: 8888, targetPort: 8888 }
YAML

  info "Applying Prometheus with a scrape job that targets the collector..."
  cat <<'YAML' | sed "s/__NS__/${NS}/g; s#__IMG_PROM__#${IMG_PROMETHEUS}#g" | "$KUBECTL" apply -f - >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: __NS__
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s
      external_labels:
        cluster: cnpa-lab

    scrape_configs:
      # Job A: application metrics forwarded by the collector's
      # prometheus exporter (OTLP -> Prometheus text format).
      - job_name: otel-collector-app-metrics
        static_configs:
          - targets: ['otel-collector.__NS__.svc.cluster.local:8889']

      # Job B: the collector's OWN internal telemetry. If Job A goes
      # quiet but Job B is green, the collector is alive and the fault
      # is upstream (receiver/pipeline), not the scrape path.
      - job_name: otel-collector-internal
        static_configs:
          - targets: ['otel-collector.__NS__.svc.cluster.local:8888']
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: __NS__
  labels:
    app.kubernetes.io/name: prometheus
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: prometheus
  template:
    metadata:
      labels:
        app.kubernetes.io/name: prometheus
    spec:
      containers:
        - name: prometheus
          image: __IMG_PROM__
          args:
            - --config.file=/etc/prometheus/prometheus.yml
            - --storage.tsdb.path=/prometheus
            - --storage.tsdb.retention.time=2h
            - --web.enable-lifecycle
          ports:
            - { name: web, containerPort: 9090 }
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits:   { cpu: 500m, memory: 1Gi }
          volumeMounts:
            - { name: config,  mountPath: /etc/prometheus }
            - { name: tsdb,    mountPath: /prometheus }
          readinessProbe:
            httpGet: { path: /-/ready, port: 9090 }
            initialDelaySeconds: 10
      volumes:
        - name: config
          configMap:
            name: prometheus-config
        - name: tsdb
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: __NS__
spec:
  selector:
    app.kubernetes.io/name: prometheus
  ports:
    - { name: web, port: 9090, targetPort: 9090 }
YAML

  info "Applying the telemetry producer (a synthetic OTLP client)..."
  cat <<'YAML' | sed "s/__NS__/${NS}/g; s#__IMG_APP__#${IMG_BUSYBOX}#g" | "$KUBECTL" apply -f - >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: telemetry-producer-script
  namespace: __NS__
data:
  # Emits OTLP/HTTP metrics + a trace on a loop. No SDK needed: raw JSON
  # over the OTLP/HTTP endpoint, which is exactly what the spec defines.
  # https://opentelemetry.io/docs/specs/otlp/#otlphttp
  produce.sh: |
    #!/bin/sh
    ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://otel-collector:4318}"
    SERVICE="checkout-api"
    i=0
    while true; do
      i=$((i+1))
      NOW="$(date +%s)000000000"
      wget -q -O- --timeout=5 \
        --header='Content-Type: application/json' \
        --post-data="{\"resourceMetrics\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"${SERVICE}\"}}]},\"scopeMetrics\":[{\"scope\":{\"name\":\"lab.producer\"},\"metrics\":[{\"name\":\"checkout_requests_total\",\"unit\":\"1\",\"sum\":{\"aggregationTemporality\":2,\"isMonotonic\":true,\"dataPoints\":[{\"asInt\":\"${i}\",\"timeUnixNano\":\"${NOW}\",\"startTimeUnixNano\":\"${NOW}\",\"attributes\":[{\"key\":\"http.route\",\"value\":{\"stringValue\":\"/checkout\"}}]}]}}]}]}]}" \
        "${ENDPOINT}/v1/metrics" >/dev/null 2>&1 \
        && echo "$(date -Iseconds) producer: metric sent seq=${i}" \
        || echo "$(date -Iseconds) producer: OTLP EXPORT FAILED seq=${i}"
      sleep 5
    done
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: telemetry-producer
  namespace: __NS__
  labels:
    app.kubernetes.io/name: telemetry-producer
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: telemetry-producer
  template:
    metadata:
      labels:
        app.kubernetes.io/name: telemetry-producer
    spec:
      containers:
        - name: producer
          image: __IMG_APP__
          command: ["/bin/sh", "/scripts/produce.sh"]
          env:
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector:4318"
            - name: OTEL_SERVICE_NAME
              value: "checkout-api"
          resources:
            requests: { cpu: 20m,  memory: 32Mi }
            limits:   { cpu: 100m, memory: 64Mi }
          volumeMounts:
            - { name: script, mountPath: /scripts }
      volumes:
        - name: script
          configMap:
            name: telemetry-producer-script
            defaultMode: 0755
YAML

  info "Waiting for the baseline to become Ready (timeout ${TIMEOUT})..."
  "$KUBECTL" -n "$NS" rollout status deploy/otel-collector     --timeout="$TIMEOUT" >/dev/null 2>&1 || warn "collector rollout slow"
  "$KUBECTL" -n "$NS" rollout status deploy/prometheus         --timeout="$TIMEOUT" >/dev/null 2>&1 || warn "prometheus rollout slow"
  "$KUBECTL" -n "$NS" rollout status deploy/telemetry-producer --timeout="$TIMEOUT" >/dev/null 2>&1 || warn "producer rollout slow"

  say ""
  "$KUBECTL" -n "$NS" get pods -o wide
  say ""
  ok "Baseline is up. Signals are flowing: metrics -> Prometheus, traces/logs -> collector stdout."
  say ""
  info "Prove it to yourself BEFORE anything breaks (this is your 'known good'):"
  say "    ${KUBECTL} -n ${NS} logs deploy/telemetry-producer --tail=5"
  say "    ${KUBECTL} -n ${NS} exec deploy/prometheus -- wget -qO- \\"
  say "        http://otel-collector:8889/metrics | grep checkout_requests_total"
  say ""
}

# ---------------------------------------------------------------------------
# Snapshot the known-good state so the student (and the verifier) can diff.
# ---------------------------------------------------------------------------
snapshot_good_state() {
  "$KUBECTL" -n "$NS" get cm otel-collector-config -o yaml > "${LAB_STATE_DIR}/otel-collector-config.good.yaml" 2>/dev/null
  "$KUBECTL" -n "$NS" get cm prometheus-config     -o yaml > "${LAB_STATE_DIR}/prometheus-config.good.yaml" 2>/dev/null
  ok "Known-good manifests snapshotted to ${LAB_STATE_DIR}/ (do not peek unless stuck)."
}

# ---------------------------------------------------------------------------
# STAGE 2 - THE BREAKAGE
#
# We inject FOUR faults, one per signal, so the student is forced to
# triage by signal type instead of restarting things at random.
#
#  FAULT 1 (metrics pipeline):  the 'prometheus' exporter is removed from
#          the metrics pipeline in the collector config. Metrics are still
#          RECEIVED, still processed, but never exposed. Prometheus keeps
#          scraping :8889 and gets a 200 with an empty-ish body.
#
#  FAULT 2 (traces pipeline):   the traces pipeline references a processor
#          that does not exist ('nonexistent_sampler'), so the collector
#          fails config validation for that pipeline at startup.
#
#  FAULT 3 (logs / scrape):     Prometheus scrape target is repointed to a
#          port nothing listens on (8899), so the target goes DOWN. This
#          separates "no data produced" from "no data collected".
#
#  FAULT 4 (events):            a workload is created that cannot be
#          scheduled/pulled, generating a stream of Kubernetes Warning
#          Events. Events are NOT logs and NOT metrics; they live in the
#          API server with a TTL and must be read with their own verbs.
# ---------------------------------------------------------------------------
inject_faults() {
  banner "STAGE 2/3  -  Injecting faults. From here on the pipeline is BROKEN."

  break_ "FAULT 1+2: rewriting the OpenTelemetry Collector configuration."
  cat <<'YAML' | sed "s/__NS__/${NS}/g" | "$KUBECTL" apply -f - >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: __NS__
data:
  collector.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25
      batch:
        timeout: 5s
        send_batch_size: 512
      resource:
        attributes:
          - key: deployment.environment
            value: lab
            action: upsert

    exporters:
      prometheus:
        endpoint: 0.0.0.0:8889
        resource_to_telemetry_conversion:
          enabled: true
      debug:
        verbosity: detailed

    service:
      telemetry:
        logs:
          level: info
        metrics:
          address: 0.0.0.0:8888
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, nonexistent_sampler, batch]
          exporters: [debug]
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, resource, batch]
          exporters: [debug]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, resource, batch]
          exporters: [debug]
YAML

  break_ "FAULT 3: repointing the Prometheus scrape target to a dead port."
  cat <<'YAML' | sed "s/__NS__/${NS}/g" | "$KUBECTL" apply -f - >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: __NS__
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s
      external_labels:
        cluster: cnpa-lab

    scrape_configs:
      - job_name: otel-collector-app-metrics
        static_configs:
          - targets: ['otel-collector.__NS__.svc.cluster.local:8899']

      - job_name: otel-collector-internal
        static_configs:
          - targets: ['otel-collector.__NS__.svc.cluster.local:8888']
YAML

  break_ "FAULT 4: deploying a workload that will emit Warning Events forever."
  cat <<'YAML' | sed "s/__NS__/${NS}/g" | "$KUBECTL" apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: event-storm
  namespace: __NS__
  labels:
    app.kubernetes.io/name: event-storm
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: event-storm
  template:
    metadata:
      labels:
        app.kubernetes.io/name: event-storm
    spec:
      containers:
        - name: ghost
          image: registry.invalid/does-not-exist:v0
          resources:
            requests: { cpu: 10m, memory: 16Mi }
YAML

  info "Restarting workloads so the poisoned ConfigMaps take effect..."
  "$KUBECTL" -n "$NS" rollout restart deploy/otel-collector >/dev/null
  "$KUBECTL" -n "$NS" rollout restart deploy/prometheus     >/dev/null

  info "Letting the failure settle (45s)..."
  sleep 45

  say ""
  "$KUBECTL" -n "$NS" get pods
  say ""
  ok "Faults injected."
}

# ---------------------------------------------------------------------------
# STAGE 3 - The student briefing
# ---------------------------------------------------------------------------
brief_student() {
  banner "STAGE 3/3  -  YOUR INCIDENT"

  cat <<BRIEF

  SCENARIO
  --------
  You are on call for the 'checkout-api' service. At 03:14 the Grafana
  dashboard 'Checkout / Golden Signals' went flat. Not spiky. FLAT. Every
  panel reads "No data". The service itself is answering traffic normally:
  customers are checking out, money is moving, nothing is on fire in the
  business sense.

  Your manager asks the only question that matters at 03:14:

      "Is the SERVICE down, or is the OBSERVABILITY down?"

  Everything below happens inside namespace: ${NS}
  Nothing outside that namespace was touched.


  SYMPTOMS YOU WILL OBSERVE
  -------------------------

  [S1] METRICS - the exposed metrics endpoint is empty.

       ${KUBECTL} -n ${NS} exec deploy/prometheus -- \\
           wget -qO- http://otel-collector:8889/metrics | grep checkout

       Expected while broken: no output at all, OR
       "wget: server returned error" / connection refused.
       The producer pod, meanwhile, keeps logging "metric sent seq=N"
       happily. Data is being PRODUCED. It is not being EXPOSED.

  [S2] TRACES - the collector's traces pipeline never starts.

       ${KUBECTL} -n ${NS} logs deploy/otel-collector --tail=40

       Expected while broken, something close to:
         error   service/service.go  failed to build pipelines:
           failed to create "traces" pipeline: processor "nonexistent_sampler"
           is not configured
         Error: cannot setup pipelines: ...
       The pod will be in CrashLoopBackOff or Error. Note the RESTARTS
       column climbing in 'get pods'.

  [S3] SCRAPING - Prometheus reports its target as DOWN.

       ${KUBECTL} -n ${NS} port-forward svc/prometheus 9090:9090
       # then open http://localhost:9090/targets  -- or, without a browser:
       ${KUBECTL} -n ${NS} exec deploy/prometheus -- \\
           wget -qO- 'http://localhost:9090/api/v1/query?query=up'

       Expected while broken: the series
         up{job="otel-collector-app-metrics"} = 0
       with lastError similar to:
         "Get \\"http://otel-collector...:8899/metrics\\": dial tcp
          10.96.x.x:8899: connect: connection refused"
       while up{job="otel-collector-internal"} may still be 1.
       Read that difference carefully. It is the whole lesson.

  [S4] EVENTS - a Warning Event storm nobody is watching.

       ${KUBECTL} -n ${NS} get events --sort-by=.lastTimestamp
       ${KUBECTL} -n ${NS} get events --field-selector type=Warning

       Expected while broken:
         Warning  Failed   pod/event-storm-...  Failed to pull image
           "registry.invalid/does-not-exist:v0": ... no such host
         Warning  BackOff  pod/event-storm-...  Back-off pulling image ...
       These Events exist ONLY in the API server, with a short TTL
       (default ~1h). They are not in your logs and not in your TSDB.
       If your platform does not ship Events somewhere durable, this
       evidence evaporates before the post-mortem meeting starts.


  WHAT YOU MUST ACHIEVE (definition of done)
  ------------------------------------------
  Run:  $0 verify

  It passes only when ALL of the following are true:

    1. Pod otel-collector is Running and Ready, with a stable restart
       count, and its logs show "Everything is ready. Begin running and
       processing data."
    2. The traces pipeline builds successfully (no "is not configured"
       error anywhere in the collector logs after the last restart).
    3. http://otel-collector:8889/metrics exposes the series
       checkout_requests_total  with a value that INCREASES between two
       reads 10 seconds apart.
    4. In Prometheus, up{job="otel-collector-app-metrics"} == 1.
    5. You can state, in one sentence written into the file
       ${LAB_STATE_DIR}/ANSWER.txt, why the Kubernetes Events from
       event-storm are a DIFFERENT signal class than the collector's
       stdout logs, and what each one is authoritative for.


  RULES OF ENGAGEMENT
  -------------------
  * Do NOT delete the namespace and re-run the deploy. That is not a fix,
    that is amnesia.
  * Do NOT edit this script. Fix the CLUSTER.
  * Reason signal by signal. Ask for each pillar: is it being GENERATED,
    COLLECTED, PROCESSED, EXPORTED, STORED, or QUERIED? The four faults
    live in four different boxes of that chain, and that is the point.
  * The known-good manifests were snapshotted to ${LAB_STATE_DIR}/ before
    the break. Consider that your "last good deploy" artifact. Using it is
    legitimate incident response, not cheating -- but read the diff, do
    not blind-apply it.

  Useful primitives:
    ${KUBECTL} -n ${NS} get pods
    ${KUBECTL} -n ${NS} describe pod <pod>
    ${KUBECTL} -n ${NS} logs deploy/otel-collector --previous
    ${KUBECTL} -n ${NS} get cm otel-collector-config -o jsonpath='{.data.collector\.yaml}'
    ${KUBECTL} -n ${NS} edit cm otel-collector-config
    ${KUBECTL} -n ${NS} rollout restart deploy/otel-collector
    ${KUBECTL} -n ${NS} get events --watch

  Good luck. The service is fine. Your eyes are not.

BRIEF
}

# ---------------------------------------------------------------------------
# Verifier - graded, signal by signal
# ---------------------------------------------------------------------------
verify() {
  banner "VERIFICATION  -  ns/${NS}"
  local score=0 total=5

  # --- Check 1: collector healthy -----------------------------------------
  info "[1/${total}] Collector pod healthy?"
  local ready
  ready="$("$KUBECTL" -n "$NS" get deploy otel-collector \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  if [ "${ready:-0}" -ge 1 ] 2>/dev/null; then
    ok "otel-collector has ${ready} ready replica(s)."
    score=$((score+1))
  else
    err "otel-collector is not Ready. Check: ${KUBECTL} -n ${NS} describe deploy/otel-collector"
  fi

  # --- Check 2: traces pipeline built -------------------------------------
  info "[2/${total}] Traces pipeline builds without errors?"
  local col_logs
  col_logs="$("$KUBECTL" -n "$NS" logs deploy/otel-collector --tail=200 2>/dev/null)"
  if printf '%s' "$col_logs" | grep -q "is not configured"; then
    err "Collector logs still contain a 'processor ... is not configured' error."
  elif printf '%s' "$col_logs" | grep -qi "Everything is ready"; then
    ok "Collector reports 'Everything is ready. Begin running and processing data.'"
    score=$((score+1))
  else
    warn "Could not confirm startup line; is the pod fresh? Re-run after a restart."
  fi

  # --- Check 3: metrics exposed AND advancing -----------------------------
  info "[3/${total}] Is checkout_requests_total exposed and increasing?"
  local v1 v2
  v1="$("$KUBECTL" -n "$NS" exec deploy/prometheus -- \
        wget -qO- --timeout=5 http://otel-collector:8889/metrics 2>/dev/null \
        | awk '/^checkout_requests_total/ {print $NF; exit}')"
  sleep 12
  v2="$("$KUBECTL" -n "$NS" exec deploy/prometheus -- \
        wget -qO- --timeout=5 http://otel-collector:8889/metrics 2>/dev/null \
        | awk '/^checkout_requests_total/ {print $NF; exit}')"

  if [ -n "$v1" ] && [ -n "$v2" ] && awk "BEGIN{exit !($v2 > $v1)}"; then
    ok "Series advancing: ${v1} -> ${v2}. Metrics are flowing end to end."
    score=$((score+1))
  elif [ -n "$v2" ]; then
    err "Series exposed (${v1} -> ${v2}) but NOT increasing. Is the producer running?"
  else
    err "checkout_requests_total is not exposed on :8889. The metrics pipeline is still broken."
  fi

  # --- Check 4: Prometheus target UP --------------------------------------
  info "[4/${total}] Prometheus target up{job=\"otel-collector-app-metrics\"} == 1?"
  local upq
  upq="$("$KUBECTL" -n "$NS" exec deploy/prometheus -- \
        wget -qO- --timeout=5 \
        'http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22otel-collector-app-metrics%22%7D' \
        2>/dev/null)"
  if printf '%s' "$upq" | grep -q '"1"'; then
    ok "Prometheus is successfully scraping the collector."
    score=$((score+1))
  else
    err "Target still DOWN or absent. Check the scrape_configs target port."
    printf '      raw: %s\n' "$(printf '%s' "$upq" | head -c 300)"
  fi

  # --- Check 5: the written answer ----------------------------------------
  info "[5/${total}] Written answer on Events vs Logs present?"
  if [ -s "${LAB_STATE_DIR}/ANSWER.txt" ] && \
     grep -qiE 'event' "${LAB_STATE_DIR}/ANSWER.txt" && \
     grep -qiE 'log'   "${LAB_STATE_DIR}/ANSWER.txt"; then
    ok "ANSWER.txt found:"
    sed 's/^/        /' "${LAB_STATE_DIR}/ANSWER.txt"
    score=$((score+1))
  else
    err "Write your one-sentence answer to ${LAB_STATE_DIR}/ANSWER.txt"
  fi

  hr
  if [ "$score" -eq "$total" ]; then
    printf '  %sSCORE %d/%d  -  LAB PASSED.%s\n' "$c_grn" "$score" "$total" "$c_reset"
    say "  You restored all four signals. Now run: $0 debrief"
    hr
    return 0
  fi
  printf '  %sSCORE %d/%d  -  keep digging.%s\n' "$c_yel" "$score" "$total" "$c_reset"
  hr
  return 1
}

# ---------------------------------------------------------------------------
debrief() {
  banner "DEBRIEF  -  what this incident was actually teaching"
  cat <<'DEBRIEF'

  1. THE FOUR SIGNALS ARE NOT INTERCHANGEABLE.

     METRICS  Aggregated numbers over time. Cheap, bounded, ideal for
              alerting and SLOs. They tell you SOMETHING is wrong.
              Cost scales with CARDINALITY (label combinations), not
              with traffic. Never put a user ID in a label.

     TRACES   One record per request, carrying causal parent/child spans
              across process boundaries via context propagation
              (W3C traceparent header). They tell you WHERE it is wrong.
              Almost always sampled: head sampling decides at the root,
              tail sampling decides after the trace is complete and can
              keep exactly the slow/errored ones.

     LOGS     Per-event text or structured records. Highest fidelity,
              highest cost, no aggregation. They tell you WHY it is wrong.
              Correlate them by injecting trace_id/span_id into every line.

     EVENTS   In Kubernetes specifically, Events are API objects
              (events.k8s.io/v1) that the control plane emits about other
              objects: scheduling decisions, image pulls, probe failures,
              evictions. They have a short TTL, they are namespaced, and
              they are NOT stored in your metrics DB or your log store
              unless you deliberately ship them there. Losing them means
              losing the control plane's own narration of the incident.

  2. THE PIPELINE HAS SIX PLACES TO FAIL. NAME THEM BEFORE YOU TOUCH ANYTHING.

        GENERATE -> COLLECT -> PROCESS -> EXPORT -> STORE -> QUERY

     This lab put one fault in EXPORT (missing prometheus exporter),
     one in PROCESS (undefined processor kills the traces pipeline),
     one in COLLECT (wrong scrape port), and used EVENTS to show a
     signal that never entered the pipeline at all. A dashboard reading
     "No data" is compatible with all six. Narrow the box first; only
     then edit YAML.

  3. OBSERVE THE OBSERVER.

     The reason job 'otel-collector-internal' exists is so that
     `up{job="otel-collector-internal"} == 1` while
     `up{job="otel-collector-app-metrics"} == 0` immediately tells you
     the collector process is alive and reachable, so the fault is in the
     pipeline or the target definition, not the network. The collector's
     own metrics (otelcol_receiver_accepted_spans,
     otelcol_exporter_send_failed_metric_points, otelcol_processor_dropped_*)
     are the fastest triage surface in an OpenTelemetry deployment.

  4. SILENT TELEMETRY IS AN OUTAGE.

     "No data" is never benign. Alert on ABSENCE, not only on thresholds:
        absent(up{job="otel-collector-app-metrics"} == 1)
        rate(otelcol_exporter_send_failed_metric_points_total[5m]) > 0
     An SLO you cannot measure is an SLO you do not have.

  Further reading:
    https://opentelemetry.io/docs/concepts/signals/
    https://opentelemetry.io/docs/collector/troubleshooting/
    https://opentelemetry.io/docs/concepts/sampling/
    https://prometheus.io/docs/practices/naming/
    https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/event-v1/

DEBRIEF
}

# ---------------------------------------------------------------------------
cleanup() {
  banner "CLEANUP"
  warn "About to delete namespace ${NS} and ${LAB_STATE_DIR}."
  printf 'Type DELETE to confirm -> '
  read -r c
  [ "$c" = "DELETE" ] || die "Aborted."
  "$KUBECTL" delete namespace "$NS" --wait=false >/dev/null 2>&1
  rm -rf "$LAB_STATE_DIR"
  ok "Namespace deletion requested; state dir removed."
}

usage() {
  cat <<USAGE
CNPA 2.1 - Observability Fundamentals - Break & Fix lab

Usage: $0 <command>

  break     Deploy the baseline, then inject the faults and brief you (default)
  brief     Re-print the incident briefing
  verify    Grade your fix (5 checks)
  debrief   Print the teaching notes (read AFTER you pass)
  solution  Print the step-by-step solution (last resort)
  cleanup   Delete namespace ${NS} and lab state

Environment overrides:
  LAB_NAMESPACE (default: obs-lab)   KUBECTL (default: kubectl)
  LAB_STATE_DIR (default: /tmp/cnpa-2.1-lab)
  I_UNDERSTAND_THIS_BREAKS_THINGS=yes  skips the interactive confirmation
USAGE
}

main() {
  case "${1:-break}" in
    break)
      safety_check
      deploy_baseline
      snapshot_good_state
      inject_faults
      brief_student
      ;;
    brief)    brief_student ;;
    verify)   verify ;;
    debrief)  debrief ;;
    solution) sed -n '/^# =\{10,\}$/,$p' "$0" | sed -n '/SOLUTION/,$p' | sed 's/^# \{0,1\}//' ;;
    cleanup)  cleanup ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
exit 0
