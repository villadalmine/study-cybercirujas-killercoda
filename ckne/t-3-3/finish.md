## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION (do not read until you have tried)

--- How the path is supposed to work --------------------------------------

  client app --> client sidecar --(VS rule 'mesh')--> istio-egressgateway:80
    (Envoy cluster outbound|80|httpbin|istio-egressgateway.istio-system.svc.cluster.local)
  istio-egressgateway (listener 0.0.0.0_8080, built from the Gateway)
    --(VS rule 'istio-egressgateway')--> outbound|80||httpbin.org --> internet

  Four objects have to agree with each other:
    - ServiceEntry     : httpbin.org exists in the mesh registry (HTTP/80).
    - Gateway          : its `selector` must match the LABELS of the gateway
                         pod. That is what makes istiod program a listener
                         on that pod.
    - DestinationRule  : defines subset `httpbin` for the gateway service, so
                         the sidecar gets a cluster with that subset.
    - VirtualService   : rule for `mesh` (sidecars) -> gateway, and rule for
                         the Gateway -> external host.

--- Step 1: static analysis ------------------------------------------------

  istioctl analyze -n egress-lab

  Expected output, similar to:
    Error [IST0101] (Gateway egress-lab/istio-egressgateway) Referenced
      selector not found: "istio=egress-gateway"
    Error [IST0101] (VirtualService egress-lab/direct-httpbin-through-egress-gateway)
      Referenced host+subset in destinationrule not found:
      "istio-egressgateway.istio-system.svc.cluster.local+httpbin"

  IST0101 = ReferencedResourceNotFound. In an exam, run this first.

--- Step 2: first fault, the missing subset (symptom 503 / NC) ------------

  The client sidecar tries to use a cluster that does not exist:

    kubectl -n egress-lab logs deploy/client -c istio-proxy --tail=5
      ... "GET /anything/... HTTP/1.1" 503 NC cluster_not_found ...

  NC = "No Cluster": the VS points at subset `httpbin`, but the DR only
  defines `httpbin-egress`. Confirm it:

    istioctl proxy-config clusters deploy/client -n egress-lab | grep egressgateway
      istio-egressgateway.istio-system.svc.cluster.local  80  httpbin-egress  outbound  EDS  ...
    (there is no line with subset `httpbin`)

  Fix: make the names match. The DR is the one that disagrees with the rest:

    kubectl -n egress-lab patch destinationrule.networking.istio.io \
      egressgateway-for-httpbin --type=merge \
      -p '{"spec":{"subsets":[{"name":"httpbin"}]}}'

  (Renaming the subset in the VS to `httpbin-egress` also works.)

--- Step 3: second fault, the gateway without a listener (503 / UF, URX) ----

  The request now reaches the egress gateway pod, but nothing is listening:

    kubectl -n egress-lab exec deploy/client -c curl -- curl -s http://httpbin.org/headers
      upstream connect error or disconnect/reset before headers.
      reset reason: remote connection failure, transport failure reason:
      delayed connect error: 111

  111 = ECONNREFUSED: the Service istio-egressgateway:80 -> targetPort 8080
  exists, but Envoy has no listener on 8080 because no Gateway selects it:

    istioctl proxy-config listeners deploy/istio-egressgateway -n istio-system
      (no listener on 0.0.0.0 port 8080)

    kubectl -n istio-system get pods -l app=istio-egressgateway --show-labels
      ... app=istio-egressgateway,istio=egressgateway,...

    kubectl -n egress-lab get gateway.networking.istio.io istio-egressgateway \
      -o jsonpath='{.spec.selector}{"\n"}'
      {"istio":"egress-gateway"}      <-- does not match istio=egressgateway

  Fix:

    kubectl -n egress-lab patch gateway.networking.istio.io istio-egressgateway \
      --type=merge -p '{"spec":{"selector":{"istio":"egressgateway"}}}'

  Confirm the listener appears:

    istioctl proxy-config listeners deploy/istio-egressgateway -n istio-system
      ADDRESSES  PORT  MATCH  DESTINATION
      0.0.0.0    8080  ALL    Route: http.8080

    istioctl proxy-config routes deploy/istio-egressgateway -n istio-system
      http.8080  httpbin.org  /*  direct-httpbin-through-egress-gateway.egress-lab

--- Step 4: end-to-end verification ------------------------------------------

  kubectl -n egress-lab exec deploy/client -c curl -- \
    curl -s -o /dev/null -w '%{http_code}\n' http://httpbin.org/headers
  200

  Proof that the request went THROUGH the gateway, not around it:

    kubectl -n istio-system logs deploy/istio-egressgateway --tail=3
      [...] "GET /headers HTTP/1.1" 200 - via_upstream ... "httpbin.org"
      outbound|80||httpbin.org ...
    (requires access logging, which is on in the demo profile)

  Or, independently of access logs, the Envoy counters used by the grader:

    kubectl -n istio-system exec deploy/istio-egressgateway -c istio-proxy -- \
      pilot-agent request GET stats | grep 'outbound|80||httpbin.org.upstream_rq_total'

  Then:  ./breakfix-3.3-egress-gateway.sh check

--- Production lessons ------------------------------------------------------

  1. An egress gateway is a ROUTING convention, not a security control.
     Nothing here stops a pod without a sidecar, or one that skips the
     sidecar, from going straight to the internet. For real enforcement,
     combine it with:
       - outboundTrafficPolicy.mode: REGISTRY_ONLY in the MeshConfig, and
       - a Kubernetes NetworkPolicy (or CiliumNetworkPolicy) that only lets
         the egress gateway pods reach 0.0.0.0/0, and application
         namespaces reach only kube-dns and istio-system.
     That is why the grader checks the counters instead of trusting a 200.
  2. A wrong Gateway selector fails SILENTLY at apply time: the API server
     accepts it, and the error only shows up as ECONNREFUSED on the data
     path. Put `istioctl analyze` in CI (it exits non-zero on errors).
  3. The Envoy response flag tells you which hop failed: NC/NR point at the
     client sidecar configuration (clusters/routes); UF/URX with
     "connect error 111" point at the next hop (the gateway has no
     listener).
  4. At L3 (Cilium), the equivalent pattern is CiliumEgressGatewayPolicy:
     it SNATs traffic selected by podSelector + destinationCIDRs to a
     fixed egress IP on designated nodes. It requires the egressGateway
     feature, bpf masquerade and kube-proxy replacement. Diagnose it with
     `cilium-dbg bpf egress list` on the agent.
     https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/3.3/lab)
