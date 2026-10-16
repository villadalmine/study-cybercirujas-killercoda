## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
STEP-BY-STEP SOLUTION (STUDENT REFERENCE & REMEDIATION GUIDE)

STEP 1: FIX KUBECONFIG FILE PERMISSIONS
Kubeconfigs contain private cryptographic keys and must be restricted to user-only access.
Command:
  chmod 0600 /tmp/kcsa-client-security-lab/kubeconfig
Expected output check:
  ls -la /tmp/kcsa-client-security-lab/kubeconfig
  -rw------- 1 user group 1850 Aug 7 19:00 /tmp/kcsa-client-security-lab/kubeconfig

STEP 2: RE-ISSUE CLIENT CERTIFICATE WITH CORRECT ORGANIZATIONAL ATTRIBUTE (O)
The RBAC ClusterRoleBinding 'kcsa-security-auditor-binding' maps the group 'security-auditors'.
In X.509 client certificates, 'O' (Organization) maps to Kubernetes User Groups.

2.1 Generate new CSR with correct CN and O:
  openssl req -new -key /tmp/kcsa-client-security-lab/auditor.key \
    -subj "/CN=sec-auditor-user/O=security-auditors" \
    -out /tmp/kcsa-client-security-lab/auditor_fixed.csr

2.2 Sign the CSR using the lab CA key and certificate:
  openssl x509 -req -in /tmp/kcsa-client-security-lab/auditor_fixed.csr \
    -CA /tmp/kcsa-client-security-lab/ca.crt \
    -CAkey /tmp/kcsa-client-security-lab/ca.key \
    -CAcreateserial \
    -out /tmp/kcsa-client-security-lab/auditor_fixed.crt \
    -days 1

2.3 Verify the certificate subject details:
  openssl x509 -in /tmp/kcsa-client-security-lab/auditor_fixed.crt -noout -subject
  Expected Output: subject=CN = sec-auditor-user, O = security-auditors

STEP 3: UPDATE KUBECONFIG WITH TRUSTED CA DATA AND FIXED CLIENT CERTIFICATE

3.1 Base64 encode the CA certificate and fixed client certificate:
  CA_B64=$(base64 -w 0 < /tmp/kcsa-client-security-lab/ca.crt)
  CLIENT_CERT_B64=$(base64 -w 0 < /tmp/kcsa-client-security-lab/auditor_fixed.crt)

3.2 Update Kubeconfig:
  - Remove: 'insecure-skip-tls-verify: true'
  - Add under cluster: 'certificate-authority-data: <CA_B64>'
  - Update under user: 'client-certificate-data: <CLIENT_CERT_B64>'

CLI Command using kubectl config:
  kubectl config --kubeconfig=/tmp/kcsa-client-security-lab/kubeconfig \
    set-cluster kcsa-secure-cluster \
    --certificate-authority-data="${CA_B64}" \
    --embed-certs=true

  kubectl config --kubeconfig=/tmp/kcsa-client-security-lab/kubeconfig \
    unset clusters.kcsa-secure-cluster.insecure-skip-tls-verify

  kubectl config --kubeconfig=/tmp/kcsa-client-security-lab/kubeconfig \
    set-credentials sec-auditor-user \
    --client-certificate-data="${CLIENT_CERT_B64}" \
    --embed-certs=true

STEP 4: RUN VERIFICATION
  ./break-fix-client-security.sh verify
  Expected Output:
    [PASS] Kubeconfig file permissions are properly hardened (600).
    [PASS] 'insecure-skip-tls-verify: true' has been removed.
    [PASS] Trusted CA configuration detected in kubeconfig.
    [PASS] Client Certificate Subject Organization correctly set to 'security-auditors'.
    CONGRATULATIONS! ALL KCSA CLIENT SECURITY CHECKS PASSED SUCCESSFULLY.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/kcsa/2.10/lab)
