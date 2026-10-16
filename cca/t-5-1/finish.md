## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
============================  SOLUTION (SPOILERS)  ===========================

THE THREE SEEDED FAULTS

  FAULT 1 — cnp/tiefighter-egress has no rule for cluster DNS.
            The moment ANY egress rule selects tiefighter, that endpoint flips
            from "default allow" to "default deny" for egress. The policy only
            allowed TCP/80 to the deathstar identity, so the pod's UDP/53
            query to CoreDNS was dropped -> curl: (6) Could not resolve host.
            This is the single most common self-inflicted outage with egress
            policies. Source: https://docs.cilium.io/en/stable/security/dns/

  FAULT 2 — cnp/deathstar-l7-landing allowed ingress fromEndpoints
            'org: alliance' instead of 'org: empire'. Cilium matched exactly
            what was written: the tiefighter identity was not in the allow
            list, so its packets were dropped with "Policy denied" BEFORE the
            HTTP proxy ever saw them -> curl: (28) timeout.
            Source: https://docs.cilium.io/en/stable/security/policy/#endpoints-based

  FAULT 3 — the L7 http rule listed path "/v1/requestlanding" while the
            application endpoint is "/v1/request-landing" (hyphen). The
            connection completes, Envoy compares the request against the
            allow list, finds no match, and returns HTTP 403 "Access denied".
            Source: https://docs.cilium.io/en/stable/security/http/

STEP 0 — prove the platform is innocent before blaming it
  kubectl -n kube-system get pods -l k8s-app=kube-dns          # CoreDNS healthy
  kubectl -n cca-lab-51 get endpoints deathstar                # backends present
  kubectl -n cca-lab-51 get pods --show-labels                 # labels intact
  kubectl -n cca-lab-51 get cep                                # identities assigned

STEP 1 — see who is enforcing what
  CILIUM_POD=$(kubectl -n kube-system get pods -l k8s-app=cilium \
                 -o jsonpath='{.items[0].metadata.name}')
  kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg endpoint list

  Expected (abridged) — note the enforcement columns:
    ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS
    412        Disabled           Enabled           23451      k8s:class=tiefighter,k8s:org=empire
    980        Enabled            Disabled          17904      k8s:class=deathstar,k8s:org=empire
    1123       Disabled           Disabled          51002      k8s:class=xwing,k8s:org=alliance

  "Enabled" in a column means default-deny in that direction. tiefighter is
  egress-enforced -> everything it needs (including DNS) must be listed.

STEP 2 — watch the drops while reproducing
  # terminal A
  kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- \
    hubble observe --namespace cca-lab-51 --verdict DROPPED --follow

  # terminal B
  kubectl -n cca-lab-51 exec tiefighter -- \
    curl -sS -XPOST deathstar.cca-lab-51.svc.cluster.local/v1/request-landing

  Terminal A prints, for fault 1:
    cca-lab-51/tiefighter:38210 -> kube-system/coredns-xxxx:53
      Policy denied DROPPED (UDP)

STEP 3 — FIX FAULT 1: allow DNS egress (and keep DNS visibility)
  cat <<'YAML' | kubectl apply -f -
  apiVersion: cilium.io/v2
  kind: CiliumNetworkPolicy
  metadata:
    name: tiefighter-egress
    namespace: cca-lab-51
    labels:
      cca-lab: "5.1"
  spec:
    description: "Egress: tiefighter may resolve names and reach the deathstar HTTP port"
    endpointSelector:
      matchLabels:
        org: empire
        class: tiefighter
    egress:
    # --- cluster DNS, with the L7 DNS proxy enabled for visibility ---
    - toEndpoints:
      - matchLabels:
          io.kubernetes.pod.namespace: kube-system
          k8s-app: kube-dns
      toPorts:
      - ports:
        - port: "53"
          protocol: ANY
        rules:
          dns:
          - matchPattern: "*"
    # --- the application itself ---
    - toEndpoints:
      - matchLabels:
          org: empire
          class: deathstar
      toPorts:
      - ports:
        - port: "80"
          protocol: TCP
  YAML

  Notes:
    * 'io.kubernetes.pod.namespace' is how a CNP crosses namespaces; without it
      the selector only matches endpoints in the policy's own namespace.
    * protocol ANY covers UDP/53 and TCP/53 (large answers, DoT-less fallback).
    * The dns matchPattern block turns on Cilium's DNS proxy for this endpoint;
      it is what makes toFQDNs rules and 'hubble observe --protocol dns' work.
      If your Cilium build has the DNS proxy disabled, drop the 'rules:' block —
      plain L3/L4 to port 53 is enough to restore resolution.
    * Retest: curl now fails differently -> curl: (28) Operation timed out.

STEP 4 — FIX FAULT 2 and FAULT 3: correct identity, correct path
  Hubble now shows the ingress drop with both identities spelled out:
    cca-lab-51/tiefighter:41022 -> cca-lab-51/deathstar-xxxx:80
      Policy denied DROPPED (TCP Flags: SYN)

  cat <<'YAML' | kubectl apply -f -
  apiVersion: cilium.io/v2
  kind: CiliumNetworkPolicy
  metadata:
    name: deathstar-l7-landing
    namespace: cca-lab-51
    labels:
      cca-lab: "5.1"
  spec:
    description: "Ingress: only empire ships may POST a landing request; the rest is denied"
    endpointSelector:
      matchLabels:
        org: empire
        class: deathstar
    ingress:
    - fromEndpoints:
      - matchLabels:
          org: empire            # FIX 2: empire, not alliance
      toPorts:
      - ports:
        - port: "80"
          protocol: TCP
        rules:
          http:
          - method: "POST"
            path: "/v1/request-landing"   # FIX 3: exact application path
  YAML

  Do NOT add /v1/exhaust-port. An L7 rule is an allow list: everything absent
  is denied, and that absence is the actual security control being tested.

STEP 5 — verify the repair AND the posture
  kubectl -n cca-lab-51 exec tiefighter -- \
    curl -sS -XPOST deathstar.cca-lab-51.svc.cluster.local/v1/request-landing
  # -> Ship landed

  kubectl -n cca-lab-51 exec tiefighter -- \
    curl -sS -XPUT deathstar.cca-lab-51.svc.cluster.local/v1/exhaust-port
  # -> Access denied            (L7 allow list working)

  kubectl -n cca-lab-51 exec xwing -- \
    curl -sS --max-time 5 -XPOST deathstar.cca-lab-51.svc.cluster.local/v1/request-landing
  # -> curl: (28) Operation timed out   (identity not in the ingress allow list)

  kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- \
    hubble observe --namespace cca-lab-51 --protocol http --last 10
  # -> HTTP/1.1 POST .../v1/request-landing  FORWARDED
  # -> HTTP/1.1 PUT  .../v1/exhaust-port     DROPPED (403)

  ./cca-5.1-break-fix.sh verify     # must exit 0

WHAT TO CARRY INTO THE EXAM (and into production)
  * Direction matters: a policy that selects an endpoint enables default-deny
    ONLY for the direction(s) it defines. Adding your first egress rule is a
    breaking change; the DNS rule is not optional boilerplate.
  * Verdict tells you the layer. "Policy denied DROPPED" on a SYN is L3/L4 —
    look at identities and selectors. HTTP 403 with a real TCP session is L7 —
    look at method/path/headers in the http rule.
  * Identity is derived from labels, so a policy bug and a labelling bug look
    identical from the app's side; 'cilium-dbg endpoint list' and
    'kubectl get cep' tell you which one you have.
  * Never "fix" a policy outage by deleting the policy or widening it to
    toEntities: [all]. Restore the specific allow, keep the deny.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cca/5.1/lab)
