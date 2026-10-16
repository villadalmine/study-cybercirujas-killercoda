## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
=========================== SOLUTION ========================================

Everything below is commented out. Read it only after you have tried.

ORDER MATTERS
dpkg's half-configured package (fault 3) blocks apt from doing anything else,
and fault 4's repair needs a working archive (fault 1). So the sane order is:

  3 (unblock dpkg) -> 1 (fix sources) -> 2 (remove the pin) -> 4 (reinstall)

FAULT 3 — the half-configured package

  # 1. Confirm the state. The two-letter code is desired-action + current
  #    status: 'iF' = desired install, status Half-configured.
  dpkg -l lpi-lab-victim
  #  Desired=Unknown/Install/Remove/Purge/Hold
  #  | Status=Not/Inst/Conf-files/Unpacked/halF-conf/Half-inst/trig-aWait/Trig-pend
  #  ||/ Name             Version   Architecture Description
  #  +++-================-=========-============-=========================
  #  iF  lpi-lab-victim   1.0       all          LPIC-1 102.4 lab victim package

  # `dpkg --audit` lists every package in a broken state, which is the
  # command to reach for when you do not already know the package name:
  dpkg --audit

  # 2. Reproduce the failure and READ the error. dpkg prints the maintainer
  #    script's own stderr:
  dpkg --configure -a
  #  Setting up lpi-lab-victim (1.0) ...
  #  lpi-lab-victim: configuration blocked by /etc/lpi-lab-victim.block
  #  lpi-lab-victim: remove that file and re-run 'dpkg --configure -a'
  #  dpkg: error processing package lpi-lab-victim (--configure):
  #   installed lpi-lab-victim package post-installation script subprocess
  #   returned error exit status 1

  # 3. Inspect the script yourself. Maintainer scripts are unpacked into
  #    /var/lib/dpkg/info/<package>.<script>:
  ls -l /var/lib/dpkg/info/lpi-lab-victim.*
  cat /var/lib/dpkg/info/lpi-lab-victim.postinst

  # 4. Remove the cause and finish the configuration:
  rm -f /etc/lpi-lab-victim.block
  dpkg --configure -a
  #  Setting up lpi-lab-victim (1.0) ...
  #  lpi-lab-victim: configured successfully.

  dpkg -l lpi-lab-victim | tail -n1
  #  ii  lpi-lab-victim   1.0  all  LPIC-1 102.4 lab victim package

  # Alternative (accepted, but inferior): remove the package outright.
  #   dpkg --remove --force-remove-reinstreq lpi-lab-victim
  #   dpkg --purge lpi-lab-victim
  # Note that `dpkg --remove` runs prerm, which may also fail; --purge
  # additionally deletes the conffiles that --remove leaves behind. Reaching
  # for --force-* before reading the error is the habit this lab is training
  # you out of.

FAULT 1 — the broken sources

  # 1. See the failure:
  apt-get update
  #  Err:3 http://mirror.lpi-lab.invalid/debian stable InRelease
  #    Temporary failure resolving 'mirror.lpi-lab.invalid'
  #  E: Malformed entry 2 in list file /etc/apt/sources.list.d/lpi-lab-mirror.list (Suite)
  #  E: The list of sources could not be read.

  # 2. APT reads /etc/apt/sources.list AND every *.list in
  #    /etc/apt/sources.list.d/ (plus *.sources in deb822 format on newer
  #    releases). Enumerate all of them — the offending file is named in the
  #    error, but learn to list them anyway:
  ls -l /etc/apt/sources.list.d/
  cat /etc/apt/sources.list.d/lpi-lab-mirror.list
  grep -rE '^\s*deb' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null

  # 3. Understand the syntax (man 5 sources.list):
  #      deb [ options ] uri distribution [component1] [component2] ...
  #    The second line in the lab file has a URI and nothing else — no
  #    distribution, no components — hence "Malformed entry ... (Suite)".
  #    The first line is syntactically valid but points at a host that does
  #    not exist; .invalid is reserved by RFC 2606 precisely for this.

  # 4. The correct repair is to delete the file the lab added, since neither
  #    line contributes anything real:
  rm -f /etc/apt/sources.list.d/lpi-lab-mirror.list
  apt-get update
  echo "exit status: $?"     # must be 0

  # If instead you wanted to keep a valid entry, it would look like this on
  # Debian 12 (bookworm):
  #   deb http://deb.debian.org/debian bookworm main contrib non-free-firmware
  # or, on Ubuntu 22.04:
  #   deb http://archive.ubuntu.com/ubuntu jammy main restricted universe multiverse
  # Disabling rather than deleting is also legitimate — comment the lines out
  # with '#', or rename the file so it no longer ends in .list:
  #   mv lpi-lab-mirror.list lpi-lab-mirror.list.disabled

  # 5. Confirm which repositories APT now trusts and their priorities:
  apt-cache policy

FAULT 2 — the pin and the hold

  # 1. See the symptom:
  apt-cache policy tree
  #  tree:
  #    Installed: (none)
  #    Candidate: (none)
  #    Version table:
  #       2.1.0-1 -1
  #          500 http://deb.debian.org/debian bookworm/main amd64 Packages
  #
  #    Candidate "(none)" with a version listed at priority -1 is the
  #    signature of a pin. Any priority < 0 means "never install this".

  # 2. Find where the pin comes from. APT reads /etc/apt/preferences and
  #    every file in /etc/apt/preferences.d/:
  ls -l /etc/apt/preferences.d/
  cat /etc/apt/preferences.d/99-lpi-lab-pin
  #  Package: tree
  #  Pin: release *
  #  Pin-Priority: -1

  # 3. Remove it (or edit the priority to a sane value):
  rm -f /etc/apt/preferences.d/99-lpi-lab-pin
  apt-cache policy tree
  #  Candidate: 2.1.0-1        <- back to the archive priority, 500

  #    Priority reference (man 5 apt_preferences):
  #      < 0     never install
  #      1-99    install only if nothing of the package is installed
  #      100-499 install unless a version from a higher-priority source exists
  #      500     the default for a normal archive
  #      990     the default for the target release (-t / APT::Default-Release)
  #      > 1000  install even if it means downgrading

  # 4. The second half of this fault is a dpkg-level hold, which is a
  #    different mechanism from pinning and lives in dpkg's own database:
  apt-mark showhold
  #  hostname
  apt-mark unhold hostname
  #  Canceled hold on hostname.
  apt-mark showhold          # now prints nothing

  #    Equivalent, lower-level forms worth knowing for the exam:
  #      echo "hostname hold"    | dpkg --set-selections
  #      echo "hostname install" | dpkg --set-selections
  #      dpkg --get-selections | grep -w hold

FAULT 4 — the missing packaged file

  # 1. Find it. `dpkg --verify` (short: dpkg -V) compares the md5sums dpkg
  #    recorded at unpack time against what is on disk:
  dpkg --verify
  #  missing     /usr/share/doc/hostname/copyright
  #
  #    The flag field is 9 characters, in the style of rpm -V:
  #      ??5?????? c /path    -> checksum differs, and it is a conffile
  #      missing     /path    -> the file is not there at all
  #    Only md5sum ('5') is actually implemented by dpkg today; the other
  #    positions are placeholders. `debsums -c` gives a second opinion when
  #    the debsums package is installed.

  # 2. Establish which package owns it — never guess from the path:
  dpkg -S /usr/share/doc/hostname/copyright
  #  hostname: /usr/share/doc/hostname/copyright

  #    And the reverse, to see everything that package shipped:
  dpkg -L hostname

  # 3. Restore it FROM THE PACKAGE. This requires a working archive, which is
  #    why faults 1 and 2 had to be fixed first:
  apt-get update
  apt-get install --reinstall hostname
  #  ...
  #  Preparing to unpack .../hostname_3.23+nmu1_amd64.deb ...
  #  Unpacking hostname (3.23+nmu1) over (3.23+nmu1) ...
  #  Setting up hostname (3.23+nmu1) ...

  # 4. Verify the repair:
  dpkg --verify hostname     # prints nothing == clean
  ls -l /usr/share/doc/hostname/copyright

  # If the machine has no network at all, the offline equivalent is to fetch
  # the .deb (or find it in /var/cache/apt/archives/) and unpack it by hand:
  #   apt-get download hostname
  #   dpkg -i ./hostname_*.deb                 # full reinstall
  #   # or extract a single file without touching the dpkg database:
  #   dpkg-deb -x ./hostname_*.deb /tmp/x && \
  #     cp /tmp/x/usr/share/doc/hostname/copyright /usr/share/doc/hostname/
  #   # inspect a .deb without installing:
  #   dpkg-deb -c ./hostname_*.deb     # contents
  #   dpkg-deb -I ./hostname_*.deb     # control information
  #   dpkg-deb -e ./hostname_*.deb /tmp/ctrl   # extract maintainer scripts
  #
  #   Creating an empty file with touch would silence `ls` but NOT
  #   `dpkg --verify` — the md5sum still would not match. The grader checks
  #   for exactly that shortcut.

FINAL VERIFICATION — the state a healthy Debian box should be in

  apt-get update            && echo "sources OK"
  apt-get check             && echo "dependencies OK"   # parses the db, verifies deps
  dpkg --audit              # prints nothing when no package is in a broken state
  dpkg --configure -a       # no-op when nothing is pending
  apt-mark showhold         # empty
  dpkg --verify             # empty
  apt-get -f install        # "0 upgraded, 0 newly installed, 0 to remove"

  # Then grade yourself:
  sudo ./102.4-break-and-fix.sh check

WHAT THIS MAPS TO IN THE 102.4 OBJECTIVE

  /etc/apt/sources.list, /etc/apt/sources.list.d/  -> faults 1
  /etc/apt/preferences.d/, apt-mark, dpkg holds    -> fault 2
  dpkg, dpkg-deb, /var/lib/dpkg/, maintainer scripts, --configure -> fault 3
  dpkg -S / -L / --verify, apt-get --reinstall, apt-cache -> fault 4

  Command inventory exercised here, all of it examinable:
    dpkg -i -l -L -S -s -V -r -P --configure --audit --get-selections
         --set-selections --force-*
    dpkg-deb -b -c -e -I -x
    dpkg-query -W -L -S -f
    apt-get update / install / --reinstall / -f install / check / download
    apt-cache policy / show / showpkg / depends / rdepends / search
    apt-mark hold / unhold / showhold / auto / manual
    apt-file search / list                (needs `apt-file update` first)

  Sources:
    LPI Exam 101/102 Objectives — https://www.lpi.org/our-certifications/exam-101-objectives/
    Debian Administrator's Handbook, ch. 5 "Packaging System" and ch. 6 "Maintenance
      and Updates: The APT Tools" — https://www.debian.org/doc/manuals/debian-handbook/
    Debian Policy Manual, ch. 6 "Package maintainer scripts and installation
      procedure" — https://www.debian.org/doc/debian-policy/ch-maintainerscripts.html
    man 1 dpkg, man 1 dpkg-deb, man 1 dpkg-query, man 8 apt-get,
    man 8 apt-cache, man 8 apt-mark, man 5 sources.list, man 5 apt_preferences

========================= END SOLUTION ======================================
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/102.4/lab)
