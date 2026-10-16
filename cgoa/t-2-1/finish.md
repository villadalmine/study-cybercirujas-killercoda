## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION — step by step. Spoilers below. Attempt the lab first.

STEP 0 — Name the violations (exam skill, do it before touching anything)
  - Stopping the agent violated Principle 3 (Pulled Automatically) and
    Principle 4 (Continuously Reconciled): no agent, no reconciliation loop.
  - `kubectl set image` / `kubectl scale` violated Principle 1 (the change
    was imperative, not declarative) and bypassed Principle 2 (it exists in
    no versioned, immutable history — it cannot be reviewed, reproduced,
    audited, or rolled back).
  - Note the compound failure mode: the cluster drifted AWAY from Git while
    an approved change in Git was never delivered TO the cluster. Divergence
    is bidirectional once the loop is broken.

STEP 1 — Observe the symptom from the cluster side
  $ kubectl -n gitops-lab get pods
    NAME                      READY   STATUS             RESTARTS   AGE
    webapp-6f9d...-abcde      1/1     Running            0          25m
    webapp-6f9d...-fghij      1/1     Running            0          25m
    webapp-7c88...-klmno      0/1     ImagePullBackOff   0          6m
    webapp-7c88...-pqrst      0/1     ImagePullBackOff   0          6m
    ...
  $ kubectl -n gitops-lab describe pod <one of the failing pods> | tail -n 6
    -> "manifest for nginx:1.99-hotfix not found" — the tag does not exist.
  The rollout is stuck: the Deployment respects maxUnavailable, so the old
  ReplicaSet's healthy pods keep serving while the new ReplicaSet can never
  become Ready. That is why the page said "rollout stuck", not "outage".

STEP 2 — Observe the agent side
  $ cat ~/cgoa-lab-2.1/reconciler.pid          # e.g. 41234
  $ kill -0 41234; echo $?                     # non-zero -> process is dead
  $ tail -n 3 ~/cgoa-lab-2.1/reconciler.log    # log stops at incident time
  A stale pid file plus a silent log is the classic signature of a
  suspended/paused reconciler (flux suspend, Argo CD sync disabled).

STEP 3 — Establish what the source of truth actually says
  $ git -C ~/cgoa-lab-2.1/platform.git log --oneline main
    <sha> feat: scale webapp for launch and roll to nginx 1.28
    <sha> feat: initial declarative desired state for webapp (Principle 1)
  $ git -C ~/cgoa-lab-2.1/platform.git show main:clusters/lab/10-deployment.yaml
    -> replicas: 3, image: nginx:1.28
  Decision point, and the heart of GitOps: you do NOT reconcile Git to match
  the cluster; you restore the machinery that reconciles the cluster to Git.

STEP 4 — Restore reconciliation (the actual fix — two commands)
  $ rm ~/cgoa-lab-2.1/reconciler.pid
  $ nohup ~/cgoa-lab-2.1/bin/reconciler.sh >/dev/null 2>&1 & \
      echo $! > ~/cgoa-lab-2.1/reconciler.pid
  $ tail -f ~/cgoa-lab-2.1/reconciler.log
    -> within 15s: "reconciled cluster to revision <sha of the launch commit>"

STEP 5 — Watch convergence and understand WHY it works
  $ kubectl -n gitops-lab get deploy webapp -w
    -> image flips to nginx:1.28, replicas to 3, then 3/3 Ready.
  `kubectl apply` re-asserts every field declared in the manifest, so the
  phantom hotfix image and the panic scale-up are simply overwritten by the
  declared state. Both pieces of drift vanish in one reconcile cycle, and
  the approved-but-stranded commit ships at the same time. Real controllers
  (Flux, Argo CD) additionally detect drift between intervals, prune
  resources deleted from Git, run health checks, and emit drift events.

STEP 6 — Prove it
  $ ./cgoa-2.1-break-fix.sh verify
    -> 5/5 [PASS]

STEP 7 — Aftercare: make the next change the right way
  $ cd ~/cgoa-lab-2.1/dev-clone
  $ sed -i 's/replicas: 3/replicas: 4/' clusters/lab/10-deployment.yaml
  $ git commit -am "feat: add capacity ahead of launch traffic" && git push
  Within one interval the cluster runs 4/4 — and this time there is an
  author, a diff, a timestamp, and a revert path (`git revert`). That
  auditability is Principle 2 paying rent.

PRODUCTION TAKEAWAYS
  - Humans get read-only cluster access; only the reconciler's identity may
    write. If kubectl-write is impossible, Friday-night hotfixes are too.
  - Pausing reconciliation is sometimes legitimate (incident forensics,
    migrations) but must be time-boxed, alarmed, and visible — an agent that
    is down IS the incident, e.g. alert on Flux's `SuspendedReconciliation`
    or a stale `.status.lastAppliedRevision`.
  - "Fix forward through Git" beats "fix live, backport later": the second
    one produced this exact lab.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cgoa/2.1/lab)
