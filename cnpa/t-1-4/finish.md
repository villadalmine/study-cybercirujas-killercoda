## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION — step by step (do not read until you have tried on your own)
###############################################################################

--- Fault A: portal unreachable through the Service -------------------------

1. Confirm the symptom is in the Service layer, not the workload:

     kubectl -n idp-platform get pods
       NAME                          READY   STATUS    RESTARTS   AGE
       portal-api-xxxxxxxxxx-xxxxx   1/1     Running   0          5m

     kubectl -n idp-platform get endpoints portal-api
       NAME         ENDPOINTS   AGE
       portal-api   <none>      5m

   A Ready pod with an empty Endpoints object means the Service selector
   matches nothing. This is the classic interface-layer failure: the stable
   entry point exists, but it is wired to a workload identity that no longer
   matches.

2. Compare the selector with the actual pod labels:

     kubectl -n idp-platform get svc portal-api -o jsonpath='{.spec.selector}'
       {"app":"portal-backend"}
     kubectl -n idp-platform get pods --show-labels
       ... app=portal-api,cnpa-lab=1.4 ...

3. Fix: point the selector back at the real label:

     kubectl -n idp-platform patch svc portal-api --type merge \
       -p '{"spec":{"selector":{"app":"portal-api"}}}'

   The EndpointSlice controller repopulates the endpoints within seconds:

     kubectl -n idp-platform get endpoints portal-api
       NAME         ENDPOINTS      AGE
       portal-api   10.244.x.y:80  6m

--- Fault B: self-service provisioning Forbidden ----------------------------

4. Confirm it is authorization, and locate the layer:

     kubectl auth can-i create namespaces \
       --as=system:serviceaccount:idp-platform:tenant-provisioner
       no

   The ClusterRole still has the right rules — verify with:

     kubectl describe clusterrole cnpa-tenant-provisioner

   So the break must be in the binding between identity and role.

5. Inspect the binding's subject:

     kubectl get clusterrolebinding cnpa-tenant-provisioner \
       -o jsonpath='{.subjects[0].name}'
       tenant-provisioner-v2

   The binding grants the role to a ServiceAccount that does not exist
   ("tenant-provisioner-v2"), while the platform's automation still runs as
   "tenant-provisioner". RBAC fails closed: an unmatched subject simply
   means no permissions, with no error anywhere until a request is denied.

6. Fix: bind the role to the real ServiceAccount again. Subjects are not
   patchable in-place by strategic merge on all servers, so replace cleanly:

     kubectl apply -f - <<'YAML'
     apiVersion: rbac.authorization.k8s.io/v1
     kind: ClusterRoleBinding
     metadata:
       name: cnpa-tenant-provisioner
       labels:
         cnpa-lab: "1.4"
     subjects:
     - kind: ServiceAccount
       name: tenant-provisioner
       namespace: idp-platform
     roleRef:
       kind: ClusterRole
       name: cnpa-tenant-provisioner
       apiGroup: rbac.authorization.k8s.io
     YAML

     kubectl auth can-i create namespaces \
       --as=system:serviceaccount:idp-platform:tenant-provisioner
       yes

7. Prove both capabilities end to end:

     ./break_fix.sh verify
       ...
       Result: 4/4 checks passed

--- The architecture lesson -------------------------------------------------

Neither fault touched the Kubernetes control plane, and `kubectl get
componentstatuses` / node health would have shown nothing. A platform is
layered: developer interfaces (the Service in front of the portal) and core
capabilities (the RBAC-backed golden path) are contracts built ON TOP of the
control plane, and each layer can break independently while every layer
below it stays green. Production diagnosis therefore walks the request path
layer by layer — interface, wiring, identity, control plane — instead of
assuming "the cluster is down".
###############################################################################
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpa/1.4/lab)
