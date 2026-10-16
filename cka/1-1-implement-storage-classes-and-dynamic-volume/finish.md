## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCIÓN PASO A PASO (comentada, no se ejecuta)

1) Diagnóstico:

   kubectl get pvc -n cka-1-1-storage-lab
     -> ver que cka-lab-pvc está "Pending"

   kubectl describe pvc cka-lab-pvc -n cka-1-1-storage-lab
     -> en Events aparece el mensaje de espera por un provisioner
        que no existe (example.com/does-not-exist)

   kubectl get storageclass cka-lab-broken-sc -o yaml
     -> confirmar que "provisioner: example.com/does-not-exist"
        es el nombre inventado, no coincide con ningún controller
        real corriendo en el cluster (compará contra el provisioner
        que anotaste al principio del ejercicio, el que devolvió
        detect_working_provisioner, por ejemplo "rancher.io/local-path"
        o "k8s.io/minikube-hostpath" según el cluster).

2) El campo "provisioner" es inmutable, así que no se puede editar
   la StorageClass existente. Hay que borrarla y recrearla con el
   MISMO nombre pero el provisioner correcto:

   kubectl delete storageclass cka-lab-broken-sc

   kubectl apply -f - <<EOF
   apiVersion: storage.k8s.io/v1
   kind: StorageClass
   metadata:
     name: cka-lab-broken-sc
   provisioner: <PROVISIONER_REAL_DETECTADO_EN_EL_PASO_1>
   reclaimPolicy: Delete
   volumeBindingMode: WaitForFirstConsumer
   EOF

   OJO (probado con study-lab en kind, 2026-10-15): copiá también el
   volumeBindingMode de la StorageClass que funciona. local-path
   (kind, k3s) solo provisiona con WaitForFirstConsumer; con Immediate
   el PVC sigue Pending con "configuration error, no node was specified".
   Otros provisioners (CSI, minikube-hostpath) aceptan Immediate.

3) El PVC cka-lab-pvc sigue existiendo, sin modificar, referenciando
   la StorageClass por nombre. Apenas el controller de provisioning
   (kube-controller-manager o el sidecar CSI, según el caso) hace su
   próximo resync, va a ver una StorageClass con un provisioner que
   sí reconoce y va a crear el PersistentVolume dinámicamente:

   kubectl get pvc cka-lab-pvc -n cka-1-1-storage-lab -w
     -> pasa de "Pending" a "Bound" (puede tardar unos segundos)

4) Una vez que el PVC está Bound, el scheduler puede completar el
   montaje del volumen y el Pod arranca solo:

   kubectl get pod cka-lab-writer -n cka-1-1-storage-lab -w
     -> pasa de "Pending" a "Running"

5) Verificación final:

   kubectl exec -n cka-1-1-storage-lab cka-lab-writer -- cat /data/hello.txt
     -> debe imprimir "hello from CKA lab"
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cka/1.1/lab)
