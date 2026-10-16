## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
============================  SOLUTION  =====================================
Stop here unless you have already fought `verify` at least twice.

STEP 0 — read the failure, do not guess
  $ kubectl run demo --image=busybox:1.36 -n kca-lab \
      --labels=kca.example.com/team=platform --dry-run=server --command -- sleep 3600

  Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

  resource Pod/kca-lab/demo was blocked due to the following policies

  kca-5-7-team-registry:
    pod-team-must-be-registered: 'failed to load context: failed to fetch data for
      APICall: failed to execute APICall: teams.kca.example.com is forbidden: User
      "system:serviceaccount:kyverno:kyverno-admission-controller" cannot list
      resource "teams" in API group "kca.example.com" at the cluster scope'

  Three facts are already in that string:
    - the subject is the Kyverno admission controller SA, not your user;
    - the verb is list, the resource is teams in group kca.example.com;
    - the webhook is *-fail, i.e. failurePolicy: Fail, which is why a broken
      context blocks the request instead of silently allowing it. That is the
      correct default for a security control: fail closed.

  Confirm it with SubjectAccessReview impersonation:
    $ kubectl auth can-i list teams.kca.example.com \
        --as=system:serviceaccount:kyverno:kyverno-admission-controller
    no

STEP 1 — FAULT 1: grant the API call the RBAC it needs (aggregated ClusterRole)
  Kyverno 1.10+ splits its permissions across four controllers, and each one
  has an aggregated ClusterRole you extend by LABEL, never by editing the
  shipped roles (they are reconciled/overwritten on upgrade):

    rbac.kyverno.io/aggregate-to-admission-controller   -> apiCall at admission time
    rbac.kyverno.io/aggregate-to-background-controller  -> background scans, generate/mutateExisting
    rbac.kyverno.io/aggregate-to-reports-controller     -> PolicyReports
    rbac.kyverno.io/aggregate-to-cleanup-controller     -> cleanup policies

  Inspect the aggregation rule you are targeting:
    $ kubectl get clusterrole kyverno:admission-controller -o jsonpath='{.aggregationRule}{"\n"}'
    {"clusterRoleSelectors":[{"matchLabels":{"rbac.kyverno.io/aggregate-to-admission-controller":"true"}}]}

  Our policy has background: false, so ONLY the admission controller performs
  the call. If you ever set background: true (or add a generate rule), add the
  background-controller label too, otherwise background scans fail while
  admission works — a classic half-fixed state.

  cat <<'EOF' | kubectl apply -f -
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRole
  metadata:
    name: kca-lab-kyverno-teams-reader
    labels:
      rbac.kyverno.io/aggregate-to-admission-controller: "true"
      rbac.kyverno.io/aggregate-to-background-controller: "true"
      kca.example.com/lab: "5.7"
  rules:
    - apiGroups: ["kca.example.com"]
      resources: ["teams"]
      verbs: ["get", "list", "watch"]
  EOF

  No RoleBinding is required: the ClusterRole is absorbed by aggregation into
  kyverno:admission-controller, which is already bound to the ServiceAccount.
  Verify (aggregation is reconciled by kube-controller-manager, allow a few
  seconds; the Kyverno API client picks it up on the next call):

    $ kubectl auth can-i list teams.kca.example.com \
        --as=system:serviceaccount:kyverno:kyverno-admission-controller
    yes

STEP 2 — FAULT 2: the JMESPath filter compares a boolean with a string
  Retry the Pod. New error, new layer:

    resource Pod/kca-lab/demo was blocked due to the following policies
    kca-5-7-team-registry:
      pod-team-must-be-registered: 'validation error: Pod label
        kca.example.com/team must name a registered active Team. Got
        ''platform''. Registered active teams: []'

  'Registered active teams: []' is the tell: RBAC is fine, the expression is
  wrong. spec.active is a JSON boolean; 'true' is a string. In JMESPath a
  literal is written between backticks, so `true` is the boolean and 'true'
  is text. They never compare equal.

  Reproduce it offline with the Kyverno CLI (kubectl kyverno jp query):
    $ kubectl get teams -o json | kubectl kyverno jp query "items[?spec.active=='true'].metadata.name"
    []
    $ kubectl get teams -o json | kubectl kyverno jp query "items[?spec.active==\`true\`].metadata.name"
    [
      "payments",
      "platform"
    ]
    $ kubectl get teams -o json | kubectl kyverno jp query "items[?spec.active].metadata.name"
    [
      "payments",
      "platform"
    ]

  Both fixed forms are correct. `items[?spec.active]` relies on JMESPath
  truthiness; `== \`true\`` is explicit and survives a schema change from
  boolean to something else more visibly. Prefer the explicit one in policy.

STEP 3 — FAULT 3: give the label lookup a default
  Now a labelled Pod is admitted and 'ghost'/'legacy' are denied. But:

    $ kubectl run nolabel --image=busybox:1.36 -n kca-lab --dry-run=server --command -- sleep 3600
    Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
    ... failed to substitute variables in deny conditions: ... variable
    request.object.metadata.labels."kca.example.com/team" not resolved at path ...

  The Pod is blocked, so the cluster is still safe — but the operator gets a
  Kyverno internal error instead of the actionable message, and an auditor
  reading PolicyReports sees 'error', not 'fail'. Declare the default once, as
  a context variable, and reference it everywhere.

  Note also the quoting rule: label keys contain dots and slashes, so the
  JMESPath segment MUST be double quoted -> labels."kca.example.com/team".
  Without the quotes JMESPath parses it as nested fields and the policy fails
  validation or resolves to null.

STEP 4 — the corrected policy, in full
  cat <<'EOF' | kubectl apply -f -
  apiVersion: kyverno.io/v1
  kind: ClusterPolicy
  metadata:
    name: kca-5-7-team-registry
    labels:
      kca.example.com/lab: "5.7"
    annotations:
      policies.kyverno.io/title: Pods must reference a registered, active Team
      policies.kyverno.io/category: Governance
      policies.kyverno.io/subject: Pod
  spec:
    validationFailureAction: Enforce     # Kyverno <= 1.12
    background: false                    # only the admission controller calls the API
    rules:
      - name: pod-team-must-be-registered
        match:
          any:
            - resources:
                kinds:
                  - Pod
                namespaces:
                  - kca-lab
        context:
          # 1) external data: the live registry, read at admission time
          - name: activeteams
            apiCall:
              urlPath: "/apis/kca.example.com/v1alpha1/teams"
              jmesPath: "items[?spec.active==`true`].metadata.name"
          # 2) local variable with an explicit default -> never resolves to null
          - name: team
            variable:
              jmesPath: 'request.object.metadata.labels."kca.example.com/team"'
              default: ""
        validate:
          # failureAction: Enforce      # Kyverno >= 1.13 puts it here instead
          message: >-
            Pod label kca.example.com/team must name a registered active Team.
            Got '{{ team }}'. Registered active teams: {{ activeteams }}
          deny:
            conditions:
              all:
                - key: "{{ team }}"
                  operator: AnyNotIn
                  value: "{{ activeteams }}"
  EOF

  $ kubectl wait --for=condition=Ready clusterpolicy/kca-5-7-team-registry --timeout=60s
  clusterpolicy.kyverno.io/kca-5-7-team-registry condition met

STEP 5 — prove the four behaviours by hand
  $ kubectl run ok --image=busybox:1.36 -n kca-lab \
      --labels=kca.example.com/team=platform --dry-run=server --command -- sleep 3600
  pod/ok created (server dry run)

  $ kubectl run ghost --image=busybox:1.36 -n kca-lab \
      --labels=kca.example.com/team=ghost --dry-run=server --command -- sleep 3600
  Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
  ... validation error: Pod label kca.example.com/team must name a registered
  active Team. Got 'ghost'. Registered active teams: ["payments","platform"]

  $ kubectl run legacy --image=busybox:1.36 -n kca-lab \
      --labels=kca.example.com/team=legacy --dry-run=server --command -- sleep 3600
  ... Got 'legacy'. Registered active teams: ["payments","platform"]

  $ kubectl run nolabel --image=busybox:1.36 -n kca-lab --dry-run=server --command -- sleep 3600
  ... Got ''. Registered active teams: ["payments","platform"]

  Liveness of the registry — no policy edit involved:
  $ kubectl apply -f - <<'EOF'
  apiVersion: kca.example.com/v1alpha1
  kind: Team
  metadata: {name: sre}
  spec: {displayName: SRE, active: true}
  EOF
  $ kubectl run sre --image=busybox:1.36 -n kca-lab \
      --labels=kca.example.com/team=sre --dry-run=server --command -- sleep 3600
  pod/sre created (server dry run)

  $ ./kca-5.7-break-fix.sh verify
  [+] PASS  policy still resolves the team registry through an apiCall context
  [+] PASS  Pod with kca.example.com/team=platform is admitted
  [+] PASS  Pod with an unregistered team is denied by the policy
  [+] PASS  Pod with an inactive Team (legacy) is denied
  [+] PASS  Pod without a team label is denied with the policy's own message
  [+] PASS  a newly created active Team is honoured without editing the policy
  ALL 6 CHECKS PASSED — topic 5.7 mastered.

STEP 6 — what to carry into the exam and into production
  * apiCall permissions belong to the controller that runs the rule. Admission
    rules -> aggregate-to-admission-controller. background: true, generate or
    mutateExisting -> aggregate-to-background-controller as well. Extend by
    labelled ClusterRole, never by editing kyverno:* roles.
  * failurePolicy: Fail means every context error is an outage. Treat urlPath,
    jmesPath and RBAC as production code: an apiCall that 404s or 403s takes
    the namespace down with it.
  * JMESPath literals need backticks: `true`, `false`, `10`, `"str"`.
    Single quotes are raw strings. This one-character difference is the most
    common silent bug in KCA policy questions, and it fails CLOSED here only
    because the operator is AnyNotIn — with AnyIn the same bug would fail OPEN
    and admit everything. Always ask which way your expression degrades.
  * Label keys with dots/slashes must be double quoted inside JMESPath.
  * Every variable that may be absent needs a default (context variable
    `default:`) or an inline `|| ''`; otherwise the rule errors instead of
    denying, and your PolicyReports fill with 'error' instead of 'fail'.
  * Cost: an apiCall runs on every matching AdmissionReview. For hot paths
    prefer a ConfigMap context, or a cached global context entry
    (GlobalContextEntry, Kyverno 1.11+), instead of hitting the API server.
  * Test expressions with `kubectl kyverno jp query` and rules with
    `kubectl kyverno test` / `kubectl kyverno apply` before they reach a
    cluster whose webhook is fail-closed.

  Sources: https://kyverno.io/docs/writing-policies/external-data-sources/
           https://kyverno.io/docs/writing-policies/variables/
           https://kyverno.io/docs/writing-policies/jmespath/
           https://kyverno.io/docs/installation/customization/
           https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles
           https://jmespath.org/specification.html
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/kca/5.7/lab)
