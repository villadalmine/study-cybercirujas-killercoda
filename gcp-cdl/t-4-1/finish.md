## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
  Errno -2 is EAI_NONAME from getaddrinfo(3): name resolution failed. Not a
  firewall, not a refused connection, not a timeout. Distinguishing these
  three is the single highest-value triage skill in a migration cutover:
    * "Name or service not known"  -> DNS / resolver / hosts file
    * "Connection refused"         -> resolved fine, nothing listening
    * "Connection timed out"       -> resolved fine, packets dropped (firewall,
                                      VPC route, missing Cloud Interconnect /
                                      Cloud VPN back to the peer network)

STEP 2 -- Find the name and who supplied it.
  $ cat /opt/cdl-lab41/app/config.env
  INVENTORY_UPSTREAM=http://inventory-db.corp.internal:9141
  INVENTORY_TIMEOUT_SECONDS=3

  $ getent hosts inventory-db.corp.internal
  (no output, exit status 2)

  $ journalctl -u cdl41-catalog.service -n 30 --no-pager
  ... catalog "GET /catalog HTTP/1.1" 502 -

  The .corp.internal suffix is the tell: that is a private, on-premises zone.
  A workload in Google Cloud resolving a .corp.internal name is, by
  definition, still reaching back into the old environment -- over Cloud VPN,
  Cloud Interconnect, or a Cloud DNS forwarding zone. That is a legitimate
  architecture *during* a migration, and a defect *after* it.

STEP 3 -- Write the artifact whose absence caused the outage.
  Do this BEFORE fixing anything. Under incident pressure the documentation
  never gets written afterwards, which is how the same gap survives into the
  next wave.

  $ sudo tee /opt/cdl-lab41/dependency-map.md > /dev/null <<'MD'
  # Dependency map -- Northwind catalog service

  Produced during incident response 2026-09-08. This should have been an
  output of the ASSESS phase, before wave 1 cutover.

  | Dependent | Depends on | Protocol / port | Direction | Migration wave |
  |---|---|---|---|---|
  | catalog service (migrated, wave 1) | inventory-db.corp.internal | HTTP/TCP 9141 | egress, synchronous, per-request | should have been wave 1, was scheduled wave 3 |

  Details
  - Discovered at runtime, not at assessment time. Failure surfaced as
    EAI_NONAME once the on-prem resolver was withdrawn.
  - Coupling: synchronous and on the read path. Every /catalog request
    blocks on it, so there is no degraded mode -- the tier is hard-required.
  - Blast radius: 100% of catalog reads; customer-visible as an empty store.
  - Detection gap: the availability dashboard polled /healthz (liveness),
    which never exercises the dependency. Repoint it at /readyz.
  - Remediation: replacement inventory endpoint provided inside Google Cloud;
    consumer repointed via configuration.
  - Target end state: managed data tier (Cloud SQL / AlloyDB / Spanner) so
    there is no self-operated host left to decommission. Private Service
    Connect or a private IP on the VPC; no .corp.internal names in config.

  Rule adopted: no environment is decommissioned until every workload that
  named it has been re-pointed and observed green on a readiness probe for
  one full business cycle.
  MD

STEP 4 -- Provide the capability in the cloud environment.
  The datacenter is gone; you replace the tier, you do not revive it. In
  production this is a managed service -- Cloud SQL, AlloyDB or Spanner --
  chosen precisely because Google operates the substrate and there is no
  rack to power down. Here, a local stand-in that honours the same contract:

  $ sudo install -d -m 0755 /opt/cdl-lab41/replacement
  $ sudo tee /opt/cdl-lab41/replacement/inventory_api.py > /dev/null <<'PY'
  #!/usr/bin/env python3
  """Replacement inventory tier, running inside the cloud environment.

  Stands in for a managed data service. Serves the identical contract the
  catalog service already speaks, so the consumer needs no code change.
  """
  import json
  from http.server import BaseHTTPRequestHandler, HTTPServer

  ROWS = [
      {"sku": "SKU-1001", "name": "Cold brew concentrate", "on_hand": 412},
      {"sku": "SKU-1002", "name": "Ceramic pour-over cone", "on_hand": 87},
      {"sku": "SKU-1003", "name": "Burr grinder, manual", "on_hand": 5},
  ]


  class Handler(BaseHTTPRequestHandler):
      def do_GET(self):
          if self.path != "/inventory":
              self.send_error(404)
              return
          body = json.dumps({"source": "google-cloud", "rows": ROWS}).encode()
          self.send_response(200)
          self.send_header("Content-Type", "application/json")
          self.send_header("Content-Length", str(len(body)))
          self.end_headers()
          self.wfile.write(body)

      def log_message(self, *_a):
          return


  if __name__ == "__main__":
      HTTPServer(("127.0.0.1", 9142), Handler).serve_forever()
  PY

  Make it survive a reboot -- a stand-in that dies with your SSH session has
  reproduced the original defect in a new place:

  $ sudo tee /etc/systemd/system/cdl41-inventory.service > /dev/null <<'UNIT'
  [Unit]
  Description=cdl-4.1 replacement inventory tier
  After=network.target

  [Service]
  Type=simple
  ExecStart=/usr/bin/python3 /opt/cdl-lab41/replacement/inventory_api.py
  Restart=always
  RestartSec=2
  NoNewPrivileges=true

  [Install]
  WantedBy=multi-user.target
  UNIT

  $ sudo systemctl daemon-reload
  $ sudo systemctl enable --now cdl41-inventory.service
  $ curl -s http://127.0.0.1:9142/inventory
  {"source": "google-cloud", "rows": [{"sku": "SKU-1001", ...}]}

STEP 5 -- Repoint the consumer. Configuration only.
  $ sudo sed -i \
      's|^INVENTORY_UPSTREAM=.*|INVENTORY_UPSTREAM=http://127.0.0.1:9142|' \
      /opt/cdl-lab41/app/config.env
  $ sudo systemctl restart cdl41-catalog.service

  The application binary is untouched. That is the point: in a real
  lift-and-shift you frequently cannot rebuild the artifact -- the toolchain
  is gone, the vendor is gone, the source is a tarball on a share that was in
  the same rack. Everything that might need to change after a cutover should
  be data the process reads, not a constant it was compiled with.

STEP 6 -- Verify, and verify the *right* signal.
  $ curl -s http://127.0.0.1:8141/catalog | python3 -m json.tool
  {
      "source": "google-cloud",
      "rows": [
          {"sku": "SKU-1001", "name": "Cold brew concentrate", "on_hand": 412},
          {"sku": "SKU-1002", "name": "Ceramic pour-over cone", "on_hand": 87},
          {"sku": "SKU-1003", "name": "Burr grinder, manual", "on_hand": 5}
      ],
      "served_by": "migrated-catalog-service",
      "upstream": "http://127.0.0.1:9142/inventory"
  }

  $ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8141/readyz
  200

  $ sudo ./cdl-4.1-break-and-fix.sh --verify
  [cdl-4.1] PASS  /catalog returns 200
  [cdl-4.1] PASS  payload contains well-formed inventory rows
  [cdl-4.1] PASS  /readyz returns 200
  [cdl-4.1] PASS  config.env repointed away from the decommissioned host
  [cdl-4.1] PASS  catalog_service.py left intact
  [cdl-4.1] PASS  dependency-map.md exists and documents the dependency
  [cdl-4.1] SCORE 6/6 -- lab complete.

  Note the "source" field flipped from "on-prem" to "google-cloud". In a real
  migration that flag is worth having: a field in the response, a label on
  the resource, a tag in Cloud Monitoring, that tells you unambiguously which
  side of the cutover served a given request.

WHY THIS IS THE 4.1 MATERIAL, NOT JUST A SHELL EXERCISE

1. ASSESS is not paperwork. Google's migration path is Assess -> Plan ->
   Deploy -> Optimize
   (https://cloud.google.com/architecture/migration-to-gcp-getting-started),
   and the ASSESS deliverable is a workload inventory *with dependencies*
   (https://cloud.google.com/architecture/migration-to-gcp-assessing-and-discovering-your-workloads).
   Migration Center exists to produce that automatically -- discovery of
   running workloads, dependency mapping, and TCO
   (https://cloud.google.com/migration-center/docs/migration-center-overview).
   The outage in this lab is what a missing row in that inventory costs.

2. The three migration types, and which one this was.
   * Lift and shift -- move as-is. Fastest, cheapest to execute, inherits
     every operational burden you had. That is what wave 1 did.
   * Improve and move -- modernise while migrating; e.g. the data tier lands
     on Cloud SQL instead of a self-managed VM.
   * Rip and replace -- decommission and rebuild, typically toward managed
     or serverless services.
   A two-tier application split across waves is temporarily the worst of all
   three: it carries lift-and-shift's operational debt AND a cross-environment
   network dependency on the critical path. That state is acceptable only
   while it is explicitly tracked with an end date.

3. Decommissioning is a phase, not an afterthought. The correct gate is
   evidence -- every workload re-pointed, every readiness probe green through
   a full business cycle -- not a contract expiry. "The rack was powered down
   on schedule" is the root cause sentence in this postmortem.

4. Managed services shrink the surface that can be decommissioned out from
   under you. Had the data tier landed on Cloud SQL, AlloyDB or Spanner in
   wave 1, there would have been no host to switch off; Google operates the
   substrate, and the migration would have ended at the point the CDL exam
   guide calls the transition to cloud operations. This is the concrete
   meaning of "how Google Cloud helps organizations transition": not that the
   VMs move, but that the number of things you must personally keep alive
   goes down.

5. Observability must test the dependency chain. /healthz proved a process
   existed. /readyz proved the system could do its job. Wire alerting to the
   second one. In GKE that is readinessProbe versus livenessProbe; in
   Cloud Run it is the startup and liveness probe configuration; in Compute
   Engine it is the health check attached to the backend service, which
   should hit a path that exercises the dependency, not a static 200.

6. The organizational half. The Google Cloud Adoption Framework
   (https://cloud.google.com/adoption-framework) scores readiness on Learn,
   Lead, Scale and Secure. This incident is a Lead failure before it is a
   technical one: the team that owned the app and the team that owned the
   datacenter contract never reconciled their views of "migrated". No amount
   of tooling fixes that; a single shared dependency map does.

CLEANUP
  $ sudo systemctl disable --now cdl41-inventory.service
  $ sudo rm -f /etc/systemd/system/cdl41-inventory.service
  $ sudo systemctl daemon-reload
  $ sudo ./cdl-4.1-break-and-fix.sh --restore
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/gcp-cdl/4.1/lab)
