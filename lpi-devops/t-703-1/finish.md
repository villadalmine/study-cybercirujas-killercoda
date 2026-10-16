## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION  --  do not read until you have genuinely tried

LAYER 1 : "The connection to the server 10.0.2.15:6443 was refused"

STEP 1 - Separate the client from the server. What does the client believe?

    $ kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'; echo
    https://10.0.2.15:6443

    $ ss -lntp | grep 6443
    (no output)

  Nothing is listening on 6443, so this is a server-side fault, not a bad
  kubeconfig. If instead you HAD seen something listening on 6443 while the
  kubeconfig said 16443, the fault would have been client-side and the fix
  would be a one-line edit of ~/.kube/config (that is the fallback variant
  this script uses on non-kubeadm clusters).

STEP 2 - Remember who owns the control plane. On a kubeadm cluster,
  kube-apiserver, kube-scheduler, kube-controller-manager and etcd are STATIC
  PODS: the kubelet reads their manifests from /etc/kubernetes/manifests and
  runs them directly against the CRI. They are not scheduled, they do not need
  the API server to exist, and the kubelet re-reads that directory on every
  file change. So the kubelet is your remaining working control plane.

    $ systemctl is-active kubelet
    active
    $ journalctl -u kubelet -n 30 --no-pager | grep -i apiserver
    ... "Failed to connect to apiserver" ... connection refused

  The kubelet is alive and complaining that IT cannot reach the API server
  either -> the API server process itself is the problem.

STEP 3 - Ask the container runtime directly, bypassing Kubernetes entirely.

    $ export CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock
    $ crictl ps -a --name kube-apiserver
    CONTAINER      IMAGE      CREATED          STATE      NAME             ATTEMPT
    8f2c1a...      d4e...     10 seconds ago   Exited     kube-apiserver   7

  ATTEMPT 7 and STATE Exited = a crash loop. The kubelet keeps restarting it.

STEP 4 - Read the dying process's own words.

    $ crictl logs "$(crictl ps -a --name kube-apiserver -q | head -1)" 2>&1 | tail -20
    ...
    "Failed to create storage backend" err="context deadline exceeded"
    dial tcp 127.0.0.1:12379: connect: connection refused

  Port 12379. etcd's client port is 2379 (2380 is peer traffic). Someone
  changed the flag.

STEP 5 - Confirm in the manifest and fix it.

    $ grep -n 'etcd-servers' /etc/kubernetes/manifests/kube-apiserver.yaml
    23:    - --etcd-servers=https://127.0.0.1:12379

    $ cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/apiserver.bak
    $ sed -i 's#--etcd-servers=\(https\?://[^:]*\):12379#--etcd-servers=\1:2379#' \
          /etc/kubernetes/manifests/kube-apiserver.yaml

  (Editing the file in place is the whole fix. Do NOT `systemctl restart
  kubelet` hoping it helps: the kubelet's inotify watch on the manifest
  directory already picked up the change and is recreating the Pod.)

STEP 6 - Verify the recovery, at the right layer.

    $ ss -lntp | grep 6443
    LISTEN 0 4096 *:6443 *:*  users:(("kube-apiserver",pid=...))

    $ kubectl get --raw='/readyz?verbose'
    [+]ping ok
    [+]etcd ok
    ...
    readyz check passed

  Give the controller-manager and scheduler ~30 s to re-acquire their leader
  election leases before judging anything else.


LAYER 2 : Pods stay Pending forever

STEP 1 - Observe.

    $ kubectl -n breakfix-703-1 get pods -o wide
    NAME                       READY   STATUS    RESTARTS   AGE   NODE
    web-703-6c9f7c8d95-4kqxr   0/1     Pending   0          6m    <none>
    web-703-6c9f7c8d95-t8v2n   0/1     Pending   0          6m    <none>

  NODE is <none>: the kube-scheduler never bound them. This is a scheduling
  problem, not an image or runtime problem.

STEP 2 - The scheduler always explains itself in the Pod's events.

    $ kubectl -n breakfix-703-1 describe pod -l app=web-703 | sed -n '/Events/,$p'
    Events:
      Type     Reason            Message
      ----     ------            -------
      Warning  FailedScheduling  0/1 nodes are available: 1 node(s) had
                                 untolerated taint {lpi.breakfix/703-1:
                                 maintenance}. preemption: 0/1 nodes are
                                 available.

STEP 3 - Confirm on the node object.

    $ kubectl describe node "$(kubectl get nodes -o name | head -1 | cut -d/ -f2)" \
          | grep -A3 Taints
    Taints:  lpi.breakfix/703-1=maintenance:NoSchedule

    $ kubectl get nodes
    NAME     STATUS   ROLES           AGE   VERSION
    lab-01   Ready    control-plane   14d   v1.31.4

  STATUS is Ready and there is no "SchedulingDisabled" marker, so the node was
  never cordoned - `kubectl uncordon` would remove only the built-in
  node.kubernetes.io/unschedulable taint and would change nothing here.

STEP 4 - Two legitimate fixes; pick the one that matches intent.

  (a) The taint is spurious - remove it (trailing dash = delete):

      $ kubectl taint nodes lab-01 lpi.breakfix/703-1-
      node/lab-01 untainted

  (b) The taint is real policy and this workload must run anyway - tolerate it:

      $ kubectl -n breakfix-703-1 patch deploy web-703 --type=merge -p '{
          "spec":{"template":{"spec":{"tolerations":[
            {"key":"lpi.breakfix/703-1","operator":"Equal",
             "value":"maintenance","effect":"NoSchedule"}]}}}}'

  In this lab (a) is correct: nothing else on the node needed protecting.
  Understand the difference - a taint repels Pods from a node; a toleration
  only lets a Pod ignore that repulsion. Neither one attracts a Pod to a node;
  that is what nodeSelector / nodeAffinity do.

STEP 5 - Verify.

    $ kubectl -n breakfix-703-1 rollout status deploy/web-703
    deployment "web-703" successfully rolled out
    $ kubectl -n breakfix-703-1 get pods -o wide
    NAME                       READY   STATUS    RESTARTS   AGE   NODE
    web-703-6c9f7c8d95-4kqxr   1/1     Running   0          8m    lab-01
    web-703-6c9f7c8d95-t8v2n   1/1     Running   0          8m    lab-01


LAYER 3 : the Service resolves but blackholes traffic

STEP 1 - Reproduce from inside the cluster (a ClusterIP is not reachable from
  the VM's host network namespace, so test from a Pod):

    $ kubectl -n breakfix-703-1 exec deploy/web-703 -- wget -qO- --timeout=5 http://web-703
    wget: download timed out
    command terminated with exit code 1

  DNS resolved (no "bad address"), so CoreDNS and the Service object are fine.
  The packets simply have nowhere to go.

STEP 2 - Look at the data plane of a Service: its EndpointSlices.

    $ kubectl -n breakfix-703-1 get endpointslices -l kubernetes.io/service-name=web-703
    NAME           ADDRESSTYPE   PORTS   ENDPOINTS   AGE
    web-703-9xz4k  IPv4          <unset> <unset>     9m

  Empty. kube-proxy programs its rules from these objects, so an empty slice
  means "no backend exists" - iptables/IPVS drops the traffic.

STEP 3 - Compare what the Service asks for with what the Pods actually carry.

    $ kubectl -n breakfix-703-1 get svc web-703 -o jsonpath='{.spec.selector}'; echo
    {"app":"web-7031"}

    $ kubectl -n breakfix-703-1 get pods --show-labels
    NAME                       READY  STATUS   LABELS
    web-703-6c9f7c8d95-4kqxr   1/1    Running  app=web-703,pod-template-hash=6c9f7c8d95

  web-7031 vs web-703. One stray character. This is the single most common
  Service failure in production, and the reason `kubectl get endpoints[slices]`
  belongs in your reflexes right after `kubectl get svc`.

STEP 4 - Fix the Service, never the Pods. The Deployment's own
  spec.selector.matchLabels is immutable after creation, and relabelling Pods
  would orphan them from their ReplicaSet.

    $ kubectl -n breakfix-703-1 patch svc web-703 --type=merge \
          -p '{"spec":{"selector":{"app":"web-703"}}}'
    service/web-703 patched

STEP 5 - Verify end to end.

    $ kubectl -n breakfix-703-1 get endpointslices -l kubernetes.io/service-name=web-703 -o wide
    NAME           ADDRESSTYPE  PORTS  ENDPOINTS               READY
    web-703-9xz4k  IPv4         80     10.244.0.14,10.244.0.15 true,true

    $ kubectl -n breakfix-703-1 exec deploy/web-703 -- wget -qO- --timeout=5 http://web-703 | head -4
    <!DOCTYPE html>
    <html>
    <head>
    <title>Welcome to nginx!</title>

    $ sudo ./703.1-break-and-fix.sh --verify
    [ OK ] Layer 1: the API server answers /readyz
    [ OK ] Layer 2: 2/2 Pods are Ready and the taint is gone
    [ OK ] Layer 3: EndpointSlice is populated
    Score: 3/3


WHAT THIS EXERCISE ACTUALLY TAUGHT (the exam-relevant model)

  * kubectl is a REST client. "Connection refused" is a statement about a
    socket, never a diagnosis. Always ask next: which endpoint, and is anything
    listening there?
  * The control plane is made of ordinary processes. On kubeadm they are static
    Pods owned by the kubelet, declared in /etc/kubernetes/manifests, and
    debuggable with crictl even when the whole API is gone. That is the escape
    hatch that makes a "dead" cluster repairable instead of disposable.
  * etcd is the only stateful component. Every API server flag pointing at it
    (--etcd-servers, --etcd-cafile, --etcd-certfile) is a single point of
    failure for the entire cluster.
  * Scheduling failures are declarative and self-documenting: the scheduler
    writes its refusal into the Pod's events. Pending + NODE <none> means read
    the events; CrashLoopBackOff means read the container logs. Different layer,
    different tool.
  * A Service is a label selector plus a virtual IP - it has no link to a
    Deployment. The chain is: Service.spec.selector -> EndpointSlice controller
    -> EndpointSlice -> kube-proxy -> iptables/IPVS. Any break in that chain
    yields a name that resolves and traffic that vanishes.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpi-devops/703.1/lab)
