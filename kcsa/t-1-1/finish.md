## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 ██  SOLUTION — do not read until you have tried  ██

 The order matters. Fix the Cloud layer first: a hardened pod on a node whose
 kubelet answers anonymously is decoration. Then Cluster, then Container, then
 Code — outside-in, exactly the way the 4Cs model is drawn.

 STEP 1 — CLOUD: node and credential hygiene

 1.1 Credentials
     chmod 600 ~/.kube/config
     rm -f /tmp/kubeconfig-lab-copy.yaml
     # Rationale: kubeconfig for cluster-admin is a bearer credential. Anyone
     # who can read the file is cluster-admin; file mode IS the access control.

 1.2 Container runtime socket
     sudo chmod 660 /var/run/docker.sock
     # Write access to the runtime socket == root on the node, because you can
     # ask the daemon to start a privileged container that bind-mounts /.

 1.3 Host firewall
     sudo iptables -S INPUT | grep kcsa-4c-lab
     sudo iptables -D INPUT -p tcp -m multiport --dports 6443,10250,10255 \
          -m comment --comment kcsa-4c-lab -j ACCEPT
     # In a managed cloud this is the security group / NSG: the control-plane
     # and kubelet ports must never be reachable from 0.0.0.0/0.

 1.4 Kubelet authentication (run on the node; on kind, inside the container)
     NODE=$(kubectl config current-context); NODE=${NODE#kind-}-control-plane
     docker exec -it "$NODE" bash
       vi /var/lib/kubelet/config.yaml
       # authentication:
       #   anonymous:
       #     enabled: false        <-- was true
       #   webhook:
       #     enabled: true
       # authorization:
       #   mode: Webhook           <-- never AlwaysAllow
       # readOnlyPort: 0           <-- was 10255
       systemctl restart kubelet
       exit
     kubectl wait --for=condition=Ready node --all --timeout=120s
     # Verify from the host:
     #   curl -sk -o /dev/null -w '%{http_code}\n' https://<node-ip>:10250/pods  -> 401
     #   curl -s  -m 5 http://<node-ip>:10255/pods                               -> refused
     # The kubelet is a second API server on every node. anonymous+AlwaysAllow
     # there gives /exec on every pod, which is cluster-admin by another route.
     # https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/

 STEP 2 — CLUSTER: RBAC, admission, network segmentation

 2.1 Revoke anonymous authority
     kubectl auth can-i '*' '*' --as=system:anonymous            # -> yes (bad)
     kubectl get clusterrolebinding -o json | \
       jq -r '.items[] | select(.subjects[]?.name |
              test("system:anonymous|system:unauthenticated")) | .metadata.name'
     kubectl delete clusterrolebinding kcsa-4c-lab-anonymous-cluster-admin \
                                       kcsa-4c-lab-anonymous-kubelet-api
     kubectl auth can-i '*' '*' --as=system:anonymous            # -> no
     # Keep system:public-info-viewer — that default binding only exposes
     # /version and /healthz to system:unauthenticated.

 2.2 Least privilege for the workload identity
     kubectl delete clusterrolebinding kcsa-4c-lab-sa-cluster-admin
     kubectl auth can-i list secrets -A \
       --as=system:serviceaccount:kcsa-4c-lab:payments-api        # -> no
     # payments-api serves HTTP; it needs ZERO Kubernetes API permissions.
     # If a workload needs none, do not give it a token at all (step 3.3).

 2.3 Pod Security Admission at the 'restricted' level, version-pinned
     kubectl label ns kcsa-4c-lab \
       pod-security.kubernetes.io/enforce=restricted \
       pod-security.kubernetes.io/enforce-version=v1.31 \
       pod-security.kubernetes.io/audit=restricted \
       pod-security.kubernetes.io/warn=restricted --overwrite
     # PSA is ADMISSION-time only: the already-running privileged pod keeps
     # running. That is why step 3 must roll the Deployment, and why 'label the
     # namespace' is never by itself a remediation.
     # https://kubernetes.io/docs/concepts/security/pod-security-standards/

 2.4 Default-deny plus one explicit allow
     cat <<'YAML' | kubectl apply -f -
     apiVersion: networking.k8s.io/v1
     kind: NetworkPolicy
     metadata:
       name: default-deny-ingress
       namespace: kcsa-4c-lab
     spec:
       podSelector: {}
       policyTypes: ["Ingress"]
     ---
     apiVersion: networking.k8s.io/v1
     kind: NetworkPolicy
     metadata:
       name: allow-checkout-to-payments-api
       namespace: kcsa-4c-lab
     spec:
       podSelector:
         matchLabels: { app: payments-api }
       policyTypes: ["Ingress"]
       ingress:
         - from:
             - podSelector:
                 matchLabels: { app: checkout }
           ports:
             - protocol: TCP
               port: 8080
     YAML
     # NetworkPolicies are additive and there is no 'deny' rule: you deny by
     # selecting pods with no matching allow. Two caveats the exam likes:
     #   * the policy is enforced by the CNI — kindnetd and the minikube bridge
     #     accept the object and enforce nothing (Calico/Cilium/k3s do enforce);
     #   * NetworkPolicy does not apply to hostNetwork pods, which is one more
     #     reason step 3 removes host namespaces.
     # https://kubernetes.io/docs/concepts/services-networking/network-policies/

 STEP 3 — CODE first, then CONTAINER (the Secret must exist before the roll)

 3.1 Move the credentials out of configuration
     kubectl -n kcsa-4c-lab create secret generic payments-api-credentials \
       --from-literal=APP_DB_PASSWORD='kcsa-lab-Pr0d-DB-P4ssw0rd-DO-NOT-REUSE' \
       --from-literal=APP_API_TOKEN='tok_live_4c5a_kcsa_lab_do_not_reuse' \
       --from-literal=APP_SIGNING_SECRET='kcsa-lab-Pr0d-DB-P4ssw0rd-DO-NOT-REUSE'
     kubectl -n kcsa-4c-lab create configmap payments-api-config \
       --from-literal=APP_ENV=production \
       --from-literal=APP_DB_HOST=postgres.payments.svc.cluster.local \
       --from-literal=APP_DB_USER=payments_rw \
       --dry-run=client -o yaml | kubectl apply -f -
     # A Secret is base64, NOT encryption. Two follow-ups that belong to the
     # Cluster and Cloud layers respectively, and that the exam expects you to
     # name: EncryptionConfiguration for secrets at rest in etcd, and RBAC that
     # keeps 'get secrets' off ordinary roles. Better still, an external store
     # (Vault / cloud KMS) via the Secrets Store CSI driver, so the value never
     # lands in etcd at all. In the real world you would also ROTATE this
     # credential — it was in a ConfigMap, therefore it is burned.
     # https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/

 3.2 Rewrite the workload to the 'restricted' profile
     cat <<'YAML' | kubectl apply -f -
     apiVersion: apps/v1
     kind: Deployment
     metadata:
       name: payments-api
       namespace: kcsa-4c-lab
       labels: { app: payments-api }
     spec:
       replicas: 1
       selector:
         matchLabels: { app: payments-api }
       template:
         metadata:
           labels: { app: payments-api }
         spec:
           serviceAccountName: payments-api
           automountServiceAccountToken: false     # the app never calls the API
           terminationGracePeriodSeconds: 2
           securityContext:
             runAsNonRoot: true
             runAsUser: 10001
             runAsGroup: 10001
             fsGroup: 10001
             seccompProfile: { type: RuntimeDefault }
           containers:
             - name: api
               image: busybox:1.36                 # pinned; prefer a digest
               imagePullPolicy: IfNotPresent
               command: ["sh","-c"]
               args:
                 - 'echo "payments-api v1 (kcsa 4c lab)" > /tmp/index.html; exec httpd -f -p 8080 -h /tmp'
               ports:
                 - containerPort: 8080
               envFrom:
                 - configMapRef: { name: payments-api-config }
                 - secretRef:    { name: payments-api-credentials }
               securityContext:
                 allowPrivilegeEscalation: false
                 readOnlyRootFilesystem: true
                 capabilities: { drop: ["ALL"] }
               resources:
                 requests: { cpu: "50m",  memory: "32Mi" }
                 limits:   { cpu: "200m", memory: "128Mi" }
               volumeMounts:
                 - name: tmp
                   mountPath: /tmp
           volumes:
             - name: tmp
               emptyDir: { sizeLimit: 8Mi }        # required by readOnlyRootFilesystem
     YAML
     kubectl -n kcsa-4c-lab rollout status deploy/payments-api --timeout=180s
     # What each field buys you:
     #   privileged/hostPID/hostIPC/hostPath removed -> the container is a
     #     namespace boundary again, not a shell on the node.
     #   runAsNonRoot + runAsUser 10001 -> a container escape lands as an
     #     unprivileged uid; uid 0 in the container is uid 0 on the host unless
     #     user namespaces are enabled.
     #   allowPrivilegeEscalation=false -> sets no_new_privs; setuid binaries
     #     inside the image can no longer raise privilege.
     #   drop ALL -> removes even the default capability set (NET_RAW enables
     #     ARP spoofing of the whole node network).
     #   readOnlyRootFilesystem -> the attacker cannot drop a binary or patch
     #     the app; it also makes the filesystem diff a real IoC signal.
     #   seccompProfile RuntimeDefault -> ~44 dangerous syscalls blocked; PSS
     #     'restricted' requires it explicitly.
     #   limits -> a compromised pod cannot starve the node (DoS is a security
     #     property, and a pod with no requests/limits is BestEffort, first to
     #     be evicted and easiest to weaponise).
     #   automountServiceAccountToken: false -> nothing to steal from
     #     /var/run/secrets/... The Code layer can no longer reach the Cluster layer.

 3.3 Confirm the escape routes are closed
     POD=$(kubectl -n kcsa-4c-lab get pod -l app=payments-api -o name | head -1)
     kubectl -n kcsa-4c-lab exec $POD -- id                     # uid=10001, not 0
     kubectl -n kcsa-4c-lab exec $POD -- ls /host                # no such file
     kubectl -n kcsa-4c-lab exec $POD -- ls /var/run/secrets/kubernetes.io  # no such file
     kubectl -n kcsa-4c-lab exec $POD -- touch /etc/x            # read-only file system

 STEP 4 — prove the service survived, then score
     kubectl -n kcsa-4c-lab exec checkout  -- wget -qO- http://payments-api:8080/   # works
     kubectl -n kcsa-4c-lab exec intruder  -- wget -qO- -T 5 http://payments-api:8080/  # times out (with a real CNI)
     ./4cs-break-and-fix.sh verify        # 14/14, exit 0
     ./4cs-break-and-fix.sh clean

 WHY THIS IS ONE EXERCISE AND NOT FOUR
 Trace the kill chain you just dismantled, and notice that every link crosses a
 layer boundary — which is the entire point of the 4Cs model:

   CODE      a credential in a ConfigMap leaks through any log, describe or
             crash dump                                     →
   CONTAINER the same pod runs as root with hostPath / and hostPID, so leaking
             is not even necessary: read the node's filesystem directly →
   CLUSTER   the auto-mounted token belongs to a cluster-admin ServiceAccount,
             and no NetworkPolicy limits who can talk to the pod in the first
             place                                          →
   CLOUD     the kubelet accepts anonymous calls and the firewall lets the
             whole internet reach it, so an attacker never needed the pod.

 Each layer only constrains what it contains. Hardening the innermost layer
 while the outermost is open just moves the cheapest path, it does not close
 it — and hardening the outermost while the innermost is open only means the
 attacker has to get in once. Defence in depth means all four, and the graded
 availability checks are there because a control that takes production down is
 a control that gets disabled on Monday.

 Sources:
   CNCF KCSA Curriculum — https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
   Kubernetes Security Overview (the 4C model) —
     https://kubernetes.io/docs/concepts/security/overview/
   Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
   RBAC — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
   Kubelet authn/authz — https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
   NetworkPolicy — https://kubernetes.io/docs/concepts/services-networking/network-policies/
   Encrypting secret data at rest — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/kcsa/1.1/lab)
