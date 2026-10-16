## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION AND TROUBLESHOOTING GUIDE (FOR INSTRUCTOR / STUDENT REFERENCE)

STEP 1: Diagnose the Failure
Run crictl or docker logs to view why kube-apiserver failed to launch:
  $ sudo crictl ps -a --name kube-apiserver
  $ sudo crictl logs <container-id>

Typical Error Log 1:
  "Error: open /etc/kubernetes/audit/policy-invalid.yaml: no such file or directory"
  Reason: The API Server flag --audit-policy-file points to a file path that does not exist
  inside the container mount.

Typical Error Log 2 (once path fixed):
  "error loading audit policy file: unknown group audit.k8s.io/v1alpha1" or "invalid Level Full"
  Reason: Invalid apiVersion, Kind, or Rule Level in the audit policy YAML.

STEP 2: Fix the Audit Policy YAML (/etc/kubernetes/audit/audit-policy.yaml)
Edit /etc/kubernetes/audit/audit-policy.yaml and replace content with valid syntax:

cat << 'EOF' > /etc/kubernetes/audit/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - "RequestReceived"
rules:
  # Do not log audit events for noisy system endpoints
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services", "services/status"]

  # Log secret and configmap access at Metadata level for security compliance
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  # Log pod lifecycle requests at RequestResponse level
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods"]

  # Default fallback for all other resources
  - level: Metadata
EOF
chmod 600 /etc/kubernetes/audit/audit-policy.yaml

STEP 3: Fix kube-apiserver Static Pod Manifest (/etc/kubernetes/manifests/kube-apiserver.yaml)
Open /etc/kubernetes/manifests/kube-apiserver.yaml and verify three key elements:

A. Command Flags under spec.containers[0].command:
  - --audit-policy-file=/etc/kubernetes/audit/audit-policy.yaml
  - --audit-log-path=/var/log/kubernetes/audit/audit.log
  - --audit-log-maxage=30
  - --audit-log-maxbackup=10
  - --audit-log-maxsize=100

B. VolumeMounts under spec.containers[0].volumeMounts:
  - mountPath: /etc/kubernetes/audit
    name: k8s-audit
    readOnly: true
  - mountPath: /var/log/kubernetes/audit
    name: k8s-audit-log
    readOnly: false

C. Volumes under spec.volumes:
  - name: k8s-audit
    hostPath:
      path: /etc/kubernetes/audit
      type: DirectoryOrCreate
  - name: k8s-audit-log
    hostPath:
      path: /var/log/kubernetes/audit
      type: DirectoryOrCreate

STEP 4: Verification
1. Wait for static pod watcher to restart kube-apiserver (approx. 15-30s).
2. Check cluster readiness:
   $ kubectl get nodes
3. Verify audit log creation and content:
   $ tail -f /var/log/kubernetes/audit/audit.log
4. Run verification command in this script:
   $ sudo ./break_fix_audit_logging.sh verify
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/kcsa/3.6/lab)
