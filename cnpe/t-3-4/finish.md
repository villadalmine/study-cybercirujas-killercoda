## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
STEP-BY-STEP SOLUTION (DO NOT READ UNTIL YOU HAVE ATTEMPTED THE FIX)

STEP 1: Diagnose the Webhook Outage
Run:
  kubectl get validatingwebhookconfigurations
  kubectl describe validatingwebhookconfiguration governance-policy-webhook

Observation:
  Notice 'failurePolicy: Fail' and 'namespaceSelector: {}'.
  The webhook service 'governance-policy-backend' on port 9443 does not exist,
  causing connection refused errors on ALL pod operations cluster-wide.

STEP 2: Remediate the ValidatingWebhookConfiguration
Update the webhook configuration to use 'failurePolicy: Ignore' OR restrict
namespace scope so system namespaces like 'kube-system' are excluded using
matchExpressions:

  kubectl edit validatingwebhookconfiguration governance-policy-webhook

Modify the spec as follows:
  failurePolicy: Ignore
  namespaceSelector:
    matchExpressions:
    - key: kubernetes.io/metadata.name
      operator: NotIn
      values: ["kube-system", "kube-public", "kube-node-lease"]

STEP 3: Diagnose the CEL Policy Runtime Error
Run:
  kubectl describe validatingadmissionpolicy require-non-root-user-policy

Observation:
  The expression: "object.spec.containers.all(c, c.securityContext.runAsNonRoot == true)"
  fails with an evaluation error when 'securityContext' is nil/undefined on a container.

STEP 4: Fix the CEL Expression for Safe Dereferencing
Edit the policy:
  kubectl edit validatingadmissionpolicy require-non-root-user-policy

Update the validations expression to use 'has()' guards:
  validations:
    - expression: "object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.runAsNonRoot) && c.securityContext.runAsNonRoot == true)"
      message: "Security Policy Error: Containers must explicitly set runAsNonRoot to true."

STEP 5: Verify the Fix
Run:
  ./break_fix.sh --check
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpe/3.4/lab)
