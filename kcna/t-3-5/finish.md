## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCIÓN PASO A PASO (para el instructor / autocorrección)

1. Diagnosticar dónde falla el request:
     kubectl logs -n kcna-security-lab rbac-probe --tail=20
   Se ve HTTP 403 con reason "Forbidden": el token es válido
   (si no lo fuera, sería 401/Unauthorized), así que el problema
   es de AUTHORIZATION, no de autenticación ni de admission control.

2. Inspeccionar el Role y confirmar que falta el verbo 'list':
     kubectl get role log-reader-role -n kcna-security-lab -o yaml
   Se ve: verbs: ["get"]  (debería incluir también "list").

3. Confirmar que el RoleBinding y el ServiceAccount están intactos
   (el break no los toca, no hace falta arreglarlos):
     kubectl get rolebinding log-reader-binding -n kcna-security-lab -o yaml
     kubectl get sa log-reader -n kcna-security-lab

4. Reparar el Role agregando el verbo 'list':
     kubectl patch role log-reader-role -n kcna-security-lab \
       --type=json -p='[{"op":"replace","path":"/rules/0/verbs","value":["get","list"]}]'

   (equivalente con kubectl edit:
     kubectl edit role log-reader-role -n kcna-security-lab
     # y cambiar verbs: ["get"] por verbs: ["get", "list"])

5. Verificar la corrección:
     kubectl logs -n kcna-security-lab -f rbac-probe
   o directamente:
     ./break-fix-3.5-security.sh verify
   Ambos deberían mostrar HTTP 200 y el JSON con la lista de pods.

6. Limpiar el laboratorio cuando termines:
     ./break-fix-3.5-security.sh cleanup
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/kcna/3.5/lab)
