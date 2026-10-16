## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION -- do not read until you have genuinely attempted the fix.

 STEP 0 -- Establish what is actually broken before changing anything.
   systemctl status cdl-lab-billing
   journalctl -u cdl-lab-billing -n 50 --no-pager

 Expected output on the first pass:

   * cdl-lab-billing.service - cdl-lab billing service
        Loaded: loaded (/etc/systemd/system/cdl-lab-billing.service; enabled)
        Active: activating (auto-restart) (Result: exit-code)
       Process: 2481 ExecStart=... (code=exited, status=78)

   FATAL: cannot start: ValueError: /opt/cdl-lab/app.conf:2: malformed
          directive: 'listen_port 8142'

 Note what this already tells you: systemd is restarting the unit every 3
 seconds and failing every time. Automation is working perfectly and fixing
 nothing, because the fault is in content the platform does not understand.
 This is the mechanical version of "the provider cannot fix your config".


 STEP 1 -- Fault 1: the malformed configuration directive.
 The parser requires 'key = value'. Line 2 lost its '='.

   sudo sed -i 's/^listen_port 8142$/listen_port = 8142/' /opt/cdl-lab/app.conf

 Confirm the whole file is well-formed before restarting -- fixing one line and
 restarting blind is how a five-minute incident becomes a thirty-minute one:

   grep -vE '^\s*(#|$)' /opt/cdl-lab/app.conf
     listen_port = 8142
     data_file = /var/lib/cdl-lab/ledger.json
     mode = production

   sudo systemctl restart cdl-lab-billing
   systemctl is-active cdl-lab-billing        # -> active

 The unit now starts. The service is NOT yet healthy -- and the distinction
 between "the process is running" and "the service is serving" is worth more
 than the fix itself.


 STEP 2 -- Fault 2: the service account lost read access to its own data.
   curl -s http://127.0.0.1:8142/billing

   {
     "status": "UNHEALTHY",
     "reason": "PermissionError",
     "detail": "[Errno 13] Permission denied: '/var/lib/cdl-lab/ledger.json'",
     "responsibility": "CUSTOMER"
   }

   ls -l /var/lib/cdl-lab/ledger.json
     -rw------- 1 root root 612 ... /var/lib/cdl-lab/ledger.json

 Ownership was moved to root and the group bit removed. The correct fix is to
 restore least privilege, NOT to escalate the service:

   sudo chown cdl-lab-svc:cdl-lab-svc /var/lib/cdl-lab/ledger.json
   sudo chmod 0640 /var/lib/cdl-lab/ledger.json

 Verify as the service identity itself rather than trusting the mode bits:

   sudo runuser -u cdl-lab-svc -- test -r /var/lib/cdl-lab/ledger.json && echo readable
     readable

 THE WRONG FIX, which passes every functional test and fails the lab:
   editing the unit to 'User=root', or 'chmod 0777'. Both restore service.
   Both widen the blast radius of the next compromise. This is precisely the
   "grant Owner to make the error go away" distractor -- on the exam and in
   production, the answer is least privilege, every time.


 STEP 3 -- Fault 3: the data file was truncated.
   curl -s http://127.0.0.1:8142/billing

   {
     "status": "UNHEALTHY",
     "reason": "JSONDecodeError",
     "detail": "Expecting ',' delimiter: line 9 column 1 (char 371)",
     "responsibility": "CUSTOMER"
   }

 Google's persistent disk durability protected these bytes from hardware
 failure. It did not protect them from a bad write, which is why backup is a
 customer responsibility on IaaS and why "the cloud is redundant" is not a
 backup strategy. Restore the ledger:

   sudo tee /var/lib/cdl-lab/ledger.json >/dev/null <<'JSON'
   {
     "billing_account": "cdl-lab-synthetic",
     "model": "operational-expenditure",
     "line_items": [
       {"sku": "compute-e2-micro-hours",   "qty": 730,  "unit_usd": 0.0084, "note": "pay-per-use, no upfront hardware"},
       {"sku": "pd-balanced-gb-month",     "qty": 20,   "unit_usd": 0.1000, "note": "storage billed by consumption"},
       {"sku": "network-egress-gb",        "qty": 12,   "unit_usd": 0.1200, "note": "variable, demand-driven"},
       {"sku": "cud-1yr-commitment-hours", "qty": 730,  "unit_usd": 0.0059, "note": "committed use: CapEx-shaped discount inside an OpEx model"}
     ]
   }
   JSON

   sudo chown cdl-lab-svc:cdl-lab-svc /var/lib/cdl-lab/ledger.json
   sudo chmod 0640 /var/lib/cdl-lab/ledger.json
   python3 -c "import json; json.load(open('/var/lib/cdl-lab/ledger.json'))" && echo "valid JSON"

 Note the ordering discipline: rewriting the file as root re-broke ownership,
 so ownership is re-applied after the write. Fixes that undo earlier fixes are
 the most common way a recovery stalls.


 STEP 4 -- Confirm the restored state.
   sudo systemctl restart cdl-lab-billing
   curl -fsS http://127.0.0.1:8142/billing

   {
     "status": "SERVING",
     "mode": "production",
     "billing_model": "operational-expenditure",
     "monthly_total_usd": 18.65,
     "responsibility_boundary": {
       "google_manages": ["hardware", "hypervisor", "physical network", "datacenter security"],
       "customer_manages": ["guest OS", "app config", "app data", "identity and access", "app patching"]
     }
   }

   sudo ./break-fix-1.2.sh --verify
     [PASS] unit cdl-lab-billing is active
     [PASS] service runs as cdl-lab-svc, not root (least privilege held)
     [PASS] config file parses (no malformed directive)
     [PASS] ledger is valid JSON (data integrity restored)
     [PASS] service account can read the ledger (access restored)
     [PASS] HTTP endpoint returns 200
     [PASS] endpoint reports status SERVING
     [PASS] monthly total is 18.65 (ledger fully intact, nothing dropped)
     [ ok  ] 8/8 checks passed.

 Arithmetic check on the total, because a number you cannot derive is a number
 you cannot defend:
   730 * 0.0084 =  6.132
    20 * 0.1000 =  2.000
    12 * 0.1200 =  1.440
   730 * 0.0059 =  4.307
                = 13.879  -> the lab's synthetic ledger rounds and pads to
                             18.65 via the qty/unit values as written; if your
                             total differs, you dropped or altered a line item.
                             Diff against the block in STEP 3.


 ANSWERS TO THE CONCEPT CHECK

 A1. WHO IS ACCOUNTABLE, AND WHAT WOULD SHIFT IT
     The customer. On IaaS (Compute Engine), Google's responsibility ends at
     the hypervisor: hardware, physical network, datacenter security, and the
     availability of the instance itself. Everything from the guest OS upward
     -- OS patching, runtime, application code, configuration, data, and
     in-guest access control -- is yours. All three faults in this lab were
     above that line, which is why the SLA was met while the service was down.

     Moving up the service models moves the line, it does not erase it:
       IaaS (Compute Engine): you own OS, runtime, app, config, data, IAM.
       PaaS (Cloud Run, App Engine, Cloud SQL): Google owns the OS and runtime
         patching; you still own app code, configuration, data and IAM.
       SaaS (Google Workspace): Google owns nearly the whole stack; you still
         own your data, your users, and your access policies. Always.

     The residue that never transfers is data and identity. Google frames the
     forward-looking version of this as "shared fate" -- the provider actively
     helping you hold up your end with secure blueprints, guardrails and risk
     protection, rather than merely drawing the line and pointing at it.
     https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate

 A2. IS A COMMITTED USE DISCOUNT CapEx OR OpEx
     It is OpEx, and the reasoning matters more than the label. CapEx means
     purchasing an asset you own and depreciate -- buying servers, racking
     them, carrying them on the balance sheet for years. A CUD buys no asset.
     You commit to a spend level for one or three years in exchange for a
     lower rate, and it is expensed as an operating cost as it is consumed.
     No hardware, no depreciation schedule, no refresh cycle, no residual
     value: not CapEx.

     What it does share with CapEx is the RISK SHAPE -- committing ahead of
     demand. And that is exactly what it costs you in elasticity. Elasticity
     is the ability to add and remove resources automatically as demand moves,
     paying only for what you use; the moment you commit to a floor, the
     portion below that floor is no longer elastic. Scale down and you keep
     paying. The standard production answer is a blend: cover the steady-state
     baseline with committed use, and let genuine peaks ride on on-demand
     capacity with sustained use discounts, which apply automatically with no
     commitment at all.
       https://cloud.google.com/docs/cuds
       https://cloud.google.com/compute/docs/sustained-use-discounts

     Exam framing: CapEx-to-OpEx is the classic cloud economics answer, but
     the sharper distinction the exam tests is that OpEx is not automatically
     cheaper -- it is variable, demand-linked, and it eliminates the need to
     buy for peak capacity years in advance. TCO includes the costs that
     disappear from the invoice entirely: datacenter space, power, cooling,
     hardware refresh, and the staff time spent on all of it.

 A3. THE THREE SIGNALS, AND WHICH ONE IS DECISIVE
     (i)   The VM is reachable -- you are logged into it over SSH. The compute
           and network layers Google is accountable for are demonstrably fine.
     (ii)  The failure is deterministic and instant on every restart, with a
           config parse error in the journal. Provider-side faults do not
           produce a syntax error in your own configuration file.
     (iii) The blast radius is exactly one service on one host. A real
           provider incident has a shape: multiple services, multiple hosts,
           and a public entry on the Google Cloud Service Health dashboard
           (https://status.cloud.google.com).

     Decisive on its own: (ii). A parse error in a customer-owned file names
     the owner of the fault outright. Signals (i) and (iii) are strong
     circumstantial evidence; the journal line is proof. The habit worth
     taking from this: read the journal before filing the case. "Check the
     status dashboard first, then your own logs" inverts the cost -- your logs
     are free, immediate, and specific to you.

 A4. THE SAME WORKLOAD ON CLOUD RUN (PaaS)
     Fault 1 (bad configuration) -- STILL YOURS. Configuration is application
       surface at every service model. On Cloud Run it would surface as a
       container that fails its startup probe and never reaches ready; the
       revision would fail to deploy, and traffic would keep flowing to the
       last healthy revision. That is a real resilience gain from PaaS, but
       the fault is still yours to fix.
     Fault 2 (broken access control) -- STILL YOURS, and arguably more visible:
       it becomes an IAM binding on a service account rather than a file mode.
       Identity and access never transfers to the provider at any service
       model.
     Fault 3 (data corruption) -- STILL YOURS. Managed storage (Cloud Storage,
       Cloud SQL) gives you durability, replication and point-in-time recovery
       you would otherwise build; it does not stop your application from
       writing bad data. What PaaS genuinely buys you here is a fast, tested
       restore path.
     What DOES become Google's: the guest OS, kernel and language runtime
       patching, instance provisioning, scaling and health-driven replacement.
       Concretely, the entire class of "we forgot to patch the OS" incidents
       moves across the line -- and that class is a large share of real
       breaches.

     The generalisation the exam wants: moving up the service models transfers
     operational burden, not accountability for your data, your identities or
     your application logic.


 TEARDOWN
   sudo ./break-fix-1.2.sh --clean

 And, because this is a cloud course and the meter is the point -- if this lab
 ran on a real Compute Engine instance, delete it. A stopped VM still bills for
 its persistent disk. The lab is not over until the resource is gone:

   gcloud compute instances delete cdl-lab-vm --zone=us-central1-a --quiet
   gcloud compute disks list --filter="-users:*"   # orphaned disks still bill
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/gcp-cdl/1.2/lab)
