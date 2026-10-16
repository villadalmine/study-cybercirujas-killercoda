#!/usr/bin/env bash
#
# CKAD v1.35 - Tema 4.7: Understand ServiceAccounts (peso: 3)
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#
# Laboratorio "break & fix" pensado para correr en una VM de laboratorio
# DESCARTABLE con acceso de kubectl a un clúster Kubernetes cualquiera.
# Alcanza con poder crear Namespace, ServiceAccount, Role, RoleBinding y
# Deployment (no hace falta acceso cluster-admin ni CRDs).
#
# Todo lo que este script toca vive dentro del namespace $NAMESPACE y el
# directorio $LAB_DIR (por defecto bajo $HOME): no borra ni modifica nada
# fuera de eso.
#
# Uso:
#   ./break_fix.sh break    -> rompe el laboratorio (deja el síntoma listo)
#   ./break_fix.sh check    -> valida si ya arreglaste el problema
#   ./break_fix.sh reset    -> reconstruye el laboratorio en estado sano (para repetir el ejercicio)
#   ./break_fix.sh cleanup  -> borra los recursos de Kubernetes y el directorio de laboratorio
#
# Requisitos: kubectl configurado contra un clúster, con permisos para crear
# Namespace, ServiceAccount, Role, RoleBinding y Deployment.

set -uo pipefail

NAMESPACE="ckad-4-7-lab"
LAB_DIR="${LAB_DIR:-$HOME/ckad-lab/4.7-serviceaccounts}"
OLD_SA="report-agent"
NEW_SA="report-agent-v2"
ROLE_NAME="pod-reader"
RB_NAME="pod-reader-binding"
DEPLOY_NAME="report-agent"
CONTAINER_NAME="app"
IMAGE="curlimages/curl:8.10.1"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: necesitás 'kubectl' instalado y configurado en esta VM de laboratorio." >&2
  exit 1
fi

if ! kubectl get nodes >/dev/null 2>&1; then
  echo "ERROR: kubectl no puede hablar con ningún clúster. Configurá el kubeconfig primero." >&2
  exit 1
fi

# ServiceAccount "sano": el que usa el Deployment antes de la rotación de
# credenciales de este sprint.
write_healthy_serviceaccount() {
  mkdir -p "$LAB_DIR"
  cat > "$LAB_DIR/serviceaccount.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $OLD_SA
  namespace: $NAMESPACE
EOF
}

# Role + RoleBinding "sanos": le dan a $OLD_SA permiso de get/list/watch
# sobre pods en el propio namespace, tal como necesita el agente de
# reporting para funcionar.
write_healthy_rbac() {
  mkdir -p "$LAB_DIR"
  cat > "$LAB_DIR/rbac.yaml" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: $ROLE_NAME
  namespace: $NAMESPACE
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $RB_NAME
  namespace: $NAMESPACE
subjects:
- kind: ServiceAccount
  name: $OLD_SA
  namespace: $NAMESPACE
roleRef:
  kind: Role
  name: $ROLE_NAME
  apiGroup: rbac.authorization.k8s.io
EOF
}

# Deployment "sano": usa serviceAccountName (nunca el ServiceAccount
# "default") y strategy Recreate, para que el síntoma de la rotura sea
# inequívoco (sin pods "surge" de por medio que puedan confundir el
# diagnóstico).
write_healthy_deployment() {
  mkdir -p "$LAB_DIR"
  cat > "$LAB_DIR/deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_NAME
  namespace: $NAMESPACE
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: $DEPLOY_NAME
  template:
    metadata:
      labels:
        app: $DEPLOY_NAME
    spec:
      serviceAccountName: $OLD_SA
      containers:
      - name: $CONTAINER_NAME
        image: $IMAGE
        command: ["sh", "-c", "sleep 3600"]
EOF
}

# Notas del sprint (contexto del ejercicio, ningún controller las lee): por
# qué cambió el ServiceAccount y qué es lo que en realidad hay que tocar.
write_notes() {
  mkdir -p "$LAB_DIR"
  cat > "$LAB_DIR/notas-sprint.md" <<EOF
# Notas del sprint - servicio "$DEPLOY_NAME" (namespace $NAMESPACE)

Como parte de la política de rotación de credenciales de este sprint, el
equipo de seguridad reemplazó el ServiceAccount del agente de reporting:

  $OLD_SA  ->  $NEW_SA

El ServiceAccount viejo ($OLD_SA) y su RoleBinding se ELIMINARON: la
rotación es definitiva, no se vuelve para atrás. El ServiceAccount nuevo
($NEW_SA) ya tiene el mismo Role ($ROLE_NAME, get/list/watch sobre pods)
asignado vía RoleBinding. Cualquier Deployment que todavía referencie el
ServiceAccount viejo tiene que actualizarse para usar el nuevo.
EOF
}

scaffold_lab() {
  if ! kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
    echo ">> Creando namespace $NAMESPACE ..."
    kubectl create ns "$NAMESPACE" >/dev/null
  fi
  write_healthy_serviceaccount
  write_healthy_rbac
  write_healthy_deployment

  echo ">> Aplicando ServiceAccount, RBAC y Deployment $DEPLOY_NAME en estado sano ..."
  kubectl apply -f "$LAB_DIR/serviceaccount.yaml" >/dev/null
  kubectl apply -f "$LAB_DIR/rbac.yaml" >/dev/null
  kubectl apply -f "$LAB_DIR/deployment.yaml" >/dev/null
  kubectl rollout status "deployment/$DEPLOY_NAME" -n "$NAMESPACE" --timeout=60s >/dev/null 2>&1
}

break_lab() {
  scaffold_lab

  # Rompe el laboratorio simulando la rotación de credenciales de este
  # sprint: se crea el ServiceAccount nuevo con su propio RoleBinding, y se
  # borran el ServiceAccount y el RoleBinding viejos. El Deployment queda
  # sin tocar, todavía apuntando al ServiceAccount viejo.
  cat > "$LAB_DIR/serviceaccount-new.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $NEW_SA
  namespace: $NAMESPACE
EOF
  kubectl apply -f "$LAB_DIR/serviceaccount-new.yaml" >/dev/null

  cat > "$LAB_DIR/rbac.yaml" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: $ROLE_NAME
  namespace: $NAMESPACE
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $RB_NAME
  namespace: $NAMESPACE
subjects:
- kind: ServiceAccount
  name: $NEW_SA
  namespace: $NAMESPACE
roleRef:
  kind: Role
  name: $ROLE_NAME
  apiGroup: rbac.authorization.k8s.io
EOF
  kubectl apply -f "$LAB_DIR/rbac.yaml" >/dev/null

  kubectl delete serviceaccount "$OLD_SA" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  rm -f "$LAB_DIR/serviceaccount.yaml"
  write_notes

  # El Pod que ya estaba corriendo con el token del ServiceAccount viejo
  # NO se entera del cambio (el kubelet no revalida el ServiceAccount de
  # un Pod ya creado). El síntoma recién aparece cuando el Deployment
  # necesita crear un Pod nuevo -- acá se fuerza ese momento con un
  # restart de rollout, como podría dispararlo cualquier despliegue,
  # reprogramación de nodo o rollout normal del equipo. Con strategy
  # Recreate, el Pod viejo se borra ANTES de intentar crear el nuevo.
  kubectl rollout restart "deployment/$DEPLOY_NAME" -n "$NAMESPACE" >/dev/null
  sleep 5

  reason=""
  for _ in $(seq 1 12); do
    reason=$(kubectl describe rs -n "$NAMESPACE" -l "app=$DEPLOY_NAME" 2>/dev/null \
      | grep -i "not found" | tail -n1)
    [ -n "$reason" ] && break
    sleep 5
  done

  cat <<MSG

=== LABORATORIO ROTO: CKAD 4.7 - Understand ServiceAccounts ===

Namespace:  $NAMESPACE
Deployment: $DEPLOY_NAME (container: $CONTAINER_NAME)
Manifiestos: $LAB_DIR/serviceaccount-new.yaml, $LAB_DIR/rbac.yaml, $LAB_DIR/deployment.yaml
Contexto del equipo: $LAB_DIR/notas-sprint.md

Contexto:
El equipo de seguridad rotó el ServiceAccount del agente de reporting como
parte de su política de rotación de credenciales. El ServiceAccount nuevo
ya está creado y ya tiene los permisos RBAC correctos, pero el Deployment
"$DEPLOY_NAME" no se tocó.

Síntoma que vas a observar:

  kubectl get pods -n $NAMESPACE

  No hay ningún Pod Running para el Deployment "$DEPLOY_NAME" (el Pod
  viejo se borró al hacer Recreate, y el Pod nuevo nunca llega a crearse).

  kubectl get rs -n $NAMESPACE
  kubectl describe rs -n $NAMESPACE -l app=$DEPLOY_NAME

  En Events del ReplicaSet nuevo vas a ver algo como:
    ${reason:-Error creating: pods \"$DEPLOY_NAME-xxxxx\" is forbidden: error looking up service account $NAMESPACE/$OLD_SA: serviceaccount \"$OLD_SA\" not found}

Tu objetivo:
  - Confirmar qué ServiceAccounts existen realmente ahora en el namespace:
      kubectl get sa -n $NAMESPACE
  - Revisar $LAB_DIR/notas-sprint.md para entender que la rotación es
    definitiva (el ServiceAccount viejo no vuelve).
  - Corregir el Deployment "$DEPLOY_NAME" para que su Pod use el
    ServiceAccount nuevo ($NEW_SA) en vez del viejo ($OLD_SA).
  - Confirmar que el rollout termina y el Pod queda Running/Ready, y que
    el ServiceAccount que usa tiene permiso RBAC real para listar pods.

Cuando creas que lo arreglaste, corré:
  ./break_fix.sh check

MSG
}

check_lab() {
  if ! kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
    echo "No hay laboratorio desplegado (namespace $NAMESPACE no existe). Corré primero: $0 break"
    exit 1
  fi

  if ! kubectl get deployment "$DEPLOY_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "TODAVIA NO: el Deployment $DEPLOY_NAME no existe en el namespace $NAMESPACE."
    echo "  Corré: $0 reset"
    exit 1
  fi

  if kubectl get serviceaccount "$OLD_SA" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "TODAVIA NO: recreaste el ServiceAccount viejo ($OLD_SA)."
    echo "  La rotación de este sprint es definitiva: no se revive el"
    echo "  ServiceAccount viejo, se actualiza el Deployment para que use"
    echo "  el ServiceAccount nuevo ($NEW_SA)."
    echo "  Pista: cat $LAB_DIR/notas-sprint.md"
    exit 1
  fi

  if ! kubectl get serviceaccount "$NEW_SA" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "TODAVIA NO: no existe el ServiceAccount $NEW_SA esperado."
    echo "  Corré: $0 reset"
    exit 1
  fi

  dep_sa=$(kubectl get deployment "$DEPLOY_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null)

  if [ "$dep_sa" == "$OLD_SA" ] || [ -z "$dep_sa" ]; then
    echo "TODAVIA NO: el Deployment $DEPLOY_NAME todavía referencia el"
    echo "  ServiceAccount viejo (serviceAccountName: ${dep_sa:-<vacío/default>})."
    echo "  Ese ServiceAccount ya no existe."
    exit 1
  fi

  if [ "$dep_sa" != "$NEW_SA" ]; then
    echo "TODAVIA NO: el Deployment $DEPLOY_NAME usa serviceAccountName:"
    echo "  '$dep_sa', que no es el ServiceAccount nuevo ($NEW_SA)."
    exit 1
  fi

  if ! kubectl auth can-i list pods -n "$NAMESPACE" \
      --as="system:serviceaccount:${NAMESPACE}:${dep_sa}" >/dev/null 2>&1; then
    echo "TODAVIA NO: el ServiceAccount $dep_sa no tiene permiso RBAC para"
    echo "  listar pods en el namespace $NAMESPACE. Revisá el RoleBinding"
    echo "  $RB_NAME."
    exit 1
  fi

  ready=$(kubectl get deployment "$DEPLOY_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [ "${ready:-0}" != "1" ]; then
    echo "TODAVIA NO: el Deployment $DEPLOY_NAME no tiene su réplica Ready todavía."
    echo "  Pistas: kubectl get pods -n $NAMESPACE"
    echo "          kubectl describe pods -n $NAMESPACE -l app=$DEPLOY_NAME"
    exit 1
  fi

  echo "RESUELTO: Deployment/$DEPLOY_NAME usa ahora serviceAccountName:"
  echo "$NEW_SA, que tiene permiso RBAC para listar pods, y el Pod está"
  echo "Running/Ready."
}

reset_lab() {
  echo ">> Reconstruyendo el laboratorio en estado sano ..."
  kubectl delete deployment "$DEPLOY_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  kubectl delete rolebinding "$RB_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  kubectl delete role "$ROLE_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  kubectl delete serviceaccount "$OLD_SA" "$NEW_SA" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  rm -rf "$LAB_DIR"

  scaffold_lab
  echo ">> Listo. Corré '$0 break' para volver a romperlo."
}

cleanup_lab() {
  echo ">> Borrando recursos de Kubernetes y $LAB_DIR ..."
  kubectl delete namespace "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  rm -rf "$LAB_DIR"
  echo ">> Limpieza completa."
}

usage() {
  cat <<EOF
Uso: $0 {break|check|reset|cleanup}
EOF
}

case "${1:-}" in
  break)   break_lab ;;
  check)   check_lab ;;
  reset)   reset_lab ;;
  cleanup) cleanup_lab ;;
  *)       usage; exit 1 ;;
esac
