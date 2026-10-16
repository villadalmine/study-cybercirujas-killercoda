## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
--- SOLUTION (not executed) -------------------------------------------------
Measure 1:
  uptime                      load average climbing towards 1.00 on an idle box
  vmstat 1 5                  r >= 1 in every sample, us high, id low
  top -b -n 1 | head -15      report-cache-worker near 100 %CPU
  pstree -p 1 | grep report   its parent is systemd (PID 1)
  p=$(systemctl show -p MainPID --value report-cache.service); kill $p; sleep 3
  systemctl show -p MainPID --value report-cache.service   it is back, new PID
  systemctl status report-cache.service                 Restart=always
Fix 1:
  systemctl disable --now report-cache.service
Measure 2:
  df -h /var/tmp ; du -sh /var/tmp   df counts about 64 MiB more than du finds
  lsof +L1                           spool-flusher holds flush.dat (deleted)
Fix 2:
  kill <pid of spool-flusher>        the space is freed when the last fd closes
Check:
  study-lab check lpic-2 200.1
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-2/200.1/lab)
