## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — read only after you have tried

 MENTAL MODEL FIRST
 A `generate` rule is not an admission-time mutation. The admission webhook
 only records the intent: it creates an ${C}UpdateRequest${C} (CR
 updaterequests.kyverno.io, namespaced in the Kyverno namespace), and the
 ${C}background controller${C} reconciles it out-of-band. Three consequences,
 and every fault in this lab is one of them:

   1. The creating identity is the background controller ServiceAccount, not
      the user. RBAC of the requesting user is irrelevant; RBAC of that SA is
      everything. Kyverno ships a deliberately small default grant and expects
      you to extend it with AGGREGATED ClusterRoles.
   2. Generate needs background processing (spec.background), so the rule may
      not use admission-only variables such as {{request.userInfo.*}} — a rule
      that does is rejected at policy admission time. Related trap, not used
      here, but it is exam material.
   3. Two independent switches decide *when* Kyverno acts:
        generate.synchronize  -> keep the downstream identical to the rule and
                                 recreate it if someone deletes or edits it
        spec.generateExisting -> process triggers that ALREADY existed when the
                                 policy was created/updated
                                 (pre-1.10 name: generateExistingOnPolicyUpdate;
                                  1.13+ also allows it per-rule under generate)
      Neither implies the other.

 DIAGNOSIS PATH (what an SRE actually types)
   kubectl get clusterpolicy tenant-namespace-baseline -o yaml
   kubectl describe clusterpolicy tenant-namespace-baseline          # events
   kubectl -n kyverno get updaterequests.kyverno.io
   kubectl -n kyverno get updaterequests.kyverno.io <ur> -o yaml     # .status.message
   kubectl -n kyverno logs deploy/kyverno-background-controller | grep -i generate
   kubectl get netpol,resourcequota,cm -A -l generate.kyverno.io/policy-name=tenant-namespace-baseline
   kubectl auth can-i create tenantguards --as=system:serviceaccount:kyverno:kyverno-background-controller -n lab-tenant-a
 PolicyReports are useless here on purpose: generate rules do not report.

 FAULT 1 — the background controller lost the permission to create TenantGuard
 Symptom: UR .status.message contains
   "... is forbidden: User \"system:serviceaccount:kyverno:kyverno-background-controller\"
    cannot create resource \"tenantguards\" in API group \"lab.kca.local\""
 Cause: the ClusterRole kyverno:background-controller:kca-lab lost the label
 that aggregates it into the controller's role.
 Fix:
   kubectl label clusterrole kyverno:background-controller:kca-lab \
     rbac.kyverno.io/aggregate-to-background-controller=true
   # verify (kube-controller-manager recomputes the aggregate in ~1-5s)
   kubectl auth can-i create tenantguards \
     --as=system:serviceaccount:kyverno:kyverno-background-controller -n lab-tenant-a
   yes
 Note: this is exactly what happens in production the first time you generate a
 cert-manager Certificate, an Istio PeerAuthentication or any CRD — Kyverno's
 default grant covers only common core/networking/rbac kinds.

 FAULT 2 — the clone source moved
 Symptom: UR message "... source resource platform-system/tenant-baseline not found ...".
 Cause: the ConfigMap now lives in platform-baselines; the rule still points at
 platform-system.
 Fix (preferred — follow the source):
   kubectl patch clusterpolicy tenant-namespace-baseline --type=json \
     -p '[{"op":"replace","path":"/spec/rules/2/generate/clone/namespace","value":"platform-baselines"}]'
 Alternative (restore the contract): copy the ConfigMap back into
 platform-system. Either is defensible; do not do both silently.
 Remember the source must stay readable by the background controller, and with
 synchronize: true every later edit of the source is pushed to every clone.

 FAULT 3 — wrong downstream namespace expression on the ResourceQuota rule
 Symptom: no ResourceQuota in the tenant namespace; the UR fails or the object
 materialises somewhere unexpected.
 Cause: generate.namespace was set to "{{request.namespace}}". The trigger is a
 Namespace, a CLUSTER-SCOPED object, so request.namespace is the empty string.
 The name of a namespace trigger lives in request.object.metadata.name.
 Fix:
   kubectl patch clusterpolicy tenant-namespace-baseline --type=json \
     -p '[{"op":"replace","path":"/spec/rules/1/generate/namespace","value":"{{request.object.metadata.name}}"}]'
 Then delete any stray object the broken expression produced, e.g.
   kubectl -n default delete resourcequota tenant-quota --ignore-not-found

 FAULT 4 — synchronize + generateExisting both off
 Symptoms: (a) a deleted NetworkPolicy is never restored; (b) lab-legacy, which
 pre-dates the policy, received nothing.
 Fix:
   kubectl patch clusterpolicy tenant-namespace-baseline --type=json -p '[
     {"op":"replace","path":"/spec/rules/0/generate/synchronize","value":true},
     {"op":"replace","path":"/spec/generateExisting","value":true}]'
 synchronize: true also makes the downstream immutable in practice — a tenant
 editing the NetworkPolicy is reverted by the sync controller. That is the
 whole point of a security baseline.

 THE TRAP: fixing the cause does not replay an exhausted UpdateRequest
 An UpdateRequest retries a bounded number of times and then stays Failed. After
 repairing RBAC you must produce a new trigger event. Any of these works:
   # re-trigger via the trigger resource (a Namespace UPDATE matches the rule)
   kubectl label ns lab-tenant-a kca.lab/reconcile=$(date +%s) --overwrite
   kubectl label ns lab-legacy   kca.lab/reconcile=$(date +%s) --overwrite
   # or re-trigger via the policy (with generateExisting: true this sweeps
   # every already-existing matching namespace)
   kubectl annotate clusterpolicy tenant-namespace-baseline \
     kca.lab/reconcile=$(date +%s) --overwrite
 Finally clear the dead queue entries:
   kubectl -n kyverno delete updaterequests.kyverno.io \
     $(kubectl -n kyverno get updaterequests.kyverno.io \
       -o jsonpath='{range .items[?(@.status.state=="Failed")]}{.metadata.name} {end}')

 ONE-SHOT REPAIR (equivalent to editing the policy by hand)
   kubectl label clusterrole kyverno:background-controller:kca-lab \
     rbac.kyverno.io/aggregate-to-background-controller=true
   kubectl patch clusterpolicy tenant-namespace-baseline --type=json -p '[
     {"op":"replace","path":"/spec/generateExisting","value":true},
     {"op":"replace","path":"/spec/rules/0/generate/synchronize","value":true},
     {"op":"replace","path":"/spec/rules/1/generate/namespace","value":"{{request.object.metadata.name}}"},
     {"op":"replace","path":"/spec/rules/2/generate/clone/namespace","value":"platform-baselines"}]'
   kubectl label ns lab-tenant-a kca.lab/reconcile=$(date +%s) --overwrite
   kubectl label ns lab-legacy   kca.lab/reconcile=$(date +%s) --overwrite
   ./kca-5.5-generation-rules-breakfix.sh verify

 EXPECTED FINAL STATE
   $ kubectl -n lab-legacy get netpol,resourcequota,cm,tenantguards.lab.kca.local
   NAME                                                  POD-SELECTOR   AGE
   networkpolicy.networking.k8s.io/default-deny-ingress   <none>        40s
   NAME                      AGE   REQUEST                                          LIMIT
   resourcequota/tenant-quota 40s  pods: 0/20, requests.cpu: 0/4, requests.memory: 0/8Gi   limits.cpu: 0/8, limits.memory: 0/16Gi
   NAME                        DATA   AGE
   configmap/kube-root-ca.crt     1   3m
   configmap/tenant-baseline      3   40s
   NAME                                        AGE
   tenantguard.lab.kca.local/baseline-guard    40s

 WHAT TO CARRY INTO THE EXAM
  * data vs clone vs cloneList; clone follows the source, data is the spec.
  * synchronize != generateExisting != orphanDownstreamOnPolicyDelete
    (the last one decides whether downstreams survive the policy's deletion).
  * Generated objects are labelled generate.kyverno.io/policy-name,
    /rule-name and /trigger-* — that is how the sync controller finds them and
    how you audit them.
  * The generate path runs as the background controller SA and is invisible to
    PolicyReports; UpdateRequests are its status surface.
  * Deleting the TRIGGER deletes the synchronised downstreams; deleting the
    downstream only makes Kyverno rebuild it.

 Sources: https://kyverno.io/docs/writing-policies/generate/ ,
          https://kyverno.io/docs/installation/customization/ ,
          https://kyverno.io/docs/troubleshooting/ ,
          https://kubernetes.io/docs/reference/access-authn-authz/rbac/ ,
          https://github.com/cncf/curriculum
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/kca/5.5/lab)
