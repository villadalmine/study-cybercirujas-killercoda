## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCION PASO A PASO (para el instructor / autocorreccion)

1. Observar el sintoma:
     kubectl get pods -n kcna-lab-debug
   -> STATUS: CrashLoopBackOff, RESTARTS subiendo.

2. Descartar que sea un problema de la aplicacion en si:
     kubectl logs -n kcna-lab-debug -l app=webapp --previous
   -> Los logs muestran a nginx arrancando sin errores. Esto es
      la pista clave: si el proceso arranca bien, el problema no
      esta en el codigo de la app sino en como Kubernetes decide
      si el pod esta "sano".

3. Revisar los eventos del pod, que es donde kubelet reporta
   fallas de probes:
     kubectl describe pod -n kcna-lab-debug -l app=webapp
   o
     kubectl get events -n kcna-lab-debug --sort-by=.metadata.creationTimestamp
   -> Se ven eventos tipo:
      "Liveness probe failed: Get http://<pod-ip>:9999/: dial tcp
       <pod-ip>:9999: connect: connection refused"
      "Killing container with id ...: Container failed liveness probe,
       will be restarted"

4. Diagnostico: el livenessProbe apunta al puerto 9999, pero nginx
   escucha en el puerto 80 (containerPort: 80). kubelet nunca logra
   conectarse, marca el probe como fallido, mata el contenedor y lo
   reinicia en loop -> CrashLoopBackOff, aunque la app nunca estuvo
   rota.

5. Corregir el recurso, alineando el puerto del probe con el puerto
   real del contenedor:
     kubectl edit deployment webapp -n kcna-lab-debug
   y cambiar:
     livenessProbe.httpGet.port: 9999   ->   80
   (alternativa equivalente: aplicar de nuevo el manifiesto con el
   puerto corregido via kubectl apply -f).

6. Confirmar la correccion:
     kubectl rollout status deployment/webapp -n kcna-lab-debug
     kubectl get pods -n kcna-lab-debug -w
   -> READY 1/1, STATUS Running, RESTARTS deja de aumentar.

7. Limpieza del laboratorio:
     kubectl delete namespace kcna-lab-debug
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/kcna/2.2/lab)
