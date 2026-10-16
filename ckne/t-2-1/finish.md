## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION - STEP BY STEP (do not read before trying!)

How a ClusterIP Service works at L4, and where it can break:

  client -> ClusterIP:port/PROTO  (virtual IP, programmed by kube-proxy or
                                    the CNI's eBPF replacement per protocol)
         -> DNAT to one ready endpoint (PodIP:targetPort/PROTO)

  The EndpointSlice controller builds the endpoint list from:
    - spec.selector          -> which Pods
    - ports[].targetPort     -> which port on those Pods (number or name)
    - ports[].protocol       -> TCP | UDP | SCTP, part of the rule itself
  None of these are validated against what the Pod actually listens on.
  The API accepts a Service that can never work.

FAULT 1 - selector mismatch -> empty EndpointSlice
  Diagnose:
    kubectl -n ckne-l4-lab describe svc web
      Selector:   app=web-frontend
      Endpoints:  <none>                      <-- the giveaway
    kubectl -n ckne-l4-lab get pods --show-labels
      web-...   app=web,tier=frontend,...
    kubectl -n ckne-l4-lab get pods -l app=web-frontend
      No resources found                      <-- the selector matches nothing

  With no endpoints, kube-proxy (iptables mode) installs a REJECT rule for the
  ClusterIP, so the client gets "Connection refused" immediately instead of a
  timeout. That is why "refused" does NOT always mean "the app isn't listening".

  Fix (the Service selector must match the Pod template labels):
    kubectl -n ckne-l4-lab patch svc web --type=merge \
      -p '{"spec":{"selector":{"app":"web"}}}'

  Confirm:
    kubectl -n ckne-l4-lab get endpointslices -l kubernetes.io/service-name=web
      NAME        ADDRESSTYPE   PORTS   ENDPOINTS               AGE
      web-xxxxx   IPv4          80      10.244.1.5,10.244.2.7   ...

  Note the PORTS column says 80: the next fault is already visible here.

FAULT 2 - wrong targetPort -> endpoints exist, but nothing listens there
  Diagnose:
    kubectl -n ckne-l4-lab exec client -- wget -qO- -T 3 http://web/hostname
      wget: can't connect to remote host (10.96.x.y): Connection refused
    # Bypass the Service and talk to a Pod directly:
    POD_IP=$(kubectl -n ckne-l4-lab get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
    kubectl -n ckne-l4-lab exec client -- wget -qO- -T 3 http://$POD_IP:80/hostname
      Connection refused                      <-- the Pod rejects port 80
    kubectl -n ckne-l4-lab exec client -- wget -qO- -T 3 http://$POD_IP:8080/hostname
      web-6d9c...                             <-- the app is on 8080
    kubectl -n ckne-l4-lab get deploy web \
      -o jsonpath='{.spec.template.spec.containers[0].ports}'

  Fix - prefer the NAMED port, so a future change of containerPort in the
  Deployment does not silently break the Service again:
    kubectl -n ckne-l4-lab patch svc web --type=json \
      -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":"http"}]'

  Confirm (repeat a few times; you should see both replicas):
    for i in 1 2 3 4 5 6; do
      kubectl -n ckne-l4-lab exec client -- wget -qO- -T 3 http://web/hostname; echo
    done

FAULT 3 - protocol mismatch -> TCP Service in front of a UDP listener
  Diagnose:
    kubectl -n ckne-l4-lab get svc echo-udp
      NAME       TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)    AGE
      echo-udp   ClusterIP   10.96.a.b     <none>        5353/TCP   ...
    kubectl -n ckne-l4-lab get deploy web \
      -o jsonpath='{range .spec.template.spec.containers[0].ports[*]}{.name}{" "}{.containerPort}/{.protocol}{"\n"}{end}'
      http 8080/TCP
      udp-echo 8081/UDP
    # Direct test against the Pod proves the app works over UDP:
    kubectl -n ckne-l4-lab exec client -- sh -c "echo hostname | nc -u -w 2 $POD_IP 8081"
      web-6d9c...

  kube-proxy only programs rules for the protocol declared in the Service.
  UDP datagrams to 10.96.a.b:5353 match no rule and are dropped silently.
  UDP has no handshake, so the symptom is "no output", not an error.

  Fix:
    kubectl -n ckne-l4-lab patch svc echo-udp --type=json -p '[
      {"op":"replace","path":"/spec/ports/0/protocol","value":"UDP"},
      {"op":"replace","path":"/spec/ports/0/targetPort","value":"udp-echo"}
    ]'

  Confirm:
    kubectl -n ckne-l4-lab exec client -- sh -c 'echo hostname | nc -u -w 2 echo-udp 5353'
      web-6d9c...

  Production note: if you need the same port number on BOTH TCP and UDP
  (the classic DNS case, 53/TCP + 53/UDP), list two entries in spec.ports
  with distinct names. Both are supported, including on type LoadBalancer
  (MixedProtocolLBService, GA since Kubernetes 1.26), subject to your
  cloud/LB implementation.

  UDP conntrack gotcha: after changing UDP backends, stale conntrack entries
  can keep sending traffic to an old Pod IP until they expire. kube-proxy
  clears them for Service changes it knows about; on a node you can inspect
  them with:  conntrack -L -p udp --dport 5353

Final check
  ./break-fix-l4-services.sh verify
    === ALL CHECKS PASSED - lab solved. ===

The fixed Services, for reference:

  apiVersion: v1
  kind: Service
  metadata:
    name: web
  spec:
    type: ClusterIP
    selector:
      app: web
    ports:
      - name: http
        port: 80
        targetPort: http
        protocol: TCP
  ---
  apiVersion: v1
  kind: Service
  metadata:
    name: echo-udp
  spec:
    type: ClusterIP
    selector:
      app: web
    ports:
      - name: echo
        port: 5353
        targetPort: udp-echo
        protocol: UDP

Diagnostic ladder to memorise for the exam:
  1. kubectl get svc          -> type, ClusterIP, port/PROTOCOL
  2. kubectl get endpointslices -l kubernetes.io/service-name=<svc>
                              -> empty? selector or readiness problem
  3. curl/nc the Pod IP:targetPort directly
                              -> fails? targetPort or protocol problem
  4. Only then suspect kube-proxy / CNI (iptables-save | grep <svc>,
     nft list ruleset, cilium service list, etc.)

Cleanup:
  ./break-fix-l4-services.sh cleanup
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/2.1/lab)
