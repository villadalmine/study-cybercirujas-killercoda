## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — step-by-step investigation and remediation (try before reading!)

 Mindset: you are reconstructing an attack from the evidence it left, exactly
 as CKS 6.3 asks. Work outside-in: broad triage first, then confirm each
 artifact, map it to a phase, and only then eradicate.

 STEP 1 — Triage: what is running that should not be?
   # Every Pod, everywhere, with the security-relevant columns exposed:
   kubectl get pods -A -o wide
   kubectl get pods -A -o custom-columns=\
'NS:.metadata.namespace,POD:.metadata.name,'\
'PRIV:.spec.containers[*].securityContext.privileged,'\
'HOSTPID:.spec.hostPID,HOSTNET:.spec.hostNetwork,SA:.spec.serviceAccountName'

   -> 'dev/support-tools' stands out: privileged=true, hostPID=true,
      hostNetwork=true. That is your beachhead (Execution + Escape-to-Host).

   # Confirm the node-escape indicator (hostPath '/' mounted into the pod):
   kubectl -n dev get pod support-tools -o yaml | grep -A4 -iE 'hostPath|volumeMounts|privileged'

 STEP 2 — Who is the bad actor's identity? (Privilege Escalation)
   # The pod runs as 'support-sa'. Find what that identity can do:
   kubectl get clusterrolebindings -o custom-columns=\
'NAME:.metadata.name,ROLE:.roleRef.name,SUBJECTS:.subjects[*].name' \
     | grep -Ei 'cluster-admin|support-sa'

   # Or, list every subject bound to cluster-admin (find the odd one out):
   kubectl get clusterrolebinding -o jsonpath=\
'{range .items[?(@.roleRef.name=="cluster-admin")]}{.metadata.name}{"\t"}{.subjects[*].name}{"\n"}{end}'

   # Prove it from the attacker's point of view:
   kubectl auth can-i '*' '*' -A \
     --as=system:serviceaccount:dev:support-sa   # -> yes  (full cluster control)

   -> 'support-sa-cluster-admin' binds dev/support-sa to cluster-admin.
      That is Privilege Escalation + a Persistence identity.

 STEP 3 — Credential Access: what did they collect?
   kubectl -n dev get secrets
   kubectl -n dev get secret exfil-token -o jsonpath='{.data.stolen_sa_token}' | base64 -d; echo
   -> a stashed/stolen token. Treat any real token found this way as burned:
      rotate/revoke it after the lab.

 STEP 4 — Persistence #1: scheduled re-entry
   kubectl get cronjobs -A
   kubectl -n kube-system get cronjob metrics-collector -o yaml | grep -iE 'privileged|hostPID|schedule'
   -> 'kube-system/metrics-collector' relaunches a privileged pod every minute.
      Named to blend in (Defense Evasion) — but no real platform ships it.

 STEP 5 — Persistence #2: node-level static Pod (the sneaky one)
   # A static Pod has NO controller/ownerReferences and its name ends in the
   # node hostname. 'kubectl delete' on the mirror Pod is undone by kubelet.
   kubectl -n kube-system get pods -o wide | grep kube-proxy-audit
   kubectl -n kube-system get pod <kube-proxy-audit-...> -o jsonpath='{.metadata.ownerReferences}'; echo
   # The source of truth is a FILE on the node:
   sudo ls -l /etc/kubernetes/manifests/
   sudo cat /etc/kubernetes/manifests/kube-proxy-audit.yaml

 STEP 6 — Corroborate with the audit trail / runtime sensor (the "investigate")
   # If API-server auditing is enabled, the RBAC change and pod creation are logged:
   sudo grep -E 'clusterrolebindings|support-sa|support-tools' \
        /var/log/kubernetes/audit/audit.log | jq -r '.verb+" "+.objectRef.resource+"/"+(.objectRef.name//"")'
   # (Docs: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
   # If Falco is running, its alerts pin the timeline (privileged pod, host mount,
   # sensitive-mount, shell-in-container). https://falco.org/docs/
   # On the node, inspect what the beachhead actually did:
   sudo crictl ps | grep support-tools
   kubectl -n dev logs support-tools
   kubectl -n dev exec support-tools -- cat /tmp/.beacon.log

 STEP 7 — Map the kill chain (this IS the deliverable of topic 6.3)
   Initial Access / Persistence : ClusterRoleBinding support-sa-cluster-admin
   Execution / Escape to Host   : Pod dev/support-tools (privileged,hostPID,hostPath /)
   Credential Access            : Secret dev/exfil-token
   Persistence (scheduled)      : CronJob kube-system/metrics-collector
   Persistence (node)           : static Pod /etc/kubernetes/manifests/kube-proxy-audit.yaml
   Defense Evasion              : ns 'dev' relabelled PodSecurity enforce=privileged;
                                  malicious pod labelled app=payment-api to masquerade

 STEP 8 — Eradicate (surgically — keep 'payment-api')
   kubectl -n dev delete pod support-tools
   kubectl delete clusterrolebinding support-sa-cluster-admin
   kubectl -n dev delete sa support-sa
   kubectl -n kube-system delete cronjob metrics-collector
   kubectl -n dev delete secret exfil-token
   # Node persistence — remove the FILE, kubelet then tears down the mirror Pod:
   sudo rm -f /etc/kubernetes/manifests/kube-proxy-audit.yaml

 STEP 9 — Harden / undo the defense evasion
   kubectl label ns dev \
     pod-security.kubernetes.io/enforce=baseline \
     pod-security.kubernetes.io/warn=baseline \
     pod-security.kubernetes.io/audit=baseline --overwrite
   # (Prefer 'restricted' if the real workloads tolerate it.)

 STEP 10 — Verify closure
   ./break_fix.sh verify        # every check must PASS
   kubectl auth can-i '*' '*' -A --as=system:serviceaccount:dev:support-sa   # -> no
   kubectl get pods -A -o custom-columns=NS:.metadata.namespace,\
POD:.metadata.name,PRIV:.spec.containers[*].securityContext.privileged | grep true
     # -> only your legitimate/system components remain.

 Post-incident: rotate any real credentials the attacker could have read via
 cluster-admin, enable/keep API-server auditing and a runtime sensor (Falco),
 and enforce Pod Security so the initial privileged-pod step is blocked at the
 admission layer next time.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cks/6.3/lab)
