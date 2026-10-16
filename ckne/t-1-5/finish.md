## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION (step by step) - read it only after trying

STEP 0 - Observe before touching anything
  kubectl -n ckne-lab-1-5 get pods -o wide
    NAME    READY   STATUS              RESTARTS   AGE
    app-a   0/1     ContainerCreating   0          40s
    app-b   1/1     Running             0          40s

  kubectl -n ckne-lab-1-5 describe pod app-a | sed -n '/Events:/,$p'
    Warning  FailedCreatePodSandBox  ...  Failed to create pod sandbox: rpc error:
      ... plugin type="multus-shim" name="multus-cni-network" failed (add):
      ... error loading k8s delegates k8s args: TryLoadPodDelegates:
      error in getting k8s network for pod: GetNetworkDelegates: failed
      getting the delegate: getKubernetesDelegate: cannot find a
      network-attachment-definition (storage-net) in namespace
      (ckne-lab-1-5): network-attachment-definitions.k8s.cni.cncf.io
      "storage-net" not found
  (The exact wording varies across Multus versions and runtimes. The key
   part is "cannot find a network-attachment-definition (storage-net)".)

  The kubelet keeps retrying sandbox creation. It is the kubelet, through
  the runtime, that calls the CNI chain: primary CNI first, then each
  delegate Multus resolves from the annotation. If any delegate fails, the
  WHOLE sandbox is torn down. That is why the Pod never reaches Running,
  even though the primary network (eth0) would have worked.

FAULT #1 - app-a references a NAD that does not exist
  kubectl -n ckne-lab-1-5 get net-attach-def
    NAME              AGE
    storage-network   1m

  The annotation asks for "storage-net". The NAD is "storage-network".
  Multus resolves the name in the Pod's own namespace, unless you write
  <namespace>/<name>. Fix the annotation in the manifest:

    sed -i 's#k8s.v1.cni.cncf.io/networks: storage-net$#k8s.v1.cni.cncf.io/networks: storage-network#' \
      /tmp/ckne-lab-1-5/app-a.yaml

  Pod annotations are mutable, but Multus reads them only at sandbox
  creation, so 'kubectl annotate' on the live Pod is not enough. Recreate
  the Pod:

    kubectl -n ckne-lab-1-5 delete pod app-a --wait=true
    kubectl apply -f /tmp/ckne-lab-1-5/app-a.yaml

  Still ContainerCreating, but the event is DIFFERENT now. That is progress.

FAULT #2 - host-local IPAM range outside the subnet
  kubectl -n ckne-lab-1-5 describe pod app-a | sed -n '/Events:/,$p'
    Warning  FailedCreatePodSandBox ... [ckne-lab-1-5/app-a/...:storage-network]:
      error adding container to network "storage-network": ... RangeStart
      10.10.1.10 not in network 10.10.0.0/24
  (Wording is approximate: the host-local plugin rejects the range.)

  Now the NAD was found and Multus invoked the delegate (bridge), which
  invoked its IPAM plugin (host-local), and host-local refused the config.
  Read the config Multus actually passes:

    kubectl -n ckne-lab-1-5 get net-attach-def storage-network \
      -o jsonpath='{.spec.config}'

  "rangeStart": "10.10.1.10" is in 10.10.1.0/24, not in 10.10.0.0/24.
  Fix it:

    sed -i 's#"rangeStart": "10.10.1.10"#"rangeStart": "10.10.0.10"#' \
      /tmp/ckne-lab-1-5/nad.yaml
    kubectl apply -f /tmp/ckne-lab-1-5/nad.yaml

  Changing a NAD does not re-plumb existing Pods either. Recreate app-a
  (or wait: the kubelet's next sandbox retry will read the new NAD, but
  recreating is deterministic):

    kubectl -n ckne-lab-1-5 delete pod app-a --wait=true
    kubectl apply -f /tmp/ckne-lab-1-5/app-a.yaml
    kubectl -n ckne-lab-1-5 wait --for=condition=Ready pod/app-a --timeout=60s

    kubectl -n ckne-lab-1-5 exec app-a -- ip -4 -o addr show dev net1
      3: net1    inet 10.10.0.10/24 brd 10.10.0.255 scope global net1

  host-local keeps its allocations as files on the node, under
  /var/lib/cni/networks/storage-network/ (one file per IP, containing the
  container ID). That is where to look if IPs "leak" after unclean
  teardowns.

FAULT #3 - app-b uses the wrong annotation key (silent failure)
  kubectl -n ckne-lab-1-5 exec app-b -- ip -4 -o addr
    1: lo      inet 127.0.0.1/8 scope host lo
    2: eth0    inet 10.244.1.23/24 ... eth0
  -> no net1.

  kubectl -n ckne-lab-1-5 get pod app-b \
    -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'
  -> lists only the default network (e.g. "kindnet" or "cbr0"), no storage-network.

  The key is "k8s.v1.cni.cncf.io/network" (singular). The multi-net spec
  and Multus use "k8s.v1.cni.cncf.io/networks" (PLURAL). An unknown
  annotation is not an error to the API server, and Multus never sees a
  request for extra networks, so there is no event and no failure.
  Only the network-status annotation, or looking inside the Pod, tells you.

    sed -i 's#k8s.v1.cni.cncf.io/network: storage-network#k8s.v1.cni.cncf.io/networks: storage-network#' \
      /tmp/ckne-lab-1-5/app-b.yaml
    kubectl -n ckne-lab-1-5 delete pod app-b --wait=true
    kubectl apply -f /tmp/ckne-lab-1-5/app-b.yaml
    kubectl -n ckne-lab-1-5 wait --for=condition=Ready pod/app-b --timeout=60s

STEP 4 - Verify end to end
  kubectl -n ckne-lab-1-5 get pod app-b \
    -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'
  Expected (trimmed): a JSON list with two entries, the default network on
  eth0 and:
    {"name": "ckne-lab-1-5/storage-network", "interface": "net1",
     "ips": ["10.10.0.11"], "mac": "..."}

  B_IP=$(kubectl -n ckne-lab-1-5 exec app-b -- sh -c \
    "ip -4 -o addr show dev net1 | awk '{print \$4}' | cut -d/ -f1")
  kubectl -n ckne-lab-1-5 exec app-a -- ping -c 3 -I net1 "$B_IP"
    3 packets transmitted, 3 packets received, 0% packet loss

  ./break-fix-1.5.sh check     -> ALL CHECKS PASSED

TAKEAWAYS
  * Multus is a meta-plugin. The error chain reads outside-in: runtime ->
    multus-shim -> Multus (NAD lookup) -> delegate plugin (bridge) -> IPAM
    (host-local). Identify WHICH layer produced the message before you
    change anything.
  * NAD names resolve in the Pod's namespace unless you qualify them as
    "<ns>/<name>". A name mismatch is a Multus error, not a CNI plugin error.
  * NAD configs are opaque JSON to the API server. Kubernetes does not
    validate them, so a bad IPAM range is accepted by 'kubectl apply' and
    only fails at Pod creation.
  * The annotation key must be exactly "k8s.v1.cni.cncf.io/networks". Any
    other key fails silently. Always confirm with the
    "k8s.v1.cni.cncf.io/network-status" annotation, never only with
    "STATUS Running".
  * Networks are attached at sandbox creation. After changing an
    annotation or a NAD, recreate the Pods (for a Deployment: kubectl
    rollout restart).
  * bridge is node-local L2. Pods on different nodes need macvlan/ipvlan
    over a shared host interface, or an overlay, to share a secondary
    network. That is why this lab pins both Pods to one node.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/1.5/lab)
