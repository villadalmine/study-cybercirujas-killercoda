## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION -- read only after you have tried it

 All four faults live in server.py. The client fails fast, so the order below
 is the order the symptoms appear. After each fix, re-run:

     ./mcpa-1.2-breakfix.sh check

 FAULT 1 -- transport: a banner on stdout
 Symptom:
     FAIL [transport] the server wrote a line to stdout that is not JSON:
     'inventory-mcp 1.0.0 listening on stdio'

 Diagnosis:
     In the stdio transport the child's stdout IS the protocol channel: one
     JSON-RPC message per line, nothing else. The client reads the first line
     expecting the initialize response and gets a human-readable banner, so
     json.loads fails before the session ever starts. This is the single most
     common bug in hand-written MCP servers, and a `print()` left in for
     debugging -- or an uncaught traceback printed to stdout by a framework --
     does it every time. The server is not "down"; it is unreadable.

     Find it mechanically:  grep -n 'print(' server.py   and check which
     calls lack file=sys.stderr.

 Fix, in main():
     -    print(f"{SERVER_NAME} {SERVER_VERSION} listening on stdio", flush=True)
     +    log(f"{SERVER_NAME} {SERVER_VERSION} listening on stdio")

     (log() already writes to sys.stderr. Any diagnostics -- startup banners,
     progress, tracebacks -- go to stderr, which the host collects as logs.
     Structured logging for the *model* has its own channel instead:
     notifications/message under the logging capability.)

 FAULT 2 -- lifecycle: an invented protocolVersion
 Symptom:
     FAIL [version negotiation] the server answered protocolVersion='1.0';
     this host speaks ['2025-11-25', '2025-06-18', '2025-03-26']

 Diagnosis:
     initialize is a negotiation, not a greeting. The client sends the newest
     revision it supports; the server answers with that same revision if it
     supports it, otherwise with another revision it does support, and the
     client then either continues on that revision or disconnects. MCP
     revisions are dates (YYYY-MM-DD), so "1.0" is not a revision at all --
     any conformant host disconnects. The server's own SUPPORTED_PROTOCOLS
     list was already correct; the handler simply stopped consulting it.

 Fix, in handle_initialize():
          requested = params.get("protocolVersion")
     -    negotiated = "1.0"
     +    negotiated = requested if requested in SUPPORTED_PROTOCOLS else SUPPORTED_PROTOCOLS[0]

     Note the fallback: answering with your own newest supported revision when
     you do not speak the client's is the correct behaviour -- it gives the
     client the chance to downgrade instead of guessing. (Over Streamable HTTP
     the same negotiated value then travels on every request in the
     MCP-Protocol-Version header; over stdio it is session state.)

 FAULT 3 -- message types: a notification that gets answered
 Symptom:
     FAIL [message types] the server answered a notification:
     '{"jsonrpc":"2.0","id":null,"result":{}}'

 Diagnosis:
     JSON-RPC 2.0 has exactly three message shapes, and MCP uses all three:
       * request      -- has method and id, MUST get exactly one response
       * response     -- has the id of its request and exactly one of
                         result or error
       * notification -- has method and NO id, MUST NOT be answered
     notifications/initialized is a notification: it tells the server the
     client finished initializing. Answering it puts one extra message into
     the stream, and from that moment every response the client reads is the
     previous one: it sends tools/list as id 2 and reads id=null, then the
     id 2 answer arrives when it is waiting for id 3. The session desyncs
     permanently. This is why the client checks the id rather than trusting
     arrival order -- and why it is worth testing with a server that emits
     progress notifications while a request is in flight.

 Fix, in dispatch():
          if "id" not in message:
              handle_notification(method, params)
     -        send({"jsonrpc": "2.0", "id": message.get("id"), "result": {}})
              return

     Note that `"id" not in message` is the right test, not `not
     message.get("id")`: id 0 and id "" are perfectly legal request ids.

 FAULT 4 -- capability negotiation: an undeclared primitive
 Symptom:
     FAIL [capabilities] the server did not declare the tools capability
     (declared: ['logging', 'prompts', 'resources'])

 Diagnosis:
     What a server can do is what it declares in the initialize result, once,
     for the whole session. The tools/list and tools/call handlers are still
     there and still work if you poke them by hand -- but a conformant host
     never calls them, because the server said it has no tools. The tools are
     invisible: no error, no crash, just a model that suddenly "has no tools".
     The sub-flags matter too: {"listChanged": true} promises you will send
     notifications/tools/list_changed when the set changes, and a client may
     cache the list on that promise. Declare only what you implement.

 Fix, in handle_initialize(), inside "capabilities":
          "capabilities": {
     +        "tools": {"listChanged": False},
              "resources": {"subscribe": False, "listChanged": False},
              "prompts": {"listChanged": False},
              "logging": {},
          },

 VERIFICATION
     ./mcpa-1.2-breakfix.sh check

     >> 1/6  lifecycle: initialize
        ok  negotiated protocol revision 2025-11-25
        ok  serverInfo inventory-mcp 1.0.0
     >> 2/6  lifecycle: notifications/initialized
        ok  notification accepted in silence (as it must be)
     >> 3/6  primitive: tools
        ok  tools/list -> stock_lookup
        ok  tools/call stock_lookup -> SKU-1001: 42 units on hand
     >> 4/6  primitive: resources
        ok  resources/read inventory://warehouse/eu-west/summary -> 1 block(s)
     >> 5/6  primitive: prompts
        ok  prompts/list -> restock_report
     >> 6/6  utility: ping
        ok  session alive

     PASS  the MCP session completed end to end.

 And by hand, with the protocol visible:
     MCP_LAB_TRACE=1 ./mcpa-1.2-breakfix.sh check

 WHAT TO CARRY INTO THE EXAM
 * Architecture: a host holds one client per server; one client speaks to
   exactly one server, over stdio (local child process) or Streamable HTTP
   (remote). Transport changes the plumbing, never the messages.
 * Wire format: JSON-RPC 2.0 -- requests (id), responses (same id, result XOR
   error), notifications (no id, never answered).
 * Lifecycle: initialize -> negotiated date-based revision + capabilities ->
   notifications/initialized -> operation. Nothing but initialize and ping
   belongs before that notification.
 * Capabilities are the contract: undeclared is unusable, even if implemented.
 * Server primitives: tools (model-controlled), resources (application-
   controlled, URI-addressed), prompts (user-controlled). Client primitives
   face the other way: sampling, roots, elicitation.
 * Two error channels, not one: JSON-RPC errors (-32700 parse, -32600 invalid
   request, -32601 method not found, -32602 invalid params) mean the protocol
   failed; a tool result with isError=true means the tool ran and failed, and
   that one is meant to reach the model.

 Sources:
   https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
   https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
   https://modelcontextprotocol.io/specification/2025-06-18/server/tools
   https://modelcontextprotocol.io/specification/2025-06-18/server/resources
   https://modelcontextprotocol.io/specification/2025-06-18/server/prompts
   https://www.jsonrpc.org/specification
   https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/mcpa/1.2/lab)
