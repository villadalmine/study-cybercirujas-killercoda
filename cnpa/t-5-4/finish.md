## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — STEP BY STEP  (do not read until you have tried)

 0. Confirm the blast radius. Everything lives in one namespace:

      kubectl -n cnpa-lab-54 get all

 1. See the frozen automation. The rollout never returns:

      kubectl -n cnpa-lab-54 rollout status deploy/sentiment-analyzer-predictor
      # ^C after a few seconds — it says 0 of 1 updated replicas are available

    And the Pods show the tell-tale split: old Ready + new Pending.

      kubectl -n cnpa-lab-54 get pods -l app=sentiment-analyzer -o wide
      # sentiment-analyzer-predictor-<oldrs>-xxxxx   1/1  Running   (serving)
      # sentiment-analyzer-predictor-<newrs>-yyyyy   0/1  Pending   (stuck)

 2. Ask the scheduler WHY the new Pod is unschedulable. The Events are the
    whole story:

      PEND=$(kubectl -n cnpa-lab-54 get pods -l app=sentiment-analyzer \
               --field-selector=status.phase=Pending -o name | head -n1)
      kubectl -n cnpa-lab-54 describe "$PEND"
      # Events:
      #   Warning  FailedScheduling  ...  0/1 nodes are available:
      #     1 Insufficient nvidia.com/gpu,
      #     1 node(s) didn't match Pod's node affinity/selector.

 3. Find the two knobs the golden-path bump added to the Pod template:

      kubectl -n cnpa-lab-54 get deploy sentiment-analyzer-predictor \
        -o jsonpath='{.spec.template.spec.nodeSelector}{"\n"}'
      # {"accelerator":"nvidia-gpu"}

      kubectl -n cnpa-lab-54 get deploy sentiment-analyzer-predictor \
        -o jsonpath='{.spec.template.spec.containers[0].resources.limits}{"\n"}'
      # {"cpu":"500m","memory":"256Mi","nvidia.com/gpu":"1"}

    Prove the platform cannot satisfy it — no node advertises the resource:

      kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" gpu="}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
      # node-0 gpu=          <-- empty: there is no GPU and no device plugin

 4. ROOT CAUSE. Platform automation rendered a workload that demands
    accelerator capacity this cluster does not have. The rollout is correct
    to refuse it — the bug is the template, not the scheduler. On a GPU-less
    lab node the associate-level fix is to reconcile the request with reality:
    drop the GPU limit and the accelerator nodeSelector so the predictor runs
    on CPU.

 5. FIX — remove both fields with a JSON Patch. Note the JSON Pointer escape:
    '/' inside the key "nvidia.com/gpu" is written as '~1'.

      kubectl -n cnpa-lab-54 patch deploy sentiment-analyzer-predictor \
        --type=json -p='[
          {"op":"remove","path":"/spec/template/spec/nodeSelector"},
          {"op":"remove","path":"/spec/template/spec/containers/0/resources/limits/nvidia.com~1gpu"}
        ]'

    (Equivalently, re-apply the clean golden-path template, or
     `kubectl -n cnpa-lab-54 edit deploy sentiment-analyzer-predictor` and
     delete the two blocks by hand.)

 6. Watch the automation unfreeze and finish:

      kubectl -n cnpa-lab-54 rollout status deploy/sentiment-analyzer-predictor
      # deployment "sentiment-analyzer-predictor" successfully rolled out
      kubectl -n cnpa-lab-54 get pods -l app=sentiment-analyzer
      # exactly one Pod, 1/1 Running, no Pending

 7. Confirm the endpoint serves (simulated model predict call):

      kubectl -n cnpa-lab-54 run curl-probe --rm -it --restart=Never \
        --image=curlimages/curl:8.10.1 -- \
        curl -s http://sentiment-analyzer.cnpa-lab-54.svc.cluster.local/ | head

 8. Grade yourself:

      ./break_fix.sh --verify     # expect: PASS

 9. Tear down:

      ./break_fix.sh --cleanup

 PLATFORM-ENGINEERING TAKEAWAY (why 5.4 cares)
 * The correct long-term fix depends on intent. If the model genuinely needs
   a GPU, you make the CAPACITY real instead of removing the request:
       - install the NVIDIA device plugin (DaemonSet) so nodes advertise
         `nvidia.com/gpu`,
       - label GPU nodes: `kubectl label node <n> accelerator=nvidia-gpu`,
       - and usually set `runtimeClassName: nvidia` in the Pod spec.
 * Golden-path templates that hardcode accelerator requirements must be gated
   on real cluster capacity (admission policy / validating the platform can
   schedule what it renders), or every CPU-only environment freezes on the
   next template bump — exactly what you just repaired.
 * `maxUnavailable: 0` is why there was zero downtime: automation protected
   the live revision while the broken one sat Pending. Read your rollout
   strategy before you trust "it deployed."
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpa/5.4/lab)
