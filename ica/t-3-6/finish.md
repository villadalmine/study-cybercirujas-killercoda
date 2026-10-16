## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 INSTRUCTOR SOLUTION — do not read until you have tried it yourself
 ROOT CAUSE
   The DestinationRule configured a fail-CLOSED circuit breaker. With
   consecutive5xxErrors=1 a single upstream 5xx ejects a host; with
   maxEjectionPercent=100 both replicas can be ejected at once; with
   baseEjectionTime=180s they stay out for 3 minutes. So one transient
   error produced a full, self-inflicted outage — even on /status/200,
   which cannot fail on its own. The 1/1/1 connectionPool limits made the
   breaker trip under trivial concurrency (Envoy flag 'UO').

 STEP 1 — Observe and confirm the diagnosis
   kubectl -n ica-lab-36 get destinationrule httpbin -o yaml
   ./lab_3_6.sh diag
     # look for  outlier.ejections_active  > 0  and  health_flags::/failed_outlier_check
   istioctl -n ica-lab-36 proxy-config clusters deploy/curl-client \
     --fqdn httpbin.ica-lab-36.svc.cluster.local

 STEP 2 — Retune the resilience policy (fail PARTIAL, not TOTAL)
   cat <<'YAML' | kubectl apply -f -
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: httpbin
     namespace: ica-lab-36
   spec:
     host: httpbin
     trafficPolicy:
       connectionPool:
         tcp:
           maxConnections: 100          # room for real concurrency
         http:
           http1MaxPendingRequests: 100
           maxRequestsPerConnection: 0  # 0 = unlimited (no premature recycling)
       outlierDetection:
         consecutive5xxErrors: 5        # need a real pattern, not one blip
         interval: 5s
         baseEjectionTime: 30s          # shorter penalty, self-heals faster
         maxEjectionPercent: 50         # NEVER eject the whole pool
   YAML
   # Re-applying the DestinationRule resets Envoy's cluster and immediately
   # clears any hosts still ejected under the old 180s timer.

 STEP 3 — Verify
   ./lab_3_6.sh verify        # expect PASS: ~20/20 x 200, outlier detection still on

 KEY TAKEAWAYS FOR THE EXAM
   * maxEjectionPercent caps the blast radius; 100 turns a circuit breaker
     into a single point of failure. Keep it well below 100 (commonly 10-50).
   * consecutive5xxErrors=1 is hair-trigger; use a threshold that reflects a
     genuine failure trend, and keep baseEjectionTime short so hosts re-enter.
   * Related resilience knobs you should also be able to configure:
       - Timeouts:  VirtualService http.timeout
           https://istio.io/latest/docs/tasks/traffic-management/request-timeouts/
       - Retries:   VirtualService http.retries {attempts, perTryTimeout, retryOn}
           https://istio.io/latest/docs/reference/config/networking/virtual-service/#HTTPRetry
       - Failover:  DestinationRule localityLbSetting.failover / failoverPriority
           https://istio.io/latest/docs/reference/config/networking/destination-rule/#LocalityLoadBalancerSetting
   * Golden rule of resilience config: degrade gracefully and partially;
     a policy that can drive availability to zero is worse than none.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ica/3.6/lab)
