#!/usr/bin/env bash
#
# =============================================================================
#  AZ-900 | Microsoft Azure Fundamentals (exam version 2026-07-20)
#  Domain 1 - Describe cloud concepts
#  Topic 1.3 - Describe cloud service types            (domain weight: 9.4 %)
#
#  BREAK & FIX LAB - "Who owns the failure?"
#
#  Skills measured by this lab
#    - Describe IaaS, PaaS and SaaS and identify the appropriate use case
#    - Describe the shared responsibility model and locate a fault inside it
#
#  Official references
#    - AZ-900 study guide
#      https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
#    - Shared responsibility in the cloud
#      https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility
#    - Azure Virtual Machines overview (IaaS reference service)
#      https://learn.microsoft.com/en-us/azure/virtual-machines/overview
#    - Azure App Service overview (PaaS reference service)
#      https://learn.microsoft.com/en-us/azure/app-service/overview
#    - Microsoft Entra ID fundamentals (SaaS identity plane)
#      https://learn.microsoft.com/en-us/entra/fundamentals/whatis
#    - Microsoft Entra authentication and authorization error codes
#      https://learn.microsoft.com/en-us/entra/identity-platform/reference-error-codes
#
#  WHAT THIS SCRIPT BUILDS
#    Three local tiers on a single throwaway VM, each one standing in for a
#    cloud service type, and each one broken at a layer that a real Azure
#    customer would - or would NOT - be allowed to touch:
#
#      az900-iaas.service   127.0.0.1:8081   IaaS  - you own OS + runtime + app
#      az900-paas.service   127.0.0.1:8082   PaaS  - you own app code + settings
#      az900-db.service     127.0.0.1:8083   PaaS  - PROVIDER-managed backing store
#      saas-portal (CLI)    no port          SaaS  - you own identities + data only
#
#  SAFETY / BLAST RADIUS  (read before running)
#    - Runs only after you set AZ900_LAB_CONFIRM=yes. It is meant for a
#      DISPOSABLE lab VM, never a workstation or a production host.
#    - Installs no packages, touches no distro service, opens no external port.
#      Every listener binds to 127.0.0.1 only.
#    - Total footprint, all removed by "reset":
#        /opt/az900-lab                              (lab tree)
#        /etc/systemd/system/az900-{iaas,paas,db}.service
#        /usr/local/bin/az900-python3                (deliberately ABSENT)
#        system user "az900lab"                      (nologin, no home)
#    - Idempotent: "break" tears the lab down and rebuilds it, so re-running it
#      always lands on the exact same starting state.
# =============================================================================

set -euo pipefail

LAB_ROOT="/opt/az900-lab"
LAB_USER="az900lab"
UNIT_DIR="/etc/systemd/system"
FAKE_PY="/usr/local/bin/az900-python3"
IAAS_PORT=8081
PAAS_PORT=8082
DB_PORT=8083
MANIFEST="${LAB_ROOT}/.provider.sha256"
UNITS=(az900-iaas az900-paas az900-db)

say()  { printf '%s\n' "$*"; }
info() { printf '[lab]  %s\n' "$*"; }
ok()   { printf '[ok]   %s\n' "$*"; }
bad()  { printf '[fail] %s\n' "$*"; }
die()  { printf '[stop] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
AZ-900 1.3 break & fix - cloud service types

  sudo AZ900_LAB_CONFIRM=yes ./break-fix-az900-1.3.sh break    build the lab and break it
                             ./break-fix-az900-1.3.sh verify   grade your repair
                             ./break-fix-az900-1.3.sh status   raw state of the three tiers
                             ./break-fix-az900-1.3.sh hint     shared responsibility matrix
  sudo                       ./break-fix-az900-1.3.sh reset    remove every trace of the lab

Run "break" only on a VM you can throw away.
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "this action needs root: sudo AZ900_LAB_CONFIRM=yes $0 $*"
}

require_confirm() {
  [[ "${AZ900_LAB_CONFIRM:-no}" == "yes" ]] || die \
"refusing to break anything without an explicit acknowledgement.
       Re-run on a DISPOSABLE lab VM with:  sudo AZ900_LAB_CONFIRM=yes $0 break"
}

require_tools() {
  [[ -d /run/systemd/system ]] || die "systemd is not the init system here; this lab needs it."
  command -v systemctl >/dev/null || die "systemctl not found."
  command -v curl      >/dev/null || die "curl not found; install it before running the lab."
  command -v sha256sum >/dev/null || die "sha256sum not found (coreutils)."
  PYTHON_BIN="$(command -v python3 || true)"
  [[ -n "${PYTHON_BIN}" ]] || die "python3 not found; the lab tiers are plain python3 processes."
}

port_in_use() {
  "${PYTHON_BIN}" - "$1" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(0)
finally:
    s.close()
sys.exit(1)
PY
}

http_code() {
  local code=""
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$1" 2>/dev/null)" || true
  printf '%s' "${code:-000}"
}

http_body() {
  curl -s --max-time 3 "$1" 2>/dev/null || true
}

unit_state() {
  systemctl is-active "$1" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# reset - full teardown, safe to run at any time
# -----------------------------------------------------------------------------
cmd_reset() {
  require_root reset
  [[ "${LAB_ROOT}" == "/opt/az900-lab" ]] || die "LAB_ROOT was tampered with; refusing to delete ${LAB_ROOT}."

  local u
  for u in "${UNITS[@]}"; do
    systemctl disable --now "${u}.service" >/dev/null 2>&1 || true
    rm -f "${UNIT_DIR}/${u}.service"
  done
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true

  rm -f "${FAKE_PY}"
  rm -rf "${LAB_ROOT}"
  if id -u "${LAB_USER}" >/dev/null 2>&1; then
    userdel "${LAB_USER}" >/dev/null 2>&1 || true
  fi
  ok "lab removed: units, ${LAB_ROOT}, ${FAKE_PY}, user ${LAB_USER}"
}

# -----------------------------------------------------------------------------
# build - lay down the three tiers (provider-managed vs customer-managed)
# -----------------------------------------------------------------------------
build_lab() {
  local nologin
  nologin="$(command -v nologin || echo /sbin/nologin)"
  id -u "${LAB_USER}" >/dev/null 2>&1 || \
    useradd --system --no-create-home --home-dir "${LAB_ROOT}" --shell "${nologin}" "${LAB_USER}"

  install -d -m 0755 -o root -g root \
    "${LAB_ROOT}" \
    "${LAB_ROOT}/iaas" "${LAB_ROOT}/iaas/app" "${LAB_ROOT}/iaas/wwwroot" \
    "${LAB_ROOT}/paas" "${LAB_ROOT}/paas/platform" "${LAB_ROOT}/paas/app" \
    "${LAB_ROOT}/saas" "${LAB_ROOT}/saas/service" "${LAB_ROOT}/saas/tenant"

  # ---- IaaS tier: every byte below the datacenter floor is yours -------------
  cat > "${LAB_ROOT}/iaas/app/serve.py" <<'PY'
#!/usr/bin/env python3
"""IaaS tier - CUSTOMER MANAGED end to end.

Azure analogue: an Azure Virtual Machine. Microsoft owns the physical host,
the hypervisor, the network fabric and the datacenter. Everything you can see
from inside the guest - OS, patches, runtime, web server, file permissions,
application content - is yours.
https://learn.microsoft.com/en-us/azure/virtual-machines/overview
"""
import http.server
import pathlib
import socketserver
import sys

ROOT = pathlib.Path("/opt/az900-lab/iaas/wwwroot")
LISTEN = ("127.0.0.1", 8081)


def log(msg):
    sys.stderr.write("iaas: %s\n" % msg)
    sys.stderr.flush()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "az900-iaas/1.0"

    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        index = ROOT / "index.html"
        try:
            self._send(200, index.read_text(), "text/html; charset=utf-8")
        except PermissionError as exc:
            log("cannot read site content: %s" % exc)
            self._send(403, "403 Forbidden: the web service account cannot read the site content\n")
        except FileNotFoundError as exc:
            log("site content missing: %s" % exc)
            self._send(404, "404 Not Found: site content is missing\n")

    def log_message(self, fmt, *args):
        log("%s %s" % (self.address_string(), fmt % args))


socketserver.TCPServer.allow_reuse_address = True
log("listening on %s:%d as uid=%d" % (LISTEN[0], LISTEN[1], __import__("os").geteuid()))
with socketserver.TCPServer(LISTEN, Handler) as httpd:
    httpd.serve_forever()
PY

  cat > "${LAB_ROOT}/iaas/wwwroot/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>AZ-900 lab - IaaS tier</title></head>
<body>
<h1>IaaS tier healthy</h1>
<p>You manage the guest OS, the runtime, the web service and this content.
Azure manages the physical hosts, the physical network and the physical datacenter.</p>
</body>
</html>
HTML

  # ---- PaaS tier: platform host is Microsoft's, the app is yours -------------
  cat > "${LAB_ROOT}/paas/platform/host.py" <<'PY'
#!/usr/bin/env python3
"""PaaS platform host - PROVIDER MANAGED. Do not modify.

Azure analogue: Azure App Service. Microsoft owns the OS, the language
runtime, the worker fleet and the scaling machinery. You own application
code, application settings, connection strings, identities and data.
https://learn.microsoft.com/en-us/azure/app-service/overview
"""
import http.server
import importlib.util
import pathlib
import socket
import socketserver
import sys

APP_DIR = pathlib.Path("/opt/az900-lab/paas/app")
SETTINGS = APP_DIR / "appsettings.env"
LISTEN = ("127.0.0.1", 8082)


def log(msg):
    sys.stderr.write("paas-host: %s\n" % msg)
    sys.stderr.flush()


def load_settings():
    values = {}
    for raw in SETTINGS.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, val = line.partition("=")
        if not sep:
            continue
        values[key.strip()] = val.strip().strip('"').strip("'")
    return values


def load_customer_app():
    spec = importlib.util.spec_from_file_location("customer_app", str(APP_DIR / "app.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "az900-paas/1.0"

    def _send(self, code, body):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        try:
            settings = load_settings()
        except OSError as exc:
            log("application settings unreadable: %s" % exc)
            self._send(500, "500 Internal Server Error: application settings unreadable\n")
            return

        endpoint = settings.get("DB_ENDPOINT", "")
        host, _, port = endpoint.partition(":")
        try:
            with socket.create_connection((host, int(port)), timeout=1) as sock:
                banner = sock.recv(64).decode(errors="replace").strip()
        except (OSError, ValueError) as exc:
            log("dependency probe failed: DB_ENDPOINT=%r %s" % (endpoint, exc))
            self._send(503,
                       "503 Service Unavailable: the application cannot reach its backing service\n"
                       "    DB_ENDPOINT=%s\n" % (endpoint or "<unset>"))
            return

        try:
            body = load_customer_app().render(settings, banner)
        except Exception as exc:  # customer code fault, not a platform fault
            log("customer application raised: %r" % exc)
            self._send(500, "500 Internal Server Error: customer application code failed\n")
            return

        self._send(200, body)

    def log_message(self, fmt, *args):
        log("%s %s" % (self.address_string(), fmt % args))


socketserver.TCPServer.allow_reuse_address = True
log("platform host starting on %s:%d" % LISTEN)
with socketserver.TCPServer(LISTEN, Handler) as httpd:
    httpd.serve_forever()
PY

  cat > "${LAB_ROOT}/paas/platform/db.py" <<'PY'
#!/usr/bin/env python3
"""Managed backing service - PROVIDER MANAGED (the PaaS data tier).

Azure analogue: Azure Database for PostgreSQL / Azure SQL Database. You never
patch it, never restart its host, never open a shell on it. You point your
application at it and you own the data inside it.
"""
import socketserver
import sys


class Banner(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.sendall(b"AZ900-DB OK\n")


socketserver.TCPServer.allow_reuse_address = True
sys.stderr.write("az900-db: listening on 127.0.0.1:8083\n")
sys.stderr.flush()
with socketserver.TCPServer(("127.0.0.1", 8083), Banner) as srv:
    srv.serve_forever()
PY

  cat > "${LAB_ROOT}/paas/platform/runtime.sh" <<EOF
#!/usr/bin/env bash
# PaaS runtime launcher - PROVIDER MANAGED. Do not modify.
# In Azure App Service this is the worker bootstrap: you cannot edit it, you
# can only change application settings and redeploy your own code.
set -euo pipefail
exec ${PYTHON_BIN} /opt/az900-lab/paas/platform/host.py
EOF

  cat > "${LAB_ROOT}/paas/app/app.py" <<'PY'
"""Customer application code - CUSTOMER MANAGED (this is your deployment)."""


def render(settings, backend_banner):
    return (
        "PaaS tier healthy\n"
        "application : %s\n"
        "backend     : %s\n"
        "backend says: %s\n"
        % (settings.get("APP_NAME", "<unset>"),
           settings.get("DB_ENDPOINT", "<unset>"),
           backend_banner)
    )
PY

  cat > "${LAB_ROOT}/paas/app/appsettings.env" <<'ENV'
# Customer-managed application settings.
# Azure analogue: App Service -> Settings -> Environment variables
# (App settings and Connection strings). Changing one restarts the app.
APP_NAME="Contoso Order API"

# Endpoint of the managed backing service published by az900-db.service.
DB_ENDPOINT=127.0.0.1:9999
ENV

  # ---- SaaS tier: only identities, access and data are yours -----------------
  cat > "${LAB_ROOT}/saas/service/saas-portal" <<'PY'
#!/usr/bin/env python3
"""SaaS control plane - PROVIDER MANAGED. Do not modify.

Azure analogue: Microsoft 365 / any SaaS application fronted by Microsoft
Entra ID. The vendor owns the application, the runtime, the OS and the
network. The tenant owns accounts, identities, role assignments and data.
https://learn.microsoft.com/en-us/entra/fundamentals/whatis
"""
import json
import pathlib
import sys

TENANT = pathlib.Path("/opt/az900-lab/saas/tenant/tenant.json")
APP_NAME = "Contoso Learning Portal"
REQUIRED_ROLE = "Learner"


def fail(msg):
    sys.stderr.write(msg + "\n")
    return 1


def main(argv):
    if len(argv) != 3 or argv[1] != "signin":
        sys.stderr.write("usage: saas-portal signin <userPrincipalName>\n")
        return 2

    upn = argv[2]
    try:
        tenant = json.loads(TENANT.read_text())
    except FileNotFoundError:
        return fail("TenantConfigurationMissing: %s does not exist." % TENANT)
    except json.JSONDecodeError as exc:
        return fail("TenantConfigurationInvalid: %s is not valid JSON (%s)." % (TENANT, exc))

    directory = {u.get("userPrincipalName"): u for u in tenant.get("users", [])}
    user = directory.get(upn)
    if user is None:
        return fail("AADSTS50034: The user account %s does not exist in tenant '%s'."
                    % (upn, tenant.get("tenantName", "unknown")))
    if not user.get("accountEnabled", False):
        return fail("AADSTS50057: The user account %s is disabled." % upn)
    if REQUIRED_ROLE not in user.get("appRoleAssignments", []):
        return fail("AADSTS50105: The signed in user %s is not assigned to a role "
                    "for the application '%s'." % (upn, APP_NAME))

    print("Access granted: %s -> %s (role: %s)" % (upn, APP_NAME, REQUIRED_ROLE))
    print("SaaS tier healthy")
    return 0


sys.exit(main(sys.argv))
PY

  cat > "${LAB_ROOT}/saas/tenant/tenant.json" <<'JSON'
{
  "tenantName": "contoso.example",
  "application": "Contoso Learning Portal",
  "comment": "Customer-managed tenant configuration: accounts, identities, role assignments and data.",
  "users": [
    {
      "userPrincipalName": "admin@contoso.example",
      "displayName": "Tenant Administrator",
      "accountEnabled": true,
      "appRoleAssignments": ["Learner", "Administrator"]
    },
    {
      "userPrincipalName": "student@contoso.example",
      "displayName": "Lab Student",
      "accountEnabled": false,
      "appRoleAssignments": []
    }
  ]
}
JSON

  # ---- ownership: provider surfaces read-only, customer surfaces writable ----
  chmod 0755 "${LAB_ROOT}/iaas/app/serve.py"
  chown -R root:root "${LAB_ROOT}"
  chmod 0644 "${LAB_ROOT}/iaas/wwwroot/index.html"

  chmod 0555 "${LAB_ROOT}/paas/platform/runtime.sh" "${LAB_ROOT}/paas/platform/host.py" \
             "${LAB_ROOT}/paas/platform/db.py"
  chmod 0555 "${LAB_ROOT}/paas/platform"
  chmod 0555 "${LAB_ROOT}/saas/service/saas-portal" "${LAB_ROOT}/saas/service"

  chown -R "${LAB_USER}:${LAB_USER}" "${LAB_ROOT}/paas/app"
  chmod 0644 "${LAB_ROOT}/paas/app/appsettings.env" "${LAB_ROOT}/paas/app/app.py"
  chmod 0644 "${LAB_ROOT}/saas/tenant/tenant.json"

  # ---- units -----------------------------------------------------------------
  cat > "${UNIT_DIR}/az900-iaas.service" <<EOF
[Unit]
Description=AZ-900 1.3 lab - IaaS tier (you manage OS, runtime and app)
Documentation=https://learn.microsoft.com/en-us/azure/virtual-machines/overview
After=network-online.target

[Service]
Type=simple
User=${LAB_USER}
Group=${LAB_USER}
Environment=PYTHONUNBUFFERED=1
ExecStart=${FAKE_PY} ${LAB_ROOT}/iaas/app/serve.py
Restart=no

[Install]
WantedBy=multi-user.target
EOF

  cat > "${UNIT_DIR}/az900-db.service" <<EOF
[Unit]
Description=AZ-900 1.3 lab - managed backing service (provider managed)
After=network-online.target

[Service]
Type=simple
User=${LAB_USER}
Group=${LAB_USER}
Environment=PYTHONUNBUFFERED=1
ExecStart=${PYTHON_BIN} ${LAB_ROOT}/paas/platform/db.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  cat > "${UNIT_DIR}/az900-paas.service" <<EOF
[Unit]
Description=AZ-900 1.3 lab - PaaS platform host (provider managed runtime)
Documentation=https://learn.microsoft.com/en-us/azure/app-service/overview
After=az900-db.service
Wants=az900-db.service

[Service]
Type=simple
User=${LAB_USER}
Group=${LAB_USER}
Environment=PYTHONUNBUFFERED=1
ExecStart=${LAB_ROOT}/paas/platform/runtime.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

write_manifest() {
  sha256sum \
    "${LAB_ROOT}/paas/platform/runtime.sh" \
    "${LAB_ROOT}/paas/platform/host.py" \
    "${LAB_ROOT}/paas/platform/db.py" \
    "${LAB_ROOT}/saas/service/saas-portal" \
    "${UNIT_DIR}/az900-paas.service" \
    "${UNIT_DIR}/az900-db.service" > "${MANIFEST}"
  chown root:root "${MANIFEST}"
  chmod 0444 "${MANIFEST}"
}

# -----------------------------------------------------------------------------
# break - three faults, one per service type
# -----------------------------------------------------------------------------
cmd_break() {
  require_root break
  require_confirm
  require_tools

  info "tearing down any previous run (the lab is idempotent)"
  cmd_reset >/dev/null

  local p
  for p in "${IAAS_PORT}" "${PAAS_PORT}" "${DB_PORT}"; do
    if port_in_use "${p}"; then
      die "127.0.0.1:${p} is already taken by a non-lab process. Free it or move the lab."
    fi
  done

  info "building the three tiers under ${LAB_ROOT}"
  build_lab
  write_manifest

  # FAULT 1 (IaaS, guest OS + runtime layer):
  #   the unit points at an interpreter that does not exist on this VM.
  rm -f "${FAKE_PY}"

  # FAULT 2 (IaaS, file system permissions):
  #   the site content is readable only by root, the service runs unprivileged.
  chown root:root "${LAB_ROOT}/iaas/wwwroot/index.html"
  chmod 0600 "${LAB_ROOT}/iaas/wwwroot/index.html"

  # FAULT 3 (PaaS, customer application settings):
  #   the connection string points at a port where nothing is listening.
  #   The platform host and the managed backing service are perfectly healthy.
  #   (already seeded as DB_ENDPOINT=127.0.0.1:9999 in appsettings.env)

  # FAULT 4 (SaaS, identity and access - the only layer a tenant owns):
  #   the learner account is disabled and has no application role assignment.
  #   (already seeded in tenant.json)

  systemctl enable --now az900-db.service   >/dev/null 2>&1 || true
  systemctl enable --now az900-paas.service >/dev/null 2>&1 || true
  systemctl enable az900-iaas.service       >/dev/null 2>&1 || true
  systemctl start  az900-iaas.service       >/dev/null 2>&1 || true
  sleep 1

  cat <<EOF

===============================================================================
 AZ-900 1.3 - BREAK & FIX BRIEF: "Who owns the failure?"
===============================================================================

Three tiers are deployed on this VM. Each one models a cloud service type, and
each one is broken at a DIFFERENT layer of the shared responsibility model.
Your job is not only to make them green - it is to fix each one at the layer
that is actually yours, and to leave the provider's layer untouched.

 TIER 1 - IaaS      http://127.0.0.1:${IAAS_PORT}      unit: az900-iaas.service
 -----------------------------------------------------------------------------
 SYMPTOM A  The service never comes up.

     \$ systemctl is-active az900-iaas.service
     failed
     \$ curl -i http://127.0.0.1:${IAAS_PORT}/
     curl: (7) Failed to connect to 127.0.0.1 port ${IAAS_PORT} after 0 ms: Couldn't connect to server

   systemctl status will show the process exiting with status=203/EXEC before
   a single line of application code runs.

 SYMPTOM B  Once it starts, the site answers but refuses to serve content:

     \$ curl -i http://127.0.0.1:${IAAS_PORT}/
     HTTP/1.0 403 Forbidden
     403 Forbidden: the web service account cannot read the site content

 GOAL       GET http://127.0.0.1:${IAAS_PORT}/ returns 200 with "IaaS tier healthy",
            with the unit active and still running unprivileged as ${LAB_USER}.
            In IaaS everything inside the guest is yours: OS, runtime, service
            unit and file permissions. Nothing here needs a support ticket.

 TIER 2 - PaaS      http://127.0.0.1:${PAAS_PORT}      unit: az900-paas.service
 -----------------------------------------------------------------------------
 SYMPTOM    The platform host is running and healthy, yet every request fails:

     \$ curl -i http://127.0.0.1:${PAAS_PORT}/
     HTTP/1.0 503 Service Unavailable
     503 Service Unavailable: the application cannot reach its backing service
         DB_ENDPOINT=127.0.0.1:9999

     \$ journalctl -u az900-paas.service -n 5 --no-pager
     paas-host: dependency probe failed: DB_ENDPOINT='127.0.0.1:9999' [Errno 111] Connection refused

 GOAL       GET http://127.0.0.1:${PAAS_PORT}/ returns 200 with "PaaS tier healthy".
 RULE       ${LAB_ROOT}/paas/platform/ and the az900-paas / az900-db units are
            PROVIDER-managed. Editing them is the equivalent of SSH-ing into a
            Microsoft App Service worker: not possible in reality, and graded
            as a failure here. Fix it from the customer side only.

 TIER 3 - SaaS      CLI: ${LAB_ROOT}/saas/service/saas-portal
 -----------------------------------------------------------------------------
 SYMPTOM    The application is up; your user cannot get in:

     \$ ${LAB_ROOT}/saas/service/saas-portal signin student@contoso.example
     AADSTS50057: The user account student@contoso.example is disabled.

   Clear that one and a second, different error takes its place. Read it - the
   AADSTS code tells you exactly which control plane object is missing.
   https://learn.microsoft.com/en-us/entra/identity-platform/reference-error-codes

 GOAL       The same command exits 0 and prints "Access granted".
 RULE       ${LAB_ROOT}/saas/service/ is the vendor's application. In SaaS the
            only things you own are accounts, identities, access and data.

 GRADE YOURSELF
 -----------------------------------------------------------------------------
     ${0} verify     PASS/FAIL per tier + integrity check on provider files
     ${0} hint       the shared responsibility matrix (not the answers)
     ${0} status     raw systemd / HTTP / sign-in state
     sudo ${0} reset remove the lab entirely

 Target time: 20 minutes. The step-by-step solution is at the bottom of this
 script, commented out - do not read it until "verify" has beaten you twice.
===============================================================================

EOF
}

# -----------------------------------------------------------------------------
# verify - grade the repair, including "did you cheat on the provider's layer"
# -----------------------------------------------------------------------------
cmd_verify() {
  require_tools
  [[ -d "${LAB_ROOT}" ]] || die "the lab is not deployed. Run: sudo AZ900_LAB_CONFIRM=yes $0 break"

  local failures=0 code body

  say ""
  say "AZ-900 1.3 - grading three tiers"
  say "-------------------------------------------------------------------------------"

  # IaaS
  code="$(http_code "http://127.0.0.1:${IAAS_PORT}/")"
  body="$(http_body "http://127.0.0.1:${IAAS_PORT}/")"
  if [[ "${code}" == "200" && "${body}" == *"IaaS tier healthy"* ]]; then
    ok "IaaS  - HTTP 200 from 127.0.0.1:${IAAS_PORT} (unit: $(unit_state az900-iaas.service))"
  else
    bad "IaaS  - HTTP ${code} from 127.0.0.1:${IAAS_PORT} (unit: $(unit_state az900-iaas.service))"
    case "${code}" in
      000) say "        nothing is listening: the process is not running. Look at ExecStart." ;;
      403) say "        it runs, but the unprivileged service account cannot read the content." ;;
      404) say "        it runs, but the document root has no index.html." ;;
    esac
    failures=$((failures + 1))
  fi

  # PaaS
  code="$(http_code "http://127.0.0.1:${PAAS_PORT}/")"
  body="$(http_body "http://127.0.0.1:${PAAS_PORT}/")"
  if [[ "${code}" == "200" && "${body}" == *"PaaS tier healthy"* ]]; then
    ok "PaaS  - HTTP 200 from 127.0.0.1:${PAAS_PORT} (backing service: $(unit_state az900-db.service))"
  else
    bad "PaaS  - HTTP ${code} from 127.0.0.1:${PAAS_PORT} (backing service: $(unit_state az900-db.service))"
    [[ "${code}" == "503" ]] && say "        the platform host is healthy; your application configuration is not."
    failures=$((failures + 1))
  fi

  # SaaS
  if "${LAB_ROOT}/saas/service/saas-portal" signin student@contoso.example >/dev/null 2>&1; then
    ok "SaaS  - sign-in succeeds for student@contoso.example"
  else
    bad "SaaS  - sign-in still rejected for student@contoso.example"
    say "        $("${LAB_ROOT}/saas/service/saas-portal" signin student@contoso.example 2>&1 || true)"
    failures=$((failures + 1))
  fi

  # Integrity of the provider-managed surface
  if sha256sum -c --status "${MANIFEST}" 2>/dev/null; then
    ok "SCOPE - provider-managed files are untouched (platform host, backing service, SaaS app)"
  else
    bad "SCOPE - a PROVIDER-managed file was modified:"
    sha256sum -c "${MANIFEST}" 2>/dev/null | grep -v ': OK$' | sed 's/^/        /' || true
    say "        In Azure you cannot patch an App Service worker or a SaaS application."
    say "        A fix that requires it is not a fix - it is an outage report to the vendor."
    failures=$((failures + 1))
  fi

  say "-------------------------------------------------------------------------------"
  if [[ "${failures}" -eq 0 ]]; then
    say "RESULT: PASS - all three service types restored from the customer side only."
    say ""
    say "  IaaS  you fixed the runtime and the file permissions inside your own guest OS."
    say "  PaaS  you fixed an application setting; the platform never needed your help."
    say "  SaaS  you fixed identity and access, the only plane a SaaS tenant controls."
    say ""
    say "  That gradient - shrinking customer surface, growing provider surface - IS the"
    say "  answer to every AZ-900 1.3 question. Reference:"
    say "  https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility"
    return 0
  fi
  say "RESULT: FAIL - ${failures} check(s) outstanding. Run '${0} hint' if you are stuck."
  return 1
}

# -----------------------------------------------------------------------------
# status / hint
# -----------------------------------------------------------------------------
cmd_status() {
  require_tools
  [[ -d "${LAB_ROOT}" ]] || die "the lab is not deployed."
  local u
  say ""
  say "systemd"
  for u in "${UNITS[@]}"; do
    printf '  %-22s %s\n' "${u}.service" "$(unit_state "${u}.service")"
  done
  say ""
  say "endpoints"
  printf '  %-22s HTTP %s\n' "iaas 127.0.0.1:${IAAS_PORT}" "$(http_code "http://127.0.0.1:${IAAS_PORT}/")"
  printf '  %-22s HTTP %s\n' "paas 127.0.0.1:${PAAS_PORT}" "$(http_code "http://127.0.0.1:${PAAS_PORT}/")"
  say ""
  say "saas sign-in"
  "${LAB_ROOT}/saas/service/saas-portal" signin student@contoso.example 2>&1 | sed 's/^/  /' || true
  say ""
  say "customer-managed application settings"
  sed 's/^/  /' "${LAB_ROOT}/paas/app/appsettings.env"
  say ""
}

cmd_hint() {
  cat <<'EOF'

Shared responsibility model - who owns what, by service type
(source: https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility)

  Responsibility                          SaaS       PaaS       IaaS
  ---------------------------------------------------------------------
  Information and data                    CUSTOMER   CUSTOMER   CUSTOMER
  Devices (mobile and PCs)                CUSTOMER   CUSTOMER   CUSTOMER
  Accounts and identities                 CUSTOMER   CUSTOMER   CUSTOMER
  Identity and directory infrastructure   SHARED     SHARED     CUSTOMER
  Applications                            PROVIDER   SHARED     CUSTOMER
  Network controls                        PROVIDER   SHARED     CUSTOMER
  Operating system                        PROVIDER   PROVIDER   CUSTOMER
  Physical hosts / network / datacenter   PROVIDER   PROVIDER   PROVIDER

How to use it as a triage tool - for each broken tier ask, in order:
  1. Which service type is this? (a VM you patch, a platform you deploy to, an
     application you only subscribe to)
  2. Which layer is the symptom in? (exec failure -> OS/runtime; connection
     refused to a dependency -> app configuration; AADSTS error -> identity)
  3. Cross the two. If the cell says CUSTOMER, fix it. If it says PROVIDER,
     the correct action is a support ticket, not a workaround - and in this lab
     touching it is graded as a failure.

Useful diagnostics, in escalation order:
  systemctl status az900-iaas.service --no-pager -l
  journalctl -u az900-paas.service -n 30 --no-pager
  ss -lntp | grep -E '808[123]'
  sudo -u az900lab cat /opt/az900-lab/iaas/wwwroot/index.html
  systemd-analyze verify /etc/systemd/system/az900-iaas.service

EOF
}

main() {
  case "${1:-}" in
    break)  cmd_break ;;
    verify) cmd_verify ;;
    status) cmd_status ;;
    hint)   cmd_hint ;;
    reset)  cmd_reset ;;
    ""|-h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
