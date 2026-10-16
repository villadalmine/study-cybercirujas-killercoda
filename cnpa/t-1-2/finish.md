## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION — step by step (spoilers below; try the lab first)

1) Reproduce the symptom and notice what is MISSING, not what is present.
     cd ~/cnpa-lab-1.2/dev/platform
     echo "1.0.1" > VERSION
     git commit -am "chore: bump to 1.0.1"
     git push origin main
   The push exits 0 and prints the ref update, but there are zero
   'remote: [pipeline]' lines. Compare with the healthy run you saw during
   setup: checkout / validate / deploy stages all reported back. A missing
   feedback signal is itself a diagnostic datum.

2) Confirm the drift and prove it is outside Git:
     cat ~/cnpa-lab-1.2/deploy/VERSION
       -> 1.0.0-hotfix1        (not a commit that exists anywhere)
     git --git-dir=$HOME/cnpa-lab-1.2/origin/platform.git show main:app.sh \
       | diff - ~/cnpa-lab-1.2/deploy/app.sh
       -> timeout_seconds 30 vs 300, plus the manual "# HOTFIX" line.
   Reality diverged from the source of truth, and Git history cannot
   explain the divergence: that is the definition of configuration drift.

3) Diagnose the pipeline itself:
     ls -l ~/cnpa-lab-1.2/origin/platform.git/hooks/
       -rw-r--r-- ... post-receive     <-- NOT executable
   Per githooks(5) (https://git-scm.com/docs/githooks), git only runs a
   hook that is executable; otherwise it is silently ignored. No exec bit,
   no pipeline, no error. In managed CI/CD the same class of failure looks
   like a disabled webhook, a paused Argo CD Application, or a workflow
   file renamed out of .github/workflows/.

4) Fix the SYSTEM, not the symptom:
     chmod +x ~/cnpa-lab-1.2/origin/platform.git/hooks/post-receive
   Resist the urge to hand-edit deploy/ — that would be one more untracked
   change on a snowflake server.

5) Let the pipeline reconcile the drift from Git:
     cd ~/cnpa-lab-1.2/dev/platform
     git push origin main          # if the 1.0.1 bump is still unpushed
     # ...or force a run without a content change:
     git commit --allow-empty -m "ci: trigger redeploy" && git push origin main
   Expected output now includes all three stages:
     remote: [pipeline] stage 1/3 checkout : <sha>
     remote: [pipeline] stage 2/3 validate : syntax + version gate
     remote: [pipeline] stage 3/3 deploy   : full sync — Git is the source of truth
     remote: [pipeline] OK: v1.0.1 is live in /home/<you>/cnpa-lab-1.2/deploy
   The deploy stage rebuilds the target from the pushed commit, so the
   hotfix drift is erased as a side effect of normal delivery — exactly how
   GitOps reconcilers (Argo CD, Flux) heal drift continuously.

6) Prove it:
     ./break_fix.sh verify
     cat ~/cnpa-lab-1.2/deploy.log     # audit trail: one line per deploy

7) Takeaways to carry into the exam:
   - Automation must fail loudly; a silent pipeline is worse than none,
     because it converts every push into false confidence.
   - Feedback loops are a deliverable of the platform, not a nicety: the
     'remote:' stage output is the lab-scale version of pipeline status
     checks, deploy notifications and Argo CD health/sync state.
   - Drift is repaired through the source of truth, never in place; if the
     hotfix value was right, it earns a commit and a review like any change.
   - Blameless response: the question is never "who typed it at 02:47" but
     "why was typing it the easiest available action" — then you fix that.
     (https://sre.google/sre-book/eliminating-toil/, https://dora.dev/)
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpa/1.2/lab)
