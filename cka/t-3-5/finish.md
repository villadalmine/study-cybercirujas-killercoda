## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCIÓN PASO A PASO (spoiler - no se ejecuta, solo referencia)

--- Deployment web-quota (admission por LimitRange) ---

1) Diagnosticar:
     kubectl -n cka-3-5-lab get deploy web-quota
     kubectl -n cka-3-5-lab get rs -l app=web-quota
     kubectl -n cka-3-5-lab describe rs -l app=web-quota
     # Evento: "forbidden: [maximum cpu usage per Container is 150m, but limit is 300m]"
     kubectl -n cka-3-5-lab get limitrange cpu-cap -o yaml
     # spec.limits[0].max.cpu = 150m

2) Arreglar (dos caminos válidos, cualquiera de los dos sirve):
     # Opción A: bajar los resources del Deployment para que entren en el max
     kubectl -n cka-3-5-lab set resources deployment/web-quota \
       --containers=nginx --requests=cpu=100m --limits=cpu=150m

     # Opción B: subir el max del LimitRange para que soporte lo que pide el Deployment
     kubectl -n cka-3-5-lab edit limitrange cpu-cap
     # (subir spec.limits[0].max.cpu a 300m o más)

3) Confirmar:
     kubectl -n cka-3-5-lab rollout status deployment/web-quota


--- Deployment web-affinity (scheduling por nodeAffinity imposible) ---

1) Diagnosticar:
     kubectl -n cka-3-5-lab get pods -l app=web-affinity -o wide
     kubectl -n cka-3-5-lab describe pod -l app=web-affinity
     # Evento: "0/N nodes are available: N node(s) didn't match Pod's node affinity/selector."
     kubectl -n cka-3-5-lab get deployment web-affinity -o jsonpath='{.spec.template.spec.affinity}'
     # -> exige label lab.cka.io/tier=gpu-ultra
     kubectl get nodes --show-labels

2) Arreglar (dos caminos válidos, cualquiera de los dos sirve):
     # Opción A: etiquetar un nodo real con el label que la afinidad exige
     kubectl label node <NOMBRE_DEL_NODO> lab.cka.io/tier=gpu-ultra

     # Opción B: editar el Deployment para que la afinidad apunte a un label
     # que sí existe en el cluster
     kubectl -n cka-3-5-lab edit deployment web-affinity
     # (ajustar spec.template.spec.affinity.nodeAffinity...matchExpressions
     #  a un key/value que un nodo real tenga, p. ej. kubernetes.io/hostname)

3) Confirmar:
     kubectl -n cka-3-5-lab rollout status deployment/web-affinity

--- Verificación final ---
     ./cka-3.5-admission-scheduling.sh check

--- Limpieza del lab ---
     ./cka-3.5-admission-scheduling.sh cleanup
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cka/3.5/lab)
