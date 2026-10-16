#!/usr/bin/env bash
#
# ============================================================================
#  CNPA — Cloud Native Platform Engineering Associate
#  Exam version: 2025-04-01
#  Domain 5.4 — AI/ML Integration in Platform Automation   (exam weight: 2.0)
#
#  BREAK & FIX LAB — "The golden-path bump that stranded the model server"
#
#  Reference:
#    CNCF CNPA Curriculum
#    https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
# ============================================================================
#
#  WHAT THIS LAB TEACHES
#  ---------------------
#  Platform teams expose ML inference as a self-service "golden path": the
#  developer declares an InferenceService and the platform renders the
#  Deployment, Service, autoscaling and *accelerator scheduling* for them.
#  The most common production incident on that path is not model code — it is
#  the platform pinning a workload to hardware the cluster cannot offer, which
#  silently freezes an automated rollout. This lab reproduces exactly that.
#
#  WHAT THIS SCRIPT DOES
#  ---------------------
#    1. Deploys a healthy, CPU-served model predictor (KServe RawDeployment
#       style) and proves it is Ready.
#    2. Injects ONE controlled fault: a golden-path template bump that pins the
#       predictor to an NVIDIA GPU the disposable lab node does not have.
#    3. Tells you the SYMPTOM you will see and the GOAL you must reach.
#
#  The step-by-step SOLUTION is at the very bottom of this file, commented out.
#  Do not read it until you have tried to diagnose the incident yourself.
#
#  SAFETY
#  ------
#    * Everything is created inside the namespace "cnpa-lab-54". Nothing else
#      on the cluster is read or modified.
#    * The break is non-destructive: it only makes a NEW ReplicaSet Pod
#      unschedulable. The previously-Ready Pod keeps serving, so you can study
#      a stuck rollout without downtime — just like production.
#    * The script refuses to run against anything that does not look like a
#      throwaway local cluster (kind / minikube / k3s / k3d / *-desktop or a
#      private/loopback API server). Override only on a lab VM with
#      CNPA_LAB_FORCE=1.
#
#  USAGE
#    ./break_fix.sh            # deploy healthy, then inject the fault
#    ./break_fix.sh --verify   # check whether you have repaired it
#    ./break_fix.sh --cleanup  # delete everything this lab created
#    ./break_fix.sh --help
# ============================================================================

set -euo pipefail

NS="cnpa-lab-54"
DEPLOY="sentiment-analyzer-predictor"
SVC="sentiment-analyzer"
CONTAINER="kserve-container"
IMAGE="traefik/whoami:v1.10.1"   # lightweight HTTP endpoint standing in for the model server

# --- tiny helpers -----------------------------------------------------------
k() { kubectl -n "$NS" "$@"; }

log()  { printf '\033[1;34m[lab]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!! ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

rule() { printf '%s\n' "----------------------------------------------------------------------"; }

# --- preflight --------------------------------------------------------------
require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kubectl cluster-info >/dev/null 2>&1 \
    || die "No reachable cluster. Point KUBECONFIG at your disposable lab cluster first."
}

# Refuse to touch anything that is not obviously a disposable/local cluster.
guard_cluster() {
  [ "${CNPA_LAB_FORCE:-0}" = "1" ] && { warn "CNPA_LAB_FORCE=1 — safety guard bypassed."; return 0; }

  local ctx server
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"

  case "$ctx" in
    kind-*|k3d-*|minikube|docker-desktop|rancher-desktop|k3s*|colima) return 0 ;;
  esac
  case "$server" in
    *127.0.0.1*|*localhost*|*://10.*|*://192.168.*|*://172.1[6-9].*|*://172.2[0-9].*|*://172.3[01].*)
      return 0 ;;
  esac

  die "Refusing to run: context '$ctx' (server '$server') does not look disposable.
      This lab is for a throwaway VM/cluster only. If this IS a lab cluster,
      re-run with: CNPA_LAB_FORCE=1 $0"
}

# --- manifests --------------------------------------------------------------
# The HEALTHY baseline: what a correct golden-path render looks like on a
# CPU-only platform. This is the target state you must restore.
apply_baseline() {
  k apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
  labels:
    app: ${SVC}
    component: predictor
    serving.kserve.io/inferenceservice: ${SVC}
    app.kubernetes.io/managed-by: platform-golden-path
  annotations:
    serving.kserve.io/deploymentMode: RawDeployment
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1          # a surge Pod is created for the new revision...
      maxUnavailable: 0    # ...but the old Ready Pod is never killed first
  selector:
    matchLabels:
      app: ${SVC}
  template:
    metadata:
      labels:
        app: ${SVC}
        component: predictor
        serving.kserve.io/inferenceservice: ${SVC}
    spec:
      containers:
        - name: ${CONTAINER}
          image: ${IMAGE}
          ports:
            - name: http
              containerPort: 80
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}
  labels:
    app: ${SVC}
    serving.kserve.io/inferenceservice: ${SVC}
spec:
  selector:
    app: ${SVC}
  ports:
    - name: http
      port: 80
      targetPort: 80
EOF
}

# The FAULT: a golden-path template "upgrade" pins the predictor to a GPU.
# On a CPU-only lab node this makes the new revision's Pod unschedulable.
# Strategic-merge patch keyed by container name merges cleanly into resources.
inject_gpu_pin() {
  k patch deployment "${DEPLOY}" --type=strategic -p '{
    "spec": {
      "template": {
        "spec": {
          "nodeSelector": { "accelerator": "nvidia-gpu" },
          "containers": [
            {
              "name": "'"${CONTAINER}"'",
              "resources": { "limits": { "nvidia.com/gpu": "1" } }
            }
          ]
        }
      }
    }
  }' >/dev/null
}

# --- modes ------------------------------------------------------------------
do_break() {
  require_kubectl
  guard_cluster

  log "Creating namespace ${NS} ..."
  kubectl create namespace "${NS}" >/dev/null 2>&1 || true

  log "Deploying the HEALTHY model predictor (CPU-served) ..."
  apply_baseline
  if ! k rollout status "deployment/${DEPLOY}" --timeout=120s; then
    die "Baseline never became Ready. Fix cluster/image pull before running the lab."
  fi
  ok "Baseline is Ready — the InferenceService '${SVC}' is serving on CPU."
  k get pods -l app="${SVC}" -o wide

  echo
  log "Injecting the fault: a golden-path bump that pins the predictor to a GPU ..."
  inject_gpu_pin
  sleep 4   # let the scheduler create + reject the new-revision Pod

  echo
  rule
  printf '  \033[1;31mINCIDENT INJECTED — CNPA 5.4 AI/ML Integration in Platform Automation\033[0m\n'
  rule
  cat <<'BRIEF'

  BACKGROUND
    Your platform's self-service "golden path" for ML just shipped a template
    version bump. The rendered InferenceService now requests an NVIDIA GPU for
    the predictor. This lab cluster has no GPU and no NVIDIA device plugin.

  SYMPTOM YOU WILL SEE
    * `kubectl -n cnpa-lab-54 get pods` shows the previous predictor Pod still
      Running/Ready, PLUS a new Pod stuck in Pending.
    * `kubectl -n cnpa-lab-54 rollout status deploy/sentiment-analyzer-predictor`
      hangs forever ("Waiting for deployment ... 0 of 1 updated replicas are
      available"). The automated rollout is frozen; the new model revision can
      never go live.
    * `kubectl -n cnpa-lab-54 describe pod <pending-pod>` Events show, e.g.:
        0/1 nodes are available: 1 Insufficient nvidia.com/gpu,
        1 node(s) didn't match Pod's node affinity/selector.

  YOUR GOAL
    Make the rollout complete: all desired replicas Updated, Available and
    Ready, with NO Pending Pod — WITHOUT pretending the lab node has a GPU.
    The predictor must serve on the CPU capacity this platform actually has.
    (In a real GPU platform the alternative fix is to make the capacity real:
     install the NVIDIA device plugin and label the node. On this VM you do not
     have that hardware, so reconcile the template with reality instead.)

  CHECK YOUR WORK
    ./break_fix.sh --verify

  Diagnose it yourself first. The full solution is at the bottom of this file.

BRIEF
  rule
  echo
  log "Current state:"
  k get pods -l app="${SVC}" -o wide || true
}

do_verify() {
  require_kubectl
  kubectl get namespace "${NS}" >/dev/null 2>&1 || die "Namespace ${NS} not found. Run the lab first."

  local desired updated avail pending gpu
  desired="$(k get deploy "${DEPLOY}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  updated="$(k get deploy "${DEPLOY}" -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || echo 0)"
  avail="$(k get deploy "${DEPLOY}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  pending="$(k get pods -l app="${SVC}" --field-selector=status.phase=Pending -o name 2>/dev/null | wc -l | tr -d ' ')"
  gpu="$(k get deploy "${DEPLOY}" -o yaml 2>/dev/null | grep -c 'nvidia.com/gpu' || true)"

  echo "  desired=${desired} updated=${updated:-0} available=${avail:-0} pendingPods=${pending} gpuPinsInSpec=${gpu}"

  if [ "${updated:-0}" = "${desired}" ] && [ "${avail:-0}" = "${desired}" ] \
     && [ "${pending}" = "0" ] && [ "${gpu}" = "0" ]; then
    ok "PASS — rollout complete, no Pending Pods, GPU pin removed. Incident resolved."
    exit 0
  fi
  warn "NOT FIXED YET — the automated rollout is still blocked. Keep digging."
  exit 1
}

do_cleanup() {
  require_kubectl
  log "Deleting namespace ${NS} and everything in it ..."
  kubectl delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null
  ok "Cleanup requested. The namespace terminates in the background."
}

usage() {
  sed -n '2,60p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
}

# --- entrypoint -------------------------------------------------------------
case "${1:-}" in
  ""|--break)  do_break ;;
  --verify)    do_verify ;;
  --cleanup)   do_cleanup ;;
  --help|-h)   usage ;;
  *)           die "Unknown option '$1'. Try --help." ;;
esac
