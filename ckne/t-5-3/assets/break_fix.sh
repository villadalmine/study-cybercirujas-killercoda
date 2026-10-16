#!/usr/bin/env bash
# =============================================================================
# CKNE 5.3 — Auditing Traffic with Logs — BREAK & FIX LAB
# -----------------------------------------------------------------------------
# Scenario: a "payments" Service stops answering its clients. Nothing in the
# default logs explains why. CoreDNS does not log queries, the backend's
# nginx access log is switched off, and the CoreDNS `errors` plugin stays
# silent because NXDOMAIN is a valid DNS answer, not an error.
#
# You have to turn traffic logging back on at two layers (L7 DNS and L7 HTTP),
# use those logs to find the fault, fix it, and then prove with the logs that
# traffic flows end to end.
#
# RUN THIS ONLY ON A DISPOSABLE LAB CLUSTER (kind, k3d, minikube, a kubeadm VM).
# The script changes the cluster-wide CoreDNS configuration. A backup of the
# original Corefile goes to ~/.breakfix/ckne-5.3/ and `reset` restores it.
#
# Usage:
#   ./break-fix-5.3.sh break    # inject the fault (default)
#   ./break-fix-5.3.sh verify   # grade your fix
#   ./break-fix-5.3.sh reset    # restore everything and remove the lab
#
# Requirements: kubectl pointed at the lab cluster; jq or python3.
#
# References (official):
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
#   https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
#   https://coredns.io/plugins/log/
#   https://coredns.io/plugins/template/
#   https://coredns.io/plugins/errors/
#   https://nginx.org/en/docs/http/ngx_http_log_module.html
# =============================================================================

set -euo pipefail

readonly NS="audit-lab"
readonly STATE_DIR="${HOME}/.breakfix/ckne-5.3"
readonly ORIG_COREFILE="${STATE_DIR}/Corefile.orig"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_bld=$'\033[1m'; c_rst=$'\033[0m'

info() { printf '%s[lab]%s %s\n' "$c_bld" "$c_rst" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
die()  { printf '%s[error]%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."; }

# -----------------------------------------------------------------------------
# Safety guard: refuse to run against anything that does not look like a lab.
# -----------------------------------------------------------------------------
guard_context() {
  need kubectl
  command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 \
    || die "Either jq or python3 is required."

  local ctx
  ctx="$(kubectl config current-context 2>/dev/null)" || die "No current kubectl context."
  case "$ctx" in
    kind-*|k3d-*|minikube|*lab*|*sandbox*|*test*) ;;
    *)
      if [[ "${I_KNOW_THIS_IS_A_LAB:-}" != "yes" ]]; then
        die "Context '${ctx}' does not look like a disposable lab cluster.
       This lab rewrites the cluster-wide CoreDNS config. If you are sure,
       re-run with: I_KNOW_THIS_IS_A_LAB=yes $0 ${1:-break}"
      fi
      ;;
  esac

  kubectl -n kube-system get deployment coredns >/dev/null 2>&1 \
    || die "No 'coredns' Deployment in kube-system. This lab needs CoreDNS."
  kubectl -n kube-system get configmap coredns >/dev/null 2>&1 \
    || die "No 'coredns' ConfigMap in kube-system."

  # k3s re-applies its packaged CoreDNS manifest and silently undoes edits.
  if kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.kubeletVersion}' | grep -q 'k3s'; then
    if [[ "${FORCE:-}" != "1" ]]; then
      die "k3s detected: its addon controller may revert CoreDNS edits and make the lab
       unpredictable. Use kind/kubeadm, or re-run with FORCE=1 at your own risk."
    fi
    warn "k3s detected and FORCE=1 set, so continuing."
  fi
  info "Using context: ${ctx}"
}

# Build a JSON merge patch for data.Corefile from a file.
corefile_patch() {
  if command -v jq >/dev/null 2>&1; then
    jq -Rs '{data: {Corefile: .}}' "$1"
  else
    python3 -c 'import json,sys; print(json.dumps({"data": {"Corefile": open(sys.argv[1]).read()}}))' "$1"
  fi
}

restart_coredns() {
  info "Restarting CoreDNS so the new Corefile is loaded immediately..."
  kubectl -n kube-system rollout restart deployment/coredns >/dev/null
  kubectl -n kube-system rollout status deployment/coredns --timeout=180s >/dev/null
}

current_corefile() {
  kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'
}

# -----------------------------------------------------------------------------
# BREAK
# -----------------------------------------------------------------------------
cmd_break() {
  guard_context break
  mkdir -p "$STATE_DIR"

  local current
  current="$(current_corefile)"

  if [[ ! -f "$ORIG_COREFILE" ]]; then
    if grep -q "template IN ANY ${NS}\.svc" <<<"$current"; then
      die "CoreDNS already contains the lab fault but the backup is missing.
       Restore the Corefile by hand (see the solution at the end of this script)."
    fi
    printf '%s\n' "$current" > "$ORIG_COREFILE"
    info "Original Corefile backed up to ${ORIG_COREFILE}"
  else
    info "Backup already exists (${ORIG_COREFILE}), so it is not overwritten."
  fi

  local domain
  domain="$(awk '$1=="kubernetes"{print $2; exit}' "$ORIG_COREFILE")"
  domain="${domain:-cluster.local}"

  # --- 1. Workload: a payments backend with access logging OFF, and a client.
  info "Deploying the '${NS}' workload..."
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: audit-lab
  labels:
    app.kubernetes.io/part-of: breakfix-ckne-5.3
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: payments-nginx
  namespace: audit-lab
data:
  default.conf: |
    server {
        listen 8080;
        server_name _;

        # Access logging disabled: "too noisy for the SIEM".
        access_log off;

        location = /healthz {
            default_type text/plain;
            return 200 "ok\n";
        }

        location / {
            default_type text/plain;
            return 200 "payments: ok\n";
        }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
  namespace: audit-lab
  labels:
    app: payments
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payments
  template:
    metadata:
      labels:
        app: payments
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 5
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 64Mi
          volumeMounts:
            - name: conf
              mountPath: /etc/nginx/conf.d
      volumes:
        - name: conf
          configMap:
            name: payments-nginx
---
apiVersion: v1
kind: Service
metadata:
  name: payments
  namespace: audit-lab
spec:
  selector:
    app: payments
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: audit-lab
  labels:
    app: client
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["/bin/sh", "-c"]
      args:
        - |
          while true; do
            echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) GET http://payments/"
            curl -sS -m 3 -o /dev/null -w 'result: HTTP %{http_code}\n' http://payments/ 2>&1 || true
            sleep 3
          done
      resources:
        requests:
          cpu: 5m
          memory: 8Mi
        limits:
          memory: 32Mi
EOF

  kubectl -n "$NS" rollout status deployment/payments --timeout=180s >/dev/null
  kubectl -n "$NS" wait pod/client --for=condition=Ready --timeout=180s >/dev/null

  # --- 2. The fault: CoreDNS answers NXDOMAIN for the payments Service FQDN,
  #        and query logging is removed so the answer is invisible.
  if grep -q "template IN ANY ${NS}\.svc" <<<"$current"; then
    info "CoreDNS fault already in place, so nothing to change (idempotent)."
  else
    local broken="${STATE_DIR}/Corefile.broken"
    if ! awk -v ns="$NS" -v dom="$domain" '
      BEGIN { re = "payments." ns ".svc." dom "."; gsub(/\./, "[.]", re) }
      /^[[:space:]]*log[[:space:]]*$/ { next }
      { print }
      !done && /^[[:space:]]*ready([[:space:]]|$)/ {
        print "    template IN ANY " ns ".svc." dom " {"
        print "        match \"(?i)^" re "$\""
        print "        rcode NXDOMAIN"
        print "        fallthrough"
        print "    }"
        done = 1
      }
      END { if (!done) exit 3 }
    ' "$ORIG_COREFILE" > "$broken"; then
      die "Could not find the 'ready' plugin line in the Corefile. Unsupported layout."
    fi
    kubectl -n kube-system patch configmap coredns --type merge -p "$(corefile_patch "$broken")" >/dev/null
    rm -f "$broken"
    restart_coredns
  fi

  cat <<EOF

${c_bld}=====================================================================
 CKNE 5.3 — Auditing Traffic with Logs — INCIDENT TICKET
=====================================================================${c_rst}

 "Since the last change window, the client in namespace '${NS}' cannot
  reach the 'payments' Service. The Service, its Pod and its endpoints
  all look healthy. Nobody knows what changed, and we have no logs."

${c_bld}SYMPTOMS YOU WILL SEE${c_rst}
  * kubectl -n ${NS} logs client -f
      -> "curl: (6) Could not resolve host: payments" and "HTTP 000"
  * kubectl -n ${NS} get svc,endpointslices,pods
      -> everything looks healthy: ClusterIP assigned, endpoint Ready.
  * kubectl -n ${NS} logs deploy/payments
      -> no access log lines at all. You cannot tell whether any request
         ever reaches the backend.
  * kubectl -n kube-system logs -l k8s-app=kube-dns
      -> nothing useful. The 'errors' plugin does not report NXDOMAIN.

${c_bld}YOUR OBJECTIVES${c_rst}
  1. Turn on DNS query logging in CoreDNS (the 'log' plugin) so that
     every query, its response code (rcode) and its flags are audited.
  2. Using ONLY what the CoreDNS log shows you, work out who is answering
     the payments lookups and why, then remove the root cause.
  3. Turn on a structured (JSON) access log in the payments nginx, written
     to stdout, with at least: timestamp, client address, method, URI,
     and status.
  4. Prove end to end with logs: CoreDNS logs NOERROR for
     payments.${NS}.svc.${domain}. and the nginx JSON log shows requests
     coming from the client Pod's IP with status 200.

${c_bld}RULES${c_rst}
  * Do not delete or recreate the Service, the Deployment or the client Pod.
  * Do not "fix" it by restoring ${ORIG_COREFILE}. That is 'reset'.
  * Leave the other CoreDNS plugins in place.

${c_bld}HINTS (read only if stuck)${c_rst}
  * A healthy ClusterIP Service plus a failed name lookup means the fault
    is in resolution, not in the data path. Who answers DNS in the cluster?
  * In a CoreDNS log line, the 'aa' flag means "authoritative answer":
    CoreDNS produced the answer itself and did not forward it upstream.
  * CoreDNS plugins run in a compiled-in order, not in the order they
    appear in the Corefile.

  Grade yourself:  $0 verify
  Clean up:        $0 reset
=====================================================================
EOF
}

# -----------------------------------------------------------------------------
# VERIFY
# -----------------------------------------------------------------------------
cmd_verify() {
  guard_context verify
  local pass=0 fail=0 corefile client_ip code

  ok()  { printf '  %s[PASS]%s %s\n' "$c_grn" "$c_rst" "$*"; pass=$((pass + 1)); }
  bad() { printf '  %s[FAIL]%s %s\n' "$c_red" "$c_rst" "$*"; fail=$((fail + 1)); }

  kubectl get namespace "$NS" >/dev/null 2>&1 || die "Namespace ${NS} not found. Run '$0 break' first."

  corefile="$(current_corefile)"
  echo
  info "Grading..."

  if grep -Eq '^[[:space:]]*log([[:space:]]|$)' <<<"$corefile"; then
    ok "CoreDNS 'log' plugin is enabled."
  else
    bad "CoreDNS 'log' plugin is not in the Corefile."
  fi

  if grep -Eq "template[[:space:]].*${NS}" <<<"$corefile"; then
    bad "A 'template' block still intercepts ${NS} names in the Corefile."
  else
    ok "No rogue 'template' block intercepts the ${NS} zone."
  fi

  code="$(kubectl -n "$NS" exec client -- curl -s -m 5 -o /dev/null -w '%{http_code}' http://payments/ 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    ok "client -> http://payments/ returns HTTP 200."
  else
    bad "client -> http://payments/ returned '${code:-nothing}' (expected 200)."
  fi

  sleep 2
  if kubectl -n kube-system logs -l k8s-app=kube-dns --tail=2000 --max-log-requests=10 2>/dev/null \
      | grep "payments\.${NS}\.svc\." | grep -q 'NOERROR'; then
    ok "CoreDNS logs show NOERROR answers for payments.${NS}.svc."
  else
    bad "No NOERROR entry for payments.${NS}.svc. in the CoreDNS logs."
  fi

  client_ip="$(kubectl -n "$NS" get pod client -o jsonpath='{.status.podIP}')"
  local nginx_logs
  nginx_logs="$(kubectl -n "$NS" logs deploy/payments --tail=300 2>/dev/null || true)"
  if command -v python3 >/dev/null 2>&1; then
    if CLIENT_IP="$client_ip" python3 -c '
import json, os, sys
ip = os.environ["CLIENT_IP"]
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    if not isinstance(rec, dict):
        continue
    vals = [str(v) for v in rec.values()]
    if ip in vals and "200" in vals:
        sys.exit(0)
sys.exit(1)
' <<<"$nginx_logs"; then
      ok "nginx writes valid JSON access logs showing the client Pod IP ${client_ip} and status 200."
    else
      bad "No valid JSON access-log line with remote address ${client_ip} and status 200."
    fi
  else
    if grep -E '^\{' <<<"$nginx_logs" | grep -F "\"${client_ip}\"" | grep -q '"200"'; then
      ok "nginx JSON access log shows ${client_ip} with status 200 (grep check, no python3)."
    else
      bad "No JSON access-log line with remote address ${client_ip} and status 200."
    fi
  fi

  echo
  if (( fail == 0 )); then
    printf '%sAll %d checks passed. Incident closed, and the logs prove it.%s\n' "$c_grn" "$pass" "$c_rst"
  else
    printf '%s%d passed, %d failed.%s Keep going.\n' "$c_ylw" "$pass" "$fail" "$c_rst"
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# RESET
# -----------------------------------------------------------------------------
cmd_reset() {
  guard_context reset
  if [[ -f "$ORIG_COREFILE" ]]; then
    info "Restoring the original Corefile..."
    kubectl -n kube-system patch configmap coredns --type merge -p "$(corefile_patch "$ORIG_COREFILE")" >/dev/null
    restart_coredns
  else
    warn "No backup at ${ORIG_COREFILE}, so the Corefile was left untouched."
  fi
  info "Deleting namespace ${NS}..."
  kubectl delete namespace "$NS" --ignore-not-found --wait=true >/dev/null
  rm -rf "$STATE_DIR"
  info "Lab removed."
}

case "${1:-break}" in
  break)  cmd_break ;;
  verify) cmd_verify ;;
  reset)  cmd_reset ;;
  *) echo "Usage: $0 {break|verify|reset}" >&2; exit 2 ;;
esac
