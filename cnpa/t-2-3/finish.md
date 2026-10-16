## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — step by step  (read only after you have tried it yourself)

 1) See the symptom and gather evidence
    kubectl -n cnpa-lab-23 get deploy governance-demo
        # READY 0/1, AVAILABLE 0 — the Deployment exists but has no Pods.
    kubectl -n cnpa-lab-23 describe rs -l app=governance-demo | tail -n 5
        # Warning FailedCreate ... failed calling webhook
        # "pods.cnpa-governance-guard.example.com": ... service
        # "policy-engine-nonexistent" not found

    LESSON: a Deployment failing at 0 replicas with *no Pod objects at all*
    (not CrashLoopBackOff, not ImagePullBackOff) points at the admission
    path, not the scheduler or kubelet. The controller cannot even CREATE
    the Pod.

 2) Find who is intercepting admission
    kubectl get validatingwebhookconfigurations
        # NAME                     WEBHOOKS   AGE
        # cnpa-governance-guard    1          2m
    kubectl get validatingwebhookconfiguration cnpa-governance-guard -o yaml
        # Read these fields:
        #   failurePolicy: Fail                 <- fails CLOSED
        #   clientConfig.service:
        #     name: policy-engine-nonexistent   <- backend Service is missing
        #   namespaceSelector.matchLabels: cnpa-lab=governance
        #   rules: pods / CREATE

    Confirm the backend really is gone:
    kubectl -n cnpa-lab-23 get svc policy-engine-nonexistent
        # Error from server (NotFound): services "..." not found

 3) Root cause
    The policy engine's ValidatingWebhookConfiguration is on the critical
    admission path for Pod CREATE in namespace cnpa-lab-23. Its backend
    Service does not exist, so the API server cannot obtain a verdict.
    Because failurePolicy is Fail, "no verdict" is treated as "deny" — the
    platform is protected from ungoverned writes at the cost of blocking ALL
    writes. This is fail-closed behaviour.

 4) Fix — pick the option that matches the real situation
    (a) PREFERRED in production: repair the backend. Redeploy / scale up the
        policy engine (Kyverno, Gatekeeper) so the Service and its endpoints
        exist again, and admission verdicts flow. The webhook stays enforcing.
            # e.g. kubectl -n <policy-ns> rollout restart deploy/<engine>
        (Not applicable in this lab — there is no real engine to restore.)

    (b) BREAK-GLASS (what to do in this lab): the webhook is orphaned and has
        no legitimate backend, so remove it deliberately:
            kubectl delete validatingwebhookconfiguration cnpa-governance-guard

    (c) MITIGATE without deleting: flip the webhook to fail OPEN. This
        unblocks writes immediately but SILENTLY DISABLES governance while
        the backend is down — a real security trade-off you must accept
        consciously and revert once the engine is healthy:
            kubectl patch validatingwebhookconfiguration cnpa-governance-guard \
              --type=json \
              -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'

 5) Verify recovery
    ./break_fix.sh verify
        # [ ok ] Pod admission SUCCEEDS ...
    kubectl -n cnpa-lab-23 rollout status deploy/governance-demo
        # deployment "governance-demo" successfully rolled out
    kubectl -n cnpa-lab-23 get pods
        # governance-demo-... 1/1 Running

 6) Production takeaways (exam-relevant)
    * failurePolicy: Fail = fail closed (safe for governance, dangerous for
      availability). failurePolicy: Ignore = fail open (available, but a
      broken engine means policies are NOT enforced). Choose per policy.
    * ALWAYS scope webhooks with namespaceSelector / objectSelector so the
      engine can never intercept its own namespace or kube-system — otherwise
      a crashed engine cannot be restarted (deadlock).
    * A policy engine is a hard dependency of the API write path. Monitor its
      webhook backend health and admission latency (timeoutSeconds), and have
      a documented break-glass procedure to delete/patch the webhook.
    * If you don't need an external backend, prefer the in-tree
      ValidatingAdmissionPolicy (CEL): no webhook, no backend to fail,
      no fail-open/closed dilemma for those rules.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpa/2.3/lab)
