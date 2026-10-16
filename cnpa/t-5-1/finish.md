## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION — step by step (do not peek until you have tried)

Root cause
  Kubernetes RBAC authorizes on the resource name EXACTLY as the API exposes
  it, which for a CustomResource is the CRD's `spec.names.plural`. Here that
  is "webservices". The Role was written with the singular "webservice", so
  RBAC granted verbs on a resource that does not exist — the developer got
  zero effective permission on real WebService objects. The RoleBinding and
  the apiGroup were correct, which is exactly why the mistake is easy to miss.

1) Reproduce the denial as the developer identity:
     kubectl auth can-i create webservices \
       --as=system:serviceaccount:cnpa-51-selfservice:developer \
       -n cnpa-51-selfservice
   # -> no

2) Confirm the binding really targets the developer and the Role:
     kubectl -n cnpa-51-selfservice get rolebinding developer-webservice -o yaml
   # subjects: ServiceAccount/developer ; roleRef: Role/webservice-editor  (correct)

3) Read the Role and spot the wrong resource name:
     kubectl -n cnpa-51-selfservice get role webservice-editor -o yaml
   # rules[0].resources: ["webservice"]   <-- singular, wrong

4) Ask the CRD for the authoritative (plural) resource name:
     kubectl get crd webservices.platform.cnpa.local \
       -o jsonpath='{.spec.names.plural}'; echo
   # -> webservices

5) Fix — change ONLY the resource name to the plural. Either patch:
     kubectl -n cnpa-51-selfservice patch role webservice-editor --type=json \
       -p='[{"op":"replace","path":"/rules/0/resources","value":["webservices"]}]'
   # ...or re-apply the corrected Role:
     kubectl apply -f - <<'YAML'
     apiVersion: rbac.authorization.k8s.io/v1
     kind: Role
     metadata:
       namespace: cnpa-51-selfservice
       name: webservice-editor
     rules:
       - apiGroups: ["platform.cnpa.local"]
         resources: ["webservices"]        # plural = CRD spec.names.plural
         verbs: ["get","list","watch","create","update","patch","delete"]
     YAML

6) Verify all three success criteria:
     kubectl auth can-i create webservices \
       --as=system:serviceaccount:cnpa-51-selfservice:developer \
       -n cnpa-51-selfservice          # -> yes
     kubectl -n cnpa-51-selfservice apply --as=system:serviceaccount:cnpa-51-selfservice:developer -f - <<'YAML'
     apiVersion: platform.cnpa.local/v1alpha1
     kind: WebService
     metadata: { name: checkout }
     spec: { image: ghcr.io/acme/checkout:1.4.2, port: 8080, replicas: 2 }
     YAML
     kubectl -n cnpa-51-selfservice get webservices   # checkout is listed
   # Or simply:  ./break_fix.sh verify

Platform takeaway (topic 5.1)
  Simplified developer access has two halves: the ABSTRACTION (the WebService
  CRD / golden path) and the ENTITLEMENT (RBAC that lets developers use it).
  A golden path with mismatched RBAC is invisible to platform owners yet fully
  blocks developers. Always pin RBAC `resources` to the CRD's published
  `spec.names.plural`, keep the grant namespace-scoped and least-privilege,
  and test entitlements from the developer's identity (kubectl --as /
  `auth can-i`) as part of platform validation — not only from admin context.

Reference: CNCF CNPA Curriculum, Domain 5 "Platform Observability, Security
and Conformance" / developer self-service capabilities —
  https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
  Kubernetes RBAC: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
  CRDs: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpa/5.1/lab)
