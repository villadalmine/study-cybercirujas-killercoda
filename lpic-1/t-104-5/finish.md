## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — do not read before you have fought --verify

 Method first. Never guess a mode: read the current state, name the class
 (owner / group / other) that is wrong, then change only that class.

     ls -ld  /srv/lab1045 /srv/lab1045/shared /srv/lab1045/dropbox
     stat -c '%A %a %U:%G %n' /srv/lab1045/shared /etc/lab1045/app.conf
     namei -l /srv/lab1045/shared/projects/spec.md   # every component of the path
     id labdev2                                      # uid, gid, supplementary groups

 Remember: to reach a file you need x on EVERY directory of the path, and
 path_resolution(7) checks the classes in order owner -> group -> other and
 stops at the FIRST match. A file 0604 root:webteam is unreadable to a member
 of webteam: the group class matched and it says "no".

 F1 — team share: group ownership + setgid
     chgrp -R webteam /srv/lab1045/shared
     chmod 2775 /srv/lab1045/shared          # == chmod g+rwxs,o=rx
     find /srv/lab1045/shared -type d -exec chmod g+rwxs {} +
     find /srv/lab1045/shared -type f -exec chmod g+rw   {} +

 Why 2775 and not 0775: the setgid bit on a DIRECTORY (leading 2) makes every
 new entry inherit the directory's group instead of the creator's primary
 group, and makes new SUBDIRECTORIES inherit the setgid bit as well. That is
 the only way "new files land in group webteam automatically" is true without
 a nightly chgrp cron job. On a file, the same bit means something completely
 different (run with the file's group, or mandatory locking) — never set it
 on regular files here.
 Verify:
     runuser -u labdev1 -- touch /srv/lab1045/shared/t && ls -l /srv/lab1045/shared/t
     -rw-rw-r-- 1 labdev1 webteam 0 ... t

 F2 — drop-box: restore the sticky bit
     chmod 1777 /srv/lab1045/dropbox         # == chmod +t (o+t)
     ls -ld /srv/lab1045/dropbox
     drwxrwxrwt 2 root root ... /srv/lab1045/dropbox

 The trailing "t" (restricted deletion flag) means: in this directory a
 non-root user may unlink or rename an entry only if they own the entry or
 the directory. Without it, w on the directory is enough to delete somebody
 else's file — write permission belongs to the DIRECTORY, not to the file.
 This is exactly why /tmp is 1777.
 Verify:
     runuser -u labdev2 -- rm -f /srv/lab1045/dropbox/invoice-labdev1.txt
     rm: cannot remove '...': Operation not permitted

 F3 — make the service entry point executable
     chmod 0755 /usr/local/bin/lab1045-report      # == chmod a+x,go-w
     ls -l /usr/local/bin/lab1045-report
     -rwxr-xr-x 1 root root ... /usr/local/bin/lab1045-report

 Read permission lets you copy a script; only x lets execve(2) hand it to the
 kernel. For a #! script the kernel also needs the interpreter itself to be
 executable — check with:  head -1 lab1045-report ; ls -l /usr/bin/env
 Do NOT "fix" it with 0777: a world-writable executable owned by root is a
 privilege escalation waiting for its first non-root writer.

 F4 — the configuration secret: change the GROUP, not the mode of "other"
     chown root:labsvc /etc/lab1045/app.conf       # or:  chgrp labsvc app.conf
     chmod 0640 /etc/lab1045/app.conf              # == chmod u=rw,g=r,o=
     chmod 0755 /etc/lab1045                       # traversal for everyone
     stat -c '%A %U:%G %n' /etc/lab1045/app.conf
     -rw-r----- root:labsvc /etc/lab1045/app.conf

 Pattern to memorise for services: root owns the file (so a compromised
 service cannot rewrite its own configuration), the service's group reads it,
 "other" gets nothing. 0640 root:<svcgroup> is the production default for any
 file containing a credential.
 Verify both directions — the second command MUST fail:
     runuser -u labsvc  -- head -1 /etc/lab1045/app.conf
     runuser -u labdev1 -- head -1 /etc/lab1045/app.conf
     head: cannot open '/etc/lab1045/app.conf' for reading: Permission denied

 F5 — the file-creation mask
     printf 'umask 0002\n' > /etc/profile.d/lab1045-umask.sh
     chmod 0644 /etc/profile.d/lab1045-umask.sh
     runuser -l labdev1 -c 'umask; umask -S'
     0002
     u=rwx,g=rwx,o=rx

 Arithmetic, because the exam asks it numerically: the mask is SUBTRACTED
 from the base mode. Files start at 0666, directories at 0777.
     umask 0077 -> file 0666 & ~0077 = 0600, dir 0777 & ~0077 = 0700  (broken)
     umask 0022 -> file 0644, dir 0755                                (no group write)
     umask 0002 -> file 0664, dir 0775                                (correct here)
     umask 0007 -> file 0660, dir 0770                                (also correct,
                   and stricter: nothing is readable by "other")
 0002 is only safe because the distribution uses user private groups (each
 user's primary group is their own, USERGROUPS_ENAB yes in /etc/login.defs).
 Where users share a primary group, use 0007 or 0027 instead.
 Scope matters: /etc/profile.d/*.sh is read by LOGIN shells. A change there is
 invisible to an already-open session and to non-login shells — log out and
 back in, or source it, before believing your own fix. For daemons, set the
 mask in the unit (UMask=) — systemd does not read /etc/profile.

 F6 — the rogue setuid helper
 Audit the whole box the way the scanner does:
     find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -ls 2>/dev/null
     find /srv/lab1045 -perm /6000 -type f -printf '%M %u:%g %p\n'
     -rwsr-xr-x labsvc:labsvc /srv/lab1045/tools/dumpcfg

 Prove the leak before you touch it (this is the part students skip):
     runuser -u labdev1 -- /srv/lab1045/tools/dumpcfg /etc/lab1045/app.conf
     ...DB_PASSWORD="s3cr3t-never-world-readable"
 labdev1 cannot read that file, yet reads it through the helper: the setuid
 bit made the process run with the EFFECTIVE uid of the file's owner, so the
 kernel checked labsvc's rights, not labdev1's. A setuid copy of any program
 that can open an arbitrary path (cat, find -exec, cp, an editor, a shell)
 hands out that identity wholesale.
 Neutralise, preserving the evidence:
     chmod u-s,g-s /srv/lab1045/tools/dumpcfg      # == chmod 0755
     ls -l /srv/lab1045/tools/dumpcfg
     -rwxr-xr-x 1 labsvc labsvc ... dumpcfg
 Then re-run the leak command: Permission denied. In production you would also
 mount data filesystems nosuid (see mount(8)) so the bit is ignored entirely.

 F7 — the private subtree inside the share
     chgrp -R webteam /srv/lab1045/shared/projects
     chmod 2775 /srv/lab1045/shared/projects
     chmod 0664 /srv/lab1045/shared/projects/spec.md
     runuser -u labdev2 -- sh -c 'echo "reviewed" >> /srv/lab1045/shared/projects/spec.md'

 Note that r on a directory lets you LIST names, while x lets you STAT and
 open the entries. A directory 0640 lists names and then denies everything —
 the classic "ls works but nothing else does" symptom. Directories are
 effectively rx or nothing.

 END-TO-END CONFIRMATION
     runuser -u labsvc -- /usr/local/bin/lab1045-report
     REPORT OK -> /srv/lab1045/shared/reports/report-<stamp>-labsvc.txt
     ls -l /srv/lab1045/shared/reports/
     -rw-rw-r-- 1 labsvc webteam ...    <- group inherited through setgid
     sudo ./break-fix-104.5.sh --verify

 ONE-SHOT REPAIR (read it as a checklist, not as a spell)
     chgrp -R webteam /srv/lab1045/shared
     find /srv/lab1045/shared -type d -exec chmod 2775 {} +
     find /srv/lab1045/shared -type f -exec chmod 0664 {} +
     chmod 1777 /srv/lab1045/dropbox
     chmod 0755 /usr/local/bin/lab1045-report
     chown root:labsvc /etc/lab1045/app.conf && chmod 0640 /etc/lab1045/app.conf
     printf 'umask 0002\n' > /etc/profile.d/lab1045-umask.sh
     find /srv/lab1045 -type f -perm /6000 -exec chmod u-s,g-s {} +

 EXAM TRAPS CONDENSED
  * Special bits occupy the leading octal digit: 4=setuid, 2=setgid, 1=sticky.
    "chmod 755" on a setuid file SILENTLY CLEARS it (3 digits reset the 4th);
    use chmod u+x when you mean to preserve it.
  * ls shows the special bits by overloading the x column: s/S (setuid|setgid,
    lowercase means x is also set) and t/T (sticky). A capital letter means
    the bit is set but the underlying x is NOT — usually a mistake.
  * setuid/setgid on a shell script is ignored by Linux; the bit only takes
    effect on binaries.
  * chown user:group / chown user: / chown :group / chgrp group are the four
    forms; only root may give a file away (chown), the owner may only change
    the group and only to a group they belong to.
  * Adding a user to a group does not change their running sessions: the
    supplementary groups are read at login. Use newgrp, or log out; id(1) is
    the arbiter, /etc/group is only the intent.
  * umask is a per-process property inherited by children — set it in the
    shell profile for users, in the unit file (UMask=) for daemons.
  * Deleting a file is a WRITE to its directory, not to the file: mode 0444
    does not protect a file living in a directory you can write, which is the
    whole reason the sticky bit exists.

 Objective reference: https://www.lpi.org/our-certifications/exam-101-objectives/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/104.5/lab)
