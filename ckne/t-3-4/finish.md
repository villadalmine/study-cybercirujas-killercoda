## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION (read only after you have tried)

--- Step 0: rule out the mesh itself ---------------------------------------
  cilium clustermesh status --context kind-ckne-east
  Expected: "All 1 nodes are connected to all clusters", "ckne-west: ready".
  The control plane is fine, so the problem is in what west publishes to the mesh.

--- Step 1: ask the east datapath which backends it knows about ------------
  kubectl --context kind-ckne-east -n mcs-lab get svc echo -o jsonpath='{.spec.clusterIP}'
  kubectl --context kind-ckne-east -n kube-system exec ds/cilium -c cilium-agent -- \
    cilium-dbg service list
  Find the row whose frontend is <east ClusterIP>:80. It has NO backends
  (or none with a 10.2.x.x west pod IP). East kube-proxy-replacement has
  nothing to send the traffic to, so curl times out.
  With a working setup you would see west pod IPs (10.2.x.x:8080) there, because
  Cilium merges remote backends into the local ClusterIP for global services.

--- Step 2: inspect the west Service ---------------------------------------
  kubectl --context kind-ckne-west -n mcs-lab get svc echo -o yaml
    annotations:
      service.cilium.io/global: "true"
      service.cilium.io/shared: "false"      <-- FAULT 1
    selector:
      app: echo-backend                      <-- FAULT 2

  FAULT 1: global="true" makes the Service part of the global service, but
  shared="false" means "consume remote backends, do NOT export mine".
  West can still reach east, but east never learns about west pods.
  The shared annotation defaults to true when global is true.

  FAULT 2: the selector does not match the pods (label app=echo), so west has
  no local endpoints. Even with sharing on, it would export an empty set.
  ClusterMesh shares endpoints, not Service definitions: no endpoints, no failover.

  kubectl --context kind-ckne-west -n mcs-lab get endpointslices \
    -l kubernetes.io/service-name=echo
  -> ENDPOINTS <unset>   (confirms FAULT 2)
  kubectl --context kind-ckne-west -n mcs-lab get pods --show-labels
  -> app=echo            (the label the selector should use)

--- Step 3: fix the selector -----------------------------------------------
  kubectl --context kind-ckne-west -n mcs-lab patch svc echo \
    --type merge -p '{"spec":{"selector":{"app":"echo"}}}'
  kubectl --context kind-ckne-west -n mcs-lab get endpointslices \
    -l kubernetes.io/service-name=echo
  -> ENDPOINTS 10.2.0.x:8080,10.2.0.y:8080

--- Step 4: share the west backends again -----------------------------------
  Remove the annotation (default is shared) ...
  kubectl --context kind-ckne-west -n mcs-lab annotate svc echo service.cilium.io/shared-
  ... or set it explicitly:
  kubectl --context kind-ckne-west -n mcs-lab annotate svc echo \
    service.cilium.io/shared="true" --overwrite

--- Step 5: verify from the east side ---------------------------------------
  kubectl --context kind-ckne-east -n kube-system exec ds/cilium -c cilium-agent -- \
    cilium-dbg service list
  -> the echo frontend now lists 10.2.x.x:8080 backends (west pods)

  kubectl --context kind-ckne-east -n mcs-lab exec deploy/client -- \
    curl -s http://echo.mcs-lab.svc.cluster.local
  -> served-by-ckne-west

  ./break-fix-3.4.sh check    -> LAB PASSED.

--- Key points for the exam -------------------------------------------------
  * Global services are matched by NAME + NAMESPACE in every cluster. A typo in
    either one silently creates two unrelated local services.
  * service.cilium.io/global  = join the global service.
    service.cilium.io/shared  = export (true, the default) or only consume (false).
    service.cilium.io/affinity= local | remote | none: which backends are preferred
    when both are healthy (local = use remote only as failover).
  * DNS does not change: the client resolves the LOCAL ClusterIP and the eBPF
    datapath picks local or remote backends. The cross-cluster "discovery" is
    the endpoint sync through clustermesh-apiserver (etcd), not CoreDNS.
  * Prerequisites that break a mesh before any Service does: unique cluster.id
    and cluster.name, pod CIDRs that do not overlap, a shared or trusted CA, and
    node-to-node reachability to the clustermesh-apiserver port.
  * Upstream equivalent (KEP-1645, MCS API): export with a ServiceExport object
    named like the Service; consumers get a ServiceImport and resolve
    <svc>.<ns>.svc.clusterset.local. The same principle applies: "exported but
    no ready endpoints" means the name resolves and the traffic has nowhere to go.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/3.4/lab)
