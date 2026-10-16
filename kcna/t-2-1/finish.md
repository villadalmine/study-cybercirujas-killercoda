## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCIÓN PASO A PASO (spoiler - no leer antes de intentarlo)

1) Diagnosticar que el problema es de "descubrimiento", no de la app:
     kubectl -n kcna-2-1-app-delivery-lab get pods -o wide
     -> los 2 pods de web-frontend están Running y READY 1/1.

2) Confirmar que el Service no tiene endpoints:
     kubectl -n kcna-2-1-app-delivery-lab get endpoints web-frontend-svc
     -> ENDPOINTS: <none>

3) Comparar el selector del Service contra las labels reales de los pods:
     kubectl -n kcna-2-1-app-delivery-lab get svc web-frontend-svc \
       -o jsonpath='{.spec.selector}{"\n"}'
     -> {"app":"web-frontend-typo"}
     kubectl -n kcna-2-1-app-delivery-lab get pods --show-labels
     -> app=web-frontend
     El selector no matchea ninguna label: por eso no hay endpoints.

4) Corregir el selector del Service para que vuelva a matchear
   las labels reales de los pods (sin tocar el Deployment):
     kubectl -n kcna-2-1-app-delivery-lab patch service web-frontend-svc \
       --type merge -p '{"spec":{"selector":{"app":"web-frontend"}}}'

5) Verificar la reparación:
     kubectl -n kcna-2-1-app-delivery-lab get endpoints web-frontend-svc
     -> debe listar 2 IPs (una por pod)
     kubectl -n kcna-2-1-app-delivery-lab exec net-tester -- \
       curl -s -o /dev/null -w '%{http_code}\n' http://web-frontend-svc/
     -> debe imprimir 200

Concepto clave para el examen KCNA:
  Un Service NO enruta por nombre de Pod ni por Deployment: usa
  spec.selector para armar (vía el controller de Endpoints/EndpointSlices)
  la lista de IPs de Pods a las que hace load balancing. Un typo en el
  selector -o en las labels del template del Deployment- deja al Service
  "vacío" aunque los Pods estén perfectamente sanos.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/kcna/2.1/lab)
