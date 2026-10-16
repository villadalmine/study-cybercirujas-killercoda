## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — full walkthrough (do not read until you have tried it yourself)

 STEP 1 — Confirm the symptom precisely.
   Applying a valid object fails; an invalid one succeeds:

     $ kubectl apply -f valid.yaml
     The LabApp "demo" is invalid: spec: Invalid value: "object":
       minReplicas must be less than or equal to maxReplicas

   The types are correct (the apiserver got as far as running CEL), so the fault
   is in a validation rule, not in the OpenAPI schema.

 STEP 2 — Read the actual expressions, not just the messages.

     $ kubectl get crd labapps.training.kca.local -o yaml | grep -n -A2 x-kubernetes-validations
       x-kubernetes-validations:
       - message: minReplicas must be less than or equal to maxReplicas
         rule: self.minReplicas >= self.maxReplicas       <-- CONTRADICTS its own message
       - message: replicas must be within the range [minReplicas, maxReplicas]
         rule: self.replicas >= self.minReplicas && self.replicas <= self.maxReplicas

   The message says "<=" but the rule enforces ">=". A CEL `rule` is the CONDITION
   that must evaluate to TRUE for the object to be admitted. So this rule only admits
   objects where minReplicas >= maxReplicas — the exact opposite of the intent, which
   is why 2>=5 (false) is rejected and 5>=2 (true) is accepted. The second rule is fine.

 STEP 3 — Fix the operator. Either edit in place:

     $ kubectl edit crd labapps.training.kca.local
     # change:  rule: self.minReplicas >= self.maxReplicas
     # to:      rule: self.minReplicas <= self.maxReplicas

   ...or re-apply the corrected manifest (idempotent):

     kubectl apply -f - <<'EOF'
     apiVersion: apiextensions.k8s.io/v1
     kind: CustomResourceDefinition
     metadata:
       name: labapps.training.kca.local
     spec:
       group: training.kca.local
       scope: Namespaced
       names: { kind: LabApp, plural: labapps, singular: labapp, shortNames: ["la"] }
       versions:
         - name: v1
           served: true
           storage: true
           schema:
             openAPIV3Schema:
               type: object
               properties:
                 spec:
                   type: object
                   required: ["image","replicas","minReplicas","maxReplicas"]
                   properties:
                     image:       { type: string }
                     replicas:    { type: integer, minimum: 0 }
                     minReplicas: { type: integer, minimum: 0 }
                     maxReplicas: { type: integer, minimum: 0 }
                   x-kubernetes-validations:
                     - rule: "self.minReplicas <= self.maxReplicas"          # FIXED
                       message: "minReplicas must be less than or equal to maxReplicas"
                     - rule: "self.replicas >= self.minReplicas && self.replicas <= self.maxReplicas"
                       message: "replicas must be within the range [minReplicas, maxReplicas]"
     EOF

   CEL rules are recompiled by the apiserver the moment the CRD is saved — there is
   nothing to restart. Existing stored objects are only re-checked on their next write.

 STEP 4 — Prove BOTH directions (this is exactly what `verify` automates):

     $ kubectl -n kca-lab-51 apply -f valid.yaml      # min=2,max=5
     labapp.training.kca.local/demo created            # accepted  ✅

     $ kubectl -n kca-lab-51 apply -f invalid.yaml    # min=5,max=2
     The LabApp "bad" is invalid: spec: Invalid value: "object":
       minReplicas must be less than or equal to maxReplicas   # rejected ✅

 WHY THIS MATTERS / EXAM TAKEAWAYS
   * A CEL `rule` is a REQUIREMENT the object must satisfy, expressed as a boolean over
     `self`. If it reads false, the write is denied. "Enforce X" means "rule: X".
   * The `message` (or `messageExpression`) is documentation shown to the user — the
     apiserver does NOT check that it agrees with the rule. A mismatch between the two
     is the classic tell of an inverted or wrong expression, so read the rule, never
     trust the message.
   * Validation rules can fail SAFE (reject good input) or fail OPEN (admit bad input).
     Always test both a passing and a failing sample; a rule that rejects everything and
     a rule that accepts everything can look identical from a single test.
   * Related knobs to know for KCA 5.1: `optionalOldSelf`/transition rules (compare
     `self` to `oldSelf` on UPDATE), `messageExpression`, `reason`, `fieldPath`, the
     per-rule cost budget, and how CRD `x-kubernetes-validations` differs from a
     ValidatingAdmissionPolicy (cluster-wide CEL admission, also GA and CEL-based).
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/kca/5.1/lab)
