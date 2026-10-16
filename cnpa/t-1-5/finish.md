## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION — step by step (do not read until you have genuinely tried)

1. Start from the symptom, not from a guess:
     kubectl get deploy -n team-checkout
   'payments' is 0/2 and 'orders' shows READY 2/2 but UP-TO-DATE 0. A READY
   deployment that cannot roll out is a controller-level failure: the
   Deployment created a new ReplicaSet, and that ReplicaSet cannot create pods.

2. Ask the controllers why:
     kubectl get events -n team-checkout --sort-by=.lastTimestamp | tail
     kubectl describe rs -n team-checkout | grep -A2 FailedCreate
   The event is explicit:
     pods "payments-..." is forbidden: failed quota: team-quota: must specify
     limits.cpu for: app; limits.memory for: app; requests.cpu ...
   Mechanics: when a ResourceQuota constrains requests.*/limits.*, the quota
   admission plugin REJECTS any pod that does not declare those values
   (https://kubernetes.io/docs/concepts/policy/resource-quotas/).

3. But the golden-path template never declared resources — so why did it ever
   work? Because something was defaulting them at admission time:
     kubectl get limitrange -n team-checkout
     -> No resources found in team-checkout namespace.
   Root cause: the LimitRange 'platform-defaults' (the mutating defaulter,
   https://kubernetes.io/docs/concepts/policy/limit-range/) was deleted
   directly in the cluster. Running pods kept their values, so the drift was
   invisible until the next scaffold/redeploy. The template's design carried
   a hidden dependency on that guardrail.

4. Fix at the platform level — reconcile from the source of truth:
     kubectl apply -f "$HOME/cnpa-1.5-lab/platform/limitrange.yaml"
   (Adjust the path if you overrode LAB_DIR.) This is exactly what a GitOps
   reconciler would have done automatically within minutes — which is why
   drift detection is an "Operations" trait in the CNCF Platform Engineering
   Maturity Model.

5. Recovery is automatic but backoff-delayed: the ReplicaSet controller
   retries failed pod creations with exponential backoff. To converge
   immediately instead of waiting:
     kubectl -n team-checkout rollout restart deploy orders payments
   (A restart only stamps a template annotation; it does not add resources,
   so the anti-pattern detector still passes.)

6. Prove it:
     ./break_fix.sh verify
   The verifier re-runs the golden path with a fresh app. That is the real
   platform SLO: "a new team, with zero Kubernetes quota knowledge, can go
   from nothing to Running through the paved road."

What NOT to do — and why it matters for the exam:
   kubectl -n team-checkout set resources deploy/payments --requests=cpu=100m...
   unblocks ONE deployment, leaves every future scaffold broken, splits the
   fleet into snowflakes, and hides the platform defect. Instance patches
   treat the platform's users as the maintenance crew — the inverse of
   Platform as a Product (https://tag-app-delivery.cncf.io/whitepapers/platforms/).
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpa/1.5/lab)
