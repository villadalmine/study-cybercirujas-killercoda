## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — step by step. Stop reading if you have not tried yet.

 STEP 0 — Reproduce and localise, before editing anything.
   sudo bash /opt/mcp-lab/verify.sh          # 2/7 PASS, five named failures
   ss -ltnp | grep 8931                      # 0.0.0.0:8931  -> off-host reachable
   TOKEN=$(python3 /opt/mcp-lab/mint-token.py https://files.other.lab/mcp)
   curl -i -X POST http://127.0.0.1:8931/mcp -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' -H 'Origin: http://evil.example' \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
   # 200 OK: a foreign-audience token, from a foreign origin, listing your tools.

 Read the token you were just handed — it is not opaque:
   python3 - <<'EOF'
   import base64, json, sys
   p = sys.stdin.read().strip().split(".")[1] if False else None
   EOF
   # simpler:  echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null; echo
   # You will see "aud": "https://files.other.lab/mcp". The server never looked.

 STEP 1 — Boundary 1: shrink the listener to loopback.
 A local MCP server has no business on 0.0.0.0. Edit the unit:

   sudo sed -i 's/^Environment=MCP_LAB_BIND=0\.0\.0\.0$/Environment=MCP_LAB_BIND=127.0.0.1/' \
     /etc/systemd/system/mcp-lab.service
   sudo systemctl daemon-reload && sudo systemctl restart mcp-lab
   ss -ltnp | grep 8931          # 127.0.0.1:8931

 Also change the default in server.py so a missing Environment= line cannot
 silently re-expose it — fail closed, not open:

   BIND = os.environ.get("MCP_LAB_BIND", "127.0.0.1")

 STEP 2 — Boundary 2: validate Origin (DNS rebinding).
 Loopback is not a security boundary against a browser: a page on any site can
 POST to 127.0.0.1, and a rebound DNS name resolves to 127.0.0.1 while keeping
 the attacker's origin. Add to server.py, above do_POST:

   def origin_allowed(headers):
       origin = headers.get("Origin")
       if origin is None:          # non-browser MCP client: no Origin at all
           return True
       return origin in ALLOWED_ORIGINS

 and make it the FIRST thing do_POST does, before reading the body or the token
 (an unauthenticated attacker must not reach your parser either):

   def do_POST(self):
       if not origin_allowed(self.headers):
           self._send(403, {"error": "forbidden_origin"})
           return
       ...

 STEP 3 — Boundary 3: a 401 must advertise how to authenticate.
 MCP authorization builds on OAuth 2.0 Protected Resource Metadata (RFC 9728):
 the 401 carries a WWW-Authenticate challenge pointing at the metadata document,
 which names the resource and its authorization servers. The lab server already
 serves the document at /.well-known/oauth-protected-resource; it just never
 points at it. Replace the bare 401 in do_POST:

   if claims is None:
       self._send(
           401,
           {"error": "invalid_token"},
           {"WWW-Authenticate":
               'Bearer realm="mcp-lab", error="invalid_token", '
               'resource_metadata="%s/.well-known/oauth-protected-resource"'
               % PUBLIC_BASE},
       )
       return

 STEP 4 — Boundary 4: validate the token's claims, not only its signature.
 This is the exam's headline anti-pattern: token passthrough / the confused
 deputy. A valid signature proves the issuer minted the token; it says nothing
 about WHO it was minted FOR. A gateway, a sibling service or a malicious client
 can replay a token issued for another resource server and get your tools.
 An MCP server MUST reject any token whose audience is not itself, and MUST NOT
 forward a client token to an upstream API. Replace authenticate():

   def authenticate(headers):
       header = headers.get("Authorization", "")
       if not header.startswith("Bearer "):
           return None
       claims = decode_token(header[7:].strip())
       if claims is None:
           return None
       if claims.get("iss") != ISSUER:
           return None
       audience = claims.get("aud")
       audiences = audience if isinstance(audience, list) else [audience]
       if RESOURCE_URI not in audiences:          # <- the confused deputy stops here
           return None
       now = time.time()
       expiry = claims.get("exp")
       if not isinstance(expiry, (int, float)) or expiry < now:
           return None
       not_before = claims.get("nbf")
       if isinstance(not_before, (int, float)) and not_before > now + 60:
           return None
       return claims

 The client side of the same boundary is RFC 8707: the client asks for a token
 scoped to one resource (resource=https://notes.mcp.lab/mcp), so a token it
 holds for one server is useless at another.

 STEP 5 — Boundary 5: contain the path inside the workspace root.
 os.path.join(ROOT, "../secrets/x") is not containment: join happily walks out,
 and an absolute argument discards ROOT entirely. Canonicalise first, then
 compare — and note that realpath also resolves a symlink planted inside the
 workspace, which string-prefix checks miss. Add:

   def resolve_within_root(relative):
       """Return an absolute path guaranteed to be inside WORKSPACE_ROOT, or None."""
       if not relative or os.path.isabs(relative) or "\0" in relative:
           return None
       root = os.path.realpath(WORKSPACE_ROOT)
       target = os.path.realpath(os.path.join(root, relative))
       if target != root and not target.startswith(root + os.sep):
           return None
       return target

 and use it in read_note(), refusing explicitly rather than 500-ing:

   def read_note(arguments):
       relative = str(arguments.get("path", ""))
       target = resolve_within_root(relative)
       if target is None:
           return {"content": [{"type": "text",
                                "text": "refused: %r is outside the notes workspace" % relative}],
                   "isError": True}
       ...unchanged from here...

 Two production notes the exam likes:
   * realpath()-then-open() is TOCTOU-racy on a writable directory; the hardened
     form is to open with O_NOFOLLOW / openat2(RESOLVE_BENEATH) and check the
     descriptor, not the string.
   * The refusal is returned as a tool result with isError true, not as a
     JSON-RPC protocol error: the model must see that the call was denied so it
     can tell the user, instead of the transport swallowing it.

 STEP 6 — Re-deploy and verify.
   sudo python3 -m py_compile /opt/mcp-lab/server.py   # syntax before restart
   sudo systemctl restart mcp-lab
   sudo bash /opt/mcp-lab/verify.sh
   # RESULT: 7/7 PASS — every trust boundary is enforced and the server still works.

 If check 7 regressed, you fixed a boundary by closing the door on everyone:
 the most common cause is rejecting a request with NO Origin header. Absent
 Origin means "not a browser"; it is foreign Origin that must be refused.

 STEP 7 — What each check maps to, in exam language.
   1 listener scope    Transport exposure. A local server must not be a LAN
                       service; binding is a trust boundary decision.
   2 browser origin    DNS rebinding. Origin validation + loopback binding are
                       required together; neither is sufficient alone.
   3 unauthenticated   Discoverability of the boundary (RFC 9728). A 401 that
                       says nothing forces clients to guess, or to hardcode.
   4 token audience    Confused deputy / token passthrough. The single most
                       examined MCP auth anti-pattern. Also: never reuse a
                       session id as an authentication credential, and never
                       forward the client's token upstream.
   5 token lifetime    Replay window. Signature validity is not liveness.
   6 path containment  Untrusted tool arguments. The server is the enforcement
                       point; the model and the client are not trusted callers.
   7 legitimate call   A boundary that breaks the product gets removed in the
                       next incident. Enforcement must be precise.

 Not covered by this lab, but on the same objective — worth reading next:
 server-supplied content (tool descriptions, resource bodies, prompts) crosses
 INTO the model's context and is untrusted input too, which is why hosts require
 explicit human approval per tool invocation, pin tool definitions against
 silent redefinition, and never grant a server's output the authority of a user
 instruction.

 STEP 8 — Tear the lab down.
   sudo /path/to/mcpa-4.1-trust-boundaries.sh --cleanup

 Sources
   https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
   https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices
   https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
   https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
   https://datatracker.ietf.org/doc/html/rfc9728
   https://datatracker.ietf.org/doc/html/rfc8707
   https://datatracker.ietf.org/doc/html/rfc6750#section-3
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/mcpa/4.1/lab)
