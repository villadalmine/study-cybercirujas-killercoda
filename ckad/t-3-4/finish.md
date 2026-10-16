## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
=== SOLUCIÓN PASO A PASO (no la mires hasta haber investigado) ===

1. kubectl get pods -n ckad-3-4-debug-lab
   -> el pod aparece Running pero 0/1 Ready, sin restarts.

2. kubectl describe pod <pod> -n ckad-3-4-debug-lab
   -> en Events se ve algo como:
      "Readiness probe failed: dial tcp <ip>:8080: connect: connection refused"
   Esto ya descarta que el proceso se haya caído (no hay restarts).

3. kubectl logs <pod> -n ckad-3-4-debug-lab
   -> los logs de nginx están limpios (arrancó bien). Esto es la pista
      clave del ejercicio: cuando los logs están sanos pero el pod no
      queda Ready, el problema casi siempre es de red/puertos, no de la
      aplicación.

4. kubectl exec -it <pod> -n ckad-3-4-debug-lab -- sh
   -> dentro del contenedor: "wget -qO- localhost:80" funciona,
      "wget -qO- localhost:8080" falla. Confirma que nginx escucha en
      el puerto 80 por defecto, sin importar lo que diga containerPort.

5. Causa raíz: el campo "containerPort" del Deployment es solo
   documentación (no hace que el proceso escuche ahí). Alguien asumió
   que nginx escuchaba en 8080 y configuró el readinessProbe y el
   targetPort del Service en 8080, pero la imagen nginx:1.25 escucha
   en el puerto 80.

6. Arreglo (elegí una forma, ambas son válidas en el examen):

   a) Editar en vivo:
      kubectl edit deployment webshop -n ckad-3-4-debug-lab
      (cambiar containerPort y readinessProbe.httpGet.port a 80)
      kubectl edit service webshop -n ckad-3-4-debug-lab
      (cambiar targetPort a 80)

   b) O con patch directo:
      kubectl patch deployment webshop -n ckad-3-4-debug-lab --type='json' -p='[
        {"op":"replace","path":"/spec/template/spec/containers/0/ports/0/containerPort","value":80},
        {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":80}
      ]'
      kubectl patch service webshop -n ckad-3-4-debug-lab -p '{"spec":{"ports":[{"port":80,"targetPort":80}]}}'

7. Verificar:
   kubectl get pods -n ckad-3-4-debug-lab        -> 1/1 Running
   kubectl get endpoints webshop -n ckad-3-4-debug-lab -> IP:80 presente
   kubectl exec -n ckad-3-4-debug-lab tester -- wget -qO- http://webshop.ckad-3-4-debug-lab.svc.cluster.local
      -> devuelve el HTML de bienvenida de nginx

8. Limpieza: ./este-script.sh cleanup
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckad/3.4/lab)
