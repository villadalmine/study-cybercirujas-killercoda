## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION - STEP BY STEP (do not read before trying)

STEP 0 - Rule out the data plane before touching routing
  kubectl -n bf-app get endpointslices -l kubernetes.io/service-name=web
  kubectl -n bf-backend get endpointslices -l kubernetes.io/service-name=api
  kubectl -n bf-gw get gateway edge

  Both Services have ready endpoints, and the Gateway shows PROGRAMMED=True.
  The problem is between the listener and the route. That layer is the
  Gateway API "attachment" contract.

STEP 1 - Fault #1: the route is not allowed to attach to the listener
  kubectl -n bf-app describe httproute shop

  Expected (abbreviated):
    Status:
      Parents:
        Conditions:
          Type:    Accepted
          Status:  False
          Reason:  NotAllowedByListeners
        Parent Ref:
          Name:          edge
          Namespace:     bf-gw
          Section Name:  http

  The listener only admits routes from namespaces labelled expose=true:
    kubectl -n bf-gw get gateway edge \
      -o jsonpath='{.spec.listeners[0].allowedRoutes.namespaces}'; echo
    {"from":"Selector","selector":{"matchLabels":{"expose":"true"}}}

    kubectl get ns bf-app --show-labels
    NAME     STATUS   AGE   LABELS
    bf-app   Active   3m    bf-lab=ckne-3-2,kubernetes.io/metadata.name=bf-app

  Attachment is a two-way handshake. The route asks for a parent in
  parentRefs, and the Gateway admits it through allowedRoutes. The platform
  team controls the second half. Do not change the Gateway to "from: All",
  because that would let any namespace publish any hostname on the shared
  edge. Onboard the namespace instead:

    kubectl label ns bf-app expose=true

  Now Accepted=True/Accepted. GET / returns "web". GET /api returns 500, and
  GET /api/items returns "web". Two faults remain.

STEP 2 - Fault #2: cross-namespace backendRef without a ReferenceGrant
  kubectl -n bf-app get httproute shop \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")]}'; echo

  Expected:
    {"...","reason":"RefNotPermitted","status":"False","type":"ResolvedRefs"}

  The spec says a rule whose backend reference is invalid must answer HTTP
  500 for matching requests. The other rules keep working, so this is a
  partial outage.

  Only the owner of the TARGET namespace (bf-backend) can grant access.
  The route owner cannot give themselves permission. The ReferenceGrant goes
  in bf-backend and should be as narrow as possible: one source kind, one
  source namespace, and one named Service.

    kubectl apply -f - <<'EOF'
    apiVersion: gateway.networking.k8s.io/v1beta1
    kind: ReferenceGrant
    metadata:
      name: allow-bf-app-httproutes
      namespace: bf-backend
    spec:
      from:
        - group: gateway.networking.k8s.io
          kind: HTTPRoute
          namespace: bf-app
      to:
        - group: ""
          kind: Service
          name: api
    EOF

  (group "" is the core API group, where Service lives.)

  Now ResolvedRefs=True/ResolvedRefs and GET /api returns "api".
  GET /api/items still returns "web".

STEP 3 - Fault #3: Exact match sends sub-paths to the catch-all rule
  The first rule uses path type Exact with value /api. It matches exactly
  "/api" and nothing else. /api/items does not match it, so it falls to
  PathPrefix "/", which matches everything. The request succeeds, but it
  reaches the wrong service. No status condition reports this. Only
  end-to-end testing catches it.

  PathPrefix matches whole path elements: /api matches /api, /api/ and
  /api/items, but NOT /apiv2. When several rules match, Gateway API gives
  precedence to Exact over PathPrefix, and then to the longest prefix.
  With PathPrefix /api and PathPrefix /, requests under /api always reach
  the api backend, whatever the order of the rules.

    kubectl -n bf-app patch httproute shop --type=json -p='[
      {"op":"replace","path":"/spec/rules/0/matches/0/path/type","value":"PathPrefix"}
    ]'

STEP 4 - Prove it end to end
  GW=$(kubectl -n bf-gw get gateway edge -o jsonpath='{.status.addresses[0].value}')
  for p in / /api /api/items; do
    printf '%-12s ' "$p"; curl -s -H 'Host: shop.lab.example' "http://$GW$p"
  done

  Expected:
    /            web
    /api         api
    /api/items   api

  ./break-fix-3.2.sh verify   -> ALL CHECKS PASSED

TAKEAWAYS FOR THE EXAM
  1. Read .status.parents[].conditions on the ROUTE first. The Gateway can
     be Programmed while every route on it is rejected.
  2. Accepted=False/NotAllowedByListeners -> allowedRoutes (namespace
     selector or kinds). Accepted=False/NoMatchingListenerHostname ->
     listener hostname vs route hostnames. Fix these on the route side, or
     on namespace labels, unless you own the Gateway.
  3. ResolvedRefs=False/RefNotPermitted -> missing ReferenceGrant, created
     in the namespace that OWNS the referenced object.
  4. ResolvedRefs=False/BackendNotFound -> wrong Service name or namespace.
     A port that does not exist on the Service is also invalid.
  5. A 200 from the wrong backend is a match/precedence bug, not an
     attachment bug. Test every path you publish, not just "/".

Cleanup when done:  ./break-fix-3.2.sh cleanup
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/3.2/lab)
