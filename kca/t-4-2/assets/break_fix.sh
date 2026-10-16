#!/usr/bin/env bash
#
# ============================================================================
#  KCA — Kubernetes and Cloud Native Associate
#  Domain 4: Scheduling  ·  Topic 4.2: Resource Selection  (exam weight 3.33)
#  Break & Fix lab — run ONLY on a disposable, throwaway lab VM / kind cluster.
# ============================================================================
#
#  What "Resource Selection" means here
#  ------------------------------------
#  kube-scheduler places a Pod on a node in two ordered stages:
#     1. Filtering  — discard every node that CANNOT run the Pod.
#     2. Scoring    — rank the survivors and pick the best.
#  A Pod's `resources.requests` (cpu / memory) is the single most important
#  input to the Filtering stage: a node is only "feasible" if its *allocatable*
#  capacity minus what is already requested by other Pods still covers this
#  Pod's request. If NO node survives Filtering, the Pod stays Pending forever
#  and the scheduler emits a `FailedScheduling` event. That is exactly the
#  failure this lab reproduces, in a controlled and reversible way.
#
#  Sources
#    - KCA Curriculum (CNCF):
#      https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#    - Resource Management for Pods and Containers:
#      https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
#    - kube-scheduler (Filtering & Scoring):
#      https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/
#    - Node-pressure & scheduling of Pods:
#      https://kubernetes.io/docs/concepts/scheduling-eviction/
#
#  Safety
#    - All objects live in a dedicated namespace ("kca-lab-4-2").
#    - The workload is `registry.k8s.io/pause` — it consumes ~0 real CPU/RAM;
#      the break is purely a *request* the node cannot satisfy, so nothing on
#      the host is ever starved. Cleanup deletes the whole namespace.
#    - No host files, no kubelet flags, no node cordoning. Fully reversible.
#
#  Usage
#    ./4.2-resource-selection.sh break     # inject the fault (default)
#    ./4.2-resource-selection.sh status    # show current symptom
#    ./4.2-resource-selection.sh verify    # did the student fix it? pass/fail
#    ./4.2-resource-selection.sh solve     # apply the reference fix (spoiler)
#    ./4.2-resource-selection.sh clean     # remove everything
# ============================================================================

set -euo pipefail

NS="kca-lab-4-2"
DEPLOY="resource-selection-demo"
IMAGE="registry.k8s.io/pause:3.9"
# Deliberately impossible on any single lab VM (64 cores / 256Gi RAM requested).
BAD_CPU="64"
BAD_MEM="256Gi"
# A request that comfortably fits any node.
GOOD_CPU="100m"
GOOD_MEM="64Mi"

c_red=$'\033[0;31m'; c_grn=$'\033[0;32m'; c_yel=$'\033[1;33m'
c_cyn=$'\033[0;36m'; c_bld=$'\033[1m'; c_off=$'\033[0m'

log()  { printf '%s\n' "$*"; }
info() { printf '%s[INFO]%s %s\n'  "$c_cyn" "$c_off" "$*"; }
warn() { printf '%s[WARN]%s %s\n'  "$c_yel" "$c_off" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n'  "$c_grn" "$c_off" "$*"; }
die()  { printf '%s[FAIL]%s %s\n'  "$c_red" "$c_off" "$*" >&2; exit 1; }

require() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kubectl cluster-info >/dev/null 2>&1 || die "No reachable cluster (check KUBECONFIG / context)."
}

guard_context() {
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || echo '?')"
  warn "Current context: ${c_bld}${ctx}${c_off}"
  warn "This script intentionally breaks scheduling. Run it ONLY on a disposable lab cluster."
  if [[ "${ASSUME_YES:-0}" != "1" ]]; then
    printf 'Type the word LAB to continue: '
    local ans; read -r ans
    [[ "$ans" == "LAB" ]] || die "Aborted by user."
  fi
}

break_it() {
  require; guard_context
  info "Creating namespace '${NS}' and the broken Deployment '${DEPLOY}'..."
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # Idempotent: re-applying just re-sets the bad requests.
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
  namespace: ${NS}
  labels: { app: ${DEPLOY}, kca-topic: "4.2" }
spec:
  replicas: 3
  selector:
    matchLabels: { app: ${DEPLOY} }
  template:
    metadata:
      labels: { app: ${DEPLOY} }
    spec:
      containers:
        - name: pause
          image: ${IMAGE}
          resources:
            requests:
              cpu: "${BAD_CPU}"
              memory: "${BAD_MEM}"
            limits:
              cpu: "${BAD_CPU}"
              memory: "${BAD_MEM}"
YAML

  ok "Fault injected."
  cat <<EOF

${c_bld}=============================  YOUR MISSION  =============================${c_off}

  A Deployment named '${DEPLOY}' with ${c_bld}3 replicas${c_off} was created in
  namespace '${NS}'. None of its Pods will start.

  ${c_bld}SYMPTOM you will observe${c_off}
    \$ kubectl -n ${NS} get pods
    NAME                                   READY   STATUS    RESTARTS   AGE
    ${DEPLOY}-xxxxxxxxxx-aaaaa   0/1     ${c_red}Pending${c_off}   0          20s
    ${DEPLOY}-xxxxxxxxxx-bbbbb   0/1     ${c_red}Pending${c_off}   0          20s
    ${DEPLOY}-xxxxxxxxxx-ccccc   0/1     ${c_red}Pending${c_off}   0          20s

    \$ kubectl -n ${NS} describe pod <one-of-the-pods>
    ...
    Events:
      Type     Reason            From                Message
      ----     ------            ----                -------
      Warning  ${c_red}FailedScheduling${c_off}  default-scheduler   0/1 nodes are available:
               ${c_red}1 Insufficient cpu${c_off}, 1 Insufficient memory. preemption: 0/1 nodes
               are available: 1 No preemption victims found for incoming pod.

  ${c_bld}WHAT YOU MUST ACHIEVE${c_off}
    Make ${c_bld}all 3 replicas reach STATUS=Running (READY 1/1)${c_off} by correcting the
    Pod resource *selection* — i.e. the CPU/memory the scheduler is being asked
    to find. You may NOT add real 64-core nodes; fix the request instead.

  ${c_bld}HINTS (dig, don't guess)${c_off}
    - Inspect what the Pod is asking for:
        kubectl -n ${NS} get deploy ${DEPLOY} \\
          -o jsonpath='{.spec.template.spec.containers[0].resources.requests}{"\n"}'
    - Inspect what each node can actually offer:
        kubectl get nodes -o custom-columns=\\
NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory
    - The 'FailedScheduling' event tells you which resource dimension failed.

  When you think it is fixed, self-check with:
        ./$(basename "$0") verify

${c_bld}========================================================================${c_off}
EOF
}

status() {
  require
  info "Pods in '${NS}':"
  kubectl -n "$NS" get pods -o wide || true
  echo
  info "Requested resources on '${DEPLOY}':"
  kubectl -n "$NS" get deploy "$DEPLOY" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests}{"\n"}' 2>/dev/null || true
  echo
  info "Latest scheduling events:"
  kubectl -n "$NS" get events --field-selector reason=FailedScheduling \
    --sort-by=.lastTimestamp 2>/dev/null | tail -n 5 || true
}

verify() {
  require
  local desired ready
  desired="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  ready="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  ready="${ready:-0}"
  info "Ready replicas: ${ready}/${desired}"
  if [[ "$ready" == "$desired" && "$desired" != "0" ]]; then
    ok "PASS — every replica is scheduled and Running. Resource Selection understood."
    return 0
  fi
  warn "NOT FIXED YET — some Pods are still Pending. Re-read the FailedScheduling event."
  status
  return 1
}

solve() {
  require
  warn "Applying the reference fix (this is the spoiler)..."
  kubectl -n "$NS" set resources "deployment/${DEPLOY}" \
    --requests="cpu=${GOOD_CPU},memory=${GOOD_MEM}" \
    --limits="cpu=${GOOD_CPU},memory=${GOOD_MEM}"
  kubectl -n "$NS" rollout status "deployment/${DEPLOY}" --timeout=120s
  verify || true
}

clean() {
  require
  info "Deleting namespace '${NS}' and everything in it..."
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
  ok "Cleanup requested."
}

case "${1:-break}" in
  break)  break_it ;;
  status) status ;;
  verify) verify ;;
  solve)  solve ;;
  clean)  clean ;;
  *) die "Unknown command '${1}'. Use: break | status | verify | solve | clean" ;;
esac
