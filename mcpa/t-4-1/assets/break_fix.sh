#!/usr/bin/env bash
#
# ==============================================================================
#  MCPA 4.1 — Trust Boundaries — BREAK & FIX LAB
#  Certification : Model Context Protocol Associate (MCPA), exam version 2026-07-28
#  Objective 4.1 : Trust Boundaries (exam weight 6.0)
# ==============================================================================
#
#  WHAT THIS SCRIPT DOES
#    Builds a small but realistic MCP server ("notes"), Streamable HTTP transport,
#    protocol revision 2025-06-18, and deploys it with FIVE trust boundary guards
#    deliberately removed. The student must restore them until the bundled
#    verifier reports 7/7 PASS, WITHOUT breaking the legitimate tool call.
#
#  SAFETY
#    - Everything lives under /opt/mcp-lab and /etc/systemd/system/mcp-lab.service.
#    - The service runs as the unprivileged system user "mcplab", with
#      NoNewPrivileges / ProtectSystem=strict / ProtectHome=yes, so the deliberate
#      path traversal cannot reach anything that matters.
#    - The "secret" it leaks is a canary string, not a credential.
#    - The broken server binds 0.0.0.0:8931 ON PURPOSE. Run this ONLY on a
#      disposable lab VM you can throw away, never on a shared or routed network.
#    - `--cleanup` removes the unit, the user and the directory.
#
#  REFERENCES (official)
#    - https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
#    - https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices
#    - https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
#    - https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
#    - https://datatracker.ietf.org/doc/html/rfc9728  (OAuth 2.0 Protected Resource Metadata)
#    - https://datatracker.ietf.org/doc/html/rfc8707  (Resource Indicators for OAuth 2.0)
#
set -euo pipefail

LAB_DIR="/opt/mcp-lab"
LAB_USER="mcplab"
LAB_PORT="8931"
UNIT_PATH="/etc/systemd/system/mcp-lab.service"
MARKER="${LAB_DIR}/.mcpa-lab-4.1"
CANARY="CANARY-MCPA-41-TRUST-BOUNDARY"

usage() {
    cat <<'EOF'
Usage: mcpa-4.1-trust-boundaries.sh [--break | --verify | --reset | --cleanup | --help]

  --break     (default) build the lab and deploy the BROKEN MCP server
  --verify    run the 7 trust boundary checks against the running server
  --reset     re-deploy the broken server (start the exercise over)
  --cleanup   remove the unit, the lab directory and the lab user
  --help      this text

Environment:
  MCPA_LAB_CONFIRM=yes   skip the interactive confirmation (unattended labs)
EOF
}

log()  { printf '[mcpa-4.1] %s\n' "$*"; }
die()  { printf '[mcpa-4.1] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "run as root (sudo $0 $*)"
}

preflight() {
    local missing=()
    for bin in python3 curl ss systemctl awk sed grep useradd; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    [ "${#missing[@]}" -eq 0 ] || die "missing required tools: ${missing[*]}"
    [ -d /run/systemd/system ] || die "systemd is not running; this lab needs a VM, not a container"
}

confirm() {
    if [ "${MCPA_LAB_CONFIRM:-no}" = "yes" ]; then
        return 0
    fi
    cat <<EOF

  This will deploy a deliberately INSECURE MCP server on this machine:
    - listening on 0.0.0.0:${LAB_PORT} (reachable from your LAN)
    - accepting bearer tokens minted for OTHER resource servers
    - serving files from outside its workspace root

  Only do this on a disposable lab VM.

EOF
    read -r -p "  Type BREAK to continue: " answer
    [ "$answer" = "BREAK" ] || die "aborted by the user"
}

# ------------------------------------------------------------------------------
# lab assets
# ------------------------------------------------------------------------------

create_user() {
    if ! id -u "$LAB_USER" >/dev/null 2>&1; then
        useradd --system --home-dir "$LAB_DIR" --no-create-home --shell /sbin/nologin "$LAB_USER"
        log "created system user ${LAB_USER}"
    fi
}

write_tree() {
    mkdir -p "$LAB_DIR/workspace" "$LAB_DIR/secrets"
    : > "$MARKER"

    cat > "$LAB_DIR/workspace/welcome.md" <<'EOF'
# Notes workspace

MCPA-4.1-WORKSPACE-OK

This file lives inside the workspace root, which is the only data this MCP server
is authorised to expose. Anything it can read outside this directory is a trust
boundary failure, not a feature.
EOF

    cat > "$LAB_DIR/workspace/runbook.md" <<'EOF'
# On-call runbook (lab sample)

1. Check the MCP server: systemctl status mcp-lab
2. Tail the transport log: journalctl -u mcp-lab -f
3. Confirm the listener scope: ss -ltn | grep 8931
EOF

    cat > "$LAB_DIR/secrets/customer-tokens.txt" <<EOF
# Simulated blast radius for the MCPA 4.1 lab. Nothing here is a real credential.
${CANARY}
integration-token = PRETEND-TOKEN-0000-DO-NOT-USE
EOF

    if [ ! -s "$LAB_DIR/jwt.key" ]; then
        head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$LAB_DIR/jwt.key"
        printf '\n' >> "$LAB_DIR/jwt.key"
    fi
}

write_token_minter() {
    cat > "$LAB_DIR/mint-token.py" <<'PY'
#!/usr/bin/env python3
"""Stand-in authorization server for the MCPA 4.1 lab.

Mints an HS256 bearer token for an arbitrary audience, which is exactly what an
attacker (or a careless gateway) has when it replays a token that was issued for
a different resource server.

    mint-token.py [audience] [ttl_seconds]
"""
import base64
import hashlib
import hmac
import json
import sys
import time

LAB_DIR = "/opt/mcp-lab"
ISSUER = "https://idp.mcp.lab"
DEFAULT_AUDIENCE = "https://notes.mcp.lab/mcp"


def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def main():
    audience = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_AUDIENCE
    ttl = int(sys.argv[2]) if len(sys.argv) > 2 else 3600

    with open(LAB_DIR + "/jwt.key", "rb") as fh:
        key = fh.read().strip()

    now = int(time.time())
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {
        "iss": ISSUER,
        "sub": "student@mcp.lab",
        "aud": audience,
        "iat": now - 10,
        "exp": now + ttl,
        "scope": "notes.read",
    }
    signing_input = "%s.%s" % (
        b64url(json.dumps(header, separators=(",", ":")).encode()),
        b64url(json.dumps(payload, separators=(",", ":")).encode()),
    )
    signature = b64url(hmac.new(key, signing_input.encode(), hashlib.sha256).digest())
    print("%s.%s" % (signing_input, signature))


if __name__ == "__main__":
    main()
PY
}

write_broken_server() {
    cat > "$LAB_DIR/server.py" <<'PY'
#!/usr/bin/env python3
"""MCPA 4.1 lab: "notes" MCP server over the Streamable HTTP transport.

Teaching artifact: stdlib only, no framework, single file, so that every trust
decision is visible in one screen of code. It is NOT production code.
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LAB_DIR = "/opt/mcp-lab"
WORKSPACE_ROOT = os.path.join(LAB_DIR, "workspace")
RESOURCE_URI = "https://notes.mcp.lab/mcp"
ISSUER = "https://idp.mcp.lab"
PROTOCOL_VERSION = "2025-06-18"
MAX_BYTES = 8192

BIND = os.environ.get("MCP_LAB_BIND", "0.0.0.0")
PORT = int(os.environ.get("MCP_LAB_PORT", "8931"))
PUBLIC_BASE = "http://127.0.0.1:%d" % PORT

ALLOWED_ORIGINS = ("http://127.0.0.1:%d" % PORT, "http://localhost:%d" % PORT)

with open(os.path.join(LAB_DIR, "jwt.key"), "rb") as _fh:
    SIGNING_KEY = _fh.read().strip()

TOOL = {
    "name": "read_note",
    "title": "Read a note",
    "description": "Return the contents of a markdown note from the notes workspace.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "path": {
                "type": "string",
                "description": "Path of the note, relative to the workspace root.",
            }
        },
        "required": ["path"],
    },
}


def b64url_decode(part):
    padding = "=" * (-len(part) % 4)
    return base64.urlsafe_b64decode(part + padding)


def decode_token(raw):
    """Verify the HS256 signature and return the claims dict, or None."""
    try:
        header_b64, payload_b64, signature_b64 = raw.split(".")
        signing_input = ("%s.%s" % (header_b64, payload_b64)).encode()
        expected = hmac.new(SIGNING_KEY, signing_input, hashlib.sha256).digest()
        if not hmac.compare_digest(expected, b64url_decode(signature_b64)):
            return None
        return json.loads(b64url_decode(payload_b64))
    except (ValueError, TypeError):
        return None


def authenticate(headers):
    header = headers.get("Authorization", "")
    if not header.startswith("Bearer "):
        return None
    return decode_token(header[7:].strip())


def read_note(arguments):
    relative = str(arguments.get("path", ""))
    target = os.path.join(WORKSPACE_ROOT, relative)
    try:
        if not os.path.isfile(target):
            return {
                "content": [{"type": "text", "text": "no such note: %s" % relative}],
                "isError": True,
            }
        with open(target, "r", errors="replace") as fh:
            text = fh.read(MAX_BYTES)
    except OSError as exc:
        return {
            "content": [{"type": "text", "text": "cannot read %s: %s" % (relative, exc.strerror)}],
            "isError": True,
        }
    return {"content": [{"type": "text", "text": text}]}


class Handler(BaseHTTPRequestHandler):
    server_version = "mcp-lab/0.1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def _send(self, code, payload=None, extra_headers=None):
        body = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        if body:
            self.send_header("Content-Type", "application/json")
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        if self.path.split("?")[0].startswith("/.well-known/oauth-protected-resource"):
            self._send(200, {
                "resource": RESOURCE_URI,
                "authorization_servers": [ISSUER],
                "scopes_supported": ["notes.read"],
                "bearer_methods_supported": ["header"],
            })
            return
        self._send(405, {"error": "method_not_allowed"})

    def do_POST(self):
        if self.path.split("?")[0] != "/mcp":
            self._send(404, {"error": "not_found"})
            return

        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            request = json.loads(raw or b"{}")
        except ValueError:
            self._send(400, {"jsonrpc": "2.0", "id": None,
                             "error": {"code": -32700, "message": "parse error"}})
            return

        claims = authenticate(self.headers)
        if claims is None:
            self._send(401, {"error": "invalid_token"})
            return

        method = request.get("method", "")
        request_id = request.get("id")

        if method == "initialize":
            result = {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "notes", "version": "0.1.0"},
            }
        elif method.startswith("notifications/"):
            self._send(202)
            return
        elif method == "tools/list":
            result = {"tools": [TOOL]}
        elif method == "tools/call":
            params = request.get("params") or {}
            if params.get("name") != TOOL["name"]:
                self._send(200, {"jsonrpc": "2.0", "id": request_id,
                                 "error": {"code": -32602, "message": "unknown tool"}})
                return
            result = read_note(params.get("arguments") or {})
        else:
            self._send(200, {"jsonrpc": "2.0", "id": request_id,
                             "error": {"code": -32601, "message": "method not found"}})
            return

        self._send(200, {"jsonrpc": "2.0", "id": request_id, "result": result})


def main():
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    sys.stderr.write("notes MCP server listening on %s:%d, resource %s\n"
                     % (BIND, PORT, RESOURCE_URI))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
PY
}

write_verifier() {
    cat > "$LAB_DIR/verify.sh" <<'VERIFY'
#!/usr/bin/env bash
# Trust boundary verifier for MCPA 4.1. Run as root: bash /opt/mcp-lab/verify.sh
set -uo pipefail

LAB_DIR="/opt/mcp-lab"
PORT="8931"
URL="http://127.0.0.1:${PORT}/mcp"
PROTO="2025-06-18"
RESOURCE="https://notes.mcp.lab/mcp"
FOREIGN_RESOURCE="https://files.other.lab/mcp"
CANARY="CANARY-MCPA-41-TRUST-BOUNDARY"

BODY="$(mktemp)"
HDRS="$(mktemp)"
trap 'rm -f "$BODY" "$HDRS"' EXIT

TOTAL=7
INDEX=0
FAILED=0

report() {  # report <PASS|FAIL> <name> <detail>
    INDEX=$((INDEX + 1))
    printf '[ %d/%d ] %-4s  %-22s %s\n' "$INDEX" "$TOTAL" "$1" "$2" "$3"
    [ "$1" = "FAIL" ] && FAILED=$((FAILED + 1))
    return 0
}

call() {  # call <origin|-> <token|-> <json-body>  -> prints HTTP status
    local origin="$1" token="$2" data="$3"
    local args=(-s -o "$BODY" -D "$HDRS" -w '%{http_code}' -X POST "$URL"
                -H 'Content-Type: application/json'
                -H 'Accept: application/json, text/event-stream'
                -H "MCP-Protocol-Version: ${PROTO}")
    [ "$origin" != "-" ] && args+=(-H "Origin: ${origin}")
    [ "$token" != "-" ] && args+=(-H "Authorization: Bearer ${token}")
    args+=(--data "$data")
    curl "${args[@]}" 2>/dev/null || echo 000
}

TOKEN_OK="$(python3 "${LAB_DIR}/mint-token.py" "$RESOURCE" 3600)"
TOKEN_FOREIGN="$(python3 "${LAB_DIR}/mint-token.py" "$FOREIGN_RESOURCE" 3600)"
TOKEN_EXPIRED="$(python3 "${LAB_DIR}/mint-token.py" "$RESOURCE" -120)"

echo
echo "MCPA 4.1 — Trust Boundaries — verifier"
echo "--------------------------------------------------------------------------"

# 1. network boundary: the listener must not leave the host.
listeners="$(ss -ltn 2>/dev/null | awk '{print $4}' | grep -E ":${PORT}\$" || true)"
if [ -z "$listeners" ]; then
    report FAIL "listener scope" "nothing is listening on port ${PORT} (is mcp-lab.service up?)"
else
    bad=""
    while read -r addr; do
        host="${addr%:*}"
        case "$host" in
            127.0.0.1|\[::1\]|::1) ;;
            *) bad="${bad} ${addr}" ;;
        esac
    done <<< "$listeners"
    if [ -n "$bad" ]; then
        report FAIL "listener scope" "reachable off-host on:${bad}"
    else
        report PASS "listener scope" "loopback only (${listeners})"
    fi
fi

# 2. browser boundary: a cross-origin POST must be refused (DNS rebinding).
code="$(call 'http://evil.example' "$TOKEN_OK" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
if [ "$code" = "403" ]; then
    report PASS "browser origin" "cross-origin POST rejected with 403"
else
    report FAIL "browser origin" "POST with Origin: http://evil.example returned ${code} (expected 403)"
fi

# 3. authentication boundary: no token -> 401 that advertises the resource metadata.
code="$(call '-' '-' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
challenge="$(grep -i '^www-authenticate:' "$HDRS" | tr -d '\r' || true)"
metadata="$(curl -s "http://127.0.0.1:${PORT}/.well-known/oauth-protected-resource" 2>/dev/null || true)"
if [ "$code" != "401" ]; then
    report FAIL "unauthenticated" "anonymous tools/list returned ${code} (expected 401)"
elif ! printf '%s' "$challenge" | grep -qi 'resource_metadata='; then
    report FAIL "unauthenticated" "401 without a WWW-Authenticate resource_metadata challenge (RFC 9728)"
elif ! printf '%s' "$metadata" | grep -q "$RESOURCE"; then
    report FAIL "unauthenticated" "protected resource metadata does not declare ${RESOURCE}"
else
    report PASS "unauthenticated" "401 + WWW-Authenticate resource_metadata"
fi

# 4. audience boundary: a token minted for another resource must not be honoured.
code="$(call '-' "$TOKEN_FOREIGN" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
if [ "$code" = "401" ]; then
    report PASS "token audience" "token for ${FOREIGN_RESOURCE} rejected"
else
    report FAIL "token audience" "token minted for ${FOREIGN_RESOURCE} returned ${code} (expected 401)"
fi

# 5. lifetime boundary: an expired token must not be honoured.
code="$(call '-' "$TOKEN_EXPIRED" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
if [ "$code" = "401" ]; then
    report PASS "token lifetime" "expired token rejected"
else
    report FAIL "token lifetime" "expired token returned ${code} (expected 401)"
fi

# 6. data boundary: the tool must stay inside the workspace root.
traversal='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_note","arguments":{"path":"../secrets/customer-tokens.txt"}}}'
code="$(call '-' "$TOKEN_OK" "$traversal")"
if grep -q "$CANARY" "$BODY" 2>/dev/null; then
    report FAIL "path containment" "the tool exfiltrated ${LAB_DIR}/secrets/customer-tokens.txt"
elif grep -qE '"isError"[[:space:]]*:[[:space:]]*true|"error"[[:space:]]*:' "$BODY" 2>/dev/null; then
    report PASS "path containment" "traversal refused, canary not disclosed"
else
    report FAIL "path containment" "traversal returned ${code} without an explicit refusal"
fi

# 7. the boundary must not be enforced by breaking the product.
legit='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_note","arguments":{"path":"welcome.md"}}}'
code="$(call '-' "$TOKEN_OK" "$legit")"
if [ "$code" = "200" ] && grep -q 'MCPA-4.1-WORKSPACE-OK' "$BODY" 2>/dev/null; then
    report PASS "legitimate call" "read_note welcome.md still works"
else
    report FAIL "legitimate call" "authorised read_note welcome.md returned ${code} without the note"
fi

echo "--------------------------------------------------------------------------"
if [ "$FAILED" -eq 0 ]; then
    echo "RESULT: 7/7 PASS — every trust boundary is enforced and the server still works."
    exit 0
fi
echo "RESULT: $((TOTAL - FAILED))/${TOTAL} PASS, ${FAILED} boundary failure(s) remaining."
exit 1
VERIFY
    chmod 0755 "$LAB_DIR/verify.sh"
}

write_unit() {
    local python_bin
    python_bin="$(command -v python3)"
    cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=MCPA 4.1 lab - notes MCP server (Streamable HTTP)
Documentation=https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
After=network.target

[Service]
User=${LAB_USER}
Group=${LAB_USER}
WorkingDirectory=${LAB_DIR}
Environment=MCP_LAB_BIND=0.0.0.0
Environment=MCP_LAB_PORT=${LAB_PORT}
ExecStart=${python_bin} ${LAB_DIR}/server.py
Restart=on-failure
RestartSec=2
# Lab containment: the deliberate break must not escape the exercise.
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
ReadWritePaths=${LAB_DIR}

[Install]
WantedBy=multi-user.target
UNIT
}

apply_permissions() {
    chown -R root:"$LAB_USER" "$LAB_DIR"
    chmod 0750 "$LAB_DIR"
    chmod 0644 "$LAB_DIR/server.py" "$LAB_DIR/mint-token.py"
    chmod 0640 "$LAB_DIR/jwt.key"
    chmod 0750 "$LAB_DIR/secrets"
    chmod 0640 "$LAB_DIR/secrets/customer-tokens.txt"
    chmod 0755 "$LAB_DIR/workspace"
    chmod 0644 "$LAB_DIR/workspace/"*.md
}

start_service() {
    systemctl daemon-reload
    systemctl enable --now mcp-lab.service >/dev/null 2>&1 || true
    systemctl restart mcp-lab.service
    sleep 1
    systemctl is-active --quiet mcp-lab.service \
        || die "mcp-lab.service failed to start; inspect with: journalctl -u mcp-lab -n 50"
}

briefing() {
    cat <<EOF

================================================================================
 MCPA 4.1 — TRUST BOUNDARIES — BREAK & FIX
================================================================================

WHAT IS RUNNING NOW
  A "notes" MCP server, Streamable HTTP transport, protocol revision 2025-06-18.

    service    : mcp-lab.service          (runs as ${LAB_USER}, unprivileged)
    endpoint   : http://127.0.0.1:${LAB_PORT}/mcp
    metadata   : http://127.0.0.1:${LAB_PORT}/.well-known/oauth-protected-resource
    code       : ${LAB_DIR}/server.py                  <- you may edit this
    unit       : ${UNIT_PATH}     <- you may edit this
    workspace  : ${LAB_DIR}/workspace                  <- the ONLY data it may serve
    canary     : ${LAB_DIR}/secrets/customer-tokens.txt  (outside the workspace)
    token tool : python3 ${LAB_DIR}/mint-token.py [audience] [ttl]
    verifier   : bash ${LAB_DIR}/verify.sh

THE FOUR TRUST BOUNDARIES THIS TOPIC IS ABOUT
  1. Network / browser  ->  server. Any local HTTP MCP server is reachable by any
     page the user has open. The transport spec requires validating Origin and
     binding to loopback precisely because of DNS rebinding.
  2. Client identity    ->  server. An MCP server is an OAuth *resource server*.
     It must accept only tokens minted FOR IT (audience), still valid (exp), from
     the issuer it trusts — and must tell an unauthenticated caller where to get
     one, via a 401 with WWW-Authenticate resource_metadata (RFC 9728).
  3. Tool arguments     ->  host filesystem. Tool input is attacker-controlled
     data, not a parameter. The server, not the model and not the client, is the
     only component that can enforce the workspace root.
  4. Server output      ->  host/model. What the server returns crosses back into
     the model's context; leaking a secret through a tool result is a boundary
     failure even when nothing "crashed".

SYMPTOM YOU WILL OBSERVE
  Run the verifier now:

      sudo bash ${LAB_DIR}/verify.sh

  It fails 5 of 7 checks. Concretely:
    * ss shows the server listening on 0.0.0.0:${LAB_PORT}, not on loopback.
    * A POST carrying "Origin: http://evil.example" is answered with 200 and the
      full tool list — any web page can drive this server.
    * A token whose "aud" is https://files.other.lab/mcp is accepted; so is an
      expired one. The server trusts the signature and nothing else.
    * An anonymous request gets a bare 401 with no WWW-Authenticate challenge, so
      a compliant MCP client cannot discover how to authenticate.
    * tools/call read_note with path "../secrets/customer-tokens.txt" returns the
      canary ${CANARY}. The workspace root is a
      suggestion, not a boundary.
  Nothing logs an error. Every one of those requests is a clean 200.

YOUR OBJECTIVE
  Make this print 7/7 PASS:

      sudo bash ${LAB_DIR}/verify.sh

  Constraints that make it a real fix rather than a shutdown:
    * Check 7 must keep passing: an authorised tools/call for "welcome.md" must
      still return the note.
    * A non-browser MCP client sends NO Origin header. That case must keep
      working; only a foreign Origin may be refused.
    * Do not delete the canary file, do not stop the service, do not change
      verify.sh or mint-token.py.

USEFUL WHILE YOU WORK
    journalctl -u mcp-lab -f
    ss -ltnp | grep ${LAB_PORT}
    systemctl restart mcp-lab            # after every edit to server.py
    systemctl daemon-reload              # after every edit to the unit
    TOKEN=\$(python3 ${LAB_DIR}/mint-token.py)
    curl -i -X POST http://127.0.0.1:${LAB_PORT}/mcp \\
      -H "Authorization: Bearer \$TOKEN" -H 'Content-Type: application/json' \\
      -H 'Accept: application/json, text/event-stream' \\
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

  Start over at any time with:  sudo $0 --reset
  Remove the lab with:          sudo $0 --cleanup

 The worked solution is at the end of this script, commented out. Try first.
================================================================================

EOF
}

do_break() {
    require_root
    preflight
    confirm
    create_user
    write_tree
    write_token_minter
    write_broken_server
    write_verifier
    write_unit
    apply_permissions
    start_service
    log "lab deployed (deliberately broken)"
    briefing
}

do_reset() {
    require_root
    [ -f "$MARKER" ] || die "lab not installed; run: $0 --break"
    write_broken_server
    write_verifier
    write_unit
    apply_permissions
    start_service
    log "broken server re-deployed; run: sudo bash ${LAB_DIR}/verify.sh"
}

do_verify() {
    require_root
    [ -x "$LAB_DIR/verify.sh" ] || die "lab not installed; run: $0 --break"
    bash "$LAB_DIR/verify.sh"
}

do_cleanup() {
    require_root
    systemctl disable --now mcp-lab.service >/dev/null 2>&1 || true
    rm -f "$UNIT_PATH"
    systemctl daemon-reload
    if [ -f "$MARKER" ]; then
        rm -rf "$LAB_DIR"
        log "removed ${LAB_DIR}"
    else
        log "skipping ${LAB_DIR}: lab marker not found, nothing removed"
    fi
    userdel "$LAB_USER" >/dev/null 2>&1 || true
    log "lab removed"
}

main() {
    case "${1:---break}" in
        --break)   do_break ;;
        --reset)   do_reset ;;
        --verify)  do_verify ;;
        --cleanup) do_cleanup ;;
        --help|-h) usage ;;
        *)         usage; exit 2 ;;
    esac
}

main "$@"
exit 0
