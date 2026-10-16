## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
===== SOLUTION (step-by-step) ================================================

ROOT CAUSE
  The PVC 'payments-data' is bound (by name) to StorageClass 'cnpe-fast-ssd',
  whose provisioner is 'kubernetes.io/no-provisioner'. That provisioner does
  NOT create volumes dynamically — it only binds PVCs to PersistentVolumes an
  administrator has already created statically. No such PV exists, so the PVC
  can never be satisfied. Because volumeBindingMode is WaitForFirstConsumer,
  the PVC sits Pending ("waiting for first consumer to be created before
  binding") until the Pod is scheduled, and then STILL never binds — so the
  Pod is stuck Pending forever. The application is innocent; the storage
  architecture is the fault.

DIAGNOSIS (what a platform engineer runs)
  1. See the stuck workload and its claim:
       kubectl -n cnpe-lab-1-1 get pods,pvc
  2. Read the claim's events — this is where the truth is:
       kubectl -n cnpe-lab-1-1 describe pvc payments-data
     -> "waiting for first consumer..." then no binding = no provisioner.
  3. Inspect the StorageClass the claim points at:
       kubectl get storageclass cnpe-fast-ssd -o yaml
     -> provisioner: kubernetes.io/no-provisioner   (the smoking gun)
  4. Confirm the Pod is blocked purely on the volume:
       kubectl -n cnpe-lab-1-1 describe pod -l app=payments
  5. Find a StorageClass that DOES provision dynamically:
       kubectl get storageclass
     (the one annotated storageclass.kubernetes.io/is-default-class="true")

FIX A — RECOMMENDED (best practice): repoint the claim at a dynamic class.
  A PVC's spec.storageClassName is IMMUTABLE, so you must delete and recreate
  the claim. The PVC is guarded by the pvc-protection finalizer while a Pod
  references it, so scale the workload down first, then back up.

  # Discover the default/dynamic class name (k3s: local-path, minikube/kind: standard)
  SC="$(kubectl get storageclass -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' | awk -F"\t" '$2=="true"{print $1; exit}')"
  echo "Using dynamic StorageClass: ${SC:?no default StorageClass found — use FIX B}"

  kubectl -n cnpe-lab-1-1 scale deploy/payments --replicas=0
  kubectl -n cnpe-lab-1-1 delete pvc payments-data
  cat <<EOF | kubectl apply -f -
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: payments-data
    namespace: cnpe-lab-1-1
    labels:
      app.kubernetes.io/part-of: cnpe-lab-1-1
  spec:
    accessModes: ["ReadWriteOnce"]
    storageClassName: ${SC}
    resources:
      requests:
        storage: 1Gi
  EOF
  kubectl -n cnpe-lab-1-1 scale deploy/payments --replicas=1

  # The default class provisions a volume, the PVC binds, the Pod runs.
  kubectl -n cnpe-lab-1-1 get pvc,pods -w

FIX B — STATIC PROVISIONING: honor the existing class by supplying a PV.
  Works on ANY single-node cluster, even one with no default class, because it
  gives 'kubernetes.io/no-provisioner' exactly what it expects: a pre-created
  PersistentVolume in the same StorageClass. WaitForFirstConsumer then binds it
  as soon as the Pod is scheduled. (hostPath is fine for a disposable lab node;
  in production you would use a real local/CSI volume with nodeAffinity.)

  cat <<EOF | kubectl apply -f -
  apiVersion: v1
  kind: PersistentVolume
  metadata:
    name: cnpe-payments-pv
    labels:
      app.kubernetes.io/part-of: cnpe-lab-1-1
  spec:
    capacity:
      storage: 1Gi
    accessModes: ["ReadWriteOnce"]
    persistentVolumeReclaimPolicy: Delete
    storageClassName: cnpe-fast-ssd
    hostPath:
      path: /tmp/cnpe-payments-data
      type: DirectoryOrCreate
  EOF

  # No delete/recreate needed — the existing Pending PVC binds to this PV.
  kubectl -n cnpe-lab-1-1 get pvc,pods -w

VERIFY
  ./break_fix.sh verify
  Expect: PVC Bound, Deployment 1/1, Service endpoint present.

CLEANUP
  ./break_fix.sh cleanup

PLATFORM-ARCHITECTURE TAKEAWAYS (topic 1.1)
  - Provisioner choice is an architecture decision: 'no-provisioner' means the
    platform team owns PV lifecycle manually; a CSI/dynamic class means the
    platform provisions on demand. Never ship a workload against a static class
    without also shipping (or automating) the backing PVs.
  - WaitForFirstConsumer defers binding to scheduling time so the volume lands
    in the right topology (zone/node) as the Pod — powerful, but it also DELAYS
    when a misconfiguration surfaces from "apply time" to "first Pod schedule".
  - storageClassName is immutable; treat a PVC's class as a day-0 contract.
  - A default StorageClass is a platform guarantee: claims that omit a class
    should Just Work. A cluster with none is a deliberate (and testable) choice.
  Refs: https://kubernetes.io/docs/concepts/storage/storage-classes/
        https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/
        https://kubernetes.io/docs/concepts/storage/persistent-volumes/
===== END SOLUTION ===========================================================
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cnpe/1.1/lab)
