## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION (spoilers: try on your own first)

There are THREE independent faults. Each one alone breaks frontend -> backend.
NetworkPolicies are additive allow-lists: once a pod is selected by any policy
for a direction, only the union of all allow rules for that direction applies.
A connection needs an egress allow on the source AND an ingress allow on the
destination.

Step 1 - Map what is selected, and by what
  kubectl -n ckne-np-lab get pods --show-labels
  kubectl -n ckne-np-lab describe netpol

  frontend (app=frontend) is selected by: default-deny-all, frontend-allow-to-backend
  backend  (app=backend)  is selected by: default-deny-all, backend-allow-from-frontend

Step 2 - Fault #1: DNS egress is denied
  kubectl -n ckne-np-lab exec deploy/frontend -- nslookup backend
  ;; connection timed out; no servers could be reached

  default-deny-all denies ALL egress, including UDP/TCP 53 to CoreDNS in
  kube-system. Name resolution is just another egress connection. Rules are
  matched after the Service VIP (kube-dns ClusterIP) is DNAT'ed to a CoreDNS
  pod IP, so select the CoreDNS pods, not the Service IP. Allow both UDP and
  TCP: large responses and truncated answers fall back to TCP.

  kubectl apply -f - <<'EOF'
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: allow-dns-egress
    namespace: ckne-np-lab
  spec:
    podSelector: {}
    policyTypes:
      - Egress
    egress:
      - to:
          - namespaceSelector:
              matchLabels:
                kubernetes.io/metadata.name: kube-system
            podSelector:
              matchLabels:
                k8s-app: kube-dns
        ports:
          - protocol: UDP
            port: 53
          - protocol: TCP
            port: 53
  EOF

  Notes:
  - namespaceSelector and podSelector sit in the SAME list item (no dash
    before podSelector), so the peer means "DNS pods IN kube-system" (AND).
    Two separate items would mean "any pod in kube-system OR any pod labeled
    k8s-app=kube-dns in THIS namespace" (OR), which is a classic mistake.
  - kubernetes.io/metadata.name is set automatically on every namespace.
  - With NodeLocal DNSCache the pods query 169.254.20.10 on the node, so you
    need an ipBlock rule for that address instead (behaviour is CNI-specific).
  - podSelector: {} gives DNS to every pod in the namespace, which is the usual
    pattern. Scoping it to app=frontend also passes this lab.

  After this: nslookup backend works, wget still says "download timed out".

Step 3 - Fault #2: egress rule uses the SERVICE port instead of the POD port
  kubectl -n ckne-np-lab get svc backend
  PORT(S): 80/TCP  -> targetPort 8080

  frontend-allow-to-backend allows TCP/80 to app=backend pods. The frontend
  connects to the ClusterIP on port 80, but kube-proxy (or the eBPF service
  layer) DNATs the packet to <backend-pod-IP>:8080 BEFORE the policy is
  evaluated. NetworkPolicy peers and ports always refer to POD IPs and POD
  (container) ports, never to Service VIPs and Service ports.

  kubectl -n ckne-np-lab patch netpol frontend-allow-to-backend --type=json \
    -p='[{"op":"replace","path":"/spec/egress/0/ports/0/port","value":8080}]'

  Tip: the container port is named "http", so `port: http` also works and
  keeps working if the container port number changes later.

Step 4 - Fault #3: ingress rule selects a label nobody has
  kubectl -n ckne-np-lab describe netpol backend-allow-from-frontend
    From: PodSelector: app=front
  kubectl -n ckne-np-lab get pods -l app=front      -> No resources found

  A selector that matches nothing is not an error: the policy is valid and
  simply allows nobody. The frontend pods carry app=frontend.

  kubectl -n ckne-np-lab patch netpol backend-allow-from-frontend --type=json \
    -p='[{"op":"replace","path":"/spec/ingress/0/from/0/podSelector/matchLabels","value":{"app":"frontend"}}]'

Step 5 - Confirm, and confirm you did not over-open
  kubectl -n ckne-np-lab exec deploy/frontend -- wget -qO- -T 4 http://backend/hostname
  backend-xxxxxxxxxx-xxxxx

  ./np-break-fix.sh verify
  [ OK ] default-deny-all intact (all pods, Ingress+Egress, no allow rules).
  [ OK ] lab-harness-intruder-open present.
  [ OK ] frontend -> http://backend/hostname works (DNS + Service + policies).
  [ OK ] intruder -> backend:8080 blocked.
  [ OK ] frontend -> intruder:8080 blocked (frontend egress is scoped).
  [ OK ] frontend -> Internet blocked (weak check: also passes on an offline VM).

  Shortcuts that verify rejects, and why they are wrong in production:
  - Deleting default-deny-all: returns to allow-all, so zero trust is gone.
  - `egress: [{}]` on the frontend: fixes DNS and the port in one go, but lets
    a compromised frontend reach anything, including the Internet.
  - `ingress: [{}]` or `podSelector: {}` in the backend's from: any pod in the
    namespace (the intruder too) reaches the API.
  - Relabeling the frontend to app=front: "fixes" it by making the workload
    fit a broken policy. The next Deployment rollout silently undoes it.

Diagnostic method to keep for the exam
  1. Which policies select the SOURCE pod for Egress? Which select the
     DESTINATION pod for Ingress? Both sides must allow the flow.
  2. Resolve names first (nslookup): a DNS timeout under default-deny is
     almost always missing egress to kube-dns on 53/UDP+TCP.
  3. Compare policy ports with the pod's containerPort / Service targetPort,
     never with the Service port.
  4. Check every selector against real labels
     (kubectl get pods -l <selector>); an empty result means a dead rule.
  5. Mind the YAML shape of peers: one list item with namespaceSelector and
     podSelector = AND, two list items = OR.
  6. Cilium: `hubble observe --verdict DROPPED -n ckne-np-lab`;
     Calico: `calicoctl` / flow logs. They show exactly which flow is dropped.

Cleanup:  ./np-break-fix.sh cleanup
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/4.1/lab)
