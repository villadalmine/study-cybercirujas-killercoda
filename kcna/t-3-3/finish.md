## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCIÓN (spoiler) - paso a paso

1. Diagnóstico:
     docker run --rm hello-world
   El daemon responde y llega hasta "failed to create shim task: OCI
   runtime create failed: runc: runc not installed". Eso indica que
   containerd encontró la imagen y armó el "shim", pero no pudo invocar
   al OCI runtime (runc) para crear el contenedor real (namespaces +
   cgroups).

2. Confirmar que el daemon en sí está sano:
     systemctl status docker
     docker info
   (el daemon arranca bien; el problema es específico de runc, no del
   engine completo)

3. Confirmar que runc no está donde se lo espera:
     command -v runc          # no devuelve nada
     ls /usr/bin/runc*        # aparece "runc.disabled-by-kcna-3.3-containerization"

4. Arreglo (sin reinstalar Docker entero):
     sudo mv /usr/bin/runc.disabled-by-kcna-3.3-containerization /usr/bin/runc
     sudo chmod +x /usr/bin/runc

   (En un caso real, si el binario se hubiese perdido de verdad, la
   alternativa es reinstalar el paquete que lo provee, por ejemplo:
     sudo apt-get install --reinstall runc
   o el paquete containerd.io, según la distro.)

5. Verificar:
     docker run --rm hello-world
   Debería completar OK, mostrando el mensaje "Hello from Docker!".

6. Concepto clave para el examen (dominio 3.3 Containerization):
   un container engine como Docker no crea contenedores por sí mismo:
   delega en un OCI runtime (runc por defecto, aunque también existen
   gVisor, Kata Containers, crun, etc.) que es quien efectivamente usa
   namespaces y cgroups del kernel de Linux para aislar procesos,
   siguiendo el OCI Runtime Specification. containerd actúa como
   intermediario ("high-level runtime") entre el CLI/daemon y ese
   OCI runtime.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/kcna/3.3/lab)
