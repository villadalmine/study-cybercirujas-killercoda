#!/usr/bin/env bash
#
# =============================================================================
#  MCPA - Model Context Protocol Associate
#  Topic 3.2 - Error Handling            (exam weight: 6.5 | exam rev 2026-07-28)
#
#  BREAK & FIX LAB - "the server that dies instead of reporting"
# =============================================================================
#
#  WHAT THIS SCRIPT DOES
#    It installs a small, self-contained MCP server (stdio transport, JSON-RPC
#    2.0, no third-party dependencies) plus a conformance probe that drives it
#    like a real MCP client would. The server is delivered ALREADY BROKEN: it
#    carries ten seeded defects, every one of them in the error-handling path.
#    Your job is to make the probe go green by editing server.py only.
#
#  WHY THIS TOPIC IS WORTH 6.5 POINTS
#    MCP has two error channels and confusing them is the single most common
#    production failure in MCP servers:
#
#      1) PROTOCOL ERRORS -> JSON-RPC "error" object. For faults the *client*
#         (the host application) must handle: unknown method, unknown tool,
#         malformed JSON, arguments that violate the tool's inputSchema.
#         The model never sees these; they are plumbing failures.
#
#      2) TOOL EXECUTION ERRORS -> a normal JSON-RPC "result" whose payload has
#         "isError": true and a human-readable content block. For faults the
#         *model* must handle: file not found, division by zero, HTTP 503 from
#         an upstream API. The model reads the text and can retry, apologise or
#         pick another tool. Reporting these as protocol errors is how you get
#         an agent that gives up silently, because the error never reaches it.
#
#    Plus the transport rule that decides whether anything works at all: on
#    stdio, the server's stdout belongs to the protocol. One stray print() and
#    the whole session is garbage.
#
#  SAFETY
#    Everything lives under one directory (default ~/mcpa-lab-error-handling).
#    No root, no package installs, no systemd units, no network, no writes
#    outside the lab directory. The processes it starts are short-lived local
#    python3 children. Still: run it on a DISPOSABLE lab VM, as the exam
#    objectives intend. "clean" removes the lab directory and nothing else.
#
#  USAGE
#    ./mcpa-3.2-error-handling.sh deploy [--yes]   install the broken server
#    ./mcpa-3.2-error-handling.sh verify           grade your fix
#    ./mcpa-3.2-error-handling.sh status           show what is installed
#    ./mcpa-3.2-error-handling.sh clean [--yes]    remove the lab directory
#
#  SOURCES
#    https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
#    https://modelcontextprotocol.io/specification/2025-06-18/basic
#    https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
#    https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
#    https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#    https://www.jsonrpc.org/specification
#
#  THE STEP-BY-STEP SOLUTION IS AT THE BOTTOM OF THIS FILE, COMMENTED OUT.
#  Do not scroll there until the probe has beaten you at least twice.
# =============================================================================

set -Eeuo pipefail

LAB_DIR="${MCPA_LAB_DIR:-$HOME/mcpa-lab-error-handling}"
MARKER=".mcpa-lab"
ASSUME_YES=0

trap 'echo "ERROR: ${BASH_SOURCE[0]}:${LINENO}: command failed" >&2' ERR

log()  { printf '[mcpa-lab] %s\n' "$*"; }
die()  { printf '[mcpa-lab] FATAL: %s\n' "$*" >&2; exit 1; }
rule() { printf '%s\n' "---------------------------------------------------------------------------"; }

usage() {
    sed -n '2,60p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
    exit 0
}

# --- guard rails -------------------------------------------------------------
sanity_checks() {
    command -v python3 >/dev/null 2>&1 || die "python3 is required and was not found in PATH"
    python3 - <<'PY' || die "python3 >= 3.8 is required"
import sys
sys.exit(0 if sys.version_info >= (3, 8) else 1)
PY

    case "$LAB_DIR" in
        "" | "/" | "$HOME" | "$HOME/") die "refusing to use '$LAB_DIR' as the lab directory" ;;
        /*) : ;;
        *)  die "MCPA_LAB_DIR must be an absolute path (got '$LAB_DIR')" ;;
    esac

    if [ -e "$LAB_DIR" ] && [ ! -f "$LAB_DIR/$MARKER" ]; then
        die "'$LAB_DIR' exists and was not created by this lab; refusing to touch it"
    fi
    if [ -e "$LAB_DIR/.git" ]; then
        die "'$LAB_DIR' looks like a git working tree; refusing to touch it"
    fi
}

confirm() {
    local question="$1"
    [ "$ASSUME_YES" = "1" ] && return 0
    if [ ! -t 0 ]; then
        die "non-interactive session: re-run with --yes if this really is a disposable lab VM"
    fi
    printf '%s [type: yes] ' "$question"
    local answer=""
    read -r answer || answer=""
    [ "$answer" = "yes" ] || die "aborted by the operator"
}

# --- lab content -------------------------------------------------------------
write_server() {
    cat > "$LAB_DIR/server.py" <<'SERVER_PY'
#!/usr/bin/env python3
"""mcpa-lab - a minimal MCP server on the stdio transport.

Wire format: JSON-RPC 2.0, one message per line, MCP revision 2025-06-18.
Tools: divide, read_note.

  >>> THIS FILE IS THE LAB SUBJECT. ITS ERROR HANDLING IS WRONG ON PURPOSE. <<<

Ten defects are hiding in here and every one of them is an error-handling
defect. Fix them until `python3 probe.py` reports every check as PASS.
You may rewrite anything in this file; do not touch probe.py.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
NOTES_DIR = os.path.join(HERE, "notes")
PROTOCOL_VERSION = "2025-06-18"
SERVER_INFO = {"name": "mcpa-error-lab", "version": "1.0.0"}

TOOLS = [
    {
        "name": "divide",
        "title": "Divide two numbers",
        "description": "Return a divided by b.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "a": {"type": "number", "description": "Dividend."},
                "b": {"type": "number", "description": "Divisor. Must not be zero."},
            },
            "required": ["a", "b"],
            "additionalProperties": False,
        },
    },
    {
        "name": "read_note",
        "title": "Read a lab note",
        "description": "Read <name>.txt from the lab notes directory.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Note name without extension and without path separators.",
                }
            },
            "required": ["name"],
            "additionalProperties": False,
        },
    },
]


# --------------------------------------------------------------------------
# wire helpers
# --------------------------------------------------------------------------
def send(message):
    """Write exactly one JSON-RPC message, newline terminated, to stdout."""
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def send_result(req_id, payload):
    send({"jsonrpc": "2.0", "id": req_id, "result": payload})


def send_error(req_id, code, message, data=None):
    err = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    send({"jsonrpc": "2.0", "id": req_id, "error": err})


def send_tool_text(req_id, text, is_error=False):
    """A tools/call result: content blocks plus the isError flag."""
    send_result(
        req_id,
        {"content": [{"type": "text", "text": text}], "isError": is_error},
    )


# --------------------------------------------------------------------------
# tools
# --------------------------------------------------------------------------
def tool_divide(req_id, args):
    a = args.get("a")
    b = args.get("b")

    if a is None or b is None:
        send(
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {"content": [{"type": "text", "text": "missing argument"}]},
                "error": {"code": -32603, "message": "missing argument"},
            }
        )
        return

    value = float(a) / float(b)
    send_tool_text(req_id, "%s / %s = %s" % (a, b, value))


def tool_read_note(req_id, args):
    name = args.get("name")
    path = os.path.join(NOTES_DIR, "%s.txt" % name)

    try:
        with open(path, "r", encoding="utf-8") as handle:
            body = handle.read()
    except OSError as exc:
        send_error(req_id, -32603, "read_note failed: %s" % exc)
        return

    send_tool_text(req_id, body)


def handle_tools_call(req_id, params):
    name = params.get("name")
    args = params.get("arguments") or {}

    print("[debug] tools/call name=%s args=%s" % (name, args))

    if name == "divide":
        tool_divide(req_id, args)
    elif name == "read_note":
        tool_read_note(req_id, args)
    else:
        send_tool_text(req_id, "unknown tool: %s" % name)


# --------------------------------------------------------------------------
# dispatch
# --------------------------------------------------------------------------
def dispatch(message):
    method = message.get("method")
    req_id = message.get("id")
    params = message.get("params") or {}

    if method == "initialize":
        send_result(
            req_id,
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": SERVER_INFO,
            },
        )
    elif method == "notifications/initialized":
        send({"jsonrpc": "2.0", "id": None, "result": {"acknowledged": True}})
    elif method == "ping":
        send_result(req_id, {})
    elif method == "tools/list":
        send_result(req_id, {"tools": TOOLS})
    elif method == "tools/call":
        handle_tools_call(req_id, params)
    else:
        send_error(req_id, -32603, "Internal error while handling %s" % method)


def main():
    print("[mcpa-lab] server up, notes directory is %s" % NOTES_DIR)

    while True:
        line = sys.stdin.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            continue

        message = json.loads(line)
        dispatch(message)


if __name__ == "__main__":
    main()
SERVER_PY
    chmod +x "$LAB_DIR/server.py"
}

write_probe() {
    cat > "$LAB_DIR/probe.py" <<'PROBE_PY'
#!/usr/bin/env python3
"""Conformance probe for MCPA topic 3.2 - Error Handling.

Spawns ./server.py over stdio once per check, drives a JSON-RPC 2.0 / MCP
conversation, and grades what comes back. Each check states what the spec
expects and what your server actually did. It never tells you where the bug is.

  DO NOT EDIT THIS FILE. The exam is server.py.
"""

import json
import os
import queue
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "server.py")
PROTOCOL_VERSION = "2025-06-18"
TIMEOUT = 4.0

INIT_REQUEST = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "protocolVersion": PROTOCOL_VERSION,
        "capabilities": {},
        "clientInfo": {"name": "mcpa-probe", "version": "1.0.0"},
    },
}
INITIALIZED_NOTIFICATION = {"jsonrpc": "2.0", "method": "notifications/initialized"}


def remaining(deadline):
    return max(0.05, deadline - time.time())


def short(value, limit=110):
    text = value if isinstance(value, str) else json.dumps(value, sort_keys=True)
    text = text.replace("\n", "\\n")
    return text if len(text) <= limit else text[: limit - 3] + "..."


class Session(object):
    """One server process plus non-blocking readers for stdout and stderr."""

    def __init__(self):
        self.proc = subprocess.Popen(
            [sys.executable, "-u", SERVER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.out = queue.Queue()
        self.err = []
        threading.Thread(target=self._pump_stdout, daemon=True).start()
        threading.Thread(target=self._pump_stderr, daemon=True).start()

    def _pump_stdout(self):
        for line in iter(self.proc.stdout.readline, ""):
            self.out.put(line.rstrip("\n"))
        self.out.put(None)

    def _pump_stderr(self):
        for line in iter(self.proc.stderr.readline, ""):
            self.err.append(line.rstrip("\n"))

    def send_raw(self, text):
        try:
            self.proc.stdin.write(text + "\n")
            self.proc.stdin.flush()
        except (BrokenPipeError, ValueError, OSError):
            pass

    def send(self, obj):
        self.send_raw(json.dumps(obj))

    def next_line(self, timeout=TIMEOUT):
        """Raw stdout line, None on EOF, False on timeout."""
        try:
            return self.out.get(timeout=timeout)
        except queue.Empty:
            return False

    def next_message(self, timeout=TIMEOUT):
        """('json', obj) | ('garbage', line) | ('eof', None) | ('timeout', None)"""
        line = self.next_line(timeout)
        if line is False:
            return ("timeout", None)
        if line is None:
            return ("eof", None)
        try:
            return ("json", json.loads(line))
        except ValueError:
            return ("garbage", line)

    def response_for(self, want_id, timeout=TIMEOUT):
        """Drain stdout until the response carrying want_id arrives."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            kind, payload = self.next_message(remaining(deadline))
            if kind == "json":
                if isinstance(payload, dict) and payload.get("id") == want_id:
                    return payload
                continue
            if kind == "garbage":
                continue
            return None
        return None

    def alive(self):
        return self.proc.poll() is None

    def crash_note(self):
        rc = self.proc.poll()
        tail = self.err[-1] if self.err else "no output on stderr"
        return "the server process exited (rc=%s); last stderr line: %s" % (rc, short(tail))

    def handshake(self, notify=True):
        self.send(INIT_REQUEST)
        response = self.response_for(1)
        if notify:
            self.send(INITIALIZED_NOTIFICATION)
        return response

    def close(self):
        for closer in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
            try:
                closer.close()
            except Exception:
                pass
        try:
            self.proc.terminate()
            self.proc.wait(timeout=2)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass


CHECKS = []


def check(cid, title):
    def decorate(fn):
        CHECKS.append((cid, title, fn))
        return fn

    return decorate


def call_tool(sess, req_id, name, arguments):
    sess.send(
        {
            "jsonrpc": "2.0",
            "id": req_id,
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        }
    )
    return sess.response_for(req_id)


def tool_text(response):
    blocks = (response.get("result") or {}).get("content") or []
    return " ".join(b.get("text", "") for b in blocks if isinstance(b, dict))


@check("01", "stdout carries protocol messages and nothing else")
def c01():
    sess = Session()
    try:
        garbage = []
        sess.send(INIT_REQUEST)
        deadline = time.time() + TIMEOUT
        seen_init = False
        while time.time() < deadline and not seen_init:
            kind, payload = sess.next_message(remaining(deadline))
            if kind == "json":
                seen_init = isinstance(payload, dict) and payload.get("id") == 1
            elif kind == "garbage":
                garbage.append(payload)
            else:
                break

        sess.send(INITIALIZED_NOTIFICATION)
        sess.send(
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {"name": "divide", "arguments": {"a": 6, "b": 3}},
            }
        )
        deadline = time.time() + TIMEOUT
        seen_call = False
        while time.time() < deadline and not seen_call:
            kind, payload = sess.next_message(remaining(deadline))
            if kind == "json":
                seen_call = isinstance(payload, dict) and payload.get("id") == 2
            elif kind == "garbage":
                garbage.append(payload)
            else:
                break

        if garbage:
            return (
                False,
                "every line written to stdout parses as one JSON-RPC message (logs go to stderr)",
                "stdout line that is not a protocol message: %s" % short(garbage[0]),
            )
        if not (seen_init and seen_call):
            return (False, "initialize and tools/call both answered", sess.crash_note())
        return (True, "", "")
    finally:
        sess.close()


@check("02", "initialize returns protocolVersion, capabilities and serverInfo")
def c02():
    sess = Session()
    try:
        response = sess.handshake(notify=False)
        if response is None:
            return (False, "a result for the initialize request", sess.crash_note())
        if "error" in response:
            return (False, "a result", "an error object: %s" % short(response["error"]))
        result = response.get("result") or {}
        missing = [k for k in ("protocolVersion", "capabilities", "serverInfo") if k not in result]
        if missing:
            return (False, "result.protocolVersion / capabilities / serverInfo", "missing: %s" % missing)
        return (True, "", "")
    finally:
        sess.close()


@check("03", "the happy path still works (tools/list, divide, read_note)")
def c03():
    sess = Session()
    try:
        if sess.handshake() is None:
            return (False, "a completed initialize handshake", sess.crash_note())

        sess.send({"jsonrpc": "2.0", "id": 10, "method": "tools/list"})
        listing = sess.response_for(10)
        if listing is None:
            return (False, "a tools/list result", sess.crash_note())
        names = sorted(t.get("name") for t in (listing.get("result") or {}).get("tools", []))
        if names != ["divide", "read_note"]:
            return (False, "tools named divide and read_note", "tools/list returned %s" % names)

        ok = call_tool(sess, 11, "divide", {"a": 6, "b": 3})
        if ok is None or "result" not in ok or (ok["result"].get("isError") is True):
            return (False, "divide(6,3) succeeds", short(ok) if ok else sess.crash_note())
        if "2" not in tool_text(ok):
            return (False, "divide(6,3) mentions 2 in its content", short(tool_text(ok)))

        note = call_tool(sess, 12, "read_note", {"name": "welcome"})
        if note is None or "result" not in note or (note["result"].get("isError") is True):
            return (False, "read_note(welcome) succeeds", short(note) if note else sess.crash_note())
        if "MCPA" not in tool_text(note):
            return (False, "the welcome note is returned verbatim", short(tool_text(note)))
        return (True, "", "")
    finally:
        sess.close()


@check("04", "a notification is never answered")
def c04():
    sess = Session()
    try:
        if sess.handshake(notify=False) is None:
            return (False, "a completed initialize handshake", sess.crash_note())
        sess.send(INITIALIZED_NOTIFICATION)

        deadline = time.time() + 1.5
        while time.time() < deadline:
            kind, payload = sess.next_message(remaining(deadline))
            if kind == "json":
                return (
                    False,
                    "silence: a JSON-RPC notification carries no id and MUST NOT get a response",
                    "the server replied with %s" % short(payload),
                )
            if kind == "garbage":
                continue
            break
        if not sess.alive():
            return (False, "the server stays up after a notification", sess.crash_note())
        return (True, "", "")
    finally:
        sess.close()


@check("05", "an unknown method answers -32601 Method not found")
def c05():
    sess = Session()
    try:
        if sess.handshake() is None:
            return (False, "a completed initialize handshake", sess.crash_note())
        sess.send({"jsonrpc": "2.0", "id": 20, "method": "resources/list"})
        response = sess.response_for(20)
        if response is None:
            return (False, "an error response for an unimplemented method", sess.crash_note())
        if "result" in response:
            return (False, "an error object, not a result", short(response))
        code = (response.get("error") or {}).get("code")
        if code != -32601:
            return (False, "error.code == -32601 (Method not found)", "error.code == %s" % code)
        return (True, "", "")
    finally:
        sess.close()


@check("06", "malformed JSON answers -32700 and does not kill the session")
def c06():
    sess = Session()
    try:
        if sess.handshake() is None:
            return (False, "a completed initialize handshake", sess.crash_note())

        sess.send_raw('{"jsonrpc": "2.0", "id": 30, "method": "tools/list"')  # truncated on purpose

        parse_error = None
        deadline = time.time() + 2.0
        while time.time() < deadline:
            kind, payload = sess.next_message(remaining(deadline))
            if kind == "json" and isinstance(payload, dict) and "error" in payload:
                parse_error = payload
                break
            if kind in ("eof", "timeout"):
                break

        if not sess.alive():
            return (
                False,
                "one unparseable line is answered with -32700 and the session continues",
                sess.crash_note(),
            )
        if parse_error is None:
            return (False, "a -32700 Parse error response", "the server stayed silent")
        code = (parse_error.get("error") or {}).get("code")
        if code != -32700:
            return (False, "error.code == -32700 (Parse error)", "error.code == %s" % code)

        sess.send({"jsonrpc": "2.0", "id": 31, "method": "tools/list"})
        if sess.response_for(31) is None:
            return (False, "the next well-formed request is still served", sess.crash_note())
        return (True, "", "")
    finally:
        sess.close()


@check("07", "arguments that violate inputSchema answer -32602, and only that")
def c07():
    sess = Session()
    try:
        if sess.handshake() is None:
            return (False, "a completed initialize handshake", sess.crash_note())
        response = call_tool(sess, 40, "divide", {"a": 10})
        if response is None:
            return (False, "an error response for a missing required argument", sess.crash_note())
        if "result" in response and "error" in response:
            return (
                False,
                "exactly one of result / error in a JSON-RPC response",
                "the response carried both: %s" % short(response),
            )
        if "error" not in response:
            return (False, "an error object (required argument 'b' is absent)", short(response))
        code = (response.get("error") or {}).get("code")
        if code != -32602:
            return (False, "error.code == -32602 (Invalid params)", "error.code == %s" % code)
        return (True, "", "")
    finally:
        sess.close()


@check("08", "division by zero is a tool execution error, not a dead server")
def c08():
    sess = Session()
    try:
        if sess.handshake() is None:
            return (False, "a completed initialize handshake", sess.crash_note())
        response = call_tool(sess, 50, "divide", {"a": 1, "b": 0})
        if response is None:
            return (
                False,
                "result.isError == true, so the model can read the failure and recover",
                sess.crash_note(),
            )
        if "error" in response:
            return (
                False,
                "a result with isError == true (the model must see this failure)",
                "a protocol error instead: %s" % short(response["error"]),
            )
        result = response.get("result") or {}
        if result.get("isError") is not True:
            return (False, "result.isError == true", "result.isError == %s" % result.get("isError"))
        if not tool_text(response).strip():
            return (False, "a text content block explaining the failure", "empty content")

        survivor = call_tool(sess, 51, "divide", {"a": 8, "b": 2})
        if survivor is None or "result" not in survivor:
            return (False, "the session survives a failed tool call", sess.crash_note())
        return (True, "", "")
    finally:
        sess.close()


@check("09", "a missing note is a tool execution error, not a protocol error")
def c09():
    sess = Session()
    try:
        if sess.handshake() is None:
            return (False, "a completed initialize handshake", sess.crash_note())
        response = call_tool(sess, 60, "read_note", {"name": "this-note-does-not-exist"})
        if response is None:
            return (False, "result.isError == true for an unreadable note", sess.crash_note())
        if "error" in response:
            return (
                False,
                "a result with isError == true (upstream/IO failures belong to the model)",
                "a protocol error instead: %s" % short(response["error"]),
            )
        if (response.get("result") or {}).get("isError") is not True:
            return (False, "result.isError == true", short(response))
        return (True, "", "")
    finally:
        sess.close()


@check("10", "a path outside the notes directory is refused, never served")
def c10():
    sess = Session()
    try:
        if sess.handshake() is None:
            return (False, "a completed initialize handshake", sess.crash_note())
        response = call_tool(sess, 70, "read_note", {"name": "../../../../etc/hostname"})
        if response is None:
            return (False, "a refusal for a traversal attempt", sess.crash_note())
        if "error" in response:
            return (True, "", "")
        result = response.get("result") or {}
        if result.get("isError") is True:
            return (True, "", "")
        return (
            False,
            "isError == true, or -32602: the note name is not allowed to escape notes/",
            "the server returned file content as a successful result",
        )
    finally:
        sess.close()


@check("11", "an unknown tool name is a protocol error")
def c11():
    sess = Session()
    try:
        if sess.handshake() is None:
            return (False, "a completed initialize handshake", sess.crash_note())
        response = call_tool(sess, 80, "drop_production_database", {})
        if response is None:
            return (False, "an error response for an unknown tool", sess.crash_note())
        if "error" not in response:
            return (
                False,
                "a JSON-RPC error (-32602 or -32601): an unknown tool is a client bug, not a tool failure",
                "a successful result instead: %s" % short(response),
            )
        code = (response.get("error") or {}).get("code")
        if code not in (-32601, -32602):
            return (False, "error.code in (-32602, -32601)", "error.code == %s" % code)
        return (True, "", "")
    finally:
        sess.close()


def main():
    if not os.path.exists(SERVER):
        print("probe: %s is missing" % SERVER)
        return 2

    print("")
    print("MCPA 3.2 - Error Handling :: conformance probe")
    print("server under test: %s" % SERVER)
    print("-" * 75)

    passed = 0
    for cid, title, fn in CHECKS:
        try:
            ok, expected, got = fn()
        except Exception as exc:  # the probe must never die with the server
            ok, expected, got = False, "the probe completes the exchange", "probe exception: %r" % exc
        if ok:
            passed += 1
            print("[ PASS ] %s  %s" % (cid, title))
        else:
            print("[ FAIL ] %s  %s" % (cid, title))
            print("         expected: %s" % expected)
            print("         got:      %s" % got)

    total = len(CHECKS)
    print("-" * 75)
    print(" %d checks, %d passed, %d failed" % (total, passed, total - passed))
    if passed == total:
        print(" Topic 3.2 objective met: both error channels behave as the spec requires.")
    else:
        print(" Keep going. Read the 'expected' lines as the spec, the 'got' lines as the symptom.")
    print("")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
PROBE_PY
    chmod +x "$LAB_DIR/probe.py"
}

write_notes() {
    mkdir -p "$LAB_DIR/notes"
    cat > "$LAB_DIR/notes/welcome.txt" <<'NOTE_TXT'
MCPA topic 3.2 - Error Handling
The read_note tool serves files from this directory and nothing else.
NOTE_TXT
}

write_readme() {
    cat > "$LAB_DIR/README.txt" <<EOF
MCPA 3.2 - Error Handling :: break & fix
========================================

Lab directory : ${LAB_DIR}
Edit          : server.py
Never edit    : probe.py
Grade it      : python3 ${LAB_DIR}/probe.py

THE SYMPTOM
  Point any MCP client at server.py and the session is unusable from the first
  byte: the client reports "unexpected token" or "server disconnected" before
  the handshake even completes. Get past that and it gets worse - some tool
  calls do not just fail, they take the whole server process down with them,
  and the failures that do come back arrive on the wrong channel: the model
  never sees them, or sees a "success" that says "unknown tool".

WHAT YOU MUST ACHIEVE
  All checks PASS. Concretely, the server must:
    - write protocol messages and nothing else to stdout (logs to stderr);
    - answer -32700 to an unparseable line and keep serving;
    - answer -32601 to an unknown method;
    - answer -32602 to arguments that violate the tool inputSchema, and to an
      unknown tool name, with exactly one of result/error per response;
    - never answer a notification;
    - report tool failures (division by zero, missing file, refused path) as a
      result with isError: true and a text block the model can act on;
    - survive every one of the above.

THE RULE BEHIND THE WHOLE TOPIC
  Protocol errors are for the client. Tool execution errors are for the model.
  Choosing the wrong one is not a style question: a protocol error is invisible
  to the LLM, so an agent that hits one stops instead of retrying.

Ten defects were seeded. Eleven checks grade them.
Reference: https://modelcontextprotocol.io/specification/2025-06-18/server/tools
EOF
}

# --- commands ----------------------------------------------------------------
do_deploy() {
    sanity_checks
    confirm "Deploy the broken MCP server under $LAB_DIR on this DISPOSABLE lab VM?"

    mkdir -p "$LAB_DIR"
    : > "$LAB_DIR/$MARKER"
    write_server
    write_probe
    write_notes
    write_readme

    rule
    log "lab deployed under $LAB_DIR"
    rule
    cat <<EOF

  BREAK APPLIED -- MCPA 3.2, Error Handling

  Ten error-handling defects are now live in:

      $LAB_DIR/server.py

  SYMPTOM YOU WILL SEE
    The MCP session is broken before it starts: the client cannot parse the
    very first thing the server writes. After that, individual tool calls kill
    the server process instead of returning a failure, and the failures that
    do come back use the wrong channel or the wrong JSON-RPC error code.

  YOUR GOAL
    Edit server.py only, until every check reports PASS:

      python3 $LAB_DIR/probe.py

    or

      $0 verify

  HOW TO WORK IT
    1. Run the probe first and read it top to bottom. Check 01 is the transport
       rule; nothing else can be trusted until it is green.
    2. Fix one defect, re-run the probe, repeat. Do not batch fixes.
    3. When a check says the server "exited (rc=1)", the stderr tail it prints
       is the Python traceback - that is your stack, read it.
    4. For every failure you fix, answer out loud: is this the client's problem
       (JSON-RPC error) or the model's problem (isError: true)?

  Reference for the two error channels:
    https://modelcontextprotocol.io/specification/2025-06-18/server/tools

EOF
}

do_verify() {
    [ -f "$LAB_DIR/probe.py" ] || die "no lab found under $LAB_DIR; run '$0 deploy' first"
    set +e
    python3 "$LAB_DIR/probe.py"
    local rc=$?
    set -e
    return "$rc"
}

do_status() {
    if [ ! -f "$LAB_DIR/$MARKER" ]; then
        log "no lab installed under $LAB_DIR"
        return 0
    fi
    log "lab directory : $LAB_DIR"
    log "server        : $(wc -l < "$LAB_DIR/server.py") lines, modified $(date -r "$LAB_DIR/server.py" '+%Y-%m-%d %H:%M:%S')"
    log "probe         : $LAB_DIR/probe.py (do not edit)"
    log "notes         : $(ls -1 "$LAB_DIR/notes" | tr '\n' ' ')"
    log "grade it with : $0 verify"
}

do_clean() {
    [ -f "$LAB_DIR/$MARKER" ] || die "no lab marker in $LAB_DIR; refusing to delete anything"
    confirm "Delete $LAB_DIR and everything in it?"
    rm -rf -- "$LAB_DIR"
    log "removed $LAB_DIR"
}

# --- argument parsing --------------------------------------------------------
COMMAND="deploy"
for arg in "$@"; do
    case "$arg" in
        deploy|break|verify|check|status|clean|help|-h|--help) COMMAND="$arg" ;;
        --yes|-y) ASSUME_YES=1 ;;
        *) die "unknown argument: $arg (try '$0 help')" ;;
    esac
done

case "$COMMAND" in
    deploy|break) do_deploy ;;
    verify|check) do_verify ;;
    status)       do_status ;;
    clean)        do_clean ;;
    help|-h|--help) usage ;;
esac

# =============================================================================
# =============================================================================
#
