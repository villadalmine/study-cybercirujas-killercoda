## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCION PASO A PASO (spoilers — intentalo primero)

---- INCIDENTE 1: Pending por Insufficient cpu -------------------------------

1. Diagnóstico: el describe del pod muestra en Events algo como
   "0/1 nodes are available: 1 Insufficient cpu."
   El pod pide requests.cpu: "128" (¡128 cores enteros!) y ningún node del
   lab tiene esa capacidad libre. El scheduler usa los REQUESTS (no el uso
   real) para decidir dónde colocar un pod; si ningún node los puede
   garantizar, el pod queda Pending indefinidamente.

2. Arreglo: bajá los requests a valores razonables. Lo más rápido en el
   examen es kubectl set resources (dispara un rollout automáticamente):

     kubectl set resources deployment/web-frontend -n ckad44-lab \
       --requests=cpu=100m,memory=128Mi --limits=cpu=500m,memory=256Mi

   Alternativa: kubectl edit deployment web-frontend -n ckad44-lab
   y corregir spec.template.spec.containers[0].resources a mano.

3. Verificación: kubectl get pods -n ckad44-lab -w  ->  Running 1/1.

---- INCIDENTE 2: OOMKilled / CrashLoopBackOff --------------------------------

1. Diagnóstico: kubectl describe pod muestra
   Last State: Terminated / Reason: OOMKilled / Exit Code: 137.
   El limit de memoria es un tope DURO: si el proceso lo supera, el kernel
   lo mata (OOM killer) y kubelet lo reinicia una y otra vez
   (CrashLoopBackOff). Acá el proceso reserva ~150M y el limit es 100Mi.

2. Arreglo: subí el limit por encima de lo que el proceso necesita, con
   margen, y alineá el request con el consumo real:

     kubectl set resources deployment/cache-worker -n ckad44-lab \
       --requests=memory=150Mi --limits=memory=250Mi

3. Verificación: kubectl get pods -n ckad44-lab -w
   El pod nuevo debe quedar Running y la columna RESTARTS dejar de crecer.
   Regla mental para el examen: OOMKilled + 137 = problema de memory limit,
   no un bug de la aplicación.

---- INCIDENTE 3: replica bloqueada por la ResourceQuota ----------------------

1. Diagnóstico: el pod que falta NO existe, así que no hay pod que describir.
   Cuando una quota rechaza la creación, el error queda en el ReplicaSet:

     kubectl describe rs -n ckad44-quota

   En Events vas a ver algo como:
   "forbidden: exceeded quota: cuota-equipo, requested: requests.cpu=400m,
    used: requests.cpu=800m, limited: requests.cpu=1"

   La cuenta: la quota permite requests.cpu = 1 (1000m) en el namespace.
   Dos pods de 400m ya usan 800m; el tercero pediría 1200m en total y la
   admission control lo rechaza.

2. Arreglo (sin tocar la quota): bajá el request por pod para que las 3
   replicas entren en 1000m, es decir, 333m como máximo por pod:

     kubectl set resources deployment/api-backend -n ckad44-quota \
       --requests=cpu=250m

   (3 x 250m = 750m <= 1000m, y los limits 3 x 600m = 1800m <= 2000m.)

   Nota fina: este deployment usa strategy: Recreate a propósito. Con un
   RollingUpdate, el pod nuevo se crea ANTES de borrar los viejos, y si la
   quota ya está casi llena el rollout se puede trabar (el pod nuevo también
   es rechazado). Si te pasa en un caso real: kubectl scale --replicas=0,
   aplicás el cambio y volvés a escalar.

3. Verificación:
     kubectl get deploy api-backend -n ckad44-quota   -> READY 3/3
     kubectl describe resourcequota cuota-equipo -n ckad44-quota
     (Used: requests.cpu 750m sobre Hard: 1)

---- Limpieza final -----------------------------------------------------------

     ./break-fix.sh clean
     (equivale a: kubectl delete ns ckad44-lab ckad44-quota)
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckad/4.4/lab)
