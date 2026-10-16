## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 REFERENCE SOLUTION — step by step  (read only after you have tried)

 Root cause
 Each Pod requests cpu=64 and memory=256Gi. The scheduler's Filtering stage
 checks every node's *allocatable* capacity (node total minus system/kubelet
 reservations minus already-requested amounts). No lab node can satisfy a
 64-core / 256Gi request, so ALL nodes are filtered out, zero feasible nodes
 remain, and the Pod is parked in Pending with a FailedScheduling event.
 Note: `requests` — not `limits` — drive placement. Limits cap runtime usage;
 requests are what the scheduler "selects" a node against.

 Step 1 — Confirm the symptom
   kubectl -n kca-lab-4-2 get pods
     -> all replicas STATUS=Pending, READY 0/1

 Step 2 — Read WHY the scheduler refused
   kubectl -n kca-lab-4-2 describe pod <pod-name> | sed -n '/Events:/,$p'
     -> Warning FailedScheduling ... "Insufficient cpu, Insufficient memory"
   The message names the exact resource dimension(s) that failed Filtering.

 Step 3 — Compare the ASK vs the OFFER
   # What the Pod asks for:
   kubectl -n kca-lab-4-2 get deploy resource-selection-demo \
     -o jsonpath='{.spec.template.spec.containers[0].resources.requests}{"\n"}'
     -> {"cpu":"64","memory":"256Gi"}
   # What the nodes can offer:
   kubectl get nodes -o custom-columns=\
NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory
     -> e.g. cpu: 2 , memory: ~4Gi   (64 >> 2, 256Gi >> 4Gi -> impossible)

 Step 4 — Fix the resource selection (lower the request to fit the node)
   kubectl -n kca-lab-4-2 set resources deployment/resource-selection-demo \
     --requests=cpu=100m,memory=64Mi --limits=cpu=100m,memory=64Mi
   # Equivalent alternatives:
   #   kubectl -n kca-lab-4-2 edit deployment resource-selection-demo
   #   kubectl -n kca-lab-4-2 patch deployment resource-selection-demo --type=json \
   #     -p='[{"op":"replace",
   #          "path":"/spec/template/spec/containers/0/resources/requests/cpu",
   #          "value":"100m"}]'
   Changing the Pod template triggers a new ReplicaSet rollout automatically.

 Step 5 — Watch the scheduler now find a feasible node
   kubectl -n kca-lab-4-2 rollout status deployment/resource-selection-demo
   kubectl -n kca-lab-4-2 get pods
     -> all replicas STATUS=Running, READY 1/1

 Step 6 — (Real-world alternative) If the request were legitimate, you would
   ADD CAPACITY instead of shrinking the ask: scale the node pool, or free a
   node by evicting lower-priority Pods (PriorityClass + preemption). In this
   lab we shrink the request because the ask was artificial.

 Step 7 — Prove it and clean up
   ./4.2-resource-selection.sh verify   # expect PASS
   ./4.2-resource-selection.sh clean    # kubectl delete namespace kca-lab-4-2

 Takeaways for the exam
   - Pending + FailedScheduling == a Filtering failure; read the Event message.
   - `requests` select the node; `limits` cap runtime. Only requests schedule.
   - "Insufficient cpu/memory" means ask > allocatable across all nodes.
   - Fix by lowering requests OR adding/free­ing node capacity — never by
     editing kubelet flags on the host.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/kca/4.2/lab)
