## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION (do not read until you have tried) — step by step

1. CONFIRM THE SHAPE OF THE FAILURE
   Authorization in RBAC is keyed on the triple (apiGroup, resource, verb).
   A "Forbidden" that hits ONE resource type while others in the same Role
   still work almost always means the verb and resource are fine but the
   API GROUP is wrong.

     kubectl auth can-i --list -n cnpe-rbac-lab \
       --as=system:serviceaccount:cnpe-rbac-lab:app-deployer

   You will see create/delete allowed on pods, services, configmaps, but the
   'deployments'/'replicasets' entries under the apps group are absent.

2. FIND WHICH GROUP THE RESOURCE REALLY BELONGS TO

     kubectl api-resources | grep -E 'deployments|replicasets'
     # NAME          SHORTNAMES   APIVERSION   NAMESPACED   KIND
     # deployments   deploy       apps/v1      true         Deployment
     # replicasets   rs           apps/v1      true         ReplicaSet

   APIVERSION 'apps/v1' => these resources are in the 'apps' API group, NOT
   the core ("") group. Listing them under apiGroups: [""] authorizes nothing.

3. INSPECT THE BROKEN ROLE

     kubectl -n cnpe-rbac-lab get role tenant-deployer -o yaml

   The single rule uses apiGroups: [""] but lists deployments/replicasets —
   that is the regression.

4. RESTORE LEAST-PRIVILEGE ACCESS BY SPLITTING THE RULE BY API GROUP
   Do NOT add a wildcard group ("*") and do NOT bind to the built-in 'edit'
   ClusterRole — both over-grant. Give each resource its correct group:

     cat <<'YAML' | kubectl apply -f -
     apiVersion: rbac.authorization.k8s.io/v1
     kind: Role
     metadata:
       name: tenant-deployer
       namespace: cnpe-rbac-lab
     rules:
       - apiGroups: [""]
         resources: ["pods", "services", "configmaps"]
         verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
       - apiGroups: ["apps"]
         resources: ["deployments", "replicasets"]
         verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
     YAML

   Note: the RoleBinding and its roleRef are untouched. roleRef is immutable —
   if you ever need to change WHICH role is bound, you must delete and recreate
   the RoleBinding, but here only the Role's rules were wrong.

5. VERIFY

     kubectl auth can-i create deployments.apps -n cnpe-rbac-lab \
       --as=system:serviceaccount:cnpe-rbac-lab:app-deployer      # -> yes
     kubectl auth can-i create secrets -n cnpe-rbac-lab \
       --as=system:serviceaccount:cnpe-rbac-lab:app-deployer      # -> no  (still least privilege)

     ./break_fix.sh --verify

6. TEAR DOWN

     ./break_fix.sh --cleanup

PLATFORM-ENGINEERING TAKEAWAYS
  * RBAC failures are almost never about the verb; they are about the
    (apiGroup, resource) pair. Read the APIGROUP column of `kubectl api-resources`
    before writing a rule, and qualify resources in checks (deployments.apps).
  * `kubectl auth can-i --as / --as-group` lets you audit any subject's
    effective permissions without impersonating credentials — bake it into
    platform CI so an over- or under-grant is caught before it reaches a tenant.
  * The safe fix widens access by exactly one (apiGroup, resource) pair.
    "Just bind them to edit/admin" fixes the symptom by deleting the security
    control — the opposite of what this competency is testing.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpe/3.2/lab)
