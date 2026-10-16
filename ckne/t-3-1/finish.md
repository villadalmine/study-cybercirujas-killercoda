## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION (spoilers - try first!)

--- Step 1: reproduce and read the evidence -------------------------------

  Non-streaming, 8 tokens:
    HTTP/1.1 504 Gateway Timeout
    upstream request timeout
  The response body is written by Envoy itself, not by the backend. Envoy's
  stats confirm it:
    kubectl -n ckne-llm-lab port-forward deploy/llm-gateway 9901:9901 &
    curl -s localhost:9901/stats | grep upstream_rq_timeout
      cluster.llm-backends.upstream_rq_timeout: 3

  Streaming: tokens 0..3 arrive and then the connection drops (curl: (18)
  transfer closed ...). Once response headers are sent, Envoy cannot turn a
  timeout into a 504, so it resets the stream instead.

  Backend logs show the other side of it:
    kubectl -n ckne-llm-lab logs deploy/llm-backend | grep "went away"

--- Step 2: understand fault #1 (timeouts) ----------------------------------

  route.timeout is a TOTAL deadline: from the end of the downstream request
  until the upstream response is COMPLETE. When unset, Envoy uses 15s.
  For REST that is sensible. For an LLM the response length scales with
  max_tokens: 2 s prefill + 16 tokens x 0.8 s = ~15 s here, and minutes with
  real reasoning models. Any fixed total cap will eventually truncate a
  legitimate answer.

  The correct shape for token streams is:
    - no total cap (timeout: 0s disables it), and
    - an IDLE timeout: the maximum silence allowed between bytes. A healthy
      generation sends a token every few hundred ms. A hung GPU worker
      sends nothing, and gets cut off.
  The route-level idle_timeout overrides the HTTP connection manager's
  stream_idle_timeout (default 5 min) for that route.

  Note that the non-streaming request is silent until it completes, so the
  idle timeout must exceed the longest non-streaming generation you accept.
  This is one more reason to stream LLM responses.

--- Step 3: understand fault #2 (load balancing) ----------------------------

  curl -s localhost:9901/clusters | grep -E 'llm-backends::[0-9.]+:8000::rq_total'
  shows three hosts with near-identical counts: ROUND_ROBIN at work.

  Per-pod /metrics shows the cost:
    kubectl -n ckne-llm-lab exec client -- sh -c \
      'for ip in $(nslookup llm-backend-headless | awk "/^Address: /{print \$2}"); do curl -s $ip:8000/metrics; done'
  Misses dominate and every pod caches the same conversations.

  An inference server's KV cache is local to the pod. Turn N of a
  conversation shares its whole prefix with turn N-1, so sending it to the
  same pod skips prefill (TTFT drops from ~2 s to ~0.1 s here, and saves
  GPU FLOPs in production). Round-robin and least-request are
  cache-oblivious. A consistent hash on the conversation identity gives
  affinity, and a consistent ring keeps most sessions in place when a pod
  is added or removed.

--- Step 4: apply the fix ---------------------------------------------------

  kubectl -n ckne-llm-lab edit configmap envoy-config

  Route section, from:
                route:
                  cluster: llm-backends
                  timeout: 5s
  to:
                route:
                  cluster: llm-backends
                  timeout: 0s
                  idle_timeout: 30s
                  hash_policy:
                  - header:
                      header_name: x-session-id

  Cluster section, from:
    lb_policy: ROUND_ROBIN
  to:
    lb_policy: RING_HASH
    ring_hash_lb_config:
      minimum_ring_size: 1024

  (MAGLEV is an equally valid consistent-hash choice: faster lookups, a
  little more disruption when the host set changes.)

  Envoy reads this static bootstrap only at startup, so restart it:
    kubectl -n ckne-llm-lab rollout restart deploy/llm-gateway
    kubectl -n ckne-llm-lab rollout status deploy/llm-gateway

  Confirm Envoy loaded the new config, instead of assuming it:
    curl -s localhost:9901/config_dump | grep -E '"(lb_policy|timeout|idle_timeout)"|header_name'
      "lb_policy": "RING_HASH",
      "timeout": "0s",
      "idle_timeout": "30s",
      "header_name": "x-session-id"

--- Step 5: verify -----------------------------------------------------------

  ./break-fix-3.1-llm-traffic.sh verify
    PASS  non-streaming 16-token completion returned 200
    PASS  stream delivered 16/16 tokens and [DONE]
    PASS  a non-zero idle timeout is configured
    PASS  all 6 turns served by the same pod
    PASS  turns 2..6 were prefix-cache hits (5/5)
    PASS  12 distinct sessions landed on 2 or 3 pods (not pinned to one)

  Requests WITHOUT x-session-id get a random host under RING_HASH, because
  there is nothing to hash. In production, make the client (or an upstream
  filter) always set a stable conversation key.

--- Step 6: the same fix in Gateway API terms (what the exam expects) -------

  Timeouts in HTTPRoute (standard since Gateway API v1.2). "0s" disables
  the timeout. The idle timeout is implementation-specific (for example
  Envoy Gateway's ClientTrafficPolicy / BackendTrafficPolicy):

    apiVersion: gateway.networking.k8s.io/v1
    kind: HTTPRoute
    metadata:
      name: llm
    spec:
      parentRefs:
      - name: inference-gateway
      rules:
      - matches:
        - path:
            type: PathPrefix
            value: /v1/
        backendRefs:
        - name: llm-backend
          port: 8000
        timeouts:
          request: "0s"

  Consistent-hash affinity is also implementation-specific. With Envoy
  Gateway it is a BackendTrafficPolicy with loadBalancer.type: ConsistentHash
  hashing on a header; check the exact field shape for your release.

  The production-grade answer goes beyond a static hash: the Gateway API
  Inference Extension. An InferencePool groups the model-server pods, and an
  Endpoint Picker (EPP) chooses the pod for each request from live
  model-server metrics: queue depth, KV-cache utilisation, prefix-cache
  locality and loaded LoRA adapters. A hash, by contrast, keeps sending a
  session to a pod even while that pod is saturated. The HTTPRoute then
  points its backendRef at the InferencePool instead of a Service.
    https://gateway-api-inference-extension.sigs.k8s.io/

--- Takeaways ----------------------------------------------------------------

  * LLM responses are long-lived streams: bound silence (idle timeout), not
    total duration.
  * The KV / prefix cache makes backend pods non-interchangeable. Routing
    should preserve cache locality: a hash at minimum, cache- and load-aware
    picking (InferencePool + EPP) in production.
  * Always prove a fix from the proxy's own view (config_dump, /stats,
    /clusters) and from the backend's metrics, not only from a single curl.

Cleanup when done:
  ./break-fix-3.1-llm-traffic.sh cleanup
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/3.1/lab)
