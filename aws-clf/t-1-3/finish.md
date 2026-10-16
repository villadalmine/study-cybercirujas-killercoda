## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — do not read until you have tried. Step by step.

 ── STEP 0 · Reconnaissance ────────────────────────────────────────────────

   systemctl --failed
   systemctl status clf13-cloud-inventory --no-pager -l
   journalctl -u clf13-cloud-inventory -n 40 --no-pager

 The journal ends with:

   starting inventory-api site=aws-ap-southeast-2 bind=10.20.0.15:18080 ...
   OSError: [Errno 99] Cannot assign requested address

 Errno 99 is EADDRNOTAVAIL: the process asked to bind an IP that does not
 exist on this host. Confirm with `ip -brief addr show` — 10.20.0.15 is on the
 data centre NIC of inv-app-01, not on the target instance.

 ── STEP 1 · Fault A: strip the source's network identity ──────────────────

   sudo sed -i 's/^bind_address .*= .*/bind_address   = 127.0.30.11/' \
        /opt/aws-clf-c02/lab-1.3/cloud/etc/inventory.conf
   sudo systemctl restart clf13-cloud-inventory
   systemctl is-active clf13-cloud-inventory        # -> active
   curl -si http://127.0.30.11:18080/health

 (0.0.0.0 also works, but note that the source already holds
 127.0.20.15:18080 — one address/port pair per socket. Binding the specific
 target address is what a real EC2 instance does.)

 The service is now up and returns:

   HTTP/1.0 503 Service Unavailable
   {"status": "degraded", ..., "missing": ["catalog.db", ".license.key"]}

 Symptom 1 is fixed; symptom 2 is now visible. That ordering is deliberate —
 a failed unit hides every application-level fault behind it.

 ── STEP 2 · Fault B: fix the replication job, not the copy ────────────────

   /opt/aws-clf-c02/lab-1.3/migration/validate_replication.sh

     MISSING   .license.key
     MISSING   catalog.db
     RESULT: FAILED — 2 artifact(s) not replicated correctly. DO NOT CUT OVER.

 Open migration/replicate.sh and read the filters:

     EXCLUDES=(
       '*.tmp'
       '*.swp'
       'core.*'
       '.*'      # hidden files: editor/temp droppings     <-- drops .license.key
       '*.db'    # databases are handled by DMS            <-- drops catalog.db
     )

 Both assumptions are wrong for this workload. catalog.db is embedded
 application state on the filesystem; AWS DMS migrates the PostgreSQL engine on
 srv-db-01 and never sees it. .license.key is a runtime dependency that happens
 to start with a dot. Delete the two patterns:

   sudo sed -i "/^  '\.\*'/d;/^  '\*\.db'/d" \
        /opt/aws-clf-c02/lab-1.3/migration/replicate.sh
   sudo /opt/aws-clf-c02/lab-1.3/migration/replicate.sh
   /opt/aws-clf-c02/lab-1.3/migration/validate_replication.sh   # RESULT: PASSED
   curl -s http://127.0.30.11:18080/health   # {"status": "ok", ...}
   curl -s http://127.0.30.11:18080/inventory | head -c 200

 Copying the two files by hand would turn /health green and still be wrong:
 the next replication cycle deletes them again. Check [2] re-runs the job on
 purpose to catch exactly that shortcut.

 ── STEP 3 · Fault C: reconcile the 7 Rs classification ────────────────────

   /opt/aws-clf-c02/lab-1.3/migration/validate_wave.sh

     R2 VIOLATION  srv-inv-01: strategy 'retire' but scheduled in wave 1 ...
     R3 VIOLATION  srv-inv-01: strategy 'retire' requires wave=none (found '1')
     R3 VIOLATION  srv-inv-01: retire requires a decommission_date
     R6 VIOLATION  srv-inv-01: runbook method 'mgn-lift-and-shift' implies
                   rehost, portfolio says 'retire'

 discovery/strategy_rules.md: in active use, source frozen, OS supported by
 MGN, must move with no code change => rehost. The runbook already says
 mgn-lift-and-shift. Correct the portfolio, not the runbook:

   sudo sed -i 's/^\(srv-inv-01,.*\),retire,1,$/\1,rehost,1,/' \
        /opt/aws-clf-c02/lab-1.3/discovery/inventory.csv
   /opt/aws-clf-c02/lab-1.3/migration/validate_wave.sh   # RESULT: PASSED

 ── STEP 4 · Grade ─────────────────────────────────────────────────────────

   sudo ./clf-c02-1.3-break-fix.sh --verify      # SCORE: 3/3
   sudo ./clf-c02-1.3-break-fix.sh --cleanup

 ── EXTRA CREDIT (not graded) ──────────────────────────────────────────────

 cloud/etc/inventory.conf still points db_endpoint at
 inv-db-01.wattle.internal:5432 and license_server at lic-09 (srv-lic-09 is
 classified retain — it never moves). Neither is exercised by /health, and
 both are real cutover work:
   · the database is being replatformed with AWS DMS, so after cutover the
     endpoint is an Amazon RDS endpoint, not the on-prem hostname;
   · the licence server stays on-premises, so the target needs hybrid
     connectivity (AWS Site-to-Site VPN or AWS Direct Connect) and a DNS
     resolution path to reach it. That dependency is precisely why "retain"
     is a strategy and not an omission.

 ── WHAT THE EXAM ASKS ABOUT THIS (Task 1.3) ───────────────────────────────

 · The 7 Rs and how to recognise each from a one-paragraph scenario:
   rehost (MGN, no code change), replatform (e.g. self-managed DB -> Amazon
   RDS via DMS), refactor (re-architect), repurchase (move to SaaS), retire
   (switch off), retain (leave in place for now), relocate (VMware Cloud on
   AWS, hypervisor-level).
 · AWS Cloud Adoption Framework: six perspectives — Business, People,
   Governance, Platform, Security, Operations — used to find capability gaps
   before a migration, and its phases Envision, Align, Launch, Scale.
 · Migration tooling and when each applies: AWS Application Migration Service
   (server rehost), AWS DMS (databases, homogeneous and heterogeneous),
   AWS DataSync (online file transfer over the network), AWS Snow Family
   (offline bulk transfer when the network cannot carry the data in time),
   AWS Migration Hub (single pane over the portfolio), AWS Application
   Discovery Service (the inventory that feeds the 7 Rs decision).
 · Benefits framed as the exam frames them: shifting CapEx to OpEx, stopping
   guesses about capacity, higher business agility and speed of experiments,
   and operational resilience — see the CLF-C02 exam guide, Domain 1.

 Sources:
   https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
   https://docs.aws.amazon.com/prescriptive-guidance/latest/large-migration-guide/migration-strategies.html
   https://docs.aws.amazon.com/whitepapers/latest/overview-aws-cloud-adoption-framework/welcome.html
   https://docs.aws.amazon.com/mgn/latest/ug/what-is-application-migration-service.html
   https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html
   https://docs.aws.amazon.com/datasync/latest/userguide/what-is-datasync.html
   https://docs.aws.amazon.com/snowball/latest/developer-guide/whatisedge.html
   https://docs.aws.amazon.com/migrationhub/latest/ug/whatishub.html
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/aws-clf/1.3/lab)
