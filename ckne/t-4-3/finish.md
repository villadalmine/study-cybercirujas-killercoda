## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION (spoilers - try it yourself first)

--- Step 1: read the listener conditions, not only the Gateway conditions --

  kubectl -n tls-lab-app get gateway tls-lab-gw \
    -o jsonpath='{range .status.listeners[*]}{.name}{"\n"}{range .conditions[*]}  {.type}={.status} {.reason}: {.message}{"\n"}{end}{end}'

  Typical output (the wording of the message depends on the implementation):

    https
      Accepted=True Accepted: ...
      ResolvedRefs=False RefNotPermitted: certificateRef tls-lab-certs/app-tls
                  is not permitted by any ReferenceGrant
      Programmed=False Invalid: ...

  RefNotPermitted means the reference points into another namespace and
  the owner of that namespace did not allow it. The Gateway API spec
  requires implementations to reject the reference in that case. This
  is what stops any namespace from mounting any other namespace's
  private keys.

--- Step 2: grant the minimal access, from the namespace that owns the Secret

  The ReferenceGrant lives in the TARGET namespace (tls-lab-certs). "from"
  names who may reference; "to" names what they may reference. Setting
  "name" limits the grant to this Secret only (constraint #2).

  kubectl apply -f - <<'EOF'
  apiVersion: gateway.networking.k8s.io/v1beta1
  kind: ReferenceGrant
  metadata:
    name: allow-tls-lab-app-gateway
    namespace: tls-lab-certs
  spec:
    from:
      - group: gateway.networking.k8s.io
        kind: Gateway
        namespace: tls-lab-app
    to:
      - group: ""
        kind: Secret
        name: app-tls
  EOF

  Check that the controller now accepts it:

  kubectl -n tls-lab-app get gateway tls-lab-gw \
    -o jsonpath='{.status.listeners[?(@.name=="https")].conditions[?(@.type=="ResolvedRefs")].status}{"\n"}'
  # True

--- Step 3: notice that "green" does not mean "working" -------------------

  ADDR=$(kubectl -n tls-lab-app get gateway tls-lab-gw -o jsonpath='{.status.addresses[0].value}')
  curl -v --cacert ~/tls-lab-4.3/ca.crt \
    --resolve app.tls-lab.local:443:$ADDR https://app.tls-lab.local/hostname

  Expected failure:
    curl: (60) SSL: no alternative certificate subject name matches
    target host name 'app.tls-lab.local'

  (With no LoadBalancer address, port-forward to the data plane Service,
   for example on Envoy Gateway:
     kubectl -n envoy-gateway-system get svc \
       -l gateway.envoyproxy.io/owning-gateway-name=tls-lab-gw
     kubectl -n envoy-gateway-system port-forward svc/<name> 18443:443 &
     curl --cacert ~/tls-lab-4.3/ca.crt \
       --resolve app.tls-lab.local:18443:127.0.0.1 https://app.tls-lab.local:18443/hostname )

  Inspect what the Gateway actually serves for that SNI:

  openssl s_client -connect $ADDR:443 -servername app.tls-lab.local \
    -CAfile ~/tls-lab-4.3/ca.crt </dev/null 2>/dev/null \
    | openssl x509 -noout -subject -issuer -ext subjectAltName

    subject=CN=app.wrong.lab.local
    issuer=CN=TLS Lab Internal CA
    X509v3 Subject Alternative Name:
        DNS:app.wrong.lab.local

  Or read it straight from the Secret:

  kubectl -n tls-lab-certs get secret app-tls -o jsonpath='{.data.tls\.crt}' \
    | base64 -d | openssl x509 -noout -subject -ext subjectAltName -enddate

  Lesson: the controller checks that the Secret exists, is readable and
  holds a parseable kubernetes.io/tls keypair. It does not compare the SAN
  with listener.hostname. Clients match hostnames against the SAN only;
  modern clients ignore the CN.

--- Step 4: reissue the certificate with the right SAN, signed by the lab CA

  cd ~/tls-lab-4.3
  cat > app.ext <<'EOF'
  basicConstraints       = CA:FALSE
  keyUsage               = critical,digitalSignature,keyEncipherment
  extendedKeyUsage       = serverAuth
  subjectAltName         = DNS:app.tls-lab.local
  authorityKeyIdentifier = keyid
  EOF
  openssl req -new -nodes -newkey rsa:2048 -sha256 \
    -keyout app.key -out app.csr -subj "/CN=app.tls-lab.local"
  openssl x509 -req -sha256 -days 30 -in app.csr \
    -CA ca.crt -CAkey ca.key -CAcreateserial -extfile app.ext -out app.crt

  Verify BEFORE uploading (cheap, and it catches most mistakes):
  openssl verify -CAfile ca.crt app.crt                 # app.crt: OK
  openssl x509 -in app.crt -noout -ext subjectAltName   # DNS:app.tls-lab.local
  diff <(openssl x509 -in app.crt -noout -pubkey) \
       <(openssl pkey -in app.key -pubout) && echo "key matches"

--- Step 5: rotate the Secret in place (constraint #4) ---------------------

  kubectl -n tls-lab-certs create secret tls app-tls \
    --cert=app.crt --key=app.key --dry-run=client -o yaml \
    | kubectl apply -f -

  The Gateway, the listener and the ReferenceGrant do not change. The
  implementation watches the Secret and reloads the certificate (Envoy
  through SDS, for example), with no restart and no dropped connections.
  In production, cert-manager does this same rotation for you: it writes
  to the Secret referenced by certificateRefs. If it runs in another
  namespace, the same ReferenceGrant rule applies.

--- Step 6: verify end to end, strictly (no -k) ----------------------------

  curl --cacert ~/tls-lab-4.3/ca.crt \
    --resolve app.tls-lab.local:443:$ADDR https://app.tls-lab.local/hostname
  # app-7c9d8f6b5-x2kqp

  ./break-fix-4.3.sh check
  # RESULT: 6/6 - FIXED. Ticket #4312 can be closed.

--- Wrong fixes that the check rejects, and why ----------------------------

  * Copying the Secret into tls-lab-app: the private key now lives where
    the app team can read it, which defeats the separation that
    ReferenceGrant exists to keep.
  * A ReferenceGrant without "to[].name": it works, but every Gateway in
    tls-lab-app can now use EVERY certificate in tls-lab-certs.
  * A ReferenceGrant created in tls-lab-app: grants are only honored in
    the namespace of the target, so nothing changes.
  * Changing listener.hostname to app.wrong.lab.local: the status stays
    green, but you broke the contract. Clients ask for app.tls-lab.local.
  * Testing with curl -k: -k skips exactly the check that was failing.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/4.3/lab)
