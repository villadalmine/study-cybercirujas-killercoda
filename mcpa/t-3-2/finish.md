## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
  SOLUTION - STOP HERE IF YOU HAVE NOT FINISHED THE LAB

  Ten defects, in the order the probe finds them. Each step gives the broken
  code, the replacement, and the rule it comes from.

STEP 0 - See the failures before you touch anything

  python3 ~/mcpa-lab-error-handling/probe.py

  Expect roughly 1/11 green. Fix top down: check 01 is the transport, and
  while stdout is polluted no client on earth can read this server.

  Watch the raw wire yourself - this is the diagnostic technique the exam
  expects you to know, and it works against any stdio MCP server:

    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}' \
      | python3 ~/mcpa-lab-error-handling/server.py

  Broken output - note the first line, which is not JSON at all:

    [mcpa-lab] server up, notes directory is /home/lab/mcpa-lab-error-handling/notes
    {"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "2025-06-18", ...}}

DEFECT 1 and 2 - log output on stdout  (check 01)

  In main():
      print("[mcpa-lab] server up, notes directory is %s" % NOTES_DIR)
  In handle_tools_call():
      print("[debug] tools/call name=%s args=%s" % (name, args))

  Replace both with writes to stderr:

      def log(message):
          sys.stderr.write("[mcpa-lab] %s\n" % message)
          sys.stderr.flush()

      log("server up, notes directory is %s" % NOTES_DIR)
      log("tools/call name=%s args=%s" % (name, args))

  Rule: on the stdio transport the server MUST NOT write anything to stdout
  that is not a valid MCP message; stderr is the sanctioned logging channel.
  https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
  In production this is the number one "my server does not connect" cause:
  a library that prints a banner, a warning from an SDK, a stray debug print.
  Defensive move: at startup, redirect the real stdout and keep a private
  handle for the protocol, so nothing downstream can corrupt the stream:

      PROTOCOL_OUT = sys.stdout
      sys.stdout = sys.stderr      # anything that prints now lands on stderr
      # ... and write protocol messages to PROTOCOL_OUT only

DEFECT 3 - a notification gets a response  (check 04)

  Broken, in dispatch():
      elif method == "notifications/initialized":
          send({"jsonrpc": "2.0", "id": None, "result": {"acknowledged": True}})

  Fixed:
      elif method == "notifications/initialized":
          log("client completed the handshake")
          return

  Better, make it structural rather than per-method - a message without an
  "id" member is a notification, and a notification never gets a reply:

      is_notification = "id" not in message
      ...
      if is_notification:
          return

  Rule: JSON-RPC 2.0 section 4.1 - the server MUST NOT reply to a
  notification. MCP adds that a request id MUST NOT be null, so
  {"id": null, "result": ...} is doubly wrong: it is a response nobody asked
  for, carrying an id the protocol forbids. Real clients either raise
  "unexpected response" or leak it into an unanswered-request table.

DEFECT 4 - unknown method answers -32603  (check 05)

  Broken, in dispatch():
      send_error(req_id, -32603, "Internal error while handling %s" % method)

  Fixed:
      send_error(req_id, -32601, "Method not found: %s" % method)

  Rule: the JSON-RPC 2.0 reserved codes are not interchangeable, and clients
  branch on them:
      -32700  Parse error       invalid JSON was received
      -32600  Invalid Request   valid JSON, not a valid Request object
      -32601  Method not found  the method does not exist
      -32602  Invalid params    the parameters are wrong
      -32603  Internal error    the server itself failed
      -32000..-32099           implementation-defined server errors
  -32601 tells a client "you asked for a capability I do not have, degrade";
  -32603 tells it "I am broken, maybe retry". Reporting a missing method as
  an internal error turns a graceful capability negotiation into a retry loop.
  https://www.jsonrpc.org/specification

DEFECT 5 - unparseable input kills the process  (check 06)

  Broken, in main():
      message = json.loads(line)
      dispatch(message)

  Fixed:
      try:
          message = json.loads(line)
      except ValueError as exc:
          # JSON-RPC 2.0 section 5.1: when the id cannot be determined
          # because the request did not parse, the id in the response is null.
          send({"jsonrpc": "2.0", "id": None,
                "error": {"code": -32700, "message": "Parse error: %s" % exc}})
          continue

      if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
          send_error(message.get("id") if isinstance(message, dict) else None,
                     -32600, "Invalid Request")
          continue

      try:
          dispatch(message)
      except Exception as exc:
          # Last line of defence: an unexpected server fault is -32603, and
          # it must not end the session either.
          log("unhandled exception in dispatch: %r" % exc)
          if "id" in message:
              send_error(message.get("id"), -32603, "Internal error", {"detail": str(exc)})

  Rule: a long-lived transport must be crash-proof at the loop boundary. One
  malformed line is a routine event - a truncated write, a proxy that split a
  message - and it costs one error response, not the session. Note the
  asymmetry with MCP's own rule: requests must carry a non-null id, but a
  parse-error response is exactly the case where null is correct, because the
  id was never legible.

DEFECT 6 - result and error in one response, wrong code  (check 07)

  Broken, in tool_divide():
      send({"jsonrpc": "2.0", "id": req_id,
            "result": {...}, "error": {"code": -32603, ...}})

  Fixed - validate against the declared inputSchema and answer -32602:

      def tool_divide(req_id, args):
          a = args.get("a")
          b = args.get("b")
          for key, value in (("a", a), ("b", b)):
              if value is None:
                  send_error(req_id, -32602, "Missing required argument: %s" % key)
                  return
              if isinstance(value, bool) or not isinstance(value, (int, float)):
                  send_error(req_id, -32602,
                             "Argument %s must be a number, got %s" % (key, type(value).__name__))
                  return
          ...

  Rule: JSON-RPC 2.0 section 5 - a Response object contains EITHER result OR
  error, never both. Strict clients reject the message outright; lenient ones
  read result and silently drop the failure, which is worse. And arguments
  that violate the tool's inputSchema are a protocol error (-32602), not a
  tool execution error: the model was told the schema, so a violation is a
  client-side bug, not a fact about the world. Note the isinstance bool check
  - in Python True is an int, and "divide(True, 2)" is not a number your
  schema promised.

DEFECT 7 - ZeroDivisionError escapes and kills the server  (check 08)

  Broken, in tool_divide():
      value = float(a) / float(b)
      send_tool_text(req_id, "%s / %s = %s" % (a, b, value))

  Fixed:
      try:
          value = float(a) / float(b)
      except ZeroDivisionError:
          send_tool_text(
              req_id,
              "divide failed: b is 0 and division by zero is undefined. "
              "Retry with a non-zero divisor.",
              is_error=True,
          )
          return
      send_tool_text(req_id, "%s / %s = %s" % (a, b, value))

  Rule: this is the heart of topic 3.2. The arguments were valid; the
  operation failed. That failure belongs to the model, so it travels as a
  normal result with isError: true and a text block written FOR the model -
  say what failed and what a viable retry looks like. Had this stayed an
  exception it would have done two kinds of damage: the process dies (every
  other in-flight request on that session dies with it) and the agent gets a
  transport failure it cannot reason about.

  The generic shape, worth memorising, because it is how every well-behaved
  MCP tool handler is written:

      def handle_tools_call(req_id, params):
          name = params.get("name")
          args = params.get("arguments") or {}
          handler = HANDLERS.get(name)
          if handler is None:
              send_error(req_id, -32602, "Unknown tool: %s" % name)   # protocol
              return
          try:
              handler(req_id, args)
          except Exception as exc:                                     # execution
              log("tool %s raised: %r" % (name, exc))
              send_tool_text(req_id, "%s failed: %s" % (name, exc), is_error=True)

DEFECT 8 - an IO failure reported as -32603  (check 09)

  Broken, in tool_read_note():
      except OSError as exc:
          send_error(req_id, -32603, "read_note failed: %s" % exc)

  Fixed:
      except FileNotFoundError:
          send_tool_text(req_id,
                         "read_note failed: no note named '%s'. "
                         "Call tools/list or try 'welcome'." % name,
                         is_error=True)
          return
      except OSError as exc:
          send_tool_text(req_id, "read_note failed: %s" % exc, is_error=True)
          return

  Rule: same channel question, different upstream. A missing file, an HTTP
  503, a database timeout - the model asked for something the world could not
  provide, and the model is the one that can react (ask the user, pick
  another note, stop). Sent as -32603 it is invisible to the model and the
  agent looks like it hung. Never put the raw exception text and nothing else
  in the content block: write the sentence you would want the model to read.

DEFECT 9 - no path containment in read_note  (check 10)

  Broken:
      path = os.path.join(NOTES_DIR, "%s.txt" % name)

  os.path.join is not a sandbox: name = "../../../../etc/hostname" escapes,
  and the tool happily serves the host's files to whoever is driving the
  model. Prompt injection turns this into data exfiltration.

  Fixed - validate the argument, then verify the resolved path:

      if not isinstance(name, str) or not name:
          send_error(req_id, -32602, "Argument 'name' must be a non-empty string")
          return
      if "/" in name or "\\" in name or name.startswith("."):
          send_tool_text(req_id,
                         "read_note refused '%s': note names may not contain path "
                         "separators or start with a dot." % name,
                         is_error=True)
          return

      base = os.path.realpath(NOTES_DIR)
      path = os.path.realpath(os.path.join(base, "%s.txt" % name))
      if os.path.commonpath([base, path]) != base:
          send_tool_text(req_id, "read_note refused '%s': path escapes the notes "
                                 "directory." % name, is_error=True)
          return

  Rule: two layers, because they fail differently - the string check rejects
  the obvious, the realpath + commonpath check catches symlinks and encodings
  the string check never imagined. A refusal is a policy decision about a
  syntactically valid request, so isError: true is the right channel: the
  model learns the constraint and can retry legally. Answering -32602 here is
  also defensible (the probe accepts it); what is never defensible is serving
  the file. MCP servers run with the privileges of whoever launched them.

DEFECT 10 - unknown tool answered as a successful result  (check 11)

  Broken, in handle_tools_call():
      else:
          send_tool_text(req_id, "unknown tool: %s" % name)

  That is a success, with isError absent. The model is told the call worked
  and the text it gets back is "unknown tool" - so it may well report to the
  user that the operation completed.

  Fixed:
      else:
          send_error(req_id, -32602, "Unknown tool: %s" % name,
                     {"available": [t["name"] for t in TOOLS]})

  Rule: the spec classes unknown tools with invalid arguments and server
  errors as PROTOCOL errors. The tool name came from the listing the client
  itself fetched, so asking for one that does not exist is a client fault -
  usually a stale tools list, which is exactly what the data field above
  helps the client repair. -32601 is accepted by many implementations too;
  what matters is that it is an error object and not a result.

VERIFY

  ~/mcpa-lab-error-handling/probe.py   # or: ./mcpa-3.2-error-handling.sh verify

  Expected final state:

    [ PASS ] 01  stdout carries protocol messages and nothing else
    [ PASS ] 02  initialize returns protocolVersion, capabilities and serverInfo
    [ PASS ] 03  the happy path still works (tools/list, divide, read_note)
    [ PASS ] 04  a notification is never answered
    [ PASS ] 05  an unknown method answers -32601 Method not found
    [ PASS ] 06  malformed JSON answers -32700 and does not kill the session
    [ PASS ] 07  arguments that violate inputSchema answer -32602, and only that
    [ PASS ] 08  division by zero is a tool execution error, not a dead server
    [ PASS ] 09  a missing note is a tool execution error, not a protocol error
    [ PASS ] 10  a path outside the notes directory is refused, never served
    [ PASS ] 11  an unknown tool name is a protocol error
     11 checks, 11 passed, 0 failed

  And the two sentences that carry the whole topic into the exam:

    A protocol error is a message to the CLIENT: the request was unusable.
    A tool execution error is a message to the MODEL: the request was fine,
    the world said no.

  Tear the lab down with:  ./mcpa-3.2-error-handling.sh clean
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/mcpa/3.2/lab)
