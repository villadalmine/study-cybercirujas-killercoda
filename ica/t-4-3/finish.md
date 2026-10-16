## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION  (commented — try the challenge before reading)

 ROOT CAUSE
 Istio's ingress gateway loads TLS certificates referenced by a Gateway's
 'tls.credentialName' through SDS (Secret Discovery Service). The secret is
 looked up in the namespace where the INGRESS GATEWAY WORKLOAD runs
 (here: 'istio-system'), NOT in the namespace of the Gateway resource or of
 the application. Our break moved the identical secret into the app namespace
 ('ica-tls-lab'). The secret exists, the name matches, the cert is valid —
 but the gateway proxy cannot see it, so the HTTPS listener has no server
 certificate and every TLS handshake is reset.

 DIAGNOSIS, STEP BY STEP
 1. Confirm HTTP still works but HTTPS does not (isolates the fault to TLS):
      curl -s -o /dev/null -w '%{http_code}\n' \
        --resolve "httpbin.ica.example:80:$INGRESS_HOST" \
        http://httpbin.ica.example/status/200                 # 200
      curl -v --cacert /tmp/ica-tls-lab/edge-tls.crt \
        --resolve "httpbin.ica.example:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
        https://httpbin.ica.example:$SECURE_INGRESS_PORT/status/200   # reset

 2. Ask the gateway proxy which secrets it actually holds:
      istioctl proxy-config secret deploy/istio-ingressgateway -n istio-system
    -> 'edge-tls-cert' is absent (or shown as not sent / no valid cert chain).

 3. Read the gateway logs for the missing-credential warning:
      kubectl -n istio-system logs deploy/istio-ingressgateway \
        | grep -iE 'edge-tls-cert|sds|secret'

 4. Locate the secret cluster-wide — this reveals the misplacement:
      kubectl get secret edge-tls-cert -A
    -> present in 'ica-tls-lab', ABSENT in 'istio-system'.

 THE FIX (one of two equivalent forms)
 (a) Put the credential back where the gateway reads it — istio-system:
      kubectl -n istio-system create secret tls edge-tls-cert \
        --cert=/tmp/ica-tls-lab/edge-tls.crt \
        --key=/tmp/ica-tls-lab/edge-tls.key \
        --dry-run=client -o yaml | kubectl apply -f -

 (b) Or copy the existing secret across namespaces without the source files:
      kubectl -n ica-tls-lab get secret edge-tls-cert -o yaml \
        | sed -e 's/namespace: ica-tls-lab/namespace: istio-system/' \
              -e '/resourceVersion:/d' -e '/uid:/d' -e '/creationTimestamp:/d' \
        | kubectl apply -f -

 Then remove the decoy so the lesson sticks (optional):
      kubectl -n ica-tls-lab delete secret edge-tls-cert

 SDS reloads the credential within seconds — no gateway restart is needed.

 VERIFY
      istioctl proxy-config secret deploy/istio-ingressgateway -n istio-system \
        | grep edge-tls-cert                                   # now present
      ./this-script.sh verify                                  # prints: 200

 TAKEAWAY FOR THE EXAM (ICA 4.3)
 For edge TLS termination, the golden rule is: the secret named by
 'credentialName' MUST live in the ingress gateway's namespace (istio-system
 by default), it MUST be type kubernetes.io/tls with 'tls.crt'/'tls.key'
 (or 'tls.key'+'ca.crt' for MUTUAL mode), and it is served over SDS — no
 volume mounts, no gateway redeploy. "Secret exists somewhere" is not the
 same as "the gateway can load it."
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ica/4.3/lab)
