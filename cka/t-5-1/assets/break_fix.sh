#!/usr/bin/env bash
#
# CKA 1.35 - Dominio 5: Services and Networking
# Tema 5.1 - Understand connectivity between Pods (peso examen: 3.33)
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Script de práctica "break & fix". Uso EXCLUSIVO en una VM de laboratorio
# descartable: modifica reglas de iptables del host y crea recursos en el
# clúster. No ejecutar en un clúster real ni compartido.
#
# Uso:
#   sudo ./5.1-connectivity.sh setup    # crea el namespace y dos Pods de prueba
#   sudo ./5.1-connectivity.sh break    # rompe la conectividad entre los Pods
#   sudo ./5.1-connectivity.sh verify   # comprueba si la conectividad está OK (no da la solución)
#   sudo ./5.1-connectivity.sh clean    # revierte todo (iptables + recursos de k8s)
#   sudo ./5.1-connectivity.sh all      # setup + break (default si no se pasa argumento)

set -euo pipefail

NS="cka-5-1-connectivity"
POD_A="pod-a"
POD_B="pod-b"
IMAGE="busybox:1.36"
MARK_COMMENT="cka-5-1-lab-break"
STATE_FILE="/tmp/${NS}.state"

log() { echo "[cka-5.1] $*"; }
die() { log "ERROR: $*"; exit 1; }

trap 'log "Algo falló. Revisá la salida de arriba."' ERR

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Este script necesita root (usá sudo), porque manipula iptables del host."
}

require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || die "No se encontró kubectl en el PATH."
  kubectl cluster-info >/dev/null 2>&1 || die "kubectl no puede contactar al clúster. Revisá el kubeconfig."
}

require_iptables() {
  command -v iptables >/dev/null 2>&1 || die "No se encontró el comando iptables en esta VM."
}

confirm_disposable() {
  if [ "${SKIP_CONFIRM:-0}" = "1" ]; then
    return 0
  fi
  echo "Este script inserta reglas en la tabla iptables del host y crea"
  echo "recursos en el clúster actual (namespace '${NS}')."
  echo "Usalo SOLO en una VM de laboratorio descartable."
  read -r -p "¿Confirmás que esta VM es descartable y podés continuar? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) die "Cancelado por el usuario." ;;
  esac
}

save_state() {
  cat > "$STATE_FILE" <<EOF
POD_A_IP=${POD_A_IP}
POD_B_IP=${POD_B_IP}
EOF
}

load_state() {
  [ -f "$STATE_FILE" ] || die "No hay estado guardado. Corré primero: $0 setup"
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  [ -n "${POD_A_IP:-}" ] && [ -n "${POD_B_IP:-}" ] || die "Estado inválido en $STATE_FILE"
}

setup() {
  require_kubectl
  log "Creando namespace '${NS}' y dos Pods de prueba (${POD_A}, ${POD_B})..."
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl run "$POD_A" -n "$NS" --image="$IMAGE" --restart=Never \
    --command -- sh -c "sleep infinity" >/dev/null 2>&1 || true
  kubectl run "$POD_B" -n "$NS" --image="$IMAGE" --restart=Never \
    --command -- sh -c "sleep infinity" >/dev/null 2>&1 || true

  log "Esperando a que los Pods estén Ready..."
  kubectl wait --for=condition=Ready pod/"$POD_A" -n "$NS" --timeout=90s
  kubectl wait --for=condition=Ready pod/"$POD_B" -n "$NS" --timeout=90s

  POD_A_IP=$(kubectl get pod "$POD_A" -n "$NS" -o jsonpath='{.status.podIP}')
  POD_B_IP=$(kubectl get pod "$POD_B" -n "$NS" -o jsonpath='{.status.podIP}')
  [ -n "$POD_A_IP" ] && [ -n "$POD_B_IP" ] || die "No pude obtener las IPs de los Pods."
  save_state

  log "Verificando conectividad inicial (debe funcionar antes de romper nada)..."
  kubectl exec -n "$NS" "$POD_A" -- ping -c 2 -W 2 "$POD_B_IP" >/dev/null \
    || die "La conectividad base ya está rota antes de aplicar el ejercicio. Revisá el clúster."
  log "OK: ${POD_A} (${POD_A_IP}) <-> ${POD_B} (${POD_B_IP}) conectan sin problemas."
}

break_scenario() {
  require_root
  require_iptables
  load_state

  log "Aplicando la falla de forma controlada (solo afecta a estos dos Pods)..."
  iptables -I FORWARD -s "$POD_A_IP" -d "$POD_B_IP" -m comment --comment "$MARK_COMMENT" -j DROP
  iptables -I FORWARD -s "$POD_B_IP" -d "$POD_A_IP" -m comment --comment "$MARK_COMMENT" -j DROP

  cat <<EOF

================= SÍNTOMA =================
Los Pods '${POD_A}' (${POD_A_IP}) y '${POD_B}' (${POD_B_IP}) en el
namespace '${NS}' están Running y Ready, pero ya no pueden comunicarse
entre sí por su IP directa: un ping o curl entre ellos hace timeout.

  kubectl exec -n ${NS} ${POD_A} -- ping -c 3 ${POD_B_IP}

El resto del clúster (DNS, otros namespaces, otros Pods, Services) sigue
funcionando con normalidad. No hay ningún NetworkPolicy aplicado en este
namespace, así que el problema no está ahí.

================= OBJETIVO =================
Diagnosticá en qué capa de networking del Pod-to-Pod se está perdiendo el
tráfico y restablecé la conectividad directa entre '${POD_A}' y '${POD_B}'
sin borrar ni recrear los Pods. Pensá en qué componente del nodo procesa
el tráfico enrutado entre dos Pods antes de llegar a la interfaz del Pod
destino.

Cuando creas que lo arreglaste, corré:
  $0 verify
=============================================

EOF
}

verify() {
  require_kubectl
  load_state
  log "Probando conectividad ${POD_A} -> ${POD_B}..."
  if kubectl exec -n "$NS" "$POD_A" -- ping -c 3 -W 2 "$POD_B_IP" >/dev/null 2>&1; then
    log "PASS: la conectividad entre los Pods está restablecida."
  else
    log "FAIL: los Pods todavía no se pueden comunicar."
  fi
}

clean() {
  require_root
  require_iptables
  log "Eliminando reglas iptables del ejercicio (si existen)..."
  while iptables -C FORWARD -m comment --comment "$MARK_COMMENT" -j DROP 2>/dev/null; do
    iptables -D FORWARD -m comment --comment "$MARK_COMMENT" -j DROP
  done
  # Por si quedaron con match de IPs específico (inserción original):
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE" || true
    if [ -n "${POD_A_IP:-}" ] && [ -n "${POD_B_IP:-}" ]; then
      iptables -D FORWARD -s "$POD_A_IP" -d "$POD_B_IP" -m comment --comment "$MARK_COMMENT" -j DROP 2>/dev/null || true
      iptables -D FORWARD -s "$POD_B_IP" -d "$POD_A_IP" -m comment --comment "$MARK_COMMENT" -j DROP 2>/dev/null || true
    fi
  fi

  if command -v kubectl >/dev/null 2>&1; then
    log "Borrando namespace '${NS}'..."
    kubectl delete namespace "$NS" --ignore-not-found=true >/dev/null 2>&1 || true
  fi

  rm -f "$STATE_FILE"
  log "Limpieza completa."
}

main() {
  local cmd="${1:-all}"
  case "$cmd" in
    setup)
      confirm_disposable
      setup
      ;;
    break)
      confirm_disposable
      break_scenario
      ;;
    verify)
      verify
      ;;
    clean)
      confirm_disposable
      clean
      ;;
    all)
      confirm_disposable
      setup
      break_scenario
      ;;
    *)
      die "Comando desconocido: $cmd (usar: setup|break|verify|clean|all)"
      ;;
  esac
}

main "$@"
