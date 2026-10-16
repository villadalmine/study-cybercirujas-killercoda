## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION -- step by step (do not read until you have tried it yourself)

 Root cause: /etc/keepalived/keepalived.conf tracks a vrrp_script whose
 command is 'pgrep -x haproxyd'. The real process is named 'haproxy' (no
 trailing 'd'), so the check ALWAYS exits 1. Because the script has no
 'weight', two consecutive failures ('fall 2') push vrrp_instance VI_1 into
 FAULT, and keepalived withdraws the VIP. HAProxy never failed -- the monitor
 lied about it.

 --- 1. Confirm the VIP is gone but nothing actually crashed --------------
    ip -4 addr show dev "$IFACE"          # the VIP is NOT listed
    systemctl is-active haproxy           # -> active
    pgrep -x haproxy                      # -> real PID(s): HAProxy is fine
    ss -ltnp | grep ':80'                 # HAProxy is still listening

 --- 2. Ask keepalived WHY it dropped the VIP -----------------------------
    journalctl -u keepalived -n 30 --no-pager
      Expected:
        VRRP_Script(chk_haproxy) failed (exited with status 1)
        (VI_1) Entering FAULT STATE
        (VI_1) removing VIPs.

 --- 3. Read the tracked command and reproduce the failure ----------------
    grep -n 'script' /etc/keepalived/keepalived.conf
      ->   script "pgrep -x haproxyd"
    pgrep -x haproxyd ; echo "exit=$?"    # -> exit=1  (nothing matches)
    pgrep -x haproxy  ; echo "exit=$?"    # -> exit=0  (this is the truth)
    The monitor is checking a process name that does not exist.

 --- 4. Fix the check so it reflects reality ------------------------------
    sed -i 's/pgrep -x haproxyd/pgrep -x haproxy/' /etc/keepalived/keepalived.conf
      (or edit the file: script "pgrep -x haproxyd"  ->  script "pgrep -x haproxy")

    A more robust real-world check would probe the service, not just the
    process -- e.g.:
        script "/usr/bin/curl -sf -o /dev/null --max-time 2 http://127.0.0.1:80/"
    because a process can be alive yet not serving. Either fix is acceptable
    as long as it tells the TRUTH about HAProxy's health.

 --- 5. Reload keepalived and re-read the config --------------------------
    systemctl restart keepalived      # (reload/SIGHUP also re-reads the file)

 --- 6. Verify recovery ---------------------------------------------------
    journalctl -u keepalived -n 15 --no-pager   # -> (VI_1) Entering MASTER STATE
    ip -4 addr show dev "$IFACE" | grep "$VIP"   # -> the VIP is back
    curl -s http://"$VIP"/                        # -> network-ha-lab: OK ...

 Recovery must happen within ~ (rise * interval) seconds once the check
 passes again ('rise 2', 'interval 2' -> ~4 s), after which VI_1 leaves
 FAULT, re-elects itself MASTER (no higher-priority peer exists), and
 re-adds the VIP.

 Shortcut to auto-restore:   sudo THIS_SCRIPT restore
 Full cleanup of the lab:    sudo THIS_SCRIPT teardown

 Takeaway for the exam and for production: in VRRP-based Network HA a healthy
 service can still be knocked offline by a defective track_script. When a VIP
 disappears, always confirm the FAULT reason in the keepalived log and RUN the
 tracked command by hand before touching the network or the load balancer.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-3-306/364.4/lab)
