## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
DETAILED STEP-BY-STEP SOLUTION & ARCHITECTURAL GUIDANCE (FOR STUDENT REFERENCE)
Official Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
Topic 712.3: Control Mounting and Unmounting of File Systems

DIAGNOSTIC STEP 1: Diagnose the EBUSY Unmount Failure
When running `umount /mnt/secure_data`, the kernel returns `EBUSY` (Device busy).
Standard `ls -la /mnt/secure_data` shows no active files. Why?
Because a process holds an open file descriptor on an unlinked file (anonymous vnode).

Command to inspect open vnodes / file handles on BSD:
  # FreeBSD native tool:
  fstat -f /mnt/secure_data

  # Cross-platform / Linux tool:
  fuser -mv /mnt/secure_data
  OR
  lsof +D /mnt/secure_data

Expected CLI Output from fstat:
  USER     CMD          PID   FD MOUNT        INUM MODE         SZ|DV R/W
  root     python3    41205    3 /mnt/secure_data   4 -rw-------      17  w

Explanation: PID 41205 holds file descriptor 3 open on the mountpoint.

Action to resolve:
  kill -9 41205
  # or using fuser directly:
  fuser -k -9 /mnt/secure_data

DIAGNOSTIC STEP 2: Resolve Execution Blocked by Mount Flags (noexec)
Running `/mnt/secure_data/deploy_app.sh` results in:
  sh: /mnt/secure_data/deploy_app.sh: Permission denied

Check current mount options:
  mount | grep /mnt/secure_data

Expected Output:
  /dev/md99 on /mnt/secure_data (ufs, local, noexec, nosuid, mounted by root)

In BSD, you can dynamically update mount flags on a live file system without
unmounting it using the `-u` (update) flag:

Command:
  mount -u -o exec,suid /mnt/secure_data

Verification:
  /mnt/secure_data/deploy_app.sh
Expected Output:
  SUCCESS: Binary executed successfully on secure_data mount!

DIAGNOSTIC STEP 3: Repair Corrupted /etc/fstab File Syntax
Running `mount -a` displays:
  mount: /mnt/secure_data: bad option invalid_flag_xyz

Inspect /etc/fstab:
  cat /etc/fstab | grep secure_data

Output:
  /dev/md99   /mnt/secure_data   ufs   rw,noexec,nosuid,invalid_flag_xyz,failok   2   2

Fix: Edit /etc/fstab using vi/nano to remove `invalid_flag_xyz` and update flags to `rw,exec,suid,failok`:
  /dev/md99   /mnt/secure_data   ufs   rw,exec,suid,failok   2   2

Validate with:
  mount -a
  echo $?  # Should return 0

SUMMARY OF KEY BSD MOUNT COMMANDS & OPTIONS FOR LPI 702-100:
- mount -a                     : Mounts all file systems listed in /etc/fstab (except those marked 'noauto').
- mount -u -o <opts> <mount>   : Updates flags on an already mounted file system atomically.
- umount -f <mount>            : Forces unmount (invalidates vnodes even if open handles exist; use with caution in production).
- fstat -f <path>              : Displays active file handles across vnodes on specified BSD filesystem.
- fstab(5) fields              : <device> <mountpoint> <type> <options> <dump_freq> <pass_num>
- Important BSD flags          : late (delays mount until network/daemons ready), failok (prevents boot drop to single-user mode), noatime, noexec, nosuid, ro, rw.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpi-702/712.3/lab)
