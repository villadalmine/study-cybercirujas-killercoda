## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
==== SOLUTION KEY ========================================================

Read only after you have tried. Every command below is meant to be typed by
hand on the lab VM; nothing here is automated by the script.

Shared shorthand used throughout:
    PKI=/opt/lab-331.2/pki
    INT=$PKI/intermediate                 # the issuing CA
    DEP=/opt/lab-331.2/deploy             # what nginx reads
    CLI=/opt/lab-331.2/client             # the client identity
    H=lab331.example.internal ; M=mtls331.example.internal ; P=8443
    CURL="curl -sS --cacert $DEP/ca-chain.pem --resolve"

FAULT 1 — incomplete chain of trust
Diagnose. Count what the server sends; one certificate means no intermediate:
    openssl s_client -connect 127.0.0.1:$P -servername $H \
        -CAfile $DEP/ca-chain.pem -showcerts </dev/null | grep -c 'BEGIN CERT'
    openssl x509 -in $DEP/server-fullchain.pem -noout -subject -issuer
The leaf's issuer is the issuing CA, which the client does not have in its
anchor set as a *sent* certificate; the client only trusts the root. RFC 5280
§6 path building needs the middle link, and TLS says the server supplies it.

Fix. Rebuild the file nginx serves, leaf first, then the intermediate:
    cat $PKI/server.crt $INT/ca.crt > $DEP/server-fullchain.pem
    chmod 0644 $DEP/server-fullchain.pem
    nginx -t </dev/null && systemctl reload nginx

Prove it, offline and on the wire:
    openssl verify -CAfile $DEP/root-ca.pem -untrusted $INT/ca.crt $PKI/server.crt
    openssl s_client -connect 127.0.0.1:$P -servername $H \
        -CAfile $DEP/ca-chain.pem </dev/null 2>&1 | grep 'Verify return code'
    # -> Verify return code: 0 (ok)

Note. Never ship the root in ssl_certificate: it wastes handshake bytes and a
client that does not already trust it will not start trusting it because the
server sent it. Order matters — OpenSSL reads the file sequentially.

FAULT 2 — key / certificate mismatch
Diagnose. The algorithm-agnostic comparison (works for RSA, EC, Ed25519):
    openssl x509 -in $DEP/server-fullchain.pem -noout -pubkey | openssl sha256
    openssl pkey  -in $DEP/server.key          -pubout        | openssl sha256
Different digests => the key does not belong to the certificate. The RSA-only
idiom you will still meet in the field, and in the exam:
    openssl x509 -noout -modulus -in cert.pem | openssl md5
    openssl rsa  -noout -modulus -in key.pem  | openssl md5
    openssl req  -noout -modulus -in csr.pem  | openssl md5

Fix A — restore the key that matches (fastest, correct here):
    install -m 0640 /opt/lab-331.2/backup/pki-leaf/server.key $DEP/server.key
    install -m 0400 /opt/lab-331.2/backup/pki-leaf/server.key $PKI/server.key

Fix B — keep the new key and re-issue the certificate for it. This is what you
do in production when the old key is genuinely gone:
    cp $DEP/server.key $PKI/server.key
    openssl req -new -key $PKI/server.key -out $INT/csr/server.csr \
        -subj "/C=AR/O=Teach-Plat Lab 331.2/CN=$H"
    export LAB_SAN="DNS:$H,DNS:$M,IP:127.0.0.1"
    openssl ca -batch -config $INT/openssl.cnf -extensions server_cert \
        -days 397 -notext -md sha256 -in $INT/csr/server.csr -out $PKI/server.crt
    cat $PKI/server.crt $INT/ca.crt > $DEP/server-fullchain.pem

Then, either way:
    chmod 0640 $DEP/server.key
    command -v restorecon >/dev/null && chcon -t cert_t $DEP/server.key
    nginx -t </dev/null && systemctl restart nginx
    ss -lnt | grep $P

FAULT 3 — expired certificate
Diagnose.
    openssl x509 -in $DEP/server-fullchain.pem -noout -dates -serial
    openssl x509 -in $DEP/server-fullchain.pem -noout -checkend 0 ; echo $?  # 1 = expired
    date -u
    grep -E '^[VER]' $INT/index.txt        # V=valid E=expired R=revoked

Fix — renewal is re-issuance. Reuse the key (the SAN and CN must not change):
    openssl req -new -key $PKI/server.key -out $INT/csr/server.csr \
        -subj "/C=AR/O=Teach-Plat Lab 331.2/CN=$H"
    export LAB_SAN="DNS:$H,DNS:$M,IP:127.0.0.1"
    openssl ca -batch -config $INT/openssl.cnf -extensions server_cert \
        -days 397 -notext -md sha256 -in $INT/csr/server.csr -out $PKI/server.crt
    cat $PKI/server.crt $INT/ca.crt > $DEP/server-fullchain.pem
    nginx -t </dev/null && systemctl reload nginx

Prove it:
    openssl x509 -in $DEP/server-fullchain.pem -noout -dates
    openssl x509 -in $DEP/server-fullchain.pem -noout -checkend 2592000 ; echo $?  # 0
    $CURL $H:$P:127.0.0.1 https://$H:$P/health

Notes.
  * `openssl ca` refuses a second certificate for the same DN unless
    index.txt.attr says `unique_subject = no`. This lab sets it; a default CA
    does not, and that is the error you will hit on a real renewal.
  * A reload, not a restart, is enough — but a reload IS required: workers
    hold the parsed PEM in memory and never re-read it on their own.
  * 397 days is the CA/Browser Forum maximum for public TLS certificates; an
    internal CA may go longer, but matching the public limit keeps your
    rotation muscle honest.

FAULT 4 — wrong subjectAltName
Diagnose. openssl verify says OK because it checks the PATH, never the NAME:
    openssl verify -CAfile $DEP/ca-chain.pem $PKI/server.crt          # OK — misleading
    openssl x509 -in $DEP/server-fullchain.pem -noout -subject -ext subjectAltName
    openssl s_client -connect 127.0.0.1:$P -servername $H \
        -verify_hostname $H -CAfile $DEP/ca-chain.pem </dev/null 2>&1 | tail -5

Fix — re-issue with the correct SAN. Two equivalent routes:

  Route 1, SAN from the CA's issuance profile (what a real CA does — note
  copy_extensions=none, so anything in the CSR is deliberately ignored):
    openssl req -new -key $PKI/server.key -out $INT/csr/server.csr \
        -subj "/C=AR/O=Teach-Plat Lab 331.2/CN=$H"
    export LAB_SAN="DNS:$H,DNS:$M,IP:127.0.0.1"
    openssl ca -batch -config $INT/openssl.cnf -extensions server_cert \
        -days 397 -notext -md sha256 -in $INT/csr/server.csr -out $PKI/server.crt

  Route 2, SAN from an explicit extension file (handy for one-offs):
    cat > /tmp/san.ext <<'EOF'
    basicConstraints = critical, CA:FALSE
    keyUsage         = critical, digitalSignature, keyEncipherment
    extendedKeyUsage = serverAuth
    subjectAltName   = DNS:lab331.example.internal,DNS:mtls331.example.internal,IP:127.0.0.1
    subjectKeyIdentifier   = hash
    authorityKeyIdentifier = keyid,issuer
    EOF
    openssl x509 -req -in $INT/csr/server.csr -CA $INT/ca.crt \
        -CAkey $INT/private/ca.key -CAcreateserial -days 397 -sha256 \
        -extfile /tmp/san.ext -out $PKI/server.crt
    # (x509 -req bypasses the CA database — fine for a lab, wrong for a real CA,
    #  because the certificate is then not recorded in index.txt and can never
    #  be revoked through `openssl ca -revoke`.)

Deploy and prove:
    cat $PKI/server.crt $INT/ca.crt > $DEP/server-fullchain.pem
    nginx -t </dev/null && systemctl reload nginx
    openssl x509 -in $DEP/server-fullchain.pem -noout -ext subjectAltName
    $CURL $H:$P:127.0.0.1 https://$H:$P/health

Note. CN has not been a valid source of hostname identity since RFC 6125 and
the Baseline Requirements; Chrome dropped CN fallback in 2017, Go in 1.15.
If a name is not in the SAN, it does not exist as far as the client is
concerned. Wildcards (DNS:*.example.internal) match one label only, never the
bare domain, and never a dotted sublabel.

FAULT 5 — revoked client certificate
Diagnose.
    openssl x509 -in $CLI/client.crt -noout -serial
    openssl crl  -in $DEP/intermediate.crl -noout -text | grep -A2 'Serial Number'
    openssl verify -crl_check -CAfile $DEP/ca-chain.pem \
        -CRLfile $DEP/intermediate.crl $CLI/client.crt
    # -> error 23 at 0 depth lookup: certificate revoked
    grep '^R' $INT/index.txt
    tail -n 20 /var/log/nginx/error.log

Fix — you cannot un-revoke. Issue a new identity. Because the recorded reason
was keyCompromise, a new KEY is mandatory, not just a new certificate:
    openssl req -new -nodes -newkey rsa:2048 -sha256 \
        -keyout $CLI/client.key -out $INT/csr/client.csr \
        -subj "/C=AR/O=Teach-Plat Lab 331.2/OU=Students/CN=student"
    chmod 400 $CLI/client.key
    openssl ca -batch -config $INT/openssl.cnf -extensions client_cert \
        -days 365 -notext -md sha256 -in $INT/csr/client.csr -out $CLI/client.crt

Keep the CRL current and let nginx re-read it (nginx parses ssl_crl at
configuration load; an expired CRL fails every client, so regenerate before
nextUpdate — that is a cron job in production, or move to OCSP):
    openssl ca -batch -config $INT/openssl.cnf -gencrl -out $INT/crl/intermediate.crl
    install -m 0644 $INT/crl/intermediate.crl $DEP/intermediate.crl
    nginx -t </dev/null && systemctl reload nginx

Prove it:
    openssl verify -crl_check -CAfile $DEP/ca-chain.pem \
        -CRLfile $DEP/intermediate.crl $CLI/client.crt        # -> OK
    openssl crl -in $DEP/intermediate.crl -noout -lastupdate -nextupdate
    $CURL $M:$P:127.0.0.1 --cert $CLI/client.crt --key $CLI/client.key \
        https://$M:$P/whoami                                  # -> verify=SUCCESS
    $CURL $M:$P:127.0.0.1 -o /dev/null -w '%{http_code}\n' https://$M:$P/whoami  # -> 400

Note. `-crl_check` validates only the leaf's CRL; `-crl_check_all` demands a
CRL for every CA in the path, which means you also need the root's CRL. Reason
codes matter operationally: only `certificateHold` is reversible, via
`openssl ca -config ... -crl_reason removeFromCRL`.

FAULT 6 — encrypted key with no passphrase source
Diagnose.
    head -3 $DEP/server.key                 # BEGIN ENCRYPTED PRIVATE KEY
    openssl pkey -in $DEP/server.key -noout ; echo $?    # prompts / fails
    journalctl -u nginx -n 30 --no-pager

Fix A — remove the passphrase (the common production choice; the key is then
protected by the filesystem, so ownership and mode carry the whole weight):
    openssl pkey -in $DEP/server.key -passin pass:L4bP4ssphr4se -out /tmp/plain.key
    install -o root -g root -m 0640 /tmp/plain.key $DEP/server.key
    install -o root -g root -m 0400 /tmp/plain.key $PKI/server.key
    shred -u /tmp/plain.key
    command -v chcon >/dev/null && chcon -t cert_t $DEP/server.key
    systemctl restart nginx

Fix B — keep it encrypted and feed nginx the passphrase. Add to BOTH server
blocks in /etc/nginx/conf.d/lab-331-2.conf, next to ssl_certificate_key:
    printf 'L4bP4ssphr4se\n' > /etc/nginx/ssl_passwords
    chown root:root /etc/nginx/ssl_passwords && chmod 0600 /etc/nginx/ssl_passwords
    # ssl_password_file /etc/nginx/ssl_passwords;
    nginx -t </dev/null && systemctl restart nginx

Prove it — the test that matters is the unattended one:
    systemctl restart nginx && systemctl is-active nginx
    openssl x509 -in $DEP/server-fullchain.pem -noout -pubkey | openssl sha256
    openssl pkey -in $DEP/server.key -pubout | openssl sha256     # same digest

Note. Argue the trade-off out loud: Fix B does not protect the key from
anyone who can read the filesystem as root — it only stops a casual copy of
the key file alone from being useful. Real protection at rest means an HSM,
a TPM, or a KMS-fronted key, not a passphrase in a sibling file.

FAULT 7 — mTLS trust store and verification depth
Diagnose. The client certificate is fine; the server's trust store is not:
    openssl verify -CAfile $DEP/ca-chain.pem $CLI/client.crt      # OK
    openssl x509 -in $CLI/client.crt -noout -issuer               # the issuing CA
    grep -nE 'ssl_client_certificate|ssl_verify_depth' /etc/nginx/conf.d/lab-331-2.conf
    # ssl_client_certificate points at root-ca.pem, depth is 1
    openssl s_client -connect 127.0.0.1:$P -servername $M </dev/null 2>&1 \
        | sed -n '/Acceptable client certificate CA names/,/^---/p'
    tail -n 20 /var/log/nginx/error.log     # (20:unable to get local issuer certificate)

Fix — two independent problems, both must be corrected. In the $M server block:
    ssl_client_certificate /opt/lab-331.2/deploy/ca-chain.pem;   # intermediate + root
    ssl_verify_depth       2;                                    # leaf(0) int(1) root(2)
Apply with:
    nginx -t </dev/null && systemctl reload nginx

Prove both halves — authentication works AND anonymity is still refused:
    $CURL $M:$P:127.0.0.1 --cert $CLI/client.crt --key $CLI/client.key \
        https://$M:$P/whoami                       # -> verify=SUCCESS dn=...
    $CURL $M:$P:127.0.0.1 -o /dev/null -w '%{http_code}\n' https://$M:$P/whoami   # -> 400

Notes.
  * ssl_client_certificate does two jobs at once: it is the trust store, and
    its subjects are broadcast in the CertificateRequest as acceptable CA
    names. Loading a large bundle leaks your internal CA topology and can blow
    past client-side handshake limits — ssl_trusted_certificate lets you trust
    without advertising.
  * ssl_verify_depth counts intermediates between the leaf and the trust
    anchor. A two-tier PKI needs at least 2. The symptom of getting this wrong
    is indistinguishable from a missing CA, which is why you check both.
  * Neither `ssl_verify_client optional` nor re-issuing clients directly off
    the root is a fix: the first disables the control you were asked to keep,
    the second destroys the reason a two-tier PKI exists — the root stays
    offline so that compromising the online issuer does not end the PKI.

GENERAL DIAGNOSTIC LADDER for any X.509/TLS incident
  1. Is the process up and the port open?          systemctl status / ss -lntp
  2. Does the config even parse?                   nginx -t </dev/null
  3. What is ON DISK?                              openssl x509 -noout -text
  4. Does the key match the cert?                  -pubkey | sha256 both sides
  5. What goes ON THE WIRE?                        openssl s_client -showcerts
  6. Does the PATH build?                          openssl verify -untrusted
  7. Is it in DATE?                                openssl x509 -checkend
  8. Does the NAME match?                          -verify_hostname / curl
  9. Is it REVOKED?                                openssl verify -crl_check
 10. For client auth, repeat 3-9 from the server's point of view, in the
     server's error log — the client only ever sees "400" or a TLS alert.

Verify codes worth memorising for 303-300:
  10 certificate has expired            19 self-signed certificate in chain
  18 self-signed certificate            20 unable to get local issuer certificate
  21 unable to verify the first certificate
  23 certificate revoked                24 invalid CA certificate
  26 unsupported certificate purpose (keyUsage / extendedKeyUsage mismatch)
  62 hostname mismatch
==== END SOLUTION KEY ====================================================
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-3-303/331.2/lab)
