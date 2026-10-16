## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION - STEP BY STEP (read only after you have tried)

The method: follow the packet, layer by layer.
  client -> DNS -> ClusterIP (kube-proxy rules) -> EndpointSlice -> Pod IP:targetPort
                                                        ^
                    most Service failures are decided here

STEP 0 - Reproduce, and rule out DNS
  kubectl -n ckne-lab-2-4 exec client -- nslookup web.ckne-lab-2-4.svc.cluster.local

  Server:    10.96.0.10
  Address:   10.96.0.10:53
  Name:      web.ckne-lab-2-4.svc.cluster.local
  Address:   10.96.143.27

  DNS works: the name resolves to the ClusterIP. "Connection refused" is NOT
  a DNS problem (that would be "bad address"). Move down one layer.

  Why is it "refused" and not a timeout? When a Service has no READY
  endpoints, kube-proxy (iptables mode) installs a REJECT rule for the
  ClusterIP in the filter table, so the client fails fast. You can see it on
  a node (read only):

  sudo iptables -t filter -S KUBE-SERVICES | grep ckne-lab-2-4
  -A KUBE-SERVICES -d 10.96.143.27/32 -p tcp -m comment \
    --comment "ckne-lab-2-4/web:http has no endpoints" -m tcp --dport 80 \
    -j REJECT --reject-with icmp-port-unreachable

  In nftables mode:  sudo nft list chain ip kube-proxy service-ips   (+ 'no-endpoint-services')
  In IPVS mode:      sudo ipvsadm -Ln -t 10.96.143.27:80   (virtual server with no real servers)

STEP 1 - FAULT 1: selector matches no pods
  kubectl -n ckne-lab-2-4 get endpointslices -l kubernetes.io/service-name=web

  NAME        ADDRESSTYPE   PORTS     ENDPOINTS   AGE
  web-7xk2p   IPv4          <unset>   <unset>     3m

  Zero endpoints: the selector matches nothing. Compare:

  kubectl -n ckne-lab-2-4 get svc web -o jsonpath='{.spec.selector}{"\n"}'
  {"app":"web","tier":"frontend"}

  kubectl -n ckne-lab-2-4 get pods -l app=web --show-labels
  NAME                   READY   STATUS    ...   LABELS
  web-6d9c8b7f5-4rj2m    0/1     Running   ...   app=web,pod-template-hash=...,tier=front-end

  'frontend' != 'front-end'. Selectors are an exact AND of every key/value.
  Quick proof: kubectl -n ckne-lab-2-4 get pods -l app=web,tier=frontend  -> No resources found

  Fix the Service (the Deployment is the source of truth for pod labels):

  kubectl -n ckne-lab-2-4 patch svc web --type merge \
    -p '{"spec":{"selector":{"app":"web","tier":"front-end"}}}'

STEP 2 - FAULT 3: endpoints exist but are NOT ready
  kubectl -n ckne-lab-2-4 get endpointslices -l kubernetes.io/service-name=web -o wide
  NAME        ADDRESSTYPE   PORTS   ENDPOINTS               AGE
  web-7xk2p   IPv4          8080    10.244.1.5,10.244.2.7   4m

  The addresses are there now, but look at their conditions:

  kubectl -n ckne-lab-2-4 get endpointslices -l kubernetes.io/service-name=web \
    -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"  ready="}{.conditions.ready}{"\n"}{end}'
  10.244.1.5  ready=false
  10.244.2.7  ready=false

  kube-proxy only programs READY endpoints, so the REJECT rule is still
  there and the client still sees "Connection refused". Same symptom,
  different cause - this is why you read EndpointSlices, not the error.

  kubectl -n ckne-lab-2-4 describe pod -l app=web | grep -A2 -i 'readiness'
    Readiness:  http-get http://:http/ready delay=2s timeout=1s period=5s #success=1 #failure=2
    Warning  Unhealthy  ...  Readiness probe failed: HTTP probe failed with statuscode: 404

  nginx has no /ready. Point the probe at a path that exists (do NOT delete
  the probe, and do NOT set publishNotReadyAddresses - both would send
  traffic to pods that have not proven they can serve it):

  kubectl -n ckne-lab-2-4 patch deploy web --type json -p \
    '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}]'

  kubectl -n ckne-lab-2-4 rollout status deploy/web
  deployment "web" successfully rolled out

STEP 3 - FAULT 2: endpoints ready, but targetPort is wrong
  kubectl -n ckne-lab-2-4 exec client -- wget -qO- -T 3 http://web.ckne-lab-2-4.svc.cluster.local/
  wget: can't connect to remote host (10.96.143.27): Connection refused

  Still refused - but now it comes from the POD, not from kube-proxy. The
  REJECT rule is gone; the DNAT rule sends the packet to PodIP:8080 and
  nothing listens there, so the pod's kernel answers with a TCP RST.

  Isolate the layer by skipping the Service and hitting the pod directly:

  POD_IP=$(kubectl -n ckne-lab-2-4 get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
  kubectl -n ckne-lab-2-4 exec client -- wget -qO- -T 3 http://$POD_IP:8080/  -> Connection refused
  kubectl -n ckne-lab-2-4 exec client -- wget -qO- -T 3 http://$POD_IP:80/    -> Welcome to nginx!

  The pod works on 80; the Service forwards to 8080:

  kubectl -n ckne-lab-2-4 get svc web -o jsonpath='{.spec.ports[0].targetPort}{"\n"}'
  8080

  On a node, the DNAT target confirms it (read only):
  sudo iptables -t nat -S | grep -A1 'ckne-lab-2-4/web:http' | grep DNAT
  ... -j DNAT --to-destination 10.244.1.5:8080

  Fix it with the NAMED port, so a future containerPort change in the pod
  spec cannot silently break the Service again:

  kubectl -n ckne-lab-2-4 patch svc web --type json -p \
    '[{"op":"replace","path":"/spec/ports/0/targetPort","value":"http"}]'

  kubectl -n ckne-lab-2-4 exec client -- wget -qO- -T 3 http://web.ckne-lab-2-4.svc.cluster.local/ | head -4
  <!DOCTYPE html>
  <html>
  <head>
  <title>Welcome to nginx!</title>

STEP 4 - FAULT 4 (only with WITH_NETPOL=1): the policy drops the client
  kubectl -n ckne-lab-2-4 exec client -- wget -qO- -T 3 http://web.ckne-lab-2-4.svc.cluster.local/
  wget: download timed out

  Refused -> timed out is the signature change: something now DROPS packets
  silently. Endpoints are ready and the pod answers on :80 locally
  (kubectl -n ckne-lab-2-4 exec deploy/web -- wget -qO- -T 2 http://127.0.0.1/ works),
  so look for policy:

  kubectl -n ckne-lab-2-4 get networkpolicy
  NAME                POD-SELECTOR   AGE
  web-allow-clients   app=web        9m

  kubectl -n ckne-lab-2-4 describe networkpolicy web-allow-clients
    Allowing ingress traffic:
      To Port: 80/TCP
      From:
        PodSelector: role=client

  kubectl -n ckne-lab-2-4 get pod client --show-labels
  client   1/1   Running   ...   role=debug

  Note the policy is evaluated on the BACKEND pod after kube-proxy's DNAT,
  so the port it must allow is the targetPort (80), not the Service port.
  The intended design is "only clients may call web", so label the client
  rather than widening the policy:

  kubectl -n ckne-lab-2-4 label pod client role=client --overwrite

  (With Cilium you can confirm the drop live: 'cilium monitor --type drop'
   or 'hubble observe -n ckne-lab-2-4 --verdict DROPPED'. With Calico,
   policy drops appear as iptables/nft counters in the cali-* chains.)

STEP 5 - Verify
  ./ckne-2.4-break-fix.sh check
  [PASS] Service web exists and still exposes port 80
  [PASS] publishNotReadyAddresses is not used
  [PASS] readinessProbe is still configured (httpGet path: /)
  [PASS] Deployment web has 2 Ready replicas
  [PASS] EndpointSlices for web list 2 ready endpoints
  [PASS] client -> http://web.ckne-lab-2-4.svc.cluster.local/ returned the nginx page (3/3)
  LAB COMPLETE - Service traffic restored at the root cause.

  ./ckne-2.4-break-fix.sh reset

TAKEAWAYS
  Symptom                         | Where to look            | Likely cause
  --------------------------------|--------------------------|--------------------------------------
  "bad address" / NXDOMAIN        | nslookup, CoreDNS        | wrong name/namespace, DNS down
  refused, EndpointSlice empty    | svc selector vs labels   | selector mismatch
  refused, endpoints ready=false  | pod conditions, probes   | failing readinessProbe
  refused, endpoints ready        | direct PodIP:port test   | wrong targetPort / app not listening
  timeout, endpoints ready        | NetworkPolicy, CNI       | policy drop, broken pod network/routes
  works from node, not from pod   | NetworkPolicy, CNI       | policy / CNI routing

  Always read EndpointSlices before touching anything: they are the single
  object that tells you whether kube-proxy has anywhere to send the packet.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/2.4/lab)
