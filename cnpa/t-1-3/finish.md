## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION — step by step (do not read until you have tried)

S1. Diagnose from the controller's point of view, not the pods'.
    The pods are fine; the objects that cannot make progress are the
    ReplicaSets, and they say so explicitly:

      kubectl -n cnpa-13-staging get deploy checkout
      kubectl -n cnpa-13-staging describe deploy checkout   # ReplicaFailure=True, reason FailedCreate
      kubectl -n cnpa-13-staging get events \
        --field-selector reason=FailedCreate --sort-by=.lastTimestamp | tail
      kubectl -n cnpa-13-staging describe quota env-quota    # hard vs used
      kubectl -n cnpa-13-staging get limitrange              # -> No resources found

    Read the two error strings carefully — they name the two root causes:
      "must specify limits.cpu ..."  -> quota constrains compute but nothing
                                        injects defaults anymore (LimitRange gone)
      "exceeded quota ... pods=2"    -> quota undersized for the environment

S2. Restore the LimitRange (the environment's defaulting guardrail):

      cat <<'YAML' | kubectl apply -f -
      apiVersion: v1
      kind: LimitRange
      metadata:
        name: env-defaults
        namespace: cnpa-13-staging
      spec:
        limits:
        - type: Container
          defaultRequest:
            cpu: 100m
            memory: 128Mi
          default:
            cpu: 250m
            memory: 256Mi
      YAML

S3. Right-size the ResourceQuota for staging, with headroom. 5 replicas at
    the defaults consume 500m/640Mi requests and 1250m/1280Mi limits, so
    the original envelope is comfortable:

      cat <<'YAML' | kubectl apply -f -
      apiVersion: v1
      kind: ResourceQuota
      metadata:
        name: env-quota
        namespace: cnpa-13-staging
      spec:
        hard:
          pods: "10"
          requests.cpu: "2"
          requests.memory: 2Gi
          limits.cpu: "4"
          limits.memory: 4Gi
      YAML

    Note: kubectl apply on the existing quota REPLACES the sabotaged hard
    limits; you never had to delete the quota. Deleting it would "work"
    but removes the environment's capacity envelope — verify rejects that.

S4. Unfreeze the rollout. The ReplicaSet controller retries FailedCreate
    with exponential backoff (it can idle for minutes), so force an
    immediate reconciliation instead of waiting:

      kubectl -n cnpa-13-staging rollout restart deploy/checkout
      kubectl -n cnpa-13-staging rollout status  deploy/checkout --timeout=180s

    Expected:
      deployment "checkout" successfully rolled out

S5. Confirm the environment is structurally healthy, then run the grader:

      kubectl -n cnpa-13-staging get deploy checkout        # READY 5/5
      kubectl -n cnpa-13-staging describe quota env-quota   # used well below hard
      kubectl -n cnpa-13-staging run probe --image=nginx:1.27-alpine \
        --restart=Never --dry-run=server -o yaml | grep -A4 'resources:'
      ./break_fix.sh verify

    The server-side dry-run trick in S5 is worth keeping: it runs the full
    admission chain (LimitRange defaulting, quota evaluation, webhooks)
    without creating anything — the cheapest way to prove an environment
    will accept tomorrow's deploy today.

Why this is a Topic 1.3 lesson and not just a quota exercise:
  * Environments are architecture, not folders. dev/staging/prod share one
    cluster yet staging's failure never touched its neighbours — isolation
    boundaries (namespace + quota) did their job.
  * Guardrails enable parity. The application manifest carried no
    environment-specific resources; the ENVIRONMENT owned that policy.
    Delete the guardrail and the "portable" manifest stops being portable.
  * Admission-time enforcement fails silently. Nothing crashed; capacity
    to change was lost. Monitor deployment conditions (ReplicaFailure) and
    quota saturation, not only pod health.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpa/1.3/lab)
