## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
#   SOLUTION — step by step. Try the lab first; only unfold this after.    #
#                                                                          #
############################################################################

STEP 0 — Confirm the symptom
  kubectl -n pca-lab-3-2 get pods

  Expected (RESTARTS keeps growing on each poll):
    NAME                            READY   STATUS             RESTARTS      AGE
    cache-warmer-6c8f9b7d4d-4xk2p   0/1     CrashLoopBackOff   3 (25s ago)   90s

  Reading it: 0/1 Ready, status CrashLoopBackOff. The "(25s ago)" is the time
  since the LAST restart; the number is how many times the kubelet has already
  restarted the container. CrashLoopBackOff is not an error itself — it is the
  kubelet deliberately WAITING (exponential backoff, capped at 5 min) before
  the next restart, to avoid a hot loop.

STEP 1 — Read the EVENTS: confirm the failure MODE
  kubectl -n pca-lab-3-2 describe pod -l app=cache-warmer

  Scroll to the Events block at the bottom. Expected tail:
    Type     Reason     Age                 From     Message
    ----     ------     ----                ----     -------
    Normal   Scheduled  2m                  ...      Successfully assigned ...
    Normal   Pulled     2m (x4 over 2m)     kubelet  Container image "busybox:1.36" already present
    Normal   Created    2m (x4 over 2m)     kubelet  Created container cache-warmer
    Normal   Started    2m (x4 over 2m)     kubelet  Started container cache-warmer
    Warning  BackOff    30s (x8 over 2m)    kubelet  Back-off restarting failed container

  The stand-alone, TTL-bounded events feed (great for a namespace-wide view,
  sorted, no object noise):
    kubectl -n pca-lab-3-2 events --for pod/<pod-name> --types=Warning
    kubectl -n pca-lab-3-2 get events --sort-by=.lastTimestamp

  Also inspect the container's last termination — events summarise, this is
  the machine-readable truth:
    kubectl -n pca-lab-3-2 get pod -l app=cache-warmer \
      -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
    -> 78

  Interpretation: the image pulls fine, the container STARTS fine, then it
  exits non-zero and the kubelet backs off. So this is NOT ImagePullBackOff
  and NOT a scheduling/quota problem. The container is running our code and
  our code is choosing to die with exit 78. Events cannot tell you WHY it
  chose to die — for that, read the logs.

STEP 2 — Read the LOGS of the PREVIOUS container: find the CAUSE
  The current container may be freshly (re)started or gone; the useful log is
  the one from the instance that JUST crashed. The '--previous' / '-p' flag is
  the whole point of this topic:

  kubectl -n pca-lab-3-2 logs -l app=cache-warmer --previous --tail=20

  Expected:
    boot: cache-warmer v1.4 starting (pid 1)
    boot: reading configuration from environment
    FATAL: MAX_CONNECTIONS must be a positive integer, got '-1'
    hint: set it via an env var or ConfigMap and redeploy

  There it is. Without --previous you would often get an empty result or the
  partial log of a container that has not failed yet — the #1 reason students
  "can't find the error." (Note: --previous keeps working only while the
  crashed container's log is still on the node; after enough restarts+GC it
  may vanish, which is exactly why events + exit code are the durable record.)

STEP 3 — Fix the ROOT CAUSE (a bad configuration value)
  The defect is env MAX_CONNECTIONS="-1". Set a valid positive integer.
  Any ONE of these is a correct, minimal fix:

  (a) Imperative — patch the env var (triggers a rollout):
      kubectl -n pca-lab-3-2 set env deployment/cache-warmer MAX_CONNECTIONS=100

  (b) Declarative — edit and re-apply the manifest:
      kubectl -n pca-lab-3-2 edit deployment/cache-warmer
        # change:  value: "-1"   ->   value: "100"

  (c) Strategic-merge patch:
      kubectl -n pca-lab-3-2 patch deployment/cache-warmer --type=strategic -p \
        '{"spec":{"template":{"spec":{"containers":[{"name":"cache-warmer","env":[{"name":"MAX_CONNECTIONS","value":"100"}]}]}}}}'

  Do NOT "fix" it by scaling to 0, deleting the guard, or removing the pod —
  that hides the fault instead of resolving it.

STEP 4 — Confirm the fix through the same two planes
  kubectl -n pca-lab-3-2 rollout status deploy/cache-warmer
    -> deployment "cache-warmer" successfully rolled out

  kubectl -n pca-lab-3-2 get pods
    NAME                            READY   STATUS    RESTARTS   AGE
    cache-warmer-7d9c5f6b8c-abcde   1/1     Running   0          20s

  kubectl -n pca-lab-3-2 logs -l app=cache-warmer --tail=3
    boot: cache-warmer v1.4 starting (pid 1)
    boot: reading configuration from environment
    ready: warming cache with 100 connections

  ./break-fix.sh verify     # -> PASS

THE TAKEAWAY
  Events and logs answer different questions and neither replaces the other:
    * Events (apiserver, ~1h TTL): WHAT the platform observed about the object
      — scheduling, pulls, restarts, backoff, probe failures, OOMKills.
    * Logs (kubelet, on the node): WHAT the process itself said — and for a
      crashed container that means `--previous`.
  Diagnosing a CrashLoopBackOff is the canonical exercise that forces you to
  cross both planes: events prove it is crash-looping and give you the exit
  code; the previous container's logs give you the sentence that explains why.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/pca/3.2/lab)
