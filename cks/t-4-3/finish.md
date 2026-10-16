## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCION PASO A PASO (no la leas hasta intentar resolverlo vos)

1. Confirmar que la ValidatingAdmissionPolicy sigue existiendo:
     kubectl get validatingadmissionpolicy cks-allowed-registries

2. Inspeccionar el Binding, que es lo que conecta la policy con
   los recursos reales y define que pasa cuando se viola:
     kubectl get validatingadmissionpolicybinding \
       cks-allowed-registries-binding -o yaml

   Vas a ver:
     spec:
       validationActions:
       - Audit

   "Audit" solo deja un registro en el audit log del API server,
   NO bloquea la request. Por eso los pods con imagenes de
   registries no autorizados se siguen creando: la politica se
   evalua, pero su resultado no tiene efecto en la admision.

3. Corregir el modo de enforcement a "Deny":
     kubectl patch validatingadmissionpolicybinding \
       cks-allowed-registries-binding \
       --type=merge -p '{"spec":{"validationActions":["Deny"]}}'

4. Verificar que ahora si bloquea:
     kubectl run test-bad --image=docker.io/library/nginx \
       -n supplychain-lab --restart=Never
     # -> Error from server: ... ValidatingAdmissionPolicy
     #    'cks-allowed-registries' ... denied request:
     #    Imagen rechazada: solo se permiten imagenes de
     #    registry.k8s.io/ o registry.internal.lab/

5. Verificar que las imagenes permitidas siguen funcionando:
     kubectl run test-good --image=registry.k8s.io/pause:3.9 \
       -n supplychain-lab --restart=Never
     # -> pod/test-good created
     kubectl delete pod test-good -n supplychain-lab

6. (Extension del tema "sign and validate artifacts")
   En un cluster real esta misma logica de "solo estos registries"
   se combina con verificacion de firmas sigstore/cosign (por
   ejemplo con Kyverno verifyImages o Connaisseur), para asegurar
   no solo DE DONDE viene la imagen sino que nadie la modifico
   despues de que el equipo la firmo:
     cosign verify --key cosign.pub registry.k8s.io/mi-imagen:tag

7. Terminado el lab, limpiar todo:
     ./break-fix-4.3-supply-chain.sh clean
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cks/4.3/lab)
