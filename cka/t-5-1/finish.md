## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCIÓN (paso a paso) - no ejecutar hasta intentar resolverlo solo

1. Confirmar que ambos Pods están Running/Ready y que no es un problema
   de scheduling ni de crash del container:
     kubectl get pods -n cka-5-1-connectivity -o wide

2. Reproducir el síntoma exacto y confirmar que el problema es a nivel
   de red, no de la app:
     kubectl exec -n cka-5-1-connectivity pod-a -- ping -c 3 <IP de pod-b>
     -> 100% packet loss

3. Descartar NetworkPolicy (tema 5.2, no 5.1):
     kubectl get networkpolicy -n cka-5-1-connectivity
     -> No resources found

4. Descartar Service/kube-proxy (tema 5.4): se está probando la IP del
   Pod directamente, no un ClusterIP, así que kube-proxy no interviene.

5. El tráfico Pod-to-Pod pasa por el host antes de llegar a la interfaz
   del Pod destino (bridge/overlay del CNI + chain FORWARD de iptables
   en el nodo, con net.bridge.bridge-nf-call-iptables habilitado como
   requiere Kubernetes). Inspeccionar las reglas del nodo:
     iptables -S FORWARD
     iptables -L FORWARD -n --line-numbers

6. Va a aparecer una regla DROP identificable por su comentario, por
   ejemplo:
     -A FORWARD -s <IP pod-a> -d <IP pod-b> -m comment --comment "cka-5-1-lab-break" -j DROP
     -A FORWARD -s <IP pod-b> -d <IP pod-a> -m comment --comment "cka-5-1-lab-break" -j DROP

7. Eliminar ambas reglas (dirección ida y vuelta), usando el mismo
   match spec que la inserción original:
     iptables -D FORWARD -s <IP pod-a> -d <IP pod-b> -m comment --comment "cka-5-1-lab-break" -j DROP
     iptables -D FORWARD -s <IP pod-b> -d <IP pod-a> -m comment --comment "cka-5-1-lab-break" -j DROP

   (alternativa: borrar por número de línea con
    "iptables -D FORWARD <línea>", empezando por la línea más alta para
    que no se corran los índices).

8. Verificar que la conectividad volvió:
     kubectl exec -n cka-5-1-connectivity pod-a -- ping -c 3 <IP de pod-b>
     -> 0% packet loss

9. Limpiar el laboratorio cuando termines:
     sudo ./5.1-connectivity.sh clean
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cka/5.1/lab)
