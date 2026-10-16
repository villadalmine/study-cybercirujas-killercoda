## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — STEP BY STEP
 (read only after you have tried; 'verify' grades the same 8 requirements)

 There are FOUR independent faults. Two kill the API server, two silently
 destroy the value of the audit trail:

   A. The 'audit-policy' hostPath volume is declared, but the matching
      volumeMount is missing -> the container cannot see /etc/kubernetes/audit.
   B. The 'audit-log' volumeMount is readOnly: true -> the API server cannot
      create /var/log/kubernetes/audit/audit.log.
   C. The policy starts with a bare '- level: None' rule. Rules are evaluated
      in order and the first match wins, so every request is dropped.
   D. Retention is set to 1 day / 1 backup / 1 MB, and the policy logs Secrets
      in a way that is either useless or dangerous.

STEP 0 — Accept that kubectl is dead and debug the static Pod from the node
  $ kubectl get nodes
  The connection to the server 127.0.0.1:6443 was refused ...

  $ sudo crictl ps -a --name kube-apiserver
  CONTAINER      IMAGE          CREATED         STATE     NAME             ...
  9f2a1c4d0b7e   c3994bc696102  8 seconds ago   Exited    kube-apiserver   ...

  $ sudo crictl logs --tail=20 9f2a1c4d0b7e
  E0806 12:04:11.882119  1 run.go:74] "command failed" err="failed to initialize audit:
    failed to read audit policy file: open /etc/kubernetes/audit/policy.yaml:
    no such file or directory"

  Equivalent sources when crictl is not available:
    sudo tail -40 /var/log/pods/kube-system_kube-apiserver-*/kube-apiserver/*.log
    sudo journalctl -u kubelet -n 100 --no-pager | grep -i apiserver

  Note the file DOES exist on the host:
    $ sudo ls -l /etc/kubernetes/audit/policy.yaml
    -rw-r--r--. 1 root root 271 Aug  6 12:03 /etc/kubernetes/audit/policy.yaml
  ...so this is a mount problem, not a missing-file problem.

STEP 1 — Fault A: add the missing volumeMount for the policy directory
  $ sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml

  Under spec.containers[0].volumeMounts add (4-space indent, like its siblings):

      - mountPath: /etc/kubernetes/audit
        name: audit-policy
        readOnly: true

  The volume itself was already there, under spec.volumes:

    - hostPath:
        path: /etc/kubernetes/audit
        type: DirectoryOrCreate
      name: audit-policy

  RULE OF THUMB for every CKS static-Pod task: a hostPath needs BOTH halves,
  spec.volumes AND containers[].volumeMounts, and the 'name' must match exactly.

  Save. The kubelet re-creates the Pod within ~20 s. Watch it:
    $ watch -n2 'sudo crictl ps -a --name kube-apiserver'

STEP 2 — Fault B: the log directory is mounted read-only
  $ sudo crictl logs --tail=20 $(sudo crictl ps -a --name kube-apiserver -q | head -1)
  E0806 12:07:52.114003  1 run.go:74] "command failed" err="failed to initialize audit:
    failed to open audit log file: open /var/log/kubernetes/audit/audit.log:
    read-only file system"

  Policy in = read-only. Log out = read-write. Fix the audit-log mount:

      - mountPath: /var/log/kubernetes/audit
        name: audit-log
        readOnly: false

  (Deleting the readOnly line entirely works too; false is the default.)

  Now the API server should start:
    $ sudo crictl ps --name kube-apiserver
    $ kubectl get --raw='/healthz'
    ok

STEP 3 — Fault C: the catch-all None rule at the top of the policy
  $ sudo ls -l /var/log/kubernetes/audit/audit.log
  -rw-------. 1 root root 0 Aug  6 12:09 /var/log/kubernetes/audit/audit.log

  Zero bytes on a live cluster is the signature of a policy that matches
  everything with level None. Audit rules are ordered and the FIRST match
  wins; a bare '- level: None' as rule #1 silences the whole cluster and makes
  every rule below it dead code.

STEP 4 — Write a policy that is actually useful (fixes C and D)
  $ sudo tee /etc/kubernetes/audit/policy.yaml >/dev/null <<'POLICY'
  apiVersion: audit.k8s.io/v1
  kind: Policy
  # RequestReceived is emitted before the request is even handled: it doubles
  # the volume and carries no outcome. Drop it globally.
  omitStages:
    - RequestReceived
  rules:
    # 1. Kill the highest-volume noise FIRST, but only the noise that can
    #    never be security-relevant: health probes and metrics scrapes.
    - level: None
      nonResourceURLs:
        - /healthz*
        - /livez*
        - /readyz*
        - /version
        - /metrics
        - /openapi*

    # 2. Secrets and credential-shaped objects: WHO, WHEN, FROM WHERE, on
    #    WHICH object -- and never the payload. Metadata, deliberately.
    #    This rule sits ABOVE the system-component silencing rule on purpose:
    #    a kubelet or a controller reading a Secret must still be recorded.
    - level: Metadata
      resources:
        - group: ""
          resources: ["secrets", "configmaps", "serviceaccounts/token"]

    # 3. Interactive access to containers: the command line is the evidence.
    - level: RequestResponse
      resources:
        - group: ""
          resources: ["pods/exec", "pods/attach", "pods/portforward"]

    # 4. RBAC objects: this is where privilege escalation lands. Full body.
    - level: RequestResponse
      resources:
        - group: "rbac.authorization.k8s.io"
          resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

    # 5. Now, and only now, silence the read-only chatter of the control plane
    #    and the kubelets. Their Secret reads were already captured by rule 2.
    - level: None
      users: ["system:kube-scheduler", "system:kube-controller-manager", "system:apiserver"]
      verbs: ["get", "list", "watch"]
    - level: None
      userGroups: ["system:nodes"]
      verbs: ["get", "list", "watch"]

    # 6. Anything that mutates state: keep the request body.
    - level: Request
      verbs: ["create", "update", "patch", "delete", "deletecollection"]

    # 7. Catch-all. Without this last rule, everything unmatched is dropped.
    - level: Metadata
  POLICY

  Level semantics (worth memorising for the exam):
    None            -> event discarded
    Metadata        -> user, verb, resource, namespace, sourceIPs, timestamp, response code
    Request         -> Metadata + request body
    RequestResponse -> Request + response body (never for secrets)

STEP 5 — Fix retention (fault D) in the manifest
  The final flag block under 'command:' must read:

      - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
      - --audit-log-path=/var/log/kubernetes/audit/audit.log
      - --audit-log-maxage=30      # days of history to keep
      - --audit-log-maxbackup=10   # rotated files to retain
      - --audit-log-maxsize=100    # megabytes per file before rotating

  1 MB / 1 backup means the incident scrolls out of the log while you are
  still opening the ticket. Note that --audit-log-path=- writes to stdout,
  which is fine when a log shipper collects the Pod's output, but then the
  maxage/maxbackup/maxsize flags do nothing.

STEP 6 — Restart, then prove it
  The kubelet reloads the static Pod on any manifest write. If it does not:
    $ sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
    $ sleep 20
    $ sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
    $ until kubectl get --raw='/healthz'; do sleep 3; done

  Generate the traffic and hunt for it:
    $ sudo ./break_fix.sh access
    $ sudo grep '"resource":"secrets"' /var/log/kubernetes/audit/audit.log \
        | jq -c '{t:.requestReceivedTimestamp, u:.user.username, v:.verb,
                  ns:.objectRef.namespace, n:.objectRef.name,
                  ip:.sourceIPs[0], code:.responseStatus.code}'
    {"t":"2026-08-06T12:21:04.771Z","u":"system:serviceaccount:finance:intern",
     "v":"get","ns":"finance","n":"db-credentials","ip":"10.0.2.15","code":200}
    {"t":"2026-08-06T12:21:05.019Z","u":"system:serviceaccount:finance:intern",
     "v":"list","ns":"kube-system","n":null,"ip":"10.0.2.15","code":403}

  Everyday triage one-liners:
    # who is getting denied, ranked
    sudo jq -r 'select(.responseStatus.code==403) | .user.username' \
      /var/log/kubernetes/audit/audit.log | sort | uniq -c | sort -rn
    # every exec into a container, with the command
    sudo jq -r 'select(.objectRef.subresource=="exec")
                | [.requestReceivedTimestamp,.user.username,.objectRef.namespace,
                   .objectRef.name,(.requestURI)] | @tsv' \
      /var/log/kubernetes/audit/audit.log
    # anonymous access attempts
    sudo grep '"username":"system:anonymous"' /var/log/kubernetes/audit/audit.log | wc -l

  Confirm you did NOT leak the Secret into the log (requirement R6):
    $ sudo grep -c "$(printf 'S3cr3t-Lab-P4ssw0rd' | base64 -w0)" \
        /var/log/kubernetes/audit/audit.log
    0

  Then grade everything:
    $ sudo ./break_fix.sh verify

WHAT TO CARRY INTO THE EXAM (and into production)
  * Enabling audit takes FOUR coordinated edits: the flags, the policy file,
    the volume, and the volumeMount. Forgetting the mount is the single most
    common way to bring a control plane down in this task.
  * Rule order is the whole language. First match wins; a broad None rule
    placed too early is a silent, total outage of your security telemetry.
  * Never log Secrets at Request/RequestResponse: the audit log is a
    world-readable-by-root plain-text file on the node, usually shipped
    off-box. Metadata answers "who and when" without creating a new target.
  * The audit log lives on the node. A node-local file is not an audit trail:
    ship it off the host (webhook backend or a DaemonSet collector), because
    an attacker with node access can truncate it.
  * Audit only records requests that reach the API server. In-container
    activity needs Falco/eBPF tooling (topic 6.2/6.3), not audit policy.

  Sources:
    https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
    https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
    https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
    https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cks/6.5/lab)
