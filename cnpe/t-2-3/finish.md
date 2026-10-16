## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — step by step (read only after you have tried)

0) Frame the incident: what is the blast radius?
  kubectl get deploy,rs,pods,svc,endpoints -n cnpe-lab-23

  You will see:
    * deployment.apps/payments-api  READY 0/3  (or 3/3 UP-TO-DATE but 0 AVAILABLE)
    * a NEW replicaset scaled to 3, an OLD one scaled to 0
    * pods:  STATUS=Running   READY=0/1   RESTARTS=0
    * endpoints/payments-api:  <none>     <-- the smoking gun

  Reading it: the app is not crashing (RESTARTS=0, STATUS=Running), so this is
  NOT an image/crashloop problem. The Service has no endpoints, which is
  exactly why callers get 503 — kube-proxy has nothing to route to.

1) Confirm it is a "no ready endpoints" problem, not a selector/DNS problem
  kubectl get endpoints payments-api -n cnpe-lab-23
  kubectl get endpointslices -n cnpe-lab-23 -l kubernetes.io/service-name=payments-api

  The addresses list is empty and pods appear under 'notReadyAddresses' only.
  Rule out a selector mismatch (a common look-alike incident):
    kubectl describe svc payments-api -n cnpe-lab-23        # Selector: app=payments-api
    kubectl get pods -n cnpe-lab-23 --show-labels           # pods carry app=payments-api
  Labels match, so the Service targets the right pods — they are simply Not Ready.

2) Ask WHY the pods are Not Ready — read the pod events
  kubectl describe pod -n cnpe-lab-23 -l app=payments-api | sed -n '/Events/,$p'

  Events show, repeatedly:
    Warning  Unhealthy  Readiness probe failed: Get "http://10.x.x.x:8080/":
             dial tcp 10.x.x.x:8080: connect: connection refused
  Liveness (port 80) is silent — the container IS alive. Only *readiness* on
  port 8080 fails. Root cause hypothesis: the readiness probe points at a port
  nothing is listening on.

  Confirm the container really listens on 80, not 8080:
    kubectl exec -n cnpe-lab-23 deploy/payments-api -- \
      sh -c 'wget -qO- -T2 http://127.0.0.1:80/ >/dev/null && echo "80 OK"; \
             wget -qO- -T2 http://127.0.0.1:8080/ >/dev/null || echo "8080 DEAD"'

3) Pin the change to a rollout (this is an incident, so look at history)
  kubectl rollout history deployment/payments-api -n cnpe-lab-23
  kubectl get deploy payments-api -n cnpe-lab-23 \
    -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.port}{"\n"}'
  -> 8080   (revision 2 introduced the bad probe port; revision 1 had 80)

4) Remediate — pick the on-call-correct path
  OPTION A (preferred during an incident: fast, low-risk rollback):
    kubectl rollout undo deployment/payments-api -n cnpe-lab-23
    kubectl rollout status deployment/payments-api -n cnpe-lab-23 --timeout=120s

  OPTION B (forward fix, if you must keep other revision-2 changes):
    kubectl patch deployment payments-api -n cnpe-lab-23 --type=json \
      -p='[{"op":"replace",
            "path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port",
            "value":80}]'
    kubectl rollout status deployment/payments-api -n cnpe-lab-23 --timeout=120s

5) Verify recovery (both signals must be green)
  kubectl get pods,endpoints -n cnpe-lab-23        # pods 1/1 Ready, endpoints populated
  ./break_fix.sh verify                            # endpoints > 0 AND HTTP 200
  # or manually:
  kubectl run t --rm -i --restart=Never -n cnpe-lab-23 \
    --image=curlimages/curl:8.10.1 -- \
    curl -s -o /dev/null -w '%{http_code}\n' \
    http://payments-api.cnpe-lab-23.svc.cluster.local/

6) Post-incident lesson (the platform-engineering takeaway)
  * A wrong readiness probe is a silent outage: pods stay Running and never
    restart, so alerting on RESTARTS or CrashLoopBackOff would have missed it.
    Alert on Deployment AVAILABLE replicas and on Service endpoint count.
  * The 'Recreate' strategy let a bad template take down every pod at once.
    With a RollingUpdate + maxUnavailable:0, the new Not-Ready pods could never
    have replaced the healthy ones — the rollout would have stalled at surge
    capacity with ZERO customer impact. That is the guardrail worth adding.
  * readinessProbe governs traffic (endpoints); livenessProbe governs restarts.
    Confusing the two is one of the most common self-inflicted platform outages.

Sources (official):
  Configure liveness, readiness and startup probes —
    https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
  Debug Services (endpoints, selectors, 503s) —
    https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
  Rolling back a Deployment —
    https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-back-a-deployment
  EndpointSlices —
    https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
  CNPE Curriculum —
    https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpe/2.3/lab)
