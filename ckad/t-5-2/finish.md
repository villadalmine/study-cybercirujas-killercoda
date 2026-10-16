## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCIÓN PASO A PASO (leer solo después de intentar el
diagnóstico por tu cuenta)

Flujo general de troubleshooting para "acceso via Service":

  1. kubectl -n ckad-5-2-lab get pods -o wide
     ¿Hay pods corriendo? ¿Cuántos están Ready (columna READY,
     ej. 1/1 vs 0/1)? Si no hay pods, el problema está en el
     Deployment, no en el Service.

  2. kubectl -n ckad-5-2-lab get endpoints web-svc
     Un Service solo enruta tráfico a pods que:
       a) coinciden con su spec.selector, y
       b) están en estado Ready.
     Si Endpoints está vacío (<none>), el problema es selector
     o falta de pods Ready. Si Endpoints tiene IPs pero con un
     puerto raro, el problema es targetPort.

  3. kubectl -n ckad-5-2-lab describe svc web-svc
     Mirá el campo "Selector:" y compará contra las labels
     reales de los pods (paso 4).

  4. kubectl -n ckad-5-2-lab get pod -l app=web --show-labels
     Si este comando no devuelve nada pero "get pods" sí
     muestra pods, es porque el selector del Service (o las
     labels del pod) no coinciden.

  5. kubectl -n ckad-5-2-lab describe pod <nombre-de-un-pod>
     Mirá la sección "Events" al final: ahí aparecen fallos de
     readiness probe con el detalle exacto (path, status code).

Causa raíz según qué falla te haya tocado:

--- CASO A: selector mismatch -----------------------------------
  Diagnóstico: "describe svc web-svc" muestra Selector:
  app=web-legacy, pero los pods tienen label app=web.
  "get endpoints web-svc" está vacío.
  Arreglo:
    kubectl -n ckad-5-2-lab patch svc web-svc --type=merge \
      -p '{"spec":{"selector":{"app":"web"}}}'

--- CASO B: targetPort mismatch ----------------------------------
  Diagnóstico: "get endpoints web-svc -o yaml" muestra el puerto
  8080 en las addresses, pero el contenedor nginx solo escucha
  en el 80 (containerPort: 80). curl da "connection refused".
  Arreglo:
    kubectl -n ckad-5-2-lab patch svc web-svc --type=json \
      -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":80}]'

--- CASO C: Deployment escalado a 0 --------------------------------
  Diagnóstico: "get deployment web-deploy" muestra 0/0 réplicas.
  "get pods -l app=web" no devuelve nada. El Service está bien
  configurado, pero no hay pods a los que enrutar.
  Arreglo:
    kubectl -n ckad-5-2-lab scale deployment web-deploy --replicas=2

--- CASO D: readinessProbe rota ------------------------------------
  Diagnóstico: "get pods -l app=web" muestra pods Running pero
  0/1 en READY. "describe pod <pod>" muestra en Events algo como
  "Readiness probe failed: HTTP probe failed with statuscode: 404"
  contra el path /no-existe-404. Como no están Ready, no entran
  en los Endpoints del Service.
  Arreglo:
    kubectl -n ckad-5-2-lab patch deployment web-deploy --type=json \
      -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}]'
    kubectl -n ckad-5-2-lab rollout status deployment/web-deploy

Verificación final (para cualquiera de los 4 casos):
    ./ckad-5.2-break-fix.sh check
  Debe imprimir "RESULTADO: PASS".
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckad/5.2/lab)
