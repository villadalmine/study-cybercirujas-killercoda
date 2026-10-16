## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION - STEP BY STEP
 (Everything below is commented out. Read it only after your own attempt.)

STEP 0 - Establish the facts before touching anything

  mcp-lab status          # the unit is active (running): this is not an outage
  mcp-lab logs 40         # no tracebacks: the defects are in response SHAPE
  mcp-lab verify          # four red checks, each naming the rule it broke

Expected output of `mcp-lab verify` before the repair:

  [PASS] handshake             protocol 2025-06-18, server mcp-lab 1.0.0
  [FAIL] pagination            tools/list returned an EMPTY page and still advertised nextCursor...
  [FAIL] structured-output     structuredContent violates the declared outputSchema: $.load1: expected
                               number, got str ('0.14') | no text content block: ...
  [FAIL] tool-error-channel    a tool that RAN AND FAILED was reported as a JSON-RPC error (code -32603)...
  [FAIL] progress-correlation  progress notifications carry 'scan-1417' instead of the caller's token...

Look at the wire yourself - this is the habit the exam is testing:

  mcp-lab rpc tools/call '{"name":"disk_usage","arguments":{"path":"/nope"}}'
  mcp-lab rpc tools/call '{"name":"sys_metrics","arguments":{}}'
  mcp-lab rpc tools/list '{}'

STEP 1 - S1 / tool-error-channel: put execution failures back in the result

In /opt/mcp-lab/server.py, function tool_disk_usage():

  -        raise RpcError(INTERNAL_ERROR, f"disk_usage: no such path: {path}")
  +        return _tool_failure(f"disk_usage: no such path: {path}")

Why. MCP deliberately splits failure into two channels:
  * JSON-RPC error object -> the request could not be processed at all
    (unknown method -32601, unknown tool or bad arguments -32602, transport
    faults). The client treats this as a protocol fault and aborts the call.
  * result with "isError": true plus a content block -> the tool executed and
    failed. The content is handed to the model, which reads "no such path" and
    retries with a valid one. That self-correction loop is the entire point.
Note the contrast left intact two lines above: arguments of the wrong shape
still raise RpcError(INVALID_PARAMS, ...), because there the tool never ran.

  mcp-lab restart && mcp-lab verify   # tool-error-channel turns green

STEP 2 - S2 / structured-output: honour the contract you published

Two edits in tool_sys_metrics():

  -    payload = {"host": platform.node(), "load1": str(round(load1, 2)), "uptime_s": uptime_s}
  +    payload = {"host": platform.node(), "load1": round(load1, 2), "uptime_s": uptime_s}

  -    return {"structuredContent": payload, "isError": False}
  +    return {"content": [{"type": "text", "text": json.dumps(payload, indent=2)}], "structuredContent": payload, "isError": False}

Why. The tool's outputSchema declares load1 as "number"; "0.14" is a string,
so a validating client rejects the whole result - the data was right and the
type was wrong, which is the most common structured-output bug in the field.
The second edit restores the compatibility mirror: a tool returning
structuredContent SHOULD also return the same object serialized in a
TextContent block, so clients (and models) that ignore structured output still
receive something they can read. Confirm the contract and the answer agree:

  mcp-lab rpc tools/list '{}' | grep -A12 outputSchema
  mcp-lab rpc tools/call '{"name":"sys_metrics","arguments":{}}'

STEP 3 - S3 / pagination: a listing has to be able to end

In paginate():

  -    if True:
  +    if next_offset < len(items):
           result["nextCursor"] = _encode_cursor(next_offset)

Why. nextCursor is not "the next offset", it is "there is more". Present means
keep going; absent means the listing is complete. Advertising it
unconditionally turns every client's `while cursor:` loop into an unbounded
request loop against your server - a self-inflicted denial of service that
scales with the number of connected agents. The same rule governs
resources/list, prompts/list and resources/templates/list; the cursor stays
opaque to the client, which must never parse or synthesise one.

  mcp-lab rpc tools/list '{}'        # page 1: 2 tools + nextCursor
  # feed that cursor back and the second page must come back WITHOUT a cursor

STEP 4 - S4 / progress-correlation: never orphan a message

Two edits in Handler._stream_slow_scan():

  -            emit(_progress_notification("scan-" + str(os.getpid()), done, total, message))
  +            emit(_progress_notification(token, done, total, message))

  -        emit({"jsonrpc": "2.0", "id": str(req_id), "result": result})
  +        emit({"jsonrpc": "2.0", "id": req_id, "result": result})

Why, first edit. A progress notification is not addressed to a request - it
carries the progressToken the CALLER supplied in params._meta.progressToken.
Invent your own and the client receives progress it cannot attribute to any
in-flight call: it is dropped, and the user stares at a frozen spinner.
Sending progress when no token was supplied is equally wrong - that is why the
`if token is None: return` guard stays.

Why, second edit. JSON-RPC 2.0 correlates responses to requests by id, and the
id MUST be echoed unchanged - the integer 7 and the string "7" are different
ids. The response does reach the client here; it simply matches nothing in the
pending-request table, so the call stays open until the client's timeout fires
and reports a hang that the server logs will never explain. That is exactly
what the harness means by "ids on the stream: '7' (str)".

STEP 5 - Verify, and understand what green means

  mcp-lab restart
  mcp-lab verify ; echo "exit=$?"

  [PASS] handshake             protocol 2025-06-18, server mcp-lab 1.0.0
  [PASS] pagination            4 tools over 2 page(s), cursor omitted on the last one
  [PASS] structured-output     structuredContent validates, mirrored as text (host, load1, uptime_s)
  [PASS] tool-error-channel    execution failure -> isError result, unknown tool -> JSON-RPC error
  [PASS] progress-correlation  3 progress notifications on token probe-1417, response correlated
  all 5 checks passed
  exit=0

Compare your repair against the pristine server if you want:

  diff -u /root/.mcp-lab-answer-key/server.py /opt/mcp-lab/server.py

WHAT TO CARRY INTO THE EXAM

  * isError:true is for the model; a JSON-RPC error is for the client. Choosing
    the wrong one either hides a recoverable mistake or kills a live turn.
  * An outputSchema is a promise. Publishing one and returning something else
    is worse than publishing none, and the mirror text block is what keeps
    older clients working.
  * nextCursor means "there is more", not "here is the offset". Absent ends the
    listing. Cursors are opaque: never parse, never fabricate.
  * id and progressToken are the routing fabric of the session. Echo them
    byte-for-byte and type-for-type, or the message is unroutable - and an
    unroutable message looks to everyone like a hang, not like a bug.
  * Diagnose at the protocol layer: `mcp-lab rpc ...` shows the frames. A
    healthy process with malformed responses is the normal failure mode of an
    MCP integration, and no amount of `systemctl status` will reveal it.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/mcpa/3.1/lab)
