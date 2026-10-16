## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION (do not read it before trying)

 --- Step 1: read the symptom where it is written --------------------------

   kubectl -n bnf-cni describe pod wire-me
     Warning  FailedCreatePodSandBox  kubelet  Failed to create pod sandbox:
     ... plugin type="lab-bridge-v2" failed (add): failed to find plugin
     "lab-bridge-v2" in path [/opt/cni/bin]

   Key point: the kubelet does not run CNI. It asks the runtime for a
   sandbox through CRI (RunPodSandbox), and the runtime (containerd/CRI-O)
   runs the plugins through libcni. That is why the error comes back
   wrapped in "rpc error" and why the detail is also in the runtime's
   journal:

   journalctl -u containerd --since "10 min ago" | grep -i cni

 --- Step 2: which config is the runtime actually using? -------------------

   ls -l /etc/cni/net.d/
     -rw-r--r-- 1 root root  512 ... 00-lab-shadow.conflist   <-- sorts first
     -rw-r--r-- 1 root root  680 ... 10-calico.conflist        (or 10-flannel...)

   crictl info | grep -A3 -i '"cni"'
     "confDir": "/etc/cni/net.d",
     "binDirs": ["/opt/cni/bin"],
     "maxConfNum": 1,

   crictl info | grep -i '"name"' | head
     shows "lab-shadow-net": the loaded network is not the cluster's.

   containerd (CRI plugin) sorts the files in confDir lexically and loads
   up to max_conf_num (default 1). The first one wins. A leftover file
   named 00-* silently shadows the real CNI. It parses fine, so the Node
   stays Ready; it only fails on the CNI ADD for each new pod.

   ls /opt/cni/bin/lab-bridge-v2
     ls: cannot access '/opt/cni/bin/lab-bridge-v2': No such file or directory

   The "type" field of each plugin is the NAME OF THE BINARY that libcni
   looks for in binDirs (CNI spec, "Plugin configuration objects").

 --- Step 3: take the shadow config out (move it, don't delete it: evidence)

   mkdir -p /root/cni-quarantine
   mv /etc/cni/net.d/00-lab-shadow.conflist /root/cni-quarantine/

   containerd watches confDir (fsnotify) and reloads without a restart.
   CRI-O does too. If in doubt:
     systemctl restart containerd     # running pods are not affected

 --- Step 4: the SECOND fault appears (it was hidden behind the first) -----

   kubectl -n bnf-cni describe pod wire-me | tail -n 2
     ... plugin type="calico" failed (add): fork/exec /opt/cni/bin/calico:
     permission denied
   (with Flannel: /opt/cni/bin/flannel; with Cilium: /opt/cni/bin/cilium-cni)

   ls -l /opt/cni/bin/calico
     -rw-r--r-- 1 root root 59M ... /opt/cni/bin/calico      <-- no 'x'

   Compare with its neighbours:
   ls -l /opt/cni/bin/ | head
     -rwxr-xr-x 1 root root 4.0M ... bandwidth
     -rwxr-xr-x 1 root root 4.4M ... bridge
     ...

 --- Step 5: restore the execute bit ---------------------------------------

   chmod 0755 /opt/cni/bin/calico           # use the real binary name

   Note: with Calico, Cilium and Flannel, the DaemonSet's init container
   (install-cni) copies the binaries back when the agent pod restarts.
   The "operator" alternative would be:
     kubectl -n kube-system delete pod -l k8s-app=calico-node \
       --field-selector spec.nodeName=<node>
   But in the exam, fixing the exact cause is faster and shows you
   understand it. Also check the whole chain the config references
   (the main plugin + IPAM + portmap/bandwidth/tuning):

     for t in $(grep -o '"type": *"[^"]*"' /etc/cni/net.d/10-*.conflist \
                | cut -d'"' -f4 | sort -u); do
       test -x /opt/cni/bin/$t && echo "OK  $t" || echo "BAD $t"
     done

 --- Step 6: verify ---------------------------------------------------------

   The kubelet retries sandbox creation with exponential backoff, so you
   don't need to recreate the pod (you can delete it to speed things up):

   kubectl -n bnf-cni get pod wire-me -o wide -w
     NAME      READY   STATUS    RESTARTS   AGE   IP              NODE
     wire-me   1/1     Running   0          6m    192.168.35.201  node1

   The IP must come from the cluster's Pod CIDR:
     kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'
     kubectl -n kube-system get cm kubeadm-config -o yaml | grep podSubnet

   sudo ./bnf-cni-1.1.sh check
     [OK] 1/5 No config file shadows the real one.
     [OK] 2/5 Active config: 10-calico.conflist
     [OK] 3/5 Every plugin referenced by the active config is executable.
     [OK] 4/5 bnf-cni/wire-me is Ready.
     [OK] 5/5 podIP 192.168.35.201 comes from the real network.
     [OK] LAB SOLVED (5/5).

 --- Step 7: cleanup ---------------------------------------------------------

   kubectl delete ns bnf-cni
   rm -rf /var/lib/bnf-cni-lab /root/cni-quarantine

 --- Lessons for the exam ----------------------------------------------------

   1. Pod stuck in ContainerCreating + FailedCreatePodSandBox = look at CNI
      before anything else. A Ready Node does NOT prove CNI works.
   2. The runtime loads the lexically first file in /etc/cni/net.d.
      One leftover file (00-*, 05-*, 99-backup.conflist.bak ending in
      .conflist) changes the whole node's network.
   3. "type" = binary name in bin_dir. "failed to find plugin" = missing
      binary or wrong bin_dir (check with crictl info / config.toml).
   4. "permission denied" on fork/exec = file permissions or noexec,
      not network policy.
   5. Faults stack up: after fixing one, read the NEW event, don't assume.
   6. Running pods are not affected: CNI only runs on ADD/DEL/CHECK.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/1.1/lab)
