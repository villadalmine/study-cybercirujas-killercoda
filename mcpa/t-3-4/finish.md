## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
=== SOLUTION BEGIN ==========================================================

MCPA 3.4 - Protocol Primitives - step-by-step solution
Seven defects in four areas. All edits are in server.py.

Step 0 - reproduce before you touch anything

    cd "$MCP_LAB_DIR"   # default: $HOME/mcpa-lab-3.4
    python3 verify.py
    ./probe.sh | python3 -c 'import sys;[print(l.rstrip()) for l in sys.stdin]'

  Expect 8 failing checks on a fresh lab. Work top-down: the lifecycle
  defects distort everything below them.

AREA 1 - LIFECYCLE (2 defects)

Defect A - initialize echoes the client's protocolVersion.

  In dispatch(), under `if method == "initialize":`

    -        "protocolVersion": params.get("protocolVersion", PROTOCOL_VERSION),
    +        "protocolVersion": PROTOCOL_VERSION,

  Why: version negotiation is a statement of what the SERVER supports.
  The client proposes, the server answers with a version it can actually
  speak - if it does not match what the client offered, the client decides
  whether to continue or disconnect. Echoing the client's string turns the
  negotiation into a mirror: a client speaking a version the server has
  never implemented is told "agreed", and the failure surfaces much later
  as a malformed field, which is far harder to diagnose.
  A server that supports several versions should answer with the requested
  one if it is in its supported set, and otherwise with its latest.

  Verify:
    ./probe.sh '{"jsonrpc":"2.0","id":9,"method":"ping","params":{}}' | head -1

Defect B - the server answers a notification.

  In dispatch():

       if method == "notifications/initialized":
    -      reply(request_id, {})
           return

  Why: in JSON-RPC 2.0 a notification is precisely a request WITHOUT an id,
  and it must not be answered. `reply(None, {})` puts `"id": null` on the
  wire; a client correlates responses by id, so it can match this to
  nothing. Strict clients treat it as a protocol violation and drop the
  connection; lenient ones log it and leak one queued reader per
  notification. The same rule applies to every notifications/* method:
  cancelled, progress, roots/list_changed, resources/updated.

  Note the guard at the bottom of dispatch(): `if request_id is not None`
  before fail(...). That is the same rule applied to unknown methods -
  an unknown NOTIFICATION is silently ignored, an unknown REQUEST gets
  -32601. Keep it.

AREA 2 - TOOLS (2 defects)

Defect C - disk_usage.inputSchema is not an object schema.

  In the TOOLS list, first entry:

        "inputSchema": {
    +       "type": "object",
            "properties": {
                "path": {"type": "string", "description": "..."}
            },
            "required": ["path"],
        },

  Why: inputSchema is a JSON Schema describing the ARGUMENTS OBJECT of the
  call. Without "type": "object" the schema is unconstrained, so the host
  cannot validate arguments before dispatching and the model has no
  reliable signal about the parameter shape. Hosts routinely refuse to
  expose such a tool - which is why one tool was missing from the picker
  while echo_context, whose schema is correct, showed up. Compare the two
  entries in TOOLS: the second is the template.

Defect D - a successful tools/call returns the wrong result shape.

  In call_tool():

        except ToolFailure as exc:
            return {"content": [{"type": "text", "text": str(exc)}], "isError": True}
    -   return {"output": text}
    +   return {"content": [{"type": "text", "text": text}], "isError": False}

  Why: a tool result is always a list of content blocks - text, image,
  audio or embedded resource - plus the boolean isError. The transport
  succeeded, so the client sees no error at all; it just finds no `content`
  key, renders nothing, and the model receives an empty tool result. That
  is the worst failure mode in this topic: silent, and it looks like the
  model ignored the tool.

  Observe that the ERROR path in the same function was already correct.
  That asymmetry is the diagnostic clue and it is also the lesson:
  execution failures belong INSIDE the result with isError:true, so the
  model can read the message and retry; JSON-RPC errors (-32602 for an
  unknown tool, -32601 for an unknown method) are reserved for protocol
  failures the model cannot act on. Both halves must be shaped alike.

  Verify:
    ./probe.sh '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"disk_usage","arguments":{"path":"/"}}}' | tail -1

AREA 3 - RESOURCES (2 defects)

Defect E - the list handler is registered under the wrong method name.

  In dispatch():

    -   if method == "resource/list":
    +   if method == "resources/list":
            reply(request_id, {"resources": resource_descriptors()})
            return

  Why: initialize declared `"resources": {...}` in capabilities, which is a
  promise that resources/list, resources/read and (only if subscribe is
  true) resources/subscribe are reachable. The dispatcher matches on an
  exact string, so a singular typo makes the method unreachable and every
  call falls through to -32601 Method not found. The pairing is the point:
  a declared capability with no handler is the single most common
  server-side conformance bug, and -32601 on a method you "know you
  implemented" should send you straight to the dispatch table rather than
  to the handler body.

  While you are there, keep the discipline honest: the server declares
  "subscribe": false, and it implements no resources/subscribe. That pair
  is correct. Do not declare true unless you implement it.

Defect F - resources/read omits the uri of each entry.

  In dispatch(), under `if method == "resources/read":`

        reply(
            request_id,
    -       {"contents": [{"mimeType": entry["mimeType"], "text": entry["text"]}]},
    +       {
    +           "contents": [
    +               {
    +                   "uri": uri,
    +                   "name": entry["name"],
    +                   "mimeType": entry["mimeType"],
    +                   "text": entry["text"],
    +               }
    +           ]
    +       },
        )

  Why: contents is a LIST because one read may legitimately expand into
  several items (a directory-like URI, a template expansion). Each entry
  therefore identifies itself with its own uri, and carries either `text`
  for textual data or `blob` (base64) for binary - never both. Without the
  uri, a client that just read three resources cannot tell which payload is
  which, cannot attach it to the conversation with a citation, and cannot
  invalidate it when notifications/resources/updated arrives for one URI.

  Keep -32002 for a URI that does not exist: that is the resource-specific
  "not found" code, distinct from -32602 (invalid params).

AREA 4 - PROMPTS (1 defect, two symptoms)

Defect G - prompts/get returns a system role and bare-string content.

  In dispatch(), under `if method == "prompts/get":`

            "messages": [
    -           {
    -               "role": "system",
    -               "content": "You are an SRE on call. Be concise and cite evidence.",
    -           },
    -           {
    -               "role": "user",
    -               "content": ("Triage %s, declared %s. ..." % (service, severity)),
    -           },
    +           {
    +               "role": "user",
    +               "content": {
    +                   "type": "text",
    +                   "text": (
    +                       "You are an SRE on call. Be concise and cite evidence.\n\n"
    +                       "Triage %s, declared %s. State the blast radius, the first "
    +                       "three commands you would run, and the rollback you would "
    +                       "prepare before touching anything." % (service, severity)
    +                   ),
    +               },
    +           },
            ],

  Why, two independent reasons:

    * Roles. A PromptMessage role is "user" or "assistant" only. There is
      no system role in this primitive: the system prompt belongs to the
      HOST, and a server that could inject one would be able to override
      the host's instructions through a menu entry the user merely clicked.
      Server guidance goes into the first user message - visible, and
      subject to the host's own policy. This is a security boundary, not a
      formatting preference.

    * Content. PromptMessage.content is ONE content block object, the same
      union the tool result uses - {"type": "text", "text": ...},
      {"type": "image", "data": ..., "mimeType": ...}, or
      {"type": "resource", "resource": {...}} to embed a resource by URI.
      A bare string has no type discriminator, so a client that switches on
      content["type"] raises - which is exactly the crash on expanding the
      prompt. Note the shape rhyme across primitives: tools return content
      blocks, prompts carry content blocks, resources embed as one.
      Learn the block, and three primitives become one shape.

  The argument validation in this handler was already correct and is worth
  copying: prompts/list declares `arguments` with name/description/required,
  and prompts/get rejects a missing required argument with -32602 (invalid
  params) instead of silently substituting a default. A prompt is a
  user-controlled, parameterised template - the contract it publishes in
  prompts/list is the contract it must enforce in prompts/get.

Step 5 - confirm

    python3 verify.py; echo "exit=$?"

  Expected: every check PASS, "exit=0", and the final line
  "Every protocol-primitive check passes."

  Then re-read the raw wire once more with ./probe.sh and notice what a
  conformant server looks like: initialize answers with its own version,
  the notification produces silence, every tools/call - success and failure
  alike - carries content blocks, every resources/read entry names its own
  URI, and every prompt message is a user/assistant turn holding a typed
  content block.

Step 6 - tear down

    "$0" clean     # removes the lab directory (marker-guarded)

=== SOLUTION END ============================================================
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/mcpa/3.4/lab)
