## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION — step by step (do NOT read until you have tried)

MENTAL MODEL
  Request  ->  VirtualService (chooses subset by NAME)
           ->  DestinationRule (turns subset NAME into a LABEL selector)
           ->  Envoy cluster "outbound|5000|v1|helloworld..." (LABELS -> endpoints)
           ->  Pod endpoints
  A 503 "no healthy upstream" (flag UH) means the route resolved to a cluster,
  but that cluster has zero healthy endpoints. So the break is downstream of
  the VirtualService — it is in how the subset maps to Pods (the DestinationRule
  labels), not in the VirtualService route itself.

STEP 1 — Reproduce and classify the failure
  kubectl -n ica-mesh-lab exec deploy/curl -c curl -- \
    curl -s -o /dev/null -w '%{http_code}\n' http://helloworld:5000/hello
  # => 503
  kubectl -n ica-mesh-lab exec deploy/curl -c curl -- \
    curl -s http://helloworld:5000/hello
  # => no healthy upstream
  Read the client sidecar access log; the response flag is the key signal:
  kubectl -n ica-mesh-lab logs deploy/curl -c istio-proxy --tail=20 | grep helloworld
  # ... "GET /hello" 503 UH ... outbound|5000|v1|helloworld.ica-mesh-lab.svc.cluster.local
  # UH = No Healthy Upstream  ->  the chosen cluster (subset v1) has no endpoints.

STEP 2 — Confirm the route itself is fine (rule out the VirtualService)
  istioctl proxy-config route deploy/curl -n ica-mesh-lab \
    --name 5000 -o json | grep -A3 '"cluster"'
  # The route points at: outbound|5000|v1|helloworld.ica-mesh-lab.svc.cluster.local
  # That is exactly what the VirtualService asked for. The route is correct.
  # (istioctl analyze -n ica-mesh-lab may print no error here — do NOT trust its
  #  silence as "healthy"; it validates references, not live endpoint population.)

STEP 3 — Prove the cluster is empty, and find out WHY
  istioctl proxy-config endpoints deploy/curl -n ica-mesh-lab \
    --cluster 'outbound|5000|v1|helloworld.ica-mesh-lab.svc.cluster.local'
  # => (empty)   <-- zero endpoints -> this is the UH.
  # Compare the subset's required labels against the labels the Pods actually have:
  istioctl proxy-config cluster deploy/curl -n ica-mesh-lab \
    --fqdn helloworld.ica-mesh-lab.svc.cluster.local --subset v1 -o json \
    | grep -A4 metadataMatch
  # => version: v1-CANARY          (what the subset demands)
  kubectl -n ica-mesh-lab get pods -l app=helloworld \
    -L version --show-labels
  # => the running Pods carry version=v1 and version=v2 — NOT v1-CANARY.
  # ROOT CAUSE: DestinationRule subset v1 selects a label no endpoint has.

STEP 4 — Apply the fix (make subset v1 select the real v1 endpoints)
  Edit the DestinationRule so subset v1's labels match the Pods again:

  kubectl -n ica-mesh-lab apply -f - <<'EOF'
  apiVersion: networking.istio.io/v1
  kind: DestinationRule
  metadata: { name: helloworld }
  spec:
    host: helloworld
    subsets:
      - name: v1
        labels: { version: v1 }     # corrected: matches the running v1 Pods
      - name: v2
        labels: { version: v2 }
  EOF

  (Equivalent surgical patch:
    kubectl -n ica-mesh-lab patch destinationrule helloworld --type=json \
      -p='[{"op":"replace","path":"/spec/subsets/0/labels/version","value":"v1"}]'
  )

  Note the two WRONG "fixes" the goal explicitly forbids, and why:
    - Relabeling the Pods to version=v1-CANARY would "work" but destroys the
      v1/v2 distinction the mesh relies on for canary/version routing.
    - Deleting the subset / dropping the subset field from the VirtualService
      removes the version pinning instead of repairing it.
  The correct fix repairs the subset->endpoint link and preserves intent.

STEP 5 — Verify recovery
  istioctl proxy-config endpoints deploy/curl -n ica-mesh-lab \
    --cluster 'outbound|5000|v1|helloworld.ica-mesh-lab.svc.cluster.local'
  # => now lists the v1 Pod IP:5000
  kubectl -n ica-mesh-lab exec deploy/curl -c curl -- \
    curl -s http://helloworld:5000/hello
  # => Hello version: v1, instance: helloworld-v1-xxxxx
  Envoy config converges within a couple of seconds of the DR apply; if it lags,
  confirm push status is clean: istioctl proxy-status

TAKEAWAYS FOR THE EXAM
  * VirtualService subset = a NAME; DestinationRule subset = NAME + label selector.
    Both the name AND the labels must line up, or the route is dead on arrival.
  * 503 UH / "no healthy upstream" = route resolved, cluster empty. Look at the
    DestinationRule labels and the Pod labels, not the VirtualService.
  * Diagnose with the data plane, not just the control plane: proxy-config
    route -> cluster -> endpoints walks the exact path a request takes.
    'istioctl analyze' checks references, not live endpoint population.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ica/3.2/lab)
