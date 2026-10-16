## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION - step by step. Stop reading if you still want the exercise.

There are five defects, in three files. They are graded in the order the
host meets them, so fix them in that order.

STEP 0 - read the log before touching anything
  cat ~/mcp-portability-lab/logs/notes-mcp.stderr.log

  Empty on the first run: the process never started. That alone rules out
  every protocol-level hypothesis and points at the manifest.

DEFECT 1 - the manifest names paths that exist on one laptop only
           (.mcp.json: command, args, env)
  `command` pins an interpreter at /usr/local/lib/mcp-runtime-3.12/bin/...,
  `args` points into /home/builder, and `env` hardcodes both the note store
  and a PYTHONPATH. The host executes command+args as a plain child process:
  it does not search, guess or rewrite anything.

  The fix is not a better path - it is no path. The repository already
  ships bin/notes-mcp, a launcher that resolves its own location, so the
  manifest only has to name a command that PATH can resolve. Replace the
  whole entry with:

    {
      "mcpServers": {
        "notes": {
          "command": "notes-mcp",
          "args": []
        }
      }
    }

  Dropping MCP_NOTES_DIR is deliberate - see DEFECT 5. Then put the
  launcher on PATH the way a real install would:

    source ~/mcp-portability-lab/lab-env.sh

  This is why published servers are invoked as `npx -y @modelcontextprotocol/
  server-filesystem` or `uvx mcp-server-git`: the manifest carries a name the
  runtime resolves, never a location.

DEFECT 2 - two writes to stdout corrupt the wire
           (bin/notes-mcp and server/notes_server.py)
  Symptom: [FAIL] 2 initialize - "this line on stdout is not JSON-RPC:
  '[notes-mcp] launching ...'".

  On the stdio transport stdout IS the protocol connection: newline-
  delimited JSON-RPC, one message per line, nothing else, ever. Every log
  line goes to stderr, which the host captures for you.

  In bin/notes-mcp:
    -   echo "[notes-mcp] launching $SERVER"
    +   echo "[notes-mcp] launching $SERVER" >&2

  In server/notes_server.py, main():
    -   print("%s %s ready (notes: %s)" % (SERVER_NAME, SERVER_VERSION, data_dir()))
    +   log("%s %s ready (notes: %s)" % (SERVER_NAME, SERVER_VERSION, data_dir()))

  (`log()` already writes to sys.stderr. In Python, also beware of anything
  that prints on import, and of libraries that default to stdout logging.)

DEFECT 3 - the protocol version is hardcoded instead of negotiated
           (server/notes_server.py, handle(), "initialize")
  Symptom: [FAIL] 3 version negotiation - server answered '2024-05-01',
  a version this client - and every other one - has never heard of.

  The lifecycle rule: the client sends the version it prefers; if the server
  supports it, the server MUST echo that exact string back; otherwise it
  answers with a version it does support, and the client disconnects if it
  cannot speak it. SUPPORTED_PROTOCOLS is already declared at the top of the
  file and was simply never used. Replace the initialize branch with:

    if method == "initialize":
        wanted = (message.get("params") or {}).get("protocolVersion")
        agreed = wanted if wanted in SUPPORTED_PROTOCOLS else SUPPORTED_PROTOCOLS[0]
        result(request_id, {
            "protocolVersion": agreed,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        })

  That single block also fixes DEFECT 4.

DEFECT 4 - the server implements tools and declares resources
           (same initialize result)
  Symptom: [FAIL] 4 capability negotiation - declared capabilities: resources.

  A client MUST NOT use a capability the server did not declare, so a
  specification-conformant host never calls tools/list and the server simply
  appears empty - no error, no warning, nothing in any log. This is the
  single most common "your server works in your client and not in mine"
  report. Whatever you implement, declare it; whatever you declare,
  implement it.

DEFECT 5 - a debug print inside the tool, and a note store that moved
           (server/notes_server.py, notes_search())
  Symptom A: [FAIL] 6 tools/call - another non-JSON line on stdout. Same
  class as DEFECT 2, but it only fires once a tool is actually called, which
  is why it survives every smoke test and dies in front of a user.

    -   print("notes_search(%r): %d/%d note(s)" % (query, len(hits), len(notes)))
    +   log("notes_search(%r): %d/%d note(s)" % (query, len(hits), len(notes)))

  Symptom B: the call succeeds and answers "No note matches 'backup'", with
  "cannot list /home/builder/dev/mcp-notes/data" in the stderr log. If you
  kept MCP_NOTES_DIR in the manifest, remove it now: data_dir() already
  falls back to $XDG_DATA_HOME/notes-mcp, which resolves per user on every
  machine. A path baked into configuration is exactly as non-portable as one
  baked into code - the manifest just makes it look like a setting.

VERIFY
  source ~/mcp-portability-lab/lab-env.sh
  ~/mcp-portability-lab/bin/lab-verify

  Expected:
    [ OK ] no absolute paths: this manifest travels
    [ OK ] 1 spawn                   notes (pid ...)
    [ OK ] 2 initialize              clean JSON-RPC framing on stdout
    [ OK ] 3 version negotiation     agreed on 2025-06-18
    [ OK ] 4 capability negotiation  tools declared
    [ OK ] 5 tools/list              1 tool(s), schema valid
    [ OK ] 6 tools/call              notes_search returned 2 match line(s)
    LAB PASSED

WHAT TO CARRY INTO THE EXAM AND INTO PRODUCTION
  * Portability lives in the package, not in the configuration. If the
    manifest contains a path, you have shipped a machine, not a server.
  * stdout is the transport; stderr is the log. The host captures stderr
    precisely so you never need stdout.
  * Version and capabilities are negotiated per connection. Hardcode either
    one and you have written a server for exactly one client.
  * Declare what you implement. An undeclared capability is an invisible
    one, and invisible failures cost the most time.
  * Derive every filesystem location at runtime: XDG_DATA_HOME, the user's
    home, an explicit argument - in that order of preference.

  Sources:
    https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
    https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
    https://modelcontextprotocol.io/specification/2025-06-18/server/tools
    https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/mcpa/5.3/lab)
