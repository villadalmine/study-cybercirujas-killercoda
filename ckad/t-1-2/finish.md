## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCIÓN PASO A PASO (no mires hasta intentarlo)

--- Escenario 1: Deployment "web" pausado -----------------------------------
Diagnóstico: el rollout está en pausa, por eso el cambio de imagen quedó
escrito en el spec pero nunca se aplicó a los Pods.

  kubectl -n ckad-1-2-breakfix get deploy web -o jsonpath='{.spec.paused}'
  # -> true
  kubectl -n ckad-1-2-breakfix describe deploy web | grep -i progress
  # -> condición Progressing con reason: DeploymentPaused

Arreglo: reanudar el rollout y esperar a que termine.

  kubectl -n ckad-1-2-breakfix rollout resume deployment/web
  kubectl -n ckad-1-2-breakfix rollout status deployment/web

Lección CKAD: "rollout pause/resume" permite agrupar varios cambios en un
solo rollout; un Deployment pausado acepta ediciones pero no las despliega.

--- Escenario 2: CronJob "backup" suspendido --------------------------------
Diagnóstico: la columna SUSPEND está en True; el controller no crea Jobs.

  kubectl -n ckad-1-2-breakfix get cronjob backup
  # NAME    SCHEDULE      SUSPEND   ACTIVE   LAST SCHEDULE
  # backup  */1 * * * *   True      0        <none>

Arreglo: poner suspend en false (patch o edit) y esperar ~1 minuto.

  kubectl -n ckad-1-2-breakfix patch cronjob backup \
    -p '{"spec":{"suspend":false}}'
  kubectl -n ckad-1-2-breakfix get jobs -w

Truco de examen: para no esperar al schedule podés disparar un Job manual
desde el CronJob:

  kubectl -n ckad-1-2-breakfix create job backup-manual --from=cronjob/backup

Lección CKAD: CronJob es el workload correcto para tareas programadas;
"suspend: true" lo apaga sin borrarlo (útil en mantenimientos).

--- Escenario 3: DaemonSet "log-agent" sin nodes elegibles ------------------
Diagnóstico: el nodeSelector "role: logging" no coincide con ningún node,
así que DESIRED=0. Un DaemonSet solo agenda Pods en nodes que matcheen.

  kubectl -n ckad-1-2-breakfix get ds log-agent \
    -o jsonpath='{.spec.template.spec.nodeSelector}'
  kubectl get nodes --show-labels

Arreglo — opción A: etiquetar un node para que cumpla el selector.

  kubectl label node <nombre-del-node> role=logging

Arreglo — opción B: quitar el nodeSelector del DaemonSet para que corra
en todos los nodes (comportamiento clásico de un agente de logging).

  kubectl -n ckad-1-2-breakfix patch ds log-agent --type=json \
    -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'

Lección CKAD: DaemonSet es el workload correcto para "un Pod por node"
(agentes de logs, monitoring, CNI); su scheduling depende de labels,
selectors, taints y tolerations, no del campo replicas.

--- Repaso del tema 1.2: ¿qué workload elijo? -------------------------------
* Deployment: apps stateless con replicas y rolling updates.
* DaemonSet:  un Pod por node (o por subconjunto de nodes vía labels).
* Job:        tarea que corre hasta completarse una vez.
* CronJob:    Jobs en un horario (sintaxis cron).
* StatefulSet: identidad estable por Pod + storage persistente por replica.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckad/1.2/lab)
