## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCION PASO A PASO (no leer antes de intentarlo)

1. kubectl get pods -n kcna-obs-lab
   Se ve STATUS CrashLoopBackOff y RESTARTS creciendo sin parar.

2. kubectl describe pod -l app=webshop-frontend -n kcna-obs-lab
   En la sección Events aparece algo como:
     Warning  Unhealthy  ...  Liveness probe failed: Get
     "http://<pod-ip>:8080/": dial tcp <pod-ip>:8080:
     connect: connection refused
     Normal   Killing    ...  Container nginx failed liveness probe,
     will be restarted

3. kubectl logs -l app=webshop-frontend -n kcna-obs-lab
   (y con --previous) muestran que nginx arrancó bien y sirvió
   tráfico normal: el problema NO está en la aplicación.

4. Root cause: el livenessProbe apunta al puerto 8080, pero nginx
   solo escucha en el puerto 80 (el mismo que declara containerPort
   y que usa el readinessProbe, que sí funciona). Con
   failureThreshold=1, la primera vez que el kubelet intenta el
   chequeo de liveness y se encuentra con "connection refused",
   mata el contenedor de inmediato -> CrashLoopBackOff.

5. Fix: corregir el puerto del livenessProbe para que coincida con
   el puerto real de la aplicación (80). Como es un Deployment,
   alcanza con reaplicar el manifiesto corregido o editarlo
   directamente:

     kubectl edit deployment webshop-frontend -n kcna-obs-lab
     # cambiar spec.template.spec.containers[0].livenessProbe.httpGet.port
     # de 8080 a 80

   o bien, reaplicando el YAML con el valor corregido:

     kubectl apply -f deployment-corregido.yaml

   Cualquiera de las dos opciones dispara un nuevo rollout: el
   ReplicaSet viejo (con el pod en crashloop) se reemplaza por uno
   nuevo con el probe corregido.

6. Confirmar con:
     kubectl rollout status deployment/webshop-frontend -n kcna-obs-lab
     kubectl get pods -n kcna-obs-lab -w
   y verificar que RESTARTS deja de crecer y el pod queda
   READY 1/1, STATUS Running.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/kcna/2.3/lab)
