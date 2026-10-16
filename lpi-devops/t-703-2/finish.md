## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
=== SOLUTION START =========================================================

ANSWER KEY — LPI 701-100, topic 703.2 (Basic Kubernetes Operations)
Namespace: bf-703-2 (override with NS=). Every command below assumes
`-n bf-703-2` unless it is explicitly cluster-scoped.

STEP 0 — Universal triage order. Do this before touching anything.
  kubectl -n bf-703-2 get all -o wide
  kubectl -n bf-703-2 get pods --show-labels
  kubectl -n bf-703-2 get events --sort-by=.lastTimestamp | tail -20

  Read the Pod STATUS column first; it tells you which layer failed:
    Pending                     -> scheduler (resources, taints, nodeSelector)
    ContainerCreating (stuck)   -> kubelet: volumes, CNI, image pull in progress
    ImagePullBackOff/ErrImagePull -> registry, tag or credentials
    CreateContainerConfigError  -> missing ConfigMap/Secret referenced by the Pod
    CrashLoopBackOff            -> the process itself exits; read logs
    Running + READY 0/1         -> readiness probe
    Running + READY 1/1 + no traffic -> Service selector / ports / NetworkPolicy

SCENARIO 1 — Service selector drift (empty endpoints)
Diagnose:
  kubectl -n bf-703-2 get endpointslice -l kubernetes.io/service-name=web -o wide
    NAME        ADDRESSTYPE   PORTS   ENDPOINTS   AGE
    web-9wq2p   IPv4          <unset> <unset>     14m       <-- no addresses
  kubectl -n bf-703-2 get svc web -o jsonpath='{.spec.selector}{"\n"}'
    {"app":"web-frontend"}
  kubectl -n bf-703-2 get pods -l app=web --show-labels
    web-5c8bd6f9d7-lm4kv   1/1   Running   app=web,pod-template-hash=...,tier=frontend

  The Service selects app=web-frontend; the Pods carry app=web. No intersection.

Fix (durable — change the Service, which is the object that drifted):
  kubectl -n bf-703-2 patch service web -p '{"spec":{"selector":{"app":"web"}}}'

  Equivalent declarative form:
    kubectl -n bf-703-2 edit service web        # spec.selector.app: web

  Do NOT "fix" it by relabelling the Pods (kubectl label pod ... app=web-frontend):
  the Deployment's template would overwrite that on the next rollout, and a Pod
  whose labels no longer match spec.selector.matchLabels is orphaned from its
  ReplicaSet — the controller immediately creates a replacement.

Verify:
  kubectl -n bf-703-2 get endpointslice -l kubernetes.io/service-name=web -o wide
    ENDPOINTS: 10.42.0.31,10.42.0.32,10.42.0.33
  kubectl -n bf-703-2 exec deploy/tester -- curl -sS http://web.bf-703-2.svc.cluster.local/ | grep LPI
    <h1>LPI-703.2-OK</h1>

SCENARIO 2 — Image tag typo (ImagePullBackOff, rollout stuck)
Diagnose:
  kubectl -n bf-703-2 rollout status deployment/web --timeout=10s
    error: timed out waiting for the condition
  kubectl -n bf-703-2 describe pod -l app=web | grep -B2 -A4 'Failed'
    Warning  Failed  kubelet  Failed to pull image "nginx:1.29-alpone":
             failed to resolve reference: not found: manifest unknown
  kubectl -n bf-703-2 get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
    nginx:1.29-alpone

Fix A — roll back to the last known-good revision (fastest, and what you do at 03:00):
  kubectl -n bf-703-2 rollout history deployment/web
    REVISION  CHANGE-CAUSE
    1         <none>
    2         <none>
  kubectl -n bf-703-2 rollout history deployment/web --revision=1 | grep Image
    Image:  nginx:1.29-alpine
  kubectl -n bf-703-2 rollout undo deployment/web --to-revision=1

Fix B — fix forward (when the intended new version is known good):
  kubectl -n bf-703-2 set image deployment/web web=nginx:1.29-alpine

Verify:
  kubectl -n bf-703-2 rollout status deployment/web
    deployment "web" successfully rolled out
  kubectl -n bf-703-2 get pods -l app=web
    3 Pods, 1/1 Running

Note: the old ReplicaSet kept serving throughout. `kubectl get rs -n bf-703-2`
shows the failed one scaled to its surge count with 0 ready — that pair of
ReplicaSets is the signature of a stalled RollingUpdate.

SCENARIO 3 — Unschedulable CPU request (Pending)
Diagnose:
  kubectl -n bf-703-2 describe pod -l app=web | tail -6
    Warning  FailedScheduling  default-scheduler
      0/1 nodes are available: 1 Insufficient cpu.
  kubectl describe node | grep -A8 'Allocatable'
    cpu:  4
  kubectl -n bf-703-2 get deploy web \
    -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
    {"limits":{"cpu":"64","memory":"128Mi"},"requests":{"cpu":"64","memory":"32Mi"}}

  64 CPUs requested on a 4-CPU node: the scheduler can never satisfy it. The
  scheduler only ever looks at requests; limits are enforced later by the
  kubelet/cgroups, but a limit lower than the request is rejected by the API
  server, which is why both fields must come down together.

Fix:
  kubectl -n bf-703-2 patch deployment web --type=json -p '[
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"50m"},
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/cpu","value":"200m"}]'

Verify:
  kubectl -n bf-703-2 get pods -l app=web -o wide     # all Running, NODE assigned
  kubectl -n bf-703-2 rollout status deployment/web

SCENARIO 4 — Missing ConfigMap (CreateContainerConfigError)
Diagnose:
  kubectl -n bf-703-2 describe pod -l app=web | tail -4
    Warning  Failed  kubelet  Error: configmap "web-content" not found
  kubectl -n bf-703-2 get deploy web -o jsonpath='{.spec.template.spec.volumes}{"\n"}'
    [{"configMap":{"name":"web-content"},"name":"content"}]
  kubectl -n bf-703-2 get cm
    No resources found in bf-703-2 namespace.

  The mount path tells you what the key must be called:
  volumeMounts[0].mountPath == /usr/share/nginx/html, and a ConfigMap volume
  projects each key as a file. nginx serves index.html from that directory.

Fix (declarative — this is the form you keep in git):
  kubectl apply -f - <<'YAML'
  apiVersion: v1
  kind: ConfigMap
  metadata:
    name: web-content
    namespace: bf-703-2
  data:
    index.html: |
      <!doctype html>
      <html>
        <head><title>LPI-703.2-OK</title></head>
        <body><h1>LPI-703.2-OK</h1><p>703.2 Basic Kubernetes Operations</p></body>
      </html>
  YAML

  Imperative equivalent:
    printf '<h1>LPI-703.2-OK</h1>\n' > /tmp/index.html
    kubectl -n bf-703-2 create configmap web-content --from-file=index.html=/tmp/index.html

  Pods in CreateContainerConfigError retry on their own backoff; to converge now:
    kubectl -n bf-703-2 rollout restart deployment/web

  Careful: an already-mounted ConfigMap updates in place (kubelet refreshes the
  projected files within ~1 minute) but a *recreated* one only reaches Pods that
  are (re)started — which is exactly why the fault survived until the restart.

Verify:
  kubectl -n bf-703-2 exec deploy/tester -- curl -sS http://web.bf-703-2.svc.cluster.local/
    ... <h1>LPI-703.2-OK</h1> ...

SCENARIO 5 — Readiness probe on the wrong port (Running, 0/1 READY)
Diagnose:
  kubectl -n bf-703-2 get pods -l app=web
    web-79fbb6cc8d-pk2tt   0/1   Running   0   90s
  kubectl -n bf-703-2 describe pod -l app=web | grep -i -A1 'readiness'
    Readiness:  http-get http://:8080/ delay=2s timeout=1s period=5s
    Warning  Unhealthy  kubelet  Readiness probe failed:
      Get "http://10.42.0.31:8080/": dial tcp 10.42.0.31:8080: connect: connection refused
  Prove the server itself is fine, from inside the container:
  kubectl -n bf-703-2 exec deploy/web -- wget -qO- http://127.0.0.1:80/ | head -1
    <!doctype html>

  Container alive + probe failing = the probe is wrong, not the app. Because
  readiness is what gates EndpointSlice membership, the Service has endpoints
  with conditions.ready=false and kube-proxy programs no backend.

Fix:
  kubectl -n bf-703-2 patch deployment web --type=json -p '[
    {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":80}]'

  Better still, reference the named port so the probe can never drift again:
    ... readinessProbe.httpGet.port: http     # matches ports[0].name

Verify:
  kubectl -n bf-703-2 get pods -l app=web            # 1/1 READY
  kubectl -n bf-703-2 get endpointslice -l kubernetes.io/service-name=web \
    -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'
    10.42.0.31 ready=true

SCENARIO 6 — kubeconfig default namespace trap
Diagnose:
  kubectl get pods
    No resources found in bf-703-2-decoy namespace.       <-- read the namespace!
  kubectl config view --minify -o jsonpath='{..namespace}{"\n"}'
    bf-703-2-decoy
  kubectl get deployments -A | grep web
    bf-703-2   web   3/3   3   3   22m

Fix:
  kubectl config set-context --current --namespace=bf-703-2
  kubectl config view --minify | grep namespace:
    namespace: bf-703-2

  Resolution order to memorise: --namespace/-n  >  context.namespace  >  "default".
  `kubectl api-resources --namespaced=false` lists what ignores namespaces entirely
  (nodes, PVs, StorageClasses, ClusterRoles…), which is why `get nodes` kept working.

FINAL VERIFICATION (what the grader runs)
  kubectl -n bf-703-2 get deploy web -o jsonpath='{.status.availableReplicas}/{.spec.replicas}{"\n"}'
    3/3
  kubectl -n bf-703-2 exec deploy/tester -- \
    curl -sS -o /dev/null -w '%{http_code}\n' http://web.bf-703-2.svc.cluster.local/
    200
  ./lpi-701-703.2-break-and-fix.sh verify
    [+] ALL CHECKS PASSED

Tear down:
  ./lpi-701-703.2-break-and-fix.sh cleanup

References
  https://www.lpi.org/our-certifications/exam-701-objectives/
  https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/
  https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-back-a-deployment
  https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
  https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
  https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
  https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/
=== SOLUTION END ===========================================================
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpi-devops/703.2/lab)
