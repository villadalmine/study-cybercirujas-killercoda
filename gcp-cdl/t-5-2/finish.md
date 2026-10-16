## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — do not read until the scanner has beaten you at least twice.

 Work top-down through the SCC findings by severity, exactly as you would in
 the real console. All paths are relative to /opt/gdl-defense-lab.

 STEP 0 — Read the backlog before touching anything
    sudo /opt/gdl-defense-lab/bin/scc-scan.sh

 Expected (8 findings): PUBLIC_BUCKET_ACL, UNENCRYPTED_DATA,
 KEY_MATERIAL_EXPOSED (CRITICAL); OVER_PRIVILEGED_ACCOUNT, BUCKET_POLICY_WEAK,
 OPEN_FIREWALL, AUDIT_LOG_TAMPERED (+ AUDIT_LOG_MUTABLE on ext4/xfs) (HIGH);
 ORG_POLICY_DISABLED (MEDIUM).

 STEP 1 — Stop the bleeding at the perimeter (VPC firewall)
 Close 0.0.0.0/0 ingress first: it is the one change that makes the exposure
 unreachable while you fix the rest. Keep loopback working.

    # nftables hosts:
    sudo nft add rule inet gdl_lab input iif != "lo" tcp dport 8080 drop

    # iptables hosts:
    sudo iptables -I INPUT -p tcp --dport 8080 '!' -i lo -j DROP

    # Verify both directions:
    curl -s --max-time 3 http://127.0.0.1:8080/            # still answers
    curl -s --max-time 3 http://$(hostname -I | awk '{print $1}'):8080/ ; echo "exit=$?"
    # -> exit=28 (timeout). The service is up; the internet just cannot reach it.

 Real-world equivalent: a VPC firewall rule denying ingress, or removing the
 external IP entirely and fronting the service with Cloud Load Balancing +
 Cloud Armor.  https://cloud.google.com/firewall/docs/firewalls

 STEP 2 — Remove the public principal and the basic role (Cloud IAM)
    sudo python3 - <<'PY'
    import json
    p = "/opt/gdl-defense-lab/iam/policy.json"
    d = json.load(open(p))
    for b in d["bindings"]:
        b["members"] = [m for m in b["members"]
                        if m not in ("allUsers", "allAuthenticatedUsers")]
    d["bindings"] = [b for b in d["bindings"]
                     if b["role"] not in ("roles/owner", "roles/editor")
                     and b["members"]]
    json.dump(d, open(p, "w"), indent=2)
    PY

    grep -c allUsers /opt/gdl-defense-lab/iam/policy.json   # -> 0

 The ETL service account keeps roles/storage.objectAdmin, which is what it
 actually needs. Basic roles (owner/editor/viewer) are the single most common
 privilege-escalation path in a GCP estate — replace them with predefined or
 custom roles.  https://cloud.google.com/iam/docs/roles-overview

 STEP 3 — Re-encrypt the data and destroy the cleartext copy (CMEK)
 Order matters: fix the key permissions FIRST, otherwise you re-encrypt with a
 key that the whole machine has already read.

    sudo chmod 0400 /opt/gdl-defense-lab/keys/cmek.key
    cd /opt/gdl-defense-lab
    sudo openssl enc -aes-256-cbc -pbkdf2 -salt \
         -in data/customers.csv -out data/customers.csv.enc \
         -pass file:keys/cmek.key
    sudo chmod 0640 data/customers.csv.enc
    sudo shred -u data/customers.csv
    sudo chmod 0750 data

    # Prove the ciphertext still yields the attested object:
    sudo openssl enc -d -aes-256-cbc -pbkdf2 -in data/customers.csv.enc \
         -pass file:keys/cmek.key | sha256sum
    sudo cat data/.customers.sha256      # the two hashes must match

 In Google Cloud you would never hold the key on the VM: Cloud KMS holds it,
 the object is CMEK-encrypted, and revoking the key revokes the data. That is
 the control that turns "we lost a bucket" into "we lost ciphertext".
    https://cloud.google.com/kms/docs/cmek

 STEP 4 — Restore the audit trail from the export sink, then re-lock it
    sudo chattr -a /opt/gdl-defense-lab/logs/audit.log 2>/dev/null || true
    sudo cp /opt/gdl-defense-lab/.log-sink/audit.log \
            /opt/gdl-defense-lab/logs/audit.log
    sudo chmod 0640 /opt/gdl-defense-lab/logs/audit.log
    sudo chattr +a /opt/gdl-defense-lab/logs/audit.log 2>/dev/null || true
    lsattr /opt/gdl-defense-lab/logs/audit.log     # -> -----a-------------- ...

 Note what saved you: the copy lived outside the project that was compromised.
 Admin Activity audit logs in Google Cloud cannot be disabled and are written
 by Google, not by your workload; exporting them to a locked-down project with
 a separate IAM boundary is the standard pattern.
    https://cloud.google.com/logging/docs/audit

 STEP 5 — Re-enforce the guardrail so step 2 cannot recur (Org Policy)
    sudo sed -i '/storage.publicAccessPrevention/,+2 s/enforced: false/enforced: true/' \
         /opt/gdl-defense-lab/org-policy/constraints.yaml
    grep -A2 publicAccessPrevention /opt/gdl-defense-lab/org-policy/constraints.yaml

 This is the highest-leverage step and the lowest severity in the report,
 which is exactly the trap. Steps 1-4 fix one incident; step 5 makes the
 public-bucket class of incident impossible for every project under the
 folder, including projects that do not exist yet. Preventive guardrails beat
 detective controls on cost per incident avoided.
    https://cloud.google.com/storage/docs/public-access-prevention
    https://cloud.google.com/resource-manager/docs/organization-policy/overview

 STEP 6 — Verify
    sudo /opt/gdl-defense-lab/bin/scc-scan.sh
    # SCAN COMPLETE: 0 findings — posture restored.
    echo $?    # -> 0

    sudo /opt/gdl-defense-lab/../gdl-defense-lab/bin/scc-scan.sh >/dev/null && \
      echo "clean"

 Then tear down:
    sudo ./5.2-break-and-fix.sh --reset

 ANSWER KEY for the exam-level question
 Layer      | Google Cloud service        | Contains on its own        | Business metric
 -----------+-----------------------------+----------------------------+---------------------------
 Perimeter  | VPC firewall, Cloud Armor,  | Public IAM binding is      | Breach probability;
            | Private Google Access       | unreachable from internet  | DDoS/L7 attack cost
 Identity   | Cloud IAM, IAM Recommender  | Open port serves nothing   | Insider + credential-theft
            |                             | without an authorized      | blast radius
            |                             | principal                  |
 Guardrails | Organization Policy Service | The public binding is      | Cost of prevention vs
            |                             | rejected at write time     | cost of remediation, org-wide
 Data       | Cloud KMS / CMEK, default   | What leaks is ciphertext   | Regulatory exposure
            | encryption at rest          |                            | (GDPR Art. 34 safe harbour)
 Audit      | Cloud Audit Logs + sink to  | You can scope, notify and  | Time to detect/respond,
            | a restricted project        | prove the impact           | disclosure liability
 Detection  | Security Command Center     | Google finds it even when  | Shared fate: Google is a
            | (Google-operated)           | all of the above are off   | participant, not a vendor

 The business value statement the exam wants: defense in depth means no single
 human error becomes a breach, because the next layer is owned by a different
 team, enforced by a different mechanism, and — for the outermost layer —
 operated by Google itself under a shared-fate model, with secure-by-default
 infrastructure, curated detectors, and risk-protection programs on top.
    https://cloud.google.com/security/overview/whitepaper
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/gcp-cdl/5.2/lab)
