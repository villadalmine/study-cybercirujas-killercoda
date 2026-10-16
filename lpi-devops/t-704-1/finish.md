## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
   resolution is traffic too.

   Do not delete default-deny. Add the narrowest exception:

   # kubectl apply -f - <<'YAML'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-dns-egress
     namespace: lab-704-1
   spec:
     podSelector: {}
     policyTypes: ["Egress"]
     egress:
       - to:
           - namespaceSelector:
               matchLabels:
                 kubernetes.io/metadata.name: kube-system
             podSelector:
               matchLabels:
                 k8s-app: kube-dns
         ports:
           - protocol: UDP
             port: 53
           - protocol: TCP
             port: 53
   YAML

   NetworkPolicies are additive and purely allow-based: this one does not
   "override" default-deny, it unions one destination into the allowed set.
   Adjust the podSelector label if your cluster labels CoreDNS differently
   (k3s and kubeadm use k8s-app=kube-dns; check with
   "kubectl -n kube-system get pods -l k8s-app=kube-dns --show-labels").

   # kubectl -n lab-704-1 rollout status deploy/orders-api
   deployment "orders-api" successfully rolled out

   Reference: https://kubernetes.io/docs/concepts/services-networking/network-policies/

4. Caveat worth carrying to production: NetworkPolicy is enforced by the CNI
   plugin, not by the API server. The object is accepted on any cluster; on a
   cluster whose plugin ignores it (plain flannel, for example) it is a
   comment. Verify enforcement empirically -- exec into a pod, try the traffic,
   and only then claim the namespace is isolated.

CLEAN UP
  ./704.1-breakfix.sh restore

WHAT TO CARRY OUT OF THIS LAB
  Every scenario had a one-command "fix" that removed the control
  (seccomp=unconfined, --privileged, enforce=baseline, delete the netpol) and a
  slightly longer fix that narrowed it. The difference between the two is the
  entire job. When a security control breaks a workload, the deliverable is
  the smallest exception that names exactly what the workload needs -- and the
  exception is reviewable evidence, which "unconfined" never is.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpi-devops/704.1/lab)
