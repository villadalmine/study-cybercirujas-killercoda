## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION - four contract violations, nine checks. Stop reading if you have
 not tried yet. Every path below is relative to the lab directory.

 DIAGNOSIS FIRST
 # 1. What does the server put on the wire when no client is talking to it?
 #      python3 server.py < /dev/null
 #    Output: "mcp-lab-server 1.5.0 ready" on STDOUT. That single line is
 #    already a fatal protocol violation: the stdio transport says stdout
 #    carries JSON-RPC messages, one per line, and nothing else.
 #
 # 2. What does a conformant client see?
 #      ./probe.sh
 #    Check 1 fails with a JSONDecodeError on that banner. Fail-fast means
 #    you will uncover the remaining faults one at a time.
 #
 # 3. Why did nobody notice? Read vendor_client.py: it skips every line that
 #    does not start with "{", ignores protocolVersion, reads the schema from
 #    inputSchema OR parameters, and falls back to result["output"]. Four
 #    private workarounds. That is the M x N world MCP exists to delete.

 FAULT A - stdout is not a log stream (checks 1 and 9)
 # grep -n 'print(' server.py   ->  two offenders.
 # Move both to stderr via the log() helper that is already in the file.
 # Do not simply delete them: check 9 requires the server to keep logging.
 #
 #   sed -i 's|^    print(SERVER_NAME + " " + SERVER_VERSION + " ready", flush=True)$|    log("listening on stdio")|' server.py
 #   sed -i 's|^        print("DEBUG method=" + str(msg.get("method")), flush=True)$|        log("method=" + str(msg.get("method")))|' server.py
 #
 # Rule to remember: in stdio transport the server MUST NOT write anything
 # to stdout that is not a valid MCP message, and messages MUST NOT contain
 # embedded newlines. Logging goes to stderr - or to the client through
 # notifications/message, once logging capability is negotiated.
 # https://modelcontextprotocol.io/specification/2025-06-18/basic/transports

 FAULT B - protocol version is a date, not a semver (check 3)
 # negotiate() was flattened to `return "1.0"`. Restore real negotiation:
 # the server echoes the client's version when it supports it, otherwise it
 # answers with a version it does support and lets the client decide.
 #
 #   python3 - <<'PY'
 #   import pathlib
 #   p = pathlib.Path("server.py"); s = p.read_text()
 #   s = s.replace(
 #       '    return "1.0"\n',
 #       '    if requested in SUPPORTED_PROTOCOL_VERSIONS:\n'
 #       '        return requested\n'
 #       '    return PREFERRED_PROTOCOL_VERSION\n')
 #   p.write_text(s)
 #   PY
 #
 # A client that receives an unsupported version MUST disconnect - that is
 # conformant behaviour, not a bug in the client.
 # https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle

 FAULT C - the tool descriptor (check 6)
 # Two edits inside the TOOLS list:
 #   a) the JSON Schema key is inputSchema, not parameters:
 #        sed -i 's|^        "parameters": {$|        "inputSchema": {|' server.py
 #   b) restore the description, which is what the model reads to decide
 #      whether the tool applies at all. Add back, above the schema:
 #        "description": "Convert a temperature between Celsius and Fahrenheit.",
 #
 #      python3 - <<'PY'
 #      import pathlib
 #      p = pathlib.Path("server.py"); s = p.read_text()
 #      s = s.replace('        "name": "convert_temperature",\n',
 #                    '        "name": "convert_temperature",\n'
 #                    '        "description": "Convert a temperature between Celsius and Fahrenheit.",\n')
 #      p.write_text(s)
 #      PY
 # https://modelcontextprotocol.io/specification/2025-06-18/server/tools

 FAULT D - the tool result shape (check 7)
 # handle_tools_call returned {"output": "212", "unit": "F"} - a private
 # shape. A tools/call result carries content: an array of typed blocks.
 #
 #   python3 - <<'PY'
 #   import pathlib
 #   p = pathlib.Path("server.py"); s = p.read_text()
 #   s = s.replace(
 #       '        "output": "%g" % result,\n        "unit": to_unit,\n',
 #       '        "content": [{"type": "text", "text": "%g %s = %g %s" % (value, from_unit, result, to_unit)}],\n')
 #   p.write_text(s)
 #   PY
 #
 # Keep isError where it is: tool-level failures belong in the result so the
 # model can see and recover from them, while protocol-level failures use the
 # JSON-RPC error object (-32601, -32602, ...). Check 8 guards that split.

 VERIFY
 #   ./probe.sh         -> 9/9 OK
 #   ./vendor.sh        -> still prints "100 C -> 100 C = 212 F"
 #   ../break-fix-mcpa-1.3.sh verify   -> GRADE: PASS
 #
 # The point to carry into the exam: nothing here was a "hard" bug. Each
 # fault was a small local convenience that cost nothing inside the team and
 # removed the server from the entire ecosystem. Interoperability is not a
 # property of the protocol; it is a property of the implementation, and it
 # is only worth the M + N arithmetic while it is enforced - by validating
 # clients, by conformance checks in CI, by refusing to be tolerant.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/mcpa/1.3/lab)
