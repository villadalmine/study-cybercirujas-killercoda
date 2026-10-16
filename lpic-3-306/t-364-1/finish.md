## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — step-by-step (instructor reference; do not read before trying)

 0. Confirm the diagnosis. Two independent faults were injected.
      systemctl status watchdog
      journalctl -u watchdog -b --no-pager
        -> "cannot open /dev/watchdog-lab-missing (errno = 2 = 'No such
            file or directory')"   ... fault #2 (wrong device path)
      ls -l /dev/watchdog*         -> nothing                ... fault #1
      lsmod | grep -i dog          -> nothing                ... fault #1
      ls -l /etc/modprobe.d/ | grep teach-plat
        -> teach-plat-364-1-break.conf contains "blacklist softdog"

 1. Remove the module blacklist so softdog can load again.
      rm -f /etc/modprobe.d/teach-plat-364-1-break.conf
      depmod -a            # refresh module dependency/blacklist state

 2. Load the software watchdog now, and prove the device appears.
      modprobe softdog
      lsmod | grep softdog
      ls -l /dev/watchdog /dev/watchdog0
      wdctl /dev/watchdog          # shows timeout, identity, flags
    (In this lab softdog loads with soft_noboot=1 from the safety file, so it
     will only log on timeout. That is a LAB setting; production omits it.)

 3. Make the module load automatically on every boot (persistence).
      echo softdog > /etc/modules-load.d/softdog.conf
    (Debian alternative: set watchdog_module="softdog" in /etc/default/watchdog.)

 4. Fix the daemon config to point at the real device.
      # edit /etc/watchdog.conf:
      #   watchdog-device = /dev/watchdog
      sed -i 's|^\s*watchdog-device.*|watchdog-device = /dev/watchdog|' /etc/watchdog.conf

 5. Start and enable the service, then confirm it is healthy.
      systemctl restart watchdog
      systemctl enable watchdog
      systemctl status watchdog            # -> Active: running
      journalctl -u watchdog -b --no-pager # -> keep-alive activity, no errors

 6. Prove the timer is actually being fed (the daemon holds the device open).
      sudo fuser -v /dev/watchdog          # shows the 'watchdog' process
      #   or:  sudo lsof /dev/watchdog

 7. Grade it.
      sudo ./break_fix.sh verify           # exits 0 when all checks pass

 WHY THIS MATTERS (production framing)
   - Only ONE process may hold /dev/watchdog. If systemd's own runtime
     watchdog is enabled (RuntimeWatchdogSec in /etc/systemd/system.conf),
     it grabs the device and the watchdog daemon fails with EBUSY. Pick one
     owner. In an SBD/Pacemaker setup, sbd is usually that owner.
   - `nowayout` (module/config) decides whether closing the device stops the
     countdown. With nowayout=1 the box WILL reset even if the daemon exits
     cleanly — safer for real HA, dangerous for a lab, hence soft_noboot=1.
   - The bug was "silent": the URL/service existed but protection was off.
     Always verify the watchdog is *held open and fed*, not merely installed.

 Reset the lab for the next student:
      sudo ./break_fix.sh revert
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-3-306/364.1/lab)
