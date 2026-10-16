## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
  SOLUTION — do not read until you have genuinely tried, or until `verify`
  has stopped teaching you anything. Everything below is commented out.


 STEP 0 — Establish the boundary: is this network, or is this resolution?

   ip -4 addr show
   ip -4 route show default
   ping -c2 "$(ip -4 route show default | awk '{print $3; exit}')"

 Expected: the interface has an address, a default route exists, the gateway
 replies. Layer 3 is healthy. Therefore the fault is at or above the resolver.
 Never skip this step in production — half of all "DNS is down" tickets are
 actually a dead link, and the two are fixed by different teams.

   ping -c1 -W2 1.1.1.1

 If a raw IP on the internet answers but a name does not, the diagnosis is
 now certain: client-side DNS.

 STEP 1 — Read the resolution path in the order the C library reads it

 glibc resolves hostnames through NSS. The order is declared in
 /etc/nsswitch.conf, NOT in /etc/resolv.conf. Look there FIRST:

   grep -E '^\s*hosts:' /etc/nsswitch.conf

 Broken state:

   hosts:      dns

 The `files` source is gone, so glibc never opens /etc/hosts at all. This is
 precisely why `grep app.lab.example /etc/hosts` shows the entry while
 `getent hosts app.lab.example` returns nothing: grep reads a text file,
 getent walks NSS.

 Prove it without guessing:

   strace -f -e trace=openat getent hosts app.lab.example 2>&1 | grep -E 'hosts|resolv'

 You will see /etc/nsswitch.conf and /etc/resolv.conf opened, and /etc/hosts
 NOT opened. That single strace line is the whole diagnosis.

 Fix — restore `files` ahead of `dns`, since a static entry must win over the
 network:

   cp -a /etc/nsswitch.conf /etc/nsswitch.conf.bak
   sed -i -E 's/^\s*hosts:.*/hosts:      files dns myhostname/' /etc/nsswitch.conf
   grep -E '^\s*hosts:' /etc/nsswitch.conf

 On a systemd host the canonical line is typically:

   hosts: mymachines resolve [!UNAVAIL=return] files myhostname dns

 Either is acceptable for this lab as long as `files` is present and precedes
 `dns`. Note there is NO daemon to restart: glibc re-reads nsswitch.conf per
 process. Long-running services that already cached a negative answer may
 still need a restart — that is nscd/sssd behaviour, not NSS.

 Verify immediately:

   getent hosts app.lab.example
   198.51.100.9    app.lab.example app

 It resolves now — to the WRONG address. Two faults were stacked. Continue.

 STEP 2 — Correct the static entry, defeating the immutable attribute

 Attempting the obvious edit fails, even as root:

   echo "" >> /etc/hosts
   bash: /etc/hosts: Operation not permitted

 Root being refused a write is a strong signal: it is not permission bits,
 it is a file attribute or a read-only mount. Check both:

   ls -l /etc/hosts        # 0644 root:root — permissions are fine
   lsattr -d /etc/hosts    # ----i---------e------- /etc/hosts
   findmnt -no OPTIONS /   # rw,... — the filesystem is writable

 The `i` is the immutable attribute (see man 1 chattr). Clear it:

   chattr -i /etc/hosts
   lsattr -d /etc/hosts    # the 'i' is gone

 Now correct the address. app.lab.example must be 203.0.113.42:

   sed -i -E 's/^198\.51\.100\.9[[:space:]]+app\.lab\.example.*/203.0.113.42\tapp.lab.example\tapp/' /etc/hosts

 Or edit by hand. The required end state is one line of the form:

   203.0.113.42    app.lab.example app

 Remember the /etc/hosts field order (man 5 hosts): IP first, then the
 canonical name, then any aliases. Reversing IP and name is a classic exam
 trap and produces a file that parses but resolves nothing.

   getent hosts app.lab.example
   203.0.113.42    app.lab.example app

 Note that `ping app.lab.example` may now report unreachable — 203.0.113.0/24
 is TEST-NET-3 and is not routable. That is correct and expected: the name
 RESOLVED, which is the objective. Resolution and reachability are separate
 concerns, and conflating them is another common misdiagnosis.

 STEP 3 — Repair the DNS resolver configuration

   cat /etc/resolv.conf

 Broken state:

   search corp.invalid lab.invalid
   options ndots:5 timeout:5 attempts:3
   nameserver 198.51.100.253
   nameserver 198.51.100.254

 Three separate defects, each worth understanding (man 5 resolv.conf):

  a) nameserver 198.51.100.x — TEST-NET-2, guaranteed unroutable. Every query
     is sent into a black hole.

  b) timeout:5 attempts:3 with two dead servers — the resolver waits 5s per
     server per attempt: 5 x 2 x 3 = 30 seconds before it gives up. THAT is
     the long hang. Default is timeout:5 attempts:2, and the practical cap is
     RES_MAXRETRANS; the lesson is that dead servers cost wall-clock time,
     which is why you list a reachable resolver FIRST and keep the list short.
     Note also that glibc honours a maximum of 3 nameserver lines (MAXNS) —
     a fourth is silently ignored, another classic exam detail.

  c) search corp.invalid lab.invalid + ndots:5 — any name with fewer than 5
     dots is first tried with each search domain appended. So `www.lpi.org`
     (2 dots) is queried as www.lpi.org.corp.invalid, then
     www.lpi.org.lab.invalid, and only then as www.lpi.org. Three times the
     queries, three times the latency, and if a wildcard existed in those
     zones you would silently reach the WRONG host. This is the single most
     under-appreciated line in resolv.conf.

 Confirm the nameserver is the problem before rewriting anything, by asking a
 known-good server directly and bypassing /etc/resolv.conf entirely:

   dig +short @1.1.1.1 www.lpi.org
   dig +short +timeout=2 +tries=1 @198.51.100.253 www.lpi.org   # times out

 If the first works and the second times out, the configured nameserver is
 the fault — not the network, not the zone.

 Write a correct file. Substitute the resolver your site actually uses; on a
 home or lab LAN that is usually the default gateway:

   cat > /etc/resolv.conf <<'EOF'
   # Site resolver — restored 109.4
   nameserver 1.1.1.1
   nameserver 9.9.9.9
   options timeout:2 attempts:2
   EOF

 Deliberately omitted: the `search` line (nothing here needs one) and any
 `ndots` override (the default of 1 is right for almost everyone). If your
 environment does need a search domain, one real domain is enough:

   search example.com

 Verify, and watch the clock:

   time getent hosts www.lpi.org
   time host www.lpi.org
   dig www.lpi.org +noall +answer

 Sub-second answers. If it is still slow, a dead nameserver line survived.

 STEP 4 — Make the fix survive a reboot (the part everyone forgets)

 On most current distributions /etc/resolv.conf is NOT a configuration file
 you own — it is generated. Find out who owns it before congratulating
 yourself:

   ls -l /etc/resolv.conf
   systemctl is-enabled systemd-resolved NetworkManager 2>/dev/null
   resolvectl status

 Three common regimes:

  * systemd-resolved: /etc/resolv.conf is a symlink to
    /run/systemd/resolve/stub-resolv.conf and contains `nameserver 127.0.0.53`.
    The real upstream servers are set per-link. Configure them properly:

      resolvectl dns eth0 1.1.1.1 9.9.9.9
      resolvectl domain eth0 '~.'
      # persistent form: /etc/systemd/resolved.conf -> [Resolve] DNS=1.1.1.1
      systemctl restart systemd-resolved
      resolvectl status
      resolvectl query www.lpi.org
      resolvectl flush-caches        # invalidate a poisoned negative cache

    and restore the symlink so the stub is used again:

      ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

  * NetworkManager: it rewrites /etc/resolv.conf from the connection profile.
    Set it on the connection, not on the file:

      nmcli con mod "$CONN" ipv4.dns "1.1.1.1 9.9.9.9"
      nmcli con mod "$CONN" ipv4.ignore-auto-dns yes
      nmcli con up "$CONN"

  * DHCP client (dhclient/dhcpcd) or static /etc/network/interfaces:
    supersede the offered servers, e.g. in /etc/dhcp/dhclient.conf:

      supersede domain-name-servers 1.1.1.1, 9.9.9.9;

 Hand-editing /etc/resolv.conf under any of these is a temporary fix that
 silently reverts on the next lease renewal, link event or reboot. Knowing
 WHO writes the file is the difference between resolving an incident and
 resolving it again tomorrow.

 STEP 5 — Final verification against the objective's checklist

   getent hosts app.lab.example      # 203.0.113.42
   getent hosts www.lpi.org          # a real address
   time host www.lpi.org             # well under 2 seconds
   lsattr -d /etc/hosts              # no 'i'
   grep -E '^\s*hosts:' /etc/nsswitch.conf   # contains 'files' before 'dns'
   grep -E 'search|ndots' /etc/resolv.conf   # nothing bogus

   sudo ./this-script verify         # all checks pass

 WHAT THIS LAB TEACHES, CONDENSED

  1. /etc/nsswitch.conf decides the ORDER of sources; /etc/resolv.conf only
     configures the `dns` source. If `files` is missing, /etc/hosts is dead
     weight no matter how correct its contents are.

  2. `dig` and `host` speak DNS directly and IGNORE /etc/hosts and NSS.
     `getent hosts` walks the same path a real application does. When they
     disagree, the disagreement localises the fault:
        dig works, getent fails      -> NSS layer (nsswitch, files, caches)
        dig fails, getent works      -> the answer came from files or a cache
        both fail                    -> resolver config or upstream server

  3. Slow failure means dead servers plus timeout x attempts x server-count.
     Fast failure means no server configured, or NXDOMAIN. The latency of a
     failure is diagnostic data, not noise.

  4. `search` + `ndots` silently rewrite the names you asked for. Audit them
     whenever a short name resolves to something surprising — this is the
     root cause behind a large share of Kubernetes DNS latency incidents too.

  5. Root being denied a write means attributes (chattr/lsattr) or a
     read-only mount, never permission bits alone.

  6. Editing a generated file is not a fix. Identify the owner —
     systemd-resolved, NetworkManager, or the DHCP client — and configure it
     there.

 OFFICIAL SOURCES

  LPI Exam 102-500 Objectives, topic 109.4 "Configure client side DNS"
    https://www.lpi.org/our-certifications/exam-102-objectives/
  LPI Exam 101-500 Objectives
    https://www.lpi.org/our-certifications/exam-101-objectives/
  resolv.conf(5)   https://man7.org/linux/man-pages/man5/resolv.conf.5.html
  hosts(5)         https://man7.org/linux/man-pages/man5/hosts.5.html
  nsswitch.conf(5) https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html
  getent(1)        https://man7.org/linux/man-pages/man1/getent.1.html
  chattr(1)        https://man7.org/linux/man-pages/man1/chattr.1.html
  systemd-resolved(8)
    https://www.freedesktop.org/software/systemd/man/latest/systemd-resolved.html
  resolvectl(1)
    https://www.freedesktop.org/software/systemd/man/latest/resolvectl.html
  BIND 9 dig(1)    https://bind9.readthedocs.io/en/latest/manpages.html#dig
  RFC 2606 — Reserved Top Level DNS Names
    https://www.rfc-editor.org/rfc/rfc2606
  RFC 5737 — IPv4 Address Blocks Reserved for Documentation
    https://www.rfc-editor.org/rfc/rfc5737
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/109.4/lab)
