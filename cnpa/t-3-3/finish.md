## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION — step by step (do not read until you have tried it)

ROOT CAUSE
  Every CI stage runs in an isolated, ephemeral container. The 'build' Task
  was mutated to write its artifact to /tmp/app.txt — a path on the step
  container's OWN filesystem. That container is destroyed the instant the
  step finishes, so the file is gone. The 'test' Task (correctly) reads from
  the SHARED workspace at $(workspaces.source.path)/app.txt, finds nothing,
  and fails. build is green because writing to /tmp succeeds; the pipeline is
  red because the hand-off never happened. Nothing is wrong with 'test'.

1. Confirm the failure is downstream, not in build:
     $ kubectl -n cnpa-ci get taskrun
     NAME                    SUCCEEDED   REASON
     ci-run-...-build        True        Succeeded
     ci-run-...-test         False       Failed

2. Read the failing stage's log — it names the missing artifact:
     $ kubectl -n cnpa-ci logs --selector tekton.dev/pipelineRun=<run> \
           --all-containers --prefix | tail -n 5
     [pod/.../step-verify] test: reading artifact from previous stage...
     [pod/.../step-verify] cat: can't open '/workspace/source/app.txt': No such file or directory

3. Compare where each stage writes vs. reads:
     $ kubectl -n cnpa-ci get task build -o jsonpath='{.spec.steps[0].script}'; echo
       ... echo "build-id=42" > /tmp/app.txt ...              <-- WRONG (private /tmp)
     $ kubectl -n cnpa-ci get task test  -o jsonpath='{.spec.steps[0].script}'; echo
       ... cat "$(workspaces.source.path)/app.txt" ...        <-- reads the shared workspace
     The two paths do not match: the producer and consumer disagree on the medium.

4. Fix the PRODUCER so it publishes into the shared workspace. Re-apply 'build'
   changing the write path from /tmp/app.txt to the workspace path:

     kubectl apply -f - <<'YAML'
     apiVersion: tekton.dev/v1
     kind: Task
     metadata:
       name: build
       namespace: cnpa-ci
     spec:
       workspaces:
         - name: source
       steps:
         - name: compile
           image: docker.io/library/busybox:1.36
           script: |
             #!/bin/sh
             set -e
             echo "build-id=42" > "$(workspaces.source.path)/app.txt"
     YAML

   (Equivalently:  ./break_fix.sh solve  — which does exactly this.)

5. Start a FRESH PipelineRun (Tekton runs are immutable — you never edit the
   old one, you launch a new one against the fixed definitions):

     kubectl create -f - <<'YAML'
     apiVersion: tekton.dev/v1
     kind: PipelineRun
     metadata:
       generateName: ci-run-
       namespace: cnpa-ci
     spec:
       pipelineRef:
         name: ci
       workspaces:
         - name: shared-data
           volumeClaimTemplate:
             spec:
               accessModes: ["ReadWriteOnce"]
               resources:
                 requests:
                   storage: 64Mi
     YAML

6. Verify it is green end to end:
     $ kubectl -n cnpa-ci get pipelinerun
     NAME           SUCCEEDED   REASON      STARTTIME   COMPLETIONTIME
     ci-run-xxxxx   True        Succeeded   30s         2s

WHY THIS IS THE POINT OF THE TOPIC
  Stage isolation is a feature, not a bug: it makes stages reproducible,
  cacheable and parallelizable. But it forces one architectural rule — a
  stage's output only exists downstream if it is published to a shared medium
  (workspace / artifact repository / cache / output parameter). "The build
  passed" is never sufficient evidence that the pipeline works; you must trace
  the artifact across the stage boundary. Diagnose CI pipelines at the seam
  between stages, not inside a single stage.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpa/3.3/lab)
