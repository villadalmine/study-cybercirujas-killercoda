## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — step by step (read only after you have tried)

 METHOD. Two questions, in this order, for every piece of surface you find:
   1. "Does the workload require it?"  -> if yes, it must be present AND
      persistent (survive a reboot), not just patched at runtime.
   2. "Can anything reach or abuse it?" -> if it is not required, it must be
      impossible to bring back, not merely stopped.
 A runtime-only fix passes a smoke test and fails the next reboot; a
 "stop but do not disable" fix passes ss(8) and fails Restart=always.

 STEP 0 — recon before touching anything
   sudo ./cks-5.1-break-fix.sh status
   sudo ss -lntp
   sudo systemctl list-unit-files --state=enabled | wc -l
   sudo systemctl list-units --failed
   lsmod | wc -l
   sudo find / -xdev -perm -4000 -type f 2>/dev/null
   sudo grep -R '' /etc/sysctl.d/ /etc/modprobe.d/ /etc/modules-load.d/

 What you are looking for, and why it matters on the exam:
   * open ports        -> every listener is a remote entry point
   * enabled units     -> every unit is code that runs as root at boot
   * loaded modules    -> every module is kernel-space attack surface (dccp,
                          sctp, rds, tipc, cramfs, usb-storage, firewire...)
   * SUID/SGID files   -> every one is a local privilege-escalation candidate
   * sudoers drop-ins  -> NOPASSWD turns any RCE into instant root

 BLOCK A — restore the MINIMUM the node requires

 A.0 Find the offending "hardening" artefacts:

   $ sudo grep -R . /etc/sysctl.d/99-cks-lab-break.conf /etc/modprobe.d/99-cks-lab-break.conf
   /etc/sysctl.d/99-cks-lab-break.conf:net.ipv4.ip_forward = 0
   /etc/modprobe.d/99-cks-lab-break.conf:blacklist br_netfilter
   /etc/modprobe.d/99-cks-lab-break.conf:install br_netfilter /bin/false

 A.1 Delete the bad drop-ins (do NOT edit them into shape — remove the file
     the "hardening" added, then state the requirement in your own file):

   sudo rm -f /etc/sysctl.d/99-cks-lab-break.conf
   sudo rm -f /etc/modprobe.d/99-cks-lab-break.conf

     Note: `install br_netfilter /bin/false` is what makes `modprobe
     br_netfilter` silently do nothing. `blacklist` alone only stops
     *automatic* loading; `install ... /bin/false` stops explicit loading too.
     Verify the effective policy, not the file you happen to be reading:

       modprobe --showconfig | grep br_netfilter     # must print nothing

 A.2 Restore module autoload at boot, the kubeadm-documented way:

   cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
   overlay
   br_netfilter
   EOF

   sudo modprobe overlay
   sudo modprobe br_netfilter
   lsmod | grep br_netfilter
   # br_netfilter           32768  0
   # bridge                311296  1 br_netfilter

 A.3 Unmask the unit that consumes /etc/modules-load.d at boot — without it
     your k8s.conf is a decorative file:

   systemctl is-enabled systemd-modules-load.service     # masked
   sudo systemctl unmask systemd-modules-load.service
   sudo systemctl start  systemd-modules-load.service
   systemctl is-enabled systemd-modules-load.service     # static

 A.4 Restore the required sysctls, persistently:

   cat <<'EOF' | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
   net.ipv4.ip_forward                 = 1
   net.bridge.bridge-nf-call-iptables  = 1
   net.bridge.bridge-nf-call-ip6tables = 1
   EOF

   sudo sysctl --system | tail -n 5
   sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables
   # net.ipv4.ip_forward = 1
   # net.bridge.bridge-nf-call-iptables = 1

     Ordering matters: the bridge-nf-* keys do not exist in /proc until
     br_netfilter is loaded, so `sysctl --system` run before the modprobe
     prints `cannot stat /proc/sys/net/bridge/bridge-nf-call-iptables`.
     Load the module first — that is exactly why the autoload unit is needed.

 A.5 Confirm the data plane is alive again:

   kubectl run probe --image=busybox:1.36 --restart=Never -it --rm -- \
     nslookup kubernetes.default.svc.cluster.local
   # Server:    10.96.0.10
   # Address:   10.96.0.10:53
   # Name:      kubernetes.default.svc.cluster.local
   # Address:   10.96.0.1

   sudo kubeadm upgrade plan   # preflight no longer complains about ip_forward

 BLOCK B — delete the surface the node does NOT require

 B.1 The self-resurrecting listener. Go from socket -> PID -> cgroup -> unit;
     never stop at "I killed the process":

   $ sudo ss -lntp 'sport = :8080'
   LISTEN 0 5 0.0.0.0:8080 0.0.0.0:* users:(("python3",pid=1421,fd=3))

   $ systemctl status 1421            # systemd resolves a PID to its unit
   ● cks-lab-legacy-metrics.service - Legacy node metrics exporter ...

   # or, without systemctl:  cat /proc/1421/cgroup

   sudo systemctl disable --now cks-lab-legacy-metrics.service
   sudo rm -f /etc/systemd/system/cks-lab-legacy-metrics.service
   sudo systemctl daemon-reload
   sudo systemctl reset-failed
   sudo ss -lntp 'sport = :8080'      # empty

     `systemctl stop` alone loses to Restart=always the moment anything
     restarts it; `disable` alone leaves the unit runnable; when the unit must
     remain on disk but must never run, use `systemctl mask <unit>`, which
     symlinks it to /dev/null so even a dependency cannot pull it up.
     Generalize on the exam: `systemctl list-units --type=service --state=running`
     and switch off everything the node does not need to be a node.

 B.2 The SUID binary. A SUID copy of find(1) is a textbook local root:
     `lab-find . -exec /bin/sh -p \;` gives an euid-0 shell.

   sudo find / -xdev -perm -4000 -type f 2>/dev/null
   # /usr/local/bin/lab-find      <-- not shipped by any package
   dpkg -S /usr/local/bin/lab-find || rpm -qf /usr/local/bin/lab-find
   # no path found / file ... is not owned by any package

   sudo chmod u-s /usr/local/bin/lab-find     # minimum viable fix
   sudo rm -f     /usr/local/bin/lab-find     # correct fix: it is not needed

 B.3 Unnecessary kernel modules (CIS "unused network protocols"):

   lsmod | grep -E '^(dccp|sctp)'
   sudo modprobe -r dccp sctp

   cat <<'EOF' | sudo tee /etc/modprobe.d/cis-disable-protocols.conf
   install dccp /bin/false
   install sctp /bin/false
   install rds  /bin/false
   install tipc /bin/false
   blacklist dccp
   blacklist sctp
   blacklist rds
   blacklist tipc
   EOF

   sudo modprobe dccp ; lsmod | grep -c dccp     # 0 — the install line wins

     If the module is compiled into a running kernel path you cannot unload
     (`rmmod: ERROR: Module ... is in use`), find the user first:
     `lsmod | grep <mod>` shows the refcount and the dependent modules.

 B.4 The passwordless-sudo principal:

   sudo grep -R 'NOPASSWD' /etc/sudoers /etc/sudoers.d/
   # /etc/sudoers.d/99-cks-lab-ops:cks-lab-ops ALL=(ALL) NOPASSWD: ALL

   sudo rm -f /etc/sudoers.d/99-cks-lab-ops
   sudo visudo -c                    # ALWAYS re-validate after editing sudoers
   sudo userdel -r cks-lab-ops

     Then audit the rest of the principals, which is what the exam actually
     rewards: `awk -F: '($3<1000)&&($7!~/nologin|false/){print}' /etc/passwd`,
     `getent group sudo wheel`, `awk -F: '($2==""){print $1}' /etc/shadow`.

 STEP FINAL — grade and reason about it
   sudo ./cks-5.1-break-fix.sh verify
   # passed: 18   failed: 0

 TAKEAWAYS FOR THE EXAM
   * Minimizing the host footprint is a subtraction with a whitelist, not a
     subtraction. br_netfilter and ip_forward look like surface; on a node with
     a bridged CNI they are load-bearing.
   * Every fix has a runtime half and a persistence half. sysctl -w without
     /etc/sysctl.d, modprobe without /etc/modules-load.d, and systemctl stop
     without disable/mask are all half-fixes that die at the next boot.
   * `blacklist` != `install /bin/false`. Only the second one survives an
     attacker (or a script) running modprobe explicitly.
   * Trace a port to a unit, not to a PID: ss -lntp -> systemctl status <pid>
     -> disable --now + rm + daemon-reload.
   * The same reasoning applies one layer up in Domain 5: a distroless or
     scratch image is exactly this exercise applied to the container
     filesystem — no shell, no package manager, no SUID binaries, no extra
     listeners. Host and image are the same discipline at two scales.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cks/5.1/lab)
