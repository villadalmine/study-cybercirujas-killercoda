## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION - do not read before --check gives you five PASS lines

STEP 0 - Reconnaissance. Always the same three commands.
  # What is actually mounted, and with which options:
  findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS | grep -E 'lab-|TARGET'

  # What /etc/fstab claims, validated statically - this alone finds fault 1:
  findmnt --verify --verbose

  # What the devices really contain (UUID, LABEL, TYPE come from the
  # superblock, not from fstab):
  lsblk -f | grep -A0 loop
  blkid | grep loop
  losetup -a

  Read /etc/fstab itself and note the six fields:
    <device>  <mountpoint>  <fstype>  <options>  <dump>  <fsck-pass>
  Field 6 (pass) non-zero + no 'nofail' is what turns a storage typo into a
  failed boot: systemd generates a .mount unit that local-fs.target requires.

FAULT 1 - bad UUID in /etc/fstab
  Symptom reproduced:
    # mount -a
    mount: /mnt/lab-data: can't find UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxdead.

  Get the truth from the device. The lab's payroll volume carries LABEL=LABDATA:
    # blkid -L LABDATA
    /dev/loop0
    # blkid -s UUID -o value /dev/loop0
    8f3a91c2-77b1-4d0e-9a3d-1c2b4e6f7a10

  Fix the entry (replace the UUID with the real one):
    # sed -i 's|^UUID=.*/mnt/lab-data|UUID=8f3a91c2-77b1-4d0e-9a3d-1c2b4e6f7a10\t/mnt/lab-data|' /etc/fstab
  or edit /etc/fstab by hand so the line reads:
    UUID=8f3a91c2-77b1-4d0e-9a3d-1c2b4e6f7a10  /mnt/lab-data  ext4  defaults  0 2

  Re-read it and mount:
    # systemctl daemon-reload
    # mount -a
    # findmnt /mnt/lab-data
    TARGET        SOURCE     FSTYPE OPTIONS
    /mnt/lab-data /dev/loop0 ext4   rw,relatime
    # cat /mnt/lab-data/payroll.csv

  PRODUCTION NOTE - two lessons here, not one:
    a) 'nofail' (and ideally 'x-systemd.device-timeout=10s') belongs on every
       non-essential volume. Without it, one dead disk stops the whole boot.
    b) These lab devices are loopback devices created by hand; they do not
       exist at boot at all, so a UUID= entry for them can never work after a
       reboot. The correct persistent form for a file-backed filesystem is:
         /var/lib/lpic-lab/104.3/data.img  /mnt/lab-data  ext4  defaults,loop,nofail  0 2
       mount(8) sets up the loop device itself when it sees 'loop'.

  If you DID reboot before fixing it and landed in emergency mode:
    - enter the root password at the maintenance prompt
    - the root filesystem is mounted read-only, so:
        # mount -o remount,rw /
        # vi /etc/fstab          (fix or comment out the offending line)
        # systemctl daemon-reload
        # mount -a
        # systemctl default      (or: reboot)
    - if you cannot log in at all, append 'systemd.unit=emergency.target' or
      'init=/bin/bash' to the kernel command line from the GRUB edit screen.

FAULT 2 - filesystem type in fstab does not match the device
  Symptom reproduced:
    # mount /mnt/lab-archive
    mount: /mnt/lab-archive: wrong fs type, bad option, bad superblock on
    /dev/loop1, missing codepage or helper program, or other error.
    # dmesg | tail -3
    EXT4-fs (loop1): VFS: Can't find ext4 filesystem

  Ask the device, never fstab:
    # blkid -L LABARCH
    /dev/loop1
    # blkid /dev/loop1
    /dev/loop1: SEC_TYPE="msdos" LABEL_FATBOOT="LABARCH" LABEL="LABARCH" UUID="A1B2-C3D4" TYPE="vfat"

  Correct the third field of the line whose mount point is /mnt/lab-archive:
    LABEL=LABARCH  /mnt/lab-archive  vfat  defaults,nofail  0 2
  Then:
    # systemctl daemon-reload && mount -a
    # findmnt -o TARGET,SOURCE,FSTYPE /mnt/lab-archive
    # cat /mnt/lab-archive/README.txt

  'auto' also works (blkid probes the type) and is accepted by the grader,
  but an explicit type is better practice: it fails loudly instead of
  silently mounting whatever happens to be plugged in.

FAULT 3 - read-only filesystem, in the kernel AND in fstab
  Symptom reproduced:
    # echo test >> /mnt/lab-logs/app.log
    -bash: /mnt/lab-logs/app.log: Read-only file system
    # findmnt -no OPTIONS /mnt/lab-logs
    ro,nosuid,nodev,relatime

  Fix the live mount without unmounting anything (no downtime, open file
  descriptors survive):
    # mount -o remount,rw /mnt/lab-logs
    # findmnt -no OPTIONS /mnt/lab-logs
    rw,nosuid,nodev,relatime

  Make it persistent - the fstab line still says 'ro', so 'mount -a' or the
  next boot would undo your work. Edit it to:
    UUID=<logs-uuid>  /mnt/lab-logs  ext4  rw,nosuid,nodev,nofail  0 2
  or simply 'defaults,nofail'. Then:
    # systemctl daemon-reload
    # mount -o remount /mnt/lab-logs   # re-applies the options from fstab
    # echo "$(date -Is) ok" >> /mnt/lab-logs/app.log

  PRODUCTION NOTE: a filesystem that flipped to read-only *on its own* is a
  different problem - ext4 does that on I/O error (errors=remount-ro).
  Check 'dmesg', 'journalctl -k' and the device's SMART data before you
  remount it rw, or you will simply repeat the corruption.
  Keep nosuid/nodev on data volumes: they are cheap, effective hardening.

FAULT 4 - "target is busy"
  Symptom reproduced:
    # umount /mnt/lab-scratch
    umount: /mnt/lab-scratch: target is busy.

  Identify the holder before touching anything:
    # fuser -vm /mnt/lab-scratch
                         USER   PID ACCESS COMMAND
    /mnt/lab-scratch:    root  1234 ..c..  sleep
  ACCESS letters: c = current directory, f = open file, e = running executable,
  r = root directory, m = mmap'ed file. Here it is 'c' - a process whose CWD
  is inside the mount point. Same answer with lsof:
    # lsof +f -- /mnt/lab-scratch
    COMMAND  PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
    sleep   1234 root  cwd    DIR    7,3     1024    2 /mnt/lab-scratch
  And confirm what it is before killing it:
    # ps -o pid,ppid,user,args -p 1234
    # ls -l /proc/1234/cwd

  Then choose deliberately:
    # kill 1234                     # ask it to stop (correct here)
    # umount /mnt/lab-scratch
  If the process must keep running, move it out instead of killing it - or
  in the real world, stop the service that owns it:
    # systemctl stop <unit> && umount /mnt/lab-scratch
  Last resorts, and what they really mean:
    # umount -l /mnt/lab-scratch    # lazy: detaches the tree NOW, frees the
                                    # device only when the last reference
                                    # closes. The unmount is not finished;
                                    # 'losetup -d' or a re-mkfs can still fail.
    # umount -f /mnt/lab-scratch    # force: intended for unreachable NFS
    # fuser -km /mnt/lab-scratch    # SIGKILL every user of the fs - data loss
  Verify:
    # findmnt /mnt/lab-scratch      # no output = unmounted
    # mountpoint /mnt/lab-scratch
    /mnt/lab-scratch is not a mountpoint

FAULT 5 - a mount shadowing a populated directory
  Symptom reproduced:
    # ls /mnt/lab-shared
    placeholder.txt
  The report is not deleted. Mounting over a non-empty directory hides its
  contents for as long as the mount exists; the inodes are untouched.

  Prove it:
    # findmnt /mnt/lab-shared
    TARGET           SOURCE FSTYPE OPTIONS
    /mnt/lab-shared  tmpfs  tmpfs  rw,relatime,size=16384k,mode=755
    # df -h /mnt/lab-shared
  Optional, without disturbing the tmpfs - bind the parent elsewhere and look
  underneath (a bind mount of a directory exposes the underlying tree):
    # mkdir -p /mnt/peek && mount --bind /mnt /mnt/peek
    # ls /mnt/peek/lab-shared
    quarterly-report.txt
    # umount /mnt/peek && rmdir /mnt/peek

  Remove the shadow:
    # umount /mnt/lab-shared
    # ls /mnt/lab-shared
    quarterly-report.txt
    # cat /mnt/lab-shared/quarterly-report.txt

  PRODUCTION NOTE: this is the classic "the disk filled up but du shows
  nothing" / "our data vanished after the reboot" incident. It happens when a
  service writes to a path before its volume is mounted, and again when
  someone mounts over a directory that already holds data. Mount points
  should be empty by policy, and 'findmnt --submounts <path>' plus a bind
  mount of the parent are how you audit it. The mirror image of this bug is
  equally common: the volume failed to mount, the service wrote to the ROOT
  filesystem instead, and those bytes stay invisible once the volume is
  mounted correctly - always check the underlying directory before you
  celebrate.

FINAL VERIFICATION - a fix you have not proven does not exist
  # findmnt --verify --verbose        # zero errors
  # mount -a                          # silent, exit status 0
  # echo $?
  0
  # mount -a                          # idempotent: still silent
  # findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS | grep lab-
  # sudo ./lpic1-104.3-mount-breakfix.sh --check
  # reboot                            # the only real proof for fstab work
  # sudo ./lpic1-104.3-mount-breakfix.sh --check

  Remember for the exam and for production: 'mount -a' validates syntax and
  reachability, but only a reboot validates ordering, dependencies and
  fsck passes. And when the entry describes a file-backed or removable
  volume, 'nofail' is the difference between a degraded service and a server
  that never comes back.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/104.3/lab)
