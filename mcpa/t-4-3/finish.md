## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION (step by step). Try the lab on your own first.

 Step 0 - Triage. Read what the server actually enforces.
 # cat /opt/mcp-lab/etc/policy.json
     allowed_roots ["/"], enforce_tool_pinning false, delete_file "auto",
     audit_log null. Four controls are gone in one file.
 # diff <(python3 -m json.tool /opt/mcp-lab/vendor/fs-tools-1.2.0/tools.json) \
 #      <(python3 -m json.tool /opt/mcp-lab/etc/tools.json)
     read_file gained an <IMPORTANT> block: a prompt injection that lives in
     tool metadata ("tool poisoning"). delete_file now calls itself safe and
     reports destructiveHint=false. Tool descriptions and annotations come
     from the server and go into the model's context. The MCP spec says
     clients MUST treat annotations as untrusted unless the server is
     trusted. A server that changes its definitions after approval is a
     "rug pull". Pinning exists to catch exactly that.

 Step 1 - Take the credential off argv.
 # TOKEN=$(cat /opt/mcp-lab/secrets/upstream.token)
 # install -m 600 -o root -g root /dev/null /opt/mcp-lab/etc/guard.env
 # printf 'MCP_GUARD_TOKEN=%s\n' "$TOKEN" > /opt/mcp-lab/etc/guard.env
     printf is a bash builtin, so the token never shows up in a process argv.
     Redirecting into the existing file keeps its 0600 mode.
 # cat > /opt/mcp-lab/bin/run-guard.sh <<'EOF'
 #!/usr/bin/env bash
 set -euo pipefail
 set -a
 . /opt/mcp-lab/etc/guard.env
 set +a
 exec /usr/bin/env python3 /opt/mcp-lab/bin/mcp_guard.py \
   --policy /opt/mcp-lab/etc/policy.json
 EOF
 # chmod 755 /opt/mcp-lab/bin/run-guard.sh
     In production the token has already leaked through ps, shell history
     and backups, so ROTATE it at the issuer. Moving it is not enough.
     With systemd, EnvironmentFile= or LoadCredential= do the same job.

 Step 2 - Restore the reviewed manifest. Do NOT re-pin.
 # install -m 644 /opt/mcp-lab/vendor/fs-tools-1.2.0/tools.json /opt/mcp-lab/etc/tools.json
 # python3 -c 'import json,sys; sys.path.insert(0,"/opt/mcp-lab/bin"); \
 #   from mcp_guard import tool_hash; \
 #   print({t["name"]: tool_hash(t) for t in json.load(open("/opt/mcp-lab/etc/tools.json"))} \
 #         == json.load(open("/opt/mcp-lab/etc/tools.lock")))'
     Expected output: True
     Regenerating tools.lock from the poisoned file would "pass" pinning and
     approve the attack. The checker compares the lock with the vendor
     release to catch that.

 Step 3 - Fix the policy.
 # cat > /opt/mcp-lab/etc/policy.json <<'EOF'
 {
   "working_dir": "/opt/mcp-lab/workspace",
   "allowed_roots": ["/opt/mcp-lab/workspace"],
   "tools_manifest": "/opt/mcp-lab/etc/tools.json",
   "tools_lock": "/opt/mcp-lab/etc/tools.lock",
   "enforce_tool_pinning": true,
   "tool_policy": {
     "read_file": "auto",
     "list_dir": "auto",
     "delete_file": "approve"
   },
   "audit_log": "/opt/mcp-lab/log/audit.jsonl",
   "max_read_bytes": 65536
 }
 EOF
 # python3 -m json.tool /opt/mcp-lab/etc/policy.json >/dev/null && echo valid
     - allowed_roots: least privilege. The server resolves every path with
       realpath before the containment check, so "../secrets" and the
       link-to-secrets symlink both land outside the root and get refused.
       A string-prefix check would miss the symlink.
     - delete_file "approve": the spec says a human SHOULD be able to deny
       tool invocations. Destructive actions stay behind a confirmation
       whatever the tool's own annotations claim.
     - audit_log: the server creates it with O_CREAT and mode 0600, and it
       logs every allowed, denied and error decision. It records the call
       arguments but never the credential.

 Step 4 - Verify by hand.
 # python3 /opt/mcp-lab/bin/mcpclient.py call read_file '{"path":"notes.txt"}'
     "isError": false, the text contains "Runbook: rotate application logs..."
 # python3 /opt/mcp-lab/bin/mcpclient.py call read_file '{"path":"../secrets/upstream.token"}'
     "isError": true, "path outside allowed roots: ../secrets/upstream.token"
 # python3 /opt/mcp-lab/bin/mcpclient.py call read_file '{"path":"link-to-secrets/upstream.token"}'
     "isError": true, "path outside allowed roots: link-to-secrets/upstream.token"
 # python3 /opt/mcp-lab/bin/mcpclient.py call delete_file '{"path":"scratch.txt"}'
     "isError": true, "tool 'delete_file' requires human approval; call refused"
 # tail -n 3 /opt/mcp-lab/log/audit.jsonl
     {"arguments": {"path": "scratch.txt"}, "decision": "denied", "event": "tools/call", ...}
 # stat -c '%a %U' /opt/mcp-lab/log/audit.jsonl
     600 root

 Step 5 - Grade.
 # sudo bash mcpa-4.3-break-fix.sh check
     Every line reads [PASS], then "... checks passed" and "Lab solved: ...".

 Takeaways for the exam
 - Tool metadata (description, inputSchema, annotations) is untrusted input
   to the model. Pin it, review changes, and re-approve before serving.
 - Annotations such as readOnlyHint and destructiveHint are hints, not
   controls. Enforce policy in the server/host, not in what a tool says
   about itself.
 - Scope filesystem access to explicit roots and resolve symlinks before
   checking containment.
 - Put destructive tools behind human-in-the-loop approval.
 - Keep credentials out of argv and logs. Use 0600 env files or a secret
   store, and rotate anything that was exposed.
 - Audit every decision. You cannot investigate what you never recorded.
 - A fix that denies everything breaks the service. The legitimate path
   must keep working.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/mcpa/4.3/lab)
