## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCIÓN PASO A PASO (para el instructor / autocorrección)

1. Confirmar el síntoma y descartar que sea un problema de la
   RuntimeClass en sí (el objeto de Kubernetes está bien):

     kubectl get runtimeclass gvisor -o yaml
     kubectl describe pod -n tenant-a -l app=sandboxed-app
     # -> Warning FailedCreatePodSandBox: failed to find runtime
     #    handler "runsc" from runtime list

2. Confirmar que el problema está en containerd, no en kubelet:

     journalctl -u containerd -n 50 --no-pager
     grep -A3 'containerd.runtimes.runsc' /etc/containerd/config.toml
     # -> no aparece nada: el bloque fue borrado por do_break()

3. Restaurar el bloque de configuración del runtime handler
   "runsc" en /etc/containerd/config.toml:

     cat >> /etc/containerd/config.toml <<-EOF

     [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
       runtime_type = "io.containerd.runc.v2"
       [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc.options]
         BinaryName = "/usr/bin/runc"
     EOF

   (En un cluster real con gVisor instalado, BinaryName apuntaría
   a "/usr/local/bin/runsc" en lugar de "/usr/bin/runc".)

4. Reiniciar containerd para que tome la nueva configuración:

     systemctl restart containerd

5. Forzar que el Deployment reintente crear el pod (o esperar
   al backoff automático) y confirmar que queda Running:

     kubectl -n tenant-a rollout restart deployment/sandboxed-app
     kubectl get pods -n tenant-a -w

6. Confirmar aislamiento: el pod corre bajo runtimeClassName=gvisor,
   es decir que cualquier carga de este tenant queda forzada a pasar
   por ese runtime handler (en producción, con gVisor real, eso
   significa syscalls interceptadas por el sentry de gVisor en vez
   de ir directo al kernel del host - aislamiento extra sobre el que
   ya da el Namespace del tenant).

     sudo ./breakfix-2.3-isolation.sh check
     # -> ÉXITO: el pod de tenant-a está Running con runtimeClassName=gvisor
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cks/2.3/lab)
