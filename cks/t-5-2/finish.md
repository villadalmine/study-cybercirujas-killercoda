## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
===== SOLUTION =============================================================
Do not read this until you have tried. Every command below is copy-pasteable.

STEP 0 — Triage: is it authentication or authorization?
  kubectl -n payments logs deploy/checkout --tail=3
    ... RESULT=000 stage=auth detail=no-serviceaccount-token-mounted

  kubectl -n payments exec deploy/checkout -- ls -l /var/run/secrets/kubernetes.io/serviceaccount
    ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory
    command terminated with exit code 1

  No token file => the request reaches the API server as system:anonymous.
  RBAC is irrelevant while the identity itself is missing.

STEP 1 — Restore the workload identity (fault 1)
  kubectl -n payments get sa checkout-sa -o yaml | grep -i automount
    automountServiceAccountToken: false

  Re-enable it (either drop the field or set it to true):
    kubectl -n payments patch sa checkout-sa --type=merge \
      -p '{"automountServiceAccountToken": true}'

  Token projection is decided at Pod admission, so the running Pod will never
  get a token. Replace it:
    kubectl -n payments rollout restart deploy/checkout
    kubectl -n payments rollout status  deploy/checkout --timeout=120s

  kubectl -n payments logs deploy/checkout --tail=2
    ... RESULT=403 stage=authz detail={"kind":"Status", ... "configmaps
    \"checkout-config\" is forbidden: User
    \"system:serviceaccount:payments:checkout-sa\" cannot get resource
    \"configmaps\" in API group \"\" in the namespace \"payments\"" ...

  Progress: authenticated, not authorized. 401 -> 403 is the signal.

STEP 2 — Ask the authorizer directly
  kubectl auth can-i --list --as=system:serviceaccount:payments:checkout-sa -n payments
    Resources          Non-Resource URLs   Resource Names   Verbs
    selfsubjectreviews []                  []               [create]
    ...
    secrets            []                  [payments-db]    [get list]

  Two defects are visible at once: the SA has rights on Secrets (it must not)
  and none on ConfigMaps (it must). Walk the chain backwards.

  kubectl -n payments get rolebinding checkout-config-reader -o yaml
    subjects:
    - kind: ServiceAccount
      name: checkout-sa
      namespace: default        <-- wrong namespace: this subject is nobody
    roleRef:
      kind: Role
      name: checkout-config-reader

  Note: the SA listing above still showed secrets because `auth can-i --list`
  aggregates every binding that matches; re-run it after each fix.

STEP 3 — Fix the RoleBinding subject (fault 2)
  roleRef is immutable; subjects are not, so a patch is enough:
    kubectl -n payments patch rolebinding checkout-config-reader --type=merge \
      -p '{"subjects":[{"kind":"ServiceAccount","name":"checkout-sa","namespace":"payments"}]}'

  Equivalent declarative form (recreate if you prefer):
    kubectl -n payments delete rolebinding checkout-config-reader
    kubectl -n payments create rolebinding checkout-config-reader \
      --role=checkout-config-reader \
      --serviceaccount=payments:checkout-sa

STEP 4 — Fix the Role rules (fault 3)
  kubectl -n payments describe role checkout-config-reader
    PolicyRule:
      Resources  Non-Resource URLs  Resource Names  Verbs
      secrets    []                 [payments-db]   [get list]

  Replace the rule with the minimum the application actually issues: a single
  GET on one named object.

    cat <<'EOF' | kubectl apply -f -
    apiVersion: rbac.authorization.k8s.io/v1
    kind: Role
    metadata:
      name: checkout-config-reader
      namespace: payments
    rules:
      - apiGroups: [""]
        resources: ["configmaps"]
        resourceNames: ["checkout-config"]
        verbs: ["get"]
    EOF

  Imperative equivalent:
    kubectl -n payments create role checkout-config-reader \
      --verb=get --resource=configmaps --resource-name=checkout-config \
      --dry-run=client -o yaml | kubectl apply -f -

  Why resourceNames and not just `get configmaps`: the pod reads ONE object.
  Granting the resource type would also expose billing-config and every future
  ConfigMap in the namespace. Caveat to remember for the exam: resourceNames
  cannot restrict `list`, `watch` or `create` — a client that needs to list is
  a client you cannot scope by name.

  RBAC is evaluated per request, so no restart is needed:
    sleep 12; kubectl -n payments logs deploy/checkout --tail=2
      ... RESULT=200 stage=ready detail=configmap/checkout-config-loaded

  Confirm the negatives too:
    kubectl auth can-i get configmaps/checkout-config --as=system:serviceaccount:payments:checkout-sa -n payments   # yes
    kubectl auth can-i get configmaps/billing-config  --as=system:serviceaccount:payments:checkout-sa -n payments   # no
    kubectl auth can-i list configmaps                --as=system:serviceaccount:payments:checkout-sa -n payments   # no
    kubectl auth can-i get secrets/payments-db        --as=system:serviceaccount:payments:checkout-sa -n payments   # no

STEP 5 — Remove standing cluster-admin and re-grant the minimum (fault 4)
  Find it:
    kubectl get clusterrolebinding -o wide | awk 'NR==1 || $2=="ClusterRole/cluster-admin"'
      NAME                      ROLE                        AGE  USERS  GROUPS  SERVICEACCOUNTS
      cluster-admin             ClusterRole/cluster-admin   30d          system:masters
      legacy-ops-cluster-admin  ClusterRole/cluster-admin   4m                   payments/deploy-bot

    kubectl auth can-i --list --as=system:serviceaccount:payments:deploy-bot
      Resources  Non-Resource URLs  Resource Names  Verbs
      *.*        []                 []              [*]

  A cluster-admin binding cannot be narrowed — delete it. Do NOT touch the
  built-in `cluster-admin` binding to system:masters.
    kubectl delete clusterrolebinding legacy-ops-cluster-admin

  Re-grant only what the CI robot does — patch Deployments in one namespace:
    cat <<'EOF' | kubectl apply -f -
    apiVersion: rbac.authorization.k8s.io/v1
    kind: Role
    metadata:
      name: deployment-patcher
      namespace: payments
    rules:
      - apiGroups: ["apps"]
        resources: ["deployments"]
        verbs: ["get", "list", "watch", "patch"]
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: RoleBinding
    metadata:
      name: deployment-patcher
      namespace: payments
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: Role
      name: deployment-patcher
    subjects:
      - kind: ServiceAccount
        name: deploy-bot
        namespace: payments
    EOF

  Note the deliberate omissions: no "delete", no "create", no
  deployments/scale unless the pipeline really scales, and a Role (namespaced)
  instead of a ClusterRole. A ClusterRole bound with a RoleBinding would also
  work and is reusable across namespaces — but a ClusterRole bound with a
  ClusterRoleBinding is what turns a per-namespace grant into a cluster-wide
  one by accident.

  Verify both directions:
    kubectl auth can-i patch deployments -n payments    --as=system:serviceaccount:payments:deploy-bot  # yes
    kubectl auth can-i delete deployments -n payments   --as=system:serviceaccount:payments:deploy-bot  # no
    kubectl auth can-i patch deployments -n kube-system --as=system:serviceaccount:payments:deploy-bot  # no
    kubectl auth can-i get secrets -A                   --as=system:serviceaccount:payments:deploy-bot  # no

STEP 6 — Close anonymous access (fault 5)
  kubectl get clusterrolebinding -o wide | grep -E 'system:(un)?authenticated|anonymous'
    anonymous-view              ClusterRole/view                 5m   system:unauthenticated
    system:public-info-viewer   ClusterRole/system:public-...    30d  system:authenticated,system:unauthenticated

  system:public-info-viewer is legitimate (nonResourceURLs /version, /healthz).
  anonymous-view is not:
    kubectl auth can-i list secrets -A --as=system:anonymous --as-group=system:unauthenticated
      yes                              <-- every Secret in the cluster, unauthenticated
    kubectl delete clusterrolebinding anonymous-view
    kubectl auth can-i list secrets -A --as=system:anonymous --as-group=system:unauthenticated
      no

  Defence in depth beyond RBAC (do this on a real cluster, not required here):
  set --anonymous-auth=false in /etc/kubernetes/manifests/kube-apiserver.yaml,
  or use AuthenticationConfiguration to keep anonymous only for /healthz,
  /livez and /readyz. Editing the static pod manifest restarts the API server:
  verify the file is valid before saving, and watch
  `crictl ps | grep kube-apiserver` come back.

STEP 7 — No credential where none is needed (fault 6)
  kubectl -n payments exec deploy/frontend -- \
    ls /var/run/secrets/kubernetes.io/serviceaccount
      ca.crt  namespace  token          <-- a usable API credential in a pod
                                            that never calls the API server

  Disable it at the Pod level (narrowest blast radius — the `default` SA is
  shared, so patching the SA would affect anything else that uses it):
    kubectl -n payments patch deploy frontend --type=merge \
      -p '{"spec":{"template":{"spec":{"automountServiceAccountToken": false}}}}'
    kubectl -n payments rollout status deploy/frontend --timeout=120s
    kubectl -n payments exec deploy/frontend -- \
      ls /var/run/secrets/kubernetes.io/serviceaccount
        ls: ...: No such file or directory      <-- expected

  Precedence: the Pod-level field always wins over the ServiceAccount-level
  field. Hardening pattern for a new namespace — turn the default off and let
  each workload opt in:
    kubectl -n payments patch sa default --type=merge \
      -p '{"automountServiceAccountToken": false}'

STEP 8 — Grade and clean up
  ./cks-5.2-break-fix.sh verify        # expect: ALL 20 CHECKS PASSED
  ./cks-5.2-break-fix.sh cleanup

EXAM TAKEAWAYS
  * 401 / "no token" => identity problem (automount, expired or wrong token,
    projected volume). 403 => RBAC problem. Read the verb, resource, apiGroup
    and namespace straight out of the message; the API server has already done
    the diagnosis for you.
  * `kubectl auth can-i --list --as=system:serviceaccount:<ns>:<sa> -n <ns>`
    is the fastest RBAC tool in the exam. Always test the negatives too — a
    fix that only proves "yes" proves nothing about least privilege.
  * The RoleBinding subject for a ServiceAccount MUST carry `namespace:`.
    A wrong namespace produces a binding that is syntactically valid, silently
    accepted, and grants nothing.
  * roleRef is immutable: to repoint a binding you delete and recreate it.
  * RBAC decisions apply to the next request; token projection applies at Pod
    creation. Only the second one needs a rollout.
  * Prefer Role + RoleBinding over ClusterRole + ClusterRoleBinding. Prefer
    resourceNames over whole resource types. Never grant `*` verbs, `*`
    resources, `escalate`, `bind`, `impersonate`, or create/patch on RBAC
    objects to a workload.
  * Audit routinely for: bindings to cluster-admin, to system:masters, to
    system:unauthenticated / system:anonymous, and for SAs with secrets get
    (equivalent to reading every credential in the namespace).
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cks/5.2/lab)
