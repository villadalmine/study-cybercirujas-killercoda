## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION (step by step) - read only after you have tried

--- Step 1: read the route status, not the route spec ---------------------

  kubectl get httproute storefront -n team-a \
    -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'

  Typical output (reasons are defined by the spec, exact set varies slightly
  by implementation):

    Accepted=False NotAllowedByListeners
    ResolvedRefs=False RefNotPermitted

  And on the Gateway:

    kubectl get gateway shared-gw -n infra-gw \
      -o jsonpath='{range .status.listeners[*]}{.name}{" attachedRoutes="}{.attachedRoutes}{"\n"}{end}'
    http attachedRoutes=0

  Key insight: the Gateway API is a two-way handshake. A route's parentRef
  is a REQUEST to attach; the listener's allowedRoutes is the Gateway
  owner's CONSENT. Likewise, a cross-namespace backendRef is a request that
  the target namespace must consent to via ReferenceGrant. "kubectl apply"
  succeeds because the objects are schema-valid; the rejection only lives
  in .status.

--- Step 2: fix FAULT #1 (listener only admits routes from 'Same') ---------

  The listener has:
      allowedRoutes:
        namespaces:
          from: Same
  so only routes in infra-gw can attach. Least-privilege fix: use a Selector
  on the immutable label kubernetes.io/metadata.name (set automatically by
  the API server on every namespace since Kubernetes 1.22):

  kubectl patch gateway shared-gw -n infra-gw --type=json -p='[
    {"op":"replace",
     "path":"/spec/listeners/0/allowedRoutes/namespaces",
     "value":{"from":"Selector",
              "selector":{"matchLabels":{"kubernetes.io/metadata.name":"team-a"}}}}
  ]'

  (Alternative for several app namespaces: label them, e.g.
   kubectl label ns team-a shared-gw-access=true, and select on that label.
   'from: All' also works but lets ANY namespace hijack hostnames on the
   shared Gateway - avoid it on multi-tenant gateways.)

  Re-check:
    Accepted=True Accepted
    ResolvedRefs=False RefNotPermitted

--- Step 3: fix FAULT #2 (cross-namespace backendRef without consent) -------

  The ReferenceGrant must live in the namespace of the TARGET (shop-backend),
  because only the owner of a resource may grant access to it:

  kubectl apply -f - <<'EOF'
  apiVersion: gateway.networking.k8s.io/v1beta1
  kind: ReferenceGrant
  metadata:
    name: allow-team-a-routes
    namespace: shop-backend
  spec:
    from:
      - group: gateway.networking.k8s.io
        kind: HTTPRoute
        namespace: team-a
    to:
      - group: ""
        kind: Service
        name: catalog
  EOF

  Notes:
    - group "" means the core API group (Service).
    - 'name' is optional; omitting it grants access to ALL Services in the
      namespace. Naming it is least privilege.
    - A ReferenceGrant placed in team-a would do nothing: the grant is
      always authored by the side being referenced.

  Re-check:
    Accepted=True Accepted
    ResolvedRefs=True ResolvedRefs

  kubectl get gateway shared-gw -n infra-gw \
    -o jsonpath='{.status.listeners[?(@.name=="http")].attachedRoutes}'
  1

--- Step 4: prove the data plane ------------------------------------------

  GW=$(kubectl get gateway shared-gw -n infra-gw -o jsonpath='{.status.addresses[0].value}')
  curl -s -H 'Host: shop.lab.example' "http://${GW}/hostname"
  catalog-6d5f8b7c9d-x2k4q

  Without a LoadBalancer, port-forward the proxy Service your implementation
  created for the Gateway (name varies per implementation; find it with
  kubectl get svc -A | grep shared-gw), then:
  curl -s -H 'Host: shop.lab.example' http://127.0.0.1:8080/hostname

  Note the Host header: the listener hostname "*.lab.example" and the route
  hostname "shop.lab.example" intersect, so a request without that Host
  header does not match and still gets 404 - that is correct behaviour.

--- Step 5: validate and clean up -----------------------------------------

  ./break-fix-2.6.sh verify
  ./break-fix-2.6.sh cleanup

TAKEAWAYS
  - Route attachment = parentRef (request) + allowedRoutes (consent).
  - Cross-namespace backendRefs = backendRef (request) + ReferenceGrant in
    the target namespace (consent).
  - Debug from .status: HTTPRoute status.parents[].conditions (Accepted,
    ResolvedRefs) and Gateway status.listeners[].attachedRoutes.
  - Prefer 'from: Selector' over 'from: All' on shared Gateways, and name
    the exact Service in a ReferenceGrant.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/2.6/lab)
