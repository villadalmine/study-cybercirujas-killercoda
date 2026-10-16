## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION - stop here if you have not tried the diagnosis yet

 Set the lab root once:

    LAB=/opt/mcpa-lab/5.1-roles-adoption      # or your MCPA_LAB_ROOT

 STEP 0 - read the evidence before changing anything
 The gate tells you WHAT is wrong; these four files tell you what the correct
 value is. None of them may be edited - they are the record.

    cat "$LAB/governance/reviews/SR-2291.json"
    cat "$LAB/governance/adoption-requests/finance-ops.json"
    cat "$LAB/platform/handovers/2026-08-31-team-atlas-legacy-dissolved.md"
    cat "$LAB/governance/policy.json"

 From them:
    finance-ops : maintainer team-fin-integrations, risk tier high (SR-2291),
                  transport stdio, data restricted, approved for atlas-desk,
                  version 1.4.0, reviewer team-secops / M. Okonjo,
                  conditions: per-call consent, no sampling,
                  transfer_funds readOnlyHint=false destructiveHint=true
    wiki-reader : owner moves from team-atlas-legacy to team-knowledge
    policy      : high -> per-call, approver role security-reviewer,
                  approver must differ from maintainer

 STEP 1 - PLATFORM TEAM: create the adoption record that was never created
 Fixes G1 (and the host refusal, indirectly: the allowlist is derived from
 this file). Note that the platform team does not decide the risk tier - it
 copies the tier the security review assigned.

    python3 - <<'PY'
    import json, pathlib
    root = pathlib.Path("/opt/mcpa-lab/5.1-roles-adoption")
    p = root / "platform/registry.json"
    d = json.loads(p.read_text())
    ids = [s["id"] for s in d["servers"]]
    if "finance-ops" not in ids:
        d["servers"].append({
            "id": "finance-ops",
            "maintainer": "team-fin-integrations",
            "owner": "team-fin-integrations",
            "risk_tier": "high",
            "transport": "stdio",
            "data_classification": "restricted",
            "approval": "SR-2291",
            "adopted_on": "2026-09-17"
        })
    p.write_text(json.dumps(d, indent=2) + "\n")
    PY

 STEP 2 - SECURITY REVIEWER: file the approval from the review of record
 Fixes G3. The defect was not a typo: the maintainer of the server signed its
 own approval. The correct approval is a transcription of SR-2291, whose
 reviewer is team-secops. Nothing about the server changes - only who says it
 is acceptable, which is the entire point of separation of duties.

    python3 - <<'PY'
    import json, pathlib
    root = pathlib.Path("/opt/mcpa-lab/5.1-roles-adoption")
    review = json.loads((root / "governance/reviews/SR-2291.json").read_text())
    approval = {
        "schema": "mcp.approval/v1",
        "server": review["server"],
        "server_version": review["server_version"],
        "risk_tier": review["risk_tier"],
        "decision": review["decision"],
        "review": review["id"],
        "approver": dict(review["reviewer"]),
        "approved_on": review["completed_on"],
        "scope": {"hosts": ["atlas-desk"], "consent": "per-call"}
    }
    (root / "governance/approvals/finance-ops.json").write_text(
        json.dumps(approval, indent=2) + "\n")
    PY

 STEP 3 - SERVICE OWNER / PLATFORM: give wiki-reader an owner that exists
 Fixes G2. team-atlas-legacy was dissolved on 2026-08-31 and its pager deleted;
 the handover note assigns wiki-reader to team-knowledge. Do NOT re-add the
 dead team to platform/teams.json - that is inventing an owner, and the file is
 checksummed for exactly that reason.

    python3 - <<'PY'
    import json, pathlib
    root = pathlib.Path("/opt/mcpa-lab/5.1-roles-adoption")
    p = root / "platform/registry.json"
    d = json.loads(p.read_text())
    for s in d["servers"]:
        if s["id"] == "wiki-reader":
            s["owner"] = "team-knowledge"
    p.write_text(json.dumps(d, indent=2) + "\n")
    PY

 STEP 4 - HOST APPLICATION OWNER: restore the consent surface
 Fixes G4. The host, not the server, owns what the user is asked to approve.
 Policy maps risk tier high to per-call consent, and SR-2291 states it as a
 condition of approval. auto-approve on a server carrying transfer_funds means
 the model can move money with no human in the loop.

    python3 - <<'PY'
    import json, pathlib
    root = pathlib.Path("/opt/mcpa-lab/5.1-roles-adoption")
    p = root / "hosts/atlas-desk/mcp.json"
    d = json.loads(p.read_text())
    d["mcpServers"]["finance-ops"]["consent"] = "per-call"
    d["mcpServers"]["finance-ops"]["sampling"] = "deny"
    p.write_text(json.dumps(d, indent=2) + "\n")
    PY

 STEP 5 - SERVER MAINTAINER: make the annotations true
 Fixes G5. readOnlyHint and destructiveHint are the only signal the host has
 for rendering a consent prompt. A destructive tool annotated read-only makes
 every host downstream silently wrong, including hosts you do not operate.

    python3 - <<'PY'
    import json, pathlib
    root = pathlib.Path("/opt/mcpa-lab/5.1-roles-adoption")
    p = root / "servers/finance-ops/tools.json"
    d = json.loads(p.read_text())
    for t in d["tools"]:
        if t["name"] == "transfer_funds":
            t["annotations"]["readOnlyHint"] = False
            t["annotations"]["destructiveHint"] = True
            t["annotations"]["idempotentHint"] = False
            t["annotations"]["openWorldHint"] = False
    p.write_text(json.dumps(d, indent=2) + "\n")
    PY

 STEP 6 - PLATFORM TEAM: re-derive the allowlist
 Fixes G6 and clears the original symptom. The allowlist is generated from the
 registry plus valid approvals; the sync tool refuses anything that still has
 an approval problem, which is why steps 1 and 2 had to come first.

    python3 "$LAB/bin/mcp-sync-allowlist"
        allowlist written: finance-ops, wiki-reader

 STEP 7 - verify
    python3 "$LAB/bin/mcp-adoption-gate"     # expect: adoption gate: PASS
    python3 "$LAB/bin/mcp-host-sim"          # expect: all 2 declared servers connected
    ./mcpa-5.1-break-fix.sh verify           # expect: SOLVED

 Expected host output after the fix (abbreviated):
    [host atlas-desk] client #1 -> server 'finance-ops' over stdio
    [host atlas-desk]   -> {"jsonrpc":"2.0","id":1,"method":"initialize",...}
    [host atlas-desk]   <- {"jsonrpc":"2.0","id":1,"result":{...,"serverInfo":{"name":"finance-ops","version":"1.4.0"}}}
    [host atlas-desk]   connected: owner=team-fin-integrations tier=high consent=per-call
    [host atlas-desk]   tools/list: transfer_funds  readOnlyHint=False destructiveHint=True -> consent prompt: per-call

 WHAT THIS TEACHES, AND THE TRAPS
 * The visible symptom (one refused connection) had five causes owned by five
   roles. Fixing only the allowlist would have "restored service" while
   shipping an unreviewed, auto-approved, mislabelled money-moving tool. That
   is the failure mode this domain exists to prevent.
 * Trap 1: editing platform/allowlist.json by hand. It is derived state; the
   gate recomputes the expected value and the change is reverted by the next
   sync run.
 * Trap 2: adding team-atlas-legacy back to platform/teams.json. Ownership is
   a claim about who answers the pager, not a string that must resolve.
 * Trap 3: deleting finance-ops from the host config. G7 catches it: an
   approved adoption request that is not deployed is an unfinished adoption,
   not a clean state.
 * Trap 4: editing governance/policy.json or bin/mcp-adoption-gate. The
   checksum manifest catches it. Whoever is blocked by a control is never the
   role that may change it.
 * Order matters: the allowlist can only be re-derived after the registry
   entry and the approval exist. Real adoption pipelines have the same
   dependency, which is why "just restart it" does not work here either.

 Further reading:
   https://modelcontextprotocol.io/specification/2025-06-18/architecture
   https://modelcontextprotocol.io/specification/2025-06-18/server/tools
   https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices
   https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/mcpa/5.1/lab)
