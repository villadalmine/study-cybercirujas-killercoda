## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — step by step (commented; do not read until you have tried)

 DIAGNOSIS
 1. Look at all four planes at once:

        ./break_fix.sh status

    You will see Git desired = registry.local/web:v1.5.0, but the registry
    only lists v1.4.0 v1.4.1 v1.4.2, and Live is still v1.4.2. Status is
    Sync=OutOfSync / Health=Degraded with reason ErrImagePull.

 2. Confirm the reconciler is behaving correctly (it is — a CD controller must
    never deploy an artifact it cannot pull):

        ./break_fix.sh reconcile
        # -> pull registry.local/web:v1.5.0 ... NOT FOUND (ErrImagePull)

 3. Read the source of truth's history to see what CI did:

        git -C ~/cnpa-lab/3.5/app-config log --oneline
        # ci: bump web image to v1.5.0 (build #4207) [skip-push glitch]
        # platform: seed web Deployment pinned to v1.4.2

    Root cause: CI committed the desired-state change (image bump) but its
    build-and-push stage failed, so v1.5.0 was never published. The CI->CD
    handoff is inconsistent: Git points at an artifact that does not exist.

 FIX — choose ONE of the two legitimate GitOps remediations:

 Option A — ROLL FORWARD (finish what CI started; keep v1.5.0):
    Re-run CI's build-and-push stage to actually publish the artifact Git
    already asks for, then reconcile:

        ./break_fix.sh ci-push v1.5.0
        ./break_fix.sh reconcile
        ./break_fix.sh verify
        # -> PASS: Sync=Synced Health=Healthy on registry.local/web:v1.5.0

 Option B — ROLL BACK (re-pin the truth to the last good, released artifact):
    Revert the bad commit in Git so the desired tag is v1.4.2 again (which
    exists), then reconcile:

        git -C ~/cnpa-lab/3.5/app-config revert --no-edit HEAD
        ./break_fix.sh reconcile
        ./break_fix.sh verify
        # -> PASS: Sync=Synced Health=Healthy on registry.local/web:v1.4.2

 WHY NOT just edit the live state?
    Editing ~/cnpa-lab/3.5/cluster/live-state.txt (the equivalent of
    `kubectl set image ...` out of band) is an imperative change that bypasses
    Git. It creates drift: the next reconcile compares live against the Git
    source of truth and reverts your change. In GitOps you always fix the
    source of truth (or the artifact it references), never the running system.

 KEY TAKEAWAYS (CNPA 3.5)
    * CI and CD are decoupled systems; their handoff is the artifact registry
      plus the Git desired-state repo. Order matters: publish the immutable
      artifact BEFORE (or atomically with) committing the tag that references
      it — otherwise "green pipeline, stale production".
    * CD is pull-based reconciliation toward a declared desired state; Git is
      the single source of truth (OpenGitOps: declarative, versioned &
      immutable, pulled automatically, continuously reconciled).
    * Recover by roll-forward (publish the artifact) or rollback (revert the
      commit) — both act on the source of truth, never on the live cluster.

 CLEANUP
        ./break_fix.sh reset
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpa/3.5/lab)
