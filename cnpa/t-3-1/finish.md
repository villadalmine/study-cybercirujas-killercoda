## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION — step by step (do not read until you have tried)
#############################################################################

ROOT CAUSE
  In ci/run-ci.sh, run_stage() runs each stage as the LEFT side of a pipe so
  its output can be streamed to the log:

      "$@" | tee -a "$CI_LOG"
      rc=$?

  In bash, the exit status of a pipeline ($?) is the exit status of its LAST
  command — here `tee`, which essentially always succeeds. So `rc` is 0 even
  when stage_test returned 1. The `if [ "$rc" -ne 0 ]` guard never fires, none
  of the `run_stage ... ||` shortcuts trigger, and control falls through to:

      echo "Pipeline: SUCCESS"
      exit 0

  The real status was thrown away by tee. Same class of bug as piping a build
  through `tee build.log` in a Makefile, or `kubectl apply -f - | tee` in a
  deploy step: the log is captured, the failure is not.

THE FIX (pick ONE; option A is the idiomatic CI answer)

  A) Turn on pipefail so a pipeline fails if ANY member fails. Add this line
     to ci/run-ci.sh right after the shebang (line 2):

         set -o pipefail

     With pipefail, `"$@" | tee ...` returns stage_test's non-zero status,
     rc becomes 1, run_stage returns 1, the `run_stage test ... ||` shortcut
     fires, and the runner prints "Pipeline: FAILED" and exits 1.
     (General best practice for CI scripts: begin with `set -euo pipefail`.)

  B) Read the specific pipeline member instead of the pipeline's last status.
     Replace:
         rc=$?
     with:
         rc=${PIPESTATUS[0]}      # exit status of the FIRST pipe member ("$@")
     PIPESTATUS is a bash array holding every member's status; index 0 is the
     stage function. This works even without pipefail.

  C) Don't pipe the status-bearing command at all — capture, then tee:
         "$@" >"$CI_LOG.stage" 2>&1; rc=$?
         tee -a "$CI_LOG" <"$CI_LOG.stage"; rm -f "$CI_LOG.stage"
     More verbose; prefer A or B.

APPLY OPTION A
      cd "${CNPA_LAB_DIR:-$HOME/cnpa-lab-3.1-ci}"
      sed -i '1a set -o pipefail' ci/run-ci.sh
      # (or open ci/run-ci.sh and add `set -o pipefail` after the shebang)

VERIFY THE FIX
      bash ci/run-ci.sh ; echo "exit=$?"
  Expected (CORRECT) output now:
      >>> stage: test
        FAIL tests/test_add.sh
      !!! stage 'test' FAILED (rc=1)
      Pipeline: FAILED
      exit=1

      ./break_fix.sh verify
  Expected:
      RESULT: PASS  — pipeline exited 1 when a stage failed. It tells the truth now.

WHY THIS IS A CI FUNDAMENTAL (exam framing)
  * Fail fast / fail loud: a pipeline exists to STOP bad changes; a run that
    cannot fail provides zero protection and manufactures false confidence.
  * Exit-code propagation is the contract between a job and its orchestrator —
    GitHub Actions, GitLab CI, Jenkins and Argo Workflows all gate the next
    step on the previous step's exit code. Any masking (`| tee`, `| cat`, a
    trailing `|| true`, an un-awaited background job) silently breaks it.
  * The remedy is a habit: start every CI shell script with `set -euo pipefail`
    and assert on ${PIPESTATUS[@]} whenever you must keep a pipe.

CLEAN UP
      ./break_fix.sh reset      # rebuild the broken lab to practise again
      rm -rf "${CNPA_LAB_DIR:-$HOME/cnpa-lab-3.1-ci}"   # remove it entirely
#############################################################################
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpa/3.1/lab)
