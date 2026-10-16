## Fix it

When you think it is solved, press **Check**.

<details><summary>Hint 1</summary>

kubectl describe pvc -n cka-1-1-storage-lab cka-lab-pvc — ¿qué provisioner está esperando?

</details>

<details><summary>Hint 2</summary>

Compará con el provisioner de la StorageClass por defecto (kubectl get storageclass).

</details>

<details><summary>Hint 3</summary>

El campo provisioner es inmutable — borrá la StorageClass y recreala con el mismo nombre.

</details>

<details><summary>Hint 4</summary>

Copiá también el volumeBindingMode de la que funciona (local-path solo provisiona con WaitForFirstConsumer).

</details>
