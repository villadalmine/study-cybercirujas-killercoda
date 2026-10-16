## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION  —  step by step (read only after you have tried it yourself)

 ROOT CAUSE
 The break patched RequestAuthentication/jwt-httpbin so that its jwtRules[0].issuer
 became "testing@insecure.istio.io" (secure -> insecure), while the JWKS URI and
 the token itself were left untouched. The Istio demo token (demo.jwt) is signed
 with the claim  iss = "testing@secure.istio.io".

 Envoy's JWT filter matches an incoming token to a jwtRule by its 'iss' claim.
 With no rule whose issuer equals "testing@secure.istio.io", the token matches
 nothing, so the filter rejects it outright with HTTP 401 and the body
 "Jwt issuer is not configured". This happens BEFORE the AuthorizationPolicy is
 even consulted — which is why a *valid* token fails while a *no-token* request
 is still cleanly 403'd by the policy. Nothing is wrong with mTLS or with authz;
 the defect is a single mismatched string in the request-authentication rule.

 STEP 1 — Reproduce and read the token's real issuer.
    POD=$(kubectl -n ica-lab-42 get pod -l app=client -o jsonpath='{.items[0].metadata.name}')
    TOKEN=$(curl -sL https://raw.githubusercontent.com/istio/istio/release-1.23/security/tools/jwt/samples/demo.jwt | tr -d '[:space:]')
    echo "$TOKEN" | cut -d. -f2 | tr '_-' '/+' | awk '{ while(length%4)$0=$0"="; print }' | base64 -d; echo
       -> {"exp":..., "iat":..., "iss":"testing@secure.istio.io", "sub":"testing@secure.istio.io", ...}

 STEP 2 — Read what the mesh trusts, and confirm the mismatch.
    kubectl -n ica-lab-42 get requestauthentication jwt-httpbin -o jsonpath='{.spec.jwtRules[0].issuer}{"\n"}'
       -> testing@insecure.istio.io          # <-- does NOT equal the token's iss

 STEP 3 — Fix the issuer back to the exact value the token carries. Keep the
          JWKS URI as-is; keep the selector as-is; do NOT touch mTLS or authz.
    kubectl -n ica-lab-42 patch requestauthentication jwt-httpbin --type merge -p \
      '{"spec":{"jwtRules":[{"issuer":"testing@secure.istio.io","jwksUri":"https://raw.githubusercontent.com/istio/istio/release-1.23/security/tools/jwt/samples/jwks.json"}]}}'

    (Equivalent declarative form — apply this manifest instead:)
       apiVersion: security.istio.io/v1
       kind: RequestAuthentication
       metadata: { name: jwt-httpbin, namespace: ica-lab-42 }
       spec:
         selector: { matchLabels: { app: httpbin } }
         jwtRules:
         - issuer: "testing@secure.istio.io"
           jwksUri: "https://raw.githubusercontent.com/istio/istio/release-1.23/security/tools/jwt/samples/jwks.json"

 STEP 4 — Give the sidecars a few seconds to converge, then verify the contract.
    sleep 6
    # valid token -> must be 200
    kubectl -n ica-lab-42 exec "$POD" -c curl -- \
      curl -s -o /dev/null -w '%{http_code}\n' http://httpbin:8000/headers -H "Authorization: Bearer $TOKEN"
       -> 200
    # no token -> must STILL be 403 (proves you did not weaken authz to "fix" it)
    kubectl -n ica-lab-42 exec "$POD" -c curl -- \
      curl -s -o /dev/null -w '%{http_code}\n' http://httpbin:8000/headers
       -> 403
    # mTLS still STRICT (unchanged the whole time)
    kubectl -n ica-lab-42 get peerauthentication default -o jsonpath='{.spec.mtls.mode}{"\n"}'
       -> STRICT

 ANTI-PATTERN — what NOT to do
 Do NOT "fix" the 401 by deleting the RequestAuthentication or by loosening the
 AuthorizationPolicy (e.g. adding a blanket allow / removing requestPrincipals).
 That turns a rejected-good-token into an accept-everything endpoint: the no-token
 request would then return 200 and you would have removed end-user authentication
 entirely. The correct fix touches exactly one field: the issuer string.

 TAKEAWAY for ICA 4.2
 RequestAuthentication only *validates* tokens; it never *requires* them — the
 requirement comes from AuthorizationPolicy (requestPrincipals). A JWT is matched
 to its rule strictly by the 'iss' claim, so the configured issuer must equal the
 token's iss byte-for-byte; a mismatch yields 401 "Jwt issuer is not configured",
 which is a configuration bug, not a bad token. Peer (mTLS) and request (JWT)
 authentication are independent layers: verify each on its own axis
 (istioctl authz check, PeerAuthentication mode) before assuming they interact.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ica/4.2/lab)
