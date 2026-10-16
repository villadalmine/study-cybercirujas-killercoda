In the namespace `cka-1-1-storage-lab`, the PVC `cka-lab-pvc` stays **Pending**, so the pod using it never starts.

Find out why and fix it, so the PVC becomes **Bound** and the pod runs.

<details><summary>Hint 1</summary>

`kubectl describe pvc -n cka-1-1-storage-lab cka-lab-pvc`: which provisioner is it waiting for?
</details>

<details><summary>Hint 2</summary>

Compare it with the default StorageClass: `kubectl get storageclass`. The `provisioner` field is immutable,
so delete the StorageClass and recreate it with the same name. Copy its `volumeBindingMode` as well.
</details>

Then press **Check**.
