## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — step by step  (do not read until you have tried it yourself)

 ROOT CAUSE
   'spec.source.targetRevision' was set to 'capa-broken-revision', a git
   revision that does not exist in the repository. Argo CD's repo-server
   cannot resolve it to a commit SHA, so it cannot render the desired
   manifests. With no desired state to diff against, the comparison itself
   fails: status becomes Sync=Unknown with a ComparisonError condition
   (distinct from OutOfSync, which means "I compared and they differ").
   Because self-heal only reverts *known* drift, it cannot act — hence the
   running-but-frozen behaviour.

 STEP 1 — Confirm the diagnosis.
   kubectl -n argocd get application capa-guestbook
   kubectl -n argocd get application capa-guestbook \
       -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
   # Expect a ComparisonError mentioning it cannot resolve 'capa-broken-revision'.

 STEP 2 — Find the offending field.
   kubectl -n argocd get application capa-guestbook \
       -o jsonpath='{.spec.source.targetRevision}{"\n"}'
   # -> capa-broken-revision      (this is the single wrong value)

 STEP 3 — Correct it. Either the declarative way (patch the CR):
   kubectl -n argocd patch application capa-guestbook --type merge \
       -p '{"spec":{"source":{"targetRevision":"HEAD"}}}'
   # ...or the imperative CLI way, if you are logged into argocd:
   #   argocd app set capa-guestbook --revision HEAD

 STEP 4 — Force a fresh comparison against the good revision.
   kubectl -n argocd annotate application capa-guestbook \
       argocd.argoproj.io/refresh=hard --overwrite
   #   argocd app get capa-guestbook --refresh     # equivalent via CLI

 STEP 5 — Let auto-sync converge (or push it manually).
   # Automated sync should now transition Unknown -> Synced on its own.
   # If you want to force it:
   #   argocd app sync capa-guestbook

 STEP 6 — Verify.
   kubectl -n argocd get application capa-guestbook
   # Expect: SYNC STATUS = Synced,  HEALTH STATUS = Healthy.
   ./capa_3_1_break_fix.sh verify

 TAKEAWAYS FOR THE EXAM
   - "Unknown + ComparisonError" != "OutOfSync". The first means Argo CD
     could not even build the desired state (bad repoURL / targetRevision /
     path / unparseable manifests); the second means it built it and found
     drift.
   - Healthy pods do NOT imply a Healthy Application. The Application's
     status reflects the GitOps reconciliation, not just runtime liveness.
   - self-heal cannot fix what it cannot render. A broken source silences
     reconciliation instead of triggering it.
   - targetRevision accepts HEAD, a branch, a tag, or a commit SHA; a value
     that resolves to none of these is the classic cause of this failure.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/capa/3.1/lab)
