## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — do not read until `verify` has beaten you at least twice

 Set a shell variable first so the commands below are copy-pasteable:

     LAB=~/labs/gcp-cdl-5.1        # or your LAB_ROOT
     PORT=18443
     cd "$LAB"

 STEP 0 — Triage before touching anything
     ./break-fix-5.1.sh verify      # 11 checks, see which fail
     ./break-fix-5.1.sh status      # posture in one screen

 Reproduce the headline symptom, because it is the one that ends careers:

     curl -sk https://127.0.0.1:$PORT/v1/b/lab-finance-prod/o/q3-payroll.csv
     # -> HTTP 200 + IBANs, with no Authorization header at all

 STEP 1 — Fault 1: IAM. Remove public access, restore least privilege.
 Edit iam/policy.json and (a) delete the "allUsers" member, (b) delete the
 whole roles/owner binding for the intern. The intern stays in
 roles/storage.objectViewer, which grants exactly storage.objects.get.

     cat > iam/policy.json <<'JSON'
     {
       "version": 3,
       "etag": "BwXlabPolicyEtag=",
       "resource": "//storage.googleapis.com/projects/_/buckets/lab-finance-prod",
       "bindings": [
         {
           "role": "roles/storage.objectViewer",
           "members": [
             "user:sre-oncall@lab.example.com",
             "user:data-intern@lab.example.com"
           ]
         },
         {
           "role": "roles/storage.objectAdmin",
           "members": [
             "serviceAccount:etl-writer@lab-fin-prod-01.iam.gserviceaccount.com"
           ]
         }
       ]
     }
     JSON
     chmod 640 iam/policy.json

 Verify immediately — no restart, the policy is evaluated per request:

     curl -s -o /dev/null -w '%{http_code}\n' -k \
       https://127.0.0.1:$PORT/v1/b/lab-finance-prod/o/q3-payroll.csv        # 403
     curl -s -o /dev/null -w '%{http_code}\n' -k \
       -H 'Authorization: Bearer data-intern@lab.example.com' \
       https://127.0.0.1:$PORT/v1/b/lab-finance-prod/o/q3-payroll.csv        # 200

 On real Google Cloud the equivalent moves are:
     gcloud storage buckets remove-iam-policy-binding gs://BUCKET \
         --member=allUsers --role=roles/storage.objectViewer
     gcloud storage buckets update gs://BUCKET --public-access-prevention
     gcloud projects remove-iam-policy-binding PROJECT \
         --member=user:EMAIL --role=roles/owner
 and the durable control is an org policy constraint
 (constraints/storage.publicAccessPrevention) plus IAM Recommender to shrink
 roles automatically.  https://cloud.google.com/storage/docs/public-access-prevention

 STEP 2 — Fault 2: encryption in transit. Re-enable TLS and RESTART.
     grep -n '^tls=' etc/server.conf            # tls=off
     sed -i 's/^tls=.*/tls=on/' etc/server.conf
     ls -l tls/                                 # server.key must be 0600
     chmod 600 tls/server.key; chmod 644 tls/server.crt
     ./break-fix-5.1.sh restart                 # the socket is bound at startup

 Verify both directions — TLS must work, cleartext must not be served:

     curl -s --cacert tls/server.crt https://127.0.0.1:$PORT/healthz
     curl -s -m 3 http://127.0.0.1:$PORT/healthz ; echo "exit=$?"   # non-zero
     openssl s_client -connect 127.0.0.1:$PORT -tls1_2 </dev/null 2>/dev/null \
       | openssl x509 -noout -subject -dates

 Exam framing: Google encrypts traffic between its data centres for you, but
 the customer chooses whether the front door speaks TLS at all, which cipher
 floor it enforces, and whether the certificate is valid. A bearer token sent
 over cleartext is a credential you have already lost.
 https://cloud.google.com/docs/security/encryption-in-transit

 STEP 3 — Fault 3: encryption at rest and key hygiene.
 3a. Lock the key and remove the copy that was backed up inside the bucket:

     chmod 600 kms/keyring/prod-key.b64
     chmod 700 kms kms/keyring
     find data/ -name '*key*'                        # data/objects/.../prod-key.b64.bak
     rm -f data/objects/lab-finance-prod/prod-key.b64.bak

 3b. Re-encrypt the object in place, with the parameters it was created with:

     openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
       -pass file:kms/keyring/prod-key.b64 \
       -in  data/objects/lab-finance-prod/q3-payroll.csv \
       -out /tmp/q3.enc
     mv /tmp/q3.enc data/objects/lab-finance-prod/q3-payroll.csv
     chmod 640 data/objects/lab-finance-prod/q3-payroll.csv
     head -c 8 data/objects/lab-finance-prod/q3-payroll.csv; echo   # Salted__

 3c. Turn the control back on so future writes are encrypted too:

     sed -i 's/^encryption_at_rest=.*/encryption_at_rest=on/' etc/server.conf

 3d. OPTIONAL, and the right instinct after any key exposure — rotate. Order
     matters: decrypt with the old key, encrypt with the new, then retire the
     old key OUTSIDE the data path. Never delete the old key before every
     object encrypted under it has been rewritten.

     openssl rand -base64 32 > kms/keyring/prod-key-v2.b64
     chmod 600 kms/keyring/prod-key-v2.b64
     openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
       -pass file:kms/keyring/prod-key.b64 \
       -in data/objects/lab-finance-prod/q3-payroll.csv -out /tmp/q3.plain
     openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
       -pass file:kms/keyring/prod-key-v2.b64 -in /tmp/q3.plain -out /tmp/q3.v2
     mv /tmp/q3.v2 data/objects/lab-finance-prod/q3-payroll.csv
     shred -u /tmp/q3.plain 2>/dev/null || rm -f /tmp/q3.plain
     mv kms/keyring/prod-key-v2.b64 kms/keyring/prod-key.b64      # server reads this path

     (In Cloud KMS this is one call — `gcloud kms keys versions create` plus a
     rewrite of the objects — and rotation can be scheduled:
      https://cloud.google.com/kms/docs/key-rotation)

 Exam framing: Google Cloud encrypts all customer data at rest by default with
 Google-managed keys. CMEK (Cloud KMS) and CSEK move progressively more of the
 key custody — and the responsibility for losing it — to the customer. The
 only thing that never changes is that a key stored beside the data it
 protects provides no confidentiality at all.

 STEP 4 — Fault 4: restore the audit trail.
     sed -i 's/^audit_logging=.*/audit_logging=on/' etc/server.conf
     chmod 640 var/log/audit.log
     curl -s --cacert tls/server.crt \
       -H 'Authorization: Bearer sre-oncall@lab.example.com' \
       https://127.0.0.1:$PORT/v1/b/lab-finance-prod/o/q3-payroll.csv >/dev/null
     tail -1 var/log/audit.log | python3 -m json.tool

 Read the entry out loud: principalEmail (who), authorizationInfo.granted and
 role (under what authority), callerIp (from where), timestamp (when),
 methodName + resourceName (what). Those five answers are the difference
 between "we had an incident" and "we had an incident and here is the exact
 blast radius". Data Access logs for storage.objects.get are NOT enabled by
 default in Google Cloud — Admin Activity logs are — so this is a customer
 decision, and the customer pays for the volume.
 https://cloud.google.com/logging/docs/audit

 STEP 5 — Confirm and close
     ./break-fix-5.1.sh verify        # expect 11/11 and exit code 0
     echo $?

 WHY EACH FAULT IS ON THE EXAM (topic 5.1, weight 9%)
  Fault 1 -> Shared responsibility + IAM + principle of least privilege.
             The provider secures the hardware, hypervisor, storage media and
             physical facility. Identity, roles, bindings and public exposure
             are always the customer's. Expect scenario questions where the
             "right answer" is the narrowest predefined role, not a custom one
             and never a basic role (owner/editor/viewer) in production.
  Fault 2 -> Encryption in transit. TLS at the edge is a customer control;
             Google's internal encryption between services does not rescue an
             endpoint the customer published over HTTP.
  Fault 3 -> Encryption at rest, default vs CMEK vs CSEK, and key management.
             Know the ladder and know who holds the key at each rung.
  Fault 4 -> Defence in depth and the CIA triad's forgotten leg. Preventive
             controls fail; detective controls tell you how badly. Cloud Audit
             Logs, VPC Service Controls, org policy constraints and zero-trust
             access (BeyondCorp: never trust the network, always verify the
             identity and device) are the layers stacked behind IAM.

  All four are things the customer configures. That sentence is the exam
  objective, and this lab is that sentence with consequences attached.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/gcp-cdl/5.1/lab)
