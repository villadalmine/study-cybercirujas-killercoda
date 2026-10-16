## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCION PASO A PASO (comentada - no se ejecuta)

1. Mirar el Dockerfile roto:
     cat $LAB_DIR/Dockerfile

   Vas a ver algo como:
     FROM alpine:3.19 AS builder
     WORKDIR /src
     COPY greet.sh .
     RUN chmod +x greet.sh

     FROM alpine:3.19
     COPY --from=builder /src/greet.sh /usr/local/bin/greeting.sh
     ENV BUILD_ID=42
     ENTRYPOINT ["/usr/local/bin/greet.sh"]

2. Diagnóstico: el build de una imagen multi-stage NO valida que los paths
   entre stages/instrucciones sean consistentes entre sí. El COPY --from=builder
   deja el archivo en /usr/local/bin/greeting.sh (con "ing"), pero el
   ENTRYPOINT intenta ejecutar /usr/local/bin/greet.sh, que no existe en la
   imagen final. Por eso el build es exitoso pero el runtime falla.

3. Confirmarlo corriendo el contenedor con el ENTRYPOINT reemplazado por un
   shell, para inspeccionar el filesystem de la imagen final:
     docker run --rm --entrypoint sh ckad-1-1-lab:lab -c "ls -la /usr/local/bin"
   Esto muestra "greeting.sh" en vez de "greet.sh", confirmando el desajuste.

4. Arreglar el Dockerfile haciendo que ambos paths coincidan. Cualquiera de
   las dos opciones es una solución válida:
     a) Corregir el destino del COPY para que coincida con el ENTRYPOINT:
          COPY --from=builder /src/greet.sh /usr/local/bin/greet.sh
     b) O corregir el ENTRYPOINT para que apunte al nombre real copiado:
          ENTRYPOINT ["/usr/local/bin/greeting.sh"]

5. Reconstruir la imagen:
     docker build -t ckad-1-1-lab:lab $LAB_DIR

6. Correr el contenedor y confirmar el mensaje esperado:
     docker run --rm ckad-1-1-lab:lab
     -> "Hello from the CKAD image lab, build number: 42"

7. Validar automáticamente:
     ./ckad-1.1-break-fix.sh check
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckad/1.1/lab)
