## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION - do not read before attempting the repair

 STEP 0 - Diagnose before touching anything
   # timedatectl
                  Local time: Fri 2026-08-28 21:35:12 +14
              Universal time: Thu 2026-08-28 07:35:12 UTC
                    RTC time: Fri 2026-08-28 21:35:11
                   Time zone: n/a (n/a, +1400)
   System clock synchronized: no
                 NTP service: inactive
             RTC in local TZ: yes

   Read it line by line, it is the whole exercise:
     - "Time zone: n/a"        -> /etc/localtime is not a symlink, so systemd
                                  cannot derive the zone NAME from it
     - "+1400"                 -> the zone DATA in use is UTC+14
     - "System clock sync: no" -> nothing is steering the clock
     - "NTP service: inactive" -> the client is not running
     - "RTC in local TZ: yes"  -> /etc/adjtime says LOCAL; on reboot the RTC
                                  value will be reinterpreted and jump again

   Confirm the underlying files:
     # ls -l /etc/localtime
     -rw-r--r-- 1 root root 429 Aug 28 21:30 /etc/localtime      <- regular file!
     # cat /etc/timezone
     Europe/Lisbon                                               <- and it lies
     # cat /etc/adjtime
     0.0 0 0.0
     0
     LOCAL
     # date -u ; hwclock --show --verbose

   And the daemon:
     # systemctl status chronyd     (or systemd-timesyncd / ntpd)
     ● chronyd.service
          Loaded: masked (Reason: Unit chronyd.service is masked.)
          Active: inactive (dead)
     # journalctl -u chronyd -b --no-pager | tail -20


 STEP 1 - Fix the timezone (the name AND the symlink)
   Find the correct zone identifier first:
     # timedatectl list-timezones | grep -i madrid
     Europe/Madrid

   Let timedatectl do it - it rewrites /etc/localtime as a proper symlink:
     # timedatectl set-timezone Europe/Madrid
     # ls -l /etc/localtime
     lrwxrwxrwx 1 root root 33 Aug 28 21:40 /etc/localtime -> /usr/share/zoneinfo/Europe/Madrid

   Equivalent manual method (know both for the exam):
     # ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
     # echo 'Europe/Madrid' > /etc/timezone            # Debian family only
     # dpkg-reconfigure tzdata                         # Debian, interactive
     Note: timedatectl set-timezone does NOT update /etc/timezone on all
     distributions; check it and fix it by hand if it still disagrees.

   Verify: date shows the right offset (+02:00 in summer for Europe/Madrid).
     # date -R
     Fri, 28 Aug 2026 09:40:12 +0200


 STEP 2 - Put the RTC back into UTC
     # timedatectl set-local-rtc 0 --adjust-system-clock
     # cat /etc/adjtime
     0.0 0 0.0
     0
     UTC

   Manual equivalent: hwclock --systohc --utc (which rewrites the third line
   of /etc/adjtime). Keep the RTC in UTC on servers - "RTC in local TZ" is
   only a dual-boot concession and systemd warns about it because DST
   transitions make it ambiguous.


 STEP 3 - Unmask, enable and start the NTP client
     # systemctl unmask chronyd
     Removed /etc/systemd/system/chronyd.service.
     # systemctl enable --now chronyd

   A masked unit is a symlink to /dev/null in /etc/systemd/system; that is
   why "systemctl start" refuses and why "timedatectl set-ntp true" fails
   with "Failed to enable unit: Unit file ... is masked." Unmask first.


 STEP 4 - Give it sources it can actually reach
   chrony:      # grep -nE '^(server|pool|#LAB-DISABLED)' /etc/chrony/chrony.conf
                remove the injected 192.0.2.x lines, uncomment the original
                pool/server lines (strip the '#LAB-DISABLED ' prefix):
                # sed -i '/LAB-INJECTED/,+2d' /etc/chrony/chrony.conf
                # sed -i 's/^#LAB-DISABLED //' /etc/chrony/chrony.conf
                # systemctl restart chronyd

   timesyncd:   the fault is a drop-in, which overrides the main file:
                # systemd-analyze cat-config systemd/timesyncd.conf
                # rm /etc/systemd/timesyncd.conf.d/99-lab-break.conf
                # systemctl restart systemd-timesyncd

   ntpd/ntpsec: same sed treatment on /etc/ntp.conf (or /etc/ntpsec/ntp.conf),
                then # systemctl restart ntpd

   Typical healthy source lines:
                pool 2.pool.ntp.org iburst          # chrony / ntpd
                NTP=time.cloudflare.com             # timesyncd, [Time] section


 STEP 5 - Turn synchronization on and force the first step
     # timedatectl set-ntp true
     # chronyc sources -v
     MS Name/IP address     Stratum Poll Reach LastRx Last sample
     ^* ntp1.example.net          2    6   377     21   +112us[ +98us] +/- 12ms
          '^*' = currently selected source. All '?' or blank Reach means
          unreachable - go back to step 4 or check egress UDP/123 and firewall.
     # chronyc tracking
     Reference ID    : C0248F01 (ntp1.example.net)
     Stratum         : 3
     System time     : 0.000004521 seconds slow of NTP time

   chrony will not step a clock this far off by itself once running
   (makestep policy), so force it:
     # chronyc makestep
     200 OK

   With timesyncd instead:
     # timedatectl timesync-status
            Server: 162.159.200.1 (time.cloudflare.com)
       Poll interval: 32s
          Packet count: 3
     # journalctl -u systemd-timesyncd -b | tail
     systemd-timesyncd[512]: Initial synchronization to time server ...

   With ntpd: # ntpq -p   (look for the '*' peer)


 STEP 6 - If the lab VM has no internet access
   Set it by hand, then hand it back to the daemon:
     # timedatectl set-ntp false                 # required: set-time refuses while NTP is on
     # timedatectl set-time '2026-08-27 09:41:00'
     or the classic:  # date -s '2026-08-27 09:41:00'
     or from another host: # date -s "$(ssh peer date -u)" -u
     # hwclock --systohc                          # push system -> RTC
     # timedatectl set-ntp true

   Reverse direction (RTC -> system, e.g. after a bad manual set):
     # hwclock --hctosys


 STEP 7 - Persist and confirm
     # hwclock --systohc --utc
     # hwclock --show
     2026-08-27 09:41:33.512300+02:00
     # timedatectl
                  Local time: Thu 2026-08-27 09:41:35 CEST
                   Time zone: Europe/Madrid (CEST, +0200)
   System clock synchronized: yes
                 NTP service: active
             RTC in local TZ: no

     # sudo ./108.1-break-fix.sh --verify        # all checks must pass
     # reboot                                    # the real proof: it comes
                                                 # back with the right time


 STEP 8 - Clean up the collateral damage
   Files written while the clock was in the future keep future mtimes, and
   make(1), rsync, incremental backups and log rotation all misbehave on them:
     # find / -xdev -newermt "$(date -d '+1 minute' '+%Y-%m-%d %H:%M:%S')" \
           -printf '%T+ %p\n' 2>/dev/null | sort | head -40
     # touch <offending files>          # only where it is safe to restamp

   And read the record of what happened - systemd journals every clock step:
     # journalctl --no-pager | grep -i "System clock\|time has been changed"


 WHY EACH FAULT MATTERS IN PRODUCTION
   wrong timezone     - only affects presentation (log timestamps, cron
                        schedules, user-facing times). UTC internally is
                        unaffected. This is why servers are kept on UTC.
   /etc/localtime as
     a regular file   - works, but the zone loses its NAME, so DST rules
                        still apply yet nothing can report or replicate the
                        configuration. Always a symlink.
   RTC in local time  - the clock jumps at every boot and twice a year at DST
                        transitions; ambiguous during the repeated hour.
   clock in the future- breaks TLS validity windows, Kerberos (default 5 min
                        skew tolerance), repository metadata Valid-Until,
                        JWT/OIDC tokens, distributed logs and any at/cron job
                        scheduled in the skipped interval - those simply
                        never run.
   masked ntp unit    - the machine can be corrected once by hand and then
                        drift again forever; masking is invisible in
                        "systemctl is-active" output alone, which is why the
                        diagnosis must start at timedatectl, not at date.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/108.1/lab)
