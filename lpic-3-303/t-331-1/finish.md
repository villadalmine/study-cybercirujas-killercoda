## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
>>> SOLUTION <<<
 STEP-BY-STEP SOLUTION - 331.1 break & fix "The leaked key incident"
 (do not read this until you have worked the three symptoms yourself)

 STEP 0 - Read the failure, do not guess it
     systemctl status nginx --no-pager
     journalctl -u nginx -n 30 --no-pager
     nginx -t

 Expected:
     nginx: [emerg] SSL_CTX_use_PrivateKey_file("/etc/pki/lab/private/server.key")
     failed (SSL: error:05800074:x509 certificate routines::key values mismatch)
     nginx: configuration file /etc/nginx/nginx.conf test failed

 "key values mismatch" is unambiguous: the certificate's SubjectPublicKeyInfo
 and the private key are not two halves of the same pair.

 STEP 1 - Prove the mismatch (the canonical modulus comparison)
     openssl x509 -noout -modulus -in /etc/pki/lab/server/server.crt | openssl sha256
     openssl rsa  -noout -modulus -in /etc/pki/lab/private/server.key | openssl sha256

 Expected: two DIFFERENT digests. The algorithm-agnostic equivalent, which
 also works for EC keys, is to compare the public keys themselves:

     openssl x509 -in /etc/pki/lab/server/server.crt -noout -pubkey | openssl sha256
     openssl pkey -in /etc/pki/lab/private/server.key -pubout        | openssl sha256

 STEP 2 - (Phase A, optional) Recover the matching key from the PKCS#12
 This is the "get it back online now" move. Inspect the archive first:

     openssl pkcs12 -info -nokeys -in /etc/pki/lab/private/server-archive.p12 \
         -passin file:/etc/pki/lab/private/p12.pass

 Extract the private key (-nodes / -noenc writes it unencrypted, which is
 what nginx needs since it cannot prompt for a passphrase at boot):

     umask 077
     openssl pkcs12 -in /etc/pki/lab/private/server-archive.p12 \
         -passin file:/etc/pki/lab/private/p12.pass \
         -nocerts -nodes -out /etc/pki/lab/private/server-recovered.key
     chmod 400 /etc/pki/lab/private/server-recovered.key

 Confirm it matches the deployed certificate, then point nginx at it:
     openssl pkey -in /etc/pki/lab/private/server-recovered.key -pubout | openssl sha256
     # -> same digest as the certificate's pubkey

 Note for the exam: on OpenSSL 3.x, -nodes is spelled -noenc (both accepted),
 and reading a legacy RC2-encrypted .p12 may require -legacy.

 STEP 3 - Understand why STEP 2 is not the end
     openssl x509 -noout -serial -in /etc/pki/lab/server/server.crt
     openssl crl  -noout -text  -in /etc/pki/lab/crl/intermediate.crl.pem
     openssl ca -config /etc/pki/lab/intermediate/openssl.cnf \
         -status <serial-from-above>

 Expected: that serial appears under "Revoked Certificates" with
 "CRL entry extensions: X509v3 CRL Reason Code: Key Compromise", and
 'openssl ca -status' answers "Revoked (K)".

     openssl x509 -noout -text -in /etc/pki/lab/server/server.crt \
         | grep -A1 'Subject Alternative Name'

 Expected: no output at all - there is no SAN extension.

 Two structural defects, one remedy: issue a NEW certificate over a NEW key
 pair, using the correct extension profile. Revocation cannot be undone, and
 re-signing the same CSR would just re-bind the leaked public key.

 STEP 4 - New key pair (the compromised one must never come back)
     umask 077
     openssl genrsa -out /etc/pki/lab/private/server-new.key 2048
     chmod 400 /etc/pki/lab/private/server-new.key

 EC is equally valid and cheaper on the handshake:
     openssl ecparam -name prime256v1 -genkey -noout \
         -out /etc/pki/lab/private/server-new.key

 STEP 5 - New CSR
     openssl req -config /etc/pki/lab/intermediate/openssl.cnf \
         -new -sha256 \
         -key /etc/pki/lab/private/server-new.key \
         -subj "/C=AR/ST=Buenos Aires/O=PKI Lab/OU=Web/CN=pki-lab.example" \
         -out /etc/pki/lab/server/server-new.csr

     openssl req -noout -text -verify -in /etc/pki/lab/server/server-new.csr
     # "Certificate request self-signature verify OK" proves the CSR was
     # signed by the key it carries - that is a proof of possession, nothing
     # more. A CSR is a request, not a certificate: it asserts identity, the
     # CA decides it.

 STEP 6 - Sign it with the CORRECT profile
 The lab CA runs with copy_extensions = none, so extensions in the CSR are
 deliberately ignored (otherwise any requester could ask for CA:TRUE). The
 SAN must therefore come from the CA's own profile:

     openssl ca -config /etc/pki/lab/intermediate/openssl.cnf \
         -extensions server_cert -days 365 -notext -md sha256 \
         -in  /etc/pki/lab/server/server-new.csr \
         -out /etc/pki/lab/server/server-new.crt

 Answer 'y' twice (or add -batch). The issuing CA records the new row in
 /etc/pki/lab/intermediate/index.txt with flag V and increments serial.

 Verify the profile before deploying it:
     openssl x509 -noout -text -in /etc/pki/lab/server/server-new.crt | sed -n '/X509v3/,/Signature Algorithm/p'
 Expected to contain:
     X509v3 Basic Constraints: CA:FALSE
     X509v3 Key Usage: critical  Digital Signature, Key Encipherment
     X509v3 Extended Key Usage:  TLS Web Server Authentication
     X509v3 Subject Alternative Name:
         DNS:pki-lab.example, DNS:www.pki-lab.example, DNS:localhost, IP Address:127.0.0.1
     X509v3 CRL Distribution Points: URI:http://pki-lab.example/crl/intermediate.crl.pem

 If you need a SAN that is not in [ alt_names ], either edit that section or
 sign with an ad-hoc extension file:
     printf 'subjectAltName=DNS:pki-lab.example,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' > /tmp/ext.cnf
     openssl ca -config .../openssl.cnf -extfile /tmp/ext.cnf -in ... -out ...

 STEP 7 - Build a real chain file (this is fault 2)
 Order matters and is defined by TLS: leaf first, then each issuer upwards.
 The root is intentionally NOT included - sending it wastes bytes and proves
 nothing, because a client that does not already trust it will not start
 trusting it just because the server offered it.

     cat /etc/pki/lab/server/server-new.crt \
         /etc/pki/lab/intermediate/certs/intermediate.cert.pem \
         > /etc/pki/lab/server/fullchain.crt
     chmod 444 /etc/pki/lab/server/fullchain.crt

 Offline validation before touching the service:
     openssl verify -CAfile /etc/pki/lab/root/certs/ca.cert.pem \
         -untrusted /etc/pki/lab/intermediate/certs/intermediate.cert.pem \
         -verify_hostname pki-lab.example \
         /etc/pki/lab/server/server-new.crt
     # -> server-new.crt: OK

 STEP 8 - Point nginx at the new key and reload
     # /etc/nginx/conf.d/pkilab.conf
     #   ssl_certificate     /etc/pki/lab/server/fullchain.crt;
     #   ssl_certificate_key /etc/pki/lab/private/server-new.key;
     sed -i 's#private/server.key#private/server-new.key#' /etc/nginx/conf.d/pkilab.conf
     nginx -t && systemctl restart nginx

 On RHEL/Fedora with SELinux enforcing, if nginx cannot read the material:
     restorecon -Rv /etc/pki/lab
     ausearch -m avc -ts recent | audit2why

 STEP 9 - Revoke the old leaf properly and refresh the CRL
 It is already revoked in this lab, but this is the operation you must know,
 and the CRL should be regenerated whenever the database changes:

     openssl ca -config /etc/pki/lab/intermediate/openssl.cnf \
         -revoke /etc/pki/lab/server/server.crt -crl_reason keyCompromise
     openssl ca -config /etc/pki/lab/intermediate/openssl.cnf \
         -gencrl -out /etc/pki/lab/crl/intermediate.crl.pem
     openssl crl -noout -text -in /etc/pki/lab/crl/intermediate.crl.pem \
         | head -20

 Valid -crl_reason values: unspecified, keyCompromise, CACompromise,
 affiliationChanged, superseded, cessationOfOperation, certificateHold,
 removeFromCRL. Only certificateHold is reversible.

 A CRL has a nextUpdate; once it passes, strict validators treat the CRL as
 missing and -crl_check fails. Regenerating the CRL on a timer (default
 default_crl_days = 30 here) is an operational duty, not an optional chore.

 STEP 10 - Validate the running endpoint the way a client does
     openssl s_client -connect 127.0.0.1:443 -servername pki-lab.example \
         -showcerts -verify_return_error </dev/null | head -40
 Expected:
     depth=2 ... CN = PKI Lab Root CA
     depth=1 ... CN = PKI Lab Intermediate CA
     depth=0 ... CN = pki-lab.example
     Verify return code: 0 (ok)

     curl -v https://pki-lab.example/ -o /dev/null
     # no -k, no --cacert: it must validate against the system trust store

 Full revocation-aware validation:
     cat /etc/pki/lab/crl/root.crl.pem /etc/pki/lab/crl/intermediate.crl.pem > /tmp/all.crl
     openssl verify -crl_check_all \
         -CAfile /etc/pki/lab/root/certs/ca.cert.pem \
         -untrusted /etc/pki/lab/intermediate/certs/intermediate.cert.pem \
         -CRLfile /tmp/all.crl \
         /etc/pki/lab/server/server-new.crt
     # -> OK   (with the OLD certificate this prints:
     #          error 23 at 0 depth lookup: certificate revoked)

 Finally:
     ./331.1-break-and-fix.sh verify     # 10/10

 WHY EACH FAULT LOOKED THE WAY IT DID (exam-level takeaways)
 * key values mismatch  -> a certificate binds a PUBLIC key to a name; the
   private key is never inside it. Any TLS server verifies the pairing at
   load time, which is why the failure is at startup, not at handshake.

 * unable to get local issuer certificate (X509_V_ERR = 20) -> the client
   trusts the root but cannot BUILD the path, because the server did not
   send the intermediate. Trusting the root is not enough; chain assembly is
   the server's responsibility. Error 21 (unable to verify the first
   certificate) is the same disease seen from a different angle, and error 2
   is the equivalent when the missing link is above a trusted anchor.

 * hostname mismatch -> since RFC 6125 / CA-Browser Forum baseline, identity
   lives in subjectAltName; commonName is legacy and ignored by modern
   clients. And because copy_extensions defaults to none, a SAN present in
   the CSR is silently dropped by 'openssl ca' - the CA profile decides.

 * certificate revoked (X509_V_ERR = 23) -> revocation is a statement about
   a SERIAL made by the ISSUER, distributed either as a CRL (pull the whole
   list, crlDistributionPoints) or per-certificate over OCSP
   (authorityInfoAccess OCSP;URI, plus OCSP stapling on the server side).
   Re-issuing over the same key pair defeats the purpose of the revocation:
   keyCompromise means the KEY is burned, not just that certificate.

 RELATED COMMANDS WORTH DRILLING FOR 331.1
     openssl x509 -in c.pem -noout -text -certopt no_sigdump,no_pubkey
     openssl x509 -in c.der -inform DER -out c.pem -outform PEM     # DER <-> PEM
     openssl x509 -in c.pem -noout -fingerprint -sha256
     openssl x509 -in c.pem -noout -dates -subject -issuer -serial
     openssl x509 -in c.pem -noout -checkend 2592000                # expires in 30 d?
     openssl req  -in r.csr -noout -text -verify
     openssl crl  -in crl.pem -noout -lastupdate -nextupdate
     openssl ocsp -issuer int.pem -cert leaf.pem -url http://ocsp.example -text
     openssl pkcs12 -export -inkey k.pem -in c.pem -certfile chain.pem -out b.p12
     openssl pkcs8 -topk8 -in k.pem -out k8.pem -v2 aes256          # PKCS#1 -> PKCS#8
     openssl s_client -connect h:443 -servername h -status          # OCSP stapling
     openssl verify -CApath /etc/ssl/certs -purpose sslserver c.pem
     trust list / update-ca-trust extract   (RHEL) | update-ca-certificates (Debian)

 Source: LPI 303-300 exam objectives, topic 331.1
         https://www.lpi.org/our-certifications/exam-303-objectives/
 OpenSSL manual pages: x509(1), req(1), ca(1), crl(1), verify(1),
         pkcs12(1), s_client(1), config(5), x509v3_config(5)
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-3-303/331.1/lab)
