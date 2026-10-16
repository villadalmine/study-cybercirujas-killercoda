## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCION PASO A PASO (leer solo después de intentarlo)

Escenario 1 - kube-scheduler roto:
  1. kubectl get pods -n kube-system | grep scheduler
     -> kube-scheduler-<nodo>  CrashLoopBackOff
  2. kubectl describe pod kube-scheduler-<nodo> -n kube-system
     (o crictl ps -a | grep scheduler / crictl logs <id>)
     -> "exec: kube-scheduler-broken: no such file or directory"
  3. cat /etc/kubernetes/manifests/kube-scheduler.yaml
     -> ver "- kube-scheduler-broken" en vez de "- kube-scheduler"
  4. sed -i 's/kube-scheduler-broken/kube-scheduler/' \
        /etc/kubernetes/manifests/kube-scheduler.yaml
  5. kubelet detecta el cambio en el manifest y recrea el static pod
     solo (30-60s). Confirmar con kubectl get pods -n kube-system y
     creando un pod nuevo para ver que se agenda.

Escenario 2 - etcd inalcanzable:
  1. kubectl get nodes  -> timeout o "connection refused"
  2. crictl ps -a | grep kube-apiserver ; crictl logs <id>
     -> errores conectando a etcd en 127.0.0.1:2379
  3. cat /etc/kubernetes/manifests/etcd.yaml
     -> --listen-client-urls usa :23799 en vez de :2379
  4. sed -i -E '/--listen-client-urls/ s/:23799/:2379/g' \
        /etc/kubernetes/manifests/etcd.yaml
  5. kubelet recrea el pod de etcd; kube-apiserver reconecta solo.
     Confirmar con kubectl get nodes.

Escenario 3 - kubelet no reporta al apiserver:
  1. kubectl get nodes -> el nodo pasa a NotReady
  2. journalctl -u kubelet -n 50 --no-pager
     -> "connection refused" contra el puerto 16443
  3. grep server /etc/kubernetes/kubelet.conf
     -> server: https://<ip>:16443 en vez de :6443
  4. sed -i -E 's/:16443/:6443/' /etc/kubernetes/kubelet.conf
  5. systemctl restart kubelet
  6. Esperar 30-60s y volver a chequear: kubectl get nodes -> Ready
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cka/2.2/lab)
