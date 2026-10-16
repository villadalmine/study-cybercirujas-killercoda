## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 REFERENCE SOLUTION -- step by step  (read only after you have tried)

 GOAL RECAP: an unprivileged user can become root because a SUID-root copy of
 a shell was planted at /usr/local/bin/.sysdiag. Fix = find it, prove it,
 neutralise it, and rule out further persistence.

 ---- Step 1: Reproduce the symptom (confirm the finding) --------------------

   # su - labuser            # password: labpass123
   $ /usr/local/bin/.sysdiag -p
   # id                      # note: euid=0(root)  -> escalation confirmed
   # cat /etc/shadow | head  # succeeds -> confidentiality broken
   # exit

 ---- Step 2: Enumerate every SUID / SGID binary on local filesystems --------

   # find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -exec ls -l {} \; 2>/dev/null

   -xdev keeps the scan on local mounts. Look for anything that is NOT a
   known system tool. Compare against a fresh install or a package baseline:

     Debian/Ubuntu:  dpkg -S /usr/local/bin/.sysdiag   # -> "no path found" = not packaged
     RHEL/Fedora:    rpm -qf  /usr/local/bin/.sysdiag   # -> "not owned by any package"

   A file owned by no package, living under /usr/local/bin, with the SUID bit
   set, is an immediate red flag.

 ---- Step 3: Identify WHAT the anomalous file is ---------------------------

   # ls -l   /usr/local/bin/.sysdiag      # -rwsr-xr-x root root  -> SUID + root-owned
   # file    /usr/local/bin/.sysdiag      # ELF ... dynamically linked, interpreter...
   # sha256sum /usr/local/bin/.sysdiag /bin/bash   # identical hash -> it IS bash

   A SUID-root interactive shell has no legitimate reason to exist.

 ---- Step 4: Neutralise the vector -----------------------------------------

   # chmod u-s /usr/local/bin/.sysdiag    # first remove the dangerous SUID bit
   # rm -f    /usr/local/bin/.sysdiag     # then delete the rogue binary entirely

   (Removing the SUID bit alone stops the escalation; deleting the planted
    binary is the correct cleanup once you have identified it as illegitimate.)

 ---- Step 5: Hunt for additional persistence (defence in depth) -------------

   # find /etc/cron* /var/spool/cron -type f 2>/dev/null | xargs -r ls -l
   # ls -l /etc/sudoers.d/ ; grep -R NOPASSWD /etc/sudoers /etc/sudoers.d 2>/dev/null
   # for h in /home/* /root; do ls -l "$h/.ssh/authorized_keys" 2>/dev/null; done
   # stat -c '%A %U:%G %n' /etc/passwd /etc/shadow    # must be 644 root:root / 640 root:shadow
   # last -n 20 ; lastb -n 20                          # suspicious logins

 ---- Step 6: Verify the fix ------------------------------------------------

   # su - labuser -c '/usr/local/bin/.sysdiag -p -c "id"'   # -> No such file / no root
   # sudo ./break-and-fix.sh check                          # -> RESULT: PASS

 ---- Step 7: Harden so it cannot recur -------------------------------------

   * Mount non-system filesystems with nosuid,nodev,noexec where feasible
     (see /etc/fstab; e.g. /tmp, /home, removable media).
   * Establish a file-integrity baseline and alert on SUID changes:
       - AIDE:   aideinit ; aide --check
       - RHEL:   rpm -Va | grep -E '^..5|S...'   (verify installed files)
       - Debian: debsums -c
   * Periodically diff live SUID inventory against a trusted baseline (this
     script records one at /root/.suid_baseline.txt for exactly that purpose).
   * Apply least privilege: legitimate SUID tools should be few, packaged,
     and audited; capabilities (setcap) are often a safer alternative.

 Official objective reference:
   https://www.lpi.org/our-certifications/exam-303-objectives/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-3-303/335.1/lab)
