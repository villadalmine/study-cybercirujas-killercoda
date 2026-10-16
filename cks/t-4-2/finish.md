## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCIÓN PASO A PASO (comentada - no se ejecuta)

1. Inspeccionar el Constraint:
     kubectl get k8sallowedrepos trusted-registries-only -o yaml
   En spec.enforcementAction vas a ver "dryrun" en vez de "deny". Con
   enforcementAction=dryrun, Gatekeeper evalúa la política y registra las
   violaciones (en status.violations y en los logs del controller), pero
   NO bloquea el request. Por eso el Constraint "parece" activo pero no
   hace nada.

2. Corregir el enforcementAction:
     kubectl patch k8sallowedrepos trusted-registries-only \
       --type merge -p '{"spec":{"enforcementAction":"deny"}}'

3. Esperar unos segundos (5-15s) a que el cache de OPA dentro de
   Gatekeeper resincronice el constraint.

4. Confirmar el fix manualmente:
     kubectl -n cks-supply-chain run t1 --image=docker.io/library/busybox --dry-run=server
     # -> Error from server (Forbidden): admission webhook
     #    "validation.gatekeeper.sh" denied the request: ...

     kubectl -n cks-supply-chain run t2 --image=registry.k8s.io/pause:3.9 --dry-run=server
     # -> pod/t2 created (server dry run)

5. O directamente:
     ./break-fix-4.2.sh check

Por qué esto importa para supply chain security:
  - "docker.io/library/nginx" y "registry.k8s.io/" simulan tu artifact
    repository confiable (podría ser Harbor, ECR o GCR, con imágenes
    escaneadas, firmadas y con SBOM generado en el pipeline de CI/CD, p.ej.
    con syft para el SBOM y cosign para la firma).
  - El Constraint es la última barrera dentro del cluster: aunque el
    pipeline de CI/CD falle o alguien haga kubectl apply a mano, ninguna
    imagen fuera de la lista permitida debería poder correr.
  - enforcementAction=dryrun es útil para probar políticas nuevas sin
    bloquear tráfico real, pero si queda así en producción por error, es
    una falla de supply chain silenciosa: todo parece controlado pero en
    realidad no se está bloqueando nada.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cks/4.2/lab)
