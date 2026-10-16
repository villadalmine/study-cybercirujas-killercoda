## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCIÓN PASO A PASO (comentada - no se ejecuta)

1) Sacar la exposición externa: cambiar el Service a ClusterIP.
   (NodePort/LoadBalancer solo deben usarse cuando el servicio
   realmente necesita ser alcanzable desde fuera del cluster)

  kubectl -n cks-53-lab patch svc internal-api-svc \
    -p '{"spec":{"type":"ClusterIP"},"$deleteFromPrimitiveList/ports":[]}' 2>/dev/null || true

  # más simple y confiable: reemplazar el Service entero
  kubectl -n cks-53-lab apply -f - <<'EOF2'
  apiVersion: v1
  kind: Service
  metadata:
    name: internal-api-svc
  spec:
    type: ClusterIP
    selector:
      app: internal-api
    ports:
      - port: 80
        targetPort: 80
  EOF2

2) Aplicar default-deny de ingress a todo el namespace, y después
   una policy puntual que habilite solo el tráfico legítimo.
   El default-deny es clave: sin un podSelector: {} que cubra todo
   el namespace, cualquier pod nuevo nace con acceso irrestricto.

  kubectl -n cks-53-lab apply -f - <<'EOF2'
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: default-deny-ingress
  spec:
    podSelector: {}
    policyTypes:
      - Ingress
  ---
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: allow-frontend-to-internal-api
  spec:
    podSelector:
      matchLabels:
        app: internal-api
    policyTypes:
      - Ingress
    ingress:
      - from:
          - podSelector:
              matchLabels:
                app: frontend-client
        ports:
          - protocol: TCP
            port: 80
  EOF2

3) Verificar:

  kubectl -n cks-53-lab exec attacker -- curl -m 5 http://internal-api-svc/
    -> debe fallar (timeout, el default-deny bloquea el ingress)

  kubectl -n cks-53-lab exec frontend-client -- curl -m 5 http://internal-api-svc/
    -> debe responder 200 (matchea el podSelector de la policy)

  kubectl -n cks-53-lab get svc internal-api-svc -o jsonpath='{.spec.type}'
    -> debe imprimir "ClusterIP"

Notas conceptuales para el estudiante:
  - El CNI del cluster tiene que soportar NetworkPolicy (Calico, Cilium,
    Weave Net, etc.). El CNI "bridge" por default de algunos kind/minikube
    puede no aplicarlas: si 'verify' sigue fallando después de aplicar
    todo esto, comprobar el CNI antes de sospechar de la policy.
  - "Minimize external access to the network" no es solo NetworkPolicy:
    también incluye no exponer Services más allá de lo necesario
    (NodePort/LoadBalancer solo si hace falta), restringir el rango de
    IPs que puede hablarle al API server, y bloquear egress hacia
    endpoints sensibles como el metadata service de la nube
    (169.254.169.254) para mitigar SSRF.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cks/5.3/lab)
