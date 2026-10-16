## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
=== SOLUTION START ==========================================================

 STEP-BY-STEP SOLUTION — do not read until you have tried `verify`

 STEP 0 — Read the machine, not the dashboard
   kubectl -n argocd get application guestbook
   kubectl -n argocd get application guestbook -o json | jq '.status.conditions'
   kubectl -n argocd logs deploy/argocd-repo-server --tail=100
   kubectl -n argocd logs statefulset/argocd-application-controller --tail=100

   `.status.conditions` is the single most useful field in the Application CR:
   ComparisonError means "I could not build the desired state"; InvalidSpecError
   means "your spec is not allowed"; SyncError means "I tried and the API server
   said no". They are produced by different components, so they send you to
   different logs. (Ref: https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/)


 STEP 1 — SOURCE: make the desired state resolvable
   Observed:
     ComparisonError: ... Unable to resolve 'release-42' to a commit SHA
     (and, once the revision is fixed) app path does not exist: kustomize-guestbok

   Confirm from outside Argo CD which refs and paths actually exist:
     git ls-remote --heads https://github.com/argoproj/argocd-example-apps.git
     git clone --depth 1 https://github.com/argoproj/argocd-example-apps.git /tmp/ex && ls /tmp/ex

   Repair:
     kubectl -n argocd patch application guestbook --type merge -p '{
       "spec": { "source": { "targetRevision": "HEAD", "path": "kustomize-guestbook" } }
     }'

     # argocd CLI equivalent:
     # argocd app set guestbook --revision HEAD --path kustomize-guestbook

   Verify:
     kubectl -n argocd get app guestbook -o jsonpath='{.status.sync.revision}{"\n"}'
     # -> a 40-char commit SHA. Empty means it still did not render.

   Why it matters: `targetRevision` is the contract between Git and the cluster.
   A branch name is a moving target (continuous delivery of whatever lands), a
   tag or SHA is an immutable pin (auditable, reproducible rollback). In
   production, pin environments to tags/SHAs and promote by changing the pin —
   that promotion is itself a reviewable commit, which is the whole point of the
   OpenGitOps "declared, versioned and immutable" principle (https://opengitops.dev/).
   Flux equivalent: GitRepository .spec.ref.{branch,tag,semver,commit}; the same
   failure surfaces as a GitRepository whose Ready condition is False.


 STEP 2 — TENANCY: let the project permit this workload
   Observed:
     InvalidSpecError: application repo https://github.com/argoproj/argocd-example-apps.git
       is not permitted in project 'lab-restricted'
     InvalidSpecError: application destination ... is not permitted in project 'lab-restricted'

   Inspect the boundary before touching it:
     kubectl -n argocd get appproject lab-restricted -o yaml

   Preferred repair — widen the project, keep the boundary:
     kubectl -n argocd patch appproject lab-restricted --type merge -p '{
       "spec": {
         "sourceRepos": [
           "https://github.com/acme-internal/*",
           "https://github.com/argoproj/argocd-example-apps.git"
         ],
         "destinations": [
           { "namespace": "acme-prod",  "server": "https://kubernetes.default.svc" },
           { "namespace": "gitops-lab", "server": "https://kubernetes.default.svc" }
         ]
       }
     }'

     # argocd CLI equivalent:
     # argocd proj add-source lab-restricted https://github.com/argoproj/argocd-example-apps.git
     # argocd proj add-destination lab-restricted https://kubernetes.default.svc gitops-lab

   Acceptable alternative — move the app back to the default project:
     kubectl -n argocd patch application guestbook --type merge -p '{"spec":{"project":"default"}}'
     This clears the symptom but throws away the guardrail. Choose it only if the
     project was created by mistake; in a shared cluster it is the wrong answer.

   Why it matters: AppProject is Argo CD's tenancy primitive — it constrains
   which repos a tenant may deploy from, which cluster/namespace pairs they may
   write to, which cluster-scoped kinds they may create, and it carries the RBAC
   role bindings. `default` permits '*' everywhere, which is exactly why no
   production installation should leave workloads in it.
   Ref: https://argo-cd.readthedocs.io/en/stable/user-guide/projects/


 STEP 3 — DIFF: unmask the drift, then enforce it
   Observed: the Deployment reports Synced, yet:
     kubectl -n gitops-lab get deploy -o jsonpath='{.items[*].spec.replicas}'   -> 4
     argocd app manifests guestbook | grep -A1 replicas                          -> 1

   The two culprits, read them first:
     kubectl -n argocd get app guestbook -o jsonpath='{.spec.ignoreDifferences}' | jq .
     kubectl -n argocd get app guestbook -o jsonpath='{.spec.syncPolicy}' | jq .

   3a. Remove the diff mask (JSON-patch removal is the reliable form):
     kubectl -n argocd patch application guestbook --type json \
       -p '[{"op":"remove","path":"/spec/ignoreDifferences"}]'

     # merge-patch alternative:
     # kubectl -n argocd patch application guestbook --type merge -p '{"spec":{"ignoreDifferences":null}}'

     Immediately after this the app flips to OutOfSync — that is progress: the
     diff is now telling the truth.

   3b. Re-enable drift correction:
     kubectl -n argocd patch application guestbook --type merge -p '{
       "spec": { "syncPolicy": { "automated": { "prune": true, "selfHeal": true } } }
     }'

     # argocd CLI equivalent:
     # argocd app set guestbook --sync-policy automated --self-heal --auto-prune

   3c. Watch the controller — not you — undo the drift:
     kubectl -n gitops-lab get deploy -w        # replicas return to 1 within seconds

   Why it matters, and this is the exam-relevant nuance:
     * `automated: {}` alone syncs when the *desired* state changes (a new commit).
       It does NOT react to someone editing the cluster.
     * `selfHeal: true` is what makes the loop converge on cluster-side drift.
       Ref: https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
     * `ignoreDifferences` removes a field from the comparison entirely. An
       ignored field is never reported AND never self-healed — which is exactly
       what you want for fields owned by another controller (an HPA owning
       /spec/replicas, a webhook injecting sidecars) and exactly what you must
       never use to silence an inconvenient diff.
       Ref: https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/
     * The legitimate version of this pattern is HPA coexistence: ignore
       /spec/replicas *because* an HPA owns it, and document why. An undocumented
       ignoreDifferences is a lie encoded in YAML — grep for it during audits.


 STEP 4 — ACT: unblock the prune of the tracked orphan
   Observed: permanently OutOfSync, one resource with requiresPruning=true:
     kubectl -n argocd get app guestbook -o json \
       | jq '[.status.resources[] | select(.requiresPruning == true)]'

   Find out why it is attributed to the app and why prune is vetoed:
     kubectl -n gitops-lab get cm rogue-legacy-config -o jsonpath='{.metadata}' | jq .
     # labels:      app.kubernetes.io/instance: guestbook     <- makes Argo CD own it
     # annotations: argocd.argoproj.io/sync-options: Prune=false  <- forbids deletion

   Repair (pick one, deliberately):
     # (a) It is genuine leftover garbage — delete it:
     kubectl -n gitops-lab delete configmap rogue-legacy-config

     # (b) Let the controller prune it, which proves the loop works:
     kubectl -n gitops-lab annotate configmap rogue-legacy-config \
       argocd.argoproj.io/sync-options-
     argocd app sync guestbook --prune     # or wait for self-heal

     # (c) It must survive but is not Argo CD's business — untrack it:
     kubectl -n gitops-lab label configmap rogue-legacy-config app.kubernetes.io/instance-

   Why it matters:
     * Resource tracking: by default Argo CD claims resources carrying
       app.kubernetes.io/instance=<app>. That label is also used by Helm and by
       the common labels convention, which is why a hand-made object can be
       adopted by accident and then deleted by a prune. The safer production
       setting is annotation-based tracking:
         kubectl -n argocd patch cm argocd-cm --type merge \
           -p '{"data":{"application.resourceTrackingMethod":"annotation"}}'
       which uses argocd.argoproj.io/tracking-id and cannot collide with Helm.
       Ref: https://argo-cd.readthedocs.io/en/stable/user-guide/resource_tracking/
     * Sync options are per-resource vetoes over the controller's actions:
       Prune=false, Delete=false, Replace=true, ServerSideApply=true,
       SkipDryRunOnMissingResource=true, PruneLast=true. They are honoured even
       when only the live object carries them, so a stale annotation can freeze
       reconciliation indefinitely.
       Ref: https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
     * "Sync succeeded but still OutOfSync" is the signature of a skipped prune.
       Read .status.operationState.message before suspecting the controller.


 STEP 5 — Prove the loop, do not trust it
   ./cgoa-3.1-break-fix.sh verify

   Then attack it once more and watch it defend itself:
     kubectl -n gitops-lab scale deploy --all --replicas=7
     kubectl -n gitops-lab delete svc --all
     sleep 20 && kubectl -n gitops-lab get deploy,svc
     # Both must be restored by the controller, from Git, with no human action.

   That last test is the actual definition of GitOps compliance: the system's
   observed state converges to the declared state continuously and autonomously.
   Everything else in this lab was a way of breaking one of those four words.


 MAPPING TO FLUX (the exam covers both toolchains)
   Fault 1  SOURCE   -> GitRepository .spec.ref / .spec.url; `flux get sources git`
                       Ready=False with "failed to checkout and determine revision".
                       https://fluxcd.io/flux/components/source/gitrepositories/
   Fault 2  TENANCY  -> Kustomization .spec.serviceAccountName + RBAC, and
                       cross-namespace source refs disabled by the controller flag
                       --no-cross-namespace-refs. The boundary is Kubernetes RBAC
                       rather than an AppProject CR.
   Fault 3  DIFF     -> `flux diff kustomization`, .spec.force, and drift correction:
                       Flux re-applies on every interval, so drift is corrected by
                       default; the analogue of the mask is excluding paths or
                       setting .spec.suspend: true, which silences reconciliation
                       while the object still reports its last known state.
                       https://fluxcd.io/flux/components/kustomize/kustomizations/
   Fault 4  ACT      -> .spec.prune plus the kustomize.toolkit.fluxcd.io/prune: disabled
                       annotation, and the inventory that Flux keeps in the
                       Kustomization status (its equivalent of resource tracking).


 EXAM CHECKPOINTS COVERED (CGOA domain 3.1, 25%)
   * Argo CD Application CR anatomy: source / destination / project / syncPolicy.
   * Manifest formats and rendering: kustomize path + image overrides at the
     Application level. https://argo-cd.readthedocs.io/en/stable/user-guide/kustomize/
   * Automated sync vs. self-heal vs. prune — three orthogonal switches.
   * Diff customisation and its abuse; when ignoreDifferences is correct (HPA,
     mutating webhooks) and when it is a cover-up.
   * Resource tracking and ownership; label vs. annotation tracking methods.
   * Multi-tenancy via AppProject: sourceRepos, destinations, resource allow-lists.
   * Reading controller conditions and choosing the right component's logs.
   * Cascading deletion and the resources-finalizer.argoproj.io escape hatch.

=== SOLUTION END ============================================================
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cgoa/3.1/lab)
