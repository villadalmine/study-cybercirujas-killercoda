## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
4. Fix resolution — repair the layer that publishes the VIP. In this lab it is
   /etc/hosts; in a real HA cluster it is DNS or keepalived/VRRP:

     $ sed -i '/k8s-api.lab/d' /etc/hosts
     $ echo '10.0.0.11 k8s-api.lab' >> /etc/hosts
     # real cluster, VIP case:  ip -4 addr show; systemctl status keepalived; journalctl -u keepalived

5. Verify, and let the kubelet reattach on its own:

     $ getent hosts k8s-api.lab
     10.0.0.11       k8s-api.lab
     $ kubectl get --raw='/readyz?verbose' | tail -1
     readyz check passed
     $ kubectl get nodes           # NotReady -> Ready within ~40s (node lease)
     $ journalctl -u kubelet -n 20 --no-pager | tail -3

6. HA takeaway. --control-plane-endpoint is set once, at init, and everything
   inherits it: admin.conf, kubelet.conf, controller-manager.conf,
   scheduler.conf, the kubeadm-config ConfigMap and the apiserver cert SANs.
   Changing it later means regenerating certificates
     (kubeadm init phase certs apiserver --apiserver-cert-extra-sans ...)
   and rewriting every kubeconfig in the cluster. Set it even for a single
   control-plane node you might scale later; that one flag is the difference
   between "add a control-plane node" and "rebuild the cluster".
   https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/

EMERGENCY (instructor only): sudo ./ha-break-fix.sh --restore
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/kca/2.5/lab)
