## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUCIÓN PASO A PASO (¡NO LEER hasta intentarlo!)

Paso 1 — Confirmar el síntoma:
  $ ping -c 2 app.lab
  $ getent hosts app.lab
  Vemos que app.lab resuelve a 203.0.113.99, una IP que no responde.

Paso 2 — Buscar rastros en el logging del sistema (tema 4.3):
  $ journalctl -t lab43
  (en sistemas con syslog clásico: grep lab43 /var/log/syslog
   o grep lab43 /var/log/messages)
  El mensaje dice que se tocó un archivo de configuración en /etc
  relacionado con resolución de nombres.

Paso 3 — Recordar dónde se guarda la configuración:
  En Linux, la configuración del sistema vive en /etc como archivos de
  texto plano. La resolución de nombres LOCAL se define en /etc/hosts
  (formato: IP  nombre). El orden de consulta (hosts primero, DNS
  después) lo controla /etc/nsswitch.conf.

Paso 4 — Inspeccionar el archivo:
  $ cat /etc/hosts
  Al final aparece la línea agregada por el "mantenimiento":
      # entrada agregada por mantenimiento (lab43)
      203.0.113.99   app.lab

Paso 5 — Corregir con un editor de texto (como root):
  $ sudo nano /etc/hosts        # o vi /etc/hosts
  Cambiar la línea rota para que quede:
      127.0.0.1   app.lab
  (Alternativa en una sola línea, si preferís sed:
   $ sudo sed -i 's/^203\.0\.113\.99[[:space:]]\+app\.lab/127.0.0.1   app.lab/' /etc/hosts )

Paso 6 — Verificar la reparación:
  $ getent hosts app.lab        -> 127.0.0.1  app.lab
  $ ping -c 2 app.lab           -> responde
  $ sudo ./lab43-break-fix.sh check   -> ¡LABORATORIO RESUELTO!

Repaso de conceptos del tema 4.3 que usaste:
  - /etc          : configuración del sistema en texto plano (/etc/hosts).
  - journalctl    : consulta del systemd journal; logger escribe en él.
  - /var/log      : logs tradicionales (syslog, messages, dmesg, etc.).
  - dmesg         : mensajes del ring buffer del kernel (hardware, boot).
  - /proc y /sys  : pseudo-filesystems con datos del kernel en vivo
                    (procesos por PID, /proc/cpuinfo, /proc/meminfo).

Fuente de referencia:
  https://learning.lpi.org/en/learning-materials/010-160/4/4.3/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpi-010-160/4.3/lab)
