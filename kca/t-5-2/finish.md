## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUCION PASO A PASO  (no leer hasta haber intentado el fix)

 PASO 0 — Reproducir y capturar la evidencia, antes de tocar nada

   $ kubectl -n kca52-dev run demo --image=registry.k8s.io/pause:3.9 --dry-run=server
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource Pod/kca52-dev/demo was blocked due to the following policies

   kca52-owner-required:
     owner-required-prod-frontend: 'failed to substitute variables in preconditions:
       failed to resolve request.object.metadata.labels.tier: JMESPath query failed:
       Unknown key "tier" in path'

   Y en los logs del controlador:

   $ kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=100 \
       | grep -iE 'precondition|variable'
   ... "failed to evaluate preconditions" policy=kca52-owner-required
       rule=owner-required-prod-frontend error="Unknown key \"tier\" in path"

   Lectura correcta del sintoma: el nombre del webhook termina en "-fail".
   Eso es failurePolicy=Fail. Un error de evaluacion en una precondition NO
   se degrada a "la regla no aplica": se degrada a DENY. La policy quedo
   acoplada a la disponibilidad de una label que la mayoria de los Pods
   no tiene.

 PASO 1 — BUG 1: clave inexistente en la precondition

   Roto:
     - key: "{{ request.object.metadata.labels.tier }}"
       operator: Equals
       value: frontend

   JMESPath sobre un objeto sin la clave 'labels' (o sin 'tier' dentro de
   ella) no devuelve "vacio": la sustitucion falla. La forma canonica de
   darle un valor por defecto es el operador `||` de JMESPath dentro de la
   propia variable:

   Corregido:
     - key: "{{ request.object.metadata.labels.tier || '' }}"
       operator: Equals
       value: frontend

   Notas de produccion:
     * Si la label tuviera puntos o barras hay que citarla:
         {{ request.object.metadata.labels."app.kubernetes.io/name" || '' }}
     * Alternativa declarativa equivalente, y a menudo mejor, es no usar
       precondition y filtrar en el match con un selector, porque el
       API server ya lo resuelve sin evaluar variables:
         match:
           any:
             - resources:
                 kinds: [Pod]
                 selector:
                   matchLabels:
                     tier: frontend
       Regla practica: lo que `match`/`exclude` pueden expresar, expresalo
       ahi; las preconditions son para lo que match no alcanza (operacion,
       usuario, comparaciones numericas, JMESPath sobre el spec).
     * Kyverno documenta el patron en:
         https://kyverno.io/docs/writing-policies/preconditions/
         https://kyverno.io/docs/writing-policies/variables/

 PASO 2 — BUG 2: la comparacion que nunca es verdadera

   Roto:
     - key: "{{ request.namespace }}"
       operator: Equals
       value: prod            # el namespace real es "kca52-prod"

   Este es el falso negativo silencioso: `kubectl get cpol` reporta
   READY=true, no hay errores en los logs y el PolicyReport queda en cero.
   La policy existe, se evalua, y siempre se salta.

   Corregido (uso AnyIn, que escala a varios namespaces sin duplicar reglas):
     - key: "{{ request.namespace }}"
       operator: AnyIn
       value:
         - kca52-prod

   Verificacion honesta de que una policy protege algo: probar el caso que
   DEBE fallar, no solo el que debe pasar.

     $ kubectl -n kca52-prod run bad --image=registry.k8s.io/pause:3.9 \
         --labels tier=frontend --dry-run=server
     Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

     resource Pod/kca52-prod/bad was blocked due to the following policies

     kca52-owner-required:
       owner-required-prod-frontend: 'validation error: Los Pods frontend de
         produccion deben declarar la label ''owner'' ...'

     $ kubectl -n kca52-prod run good --image=registry.k8s.io/pause:3.9 \
         --labels tier=frontend,owner=sre-platform --dry-run=server
     pod/good created (server dry run)

 PASO 3 — policy-a.yaml corregida, completa

   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: kca52-owner-required
   spec:
     validationFailureAction: Enforce     # Kyverno < 1.13
     background: false                    # la regla solo tiene sentido en admision
     rules:
       - name: owner-required-prod-frontend
         match:
           any:
             - resources:
                 kinds:
                   - Pod
                 namespaces:
                   - kca52-dev
                   - kca52-prod
         preconditions:
           all:
             - key: "{{ request.object.metadata.labels.tier || '' }}"
               operator: Equals
               value: frontend
             - key: "{{ request.namespace }}"
               operator: AnyIn
               value:
                 - kca52-prod
         validate:
           # failureAction: Enforce       # Kyverno >= 1.13 (reemplaza al de spec)
           message: >-
             Los Pods frontend de produccion deben declarar la label 'owner'.
           pattern:
             metadata:
               labels:
                 owner: "?*"

   Aplicar y esperar la reconfiguracion de webhooks:

     $ kubectl apply -f /tmp/kca-5.2-preconditions/policy-a.yaml
     clusterpolicy.kyverno.io/kca52-owner-required configured
     $ sleep 6
     $ kubectl get cpol kca52-owner-required
     NAME                    ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE
     kca52-owner-required    true        false        Enforce           True    3m

 PASO 4 — BUG 3: variables de admision con background=true

   Sintoma al aplicar policy-b.yaml:

     $ kubectl apply -f /tmp/kca-5.2-preconditions/policy-b.yaml
     Error from server: error when creating "policy-b.yaml": admission webhook
     "validate-policy.kyverno.svc" denied the request: spec.rules[0]:
     "kca52-no-default-sa" - variable "request.userInfo.username" is not allowed
     in background mode. Set spec.background=false

   Causa: el background controller reevalua policies contra recursos que ya
   existen en etcd. En ese contexto no hay AdmissionReview, por lo tanto no
   existen request.userInfo, request.roles, request.clusterRoles,
   serviceAccountName ni serviceAccountNamespace, y request.operation vale
   BACKGROUND. Kyverno lo valida en tiempo de creacion de la policy en lugar
   de fallar en silencio durante cada scan.

   Fix: declarar que la policy es solo de admision.

     spec:
       background: false
       rules:
         - name: no-default-sa-for-humans
           preconditions:
             all:
               - key: "{{ request.userInfo.username }}"
                 operator: NotEquals
                 value: "system:serviceaccount:kyverno:kyverno-background-controller"

   Aplicar:
     $ sed -i 's/^  background: true$/  background: false/' \
           /tmp/kca-5.2-preconditions/policy-b.yaml
     $ kubectl apply -f /tmp/kca-5.2-preconditions/policy-b.yaml
     clusterpolicy.kyverno.io/kca52-no-default-sa created

   Consecuencia consciente del trade-off: con background=false esta policy no
   genera PolicyReports para los Pods preexistentes. Si tambien necesitas
   visibilidad historica, el patron correcto son DOS policies: una de
   admision (background=false, con las variables de request) y otra de
   auditoria (background=true, Audit, escrita solo sobre el objeto).

 PASO 5 — Cierre

     $ ./kca-5.2-preconditions-breakfix.sh verify
     [PASS] Pod sin labels en kca52-dev es admitido
     [PASS] Pod tier=frontend sin owner en kca52-dev es admitido
     [PASS] Pod sin labels en kca52-prod es admitido
     [PASS] Pod tier=batch sin owner en kca52-prod es admitido
     [PASS] Pod tier=frontend SIN owner en kca52-prod es RECHAZADO
     [PASS] Pod tier=frontend CON owner en kca52-prod es admitido
     ...
     RESULTADO: 11/11 — laboratorio superado.

     $ ./kca-5.2-preconditions-breakfix.sh clean

 LO QUE HAY QUE LLEVARSE AL EXAMEN Y A PRODUCCION
  1. Las preconditions se evaluan DESPUES de match/exclude y ANTES del cuerpo
     de la regla. `all` exige que todas las condiciones sean true; `any`, al
     menos una; pueden anidarse.
  2. Una variable que no resuelve NO equivale a "false": rompe la evaluacion,
     y con failurePolicy=Fail eso es un DENY. Defendete siempre con
     `|| ''`, `|| 'default'` o `|| []`.
  3. Los operadores comparan tipos: Equals / NotEquals / AnyIn / AllIn /
     AnyNotIn / AllNotIn / GreaterThan(OrEquals) / LessThan(OrEquals) /
     DurationGreaterThan / DurationLessThan. Comparar un numero con "3"
     entre comillas es un error de evaluacion, no una comparacion falsa.
  4. Lo que se puede filtrar en `match` (kinds, namespaces, selectors,
     subjects) no deberia filtrarse en preconditions.
  5. request.userInfo / request.roles / request.clusterRoles /
     serviceAccountName / serviceAccountNamespace son exclusivas de admision:
     exigen background=false.
  6. Toda policy nueva se prueba con el caso que DEBE fallar. "READY=true y
     cero violaciones" tambien es el aspecto de una policy que no evalua nada.
     La CLI `kyverno apply <policy> --resource <recurso>` permite hacerlo en
     CI, sin cluster: https://kyverno.io/docs/kyverno-cli/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/kca/5.2/lab)
