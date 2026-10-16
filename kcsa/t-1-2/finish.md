## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION — step by step (do not read until you have tried it)

The fault: the iptables OUTPUT rule that denied the workload identity egress
to the cloud metadata IP (169.254.169.254) was removed, so a compromised Pod
can now steal the node's cloud credentials. The fix is to reinstate that
host-level egress restriction. Locally-originated packets traverse the
OUTPUT chain, and the `owner` match lets us scope the block to the workload
uid while leaving system agents (root, cloud-init, kubelet) unaffected.

1) Confirm the leak the way the exam scenario would — as the workload:

     runuser -u metaworkload -- \
       curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/lab-node-role

   You will see the fake AccessKeyId / SecretAccessKey / Token. That is the
   node identity any pod on this host could exfiltrate.

2) Inspect the OUTPUT chain and confirm no guard rule is present:

     iptables -S OUTPUT | grep -i metadata || echo "no guard rule present"

3) Reinstate the egress guard (REJECT is used here for an instant, teachable
   failure; production hardening typically uses DROP so the endpoint appears
   to simply not exist):

     iptables -A OUTPUT -d 169.254.169.254/32 -p tcp --dport 80 \
       -m owner --uid-owner metaworkload \
       -m comment --comment "kcsa-1.2-metadata-guard" \
       -j REJECT --reject-with icmp-port-unreachable

4) Verify the same probe is now denied (empty body / "Connection refused"):

     runuser -u metaworkload -- \
       curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/lab-node-role
     echo "exit=$?"

   Or use the built-in checker:

     sudo ./this.sh verify        # expect: PASS

5) (Optional) Persist the rule so a reboot does not silently re-expose the
   node — the same lesson as making hardening declarative:

     # Debian/Ubuntu:  apt-get install -y iptables-persistent && netfilter-persistent save
     # RHEL/Fedora:    iptables-save > /etc/sysconfig/iptables

How this maps to real clusters (KCSA 1.2, Cloud Provider & Infrastructure
Security). The single host rule above is a model of controls you apply for
real:

  * Kubernetes NetworkPolicy — default-deny egress from workload namespaces,
    explicitly blocking 169.254.169.254/32, so pods cannot reach the IMDS:

      apiVersion: networking.k8s.io/v1
      kind: NetworkPolicy
      metadata:
        name: deny-cloud-metadata
        namespace: apps
      spec:
        podSelector: {}
        policyTypes: ["Egress"]
        egress:
          - to:
              - ipBlock:
                  cidr: 0.0.0.0/0
                  except:
                    - 169.254.169.254/32

  * AWS IMDSv2 with a hop limit of 1 (metadata requests require a signed
    token and cannot be relayed through a pod's extra network hop):
      aws ec2 modify-instance-metadata-options \
        --instance-id <id> --http-tokens required --http-put-response-hop-limit 1

  * GKE: enable Workload Identity, which conceals the node metadata endpoint
    from pods and issues per-workload identities instead of node-wide creds.

References:
  - Securing a Cluster (restricting cloud metadata API access):
    https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
  - IMDSv2: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
  - GKE Workload Identity: https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/kcsa/1.2/lab)
