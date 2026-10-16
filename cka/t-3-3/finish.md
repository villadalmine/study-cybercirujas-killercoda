## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCIÓN PASO A PASO (comentada - no se ejecuta)

El HPA no puede calcular utilización porque el contenedor "revenue-api"
no tiene definido resources.requests.cpu: la utilización se calcula como
(uso actual / request), así que sin request no hay base de cálculo.

1) Confirmar el diagnóstico:

     kubectl describe hpa revenue-api-hpa -n autoscaling-lab
     # Ver el evento: "missing request for cpu on container revenue-api"

2) Agregar el request de CPU faltante al Deployment (sin recrearlo):

     kubectl set resources deployment/revenue-api -n autoscaling-lab \
       --containers=revenue-api --requests=cpu=200m

   (equivalente editando el manifiesto con `kubectl edit deployment
   revenue-api -n autoscaling-lab` y agregando bajo el contenedor:

     resources:
       requests:
         cpu: 200m
   )

3) Esperar el rollout y confirmar que los Pods nuevos ya tienen el request:

     kubectl rollout status deployment/revenue-api -n autoscaling-lab
     kubectl get pods -n autoscaling-lab -o jsonpath='{.items[0].spec.containers[0].resources}'

4) Confirmar que el HPA ya calcula utilización real:

     kubectl get hpa revenue-api-hpa -n autoscaling-lab -w
     # TARGETS debería pasar de "<unknown>/50%" a algo como "1%/50%"

5) (Opcional) Generar carga para ver el scale-up en acción:

     kubectl run load-generator --rm -it --image=busybox:1.36 \
       --restart=Never -n autoscaling-lab -- \
       /bin/sh -c "while true; do wget -q -O- http://revenue-api; done"

     kubectl get hpa revenue-api-hpa -n autoscaling-lab -w
     # Con el tiempo REPLICAS debería subir por encima de 2
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cka/3.3/lab)
