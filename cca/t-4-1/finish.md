## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTIONS — read only after you have tried. One block per fault.

 GENERAL METHOD (works for every fault, and for the exam)
 Walk the pipeline from the producer to the consumer and stop at the first
 broken arrow. Four questions, in this order:

  1) Does the DATAPATH produce events?
     kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -i hubble
     # Hubble:  Ok   Current/Max Flows: 4095/4095 (100.00%), Flows/s: 27.31
     # "Disabled" here means nothing downstream can ever work.

  2) Does the NODE-LOCAL API answer? (bypasses relay, Service and TLS)
     kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --last 5
     # This talks to unix:///var/run/cilium/hubble.sock inside the agent.
     # Works => the break is north of the agent (Service / relay / client).

  3) Does RELAY see the nodes?
     kubectl -n kube-system port-forward svc/hubble-relay 4245:80 &
     hubble status
     # Connected Nodes: N/N is the single most informative line in Hubble.
     kubectl -n kube-system logs deploy/hubble-relay --tail=50

  4) Do the CONSUMERS get what they need?
     hubble observe --namespace X --protocol http     # L7 → needs Envoy redirect
     curl http://<node>:9965/metrics | grep hubble_   # Prometheus → needs metrics config

 Rule of thumb: 0/N connected nodes = discovery or agent problem;
 relay Pod not Ready = relay's own config; flows but no HTTP = policy/proxy;
 flows but no metrics = exporter config.

 FAULT 1 — enable-hubble: "false" in the cilium-config ConfigMap
 Diagnosis
   kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -i hubble
   # Hubble:   Disabled
   kubectl -n kube-system get cm cilium-config -o yaml | grep -E 'hubble'
   # enable-hubble: "false"

 Fix
   # 1. flip the flag
   kubectl -n kube-system patch cm cilium-config --type merge \
     -p '{"data":{"enable-hubble":"true"}}'

   # 2. agents read cilium-config only at startup — a restart is mandatory
   kubectl -n kube-system rollout restart ds/cilium
   kubectl -n kube-system rollout status  ds/cilium --timeout=180s

   # 3. relay reconnects on its own, but restart it if it stays at 0 nodes
   kubectl -n kube-system rollout restart deploy/hubble-relay

 Verify
   kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -i hubble
   # Hubble:  Ok   Current/Max Flows: 4095/4095 (100.00%), Flows/s: 31.02
   hubble status      # Connected Nodes: N/N

 Production note
   In a Helm-managed cluster, patching the ConfigMap by hand is undone by the
   next 'helm upgrade'. The durable fix is:
     helm upgrade cilium cilium/cilium -n kube-system --reuse-values \
       --set hubble.enabled=true --set hubble.relay.enabled=true
   Same for every other fault in this lab.

 FAULT 2 — Service hubble-peer forwarding to the wrong container port
 Diagnosis
   hubble status                       # Connected Nodes: 0/N, healthcheck Ok
   kubectl -n kube-system logs deploy/hubble-relay | tail
   # "Failed to create gRPC client" ... error="context deadline exceeded"
   kubectl -n kube-system get svc hubble-peer -o yaml
   # targetPort: 4299   <-- nothing listens there
   kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.hubble-listen-address}'
   # :4244

 Fix
   kubectl -n kube-system patch svc hubble-peer --type merge -p \
     '{"spec":{"ports":[{"name":"peer-service","port":443,"protocol":"TCP","targetPort":4244}]}}'
   # (keep the original port name; a wrong name creates a second port instead
   #  of replacing the existing one)

   kubectl -n kube-system rollout restart deploy/hubble-relay

 Verify
   kubectl -n kube-system get endpointslices \
     -l kubernetes.io/service-name=hubble-peer -o wide
   # one endpoint per node, port 4244, ready=true
   hubble status          # Connected Nodes: N/N

 Why it matters
   hubble-peer is a hostNetwork-backed Service (internalTrafficPolicy: Local)
   whose only job is peer discovery: relay lists it, then opens one Observer
   stream per node to :4244 over mTLS. Break the Service and relay is blind,
   even though every agent is perfectly healthy.

 FAULT 3 — hubble-relay-config points at a non-existent peer service
 Diagnosis
   kubectl -n kube-system get pods -l k8s-app=hubble-relay     # 0/1 Running
   kubectl -n kube-system logs deploy/hubble-relay
   # "Failed to create peer client for peers synchronization"
   # lookup hubble-peer.cilium-system.svc.cluster.local: no such host
   kubectl -n kube-system get cm hubble-relay-config -o jsonpath='{.data.config\.yaml}'
   # peer-service: hubble-peer.cilium-system.svc.cluster.local:443
   kubectl get svc -A | grep hubble-peer     # it lives in kube-system

 Fix
   kubectl -n kube-system get cm hubble-relay-config \
     -o jsonpath='{.data.config\.yaml}' > /tmp/relay.yaml
   sed -i 's#peer-service: .*#peer-service: hubble-peer.kube-system.svc.cluster.local:443#' /tmp/relay.yaml

   { echo "data:"; echo "  config.yaml: |"; sed 's/^/    /' /tmp/relay.yaml; } > /tmp/relay-patch.yaml
   kubectl -n kube-system patch cm hubble-relay-config --patch-file /tmp/relay-patch.yaml
   kubectl -n kube-system rollout restart deploy/hubble-relay
   kubectl -n kube-system rollout status  deploy/hubble-relay

 Verify
   kubectl -n kube-system get pods -l k8s-app=hubble-relay     # 1/1 Running
   hubble status                                               # Connected Nodes: N/N

 Adjacent failure to recognise
   If instead of DNS errors you see 'transport: authentication handshake
   failed' or 'x509: certificate signed by unknown authority', the peer
   address is right and the mTLS material is wrong: relay mounts
   hubble-relay-client-certs (client cert + CA) and the agent presents
   hubble-server-certs. Rotate with 'cilium hubble disable && cilium hubble
   enable', or re-run the Helm upgrade so cert-manager/Helm regenerates both.

 FAULT 4 — L7 visibility lost (policy downgraded to L3/L4)
 Diagnosis
   hubble observe --namespace cca-obs --last 3                  # L4 flows OK
   hubble observe --namespace cca-obs --protocol http --last 20 # empty
   kubectl -n cca-obs get cnp obs-l7-visibility -o yaml
   # toPorts has ports: but no rules: block  -> no Envoy redirect
   kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg policy get
   # no L7 rules listed for the backend identity

 Fix — reinstate an L7 rule that allows everything but forces HTTP parsing
   cat <<'EOF' | kubectl apply -f -
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: obs-l7-visibility
     namespace: cca-obs
   spec:
     endpointSelector:
       matchLabels:
         app: backend
     ingress:
     - fromEndpoints:
       - matchLabels:
           app: client
       toPorts:
       - ports:
         - port: "80"
           protocol: TCP
         rules:
           http:
           - {}          # match-all: same allow-set as L4, but proxied
   EOF

 Verify (allow ~15s for the proxy redirect to be programmed)
   hubble observe --namespace cca-obs --protocol http --last 10
   # cca-obs/client-xxx:41288 -> cca-obs/backend-yyy:80 http-request FORWARDED (HTTP/1.1 GET http://backend.cca-obs.svc.cluster.local/)
   # cca-obs/backend-yyy:80 -> cca-obs/client-xxx:41288 http-response FORWARDED (HTTP/1.1 200 1ms (GET http://.../))
   hubble observe --namespace cca-obs --http-status 200 --last 5

 Key concepts
   * Hubble reports L7 only for traffic redirected to the node's Envoy proxy;
     that redirect is created by an L7 policy rule, never by Hubble itself.
   * 'http: [{}]' is the visibility idiom: it changes nothing about what is
     allowed, it only moves the connection through the proxy. Adding a real
     rule (method: "GET", path: "/api/.*") turns visibility into enforcement,
     and anything unmatched becomes 'http-request DROPPED (403)'.
   * The old 'policy.cilium.io/proxy-visibility' annotation did the same job
     without a policy; it is deprecated and removed in current Cilium — use a
     CiliumNetworkPolicy.
   * L7 proxying costs CPU and latency, and breaks flows that are not really
     HTTP. Scope it to the ports you actually need to observe.

 FAULT 5 — Hubble Prometheus exporter disabled
 Diagnosis
   hubble observe --last 5                       # flows fine → observer alive
   curl -s http://<node-ip>:9965/metrics         # connection refused
   kubectl -n kube-system get cm cilium-config -o yaml | grep -i metrics
   # hubble-metrics and hubble-metrics-server are gone;
   # prometheus-serve-addr (:9962, agent metrics) is still there — that is why
   # cilium_* keeps being scraped while hubble_* does not.

 Fix
   kubectl -n kube-system patch cm cilium-config --type merge -p '{"data":{
     "hubble-metrics-server": ":9965",
     "hubble-metrics": "dns drop tcp flow port-distribution icmp httpV2"
   }}'
   kubectl -n kube-system rollout restart ds/cilium
   kubectl -n kube-system rollout status  ds/cilium --timeout=180s

 Verify
   kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.8.0 -- \
     curl -s http://<node-ip>:9965/metrics | grep -E '^hubble_(flows_processed|dns_queries)'
   # hubble_flows_processed_total{protocol="TCP",subtype="to-endpoint",type="Trace",verdict="FORWARDED"} 1843
   kubectl -n kube-system get svc hubble-metrics -o yaml    # headless, port 9965

 Notes
   * The space-separated list is exact: an unknown handler name makes the
     agent fail to start the metrics server — check with
     'kubectl -n kube-system logs ds/cilium -c cilium-agent | grep -i metric'.
   * Context labels are opt-in and expensive; 'httpV2:labelsContext=source_namespace,
     destination_namespace' is the usual compromise. Per-pod labels are a
     cardinality trap on any real cluster.
   * These are AGGREGATE metrics derived from flows. They are not a substitute
     for flow export: for per-flow retention beyond the in-memory ring buffer
     (hubble-event-buffer-capacity, default 4095 flows per node) configure
     Hubble export to a file/collector, otherwise old flows are simply gone.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cca/4.1/lab)
