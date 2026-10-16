## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 INSTRUCTOR SOLUTION — DO NOT READ UNTIL YOU HAVE ATTEMPTED THE FIX

 Root cause in one sentence:
   The rollout changed the container's readinessProbe httpGet path to
   "/healthz", which nginx answers with HTTP 404. A readiness probe treats
   any non-2xx/3xx response as a failure, so every pod stays NotReady; the
   kubelet removes NotReady pods from the Service's EndpointSlice, leaving the
   ClusterIP with zero backends — a full outage even though every container
   is happily Running (liveness still targets "/", so nothing restarts).

 PHASE 1 — DETECT & TRIAGE (establish blast radius before touching anything)
   kubectl -n cnpa-incident-lab get deploy,rs,pods,endpoints -o wide
     # Deployment: 0/3 available. Pods: Running, READY 0/1, low restarts.
     # endpoints/web: <none>  <-- this line IS the outage.

   kubectl -n cnpa-incident-lab get endpointslices -l kubernetes.io/service-name=web
     # Confirms zero ready addresses backing the Service.

 Mental model to verbalize: "Running" is a pod lifecycle phase; "Ready" is a
 readiness-gate result. Services route only to Ready endpoints. The two are
 independent — that gap is the whole incident.

 PHASE 2 — DIAGNOSE (find the proximate cause and the change that introduced it)
   kubectl -n cnpa-incident-lab describe pod -l app=web | sed -n '/Conditions/,/Events/p'
     # Ready: False, ContainersReady: False.
     # Events: "Readiness probe failed: HTTP probe failed with statuscode: 404".

   kubectl -n cnpa-incident-lab get events --sort-by=.lastTimestamp | tail
     # A wall of "Unhealthy ... Readiness probe failed ... statuscode: 404".

   # Prove it is readiness-only (container is genuinely serving on "/"):
   POD=$(kubectl -n cnpa-incident-lab get pod -l app=web -o name | head -1)
   kubectl -n cnpa-incident-lab exec "$POD" -- \
     wget -qO- -S http://127.0.0.1:8080/ 2>&1 | head -1     # -> 200 OK
   kubectl -n cnpa-incident-lab exec "$POD" -- \
     wget -qO- -S http://127.0.0.1:8080/healthz 2>&1 | head -1  # -> 404 Not Found

   # Tie it to a change — read the release log:
   kubectl -n cnpa-incident-lab rollout history deploy/web
     # REVISION 1  baseline healthy release (readiness=/)
     # REVISION 2  incident: readiness path changed to /healthz (404)
   kubectl -n cnpa-incident-lab rollout history deploy/web --revision=2
     # Shows readinessProbe.httpGet.path: /healthz  <-- the smoking gun.

 PHASE 3 — REMEDIATE  (choose based on urgency; both restore service)
 OPTION A — FAST ROLLBACK (preferred under SEV pressure; reverts to a known-good state):
   kubectl -n cnpa-incident-lab rollout undo deploy/web --to-revision=1
   kubectl -n cnpa-incident-lab rollout status deploy/web --timeout=120s

 OPTION B — FORWARD FIX (when rollback would revert other, wanted changes):
   kubectl -n cnpa-incident-lab patch deploy/web --type=json \
     -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}]'
   kubectl -n cnpa-incident-lab rollout status deploy/web --timeout=120s
   # (In a real platform, the durable forward fix is to make the probe target
   #  a real endpoint: ship an actual /healthz in the app, or point the probe
   #  at "/". Never "fix" a red probe by deleting it.)

 PHASE 4 — VERIFY (do not declare resolved until traffic actually flows)
   kubectl -n cnpa-incident-lab get pods -l app=web        # 3x READY 1/1
   kubectl -n cnpa-incident-lab get endpoints web          # 3 IPs listed
   kubectl -n cnpa-incident-lab run smoke --rm -it --restart=Never \
     --image=curlimages/curl -- -sS -o /dev/null -w '%{http_code}\n' http://web
     # -> 200
   ./cnpa_3_4_break_and_fix.sh verify                      # -> SERVICE HEALTHY

 PHASE 5 — POST-INCIDENT / DURABLE GUARDRAILS (the platform-engineering payload)
  * Why did one bad probe = total outage? The Deployment used strategy
    Recreate, so all replicas were replaced at once with the broken spec.
    A RollingUpdate with a conservative maxUnavailable (e.g. 0) plus a
    minReadySeconds gate would have STALLED the rollout with the old healthy
    pods still serving — the rollout would fail closed instead of open.
  * Add a progressive-delivery gate (Argo Rollouts / Flagger canary) that
    watches Ready endpoints and auto-aborts a rollout that yields 0 backends.
  * CI policy check on manifests: readiness/liveness probe paths must match a
    route the app actually serves; block probes pointing at undefined paths.
  * Alert on the leading signal — Service endpoints == 0 (or
    kube_endpoint_address_available == 0) — not just on user-facing 5xx, so
    detection beats the customers.
  * Keep liveness and readiness semantically distinct: readiness gates
    traffic; liveness restarts. Had liveness ALSO pointed at /healthz, this
    would have degraded into CrashLoopBackOff and masked the real cause.

 Sources (official):
   - Kubernetes — Configure Liveness, Readiness and Startup Probes:
     https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
   - Kubernetes — Service & EndpointSlices (readiness -> endpoints):
     https://kubernetes.io/docs/concepts/services-networking/service/
     https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
   - Kubernetes — Deployments: rollout, history, undo, strategies:
     https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
   - CNPA Curriculum (Domain 3.4):
     https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpa/3.4/lab)
