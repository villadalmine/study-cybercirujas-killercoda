## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION — spoilers below. Attempt the fix yourself first.

STEP 1 — Confirm the symptom is drift that is NOT being corrected.

  $ kubectl --context kind-cgoa-lab -n podinfo get pods
  NAME                       READY   STATUS             RESTARTS   AGE
  podinfo-6f9d5f7b9c-k2m8p   1/1     Running            0          12m
  podinfo-7c8b9d5db4-qx4jt   0/1     ImagePullBackOff   0          4m

  ImagePullBackOff on a tag nobody published. In a healthy GitOps setup this
  would self-revert within one reconciliation interval (spec.interval: 30s).
  It has not. So the question is not "what is wrong with the pod" — it is
  "why is the reconciler not reconciling".

STEP 2 — Interrogate the reconciler, not the workload.

  $ flux --context kind-cgoa-lab get kustomizations
  NAME     REVISION             SUSPENDED   READY   MESSAGE
  podinfo  master@sha1:a1b2c3d  True        True    Applied revision: master@sha1:a1b2c3d

  SUSPENDED=True. Mechanically, spec.suspend=true tells kustomize-controller
  to skip this object entirely in its reconcile loop — no pulls are acted on,
  no server-side apply, no drift detection, no pruning. The cluster is
  unmanaged while looking managed. Confirm at the API level:

  $ kubectl --context kind-cgoa-lab -n flux-system \
      get kustomization podinfo -o jsonpath='{.spec.suspend}{"\n"}'
  true

STEP 3 — Resume the reconciler. Do NOT touch the Deployment.

  $ flux --context kind-cgoa-lab resume kustomization podinfo
  ► resuming kustomization podinfo in flux-system namespace
  ✔ kustomization resumed
  ◎ waiting for Kustomization reconciliation
  ✔ applied revision master@sha1:a1b2c3d

  'flux resume' both clears spec.suspend and triggers an immediate
  reconciliation. The declarative equivalent is:
    kubectl -n flux-system patch kustomization podinfo \
      --type merge -p '{"spec":{"suspend":false}}'
  ...which waits up to one interval (30s), or force it right away with:
    flux reconcile kustomization podinfo --with-source

STEP 4 — Watch the loop heal the drift.

  $ kubectl --context kind-cgoa-lab -n podinfo get pods -w
  podinfo-7c8b9d5db4-qx4jt   0/1   Terminating   0   6m    <- broken "hotfix" RS scaled down
  podinfo-6f9d5f7b9c-w9z2v   1/1   Running       0   5s    <- Git-declared spec restored

  WHY this works: kustomize-controller applies manifests with Kubernetes
  Server-Side Apply and takes ownership of the fields it manages, forcing
  conflict resolution in its favor. 'kubectl set image' had stolen ownership
  of .spec.template.spec.containers[0].image; on resume, the controller
  re-applies the Git-declared value and reclaims the field. Manual drift
  loses to declared state — by design, every 30 seconds, forever.
  (SSA field ownership: kubernetes.io/docs/reference/using-api/server-side-apply/
   drift correction: fluxcd.io/flux/components/kustomize/kustomizations/)

STEP 5 — Prove it.

  $ ./gitops-fundamentals-breakfix.sh verify
  [ ok] Kustomization is not suspended (pull + reconcile loop restored)
  [ ok] Kustomization Ready=True (last reconciliation applied cleanly)
  [ ok] Deployment image is ghcr.io/stefanprodan/podinfo:6.x.y (matches the Git-declared image captured at break time)
  [ ok] rollout complete, all replicas Ready
  *** FIXED. ***

THE ANTI-SOLUTION (what NOT to do, and why verify rejects it):
  'kubectl set image' back to the good tag makes the pods green in seconds —
  and fixes nothing. The reconciler is still suspended, so the cluster is
  still unmanaged: the next bad hand-edit also sticks, prune is off, and Git
  no longer predicts production. You would have treated the symptom (a pod)
  and preserved the disease (a broken control loop). Suspend is a legitimate,
  auditable tool for planned maintenance windows — the failure here was
  combining it with imperative mutation and forgetting to resume.

EXAM MAPPING (CGOA · GitOps Principles, 25% of the exam):
  Principle 1 (declarative)  — the Kustomization + Git manifests, not scripts
  Principle 2 (versioned)    — master@sha1:... is an immutable, auditable ref
  Principle 3 (pulled)       — source-controller fetched Git; nothing pushed
  Principle 4 (reconciled)   — the drift revert you watched in STEP 4
  https://opengitops.dev/  ·  github.com/open-gitops/documents/blob/v1.0.0/PRINCIPLES.md
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cgoa/1.1/lab)
