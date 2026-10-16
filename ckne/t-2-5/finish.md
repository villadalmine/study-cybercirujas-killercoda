## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION (step by step) - read only after you have tried

--- Step 0: see the data plane from the control plane's side --------------

  kubectl -n ckne-lab-2-5 get pods -o wide
  # NAME                  READY   STATUS    RESTARTS   ...   READINESS GATES
  # web-7d9c...-abcde     0/1     Running   0          ...   0/1

  kubectl -n ckne-lab-2-5 get endpointslices -l kubernetes.io/service-name=web -o yaml
  #   endpoints:
  #   - addresses: ["10.244.1.12"]
  #     conditions:
  #       ready: false
  #       serving: false
  #       terminating: false

  The EndpointSlice controller copies the Pod's Ready condition into
  conditions.ready. kube-proxy (or eBPF replacements like Cilium) only
  programs endpoints with ready=true (or serving=true while terminating).
  Result: the Service VIP has no backends. With iptables kube-proxy you get
  an immediate REJECT ("connection refused"). Other dataplanes may time out.

--- Step 1: find why the Pod is not Ready -------------------------------

  kubectl -n ckne-lab-2-5 get pod <pod> -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
  # PodReadyToStartContainers=True
  # Initialized=True
  # Ready=False
  # ContainersReady=False          <- fault #1: container readiness (probe)
  # PodScheduled=True
  #                                <- fault #2: lab.ckne.io/lb-registered is
  #                                   MISSING, and a missing gate condition counts as False

  Pod Ready = ContainersReady AND every readinessGates condition == True.

--- Step 2: fault #1, the readiness probe points at the wrong port/path ------

  kubectl -n ckne-lab-2-5 describe pod <pod> | grep -i readiness
  #   Readiness:  http-get http://:8080/healthz delay=2s timeout=1s period=5s #success=1 #failure=2
  #   Warning  Unhealthy  ...  Readiness probe failed: Get "http://10.244.1.12:8080/healthz":
  #            dial tcp 10.244.1.12:8080: connect: connection refused

  nginx listens on 80 (named port "http") and has no /healthz. The liveness
  probe (tcpSocket on "http") passes, so nothing restarts. That is why the
  pods "look fine".

  Fix: probe the real port by name, on a path that returns 2xx/3xx:

  kubectl -n ckne-lab-2-5 patch deployment web --type=json -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":"http"},
    {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}
  ]'

--- Step 3: notice the rollout hangs -----------------------------------

  kubectl -n ckne-lab-2-5 rollout status deploy/web
  # Waiting for deployment "web" rollout to finish: 1 out of 3 new replicas have been updated...

  With maxUnavailable=0 and maxSurge=1, the Deployment creates ONE new pod
  and waits for it to become Ready before it continues. The new pod now has
  ContainersReady=True, but READINESS GATES is still 0/1, so it never
  becomes Ready and the rollout stalls. This is exactly what happens in
  production when the LB controller that owns the gate is broken.

--- Step 4: fault #2, satisfy the readiness gate (act as the controller) ----

  A gate condition lives in pod.status, so it has to be written through the
  status subresource (kubectl >= 1.24). The default strategic merge patch
  merges conditions by 'type', so the kubelet-owned conditions are kept.
  Loop until the rollout finishes, because every new pod needs the condition:

  NS=ckne-lab-2-5
  until kubectl -n $NS rollout status deploy/web --timeout=5s >/dev/null 2>&1; do
    for p in $(kubectl -n $NS get pods -l app=web -o name); do
      kubectl -n $NS patch "$p" --subresource=status \
        -p '{"status":{"conditions":[{"type":"lab.ckne.io/lb-registered","status":"True","reason":"ManualRegistration","message":"set by student"}]}}' \
        >/dev/null 2>&1 || true
    done
    sleep 3
  done

  (Alternative accepted by the checker: remove the gate from the template
   with  kubectl -n $NS patch deploy web --type=json \
         -p='[{"op":"remove","path":"/spec/template/spec/readinessGates"}]'
   You lose the guarantee that pods only receive traffic after the external
   system registers them.)

--- Step 5: verify ---------------------------------------------------

  kubectl -n ckne-lab-2-5 get pods -o wide
  # web-...   1/1   Running   0   ...   1/1

  kubectl -n ckne-lab-2-5 get endpointslices -l kubernetes.io/service-name=web \
    -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} ready={.conditions.ready}{"\n"}{end}'
  # 10.244.1.20 ready=true
  # 10.244.2.17 ready=true
  # 10.244.1.21 ready=true

  kubectl -n ckne-lab-2-5 exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://web
  # 200

  ./break-fix-2.5.sh check

--- Wrong fixes and why they are wrong ------------------------------

  * spec.publishNotReadyAddresses: true on the Service
      curl would succeed here only because nginx happens to work. The
      setting exists for StatefulSet peer discovery via headless Services
      (e.g. etcd, Cassandra bootstrap), where peers must resolve each other
      before they are Ready. On a client-facing Service it sends traffic to
      pods that failed readiness.
  * Deleting the readinessProbe
      The pod becomes Ready as soon as the container starts, before the app
      is actually able to serve, so every rollout causes errors.
  * Pointing the readinessProbe at the same check as liveness without thought
      Readiness should reflect "can I serve traffic now" (dependencies,
      warm-up). Liveness should reflect "am I stuck and need a restart".
      If they are the same check, a slow dependency causes restarts.

--- Cleanup ------------------------------------------------------

  ./break-fix-2.5.sh cleanup
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/2.5/lab)
