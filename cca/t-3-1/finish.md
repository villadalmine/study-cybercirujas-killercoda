## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
==  SOLUTION — DO NOT READ UNTIL YOU HAVE SOLVED THE INCIDENT              ==

INCIDENT 1 — eBPF LB entry deleted (ClusterIP dead, Endpoints healthy)
Root cause in one line:
  With kube-proxy replacement, Service forwarding lives in the cilium_lb4_*
  eBPF maps. The Kubernetes Service/EndpointSlice objects are only the DESIRED
  state; the agent programs the maps. The frontend entry was removed from the
  map, so the socket-LB / tail-call translation from ClusterIP to a backend no
  longer has a mapping. Packets to the ClusterIP are dropped in the datapath
  while every control-plane object still reports Healthy.

Step 1 — separate control plane from datapath. Control plane is fine:
  kubectl -n cca-lab get svc web -o wide
  kubectl -n cca-lab get endpointslices -l kubernetes.io/service-name=web -o wide
  # 2 Ready backend addresses -> the Service selector and readiness are correct.

Step 2 — prove the datapath disagrees. This is the decisive command:
  CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium -o name | head -1)
  kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg service list
  # The frontend <ClusterIP>:80/TCP is ABSENT, while kube-dns, kubernetes and
  # every other Service are listed. Confirm at the map level:
  kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg bpf lb list | grep <ClusterIP>

Step 3 — confirm the verdict on the wire:
  kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- \
      hubble observe --from-pod cca-lab/client --verdict DROPPED --last 20
  # Look for the drop reason pointing at a missing service translation. Note
  # that direct Pod-IP traffic is FORWARDED — only the ClusterIP path fails.

Step 4 — fix by forcing a full resync from the API server. The agent rebuilds
  the LB maps from the watched Service/EndpointSlice state at startup:
    kubectl -n kube-system rollout restart ds/cilium
    kubectl -n kube-system rollout status ds/cilium --timeout=300s
  Surgical alternative, without restarting the agent (useful when the node is
  carrying production traffic) — re-create the frontend from the known backends:
    kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg service update \
        --frontend <ClusterIP>:80 --backends <podIP1>:80,<podIP2>:80 --k8s-cluster-internal
  Third option: touch the Service so the watcher emits an update event
  (e.g. add a harmless annotation) and the agent reprograms the frontend:
    kubectl -n cca-lab annotate svc web cca-lab/resync="$(date +%s)" --overwrite
  All three keep the Service UID intact. Deleting and recreating the Service
  also "works" and is exactly what the verify step rejects: in production it
  would change the ClusterIP and break every client holding a cached DNS answer.

Step 5 — verify:
  kubectl -n cca-lab exec deploy/client -- curl -sS -o /dev/null -w '%{http_code}\n' \
      http://web.cca-lab.svc.cluster.local/
  kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg service list | grep <ClusterIP>

Exam takeaway: when a Service is unreachable, ask "is the frontend programmed
in the datapath?" before touching the Service object. cilium-dbg service list
and cilium-dbg bpf lb list are the source of truth for forwarding; kubectl is not.

INCIDENT 2 — masquerading disabled (east-west fine, egress dead)
Root cause in one line:
  enable-ipv4-masquerade=false in the cilium-config ConfigMap. Packets leaving
  the node keep their Pod CIDR source address; the upstream router has no route
  back to that prefix, so replies never return — a one-way blackhole that looks
  like a firewall drop.

Step 1 — characterise the blast radius. Pod->Pod and Pod->ClusterIP work, DNS
  works, only off-cluster destinations fail, and the same request from the node
  succeeds. That combination points at SNAT on egress, not at policy (a policy
  drop would show up in Hubble as DROPPED with a Policy denied reason) and not
  at DNS (name resolution still succeeds).

Step 2 — read the agent's live state rather than the Helm values:
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose | grep -iA2 Masquerading
  # Healthy node:  Masquerading:  BPF   [eth0]  10.244.0.0/16 [IPv4: Enabled, IPv6: Disabled]
  # Broken node:   Masquerading:  Disabled
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg config | grep -i masq
  kubectl -n kube-system get cm cilium-config -o yaml | grep -i masq

Step 3 — see it on the wire (the source address is the proof):
  kubectl -n cca-lab exec deploy/client -- \
      tcpdump -ni any host 1.1.1.1 and tcp port 80 -c 5
  # SYN leaves with a Pod IP as source and nothing ever comes back.
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf nat list | head
  # No NAT entries created for the egress flow when BPF masquerading is off.

Step 4 — fix at the source of truth, then roll the agents:
  kubectl -n kube-system patch cm cilium-config --type merge \
      -p '{"data":{"enable-ipv4-masquerade":"true","enable-bpf-masquerade":"true"}}'
  kubectl -n kube-system rollout restart ds/cilium
  kubectl -n kube-system rollout status ds/cilium --timeout=300s
  In a Helm-managed cluster the durable fix is the values file, otherwise the
  next 'helm upgrade' reintroduces the outage:
      helm upgrade cilium cilium/cilium -n kube-system --reuse-values \
           --set enableIPv4Masquerade=true --set bpf.masquerade=true
  Do NOT "fix" this with a hand-written iptables MASQUERADE rule on the node:
  it is invisible to the agent, survives no reboot, and will silently conflict
  the day BPF masquerading is turned back on.

Step 5 — verify:
  kubectl -n cca-lab exec deploy/client -- curl -sS -o /dev/null -w '%{http_code}\n' http://1.1.1.1/
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose | grep -i Masquerading

Exam takeaway: know the three egress knobs and how they interact —
  enableIPv4Masquerade (do SNAT at all), bpf.masquerade (do it in eBPF instead
  of iptables), and ipMasqAgent/nonMasqueradeCIDRs (which destinations are
  exempt). Also remember masquerading is skipped for destinations inside the
  cluster CIDR, which is exactly why east-west traffic survived.

INCIDENT 3 — CNI plugin binary renamed (running Pods fine, no new Pod starts)
Root cause in one line:
  /opt/cni/bin/cilium-cni was renamed. kubelet reads the network config from
  /etc/cni/net.d/05-cilium.conflist, then executes the plugin named in it from
  the CNI bin dir; the binary is missing, so every CreatePodSandbox call fails
  and Pods never leave ContainerCreating. Already-running Pods are untouched
  because CNI ADD only runs at sandbox creation.

Step 1 — read the kubelet event verbatim, do not paraphrase it:
  kubectl -n cca-lab describe pod -l app=canary | sed -n '/Events/,$p'
  # network: failed to find plugin "cilium-cni" in path [/opt/cni/bin]
  # (the sibling failure mode, worth recognising, is
  #  "no networks found in /etc/cni/net.d" -> the CONFIG is missing, not the binary)

Step 2 — inspect the node without a working CNI. hostNetwork Pods do not need
  the plugin, which is why 'kubectl debug node/...' still works:
  NODE=$(kubectl -n cca-lab get pod -l app=client -o jsonpath='{.items[0].spec.nodeName}')
  kubectl debug node/$NODE -it --image=busybox:1.36 -- ls -la /host/opt/cni/bin /host/etc/cni/net.d
  # on kind:  docker exec ${NODE} ls -la /opt/cni/bin /etc/cni/net.d
  # cilium-cni.cca-lab-disabled is present; cilium-cni is not.

Step 3 — identify who owns those files. The agent DaemonSet ships them:
  kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.initContainers[*].name}'
  # ... install-cni-binaries ...   copies cilium-cni into the host CNI bin dir
  kubectl -n kube-system logs ds/cilium -c install-cni-binaries
  # The agent itself writes 05-cilium.conflist when it is ready
  # (--write-cni-conf-when-ready), which is why restarting it repairs BOTH files.

Step 4 — fix by restarting the DaemonSet so the init container reinstalls the plugin:
  kubectl -n kube-system rollout restart ds/cilium
  kubectl -n kube-system rollout status ds/cilium --timeout=300s
  kubectl -n cca-lab rollout status deploy/canary --timeout=180s
  This works because the agent Pod is hostNetwork: true and therefore does not
  itself require the CNI plugin to start — the property that makes CNI
  DaemonSets self-healing. If the binary had been renamed rather than deleted
  and you wanted to avoid the restart, the equivalent manual repair is a
  privileged hostNetwork Pod mounting hostPath /opt/cni/bin that moves it back.
  Pods already stuck in ContainerCreating retry the sandbox automatically; you
  do not need to delete them, though 'kubectl delete pod' speeds it up.

Step 5 — verify:
  kubectl -n cca-lab get pods -o wide      # canary Running/Ready with its own Pod IP
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief

Exam takeaway: the CNI contract has exactly two node-local dependencies —
  the config in /etc/cni/net.d and the binary in /opt/cni/bin. "Old Pods work,
  new Pods hang in ContainerCreating" is the signature of that pair being
  broken, and it is never a NetworkPolicy, never DNS, and never the Service.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cca/3.1/lab)
