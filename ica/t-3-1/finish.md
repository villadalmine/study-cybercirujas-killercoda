## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION — step by step (do not peek until you have tried)

ROOT CAUSE
  The Gateway resource selects the gateway *workload* it configures via
  `spec.selector`. The break set it to `istio: ingressgateway-BROKEN`, which
  matches no pod. With no matching workload, istiod pushes this Gateway's
  server (port 80, host httpbin.example.com) to nobody. The ingress gateway
  Envoy therefore has no route for that host and answers 404. The backend is
  fine — this is purely a control-plane selector mismatch.

1) Let the analyzer point at it:
     istioctl analyze -n ica-lab-31
   Expected finding (IST0101, "Referenced selector not found"):
     Warning [IST0101] (Gateway ica-lab-31/httpbin-gw) Referenced selector
     not found: "istio=ingressgateway-BROKEN"

2) Confirm the mismatch by hand:
     kubectl -n ica-lab-31 get gateway httpbin-gw \
       -o jsonpath='{.spec.selector}{"\n"}'
       => {"istio":"ingressgateway-BROKEN"}
     kubectl -n istio-system get pods -l istio=ingressgateway --show-labels
       => pods carry the label  istio=ingressgateway   (NOT ...-BROKEN)

3) (Optional, prove it from Envoy) — the listener/route for the host is gone:
     istioctl proxy-config routes deploy/istio-ingressgateway -n istio-system \
       | grep -i httpbin        # returns nothing while broken

4) Fix in place — restore the selector so it matches the ingress pods:
     kubectl -n ica-lab-31 patch gateway httpbin-gw --type merge \
       -p '{"spec":{"selector":{"istio":"ingressgateway"}}}'
   (Equivalent: `kubectl -n ica-lab-31 edit gateway httpbin-gw` and correct
    the selector value.)

5) Verify recovery (config push takes a few seconds):
     kubectl -n istio-system port-forward svc/istio-ingressgateway 18080:80 &
     curl -s -o /dev/null -w '%{http_code}\n' \
       -H 'Host: httpbin.example.com' http://127.0.0.1:18080/status/200
       => 200
     istioctl proxy-config routes deploy/istio-ingressgateway -n istio-system \
       | grep -i httpbin        # the route is back
   Or simply:  ./ica-3.1-break-and-fix.sh verify

KEY TAKEAWAYS
  - Gateway.spec.selector must equal a LABEL that real gateway pods carry;
    a typo silently removes the listener with no error on apply.
  - `istioctl analyze` catches selector/binding faults that `kubectl apply`
    accepts happily. Make it the first reflex on any ingress incident.
  - HTTP 404 at the gateway => no matching route/listener (config plane).
    HTTP 503 => route exists but no healthy upstream (destination/cluster).
    Read Envoy's view with `istioctl proxy-config {listeners,routes,clusters}`.

BONUS DRILL — the EGRESS half of topic 3.1 (optional; run manually)
  By default Istio's outbound policy is ALLOW_ANY, so meshed pods can reach
  the internet. Production meshes often lock this to REGISTRY_ONLY so only
  explicitly declared external hosts are reachable. To practice:

  BREAK — deny undeclared egress:
    istioctl install --set profile=demo \
      --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY -y
    kubectl -n ica-lab-31 exec deploy/httpbin -c istio-proxy -- \
      curl -sS -o /dev/null -w '%{http_code}\n' https://httpbin.org/get
      => 502 (BlackHoleCluster: the host is not in the mesh registry)

  FIX — declare the external host with a ServiceEntry:
    kubectl apply -f - <<'EOF'
    apiVersion: networking.istio.io/v1beta1
    kind: ServiceEntry
    metadata:
      name: allow-httpbin-org
      namespace: ica-lab-31
    spec:
      hosts: ["httpbin.org"]
      ports:
        - number: 443
          name: https
          protocol: TLS
      resolution: DNS
      location: MESH_EXTERNAL
    EOF
    # re-run the curl above => 200

  RESET egress back to permissive:
    istioctl install --set profile=demo \
      --set meshConfig.outboundTrafficPolicy.mode=ALLOW_ANY -y
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ica/3.1/lab)
