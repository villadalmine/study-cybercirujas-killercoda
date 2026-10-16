## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION (step by step). Do not read this until you have tried.

1) Confirm the control plane is fine. The Service and its endpoints exist:

     kubectl -n bf-kproxy get svc,endpointslices
     NAME              TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
     service/web-new   ClusterIP   10.96.142.17    <none>        80/TCP    2m
     service/web-old   ClusterIP   10.96.201.33    <none>        80/TCP    3m
     NAME                                     ADDRESSTYPE   PORTS   ENDPOINTS                 AGE
     endpointslice.../web-new-xk2p9           IPv4          80      10.244.1.12,10.244.2.9    2m
     endpointslice.../web-old-7rq4d           IPv4          80      10.244.1.12,10.244.2.9    3m

   Both Services select the same healthy Pods, so the Deployment, the
   selector, and the EndpointSlice controller are not the problem. The fault
   is between "the API knows" and "the kernel knows".

2) Check the component that bridges the two, kube-proxy:

     kubectl -n kube-system get ds kube-proxy -o wide
     NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR           AGE
     kube-proxy   0         0         0       0            0           kubernetes.io/os=linx   20d

     kubectl -n kube-system get pods -l k8s-app=kube-proxy
     No resources found in kube-system namespace.

   DESIRED 0 on a cluster with nodes means no node matches the selector.
   "linx" is a typo for "linux":

     kubectl get nodes -L kubernetes.io/os
     NAME     STATUS   ROLES           AGE   VERSION   OS
     cp-1     Ready    control-plane   20d   v1.34.x   linux
     node-1   Ready    <none>          20d   v1.34.x   linux

3) (Optional, but this is the key insight.) Look at the data plane on a node.
   In iptables mode:

     sudo iptables -t nat -S KUBE-SERVICES | grep bf-kproxy
     -A KUBE-SERVICES -d 10.96.201.33/32 -p tcp -m comment --comment "bf-kproxy/web-old:http cluster IP" ... -j KUBE-SVC-...
     (there is NO line for web-new)

   In nftables mode:   sudo nft list table ip kube-proxy | grep bf-kproxy
   In IPVS mode:       sudo ipvsadm -Ln | grep -A2 10.96.201.33
                       (web-new's ClusterIP is also missing from kube-ipvs0:
                        ip addr show kube-ipvs0)

   Why web-old still works: kube-proxy does not forward packets. It writes
   rules, and those rules stay in the kernel after the process exits (only
   'kube-proxy --cleanup' removes them). Existing Services keep working
   until something changes: a new Service, a Pod rescheduled to a new IP,
   a scale-out, or a node reboot that wipes the tables. That delayed failure
   is what makes this class of outage dangerous in production.

4) Fix the root cause by restoring the correct nodeSelector:

     kubectl -n kube-system patch ds kube-proxy --type merge \
       -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/os":"linux"}}}}}'

     kubectl -n kube-system rollout status ds/kube-proxy
     daemon set "kube-proxy" successfully rolled out

   (Equivalent: kubectl -n kube-system edit ds kube-proxy and fix the typo.)

5) On startup, kube-proxy does a full sync from the API. It lists every
   Service and EndpointSlice and reprograms the kernel, so web-new appears
   without touching it:

     kubectl -n kube-system logs ds/kube-proxy | grep -i -E 'sync|proxier'
     kubectl -n bf-kproxy exec client -- wget -qO- -T 3 http://web-new | head -4
     <!DOCTYPE html>
     <html>
     <head>
     <title>Welcome to nginx!</title>

6) Run: ./break-fix-kube-proxy.sh verify   then   ./break-fix-kube-proxy.sh reset

Takeaways for the exam and for production:
  - Service triage ladder: Service -> EndpointSlice (control plane) ->
    node rules (data plane) -> the component that syncs them.
  - "Old Services work, new ones don't" points strongly at the Service
    proxy, not at the CNI's Pod-to-Pod routing. Pod-to-Pod traffic by
    Pod IP keeps working the whole time.
  - Alert on the kube-proxy DaemonSet with numberReady < desiredNumberScheduled
    AND desiredNumberScheduled < node count. A DaemonSet that wants zero
    Pods looks "healthy" (0/0) to a naive check.
  - With a CNI that replaces kube-proxy (Cilium kubeProxyReplacement, Calico
    eBPF), there is no kube-proxy DaemonSet at all. There, the equivalent
    check is the agent's own service table, for example
    'cilium-dbg service list' inside a cilium Pod, or 'cilium status'.
    If you see kube-proxy AND an eBPF replacement both active, that is a
    misconfiguration: two components are programming Service load balancing.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/2.2/lab)
