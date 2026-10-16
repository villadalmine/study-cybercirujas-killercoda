## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCION PASO A PASO (referencia para autocorregirte; no hace falta
ejecutar esto para que el lab funcione, es la guia si quedaste trabado)

1) Verificar los tres binarios descargados contra su SHA-256, con el
   mismo mecanismo que documenta upstream para kubectl/kubeadm/kubelet:
   https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/#verify-kubectl-binary

     cd ~/cks-lab/1.5-verify-binaries/incoming
     for f in kubeadm kubelet kubectl; do
       echo "== $f =="
       echo "$(cat "$f.sha256")  $f" | sha256sum --check
     done

   Vas a ver algo como:
     kubeadm: OK
     kubelet: FAILED
     kubectl: OK
   (cual de los tres falla varia entre corridas del lab, es aleatorio)

2) El binario que dio FAILED esta corrompido/manipulado: NO se instala
   tal como esta. En este lab, la "fuente oficial" esta simulada en
   reference/; en un cluster real volverias a descargarlo desde
   dl.k8s.io/release/<version>/bin/linux/amd64/<binario> junto con su
   <binario>.sha256 publicado ahi mismo, y jamas confiarias en el mismo
   mirror sin volver a verificar la nueva copia.

     cp ../reference/kubelet ./kubelet   # sustituir <binario> segun cual haya fallado

3) Volver a verificar TODO antes de instalar (no asumir que porque uno
   se arreglo, el resto sigue bien):

     for f in kubeadm kubelet kubectl; do
       echo "$(cat "$f.sha256")  $f" | sha256sum --check
     done

4) Recien ahi "desplegar" (copiar) los tres binarios ya verificados:

     mkdir -p ../installed
     cp kubeadm kubelet kubectl ../installed/

5) Confirmar la resolucion:

     cd ~/cks-lab/1.5-verify-binaries
     ./break-fix-1.5-verify-binaries.sh grade

Nota de examen: la misma logica aplica a los tarballs completos de
release (checksums SHA-512 publicados en CHANGELOG-<version>.md del
repo kubernetes/kubernetes) y, desde Kubernetes 1.24+, los artefactos
de release tambien tienen firmas cosign/sigstore ademas de los
checksums SHA-256/512.
Fuente: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cks/1.5/lab)
