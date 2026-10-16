#!/usr/bin/env bash
# CKAD 1.35 - Tema 3.4 "Debugging in Kubernetes" (peso: 3)
# Ejercicio break & fix para VM de laboratorio descartable (kind/minikube/etc).
# Fuente de referencia (curriculum, solo como contexto de alcance del tema):
#   https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#
# Este script crea un namespace propio y despliega un Deployment + Service
# rotos de forma intencional pero segura (no toca nada fuera de ese namespace).
# No hace falta memorizar el arreglo: el objetivo es practicar el flujo de
# debugging (kubectl describe / logs / exec / get endpoints) hasta encontrarlo.

set -euo pipefail

NS="ckad-3-4-debug-lab"
DEPLOY="webshop"
SVC="webshop"
TESTER="tester"

usage() {
  cat <<EOF
Uso: $0 [setup|verify|cleanup]

  setup    (default) rompe el escenario en el namespace $NS
  verify   chequea si ya lo arreglaste
  cleanup  borra el namespace $NS y todo lo que contiene
EOF
}

need_kubectl() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "No se encontró kubectl en el PATH." >&2
    exit 1
  fi
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "No hay un cluster accesible con el kubeconfig actual." >&2
    exit 1
  fi
}

confirm_context() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo desconocido)"
  echo "Contexto actual de kubectl: $ctx"
  if [ "${YES:-0}" = "1" ]; then
    return 0
  fi
  read -r -p "Este script va a crear/borrar recursos en el namespace '$NS' de ese contexto. ¿Continuar? [y/N] " ans
  case "$ans" in
    y|Y) ;;
    *) echo "Cancelado."; exit 1 ;;
  esac
}

do_setup() {
  need_kubectl
  confirm_context

  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl apply -n "$NS" -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webshop
  labels:
    app: webshop
spec:
  replicas: 1
  selector:
    matchLabels:
      app: webshop
  template:
    metadata:
      labels:
        app: webshop
    spec:
      containers:
      - name: webshop
        image: nginx:1.25
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 2
          periodSeconds: 5
        resources:
          requests:
            cpu: "50m"
            memory: "32Mi"
          limits:
            cpu: "100m"
            memory: "64Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: webshop
spec:
  selector:
    app: webshop
  ports:
  - port: 80
    targetPort: 8080
EOF

  kubectl run "$TESTER" -n "$NS" --image=busybox:1.36 --restart=Never \
    --overrides='{"spec":{"containers":[{"name":"tester","image":"busybox:1.36","command":["sleep","3600"],"resources":{"requests":{"cpu":"20m","memory":"16Mi"},"limits":{"cpu":"50m","memory":"32Mi"}}}]}}' \
    >/dev/null 2>&1 || true

  echo "Esperando a que el estado se estabilice..."
  sleep 15

  echo
  echo "=== Estado actual ==="
  kubectl get deployment,pod,endpoints -n "$NS"

  cat <<EOF

=== SÍNTOMA ===
El Deployment '$DEPLOY' tiene 1 réplica corriendo, pero el Pod queda en
READY 0/1 y no se recupera solo. No hay restarts (no es CrashLoopBackOff).
Si mirás 'kubectl get endpoints $SVC -n $NS' vas a ver que el Service no
tiene ningún endpoint. Un pod 'tester' quedó desplegado en el mismo
namespace para que pruebes conectividad contra el Service.

=== OBJETIVO ===
Sin cambiar la imagen del contenedor, lograr que:
  1. El Pod del Deployment '$DEPLOY' quede 1/1 Ready.
  2. El Service '$SVC' tenga al menos un endpoint.
  3. Desde el pod '$TESTER' se pueda obtener la página de bienvenida
     de nginx a través del Service (no del Pod directo).

Comandos que te van a servir para investigar:
  kubectl get pods -n $NS -o wide
  kubectl describe pod <pod> -n $NS
  kubectl logs <pod> -n $NS
  kubectl get endpoints $SVC -n $NS
  kubectl exec -it <pod> -n $NS -- sh
  kubectl exec -n $NS $TESTER -- wget -qO- --timeout=5 http://$SVC.$NS.svc.cluster.local

Corré '$0 verify' cuando creas que lo resolviste.
EOF
}

do_verify() {
  need_kubectl
  local ready ep
  ready="$(kubectl get pods -n "$NS" -l app=webshop -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo false)"
  ep="$(kubectl get endpoints "$SVC" -n "$NS" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"

  if [ "$ready" != "true" ]; then
    echo "FALTA: el Pod todavía no está Ready."
    exit 1
  fi
  if [ -z "$ep" ]; then
    echo "FALTA: el Service '$SVC' todavía no tiene endpoints."
    exit 1
  fi
  if kubectl exec -n "$NS" "$TESTER" -- wget -qO- --timeout=5 "http://$SVC.$NS.svc.cluster.local" 2>/dev/null | grep -qi "Welcome to nginx"; then
    echo "OK: Pod Ready, Service con endpoints, y el tester recibe la página de nginx a través del Service."
  else
    echo "FALTA: el tester todavía no puede llegar a nginx a través del Service."
    exit 1
  fi
}

do_cleanup() {
  need_kubectl
  kubectl delete namespace "$NS" --ignore-not-found
}

case "${1:-setup}" in
  setup)   do_setup ;;
  verify)  do_verify ;;
  cleanup) do_cleanup ;;
  -h|--help) usage ;;
  *) usage; exit 1 ;;
esac
