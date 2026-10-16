#!/usr/bin/env bash
# =============================================================================
# CKNE 1.4 - Troubleshooting Pod Connectivity (DNS, pod-to-pod)
# BREAK & FIX LAB
#
# Scope and safety
#   - Every object this script creates lives in ONE dedicated namespace
#     (ckne-bf-14), labelled as owned by this lab. The script never modifies
#     CoreDNS, kube-proxy, the CNI, or anything in kube-system.
#   - "cleanup" deletes the namespace ONLY if it carries the lab's label.
#   - Use a disposable lab cluster (kubeadm, kind, k3s, minikube). You need
#     kubectl access with permission to create namespaces.
#
# Usage
#   ./ckne-1.4-break-fix.sh break   [--yes]   # deploy the broken scenario
#   ./ckne-1.4-break-fix.sh check             # grade your fix (PASS/FAIL)
#   ./ckne-1.4-break-fix.sh hint              # one nudge per fault
#   ./ckne-1.4-break-fix.sh cleanup [--yes]   # remove everything
#
# Reference material
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
#   https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
#   https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
#   https://kubernetes.io/docs/concepts/services-networking/network-policies/
# =============================================================================
set -euo pipefail

NS="ckne-bf-14"
LAB_LABEL_KEY="lab.teach-plat/owner"
LAB_LABEL_VAL="ckne-1.4-break-fix"
BACKEND_IMAGE="registry.k8s.io/e2e-test-images/agnhost:2.47"
CLIENT_IMAGE="busybox:1.36.1"
TIMEOUT="180s"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
[[ -t 1 ]] || { RED=""; GRN=""; YLW=""; BLD=""; RST=""; }

info()  { printf '%s[INFO]%s %s\n'  "$BLD" "$RST" "$*"; }
warn()  { printf '%s[WARN]%s %s\n'  "$YLW" "$RST" "$*"; }
die()   { printf '%s[ERROR]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }
pass()  { printf '  %s[PASS]%s %s\n' "$GRN" "$RST" "$*"; PASSES=$((PASSES+1)); }
fail()  { printf '  %s[FAIL]%s %s\n' "$RED" "$RST" "$*"; FAILS=$((FAILS+1)); }
skip()  { printf '  %s[SKIP]%s %s\n' "$YLW" "$RST" "$*"; }

ASSUME_YES="false"
for arg in "$@"; do [[ "$arg" == "--yes" ]] && ASSUME_YES="true"; done

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kubectl version --request-timeout=5s >/dev/null 2>&1 \
    || die "Cannot reach the API server. Check your kubeconfig / cluster."
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo '<none>')"
  info "Current kubectl context: ${BLD}${ctx}${RST}"
}

confirm() {
  [[ "$ASSUME_YES" == "true" ]] && return 0
  read -r -p "$1 [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted by user."
}

# Does the CNI enforce NetworkPolicy? (flannel alone and kindnet < 1.30 do not.)
netpol_enforced() {
  kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null \
    | grep -Eq '(calico|cilium|antrea|kube-router|weave-net|canal)'
}

ns_is_ours() {
  [[ "$(kubectl get ns "$NS" -o jsonpath="{.metadata.labels.lab\.teach-plat/owner}" 2>/dev/null || true)" \
      == "$LAB_LABEL_VAL" ]]
}

# -----------------------------------------------------------------------------
# BREAK
# -----------------------------------------------------------------------------
do_break() {
  preflight
  if kubectl get ns "$NS" >/dev/null 2>&1; then
    ns_is_ours || die "Namespace $NS exists but is NOT owned by this lab. Refusing to touch it."
    warn "Namespace $NS already exists (from a previous run). It will be re-applied."
  fi
  confirm "Create the broken scenario in namespace '$NS' on this cluster?"

  info "Creating namespace and workloads..."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    ${LAB_LABEL_KEY}: ${LAB_LABEL_VAL}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: ${NS}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
        tier: api
    spec:
      containers:
        - name: netexec
          image: ${BACKEND_IMAGE}
          args: ["netexec", "--http-port=8080"]
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          readinessProbe:
            tcpSocket:
              port: 8080
            periodSeconds: 5
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: ${NS}
spec:
  type: ClusterIP
  selector:
    app: backend
    tier: backend
  ports:
    - name: http
      port: 80
      targetPort: 8081
      protocol: TCP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: client
  template:
    metadata:
      labels:
        app: client
        access: allowed
    spec:
      dnsPolicy: Default
      terminationGracePeriodSeconds: 1
      containers:
        - name: shell
          image: ${CLIENT_IMAGE}
          command: ["sh", "-c", "sleep 360000"]
          resources:
            requests:
              cpu: 5m
              memory: 8Mi
            limits:
              memory: 32Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: intruder
  namespace: ${NS}
  labels:
    app: intruder
spec:
  terminationGracePeriodSeconds: 1
  containers:
    - name: shell
      image: ${CLIENT_IMAGE}
      command: ["sh", "-c", "sleep 360000"]
      resources:
        requests:
          cpu: 5m
          memory: 8Mi
        limits:
          memory: 32Mi
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-allow-granted-clients
  namespace: ${NS}
  annotations:
    lab.teach-plat/owned-by: "security-team - DO NOT MODIFY"
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              access: granted
      ports:
        - protocol: TCP
          port: 8080
EOF

  info "Waiting for pods to become ready..."
  kubectl -n "$NS" rollout status deploy/backend --timeout="$TIMEOUT"
  kubectl -n "$NS" rollout status deploy/client  --timeout="$TIMEOUT"
  kubectl -n "$NS" wait --for=condition=Ready pod/intruder --timeout="$TIMEOUT"

  if netpol_enforced; then
    info "Detected a CNI that enforces NetworkPolicy: all 3 faults are live."
  else
    warn "No NetworkPolicy-enforcing CNI detected (Calico/Cilium/Antrea/kube-router)."
    warn "Fault #3 (NetworkPolicy) will NOT be observable; 'check' will skip it."
  fi

  cat <<EOF

${BLD}=============================================================================
 SCENARIO: "The client can't talk to the backend"
=============================================================================${RST}
The application team reports that the pod in Deployment ${BLD}client${RST}
(namespace ${BLD}${NS}${RST}) cannot reach the ${BLD}backend${RST} Service.
Their ticket says: "DNS is broken and the network is broken. Fix Kubernetes."

${BLD}What you will observe${RST}
  kubectl -n ${NS} exec deploy/client -- nslookup backend.${NS}.svc.cluster.local
    -> NXDOMAIN / "can't find", answered by a server that is NOT kube-dns
  kubectl -n ${NS} exec deploy/client -- wget -T 3 -qO- http://backend/hostname
    -> "bad address 'backend'"
  Once name resolution works, the Service still does not answer, and once the
  Service answers, a direct pod-to-pod request may still time out.

${BLD}Your goal${RST}
  From the client pod, ALL of these must succeed:
    1. nslookup backend.${NS}.svc.cluster.local   (resolved by cluster DNS)
    2. wget -qO- http://backend/hostname            (short name, via Service)
    3. wget -qO- http://<backend-pod-IP>:8080/hostname   (direct pod-to-pod)

${BLD}Rules${RST}
  - Do NOT modify or delete NetworkPolicy 'backend-allow-granted-clients'
    (owned by the security team). The 'intruder' pod must stay blocked.
  - Do NOT change the labels of the backend pods.
  - Do NOT touch kube-system (CoreDNS is healthy; prove it, don't edit it).

There are 3 independent faults. Isolate each layer: DNS -> Service -> Endpoints
-> pod IP -> policy. Grade yourself with:  $0 check
Stuck? Run:  $0 hint
EOF
}

# -----------------------------------------------------------------------------
# CHECK
# -----------------------------------------------------------------------------
PASSES=0; FAILS=0

cexec() { kubectl -n "$NS" exec deploy/client -- "$@"; }

do_check() {
  preflight
  kubectl get ns "$NS" >/dev/null 2>&1 || die "Namespace $NS not found. Run '$0 break' first."
  kubectl -n "$NS" rollout status deploy/client --timeout=60s >/dev/null 2>&1 \
    || die "Deployment 'client' is not rolled out / ready."

  echo "${BLD}Grading CKNE 1.4 break & fix...${RST}"

  # --- Fault 1: pod DNS configuration ----------------------------------------
  local dnspol kubedns_ip resolv
  dnspol="$(kubectl -n "$NS" get deploy client -o jsonpath='{.spec.template.spec.dnsPolicy}')"
  kubedns_ip="$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  resolv="$(cexec cat /etc/resolv.conf 2>/dev/null || true)"

  if [[ "$dnspol" == "ClusterFirst" || "$dnspol" == "ClusterFirstWithHostNet" ]] \
     && grep -q "svc.cluster.local" <<<"$resolv"; then
    pass "client dnsPolicy=${dnspol}; resolv.conf has the cluster search path"
  else
    fail "client dnsPolicy='${dnspol:-<unset>}'; resolv.conf lacks 'svc.cluster.local'"
  fi

  if [[ -n "$kubedns_ip" ]] && grep -q "nameserver ${kubedns_ip}" <<<"$resolv"; then
    pass "client uses the cluster DNS Service (${kubedns_ip}) as nameserver"
  else
    fail "client nameserver is not the kube-dns ClusterIP (${kubedns_ip:-unknown})"
  fi

  if cexec nslookup "backend.${NS}.svc.cluster.local" >/dev/null 2>&1; then
    pass "nslookup backend.${NS}.svc.cluster.local resolves"
  else
    fail "nslookup backend.${NS}.svc.cluster.local does not resolve"
  fi

  # --- Fault 2: Service selector / targetPort --------------------------------
  local eps
  eps="$(kubectl -n "$NS" get endpointslices -l kubernetes.io/service-name=backend \
          -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" "}{end}' 2>/dev/null || true)"
  if [[ -n "${eps// /}" ]]; then
    pass "Service 'backend' has endpoints: ${eps}"
  else
    fail "Service 'backend' has NO endpoints (selector does not match any ready pod)"
  fi

  local tp
  tp="$(kubectl -n "$NS" get svc backend -o jsonpath='{.spec.ports[0].targetPort}')"
  if [[ "$tp" == "8080" || "$tp" == "http" ]]; then
    pass "Service targetPort=${tp} matches the container port"
  else
    fail "Service targetPort=${tp} does not match the container port"
  fi

  local out
  out="$(cexec wget -T 3 -qO- http://backend/hostname 2>/dev/null || true)"
  if [[ "$out" == backend-* ]]; then
    pass "client -> http://backend/hostname answered by '${out}'"
  else
    fail "client -> http://backend/hostname failed"
  fi

  # --- Fault 3: NetworkPolicy / pod-to-pod -----------------------------------
  local pod_ip
  pod_ip="$(kubectl -n "$NS" get pods -l app=backend -o jsonpath='{.items[0].status.podIP}')"

  out="$(cexec wget -T 3 -qO- "http://${pod_ip}:8080/hostname" 2>/dev/null || true)"
  if [[ "$out" == backend-* ]]; then
    pass "client -> pod IP ${pod_ip}:8080 (direct pod-to-pod) OK"
  else
    fail "client -> pod IP ${pod_ip}:8080 (direct pod-to-pod) failed"
  fi

  local np_label
  np_label="$(kubectl -n "$NS" get networkpolicy backend-allow-granted-clients \
              -o jsonpath='{.spec.ingress[0].from[0].podSelector.matchLabels.access}' 2>/dev/null || true)"
  if [[ "$np_label" == "granted" ]]; then
    pass "NetworkPolicy 'backend-allow-granted-clients' is intact"
  else
    fail "NetworkPolicy 'backend-allow-granted-clients' was modified or deleted (rule violation)"
  fi

  if netpol_enforced; then
    if kubectl -n "$NS" exec intruder -- wget -T 3 -qO- "http://${pod_ip}:8080/hostname" >/dev/null 2>&1; then
      fail "the 'intruder' pod can reach the backend - the policy is no longer protecting it"
    else
      pass "the 'intruder' pod is still blocked by the NetworkPolicy"
    fi
  else
    skip "intruder isolation (CNI does not enforce NetworkPolicy)"
  fi

  echo
  if (( FAILS == 0 )); then
    echo "${GRN}${BLD}All checks passed (${PASSES}). Lab solved.${RST}"
  else
    echo "${RED}${BLD}${FAILS} check(s) failed, ${PASSES} passed. Keep going.${RST}"
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# HINT
# -----------------------------------------------------------------------------
do_hint() {
  cat <<EOF
${BLD}Hint 1 (DNS):${RST}   Which server answered the nslookup? Compare the client's
               /etc/resolv.conf with that of a fresh pod, and with the kube-dns
               Service ClusterIP. What decides how kubelet writes that file?
${BLD}Hint 2 (Service):${RST} 'kubectl get endpointslices -l kubernetes.io/service-name=backend'.
               Compare the Service selector with 'kubectl get pods --show-labels'.
               When endpoints appear, compare targetPort with containerPort.
${BLD}Hint 3 (Policy):${RST}  Read the NetworkPolicy's 'from' selector character by character
               and compare it with the client pod's labels. You may not edit the policy.
EOF
}

# -----------------------------------------------------------------------------
# CLEANUP
# -----------------------------------------------------------------------------
do_cleanup() {
  preflight
  if ! kubectl get ns "$NS" >/dev/null 2>&1; then
    info "Namespace $NS does not exist. Nothing to do."
    return 0
  fi
  ns_is_ours || die "Namespace $NS is not labelled as owned by this lab. Refusing to delete it."
  confirm "Delete namespace '$NS' and everything in it?"
  kubectl delete ns "$NS" --wait=true --timeout="$TIMEOUT"
  info "Cleanup complete."
}

case "${1:-}" in
  break)   do_break ;;
  check)   do_check ;;
  hint)    do_hint ;;
  cleanup) do_cleanup ;;
  *) echo "Usage: $0 {break|check|hint|cleanup} [--yes]"; exit 2 ;;
esac
