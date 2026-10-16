## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
STEP-BY-STEP SOLUTION (do not read until you have tried)

STEP 0 - Reproduce and classify the symptom
  kubectl -n bf-authz exec deploy/frontend -c curl -- curl -sS http://httpbin:8000/get
    curl: (56) Recv failure: Connection reset by peer

  Ask yourself: is it a TCP/TLS failure or an HTTP answer?
    - Connection reset / 000  -> the server sidecar rejected the connection
      BEFORE any HTTP was exchanged. That is the AUTHENTICATION layer (mTLS).
    - HTTP 403 "RBAC: access denied" -> TLS worked and the identity is known,
      but no ALLOW rule matched. That is the AUTHORIZATION layer.
    - HTTP 503 "upstream connect error" -> usually a DestinationRule/TLS
      mismatch on the CLIENT side, not an AuthorizationPolicy.

STEP 1 - Authentication: does the client even have an identity?
  kubectl -n bf-authz get pods
    NAME                        READY   STATUS    RESTARTS   AGE
    frontend-6c9f7d8b5d-x2mzq   1/1     Running   0          2m     <-- 1/1: no sidecar
    httpbin-7b8d9c7f6-k8vlp     2/2     Running   0          2m
    intruder-5f7d6c9b8-q4wzn    2/2     Running   0          2m

  istioctl proxy-status | grep bf-authz
    -> httpbin and intruder are listed, frontend is NOT.

  Why is it missing? The namespace is labeled for injection, so something
  in the pod template opts it out:
  kubectl -n bf-authz get deploy frontend -o jsonpath='{.spec.template.metadata.labels}'; echo
    {"app":"frontend","sidecar.istio.io/inject":"false"}

  Without a sidecar the pod has no SPIFFE certificate and sends plain text.
  The PeerAuthentication in STRICT mode makes httpbin's sidecar accept only
  mTLS, so it resets the connection:
  kubectl -n bf-authz get peerauthentication default -o jsonpath='{.spec.mtls.mode}'; echo
    STRICT

  FIX 1 - remove the opt-out label (in a JSON Pointer, "/" is escaped as "~1").
  Changing the pod template triggers a new rollout on its own:
  kubectl -n bf-authz patch deploy frontend --type=json \
    -p='[{"op":"remove","path":"/spec/template/metadata/labels/sidecar.istio.io~1inject"}]'
  kubectl -n bf-authz rollout status deploy/frontend
  kubectl -n bf-authz get pods -l app=frontend
    frontend-...   2/2   Running   <-- now it is in the mesh

  Do NOT "fix" it by setting the PeerAuthentication to PERMISSIVE: that lets
  any pod without an identity in, including the "outsider".

STEP 2 - Authorization: the next layer shows up
  kubectl -n bf-authz exec deploy/frontend -c curl -- curl -sS http://httpbin:8000/get
    RBAC: access denied

  TLS works now (you get an HTTP answer), so the caller IS authenticated.
  What is its identity? Read the SAN of the certificate its sidecar received:
  istioctl proxy-config secret deploy/frontend -n bf-authz -o json \
    | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
    | base64 -d | openssl x509 -noout -ext subjectAltName
    X509v3 Subject Alternative Name: critical
        URI:spiffe://cluster.local/ns/bf-authz/sa/frontend

  Now look at what the policy expects:
  kubectl -n bf-authz get authorizationpolicy httpbin-allow-frontend \
    -o jsonpath='{.spec.rules[0].from[0].source.principals}'; echo
    ["cluster.local/ns/bf-authz/sa/front-end"]      <-- "front-end" != "frontend"

  Confirm it from the enforcement point (the server's Envoy):
  istioctl proxy-config log deploy/httpbin -n bf-authz --level rbac:debug
  kubectl -n bf-authz exec deploy/frontend -c curl -- curl -s http://httpbin:8000/get >/dev/null
  kubectl -n bf-authz logs deploy/httpbin -c istio-proxy --tail=20 | grep -i rbac
    ... enforced denied, matched policy none
  (With debug on you will also see the connection's peer principal,
   ending in "/sa/frontend".)

  Optional: list the policies that apply to the server pod:
  istioctl x authz check deploy/httpbin -n bf-authz

  Remember: principals are "<trust-domain>/ns/<namespace>/sa/<serviceaccount>",
  WITHOUT the "spiffe://" prefix, and they are an exact string match
  (only a "*" prefix or suffix is allowed as a wildcard).

  FIX 2 - correct the principal:
  kubectl -n bf-authz patch authorizationpolicy httpbin-allow-frontend --type=json \
    -p='[{"op":"replace","path":"/spec/rules/0/from/0/source/principals/0","value":"cluster.local/ns/bf-authz/sa/frontend"}]'
  (If your mesh uses a trust domain other than cluster.local, use that one;
   the script printed it as "Detected trust domain".)

  Or declaratively (the version to keep in Git):
    apiVersion: security.istio.io/v1
    kind: AuthorizationPolicy
    metadata:
      name: httpbin-allow-frontend
      namespace: bf-authz
    spec:
      selector:
        matchLabels:
          app: httpbin
      action: ALLOW
      rules:
        - from:
            - source:
                principals:
                  - "cluster.local/ns/bf-authz/sa/frontend"
          to:
            - operation:
                methods: ["GET"]
                paths: ["/get", "/headers"]

  Do NOT "fix" it with principals: ["*"] or namespaces: ["bf-authz"]:
  "intruder" runs in the same namespace and would get access.

STEP 3 - Verify all layers at once
  kubectl -n bf-authz exec deploy/frontend -c curl -- curl -s -o /dev/null -w '%{http_code}\n' http://httpbin:8000/get
    200
  kubectl -n bf-authz exec deploy/frontend -c curl -- curl -s -o /dev/null -w '%{http_code}\n' -X POST http://httpbin:8000/post
    403
  kubectl -n bf-authz exec deploy/intruder -c curl -- curl -s -o /dev/null -w '%{http_code}\n' http://httpbin:8000/get
    403
  kubectl -n bf-authz-outside exec deploy/outsider -c curl -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://httpbin.bf-authz:8000/get
    000

  Restore the Envoy log level:
  istioctl proxy-config log deploy/httpbin -n bf-authz --level rbac:warning

  ./ckne-4.4-break-fix.sh check      -> SOLVED: 7/7 checks.
  ./ckne-4.4-break-fix.sh cleanup

TAKEAWAYS FOR THE EXAM
  * Identity = ServiceAccount. Changing a pod's serviceAccountName changes its
    SPIFFE ID, and every AuthorizationPolicy that names it has to change too.
  * source.principals and source.namespaces only work with mTLS: without
    a sidecar or with mTLS disabled, the principal is empty and never matches.
  * Connection reset/000 = authentication (mTLS). 403 RBAC: access denied =
    authorization. Fix them in that order: the first one hides the second.
  * An ALLOW policy turns the workload into deny-by-default for anything it
    does not list. An empty "spec: {}" policy denies everything; a rule "{}"
    allows everything.
  * Evaluation order: CUSTOM -> DENY -> ALLOW. One DENY match wins over any ALLOW.
  * Policies in the root namespace (istio-system by default) apply to the whole mesh:
    check them with kubectl get authorizationpolicy -A when the behavior makes no sense.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/4.4/lab)
