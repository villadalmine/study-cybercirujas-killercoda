## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
=========================  SOLUTION — STOP READING  =========================

Everything below is the worked solution with the output you should expect at
each step. Do not read it before you have driven `verify` yourself at least
once. Commands are shown for namespace cnpa-lab-11 with the repository at
$CNPA_LAB_HOME/gitops (default ~/cnpa-lab-1.1/gitops).

STEP 0 — Read the cluster before you change it

  $ kubectl -n cnpa-lab-11 get deploy,pods,cm
  NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
  deployment.apps/checkout-api   0/6     6            0           2m

  NAME                                READY   STATUS                       RESTARTS   AGE
  pod/checkout-api-77b4c8c9c5-4hnzq   0/1     CreateContainerConfigError   0          2m
  ... (6 pods, all identical)

  No ConfigMap is listed. Three independent facts already contradict git:
  six replicas instead of two, zero Ready, and a missing ConfigMap.

  $ kubectl -n cnpa-lab-11 describe pod -l app.kubernetes.io/name=checkout-api | tail -4
    Warning  Failed     kubelet  Error: configmap "checkout-api-config" not found

  The pods are a SYMPTOM. `envFrom.configMapRef` is a hard dependency: the
  kubelet refuses to create the container until the ConfigMap resolves. Fix
  the ConfigMap and the pods heal themselves — there is nothing wrong with
  the Deployment's runtime.

STEP 1 — FAULT C: why does the ConfigMap keep disappearing?

  Watch it die. In one terminal:

    $ kubectl -n cnpa-lab-11 get cm --watch

  In another:

    $ kubectl apply -f ~/cnpa-lab-1.1/gitops/10-configmap.yaml
    configmap/checkout-api-config created

  The watcher shows the object appear and then, within a few seconds:

    checkout-api-config   3      6s
    checkout-api-config   3      11s        <- DELETED

  Nothing in the event stream explains it:

    $ kubectl -n cnpa-lab-11 get events --sort-by=.lastTimestamp | grep -i configmap
    (no output)

  Garbage collection does not emit Events on the dependent. The evidence is
  on the object itself — you have to be fast, or ask for it at create time:

    $ kubectl apply -f ~/cnpa-lab-1.1/gitops/10-configmap.yaml -o json \
        | jq '.metadata.ownerReferences'
    [
      {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "name": "platform-bootstrap-config",
        "uid": "deadbeef-0000-4000-8000-000000000000",
        "controller": false,
        "blockOwnerDeletion": false
      }
    ]

    $ kubectl -n cnpa-lab-11 get cm platform-bootstrap-config
    Error from server (NotFound): configmaps "platform-bootstrap-config" not found

  That is the whole mechanism. The garbage collector resolves each
  ownerReference by apiVersion/kind/name and compares the stored UID against
  the live one. Owner absent (or UID mismatch, which is why deleting and
  recreating an owner orphans its old dependents) => the dependent is
  deleted. `blockOwnerDeletion: false` and `controller: false` change
  nothing here; they govern foreground deletion and controller adoption, not
  whether the sweep happens.

  The decisive question is WHERE the ownerReference came from. It is not a
  live-only mutation:

    $ grep -n -A6 ownerReferences ~/cnpa-lab-1.1/gitops/10-configmap.yaml
    8:  ownerReferences:
    9:    - apiVersion: v1
    ...

  The bad desired state is committed. This is the classic way it happens in
  real platforms: somebody ran `kubectl get -o yaml` on an operator-generated
  object, pasted the result into the repo, and shipped the operator's
  ownership metadata along with it. Patching the cluster would be undone by
  the very next reconcile.

  FIX — repair the source of truth, then re-apply:

    $ cd ~/cnpa-lab-1.1
    $ python3 - <<'PY'
    import re, pathlib
    p = pathlib.Path("gitops/10-configmap.yaml")
    s = p.read_text()
    s = re.sub(r"\n  ownerReferences:\n(?:    .*\n| *- .*\n)+", "\n", s)
    p.write_text(s)
    PY

  (or simply delete the ownerReferences block with your editor — the point is
  that the file, not the API object, is what must change.)

    $ grep -c ownerReferences gitops/10-configmap.yaml
    0
    $ kubectl apply --server-side --field-manager=gitops -f gitops/10-configmap.yaml
    configmap/checkout-api-config serverside-applied
    $ sleep 20 && kubectl -n cnpa-lab-11 get cm checkout-api-config
    NAME                  DATA   AGE
    checkout-api-config   3      20s

  It survives, because the recreated object carries no ownerReferences at all.
  Note the trap: if a stale copy WITH the ownerReference were still live,
  applying a manifest without it would not remove it — ownerReferences is an
  atomic list owned by whoever set it. In that situation you strip it
  explicitly:

    $ kubectl -n cnpa-lab-11 patch cm checkout-api-config --type=json \
        -p '[{"op":"remove","path":"/metadata/ownerReferences"}]'

STEP 2 — FAULT A: why does apply not remove what git removed?

    $ kubectl apply -f ~/cnpa-lab-1.1/gitops/20-deployment.yaml
    Warning: resource deployments/checkout-api is missing the
    kubectl.kubernetes.io/last-applied-configuration annotation which is
    required by kubectl apply. kubectl apply should only be used on resources
    created declaratively by either kubectl create --save-config or kubectl
    apply. The missing annotation will be adopted automatically.
    deployment.apps/checkout-api configured

    $ kubectl -n cnpa-lab-11 get deploy checkout-api \
        -o jsonpath='{.metadata.annotations.deploy\.corp/hotfix}{"\n"}'
    manual-2026-08-05-INC-4471                       <- still there

    $ kubectl -n cnpa-lab-11 get deploy checkout-api -o json \
        | jq -r '.spec.template.spec.containers[].env'
    [ { "name": "DEBUG_TRACE", "value": "1" } ]      <- still there

  Mechanism. Client-side apply performs a three-way merge over
  (last-applied-configuration, your manifest, live object). A field is
  DELETED only when it appears in last-applied and not in your manifest.
  `kubectl create -f` never wrote a last-applied annotation, so the deletion
  set was empty, and it stays empty for these two fields even after the
  annotation is adopted — because the adopted annotation is built from the
  manifest you just applied, which never mentioned them.

  Read the ownership ledger to see who is actually holding them:

    $ kubectl -n cnpa-lab-11 get deploy checkout-api -o json \
        | jq -r '.metadata.managedFields[] | "\(.manager)\t\(.operation)"'
    kubectl-create               Update
    legacy-autoscaler-v1         Apply
    kubectl-client-side-apply    Update
    kube-controller-manager      Update      (subresource: status)

  `kubectl-create` still owns the annotation and the env list. Server-Side
  Apply will NOT remove them either: SSA removes only fields that the
  applying manager itself previously owned and has now dropped. Fields owned
  exclusively by another manager and absent from your config are left alone.
  This is the single most misunderstood property of declarative management,
  and it is worth stating flatly:

      apply converges the fields you declare. It does not delete
      state that no manifest has ever claimed.

  That leaves two legitimate remediations.

  (a) THE CATTLE ANSWER — recreate the object from the source of truth.
      Correct here: the object was never declaratively owned, and this also
      clears the rogue manager from Fault B in one move.

        $ kubectl -n cnpa-lab-11 delete deployment checkout-api --wait=true
        deployment.apps "checkout-api" deleted
        $ kubectl apply --server-side --field-manager=gitops -f ~/cnpa-lab-1.1/gitops/
        namespace/cnpa-lab-11 serverside-applied
        configmap/checkout-api-config serverside-applied
        deployment.apps/checkout-api serverside-applied

      Note what this costs: full downtime for that Deployment. Acceptable for
      a stateless service behind a queue or during a maintenance window,
      unacceptable for a singleton with a PVC. Decide before you type it.

  (b) THE IN-PLACE ANSWER — when deleting is not allowed. Take ownership of
      the declared fields, then explicitly evict the two orphans:

        $ kubectl apply --server-side --force-conflicts \
            --field-manager=gitops -f ~/cnpa-lab-1.1/gitops/20-deployment.yaml
        deployment.apps/checkout-api serverside-applied
        $ kubectl -n cnpa-lab-11 annotate deployment checkout-api deploy.corp/hotfix-
        deployment.apps/checkout-api annotated
        $ kubectl -n cnpa-lab-11 set env deployment/checkout-api DEBUG_TRACE-
        deployment.apps/checkout-api env updated

      Both paths satisfy `verify`. Path (b) is the one you will actually use
      on a live payments service.

  Side lesson worth internalising: `spec.selector` is immutable. Had the
  hotfix manifest used a different selector, neither path (b) nor any apply
  would have worked — the API server would answer
    `Deployment.apps "checkout-api" is invalid: spec.selector: Invalid
     value: ...: field is immutable`
  and delete-and-recreate would be the ONLY option. Immutable fields are the
  hard boundary of declarative management.

STEP 3 — FAULT B: two managers, one field

  If you took path (b), your first SSA attempt without --force-conflicts
  looked like this:

    $ kubectl apply --server-side --field-manager=gitops -f gitops/20-deployment.yaml
    error: Apply failed with 5 conflicts:
    conflict with "legacy-autoscaler-v1": .spec.replicas
    conflict with "kubectl-create":
      - .metadata.labels.app.kubernetes.io/managed-by
      - .spec.template.spec.containers[name="api"].args
      ...
    Please review the fields above--they currently have other managers. Here
    are the ways you can resolve this warning:
    * If you intend to manage all of these fields, please re-run the apply
      command with the `--force-conflicts` flag.
    * If you do not intend to manage all of the fields, please edit your
      manifest to remove references to the fields that should keep their
      current managers.

  The error is a design question, not an obstacle. Three valid answers:

    1. TAKE the field. Correct when git is genuinely the owner:
         kubectl apply --server-side --force-conflicts --field-manager=gitops -f ...
       `.spec.replicas` moves to `gitops` and `legacy-autoscaler-v1` loses it.

    2. GIVE UP the field. Correct when a live controller owns it — and this
       is exactly the production pattern for HorizontalPodAutoscaler: delete
       `replicas:` from the manifest so the HPA owns it and your pipeline
       stops fighting the autoscaler every sync. If you leave `replicas` in
       git alongside an HPA you get a permanent flap: apply sets 2, HPA sets
       6, apply sets 2. (This lab's grader requires answer 1, because
       `legacy-autoscaler-v1` is decommissioned — it is not a real owner,
       it is a ghost. Identify the owner before you yield to it.)

    3. CO-OWN the field, by having both managers apply an identical value.
       Rarely what you want; it hides disagreement instead of resolving it.

  Confirm the ledger afterwards:

    $ kubectl -n cnpa-lab-11 get deploy checkout-api -o json | jq -r '
        .metadata.managedFields[]
        | select(.fieldsV1["f:spec"]["f:replicas"]? != null)
        | "\(.manager) \(.operation)"'
    gitops Apply

  One line, one owner, Apply operation. That is the goal state.

  Housekeeping: a manager that owns no fields is dropped automatically. If a
  stale entry lingers you can clear it explicitly by applying an empty
  configuration under that manager name, or by moving to answer 1 as above.

STEP 4 — Converge and confirm

    $ kubectl -n cnpa-lab-11 rollout restart deployment/checkout-api
    deployment.apps/checkout-api restarted
    $ kubectl -n cnpa-lab-11 rollout status deployment/checkout-api --timeout=120s
    deployment "checkout-api" successfully rolled out

  (The restart is a convenience, not a requirement: pods stuck in
  CreateContainerConfigError retry with exponential backoff and recover on
  their own once the ConfigMap exists. Restarting just skips the backoff.
  Remember, though, that `envFrom` is evaluated once at container start — a
  later ConfigMap edit does NOT reach a running container. Volume-mounted
  ConfigMaps do update in place, with kubelet sync latency.)

    $ kubectl -n cnpa-lab-11 get pods
    NAME                            READY   STATUS    RESTARTS   AGE
    checkout-api-5f9c7b6d44-9lm2v   1/1     Running   0          25s
    checkout-api-5f9c7b6d44-rr7qz   1/1     Running   0          22s

    $ kubectl -n cnpa-lab-11 logs -l app.kubernetes.io/name=checkout-api --tail=5 | sort -u
    FEATURE_CHECKOUT_V2=false
    RELEASE_CHANNEL=stable
    UPSTREAM_TIMEOUT_MS=2500
    checkout-api booting

  The last and most important check — idempotency. A declarative system is
  only healthy when re-applying is a no-op:

    $ kubectl diff -f ~/cnpa-lab-1.1/gitops/ ; echo "exit=$?"
    exit=0

    $ ./break_fix.sh verify
    [OK] A1 — orphan annotation 'deploy.corp/hotfix' is gone
    [OK] A2 — orphan env var 'DEBUG_TRACE' is gone
    [OK] A3 — app.kubernetes.io/managed-by=gitops
    [OK] B1 — .spec.replicas == 2 (matches the manifest)
    [OK] B2 — .spec.replicas owned by field manager 'gitops' (Apply)
    [OK] C1 — the committed ConfigMap manifest no longer declares ownerReferences
    [OK] C2 — configmap/checkout-api-config survived the garbage collector
    [OK] C3 — ConfigMap data matches the manifest
    [OK] D  — 2/2 replicas Ready
    [OK] E  — bonus: 'kubectl diff -f gitops/' is clean
    PASSED  10/10 checks.

WHAT TO CARRY INTO THE EXAM AND INTO PRODUCTION
  * Imperative and declarative are not styles, they are different contracts.
    `create`/`edit`/`scale`/`patch` state a transition; `apply` states an
    invariant. Mixing them without `--save-config` breaks the invariant's
    bookkeeping permanently.
  * Client-side apply keeps its ledger in an annotation and can only delete
    what that annotation recorded. Server-Side Apply keeps a per-field ledger
    in `.metadata.managedFields` inside the API server, which is why it can
    report conflicts, survive `kubectl` version drift, and be used safely by
    controllers. New platforms should default to
    `--server-side --field-manager=<pipeline-name>`.
  * A conflict is information. Resolve it by deciding the owner: force, or
    drop the field from git. Never by looping.
  * Deletion is a controller behaviour too. `ownerReferences` make the
    garbage collector a reconciliation loop that can remove your objects
    without an Event, without a log, and without any error from apply.
    Never copy an operator's metadata into a hand-maintained manifest.
  * Drift can live in the repository. When the cluster disagrees with git,
    confirm which one is actually wrong before you reconcile toward either.
  * Idempotency is the acceptance test. `kubectl diff` exiting 0 after a full
    apply is the only evidence that the cluster is a projection of the repo.

  Tear the lab down with:  ./break_fix.sh cleanup
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpa/1.1/lab)
