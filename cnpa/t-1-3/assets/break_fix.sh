#!/usr/bin/env bash
#
# =============================================================================
# CNPA — Certified Cloud Native Platform Engineering Associate (2025-04-01)
# Topic 1.3 — Application Environments and Infrastructure Architecture (7.2%)
#
# Break & Fix Lab: "The staging environment that could not scale"
#
# Scenario
# --------
# A platform team runs a single lab cluster hosting three application
# environments — dev, staging and prod — isolated by namespace. This is the
# canonical namespace-per-environment architecture: identical application
# manifests everywhere (environment parity), with per-environment guardrails
# expressed as cluster policy, not as copy-pasted app config:
#
#   * ResourceQuota  -> the capacity envelope of the environment (blast
#                       radius, cost attribution, bin-packing predictability)
#   * LimitRange     -> per-container defaults, so workloads that do not
#                       declare resources still admit cleanly under the quota
#   * ConfigMap      -> environment-specific runtime configuration
#
# Someone "tuned" staging by hand: the LimitRange was deleted and the
# ResourceQuota was replaced by one sized for a single smoke-test pod.
# Nothing crashed — quotas are enforced at ADMISSION time, so running pods
# survive — but the environment silently lost the ability to scale or roll
# out. That failure mode (healthy-looking but frozen) is exactly why this
# topic exists in the CNPA curriculum.
#
# Usage
# -----
#   ./break_fix.sh            provision the three environments, then break staging
#   ./break_fix.sh verify     check whether your fix meets the success criteria
#   ./break_fix.sh cleanup    delete every lab namespace (cnpa-13-*)
#
# Requirements
# ------------
#   * A DISPOSABLE lab VM with a running Kubernetes cluster
#     (kind, minikube, k3s/k3d, rancher-desktop or similar) and kubectl.
#   * Internet access to pull nginx:1.27-alpine.
#   * The script only creates/mutates/deletes namespaces prefixed "cnpa-13-".
#
# References
# ----------
#   * https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
#   * https://kubernetes.io/docs/concepts/policy/resource-quotas/
#   * https://kubernetes.io/docs/concepts/policy/limit-range/
#   * https://kubernetes.io/docs/concepts/security/multi-tenancy/
#   * https://kubernetes.io/docs/tasks/administer-cluster/manage-resources/quota-memory-cpu-namespace/
# =============================================================================

set -euo pipefail

LAB_PREFIX="cnpa-13"
NS_DEV="${LAB_PREFIX}-dev"
NS_STAGING="${LAB_PREFIX}-staging"
NS_PROD="${LAB_PREFIX}-prod"
APP="checkout"
STAGING_TARGET_REPLICAS=5

log()  { printf '\n\033[1;34m[lab]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[PASS]\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[lab:error]\033[0m %s\n' "$*" >&2; exit 1; }

preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kubectl get nodes >/dev/null 2>&1 || die "no reachable Kubernetes cluster (kubectl get nodes failed)."
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  case "$ctx" in
    *kind*|*k3d*|*k3s*|*minikube*|*docker-desktop*|*rancher-desktop*|*colima*) ;;
    *)
      if [ "${CNPA_LAB_FORCE:-0}" != "1" ]; then
        printf 'Current kube context is "%s", which does not look like a disposable lab cluster.\n' "$ctx"
        printf 'Type the context name to continue, or Ctrl-C to abort: '
        read -r answer
        [ "$answer" = "$ctx" ] || die "confirmation failed; aborting to protect a possibly real cluster."
      fi
      ;;
  esac
}

# provision_env <env> <replicas> <log_level> <pods> <req_cpu> <req_mem> <lim_cpu> <lim_mem>
provision_env() {
  local env="$1" replicas="$2" log_level="$3" pods="$4"
  local req_cpu="$5" req_mem="$6" lim_cpu="$7" lim_mem="$8"
  local ns="${LAB_PREFIX}-${env}"

  kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    environment: ${env}
    app.kubernetes.io/part-of: cnpa-13-lab
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: env-quota
  namespace: ${ns}
spec:
  hard:
    pods: "${pods}"
    requests.cpu: "${req_cpu}"
    requests.memory: ${req_mem}
    limits.cpu: "${lim_cpu}"
    limits.memory: ${lim_mem}
---
apiVersion: v1
kind: LimitRange
metadata:
  name: env-defaults
  namespace: ${ns}
spec:
  limits:
  - type: Container
    defaultRequest:
      cpu: 100m
      memory: 128Mi
    default:
      cpu: 250m
      memory: 256Mi
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: ${ns}
data:
  ENVIRONMENT: "${env}"
  LOG_LEVEL: "${log_level}"
  FEATURE_FLAGS_SOURCE: "configmap://${env}/flags"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}
  namespace: ${ns}
  labels:
    app.kubernetes.io/name: ${APP}
    app.kubernetes.io/part-of: cnpa-13-lab
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app.kubernetes.io/name: ${APP}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${APP}
    spec:
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
        envFrom:
        - configMapRef:
            name: app-config
        # Intentionally NO resources block: the environment's LimitRange
        # injects defaults at admission. This is the parity pattern —
        # the manifest is identical in every environment.
EOF
}

provision() {
  log "Provisioning three environments with identical app manifests and per-environment guardrails..."
  #             env      repl loglevel pods req_cpu req_mem lim_cpu lim_mem
  provision_env dev      1    debug    5    500m    512Mi   "1"     1Gi
  provision_env staging  2    info     10   "2"     2Gi     "4"     4Gi
  provision_env prod     3    warn     20   "4"     4Gi     "8"     8Gi

  log "Waiting for the three '${APP}' Deployments to become available..."
  kubectl -n "$NS_DEV"     rollout status "deploy/${APP}" --timeout=180s
  kubectl -n "$NS_STAGING" rollout status "deploy/${APP}" --timeout=180s
  kubectl -n "$NS_PROD"    rollout status "deploy/${APP}" --timeout=180s
  log "Baseline healthy. Note: same Deployment YAML everywhere; only quota, LimitRange sizing and ConfigMap differ."
}

break_staging() {
  log "Sabotaging the staging environment (this is the controlled break)..."

  # 1. Remove the guardrail that injects default resource requests/limits.
  kubectl -n "$NS_STAGING" delete limitrange env-defaults --ignore-not-found

  # 2. Replace the quota with one sized for a single smoke-test pod.
  #    Existing pods are NOT evicted: quota is admission-time enforcement only.
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: env-quota
  namespace: ${NS_STAGING}
spec:
  hard:
    pods: "2"
    requests.cpu: 200m
    requests.memory: 256Mi
    limits.cpu: 300m
    limits.memory: 384Mi
EOF

  # 3. Simulate normal platform activity: a scale-up for load testing plus a
  #    routine rollout. Both will freeze against the sabotaged guardrails.
  kubectl -n "$NS_STAGING" scale "deploy/${APP}" --replicas="${STAGING_TARGET_REPLICAS}"
  kubectl -n "$NS_STAGING" rollout restart "deploy/${APP}"

  sleep 8
  log "Current state of ${NS_STAGING}:"
  kubectl -n "$NS_STAGING" get deploy,rs,pods
  echo
  kubectl -n "$NS_STAGING" get events --field-selector reason=FailedCreate \
    --sort-by=.lastTimestamp 2>/dev/null | tail -n 4 || true
}

briefing() {
  cat <<'EOF'

=============================================================================
 YOUR MISSION
=============================================================================

 THE SYMPTOM you will observe
 ----------------------------
 The staging Deployment looks "green-ish" but is frozen. Nothing is
 crashing, no pod is in Error state — and yet nothing new can be created:

   $ kubectl -n cnpa-13-staging get deploy checkout
   NAME       READY   UP-TO-DATE   AVAILABLE   AGE
   checkout   2/5     0            2           6m

   $ kubectl -n cnpa-13-staging describe deploy checkout | grep -A4 'Conditions:'
   Conditions:
     Type             Status  Reason
     ----             ------  ------
     Available        True    MinimumReplicasAvailable
     ReplicaFailure   True    FailedCreate

   $ kubectl -n cnpa-13-staging get events --field-selector reason=FailedCreate | tail
   ... Error creating: pods "checkout-..." is forbidden: failed quota:
       env-quota: must specify limits.cpu for: web; limits.memory for: web;
       requests.cpu for: web; requests.memory for: web
   ... Error creating: pods "checkout-..." is forbidden: exceeded quota:
       env-quota, requested: pods=1, used: pods=2, limited: pods=2

 Two distinct environment-architecture failures are stacked here:
   1. The LimitRange is gone, so pods without an explicit resources block
      can no longer be admitted into a namespace whose quota constrains
      cpu/memory ("must specify limits.cpu ...").
   2. The ResourceQuota was shrunk below what the environment needs
      ("exceeded quota ... limited: pods=2").
 Meanwhile dev and prod are untouched — the whole point of namespace-based
 environment isolation is that the blast radius stopped at staging.

 WHAT YOU MUST ACHIEVE (success criteria)
 ----------------------------------------
   1. deploy/checkout in cnpa-13-staging reaches 5/5 READY on a fresh
      ReplicaSet (a rollout completes).
   2. The namespace has a LimitRange again, so the unchanged application
      manifest (no resources block) still admits with sane defaults.
   3. The namespace STILL has a ResourceQuota named env-quota, right-sized
      for staging WITH HEADROOM (at least one extra pod must fit). Deleting
      the quota is not a fix — it removes the environment's isolation.
   4. Do NOT edit the Deployment or the pods. The application manifest is
      correct; the environment's guardrails are what you must repair.

 Check yourself with:  ./break_fix.sh verify
 Stuck? The step-by-step solution is commented at the end of this script.
=============================================================================
EOF
}

verify() {
  local fail=0 ready hard_pods probe_cpu

  if kubectl -n "$NS_STAGING" get limitrange env-defaults >/dev/null 2>&1 \
     || [ "$(kubectl -n "$NS_STAGING" get limitrange -o name 2>/dev/null | wc -l)" -gt 0 ]; then
    ok "A LimitRange exists in ${NS_STAGING}."
  else
    bad "No LimitRange in ${NS_STAGING} — the defaulting guardrail is still missing."; fail=1
  fi

  if kubectl -n "$NS_STAGING" get quota env-quota >/dev/null 2>&1; then
    hard_pods="$(kubectl -n "$NS_STAGING" get quota env-quota -o jsonpath='{.spec.hard.pods}' 2>/dev/null || true)"
    if [ "${hard_pods:-0}" -gt "$STAGING_TARGET_REPLICAS" ] 2>/dev/null; then
      ok "ResourceQuota env-quota present with pod headroom (pods hard limit: ${hard_pods})."
    else
      bad "env-quota exists but pods hard limit (${hard_pods:-unset}) leaves no headroom over ${STAGING_TARGET_REPLICAS} replicas."; fail=1
    fi
  else
    bad "ResourceQuota env-quota is missing — deleting the quota is not an accepted fix."; fail=1
  fi

  ready="$(kubectl -n "$NS_STAGING" get "deploy/${APP}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  if [ "${ready:-0}" -eq "$STAGING_TARGET_REPLICAS" ] 2>/dev/null \
     && kubectl -n "$NS_STAGING" rollout status "deploy/${APP}" --timeout=15s >/dev/null 2>&1; then
    ok "deploy/${APP} is ${ready}/${STAGING_TARGET_REPLICAS} READY and the rollout is complete."
  else
    bad "deploy/${APP} is ${ready:-0}/${STAGING_TARGET_REPLICAS} READY or the rollout has not completed."; fail=1
  fi

  # Server-side dry-run exercises the real admission chain (LimitRange
  # defaulting + quota evaluation) without persisting anything.
  probe_cpu="$(kubectl -n "$NS_STAGING" run cnpa13-probe --image=nginx:1.27-alpine \
      --restart=Never --dry-run=server -o jsonpath='{.spec.containers[0].resources.requests.cpu}' 2>/dev/null || true)"
  if [ -n "$probe_cpu" ]; then
    ok "Admission probe: a resource-less pod is admitted and defaulted (requests.cpu=${probe_cpu})."
  else
    bad "Admission probe failed: a pod with no resources block is still rejected (or gets no defaults)."; fail=1
  fi

  echo
  if [ "$fail" -eq 0 ]; then
    ok "All checks passed. Staging is a functioning environment again — guardrails included."
  else
    bad "Not fixed yet. Re-read the FailedCreate events and the quota/LimitRange state."
    exit 1
  fi
}

cleanup() {
  log "Deleting lab namespaces ${NS_DEV}, ${NS_STAGING}, ${NS_PROD}..."
  kubectl delete namespace "$NS_DEV" "$NS_STAGING" "$NS_PROD" --ignore-not-found
  log "Cleanup done."
}

usage() {
  cat <<EOF
Usage: $0 [run|verify|cleanup]
  run      (default) provision dev/staging/prod and break staging
  verify   check whether your fix meets the success criteria
  cleanup  delete all cnpa-13-* namespaces
EOF
}

case "${1:-run}" in
  run)     preflight; provision; break_staging; briefing ;;
  verify)  preflight; verify ;;
  cleanup) preflight; cleanup ;;
  *)       usage; exit 1 ;;
esac

exit 0
