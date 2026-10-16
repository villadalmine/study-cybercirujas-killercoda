## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
===== SOLUTION BEGIN =========================================================

 333.1 Discretionary Access Control - answer key
 Read only after you have tried. Every command below runs as root.

 STEP 0 - map the damage before touching anything

   namei -om /srv/dac-lab/projects/apollo/mission.log
   stat -c '%A %a %U:%G %n' /srv/dac-lab/projects/apollo
   getfacl /srv/dac-lab/reports/q3-summary.txt
   lsattr  /srv/dac-lab/etc/app.conf
   find /srv/dac-lab -perm /6000 -type f -ls
   id dac-bob

   "namei -om" walks every component of the path and prints its mode: it is
   the fastest way to see that a denial comes from a parent directory's
   missing x bit rather than from the file itself.

 FAULT 1 - shared directory: wrong group, no SGID, no group write

   Observed:  drwxr-x---  root:root   /srv/dac-lab/projects/apollo
   Wanted:    drwxrws---  root:dacteam

     chgrp dacteam /srv/dac-lab/projects/apollo
     chmod 2770    /srv/dac-lab/projects/apollo
     chgrp dacteam /srv/dac-lab/projects/apollo/mission.log
     chmod 0660    /srv/dac-lab/projects/apollo/mission.log

   Check:  ls -ld /srv/dac-lab/projects/apollo
           drwxrws--- 2 root dacteam 4096 ... apollo

   Why the SGID bit (2 in 2770): on a directory it makes every new entry
   inherit the DIRECTORY's group instead of the creator's primary group, and
   it propagates itself to new subdirectories. Without it, dac-alice's files
   land in group "dac-alice" (her user private group) and dac-bob is locked
   out even though the directory itself is fine.
   A capital S in the listing (drwxr-S---) means SGID is set but the group
   execute bit is missing - a common half-fix.
   Note the parallel with the sticky bit (chmod 1777 /tmp), which restricts
   deletion in a world-writable directory to the file owner.

 FAULT 5 - umask 0077 kills the inheritance you just restored

   Two valid repairs. Prefer the second.

   (a) Fix the drop-in, which is global and easy to undo by the next ticket:
         sed -i 's/^umask 077/umask 002/' /etc/profile.d/99-dac-lab-umask.sh
       umask 002 works only with user private groups (each user's primary
       group is their own), which is the default on Debian and RHEL alike.

   (b) Attach a DEFAULT ACL to the directory - it belongs to the data, not to
       the user's shell, and it supersedes the process umask for files created
       inside that directory:
         setfacl -d -m u::rwx,g::rwx,o::--- /srv/dac-lab/projects/apollo

       Check:  getfacl /srv/dac-lab/projects/apollo
               default:user::rwx
               default:group::rwx
               default:other::---

   Existing files created while the lab was broken keep their old mode; fix
   them explicitly:
         chmod -R g+rw /srv/dac-lab/projects/apollo

 FAULT 2 - the ACL mask is clamping a valid grant

   getfacl /srv/dac-lab/reports/q3-summary.txt
     user::rw-
     user:dac-bob:rw-        #effective:r--     <-- the grant is there ...
     group::r--
     mask::r--                                  <-- ... and the mask kills it
     other::---

   The mask is the upper bound applied to every named user, every named group
   and the owning group. Raise the mask only:

     setfacl -m m::rw- /srv/dac-lab/reports/q3-summary.txt

   Check:  getfacl file   -> user:dac-bob:rw-   with no "#effective" comment

   Two traps worth memorising:
     * "chmod g+w file" on an ACL-bearing file rewrites the MASK, not the
       owning group entry. That happens to fix this case, but it silently
       widens every named entry too - say what you mean with m::.
     * "chmod 666 file" passes the functional test and fails the audit: it
       grants write to the whole world. The grader rejects it.
     * setfacl -x u:dac-bob file removes one entry; -b removes all access
       ACLs; -k removes the default ACL.

 FAULT 3 - the immutable extended attribute outranks DAC entirely

   lsattr /srv/dac-lab/etc/app.conf
     ----i---------e------- /srv/dac-lab/etc/app.conf

     chattr -i /srv/dac-lab/etc/app.conf

   Check:  lsattr file  -> --------------e-------   ; touch file now succeeds

   While +i is set, the file cannot be modified, deleted, renamed, hard-linked
   or have its metadata changed - by anyone, root included. Removing the flag
   requires CAP_LINUX_IMMUTABLE, which root normally holds but a hardened
   container or a securelevel-style lockdown may drop.
   Related and equally examinable: chattr +a (append-only, the classic
   protection for log files) and chattr +d (skip this file in dump backups).

 FAULT 4 - the SGID bit was stripped from the helper binary

   stat -c '%A %U:%G %n' /srv/dac-lab/bin/showsecret
     -rwx--x--x root:dacsecret ...        <-- no s : it runs with the caller's
                                              own egid, so the group-readable
                                              token is out of reach

     chmod 2711 /srv/dac-lab/bin/showsecret      # or: chmod g+s FILE

   Check:  stat -c '%A' file          -> -rwx--s--x
           runuser -u dac-bob -- /srv/dac-lab/bin/showsecret \
                                 /srv/dac-lab/secret/token.txt
           LAB-SECRET-TOKEN-333-1

   SUID (4000) makes the process run with the FILE OWNER's euid; SGID (2000)
   on an executable makes it run with the file's group. That is how a normal
   user reads /etc/shadow through "passwd" without ever holding read access
   to it. The correct fix is to restore the bit on the binary, never to widen
   the data: adding dac-bob to "dacsecret" or chmod 0644 on the token gives
   him permanent, unmediated access and fails check 6b.

   Auditing SUID/SGID is itself an exam objective:
     find / -xdev -perm /6000 -type f -ls 2>/dev/null
     find / -xdev -perm -0002 ! -type l -ls 2>/dev/null   # world-writable

 STEP FINAL - confirm, then release the lab

   ./333.1-dac-break-fix.sh --verify
   ./333.1-dac-break-fix.sh --cleanup

 Reference: LPI exam 303-300 objectives, topic 333.1
            https://www.lpi.org/our-certifications/exam-303-objectives/
            acl(5), setfacl(1), getfacl(1), chattr(1), lsattr(1),
            chmod(1), umask(1p), namei(1), runuser(1)

===== SOLUTION END ===========================================================
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-3-303/333.1/lab)
