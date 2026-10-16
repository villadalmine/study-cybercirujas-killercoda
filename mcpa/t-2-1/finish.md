## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
=== SOLUTION — MCPA 2.1, Schemas & Structured Data ==========================

Five defects, all in $LAB_DIR/server.py. Fix them in this order; each step
turns one probe check green, so you can verify incrementally with
`./mcpa-2.1-break-fix.sh verify` after every edit.

STEP 0 — Reproduce and read the evidence, do not guess
  $ cd ~/mcpa-lab-2.1
  $ ../mcpa-2.1-break-fix.sh trace 2>&1 | less

In the trace, find the `tools/list` response and the two `tools/call`
responses. Everything you need is in those three frames: the advertised
schemas and the actual payloads. The transport is healthy — `initialize`
succeeds (C1) and both tools are listed (C2), so the fault is entirely in
the schema layer.

Useful one-liners (the server is an importable module, so inspect it directly):
  $ python3 -c 'import json,server; print(json.dumps(server.GET_FORECAST, indent=2))'
  $ python3 -c 'import json,server; print(json.dumps(server.handle_get_forecast({"station":"SAEZ"}), indent=2))'
  $ python3 -c 'import json,server; json.loads(server.STATION_CATALOGUE)'
    Traceback ... json.decoder.JSONDecodeError: Expecting value: line 6 column 3 (char 129)

STEP 1 — C4: the inputSchema root type (GET_FORECAST["inputSchema"]["type"])
Symptom: the model never calls get_forecast. A validating host loads
tools/list, fails to resolve the schema, and silently drops the tool — from
the model's point of view the tool does not exist. Nothing is logged as an
error at the protocol level, which is exactly why this one is expensive.

  BEFORE:   "type": "Object",
  AFTER:    "type": "object",

Two rules in one line. JSON Schema type names are lowercase and case
sensitive — "Object" is not a misspelling the validator tolerates, it is an
unknown type. And MCP requires a tool's inputSchema root to be an object
schema specifically, because tool arguments are always passed as a named
map (`params.arguments`), never as a bare scalar or array.
  https://modelcontextprotocol.io/specification/2025-06-18/server/tools
  https://json-schema.org/understanding-json-schema/reference/type

STEP 2 — C4: required names a property that does not exist
Symptom: even after step 1, a strict host reports the schema as
unsatisfiable, and a permissive host lets the model guess: it invents a
`units` key the server ignores, or it refuses to call at all because it
cannot fill a required parameter that has no description, no type and no
enum.

  BEFORE:   "required": ["station", "units"],
  AFTER:    "required": ["station"],

The property is `unit` (singular), and it is genuinely optional: the handler
defaults it. So the fix is to drop it from `required`, not to rename the
entry. If you want it required instead, rename it to "unit" — but then the
handler must stop defaulting and must reject a call without it. Either is
defensible; what is never defensible is a `required` entry with no matching
property, because no caller on earth can satisfy it.

Keep the `enum` on `unit`: an enum is the cheapest way to stop a model from
inventing "celsius", "C", "metric". Enums are part of the contract, not
documentation.

STEP 3 — C7 and C8: structuredContent must match the declared outputSchema
Symptom: the call succeeds and the text block reads perfectly to a human —
"SAEZ: 21.5 C, few clouds" — yet the consumer fails. The outputSchema
promises `temperature_c` as a `number`; the handler returns `temperature` as
a `string`. Wrong key, wrong type. Anything downstream that compares,
averages or thresholds that value breaks, and the probe reports both:
    structuredContent: required property "temperature_c" is missing

Rewrite handle_get_forecast so the structured object is built once and the
text block is its serialization:

  def handle_get_forecast(args):
      station_id = (args.get("station") or "SAEZ").upper()
      row = next((s for s in STATIONS if s["id"] == station_id), None)
      if row is None:
          return {
              "content": [{"type": "text", "text": "unknown station: %s" % station_id}],
              "isError": True,
          }

      structured = {
          "station": row["id"],
          "temperature_c": row["temperature_c"],   # number, not str(...)
          "conditions": row["conditions"],
      }
      return {
          "content": [{"type": "text", "text": json.dumps(structured)}],
          "structuredContent": structured,
      }

Three things happened there, and each is exam-relevant:
  * the key now matches the schema (`temperature_c`);
  * the value keeps its JSON type (`21.5`, not `"21.5"`) — str() is how a
    float silently becomes a string, and JSON has a number type precisely so
    you do not have to re-parse it;
  * `content` is now derived from `structuredContent` instead of being written
    by hand. That is the general rule: ONE source of truth, serialized. The
    text block exists for backwards compatibility with hosts that ignore
    structuredContent, and it SHOULD carry the same data (probe check C8).

Note `isError: true` for the unknown-station path: a tool-level failure is
reported inside the result so the model can see it and retry, NOT as a
JSON-RPC error object, which is reserved for protocol-level faults
(unknown method, malformed request, unknown tool name).

STEP 4 — C9 and C10: declaring an outputSchema obliges the handler
Symptom: list_stations returns a comma-separated sentence. The agent tries to
iterate it and gets characters, or splits it on ", " and hopes. The tool
declares an outputSchema, so returning no structuredContent at all is a
contract violation, not a style choice.

  def handle_list_stations(args):
      structured = {"stations": [s["id"] for s in STATIONS]}
      return {
          "content": [{"type": "text", "text": json.dumps(structured)}],
          "structuredContent": structured,
      }

The schema says `"items": {"type": "string"}`, and station ids are strings —
the shapes agree. If you had returned the full station dicts, C10 would fail
with `structuredContent.stations[0]: expected string, got object`. When that
happens the answer is a decision, not a cast: either the schema describes
objects (`"items": {"type": "object", "properties": {...}}`) or the handler
returns ids. Never coerce the data to fit a schema you did not mean.

STEP 5 — C12: a mimeType is a claim about the bytes
Symptom: the resource is advertised as `application/json`, the host reads it
and calls json.loads(), and it explodes on the trailing comma after the last
array element. JSON, unlike Python, allows no trailing comma — and no
comments either, which is the other way hand-written JSON dies.

The tempting fix is to delete the comma. The correct fix is to stop writing
JSON by hand, because the same class of bug will come back the moment anyone
edits the catalogue:

  BEFORE:
      STATION_CATALOGUE = """{
        "stations": [
          {"id": "SAEZ", "name": "Ezeiza"},
          ...
        ]
      }
      """

  AFTER (delete the string constant entirely and serialize the real data):
      def station_catalogue():
          return json.dumps(
              {"stations": [{"id": s["id"], "name": s["name"]} for s in STATIONS]},
              indent=2,
          )

  ... and in the resources/read branch of dispatch():
      reply(request_id, {"contents": [{
          "uri": uri,
          "mimeType": "application/json",
          "text": station_catalogue(),
      }]})

Now the payload cannot drift from the data and cannot be syntactically
invalid, and the catalogue stays in sync with the STATIONS list that feeds
the tools. Serializers exist so that structured data is produced by a
machine that cannot forget a comma.

VERIFY
  $ ./mcpa-2.1-break-fix.sh verify

  === MCP schema probe: weather-lab ===
  [PASS] C1  initialize handshake completes
  [PASS] C2  tools/list advertises get_forecast and list_stations
  [PASS] C3  get_forecast declares both inputSchema and outputSchema
  [PASS] C4  get_forecast.inputSchema is a usable JSON Schema object
  [PASS] C5  declared outputSchemas are structurally sound
  [PASS] C6  get_forecast returns structuredContent (outputSchema is declared)
  [PASS] C7  get_forecast.structuredContent conforms to its outputSchema
  [PASS] C8  the text content block mirrors structuredContent as serialized JSON
  [PASS] C9  list_stations returns structuredContent (outputSchema is declared)
  [PASS] C10 list_stations.structuredContent conforms to its outputSchema
  [PASS] C11 the station catalogue resource is advertised with a mimeType
  [PASS] C12 a resource declared "application/json" parses as JSON

  0 failing, 0 warning, 12 passing
  LAB PASSED — 0 failing checks. The schema contract holds end to end.

WHAT TO CARRY INTO PRODUCTION (and into the exam)
  * A tool's inputSchema is not documentation. Hosts read it to decide whether
    the tool is usable at all, and a malformed schema removes the tool from
    the model's world with no error anyone will notice.
  * `type` values are lowercase; `required` may only name declared properties;
    `enum` is the cheapest guard against invented arguments.
  * `outputSchema` is a promise. If you declare it, `structuredContent` is
    mandatory and must validate — key by key, type by type. If you are not
    going to honour it, do not declare it.
  * `content` is for humans and legacy hosts; `structuredContent` is for
    programs. Build the structured object first and serialize it into the text
    block, so the two can never disagree.
  * Never hand-write JSON into a string literal. `json.dumps` cannot produce a
    trailing comma, a comment, or an unquoted key.
  * Validate your own schemas in CI. Everything the probe does here —
    lint the advertised schema, call the tool, validate the response against
    the schema the server itself published — is a few dozen lines and catches
    this entire class of defect before a student, or a model, ever sees it.

SOURCES
  Linux Foundation, MCPA certification:
    https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
  MCP specification 2025-06-18, Tools (inputSchema, outputSchema,
  structuredContent, isError):
    https://modelcontextprotocol.io/specification/2025-06-18/server/tools
  MCP specification 2025-06-18, Resources (uri, mimeType, contents):
    https://modelcontextprotocol.io/specification/2025-06-18/server/resources
  JSON Schema, type keyword:
    https://json-schema.org/understanding-json-schema/reference/type
  RFC 8259, The JavaScript Object Notation (JSON) Data Interchange Format:
    https://www.rfc-editor.org/rfc/rfc8259
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/mcpa/2.1/lab)
