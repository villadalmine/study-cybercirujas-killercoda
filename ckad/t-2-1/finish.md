## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCIÓN PASO A PASO (comentada a propósito: no se ejecuta automáticamente)

1. Confirmar el síntoma:
     kubectl get endpoints webapp-svc -n ckad-2-1-blue-green
     -> ENDPOINTS: <none>

2. Ver el selector roto que quedó en el Service:
     kubectl get service webapp-svc -n ckad-2-1-blue-green -o yaml
     -> spec.selector: { app: webapp, version: green-v2 }

   El valor "green-v2" no existe en ningún pod: ningún pod matchea ese
   selector (superset/typo), por eso el Service queda sin endpoints
   aunque webapp-blue y webapp-green estén Ready.

3. Ver los labels reales de los pods candidatos al cutover:
     kubectl get pods -n ckad-2-1-blue-green --show-labels
     -> pods de webapp-green tienen: app=webapp, version=green

4. Corregir el selector del Service para que apunte a la versión green
   (completando el cutover, no revirtiendo a blue):
     kubectl patch service webapp-svc -n ckad-2-1-blue-green \
       --type merge -p '{"spec":{"selector":{"app":"webapp","version":"green"}}}'

   (Alternativa equivalente con edición interactiva:)
     kubectl edit service webapp-svc -n ckad-2-1-blue-green
     # cambiar spec.selector.version de "green-v2" a "green"

5. Verificar que el Service ahora tiene endpoints y que sirve solo green:
     kubectl get endpoints webapp-svc -n ckad-2-1-blue-green
     kubectl exec -n ckad-2-1-blue-green curl-client -- curl -s http://webapp-svc
     -> RESPONSE_FROM_GREEN (repetido en todos los intentos)

6. (Opcional, buena práctica post-cutover) Una vez confirmado que green
   es estable, escalar a cero o eliminar el Deployment webapp-blue para
   liberar recursos, ya que el Service ya no lo selecciona:
     kubectl scale deployment webapp-blue -n ckad-2-1-blue-green --replicas=0
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckad/2.1/lab)
