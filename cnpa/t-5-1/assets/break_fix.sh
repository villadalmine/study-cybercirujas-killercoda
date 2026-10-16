#!/usr/bin/env bash
#
# =============================================================================
# CNPA 5.1 — Simplified Access to Platform Capabilities for Developers
# Break & Fix laboratory  (exam version 2025-04-01, weight 2.0)
# -----------------------------------------------------------------------------
# Reference: CNCF CNPA Curriculum
#   https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
#
# WHAT THIS TOPIC IS ABOUT
#   A platform team exposes complex infrastructure through a *simplified*,
#   golden-path abstraction so that application developers never touch raw
#   Deployments/Services/Ingress/RBAC. Two things must be true for that
#   self-service promise to hold:
#     1. The abstraction exists            -> a namespaced CustomResourceDefinition
#                                             (here: kind WebService) that lets a
#                                             developer declare image+port+replicas
#                                             and nothing else.
#     2. Developers are ALLOWED to use it  -> a Role/RoleBinding grants the
#                                             developer identity the verbs on the
#                                             abstraction's resource.
#   If (2) is subtly wrong, the platform is "up" from the admin's point of view
#   but completely unusable for developers. That is the failure this lab injects.
#
# SAFETY
#   * Everything is created inside a single throwaway namespace and one clearly
#     named CRD. `cleanup` removes both. No cluster-wide or host changes.
#   * The script refuses to run against a context that does not look like a
#     local/disposable cluster unless you export LAB_CONFIRM=1.
#   * Run this ONLY on a disposable lab VM cluster (kind / minikube / k3s).
# =============================================================================

set -euo pipefail

# ---- lab constants ----------------------------------------------------------
NS="cnpa-51-selfservice"
CRD_GROUP="platform.cnpa.local"
CRD_PLURAL="webservices"
CRD_KIND="WebService"
CRD_NAME="${CRD_PLURAL}.${CRD_GROUP}"
DEV_SA="developer"
ROLE="webservice-editor"
BINDING="developer-webservice"
DEV_USER="system:serviceaccount:${NS}:${DEV_SA}"

# ---- pretty output ----------------------------------------------------------
c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'
c_ylw=$'\033[33m'; c_cya=$'\033[36m'; c_bold=$'\033[1m'
say()  { printf '%s\n' "$*"; }
info() { printf '%s[i]%s %s\n' "$c_cya" "$c_reset" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_grn" "$c_reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_ylw" "$c_reset" "$*"; }
err()  { printf '%s[x]%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
rule() { printf '%s\n' "-------------------------------------------------------------------------------"; }

# ---- preflight --------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || { err "kubectl not found in PATH."; exit 1; }
  if ! kubectl cluster-info >/dev/null 2>&1; then
    err "No reachable Kubernetes cluster. Start a disposable one, e.g.:"
    err "    kind create cluster --name cnpa-lab"
    exit 1
  fi
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  case "$ctx" in
    kind-*|minikube|k3d-*|k3s*|docker-desktop|*lab*|*local*) : ;;
    *)
      if [ "${LAB_CONFIRM:-0}" != "1" ]; then
        err "Current context '${ctx}' does not look like a disposable lab cluster."
        err "This lab mutates RBAC and installs a CRD. Refusing to continue."
        err "If you are SURE this cluster is throwaway, re-run with LAB_CONFIRM=1."
        exit 1
      fi
      warn "Proceeding on non-lab-looking context '${ctx}' because LAB_CONFIRM=1." ;;
  esac
  # Impersonation is needed to act as the developer identity.
  if ! kubectl auth can-i impersonate serviceaccounts >/dev/null 2>&1; then
    warn "Your kubeconfig may not be allowed to impersonate service accounts."
    warn "The developer-perspective demo still fails the same way for real devs."
  fi
  info "Cluster context: ${ctx}"
}

# ---- the developer-facing abstraction (the 'golden path' CRD) ---------------
install_crd() {
  info "Installing the developer abstraction: CRD '${CRD_NAME}' (kind ${CRD_KIND})."
  kubectl apply -f - >/dev/null <<EOF
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ${CRD_NAME}
spec:
  group: ${CRD_GROUP}
  scope: Namespaced
  names:
    kind: ${CRD_KIND}
    plural: ${CRD_PLURAL}
    singular: webservice
    shortNames: ["ws"]
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          required: ["spec"]
          properties:
            spec:
              type: object
              required: ["image", "port"]
              properties:
                image:
                  type: string
                  description: "Container image the developer wants to ship."
                port:
                  type: integer
                  minimum: 1
                  maximum: 65535
                replicas:
                  type: integer
                  default: 1
                  minimum: 0
                  maximum: 10
      additionalPrinterColumns:
        - name: Image
          type: string
          jsonPath: .spec.image
        - name: Port
          type: integer
          jsonPath: .spec.port
EOF
  kubectl wait --for=condition=Established "crd/${CRD_NAME}" --timeout=60s >/dev/null
  ok "Abstraction ready. Developers are meant to create '${CRD_KIND}' objects only."
}

# ---- the self-service access wiring, WITH the injected defect ----------------
install_rbac_broken() {
  info "Creating namespace, developer ServiceAccount and self-service RBAC."
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$NS" create serviceaccount "$DEV_SA" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # -------------------------------------------------------------------------
  # BROKEN ON PURPOSE.
  # RBAC 'resources' must be the CRD's *plural* name ("webservices").
  # A platform engineer here wrote the *singular* ("webservice"), which RBAC
  # treats as a resource that simply does not exist. The Role therefore grants
  # nothing on the real WebService resource.
  # -------------------------------------------------------------------------
  kubectl apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: ${NS}
  name: ${ROLE}
rules:
  - apiGroups: ["${CRD_GROUP}"]
    resources: ["webservice"]          # <-- DEFECT: singular; must be "${CRD_PLURAL}"
    verbs: ["get","list","watch","create","update","patch","delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: ${NS}
  name: ${BINDING}
subjects:
  - kind: ServiceAccount
    name: ${DEV_SA}
    namespace: ${NS}
roleRef:
  kind: Role
  name: ${ROLE}
  apiGroup: rbac.authorization.k8s.io
EOF
  ok "Self-service RBAC applied (Role '${ROLE}', RoleBinding '${BINDING}')."
}

# ---- reproduce what the developer experiences -------------------------------
sample_manifest() {
  cat <<EOF
apiVersion: ${CRD_GROUP}/v1alpha1
kind: ${CRD_KIND}
metadata:
  name: checkout
  namespace: ${NS}
spec:
  image: ghcr.io/acme/checkout:1.4.2
  port: 8080
  replicas: 2
EOF
}

show_symptom() {
  rule
  say "${c_bold}DEVELOPER PERSPECTIVE${c_reset} — acting as '${DEV_USER}'"
  rule

  info "1) Ask the API server whether the developer may create a WebService:"
  local ans
  ans="$(kubectl auth can-i create "${CRD_PLURAL}" \
           --as="${DEV_USER}" -n "${NS}" 2>/dev/null || true)"
  printf '    $ kubectl auth can-i create %s --as=%s -n %s\n' "${CRD_PLURAL}" "${DEV_USER}" "${NS}"
  printf '    %s%s%s\n\n' "$c_red" "${ans:-no}" "$c_reset"

  info "2) The developer tries to ship through the golden path:"
  printf '    $ kubectl apply --as=%s -f webservice.yaml\n' "${DEV_USER}"
  set +e
  local out
  out="$(sample_manifest | kubectl apply -n "${NS}" --as="${DEV_USER}" -f - 2>&1)"
  set -e
  printf '%s%s%s\n' "$c_red" "$(printf '%s\n' "$out" | sed 's/^/    /')" "$c_reset"
  rule
}

print_mission() {
  cat <<EOF

${c_bold}=== SYMPTOM ===${c_reset}
The platform admin sees a healthy cluster and a healthy CRD, but every
developer is blocked. Acting as the developer identity:

    kubectl auth can-i create ${CRD_PLURAL} --as=${DEV_USER} -n ${NS}
    -> no

    kubectl apply --as=${DEV_USER} -f webservice.yaml
    -> Error from server (Forbidden): webservices.${CRD_GROUP} is forbidden:
       User "${DEV_USER}" cannot create resource "${CRD_PLURAL}" in API group
       "${CRD_GROUP}" in the namespace "${NS}"

There IS a Role and there IS a RoleBinding for the developer, and they clearly
mention this API group. Yet access is denied. The self-service platform is
effectively down for developers even though nothing looks broken to the admin.

${c_bold}=== YOUR MISSION ===${c_reset}
Restore developer self-service WITHOUT granting broad or cluster-wide
permissions. Success criteria — all three must pass:

  (a) kubectl auth can-i create ${CRD_PLURAL} --as=${DEV_USER} -n ${NS}   -> yes
  (b) The developer can 'kubectl apply' the WebService manifest above.
  (c) kubectl -n ${NS} get ${CRD_PLURAL} lists the created object.

Constraints:
  * Keep it namespace-scoped (a Role, not a ClusterRole).
  * Do not bind the developer to admin/edit or any wildcard resource.
  * Change only what is actually wrong.

Hints:
  * "The Role exists and names the right group" is not the same as
    "the Role grants the right resource".
  * RBAC matches on the resource name exactly as the API exposes it.
    Where does that exact name come from for a CRD?

When you think it is fixed, run:   $0 verify
To inspect the current wiring:     $0 inspect
To tear everything down:           $0 cleanup

EOF
}

# ---- helpers for the student ------------------------------------------------
inspect() {
  rule; info "RoleBinding '${BINDING}':"
  kubectl -n "$NS" get rolebinding "$BINDING" -o yaml 2>/dev/null || warn "not found"
  rule; info "Role '${ROLE}':"
  kubectl -n "$NS" get role "$ROLE" -o yaml 2>/dev/null || warn "not found"
  rule; info "Authoritative resource name published by the CRD:"
  printf '    spec.names.plural = %s%s%s\n' \
    "$c_grn" "$(kubectl get crd "$CRD_NAME" -o jsonpath='{.spec.names.plural}' 2>/dev/null)" "$c_reset"
  rule
}

verify() {
  local pass=0
  info "(a) auth can-i create ${CRD_PLURAL} as developer ..."
  if [ "$(kubectl auth can-i create "${CRD_PLURAL}" --as="${DEV_USER}" -n "${NS}" 2>/dev/null)" = "yes" ]; then
    ok "    yes"; else err "    no"; pass=1; fi

  info "(b) developer can apply a WebService ..."
  if sample_manifest | kubectl apply -n "${NS}" --as="${DEV_USER}" -f - >/dev/null 2>&1; then
    ok "    applied"; else err "    still forbidden"; pass=1; fi

  info "(c) object is listable ..."
  if kubectl -n "${NS}" get "${CRD_PLURAL}" checkout >/dev/null 2>&1; then
    ok "    $(kubectl -n "${NS}" get "${CRD_PLURAL}" --no-headers 2>/dev/null | wc -l | tr -d ' ') WebService(s) present"
  else err "    none listable"; pass=1; fi

  rule
  if [ "$pass" -eq 0 ]; then
    ok "${c_bold}LAB PASSED — developer self-service restored.${c_reset}"
  else
    err "${c_bold}Not fixed yet.${c_reset} Run '$0 inspect' and compare the Role's"
    err "resources[] against the CRD's spec.names.plural."
  fi
  return "$pass"
}

# ---- optional auto-solver (for checking your answer) ------------------------
solve() {
  warn "Applying the reference fix (namespace-scoped, minimal change)."
  kubectl -n "$NS" patch role "$ROLE" --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/rules/0/resources\",\"value\":[\"${CRD_PLURAL}\"]}]" >/dev/null
  ok "Role '${ROLE}' now grants verbs on '${CRD_PLURAL}'."
  verify || true
}

# ---- lifecycle --------------------------------------------------------------
setup() {
  preflight
  install_crd
  install_rbac_broken
  show_symptom
  print_mission
}

cleanup() {
  info "Removing lab resources ..."
  kubectl delete namespace "$NS" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete crd "$CRD_NAME" --ignore-not-found >/dev/null 2>&1 || true
  ok "Lab cleaned up."
}

usage() {
  cat <<EOF
CNPA 5.1 Break & Fix — Simplified Access to Platform Capabilities for Developers

Usage: $0 [command]

  (no args) | setup   Install the abstraction + broken self-service and show the task
  inspect             Dump the RoleBinding, Role and the CRD's authoritative names
  verify              Check the three success criteria
  solve               Apply the reference fix (use only to check your answer)
  cleanup             Delete the namespace and the CRD
  help                Show this help

Guard: refuses non-lab contexts unless LAB_CONFIRM=1 is exported.
EOF
}

main() {
  case "${1:-setup}" in
    setup|"")  setup ;;
    inspect)   inspect ;;
    verify)    preflight; verify ;;
    solve)     preflight; solve ;;
    cleanup)   cleanup ;;
    help|-h|--help) usage ;;
    *) err "Unknown command: $1"; usage; exit 2 ;;
  esac
}

main "$@"
