#!/usr/bin/env bash
#
# =============================================================================
#  teach-plat :: CNPA (Cloud Native Platform Associate) — exam 2025-04-01
#  Domain 2.3  Policy Engines for Platform Governance   (exam weight: 4.0)
#  Lab type:   BREAK & FIX   —   run ONLY on a disposable lab VM / throwaway
#              Kubernetes cluster (kind, k3s, minikube). NEVER on production.
# =============================================================================
#
#  What this scenario teaches
#  --------------------------
#  A policy engine (Kyverno, OPA/Gatekeeper, or the built-in
#  ValidatingAdmissionPolicy) enforces governance by inserting itself into the
#  Kubernetes admission path through a ValidatingWebhookConfiguration. That
#  makes the policy engine a hard dependency of *every write* to the API for
#  the resources it matches. The single most common self-inflicted platform
#  outage caused by a policy engine is a webhook that "fails closed"
#  (failurePolicy: Fail) while its backend is unreachable: the API server can
#  no longer get an admission verdict, so it denies the request. Governance
#  meant to protect the platform ends up blocking it.
#
#  This lab reproduces exactly that failure mode, but with the blast radius
#  fenced to one labelled lab namespace via namespaceSelector — so kube-system
#  and everything else keep working while you diagnose.
#
#  Reference sources (official)
#  ----------------------------
#   - CNPA curriculum:
#       https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
#   - Kubernetes — Dynamic Admission Control (webhooks, failurePolicy):
#       https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
#   - Kubernetes — Validating Admission Policy (CEL, in-tree, no webhook):
#       https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
#   - Kyverno documentation:
#       https://kyverno.io/docs/
#   - OPA Gatekeeper documentation:
#       https://open-policy-agent.github.io/gatekeeper/website/docs/
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# --- Configuration -----------------------------------------------------------
NS="cnpa-lab-23"
NS_LABEL_KEY="cnpa-lab"
NS_LABEL_VAL="governance"
WEBHOOK="cnpa-governance-guard"          # the ValidatingWebhookConfiguration
DEMO="governance-demo"                   # the workload the student watches fail
DEMO_IMAGE="registry.k8s.io/pause:3.9"   # tiny, no network needed
ASSUME_YES="${FORCE:-0}"

# --- Pretty output (degrade gracefully when stdout is not a TTY) --------------
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'
  BLU=$'\033[34m'; CYN=$'\033[36m'; RST=$'\033[0m'
else
  BOLD=""; RED=""; GRN=""; YLW=""; BLU=""; CYN=""; RST=""
fi
say()  { printf '%s\n' "$*"; }
head() { printf '\n%s== %s ==%s\n' "$BOLD" "$*" "$RST"; }
ok()   { printf '%s[ ok ]%s %s\n'   "$GRN" "$RST" "$*"; }
warn() { printf '%s[warn]%s %s\n'   "$YLW" "$RST" "$*"; }
die()  { printf '%s[fail]%s %s\n'   "$RED" "$RST" "$*" >&2; exit 1; }

# --- Preflight ---------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kubectl version >/dev/null 2>&1 \
    || die "Cannot reach a Kubernetes API server. Start your lab cluster first."
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || echo '<none>')"
  head "Preflight"
  say "Current kube context : ${BOLD}${ctx}${RST}"
  say "Lab namespace        : ${BOLD}${NS}${RST}"
  if [[ "$ASSUME_YES" != "1" ]]; then
    printf '%sThis will modify the cluster above. Continue? [y/N] %s' "$YLW" "$RST"
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]] || die "Aborted by user. (Set FORCE=1 to skip this prompt.)"
  fi
}

# --- The break ---------------------------------------------------------------
do_break() {
  head "Preparing the lab namespace"
  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    ${NS_LABEL_KEY}: ${NS_LABEL_VAL}
YAML
  ok "Namespace ${NS} present and labelled ${NS_LABEL_KEY}=${NS_LABEL_VAL}."

  head "Installing the (deliberately broken) governance webhook"
  # A ValidatingWebhookConfiguration that intercepts every Pod CREATE in the
  # lab namespace and routes the admission review to a policy-engine Service
  # that does not exist. Because failurePolicy is Fail, an unreachable backend
  # means every Pod creation is DENIED. namespaceSelector fences the damage to
  # this one namespace, so the rest of the cluster is untouched.
  kubectl apply -f - >/dev/null <<YAML
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: ${WEBHOOK}
  labels:
    app.kubernetes.io/part-of: ${NS}
webhooks:
  - name: pods.cnpa-governance-guard.example.com
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Fail          # <-- fail CLOSED: no verdict => deny
    matchPolicy: Equivalent
    timeoutSeconds: 5
    namespaceSelector:
      matchLabels:
        ${NS_LABEL_KEY}: ${NS_LABEL_VAL}
    rules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        resources:   ["pods"]
        operations:  ["CREATE"]
        scope: Namespaced
    clientConfig:
      service:
        name: policy-engine-nonexistent   # <-- this Service is never created
        namespace: ${NS}
        path: /validate
        port: 443
YAML
  ok "ValidatingWebhookConfiguration/${WEBHOOK} installed (backend is unreachable)."

  head "Deploying the demo workload the student must recover"
  kubectl apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEMO}
  namespace: ${NS}
  labels:
    app: ${DEMO}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${DEMO}
  template:
    metadata:
      labels:
        app: ${DEMO}
    spec:
      containers:
        - name: app
          image: ${DEMO_IMAGE}
YAML
  ok "Deployment/${DEMO} created. Its ReplicaSet will now fail to create Pods."
  sleep 3
}

# --- Student briefing --------------------------------------------------------
briefing() {
  head "SCENARIO — what just happened"
  cat <<TXT
A platform-governance policy engine is now enforcing admission in namespace
'${NS}'. A workload was scheduled, but it will never come up.

${BOLD}Symptom you will observe${RST}
  * The Deployment applies fine, yet stays at 0 ready replicas forever:

      $ kubectl -n ${NS} get deploy ${DEMO}
      NAME              READY   UP-TO-DATE   AVAILABLE   AGE
      ${DEMO}   0/1     0            0           30s

  * No Pods ever appear; the ReplicaSet records repeated FailedCreate events:

      $ kubectl -n ${NS} describe rs -l app=${DEMO} | tail -n 5
      Warning  FailedCreate  ...  Error creating: Internal error occurred:
        failed calling webhook "pods.cnpa-governance-guard.example.com":
        failed to call webhook: Post "https://policy-engine-nonexistent.${NS}.svc:443/validate?timeout=5s":
        service "policy-engine-nonexistent" not found

  * Trying to create a Pod by hand fails the same way (note it hangs ~5s first):

      $ kubectl -n ${NS} run probe --image=${DEMO_IMAGE} --restart=Never
      Error from server (InternalError): Internal error occurred:
        failed calling webhook "pods.cnpa-governance-guard.example.com": ...

  * ${BOLD}Already-running Pods elsewhere are unaffected${RST} — the webhook only
    fires on CREATE, and only in this labelled namespace.

${BOLD}Your goal${RST}
  Restore the ability to run workloads in '${NS}' AND be able to explain, in
  production terms, the root cause and the trade-off behind the fix you choose.
  You are NOT asked to install a real policy engine; you are asked to make the
  governance webhook safe or to remove the broken configuration deliberately.

${BOLD}Suggested first moves (diagnosis, no fix yet)${RST}
  kubectl -n ${NS} get deploy,rs,pods
  kubectl -n ${NS} describe rs -l app=${DEMO}
  kubectl get validatingwebhookconfigurations
  kubectl get validatingwebhookconfiguration ${WEBHOOK} -o yaml

${BOLD}Check your work at any time (non-destructive, server-side dry-run)${RST}
  $0 verify

When you are completely finished, tear the lab down with:
  $0 reset
TXT
}

# --- Verification (server dry-run triggers the webhook without leaving a Pod) -
verify() {
  head "Verifying whether workloads can be admitted in ${NS}"
  if kubectl -n "$NS" run cnpa-verify --image="$DEMO_IMAGE" --restart=Never \
       --dry-run=server -o name >/dev/null 2>&1; then
    ok "Pod admission SUCCEEDS — the governance webhook no longer blocks CREATE."
    say "Confirm the demo recovered:  kubectl -n ${NS} rollout status deploy/${DEMO}"
    return 0
  else
    warn "Pod admission is STILL BLOCKED. The broken webhook is still in the path."
    say  "Inspect it with:  kubectl get validatingwebhookconfiguration ${WEBHOOK} -o yaml"
    return 1
  fi
}

# --- Full teardown -----------------------------------------------------------
reset() {
  head "Tearing down the lab"
  kubectl delete validatingwebhookconfiguration "$WEBHOOK" --ignore-not-found >/dev/null
  kubectl delete namespace "$NS" --ignore-not-found >/dev/null
  ok "Removed webhook/${WEBHOOK} and namespace/${NS}."
}

usage() {
  cat <<TXT
Usage: $0 [break|verify|reset]
  break   (default) install the broken governance webhook and demo workload
  verify  non-destructively test whether Pod admission works again
  reset   remove the webhook and the lab namespace (full cleanup)
Env:
  FORCE=1  skip the interactive confirmation prompt
TXT
}

main() {
  case "${1:-break}" in
    break)  preflight; do_break; briefing ;;
    verify) verify ;;
    reset)  reset ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}
main "$@"
