## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 │  SOLUTION — step by step. Try the exercise before reading this.            │
 └──────────────────────────────────────────────────────────────────────────┘

 ROOT CAUSE
   Backstage validates every catalog entity against the descriptor schema
   BEFORE it enters the catalog. `metadata.name` is an *entity name* and must
   obey the naming rules: only [A-Za-z0-9], the separators [-_.], length ≤ 63,
   and it must start and end with an alphanumeric. Spaces and the pattern used
   ("Payments API Gateway") are invalid, so the parser raises an InputError and
   the entity is discarded — the location is processed, the file is read, but
   the entity is refused. That is why the portal is otherwise healthy yet this
   one component is simply absent.
   Docs: https://backstage.io/docs/features/software-catalog/descriptor-format
         https://backstage.io/docs/features/software-catalog/references

 STEP 1 — Read the backend log and locate the failing entity.
   The startup log names the offending location and value:
     backstage:catalog InputError: Malformed envelope, .metadata.name
     "Payments API Gateway" is not a valid entity name; expected a string that
     is sequences of [a-zA-Z0-9] separated by [-_.], at most 63 characters ...
   (If your app exposes it, the same error is visible in the UI under the
    component's INSPECT ▸ errors, or Catalog ▸ location health.)

 STEP 2 — Open the descriptor.
     $EDITOR examples/cnpa-5.3-lab/broken-entity.yaml

 STEP 3 — Fix metadata.name to a valid entity name (kebab-case is the norm):

     apiVersion: backstage.io/v1alpha1
     kind: Component
     metadata:
       name: payments-api-gateway        # <-- lowercase, hyphens, no spaces
       description: Public payments ingress — CNPA 5.3 lab component
       tags: [cnpa, lab]
       annotations:
         backstage.io/techdocs-ref: dir:.
     spec:
       type: service
       lifecycle: production
       owner: platform-team
       system: payments

   Keep the human-friendly label separate from the identifier if you want the
   UI to still read "Payments API Gateway":
       metadata:
         name: payments-api-gateway
         title: Payments API Gateway     # display-only, no character restriction

 STEP 4 — Let the catalog reprocess.
   The catalog re-reads locations on its refresh interval (default ~100s).
   To see it immediately, restart the backend so it reprocesses on startup:
       cd "$BACKSTAGE_DIR" && yarn start
   (If you registered via the dedicated file, restart with the same
    --config flags that break_fix.sh printed in the briefing.)

 STEP 5 — Verify.
     # UI: http://localhost:3000 → Catalog → search "payments" → the component
     #     "Payments API Gateway" (name payments-api-gateway) is now listed.
     # API:
     curl -s -o /dev/null -w '%{http_code}\n' \
       http://localhost:7007/api/catalog/entities/by-name/component/default/payments-api-gateway
     #   → 200
     # Or let the script judge it:
     ./break_fix.sh --check          # expect: FIXED 🎉

 STEP 6 — Tear down the lab when you are done.
     ./break_fix.sh --restore

 WHY THIS MATTERS FOR PLATFORM ADOPTION (the CNPA 5.3 lesson)
   A developer portal is only adopted if self-service onboarding "just works".
   The single most common reason a newly-registered service never appears is a
   descriptor that fails schema validation — an invalid name, a missing
   required spec field (type/lifecycle/owner for a Component), or an unknown
   apiVersion. As a platform engineer you (a) surface these errors where the
   developer will see them (location health / entity errors, not just backend
   logs), and (b) shift them left with CI validation on the catalog-info.yaml
   before merge — e.g. the Backstage CLI:
       npx @backstage/cli repo lint            # repo-wide checks
       # or a schema/CI step that rejects invalid catalog-info.yaml on PR.
   Config reference for static & discovered locations:
       https://backstage.io/docs/features/software-catalog/configuration
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpa/5.3/lab)
