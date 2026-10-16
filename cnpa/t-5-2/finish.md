## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 ▼▼▼  SOLUTION — step by step (read only after you have tried)  ▼▼▼

 ROOT CAUSE
   The provisioning API (CRD databases.platform.acme.io) had its `spec.tier`
   OpenAPI enum tightened from [standard, high-mem, gpu] to [high-mem, gpu].
   The service catalog (ServiceOffering/postgres-standard) still advertises
   tier=standard as the golden path. Catalog ↔ provisioning-API drift: the
   self-service contract the developer was told to follow no longer validates.
   Nothing is "down"; the API server correctly rejects an out-of-contract
   value. Existing Database objects with tier=standard are unaffected because
   enum validation runs on write, not on read.

 STEP 1 — Reproduce and read the error precisely.
     kubectl apply -f /tmp/cnpa-5.2-lab/golden-path-db.yaml \
       --as=system:serviceaccount:cnpa-lab:app-developer
   -> spec.tier: Unsupported value: "standard": supported values: "high-mem","gpu"
   The message names the field and the accepted set: this is schema validation.

 STEP 2 — Rule out RBAC (a common misdiagnosis for "can't create").
     kubectl auth can-i create databases -n cnpa-lab \
       --as=system:serviceaccount:cnpa-lab:app-developer      # -> yes
   Authorization is fine; the request is rejected at *validation/admission*.

 STEP 3 — Inspect the live API contract (the CRD is the source of truth).
     kubectl explain database.spec.tier
     kubectl get crd databases.platform.acme.io \
       -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.tier.enum}{"\n"}'
   -> ["high-mem","gpu"]   (note: "standard" is gone)

 STEP 4 — Compare against what the catalog advertises.
     kubectl get serviceoffering postgres-standard -o yaml
   -> spec.tier: standard, spec.golden: true
   Drift confirmed: the catalog promises a tier the provisioning API refuses.
   (In Crossplane terms: the XRD schema was changed under a live claim shape.)

 STEP 5 — Decide the correct reconciliation.
   Two legitimate directions; pick by intent:
     (A) The 'standard' tier is still valid  -> the CRD change was a regression.
         Restore the contract (preferred here, matches the objective):
           kubectl patch crd databases.platform.acme.io --type=json -p \
             '[{"op":"replace",
                "path":"/spec/versions/0/schema/openAPIV3Schema/properties/spec/properties/tier/enum",
                "value":["standard","high-mem","gpu"]}]'
     (B) 'standard' is genuinely being deprecated -> then the *catalog* and all
         consumers must be migrated first, and the API bumped to a NEW version
         (v1alpha2) with a conversion webhook — never dropped in place under a
         live golden path. Update ServiceOffering/postgres-standard (or retire
         it) BEFORE removing the enum value, so the catalog never advertises an
         offering the API cannot fulfil.
   Because the objective is "restore the advertised golden path", use (A).

 STEP 6 — Verify end-to-end as the developer.
     kubectl apply -f /tmp/cnpa-5.2-lab/golden-path-db.yaml \
       --as=system:serviceaccount:cnpa-lab:app-developer
     kubectl get databases -n cnpa-lab
   orders-db is created; self-service through the platform API is restored.
   (Equivalent: ./this-script.sh verify  -> PASS)

 STEP 7 — Prevent recurrence (platform-engineering guardrails).
   * Treat CRD/XRD schema edits as API-breaking. Do additive-only changes;
     remove fields/enum values only across a version bump + conversion webhook.
     https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#versions-in-customresourcedefinitions
   * Gate every CRD change in CI with `kubectl diff` and a policy check that
     asserts: for each golden ServiceOffering, its tier ∈ Database.spec.tier
     enum — so catalog/provisioning drift fails the pipeline, not the developer.
   * Enforce it in-cluster with a ValidatingAdmissionPolicy (CEL) that blocks
     shrinking the enum of a served CRD version.
     https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
   * Manage CRDs/XRDs via GitOps so the schema is declarative and drift like
     this is auto-reverted (and reviewed) instead of hand-patched in prod.
   * Crossplane analog: the XRD is the contract for every Claim/XR; evolve it
     additively and version it — an in-place breaking edit rejects new claims
     exactly as seen here.
     https://docs.crossplane.io/latest/concepts/composite-resource-definitions/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpa/5.2/lab)
