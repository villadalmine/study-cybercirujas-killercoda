## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
=== SOLUTION -- step by step. Do not read this until you have tried.         #
============================================================================ #

Throughout: substitute the real loop device printed by "$0 status" for
/dev/loopN, and $LAB for /var/tmp/lpic1-104.2-lab.

SCENARIO 1 -- destroyed ext4 superblock

Step 1. Confirm the primary superblock is unreadable and that the device is
        otherwise fine (this distinguishes "metadata gone" from "disk dying"):

    dumpe2fs -h /dev/loopN
        dumpe2fs: Bad magic number in super-block while trying to open /dev/loopN
        Couldn't find valid filesystem superblock.
    blkid /dev/loopN            # prints nothing: the signature is gone
    dd if=/dev/loopN bs=1M count=64 of=/dev/null   # reads fine: the media is OK

Step 2. Find the backup superblocks WITHOUT writing anything. mke2fs -n
        computes the layout mkfs WOULD produce and prints it:

    mke2fs -n -b 4096 /dev/loopN
        ...
        Superblock backups stored on blocks:
                32768, 98304

        The -b 4096 is essential: run without it and mke2fs picks the default
        block size for the device size, which yields DIFFERENT backup offsets
        and an e2fsck that fails with "Bad magic number in super-block".
        If mke2fs asks "Proceed anyway?", answering y is safe -- with -n it
        never writes. If you do not know the original block size, try 1024,
        2048 and 4096 in turn with the read-only probe in step 3.

Step 3. Probe a backup read-only before committing to it:

    dumpe2fs -o superblock=32768 -o blocksize=4096 /dev/loopN | head -n 30
        Filesystem volume name:   LAB1042SB
        Filesystem state:         clean
        Block size:               4096

Step 4. Repair from the backup. e2fsck rewrites the primary superblock and
        the group descriptor table from the redundant copy:

    e2fsck -b 32768 -B 4096 -y /dev/loopN
        e2fsck 1.47.x
        /dev/loopN was not cleanly unmounted, check forced.
        Pass 1: Checking inodes, blocks, and sizes
        Pass 2: Checking directory structure
        Pass 3: Checking directory connectivity
        Pass 4: Checking reference counts
        Pass 5: Checking group summary information
        /dev/loopN: ***** FILE SYSTEM WAS MODIFIED *****

        -b = backup superblock block number, -B = block size, -y = assume yes.
        Run it a second time until it exits 0 with no modifications; the exit
        code is a bitmask (1 = errors corrected, 2 = reboot needed, 4 = errors
        left uncorrected).

Step 5. Verify:

    mount /dev/loopN $LAB/mnt/s1
    cd $LAB/mnt/s1 && sha256sum -c $LAB/state/s1.sha256
        etc/canary.txt: OK
        srv/payroll/2026-08.csv: OK
        srv/payroll/archive.bin: OK

Production note: on a real disk the danger is picking the wrong device or the
wrong block size and then letting e2fsck -y "fix" a filesystem it is
misreading. Always dry-run first (e2fsck -fn -b 32768 -B 4096) and, when the
data matters, image the device with ddrescue before repairing.

SCENARIO 2 -- df full, du empty

Step 1. Prove the divergence (this is the diagnosis, not a formality):

    df -h  $LAB/mnt/s2      -> 79% used
    du -sh $LAB/mnt/s2      -> 20K

Step 2. Find open-but-unlinked files on that filesystem:

    lsof +L1 $LAB/mnt/s2
        COMMAND   PID USER  FD  TYPE DEVICE   SIZE/OFF NLINK   NODE NAME
        lab-appd 4213 root   9w  REG   7,1  314572800     0     12 .../var/log/app.log (deleted)

    Read the columns: NLINK 0 is the proof, FD 9w is the descriptor you need,
    PID 4213 is the culprit. Without lsof:

    find /proc/[0-9]*/fd -xtype l 2>/dev/null | while read -r l; do
        case "$(readlink "$l")" in */mnt/s2/*\ \(deleted\)) ls -l "$l";; esac
    done
    # or simply:  ls -l /proc/*/fd 2>/dev/null | grep 'deleted'

Step 3. Reclaim the space WITHOUT killing the daemon, by truncating through
        the descriptor. /proc/<pid>/fd/<n> refers to the same open file
        description, so this frees the blocks immediately:

    : > /proc/4213/fd/9          # or: truncate -s 0 /proc/4213/fd/9
    df -h $LAB/mnt/s2            # back to ~1% used, process still running

        Use "> file", never "rm", on a log a daemon holds open -- that is the
        whole reason logrotate has copytruncate and postrotate/kill -HUP.

Step 4. The blunt alternatives, and why they are worse:

    kill 4213            # works, but takes the service down
    systemctl restart X  # same, plus it is the reflex that hides the real bug
    umount / reboot      # frees everything and teaches you nothing

SCENARIO 3 -- inode exhaustion

Step 1. Ask the right question:

    df -h $LAB/mnt/s3
        /dev/loopN  119M  1.6M  108M   2% ...
    df -i $LAB/mnt/s3
        /dev/loopN  1024  1022     2  100% ...     <-- IUse% 100%

Step 2. Find who ate the inodes -- count entries per directory, not bytes:

    find $LAB/mnt/s3 -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head
        1005 /var/tmp/.../mnt/s3/var/spool/lab-mailq
           8 .../mnt/s3/srv/data

    -xdev keeps the search on this one filesystem, which is what you want on a
    real box with dozens of mounts.

Step 3. Free inodes by deleting the queue, not the data:

    find $LAB/mnt/s3/var/spool/lab-mailq -type f -name 'qf*.msg' -delete
    df -i $LAB/mnt/s3          # IUse% back to ~1%

    On a real spool, use "find ... -mtime +N -delete" and expect argument-list
    limits: "rm -f dir/*" fails with E2BIG at this scale, find -delete and
    "xargs -0 rm" do not.

Step 4. The permanent fix, which is a mkfs-time decision:

    tune2fs -l /dev/loopN | grep -i 'inode count'
        Inode count:              1024      <-- immutable for this fs size

    There is no tune2fs option to add inodes. You must recreate the
    filesystem with a smaller bytes-per-inode ratio:

    mkfs.ext4 -i 4096  /dev/loopN     # one inode per 4 KiB -> many small files
    mkfs.ext4 -N 65536 /dev/loopN     # or an absolute inode count
    mkfs.ext4 -T small /dev/loopN     # usage type from /etc/mke2fs.conf

    (resize2fs adds inodes only as a side effect of GROWING the filesystem.)
    XFS has no such limit: it allocates inodes dynamically, which is one of the
    standard arguments for XFS on mail and cache servers.

SCENARIO 4 -- unattached inode / lost+found

Step 1. Confirm the mismatch and get the inode number BEFORE repairing:

    du -sh $LAB/mnt/s4      -> 20K     (nothing visible)
    df -h  $LAB/mnt/s4      -> 6M used (blocks still allocated)

    umount $LAB/mnt/s4                      # NEVER e2fsck a mounted rw fs
    e2fsck -fn /dev/loopN                   # read-only dry run
        Pass 4: Checking reference counts
        Unattached inode 13
        Connect to /lost+found? no
        Inode 13 ref count is 1, should be 1.  Fix? no

    debugfs -R 'ncheck 13' /dev/loopN       # no path -> confirms it is orphaned
    debugfs -R 'stat <13>' /dev/loopN | head

Step 2a. Read-only rescue (preferred when you must not modify the volume --
         forensics, or a filesystem you have not imaged yet):

    debugfs -R 'dump <13> /tmp/report-2026.csv' /dev/loopN
    sha256sum /tmp/report-2026.csv          # matches the published hash

         Angle brackets mean "by inode number"; without them debugfs expects a
         path, which no longer exists.

Step 2b. Real repair -- e2fsck reconnects the orphan under lost+found, naming
         the file after its inode number:

    e2fsck -fy /dev/loopN
        Pass 4: Checking reference counts
        Unattached inode 13
        Connect to /lost+found? yes
        Inode 13 ref count is 1, should be 1.  Fix? yes
        /dev/loopN: ***** FILE SYSTEM WAS MODIFIED *****

    mount /dev/loopN $LAB/mnt/s4
    ls -l $LAB/mnt/s4/lost+found
        -rw-r--r-- 1 root root 6291533 Aug 26 09:12 #13
    sha256sum $LAB/mnt/s4/lost+found/\#13
    mv "$LAB/mnt/s4/lost+found/#13" $LAB/mnt/s4/finance/report-2026.csv

    lost+found is a preallocated directory at the root of every ext filesystem
    for exactly this: fsck has data with no name and needs somewhere to put it.
    The recovered names are inode numbers, so identification is on you -- file,
    strings, and known checksums are the tools.

Step 3 (side quest). Check policy:

    tune2fs -l /dev/loopN | grep -iE 'mount count|check interval|state'
        Mount count:              40
        Maximum mount count:      30       <-- exceeded: forces fsck at boot
        Check interval:           0 (<none>)

    tune2fs -c 0 -i 0 /dev/loopN     # disable count- and time-based checks
    tune2fs -c 30 -i 6m /dev/loopN   # or: every 30 mounts / 6 months

    Large production filesystems usually run -c 0 -i 0 because an unplanned
    multi-hour fsck at boot is a worse outage than the risk it mitigates; the
    journal plus monitoring plus scheduled offline checks replace it. Also
    know: dumpe2fs -h shows the same fields, and the sixth field of /etc/fstab
    (fs_passno) decides boot-check ORDER -- 1 for /, 2 for the rest, 0 to skip.

SCENARIO 5 -- XFS destroyed primary superblock

Step 1. Confirm and inspect read-only. Never run xfs_repair on a mounted fs;
        xfs_repair refuses, and forcing it corrupts the filesystem.

    mount /dev/loopN $LAB/mnt/s5
        mount: wrong fs type, bad option, bad superblock on /dev/loopN
    dmesg | tail -n3
        XFS (loopN): Invalid superblock magic number
    xfs_db -r -c 'sb 1' -c 'print' /dev/loopN | head
        magicnum = 0x58465342          <-- 'XFSB': AG 1's copy is intact

Step 2. Dry run. Read what it says about the secondary superblock scan:

    xfs_repair -n /dev/loopN
        Phase 1 - find and verify superblock...
        bad primary superblock - bad magic number !!!
        attempting to find secondary superblock...
        found candidate secondary superblock...
        verified secondary superblock...
        writing modified primary superblock       (suppressed by -n)
        ...
        No modify flag set, skipping filesystem flush and exiting.

Step 3. Repair for real:

    xfs_repair /dev/loopN
        Phase 1 - find and verify superblock...
        Phase 2 - using internal log
        Phase 3 - for each AG...
        Phase 4 - check for duplicate blocks...
        Phase 5 - rebuild AG headers and trees...
        Phase 6 - check inode connectivity...
        Phase 7 - verify and correct link counts...
        done

Step 4. Verify:

    mount /dev/loopN $LAB/mnt/s5
    xfs_info $LAB/mnt/s5                     # geometry readable again
    cd $LAB/mnt/s5 && sha256sum -c $LAB/state/s5.sha256
        srv/marker.txt: OK
        var/lib/containers/layer.tar: OK

Step 5. About -L, asked in interviews and on the exam:

    xfs_repair -L /dev/loopN

    -L zeroes the journal. Use it ONLY when repair stops with "ERROR: The
    filesystem has valuable metadata changes in a log which needs to be
    replayed" AND the log genuinely cannot be replayed (typically because the
    fs was created by a newer kernel or the log itself is damaged). The
    unreplayed transactions are lost: expect files in lost+found and zero-length
    files that used to have data. First try, in order: mount and unmount the
    filesystem cleanly on a matching kernel to replay the log; only then -L.

    Two more XFS facts on the 104.2 objective list:
      * fsck.xfs exists purely so that a non-zero fs_passno in /etc/fstab does
        not break the boot. It does nothing and exits 0.
      * xfs_fsr defragments a MOUNTED XFS ("filesystem reorganizer"):
            xfs_fsr -v /dev/loopN      # one filesystem
            xfs_fsr                    # every mounted XFS listed in mtab
        It is maintenance, not repair -- do not reach for it when a filesystem
        will not mount.

When finished:   ./lpic1-104.2-break-and-fix.sh cleanup

Sources:
  LPI Exam 101-500 objectives, topic 104.2 -- https://www.lpi.org/our-certifications/exam-101-objectives/
  e2fsck(8), mke2fs(8), tune2fs(8), dumpe2fs(8), debugfs(8), fsck(8) -- e2fsprogs
  xfs_repair(8), xfs_db(8), xfs_info(8), xfs_fsr(8) -- xfsprogs
  lsof(8), df(1), du(1), proc(5) ("/proc/[pid]/fd")
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/104.2/lab)
