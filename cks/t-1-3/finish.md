## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCION PASO A PASO (comentada - no se ejecuta)

1) Diagnosticar: inspeccionar el Secret que el Ingress referencia.
     kubectl -n cks-1-3-ingress-tls-lab get secret secure-cks-tls -o yaml
   Vas a ver:
     type: Opaque
     data:
       certificate.pem: ...
       private.key: ...
   Eso confirma el problema: para que un Ingress sirva TLS, Kubernetes
   espera un Secret type=kubernetes.io/tls cuyas keys de "data" se
   llamen EXACTAMENTE "tls.crt" y "tls.key" (referencia: doc de Ingress
   TLS de Kubernetes y guia de TLS de ingress-nginx citadas arriba).
   Como esos nombres no coinciden, el Ingress controller no puede
   armar el keypair y cae al certificado default/fake.

2) Confirmar tambien el sintoma en runtime (opcional, ya lo hace "verify"):
     kubectl -n <ns-del-controller> port-forward svc/<svc-del-controller> 18443:443 &
     curl -kv --resolve secure.cks.local:18443:127.0.0.1 \
       https://secure.cks.local:18443/ 2>&1 | grep -iE "subject:|issuer:"
   El "subject:" va a mostrar el certificado fake del controller, no
   CN=secure.cks.local.

3) Arreglar: recrear el Secret con el nombre y las keys correctas.
   Los archivos de certificado/clave ya generados por "setup" siguen
   en /tmp/cks-1-3-ingress-tls-lab-certs/ (tls.crt, tls.key):

     kubectl -n cks-1-3-ingress-tls-lab delete secret secure-cks-tls

     kubectl -n cks-1-3-ingress-tls-lab create secret tls secure-cks-tls \
       --cert=/tmp/cks-1-3-ingress-tls-lab-certs/tls.crt \
       --key=/tmp/cks-1-3-ingress-tls-lab-certs/tls.key

   "kubectl create secret tls" arma automaticamente type=kubernetes.io/tls
   con las keys tls.crt/tls.key, que es exactamente lo que faltaba. No
   hace falta tocar el objeto Ingress: el spec.tls[].secretName ya
   apuntaba al nombre correcto, el problema era pura y exclusivamente
   la forma del Secret.

4) Confirmar el fix:
     kubectl -n cks-1-3-ingress-tls-lab get secret secure-cks-tls -o jsonpath='{.type}{"\n"}'
     # esperado: kubernetes.io/tls

     ./cks-1.3-ingress-tls.sh verify
     # esperado: "RESULTADO: ARREGLADO."

5) Nota para el examen: el mismo sintoma (certificado fake/default
   servido por el Ingress controller) tambien aparece si el Secret
   esta en el namespace equivocado (Secret e Ingress deben vivir en
   el mismo namespace) o si spec.tls[].secretName tiene un typo. Ante
   "el Ingress tiene TLS configurado pero el navegador/curl no ve mi
   certificado", el orden de chequeo recomendado es: namespace del
   Secret -> nombre del Secret -> type del Secret -> nombres de key
   dentro de "data".
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cks/1.3/lab)
