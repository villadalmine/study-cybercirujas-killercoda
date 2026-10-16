## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCIÓN PASO A PASO (para el instructor / autocorrección)

cd "$HOME/kcna-lab-4.2-community/cloudnative-widget"

1) Configurar identidad de git (alcanza con local; también sirve
   global si preferís dejarla para el resto de la VM):

     git config user.name  "Estudiante KCNA"
     git config user.email "estudiante@kcna.example"

2) Commitear el cambio ya preparado, firmando DCO (el flag -s
   agrega automáticamente la línea "Signed-off-by: Nombre <email>"
   tomando el nombre/email de la config de git, tal como exige
   CONTRIBUTING.md):

     git commit -s -m "bump version to 1.1.0"

3) Verificar que el hook (el "CI" local que simula el DCO check
   real de los proyectos CNCF) aceptó el commit:

     git log -1 --format='%B'
     # debe mostrar algo como:
     # bump version to 1.1.0
     #
     # Signed-off-by: Estudiante KCNA <estudiante@kcna.example>

4) Confirmar con el propio script:

     ./break-fix-4.2.sh check
     # => PASS: el commit cumple el proceso de contribución del
     #    proyecto (DCO sign-off válido).

Nota conceptual (tema 4.2): esto reproduce en miniatura el flujo
real de contribución a un proyecto CNCF — CONTRIBUTING.md define
el proceso, MAINTAINERS.md documenta quién tiene autoridad de
merge (rol de maintainer dentro de la gobernanza del proyecto), y
el DCO reemplaza a un CLA tradicional como mecanismo liviano para
que la comunidad acepte contribuciones sin fricción legal — un
rasgo característico de cómo CNCF organiza la colaboración open
source entre contribuyentes, maintainers y el TOC.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/kcna/4.2/lab)
