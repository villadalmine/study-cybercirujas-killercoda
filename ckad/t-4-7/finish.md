## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCION PASO A PASO (comentada - no se ejecuta)

1. Ver el estado de los Pods:
     kubectl get pods -n ckad-4-7-lab

   No hay ningún Pod para el Deployment "report-agent". El Pod anterior
   se borró (strategy Recreate) y el reemplazo nunca se creó -- no es un
   crash de la app, la creación del Pod fue rechazada antes de existir.

2. Ver el ReplicaSet y sus eventos:
     kubectl get rs -n ckad-4-7-lab
     kubectl describe rs -n ckad-4-7-lab -l app=report-agent

   En Events del ReplicaSet más nuevo aparece algo como:
     Error creating: pods "report-agent-xxxxx" is forbidden: error looking
     up service account ckad-4-7-lab/report-agent: serviceaccount
     "report-agent" not found

   Esto lo rechaza el admission controller ServiceAccount del apiserver:
   valida que el serviceAccountName del Pod exista en el namespace ANTES
   de admitir el Pod. Si no existe, el Pod ni se crea.

3. Confirmar qué ServiceAccounts existen realmente ahora:
     kubectl get sa -n ckad-4-7-lab

   Vas a ver "default" y "report-agent-v2" -- "report-agent" (el que usa
   el Deployment) ya NO existe.

4. Revisar el contexto del equipo:
     cat $LAB_DIR/notas-sprint.md

   Confirma que la rotación (report-agent -> report-agent-v2) es
   definitiva: la corrección va del lado del Deployment, no de recrear
   el ServiceAccount viejo.

5. Corregir el Deployment: el Pod template tiene que usar el
   ServiceAccount nuevo. Con kubectl edit:
     kubectl edit deployment report-agent -n ckad-4-7-lab

   Y cambiar:
     spec:
       template:
         spec:
           serviceAccountName: report-agent      # <- viejo, no existe
   por:
     spec:
       template:
         spec:
           serviceAccountName: report-agent-v2   # <- nuevo

   Alternativa sin editor interactivo (mismo resultado):
     kubectl patch deployment report-agent -n ckad-4-7-lab --type='json' -p='[
       {"op":"replace",
        "path":"/spec/template/spec/serviceAccountName",
        "value":"report-agent-v2"}
     ]'

   serviceAccountName es parte del Pod template, así que modificarlo
   dispara un rollout nuevo automáticamente -- no hace falta un restart
   manual.

6. Confirmar que el rollout termina:
     kubectl rollout status deployment/report-agent -n ckad-4-7-lab
     kubectl get pods -n ckad-4-7-lab

   El Pod nuevo debería quedar 1/1 Running.

7. Confirmar que el ServiceAccount nuevo realmente tiene los permisos
   RBAC que el agente necesita (get/list/watch sobre pods):
     kubectl auth can-i list pods -n ckad-4-7-lab \
       --as=system:serviceaccount:ckad-4-7-lab:report-agent-v2

   Tiene que devolver "yes" -- el RoleBinding "pod-reader-binding" ya
   estaba armado para report-agent-v2 desde el break, así que no hace
   falta tocar RBAC, solo el Deployment.

8. Validar automáticamente:
     ./break_fix.sh check
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckad/4.7/lab)
