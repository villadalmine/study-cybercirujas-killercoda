## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION (step by step) - try it on your own first

--- STEP 0: Confirm the diagnosis -------------------------------------------

  kubectl --context kind-ckne-ipam-lab get nodes \
    -o custom-columns='NAME:.metadata.name,PODCIDR:.spec.podCIDR'

  Expected output (which worker is starved varies from run to run):
    NAME                          PODCIDR
    ckne-ipam-lab-control-plane   10.244.0.0/24
    ckne-ipam-lab-worker          10.244.1.0/24
    ckne-ipam-lab-worker2         <none>

  kubectl --context kind-ckne-ipam-lab -n kube-system logs \
    -l component=kube-controller-manager | grep -i cidr
    ... "CIDR allocation failed; there are no remaining CIDRs left to
         allocate in the accepted range" ...

  The math: cluster-cidr /23, node-cidr-mask-size /24 gives
  2^(24-23) = 2 node blocks for 3 nodes.
  The CNI (kindnet, like flannel or any plugin driven by host-local
  IPAM) builds each node's range from Node.spec.podCIDR. No podCIDR means
  no CNI config, so the kubelet reports NetworkReady=false and the node is
  NotReady. The CNI is a victim here, not the cause.

--- WHY THE "OBVIOUS" FIXES DO NOT WORK ---------------------------------------

  * Only lowering --node-cidr-mask-size to 25: the two /24s already
    handed out fill the whole /23, so there is nothing left to carve.
    Node.spec.podCIDR can be set once and never changed afterwards, so the
    allocator cannot shrink the existing ones either.
  * Moving to a DIFFERENT, non-overlapping range (e.g. 10.100.0.0/16):
    the existing nodes keep CIDRs outside the new cluster-cidr and
    kube-proxy/CNI masquerade rules stop matching the real pod IPs.
    Changing ranges needs a drain + node delete + rejoin per node.
  * The safe in-place change: WIDEN to a SUPERSET of the old range
    (10.244.0.0/23 -> 10.244.0.0/16). When the allocator starts, it marks
    the existing /24s as used and gives the next free one
    (10.244.2.0/24) to the starved node.
    First check that the new range overlaps neither the Service CIDR
    (10.96.0.0/16 here) nor the node/LAN network.

--- STEP 1: Widen --cluster-cidr in the static pod manifest --------------------

  Back up OUTSIDE the manifests directory. The kubelet treats every
  file there as a static pod, so a stray backup can start a second
  kube-controller-manager.

  docker exec ckne-ipam-lab-control-plane \
    cp /etc/kubernetes/manifests/kube-controller-manager.yaml /root/kcm.yaml.bak

  docker exec ckne-ipam-lab-control-plane \
    sed -i 's#--cluster-cidr=10.244.0.0/23#--cluster-cidr=10.244.0.0/16#' \
    /etc/kubernetes/manifests/kube-controller-manager.yaml

  docker exec ckne-ipam-lab-control-plane \
    grep -E 'cluster-cidr|allocate-node-cidrs|node-cidr-mask' \
    /etc/kubernetes/manifests/kube-controller-manager.yaml
    - --allocate-node-cidrs=true
    - --cluster-cidr=10.244.0.0/16

  The kubelet sees the manifest change and recreates the static pod.
  Wait for it:

  kubectl --context kind-ckne-ipam-lab -n kube-system get pod \
    -l component=kube-controller-manager -w

--- STEP 2: Check that the starved node got its CIDR ---------------------------

  kubectl --context kind-ckne-ipam-lab get nodes \
    -o custom-columns='NAME:.metadata.name,PODCIDR:.spec.podCIDR'
    ckne-ipam-lab-control-plane   10.244.0.0/24
    ckne-ipam-lab-worker          10.244.1.0/24
    ckne-ipam-lab-worker2         10.244.2.0/24

  Within a few seconds kindnet on that node writes the CNI config and the
  kubelet flips it to Ready:

  docker exec ckne-ipam-lab-worker2 ls /etc/cni/net.d
  kubectl --context kind-ckne-ipam-lab get nodes

--- STEP 3: Make kubeadm's source of truth agree -------------------------------

  'kubeadm upgrade' rebuilds the control-plane manifests from the
  ClusterConfiguration stored in this ConfigMap. If you skip this step,
  the next upgrade quietly brings the /23 back.

  kubectl --context kind-ckne-ipam-lab -n kube-system get cm kubeadm-config -o yaml \
    | sed 's#podSubnet: 10.244.0.0/23#podSubnet: 10.244.0.0/16#' \
    | kubectl --context kind-ckne-ipam-lab apply -f -

--- STEP 4: kube-proxy clusterCIDR ---------------------------------------------

  kube-proxy uses clusterCIDR to decide which traffic to Services comes
  from outside the Pod network and must be masqueraded. With a stale /23,
  pods in 10.244.2.0/24 would be treated as "external".

  kubectl --context kind-ckne-ipam-lab -n kube-system get cm kube-proxy -o yaml \
    | sed 's#clusterCIDR: 10.244.0.0/23#clusterCIDR: 10.244.0.0/16#' \
    | kubectl --context kind-ckne-ipam-lab apply -f -
  kubectl --context kind-ckne-ipam-lab -n kube-system rollout restart ds/kube-proxy
  kubectl --context kind-ckne-ipam-lab -n kube-system rollout status ds/kube-proxy

  (If the sed did not match, the value may be quoted in your version.
   Edit it directly with: kubectl -n kube-system edit cm kube-proxy)

--- STEP 5: CNI plugin view of the Pod network ----------------------------------

  kindnet uses POD_SUBNET to decide what NOT to masquerade:

  kubectl --context kind-ckne-ipam-lab -n kube-system set env ds/kindnet \
    POD_SUBNET=10.244.0.0/16
  kubectl --context kind-ckne-ipam-lab -n kube-system rollout status ds/kindnet

  Other CNIs keep this setting elsewhere: flannel in the net-conf.json
  "Network" key, Calico in its IPPool, Cilium in
  clusterPoolIPv4PodCIDRList when it runs its own IPAM instead of
  ipam.mode=kubernetes.

--- STEP 6: Clean up the backup and verify end to end ---------------------------

  /root/kcm.yaml.bak is outside /etc/kubernetes/manifests, so the kubelet
  ignores it. Confirm the directory holds only the four manifests:

  docker exec ckne-ipam-lab-control-plane ls /etc/kubernetes/manifests
    etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml

  Then:
  ./ckne-1.2-ipam-break-fix.sh check

--- PRODUCTION TAKEAWAYS -------------------------------------------------------

  * Size it up front:  nodes_max = 2^(node_mask - cluster_mask).
    A /16 with /24 per node gives 256 nodes of 254 usable IPs each. The kubelet
    limit (maxPods, default 110) is what bounds pods per node,
    not the /24.
  * Watch for CIDRNotAvailable events and alert on NotReady nodes whose
    spec.podCIDR is empty. That pair means IPAM exhaustion, not a CNI bug.
  * There are four places that must agree on the Pod CIDR: controller-manager,
    kubeadm-config, kube-proxy, and the CNI. Changing only one of them gives a
    cluster that "works" until the next upgrade or the next node.
  * Widening in place only works to a superset. Anything else is a
    per-node migration (drain, delete Node, rejoin), because
    spec.podCIDR cannot be changed.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/1.2/lab)
