## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — do not read before attempting the lab

 ROOT CAUSE
 The ClusterPolicy carries this annotation:

     metadata:
       annotations:
         pod-policies.kyverno.io/autogen-controllers: "none"

 Kyverno's autogen feature normally reads any rule whose match block targets
 ONLY the kind Pod and derives equivalent rules for the Pod controllers,
 rewriting the JMESPath/pattern root as it goes:

     Pod                      spec.<...>
     Deployment/DaemonSet/    spec.template.spec.<...>       -> autogen-<rule>
       StatefulSet/Job/
       ReplicaSet/ReplicationController
     CronJob                  spec.jobTemplate.spec.template.spec.<...>
                                                             -> autogen-cronjob-<rule>

 The value "none" switches that off. The Pod rule stays perfectly valid — it
 is the reason the Pods get denied — but nothing evaluates the Deployment or
 the CronJob, so both are admitted and the violation only surfaces later, in
 the ReplicaSet/Job controller, as FailedCreate events nobody is watching.
 Kyverno also derives its webhook registration from the matched kinds, so
 with autogen off the resource webhook is not even registered for
 apps/deployments or batch/cronjobs.

 STEP BY STEP
 1. Confirm the Pod rule works and the parent objects were admitted:

      kubectl -n kca59-autogen get deploy,rs,pod
      # deployment.apps/legacy-api   0/2   0   0
      # replicaset.apps/legacy-api-6d4f8c9b7   2   0   0
      # (no pods)

      kubectl -n kca59-autogen describe rs -l app=legacy-api | sed -n '/Events:/,$p'
      # Warning FailedCreate ... admission webhook "validate.kyverno.svc-fail"
      # denied the request: ... kca59-require-nonroot: check-runasnonroot:
      # 'validation error: Workloads in kca59-autogen must run as non-root...'

    Reading: the policy is alive and enforcing. The failure is one level too
    late. That combination — Pod denied, controller accepted — is the
    signature of an autogen problem, not of a rule problem.

 2. Prove that Kyverno is running no derived rules:

      kubectl get cpol kca59-require-nonroot -o jsonpath='{.status.autogen.rules[*].name}'; echo
      # (empty)

    On a healthy policy this prints:
      autogen-check-runasnonroot autogen-cronjob-check-runasnonroot

 3. Find the switch:

      kubectl get cpol kca59-require-nonroot -o yaml | grep -A6 'annotations:'
      # pod-policies.kyverno.io/autogen-controllers: "none"

 4. Fix it. Removing the annotation restores the default controller set,
    which is what you want in almost every real cluster:

      kubectl annotate cpol kca59-require-nonroot \
        pod-policies.kyverno.io/autogen-controllers-

    Equivalent, explicit form (use it only when you deliberately want a
    narrower set; every kind you leave out stays unguarded):

      kubectl annotate --overwrite cpol kca59-require-nonroot \
        pod-policies.kyverno.io/autogen-controllers=DaemonSet,Deployment,Job,StatefulSet,ReplicaSet,ReplicationController,CronJob

 5. Verify the derived rules exist and the webhook picked them up (allow a
    few seconds for the webhook configuration to be rewritten):

      kubectl get cpol kca59-require-nonroot -o jsonpath='{.status.autogen.rules[*].name}'; echo
      # autogen-check-runasnonroot autogen-cronjob-check-runasnonroot

      kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
        -o jsonpath='{.webhooks[*].rules[*].resources}'; echo
      # ... "deployments" ... "cronjobs" ... "pods" ...

 6. Prove fail-fast without creating anything (server-side dry run executes
    the admission chain, which is the cheapest way to test a policy against a
    live cluster):

      kubectl apply -f bad-deploy.yaml --dry-run=server
      # Error from server: error when creating "bad-deploy.yaml": admission
      # webhook "validate.kyverno.svc-fail" denied the request:
      # resource Deployment/kca59-autogen/legacy-api was blocked due to the
      # following policies
      #
      # kca59-require-nonroot:
      #   autogen-check-runasnonroot: 'validation error: Workloads in
      #     kca59-autogen must run as non-root...'

    Note the rule name in the message: autogen-check-runasnonroot. That
    prefix is how you tell a derived denial from a hand-written one when you
    are reading someone else's incident ticket.

 7. Clear the wreckage left by the broken state and re-run the grader:

      kubectl -n kca59-autogen delete deploy legacy-api
      kubectl -n kca59-autogen delete cronjob nightly-report
      ./kca-5.9-autogen-breakfix.sh verify

 WHAT THE EXAM EXPECTS YOU TO KNOW BEYOND THE FIX
 * Autogen triggers only when the rule matches Pod and nothing else. Add a
   non-Pod kind (ConfigMap, Service) to the same rule's match block and
   Kyverno silently stops generating controller rules — same symptom,
   different cause, and no annotation to point at. Split such rules.
 * Derived rules are computed, not stored as authored content: you cannot
   edit them, and editing the source rule regenerates them. They surface in
   status.autogen.rules; older releases materialised them into spec.rules.
 * "none" is legitimate in exactly two situations: a rule that must apply to
   directly-created Pods only, and a policy where you hand-write the
   controller logic because the derived path rewrite would be wrong.
 * Autogen covers validate, mutate, generate and verifyImages rules, and the
   CronJob variant carries its own prefix because it needs a second level of
   template nesting.
 * Autogen is an admission-time convenience. It does not change what the Pod
   rule does, and it does not retroactively evict workloads that were already
   running: for that you need the background scan and the resulting
   PolicyReport / ClusterPolicyReport objects.
 * Offline equivalent for CI, no cluster required:
     kubectl kyverno apply policy.yaml --resource bad-deploy.yaml

 REFERENCES
 - Auto-Gen Rules for Pod Controllers — https://kyverno.io/docs/writing-policies/autogen/
 - Kyverno documentation index      — https://kyverno.io/docs/
 - Kyverno source                   — https://github.com/kyverno/kyverno
 - KCA curriculum                   — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
 - Dynamic admission control        — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/kca/5.9/lab)
