## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION - step by step. Stop here unless you have already tried.

TIER 1 - IaaS: the guest OS is yours, both faults live inside it

Step 1.1 - Read the failure before touching anything.

  $ systemctl status az900-iaas.service --no-pager -l
  × az900-iaas.service - AZ-900 1.3 lab - IaaS tier (you manage OS, runtime and app)
       Loaded: loaded (/etc/systemd/system/az900-iaas.service; enabled; preset: disabled)
       Active: failed (Result: exit-code) since Fri 2026-09-04 10:12:03 UTC; 8s ago
      Process: 4711 ExecStart=/usr/local/bin/az900-python3 /opt/az900-lab/iaas/app/serve.py \
               (code=exited, status=203/EXEC)

  status=203/EXEC is decisive: systemd could not EXECUTE the binary at all.
  The application never started, so no application log exists. The fault is
  below your code, in the runtime layer - which in IaaS is still yours.

  $ ls -l /usr/local/bin/az900-python3
  ls: cannot access '/usr/local/bin/az900-python3': No such file or directory

Step 1.2 - Provide the missing runtime (the customer owns the runtime in IaaS).

  $ sudo ln -sfn "$(command -v python3)" /usr/local/bin/az900-python3
  $ sudo systemctl restart az900-iaas.service
  $ systemctl is-active az900-iaas.service
  active

  Equally valid: edit ExecStart to /usr/bin/python3 and run
  `sudo systemctl daemon-reload && sudo systemctl restart az900-iaas.service`.
  Both are legitimate here precisely because the VM's OS configuration is
  customer territory. Neither would be possible on PaaS or SaaS.

Step 1.3 - Now the second, deeper fault surfaces.

  $ curl -i http://127.0.0.1:8081/
  HTTP/1.0 403 Forbidden
  Server: az900-iaas/1.0
  403 Forbidden: the web service account cannot read the site content

  $ journalctl -u az900-iaas.service -n 3 --no-pager
  iaas: cannot read site content: [Errno 13] Permission denied: '/opt/az900-lab/iaas/wwwroot/index.html'

  $ ls -l /opt/az900-lab/iaas/wwwroot/index.html
  -rw------- 1 root root 331 Sep  4 10:11 /opt/az900-lab/iaas/wwwroot/index.html

  The unit runs as az900lab (User= in the unit). Mode 0600 root:root means the
  service account has no read bit. Confirm the diagnosis as the service user
  instead of guessing - root would read it fine and mislead you:

  $ sudo -u az900lab cat /opt/az900-lab/iaas/wwwroot/index.html
  cat: /opt/az900-lab/iaas/wwwroot/index.html: Permission denied

Step 1.4 - Repair ownership, keeping least privilege (do NOT run the service
           as root - that "fixes" the symptom and creates a real finding).

  $ sudo chown az900lab:az900lab /opt/az900-lab/iaas/wwwroot/index.html
  $ sudo chmod 0644 /opt/az900-lab/iaas/wwwroot/index.html
  $ curl -s http://127.0.0.1:8081/ | grep -o 'IaaS tier healthy'
  IaaS tier healthy

  If 203/EXEC persists after the symlink exists, suspect the mandatory access
  control layer, not DAC:  sudo ausearch -m avc -ts recent   (SELinux) or
  sudo journalctl -k | grep -i apparmor. Still an IaaS-layer, customer-owned
  problem - which is the whole point of the tier.

TIER 2 - PaaS: the platform is healthy, your configuration is not

Step 2.1 - Separate platform health from application health.

  $ systemctl is-active az900-paas.service az900-db.service
  active
  active

  Both provider components are up. So the 503 is not an outage - it is your
  deployment. This is the reflex AZ-900 wants: in PaaS you do not troubleshoot
  the worker, the OS or the runtime; you troubleshoot code and configuration.

Step 2.2 - Read the platform's diagnostic output (App Service Log stream is
           the real-world equivalent).

  $ journalctl -u az900-paas.service -n 10 --no-pager
  paas-host: platform host starting on 127.0.0.1:8082
  paas-host: dependency probe failed: DB_ENDPOINT='127.0.0.1:9999' [Errno 111] Connection refused

Step 2.3 - Find where the managed backing service actually listens.

  $ ss -lntp | grep -E '808[123]'
  LISTEN 0 5 127.0.0.1:8081 0.0.0.0:* users:(("python3",pid=4802,fd=3))
  LISTEN 0 5 127.0.0.1:8082 0.0.0.0:* users:(("python3",pid=4780,fd=3))
  LISTEN 0 5 127.0.0.1:8083 0.0.0.0:* users:(("python3",pid=4769,fd=3))

  Nothing on 9999; the backing service is on 8083 (also stated by
  `systemctl cat az900-db.service`). The connection string is simply wrong -
  a customer-owned setting, exactly like an App Service connection string.

Step 2.4 - Correct the application setting and restart the app.

  $ sudo sed -i 's|^DB_ENDPOINT=.*|DB_ENDPOINT=127.0.0.1:8083|' \
      /opt/az900-lab/paas/app/appsettings.env
  $ sudo systemctl restart az900-paas.service
  $ curl -s http://127.0.0.1:8082/
  PaaS tier healthy
  application : Contoso Order API
  backend     : 127.0.0.1:8083
  backend says: AZ900-DB OK

  In Azure the same change is: App Service -> Settings -> Environment
  variables -> edit the connection string -> Apply. The platform restarts the
  worker for you; you never touch a host.

  WRONG FIX, and the grader catches it: editing
  /opt/az900-lab/paas/platform/host.py to hard-code port 8083. That file is
  the provider's runtime. `verify` compares it against .provider.sha256 and
  fails the SCOPE check, because in real PaaS you have no such access.

TIER 3 - SaaS: identity and access are the only levers you have

Step 3.1 - Reproduce and read the error code.

  $ /opt/az900-lab/saas/service/saas-portal signin student@contoso.example
  AADSTS50057: The user account student@contoso.example is disabled.

  AADSTS50057 = disabled account. Account state is a tenant object, so this is
  customer work, not a vendor incident.
  https://learn.microsoft.com/en-us/entra/identity-platform/reference-error-codes

Step 3.2 - Enable the account in the tenant configuration.

  $ sudo python3 - <<'PY'
  import json, pathlib
  p = pathlib.Path("/opt/az900-lab/saas/tenant/tenant.json")
  t = json.loads(p.read_text())
  for u in t["users"]:
      if u["userPrincipalName"] == "student@contoso.example":
          u["accountEnabled"] = True
  p.write_text(json.dumps(t, indent=2) + "\n")
  PY

  (Editor or jq are equally fine:
   sudo jq '(.users[] | select(.userPrincipalName=="student@contoso.example")
             | .accountEnabled) = true' ... )

Step 3.3 - The next error is a different object entirely.

  $ /opt/az900-lab/saas/service/saas-portal signin student@contoso.example
  AADSTS50105: The signed in user student@contoso.example is not assigned to a
  role for the application 'Contoso Learning Portal'.

  Authentication now succeeds; authorization does not. The user exists and can
  prove who they are, but has no app role assignment. Distinguishing 50057
  (authentication / account state) from 50105 (authorization / assignment) is
  the exact distinction AZ-900 tests when it asks what a SaaS tenant controls.

Step 3.4 - Assign the application role, then confirm.

  $ sudo python3 - <<'PY'
  import json, pathlib
  p = pathlib.Path("/opt/az900-lab/saas/tenant/tenant.json")
  t = json.loads(p.read_text())
  for u in t["users"]:
      if u["userPrincipalName"] == "student@contoso.example":
          roles = set(u.get("appRoleAssignments", [])) | {"Learner"}
          u["appRoleAssignments"] = sorted(roles)
  p.write_text(json.dumps(t, indent=2) + "\n")
  PY

  $ /opt/az900-lab/saas/service/saas-portal signin student@contoso.example
  Access granted: student@contoso.example -> Contoso Learning Portal (role: Learner)
  SaaS tier healthy
  $ echo $?
  0

  Note what you never did: patch the portal, restart it, resize it, or read
  its logs. In SaaS the vendor owns the application, the runtime, the OS and
  the network. Your entire remediation surface was accounts, identities,
  access and data.

FINAL GRADE

  $ ./break-fix-az900-1.3.sh verify
  [ok]   IaaS  - HTTP 200 from 127.0.0.1:8081 (unit: active)
  [ok]   PaaS  - HTTP 200 from 127.0.0.1:8082 (backing service: active)
  [ok]   SaaS  - sign-in succeeds for student@contoso.example
  [ok]   SCOPE - provider-managed files are untouched
  RESULT: PASS - all three service types restored from the customer side only.

  $ sudo ./break-fix-az900-1.3.sh reset
  [ok]   lab removed: units, /opt/az900-lab, /usr/local/bin/az900-python3, user az900lab

EXAM TAKEAWAY (topic 1.3, 9.4 % of the exam)
  Three faults, three different owners, one rule. The number of layers you are
  allowed to fix is the definition of the service type:

    IaaS  - you fixed the runtime AND the file permissions. Maximum control,
            maximum operational burden. Use it for lift-and-shift, legacy or
            OS-level requirements. https://learn.microsoft.com/en-us/azure/virtual-machines/overview
    PaaS  - you fixed one setting; patching, scaling and the OS were not your
            problem and not your permission. Use it to ship applications
            without owning infrastructure. https://learn.microsoft.com/en-us/azure/app-service/overview
    SaaS  - you fixed an identity and a role assignment; there was nothing
            else to fix. Use it to consume a finished product.

  Constant across all three: data, devices, accounts and identities are ALWAYS
  yours. That is why the SaaS tier still broke - and why "the vendor handles
  security" is the single most reliably wrong answer on this exam.
  https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/az-900/1.3/lab)
