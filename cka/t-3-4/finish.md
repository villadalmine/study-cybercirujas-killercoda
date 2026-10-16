## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCIÓN PASO A PASO (comentada - no la leas antes de intentarlo vos mismo)

1) Diagnosticar el síntoma:
     kubectl get pods -n cka-3-4-selfheal
     -> STATUS: CrashLoopBackOff, RESTARTS creciendo en los 3 Pods.

2) Confirmar la causa raíz con los eventos del Pod:
     kubectl describe pod <pod> -n cka-3-4-selfheal
     -> En la sección Events vas a ver algo como:
        "Liveness probe failed: Get http://10.x.x.x:9999/nope-no-existe:
         dial tcp 10.x.x.x:9999: connect: connection refused"
        "Killing container with id ...: Container failed liveness probe,
         will be restarted"
     Esto confirma que el kubelet está matando el container porque el
     livenessProbe apunta a un puerto/path que no existe, NO porque la
     app esté rota.

3) Revisar la configuración actual del primitivo roto:
     kubectl get deployment webapp -n cka-3-4-selfheal -o yaml \
       | grep -A6 livenessProbe
     -> path: /nope-no-existe, port: 9999, periodSeconds: 2

4) Arreglar el livenessProbe para que apunte al puerto/path reales
   que expone el container (nginx en el puerto 80, path "/"):

     kubectl patch deployment webapp -n cka-3-4-selfheal --type='json' -p='[
       {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/httpGet/path", "value": "/"},
       {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/httpGet/port", "value": 80},
       {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/periodSeconds", "value": 5}
     ]'

   (Alternativa equivalente: kubectl edit deployment webapp -n cka-3-4-selfheal
    y corregir a mano los mismos tres campos bajo livenessProbe.)

5) Verificar que el ReplicaSet converge al estado deseado (primitivo de
   self-healing funcionando correctamente esta vez):
     kubectl rollout status deployment/webapp -n cka-3-4-selfheal --timeout=60s
     kubectl get pods -n cka-3-4-selfheal
     -> 3/3 Pods READY, STATUS Running, RESTARTS estable (no sigue creciendo).

6) Confirmación automatizada: ./break-fix-3.4.sh check
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cka/3.4/lab)
