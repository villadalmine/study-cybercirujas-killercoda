## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
  "Temporary failure in name resolution".

    cat /etc/resolv.conf
    ls -l /etc/resolv.conf         # a symlink? then something else owns it

  The file is a plain list of directives read by the glibc stub resolver:
    nameserver <ip>     up to three, tried in order
    search <domain...>  suffixes appended to unqualified names
    domain <domain>     legacy single-suffix form
    options timeout:2 attempts:2 ndots:1
  (man 5 resolv.conf)

  2a. If it is an immutable file (LAB_HARD mode):
        lsattr /etc/resolv.conf        # shows ----i---------
        chattr -i /etc/resolv.conf

  2b. Who owns it? Three common answers:

      * Nobody -- a real file you may edit directly:
          printf 'nameserver 192.168.122.1\nnameserver 1.1.1.1\n' > /etc/resolv.conf

      * NetworkManager -- it rewrites the file from the active profile.
        Editing by hand is undone on the next connection change. Fix the
        profile instead:
          nmcli con mod "$CON" ipv4.dns "192.168.122.1 1.1.1.1"
          nmcli con mod "$CON" ipv4.ignore-auto-dns no    # or 'yes' + explicit dns
          nmcli con up "$CON"

      * systemd-resolved -- /etc/resolv.conf is a symlink to
        /run/systemd/resolve/stub-resolv.conf and points at 127.0.0.53.
        The real setting is elsewhere:
          resolvectl status                       # per-link DNS servers
          $EDITOR /etc/systemd/resolved.conf      # [Resolve] DNS= / FallbackDNS=
          systemctl restart systemd-resolved
          resolvectl query deb.debian.org
          resolvectl flush-caches                 # a stale negative cache lies to you
        If the lab poisoned resolved.conf, set DNS= back to your real resolver
        (or comment it out entirely so the per-link DHCP servers are used),
        and restore the symlink if you deleted it:
          ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

  Checkpoint:
      getent ahostsv4 deb.debian.org
      dig +short deb.debian.org          # or: host deb.debian.org

STEP 3 -- The name service switch: /etc/nsswitch.conf

  Symptom that gives this one away: you add a line to /etc/hosts and it has
  no effect whatsoever -- and `getent hosts localhost` also returns nothing.

    grep ^hosts: /etc/nsswitch.conf
    hosts:          dns                <-- the fault: /etc/hosts is never read

  Restore the normal order, files first:

    hosts:          files dns

  or, on a systemd box that also wants mDNS and the magic self-name module:

    hosts:          files mymachines myhostname resolve [!UNAVAIL=return] dns

  No daemon restart is needed -- nsswitch.conf is consulted by the glibc
  NSS machinery per lookup -- but long-lived processes may have cached the
  old configuration, so re-test in a fresh shell.  (man 5 nsswitch.conf)

  Note `myhostname`: that NSS module resolves the local hostname without any
  /etc/hosts entry, which is why some distributions survive step 4 by
  accident. Do not rely on it in the exam; LPI expects the /etc/hosts entry.

  Checkpoint:
      getent hosts localhost         # must print 127.0.0.1 localhost

STEP 4 -- Identity: /etc/hostname and /etc/hosts

  Symptom: `sudo: unable to resolve host broken-node: Name or service not
  known`, plus a multi-second pause on every sudo (that pause is the DNS
  timeout for a name that only exists locally).

  4a. Persistent hostname. Two equivalent routes:

        hostnamectl set-hostname lab-vm01        # systemd: writes /etc/hostname
                                                 # AND sets the running name
      or the portable pair:
        echo 'lab-vm01' > /etc/hostname          # persistent, read at boot
        hostname lab-vm01                        # runtime, immediate

      `hostname lab-vm01` alone is the trap: correct now, gone after reboot.
      `echo > /etc/hostname` alone is the mirror trap: correct after reboot,
      still broken now. hostnamectl does both, which is why it is preferred.

        hostnamectl status        # static / transient / pretty hostname

  4b. Map the name to a local address, so lookups never leave the box:

        cat /etc/hosts
        127.0.0.1       localhost
        127.0.1.1       lab-vm01.example.lan lab-vm01
        ::1             localhost ip6-localhost ip6-loopback

      Format: <address> <canonical-name> [aliases...]  (man 5 hosts)
      Debian convention is 127.0.1.1 for the machine's own name; RHEL puts
      the name on the 127.0.0.1 line or on the real LAN address. Either is
      accepted -- what matters is that the running hostname resolves.

  Checkpoint:
      hostname; cat /etc/hostname          # must agree
      getent hosts "$(hostname)"           # must return an address
      sudo true                            # must be instant, no warning

STEP 5 -- Prove persistence. This is the graded part.

    sudo /path/to/this-script.sh verify     # runs a simulated reboot
    sudo reboot
    # after it comes back:
    ip -4 -br addr ; ip route ; hostname ; getent hosts deb.debian.org
    sudo /path/to/this-script.sh verify

  If something reverts across the reboot, the fix went into runtime state.
  Map each symptom back to its persistent home:

    address / route revert  -> profile or unit file, and whether it is set to
                               auto-start (NM connection.autoconnect,
                               ifupdown `auto`, networkd unit present & matching)
    hostname reverts        -> /etc/hostname (or hostnamectl, which writes it)
    resolv.conf reverts     -> it is generated: fix the generator
                               (NM ipv4.dns / systemd-resolved DNS=), not the file
    /etc/hosts ignored      -> /etc/nsswitch.conf hosts: line

Command reference for this objective

  Runtime   : ip link | ip addr | ip route | ip neigh, hostname,
              ifconfig / route / arp (deprecated net-tools, still examinable)
  Persistent: /etc/hostname, /etc/hosts, /etc/nsswitch.conf, /etc/resolv.conf,
              /etc/network/interfaces(.d), /etc/systemd/network/*.network,
              /etc/NetworkManager/system-connections/*, /etc/netplan/*.yaml
  Tools     : hostnamectl, nmcli, nmtui, networkctl, resolvectl, netplan,
              ifup / ifdown, dhclient, getent, host, dig
  Read      : man 5 hosts, man 5 resolv.conf, man 5 nsswitch.conf,
              man 5 interfaces, man 5 systemd.network, man 1 nmcli,
              man 1 hostnamectl, man 8 ip

Sources
  LPI Exam 101-500 objectives -- https://www.lpi.org/our-certifications/exam-101-objectives/
  LPI Exam 102-500 objectives -- https://www.lpi.org/our-certifications/exam-102-objectives/
  systemd.network(5)          -- https://www.freedesktop.org/software/systemd/man/systemd.network.html
  systemd-resolved(8)         -- https://www.freedesktop.org/software/systemd/man/systemd-resolved.service.html
  hostnamectl(1)              -- https://www.freedesktop.org/software/systemd/man/hostnamectl.html
  nmcli(1)                    -- https://networkmanager.dev/docs/api/latest/nmcli.html
  NetworkManager settings     -- https://networkmanager.dev/docs/api/latest/nm-settings-nmcli.html
  interfaces(5), Debian       -- https://manpages.debian.org/stable/ifupdown/interfaces.5.en.html
  Netplan reference           -- https://netplan.readthedocs.io/en/stable/netplan-yaml/
  RFC 5737, reserved test IPv4 -- https://www.rfc-editor.org/rfc/rfc5737
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/109.2/lab)
