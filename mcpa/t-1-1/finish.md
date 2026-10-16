## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION - stop reading if you have not finished the lab

 STEP 0 - Reproduce, and read the failure in the right order
     cd ~/mcpa-lab-1.1
     ./mcpa-1.1-break-fix.sh verify

 Expected (broken state):

     [FAIL] 1. stdio framing        stdout carried a line that is not a JSON-RPC
                                    message: 'ready: reading newline-delimited ...'
     [FAIL] 2. protocol revision    not reached: the transport is unusable
     [FAIL] 3. advertised capab...  not reached
     [FAIL] 4. tools/list           not reached
     [FAIL] 5. tools/call round...  not reached
     [FAIL] 6. lifecycle gate       stdout carried a line that is not a JSON-RPC ...
     0/6 checks passed

 Diagnostic reflex for any stdio MCP server: the transport is the bottom of
 the stack. Never chase a capability bug while the framing is broken - you
 cannot see past it.


 STEP 1 - FAULT 3 (transport scope): stdout is the protocol bus
 Prove it by hand, exactly as a host would:

     printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"hand","version":"0"}}}' \
       | python3 server/mcp_echo_server.py

 Broken output (note the first line, which is not JSON):

     ready: reading newline-delimited JSON-RPC from stdin
     [server] initialize from {'name': 'hand', 'version': '0'}
     {"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "1.0", "capabilities": {}, "serverInfo": {...}}}

 The "[server] ..." line is fine: it is on stderr, which is merged into your
 terminal here but is a separate stream for the host. The bare "ready: ..."
 line is on stdout, and it destroys the framing.

 Fix - send the diagnostic to stderr, where the healthy code already sends
 everything else:

     sed -i 's/^    print("ready: reading newline-delimited JSON-RPC from stdin")$/    log("ready: reading newline-delimited JSON-RPC from stdin")/' \
       server/mcp_echo_server.py

 Verify that stdout is now clean (exactly one line, and it parses):

     printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"hand","version":"0"}}}' \
       | python3 server/mcp_echo_server.py 2>/dev/null | python3 -m json.tool

 Rule to memorise: on the stdio transport a server MUST NOT write anything to
 stdout that is not a newline-delimited JSON-RPC message, and messages MUST
 NOT contain embedded newlines. print() is the single most common way real
 MCP servers die. See:
 https://modelcontextprotocol.io/specification/2025-06-18/basic/transports

 Re-run ./mcpa-1.1-break-fix.sh verify - now checks 1 and 6 pass, and the two
 faults that were hidden behind the framing become visible.


 STEP 2 - FAULT 1 (protocol scope): the revision is a date, not a semver
 Now the grader can read the initialize result and says:

     [FAIL] 2. protocol revision    server offered '1.0'; MCP revisions are dates
                                    (YYYY-MM-DD) and this host supports:
                                    2025-06-18, 2025-03-26, 2024-11-05

 Version negotiation is inside MCP's scope: the client proposes a revision in
 initialize, the server answers with the revision it will actually use, and if
 the client cannot speak it the client MUST disconnect. "1.0" is not a
 revision any host knows, so a conformant host drops the session here - which
 looks, from the user's chair, exactly like "the server is broken".

     sed -i 's/^PROTOCOL_VERSION = "1.0"$/PROTOCOL_VERSION = "2025-06-18"/' \
       server/mcp_echo_server.py

 Confirm what is negotiated:

     printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"hand","version":"0"}}}' \
       | python3 server/mcp_echo_server.py 2>/dev/null \
       | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["protocolVersion"])'
     2025-06-18

 https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle


 STEP 3 - FAULT 2 (contract scope): capabilities are the contract
 The remaining failure is the subtle one, and the reason this lab belongs to
 "Purpose & Scope" rather than to a tools topic:

     [FAIL] 3. advertised capabilities  initialize advertised {}: with no "tools"
                                        capability a conformant host must never call
                                        tools/list or tools/call ...

 Nothing is wrong with the tool. tools/list still answers, tools/call still
 echoes - the grader proves it, and says so ("reached only because the grader
 ignores the contract"). A real host would never have asked. Capability
 negotiation is how MCP keeps host and server independently versioned: the
 server declares what it has, and the host restricts itself to that set.
 Working code that is not advertised does not exist as far as the model is
 concerned.

     sed -i 's/^CAPABILITIES = {}$/CAPABILITIES = {"tools": {"listChanged": False}}/' \
       server/mcp_echo_server.py

 ("listChanged": False means: I will never send notifications/tools/list_changed,
 so the host may cache my tool list for the session.)

 https://modelcontextprotocol.io/specification/2025-06-18/server/tools


 STEP 4 - Final verification
     ./mcpa-1.1-break-fix.sh verify

     MCP conformance probe -> server/mcp_echo_server.py
     [ OK ] 1. stdio framing           the first stdout line parsed as JSON-RPC 2.0
     [ OK ] 2. protocol revision       negotiated 2025-06-18
     [ OK ] 3. advertised capabilities initialize advertised: tools
     [ OK ] 4. tools/list              server exposes: echo
     [ OK ] 5. tools/call round trip   text content returned unchanged
     [ OK ] 6. lifecycle gate          pre-handshake request refused: server not
                                       initialized: 'tools/list' arrived before
                                       notifications/initialized
     6/6 checks passed


 STEP 5 - The answer the exam actually wants
 Each fault was one sentence about the boundary:

   transport      MCP owns the channel. On stdio that is stdout, exclusively,
                  newline-delimited. Your logging is out of scope and goes to
                  stderr (or to a file); on HTTP/SSE the equivalent rule is
                  that only protocol events go on the event stream.

   lifecycle      MCP owns version negotiation and session state: initialize,
                  then notifications/initialized, then and only then normal
                  operation. Your application does not invent its own
                  handshake or its own version scheme.

   capabilities   MCP owns the contract of what exists. A host may use only
                  what was advertised. This is what lets any client talk to
                  any server without prior knowledge of either - the actual
                  purpose of the protocol.

 And what MCP deliberately does NOT own, which is the other half of topic 1.1:
 it does not run inference, does not choose which tool to invoke, does not
 decide whether the caller is authorised for a business action, and does not
 define the agent loop. The host application owns all of those. A question
 that asks "which component decides to call the tool?" is answered by the
 host, never by MCP.

 Clean up the VM when done:
     ./mcpa-1.1-break-fix.sh clean
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/mcpa/1.1/lab)
