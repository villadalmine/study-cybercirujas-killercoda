## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION (step by step) - read only after you have tried

STEP 0 - Prove the platform is healthy before blaming it
  kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
    NAME                       READY   STATUS    RESTARTS   AGE
    coredns-7c65d6cfc9-4xk2p   1/1     Running   0          3d
    coredns-7c65d6cfc9-l9m8q   1/1     Running   0          3d

  kubectl -n kube-system get svc kube-dns
    NAME       TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)                  AGE
    kube-dns   ClusterIP   10.96.0.10   <none>        53/UDP,53/TCP,9153/TCP   3d

  Control test: a fresh pod with default settings in the SAME namespace.
  kubectl -n ckne-bf-14 run dnstest --rm -it --restart=Never \
    --image=busybox:1.36.1 -- nslookup backend.ckne-bf-14.svc.cluster.local
    Server:     10.96.0.10
    Address:    10.96.0.10:53
    Name:   backend.ckne-bf-14.svc.cluster.local
    Address: 10.103.41.17

  Cluster DNS works. The fault is specific to the client workload.

STEP 1 - Fault #1: client pod uses dnsPolicy: Default
  kubectl -n ckne-bf-14 exec deploy/client -- cat /etc/resolv.conf
    nameserver 192.168.122.1          <- the NODE's upstream resolver
    search lab.local

  Compared with a correct pod:
    search ckne-bf-14.svc.cluster.local svc.cluster.local cluster.local
    nameserver 10.96.0.10
    options ndots:5

  kubectl -n ckne-bf-14 get deploy client -o jsonpath='{.spec.template.spec.dnsPolicy}{"\n"}'
    Default

  Mechanism: with dnsPolicy "Default" kubelet copies the node's resolv.conf
  (the file set by kubelet --resolv-conf / resolvConf in KubeletConfiguration)
  into the pod. The pod bypasses CoreDNS, so cluster.local names return
  NXDOMAIN from the upstream resolver. "Default" is NOT the default; the
  default is "ClusterFirst".

  dnsPolicy lives in the pod spec, which is immutable for a running pod, so
  change it on the Deployment template and let it roll:

  kubectl -n ckne-bf-14 patch deploy client --type=merge \
    -p '{"spec":{"template":{"spec":{"dnsPolicy":"ClusterFirst"}}}}'
  kubectl -n ckne-bf-14 rollout status deploy/client

  kubectl -n ckne-bf-14 exec deploy/client -- nslookup backend.ckne-bf-14.svc.cluster.local
    Server:     10.96.0.10
    Name:   backend.ckne-bf-14.svc.cluster.local
    Address: 10.103.41.17

  DNS is fixed, but:
  kubectl -n ckne-bf-14 exec deploy/client -- wget -T 3 -qO- http://backend/hostname
    wget: download timed out          (or: Connection refused)

STEP 2 - Fault #2a: Service selector matches no pods
  Resolution gives you a ClusterIP; it does NOT prove there is anything behind it.

  kubectl -n ckne-bf-14 get endpointslices -l kubernetes.io/service-name=backend
    NAME            ADDRESSTYPE   PORTS     ENDPOINTS   AGE
    backend-8kq2d   IPv4          <unset>   <unset>     12m

  kubectl -n ckne-bf-14 get svc backend -o jsonpath='{.spec.selector}{"\n"}'
    {"app":"backend","tier":"backend"}
  kubectl -n ckne-bf-14 get pods -l app=backend --show-labels
    NAME                       READY   STATUS    ...   LABELS
    backend-6d9f7b8c4d-2xv7n   1/1     Running   ...   app=backend,pod-template-hash=...,tier=api

  The selector ANDs its labels: tier=backend never matches tier=api.
  The rules forbid relabelling the pods, so fix the Service:

  kubectl -n ckne-bf-14 patch svc backend --type=merge \
    -p '{"spec":{"selector":{"app":"backend","tier":"api"}}}'

  kubectl -n ckne-bf-14 get endpointslices -l kubernetes.io/service-name=backend
    NAME            ADDRESSTYPE   PORTS   ENDPOINTS                 AGE
    backend-8kq2d   IPv4          8081    10.244.1.12,10.244.2.9    13m

STEP 3 - Fault #2b: targetPort points to a port nobody listens on
  Note PORTS=8081 above. The container listens on 8080 (named "http").

  kubectl -n ckne-bf-14 get pods -l app=backend \
    -o jsonpath='{.items[0].spec.containers[0].ports}{"\n"}'
    [{"containerPort":8080,"name":"http","protocol":"TCP"}]

  Use the named port, so the Service follows the container if the port changes:
  kubectl -n ckne-bf-14 patch svc backend --type=json \
    -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":"http"}]'

  Still failing? If your CNI enforces NetworkPolicy, you now get a timeout,
  not a refusal. A timeout (packets dropped) and "connection refused" (a RST
  from a live host with no listener) point to different layers.

STEP 4 - Fault #3: NetworkPolicy does not select the client
  Take the Service out of the path and test pod-to-pod directly:

  POD_IP=$(kubectl -n ckne-bf-14 get pods -l app=backend -o jsonpath='{.items[0].status.podIP}')
  kubectl -n ckne-bf-14 exec deploy/client -- wget -T 3 -qO- http://$POD_IP:8080/hostname
    wget: download timed out

  Pod IP unreachable while the backend is Ready: look for policies that
  select the destination.

  kubectl -n ckne-bf-14 get networkpolicy
    NAME                            POD-SELECTOR   AGE
    backend-allow-granted-clients   app=backend    15m

  kubectl -n ckne-bf-14 describe networkpolicy backend-allow-granted-clients
    Spec:
      PodSelector:     app=backend
      Allowing ingress traffic:
        To Port: 8080/TCP
        From:
          PodSelector: access=granted
      Not affecting egress traffic
      Policy Types: Ingress

  kubectl -n ckne-bf-14 get pods -l app=client --show-labels
    ... app=client,access=allowed,pod-template-hash=...

  Once any policy selects a pod for Ingress, that pod is default-deny for
  ingress and only traffic matching some rule gets in. "allowed" != "granted".
  You may not edit the policy, so fix the client's pod template (a direct
  `kubectl label pod` would be undone at the next rollout):

  kubectl -n ckne-bf-14 patch deploy client --type=merge \
    -p '{"spec":{"template":{"metadata":{"labels":{"access":"granted"}}}}}'
  kubectl -n ckne-bf-14 rollout status deploy/client

  The Deployment selector is only app=client, so changing another template
  label is allowed (spec.selector is immutable; the template labels are not).

STEP 5 - Verify end to end
  kubectl -n ckne-bf-14 exec deploy/client -- wget -T 3 -qO- http://backend/hostname
    backend-6d9f7b8c4d-2xv7n
  kubectl -n ckne-bf-14 exec deploy/client -- wget -T 3 -qO- http://$POD_IP:8080/hostname
    backend-6d9f7b8c4d-2xv7n
  kubectl -n ckne-bf-14 exec intruder -- wget -T 3 -qO- http://$POD_IP:8080/hostname
    wget: download timed out        <- still blocked, as required

  ./ckne-1.4-break-fix.sh check
    ...
    All checks passed (10). Lab solved.

  ./ckne-1.4-break-fix.sh cleanup

TAKEAWAY - the isolation ladder for "pod A can't reach service B"
  1. Does the name resolve, and WHO answered it?  (/etc/resolv.conf, dnsPolicy)
  2. Does the Service have endpoints?              (selector vs pod labels, readiness)
  3. Does targetPort match a listening port?       (refused = no listener)
  4. Does pod IP:port work directly?               (skips DNS and kube-proxy)
  5. Does a NetworkPolicy select the destination?  (timeout = dropped)
  Change one layer at a time and re-test after each change.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/1.4/lab)
