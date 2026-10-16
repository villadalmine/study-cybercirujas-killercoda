## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION - STEP BY STEP
 Do not read this until 'verify' has beaten you at least twice.

STEP 0 - Establish which tools you can trust
  $ type -a find
  find is /usr/local/bin/find
  find is /usr/bin/find

  `type -a` (a shell builtin) lists EVERY match in PATH order, and also shows
  aliases and functions, which `which` cannot see. `which -a find` gives the
  same two paths here; `command -v find` gives only the winner. The winner is
  /usr/local/bin/find because /usr/local/bin precedes /usr/bin in PATH - which
  is exactly what /usr/local is for (FHS 4.9: locally installed software, kept
  separate from distribution files so upgrades never overwrite it).

  $ cat /usr/local/bin/find
  #!/bin/sh
  ... exit 0

  That is the fault: a stub that swallows every search. Remove it and refresh
  the shell's command hash table:

  $ sudo rm /usr/local/bin/find
  $ hash -r
  $ type -a find
  find is /usr/bin/find
  $ find /etc -maxdepth 1 -name hosts
  /etc/hosts

  Lesson: `command not found` and `command found but wrong` are different
  failures. Only the second one is silent.

STEP 1 - Find the misplaced program
  $ sudo find / -xdev -name 'hostinv*' -print 2>/dev/null
  /opt/hostinv-1.4/pkg/usr/local/bin/hostinv
  /opt/hostinv-1.4/pkg/usr/local/share/man/man8/hostinv.8
  /opt/hostinv-1.4/pkg/usr/share/doc/hostinv
  /srv/pkgcache/hostinv-0.9/hostinv
  /usr/bin/hostinv.conf
  /etc/hostinv-state.db

  -xdev keeps the search on one filesystem (no /proc, /sys, no NFS mounts);
  2>/dev/null drops the permission-denied noise. Two candidate binaries:

  $ find / -xdev -name hostinv -type f -ls 2>/dev/null
  ... rw-r--r-- ... /opt/hostinv-1.4/pkg/usr/local/bin/hostinv
  ... rwxr-xr-x ... 2019 ... /srv/pkgcache/hostinv-0.9/hostinv

  Both are plausible; only one is 1.4. Ways to tell them apart, all in scope
  for this objective:
      find / -xdev -name hostinv -type f ! -perm -u+x      # the uninstalled one
      find / -xdev -name hostinv -newermt '2020-01-01'     # by modification time
      find /srv /opt -name hostinv -type f -exec sh {} --version \;
  The /srv copy is version 0.9 (FHS 3.16: /srv is data served by this system,
  not a place to install programs). The /opt tree is an unpacked vendor
  package (FHS 3.13: add-on application software packages).

STEP 2 - Place the binary where the FHS says it goes
  A locally installed, hand-managed binary belongs in /usr/local/bin
  (FHS 4.9.1). Not /usr/bin - that is owned by the distribution's package
  manager. Not /bin or /sbin - those are for binaries needed before /usr is
  available (FHS 3.4, 3.5).

  $ sudo install -m 0755 -o root -g root \
        /opt/hostinv-1.4/pkg/usr/local/bin/hostinv /usr/local/bin/hostinv
  $ hash -r
  $ command -v hostinv
  /usr/local/bin/hostinv
  $ hostinv --version
  hostinv 1.4

  `install` sets mode and ownership in one step; `cp` + `chmod 0755` is
  equally valid. Verify the resolution order once more with `type -a hostinv`
  so the 0.9 copy is not shadowing anything.

STEP 3 - Move the scattered files to their FHS directories
  $ hostinv
  hostinv: cannot read configuration: /etc/hostinv/hostinv.conf
  hostinv: state database missing or empty: /var/lib/hostinv/state.db
  hostinv: log directory missing: /var/log/hostinv
  hostinv: FHS layout incomplete, refusing to run

  Three rules, three destinations:
    /etc      host-specific static CONFIGURATION, no binaries      (FHS 3.7)
    /var/lib  variable STATE that must persist across reboots      (FHS 5.8)
    /var/log  log files                                            (FHS 5.10)
  And the corollary: /usr/bin holds executables only - a .conf file there is
  wrong even if it works, because /usr must be shareable and read-only
  (FHS 4.1).

  $ sudo install -d -m 0755 /etc/hostinv /var/lib/hostinv /var/log/hostinv
  $ sudo mv /usr/bin/hostinv.conf   /etc/hostinv/hostinv.conf
  $ sudo mv /etc/hostinv-state.db   /var/lib/hostinv/state.db
  $ sudo chmod 0644 /etc/hostinv/hostinv.conf /var/lib/hostinv/state.db
  $ hostinv
  hostinv: OK (version=1.4 profile=lab-104-7 entries=4)

  Use mv, not cp: a copy leaves the misplaced original behind, and the next
  administrator will edit the wrong one. Confirm nothing is left:
  $ sudo find /usr /etc -xdev -name 'hostinv*' -maxdepth 2

STEP 4 - Repair locate: the configuration, then the database
  $ locate hostinv
  (nothing)

  locate never touches the filesystem; it reads an index built by updatedb
  (/var/lib/mlocate/mlocate.db, or /var/lib/plocate/plocate.db). Two failure
  modes exist and you must distinguish them: a STALE index, or an index built
  from a sabotaged configuration. Read the configuration first:

  $ cat /etc/updatedb.conf
  PRUNEFS="... ext2 ext3 ext4 xfs btrfs"
  PRUNEPATHS="/tmp /var/spool /media ... /home /srv /opt /usr/local /etc"

  Both lines are wrong. PRUNEFS listing the local filesystem types excludes
  essentially the whole disk; PRUNEPATHS excludes exactly the directories this
  task cares about. See updatedb.conf(5). A sane file:

  $ sudo cp /etc/updatedb.conf /etc/updatedb.conf.bak
  $ sudo tee /etc/updatedb.conf >/dev/null <<'EOF'
  PRUNE_BIND_MOUNTS="yes"
  PRUNENAMES=".git .bzr .hg .svn"
  PRUNEFS="NFS nfs nfs4 afs binfmt_misc proc smbfs autofs iso9660 ncpfs coda devpts ftpfs devfs mfs shfs sysfs cifs lustre tmpfs usbfs udf fuse.glusterfs fuse.sshfs curlftpfs ecryptfs fusesmb devtmpfs"
  PRUNEPATHS="/tmp /var/spool /media /var/lib/os-prober /var/lib/ceph"
  EOF
  $ sudo updatedb
  $ locate hostinv
  /etc/hostinv/hostinv.conf
  /usr/local/bin/hostinv
  ...

  Notes worth remembering for the exam:
    - updatedb must run as root to index directories it cannot otherwise read;
      mlocate stores permissions in the db so unprivileged locate does not leak
      paths users cannot see.
    - The index is refreshed by a cron job or systemd timer
      (updatedb.timer / /etc/cron.daily/mlocate). A file created one minute ago
      is invisible to locate until the next run - that is not a bug.
    - Useful flags: locate -i (case-insensitive), -b '\name' (basename, exact),
      -r/--regex, -c (count), -e (only existing files, mlocate), -l N (limit).
    - When you need current truth, use find. When you need speed over a whole
      filesystem, use locate and accept the lag.

STEP 5 - Documentation (extra credit)
  Local man pages go under /usr/local/share/man/manN (FHS 4.11), mirroring
  /usr/share/man for distribution pages. Section 8 = system administration.

  $ sudo install -d -m 0755 /usr/local/share/man/man8
  $ sudo install -m 0644 \
        /opt/hostinv-1.4/pkg/usr/local/share/man/man8/hostinv.8 \
        /usr/local/share/man/man8/hostinv.8
  $ sudo mandb -q            # Debian/SUSE; on RHEL the cache rebuilds via mandb too
  $ man -w hostinv
  /usr/local/share/man/man8/hostinv.8
  $ whereis hostinv
  hostinv: /usr/local/bin/hostinv /usr/local/share/man/man8/hostinv.8

  whereis only searches a compiled-in list of standard binary, source and man
  directories (see `whereis -l`), which is why correct placement is what makes
  it work. That is the whole point of objective 104.7: the FHS is not
  bureaucracy, it is the contract the tools rely on.

STEP 6 - Grade yourself
  $ sudo ./104.7-break-and-fix.sh verify

  Optional cleanup of the lab leftovers, once verify passes:
  $ sudo rm -rf /opt/hostinv-1.4 /srv/pkgcache && sudo updatedb
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/104.7/lab)
