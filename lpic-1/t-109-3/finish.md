## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION - do not read until you have finished the exercise

 A method that works for all six, and for the exam:
 go up the stack and stop at the first layer that lies to you.

   1. Link      ip -br link show          state UP? carrier? (ethtool <if>)
   2. Address   ip -br addr show          right IP *and* right prefix?
   3. Neighbour ip neigh show             does the gateway answer ARP?
   4. Route     ip route show             is there a default, and is the
                                          gateway inside the local subnet?
   5. Filter    iptables -S / nft list ruleset   anything DROPping?
   6. Names     getent hosts X vs dig +short X   NSS and DNS disagree?
   7. Sockets   ss -tulpn                 is the service even listening,
                                          and on 0.0.0.0 or only 127.0.0.1?

 SCENARIO 1 - default route pointing at a black hole
  Diagnose
    ip route show
      default via 192.0.2.254 dev eth0 onlink       <-- not in our subnet
      10.0.2.0/24 dev eth0 proto kernel scope link src 10.0.2.15
    ip neigh show
      192.0.2.254 dev eth0 FAILED                   <-- nobody answers ARP
    ping -c2 1.1.1.1
      From 10.0.2.15 icmp_seq=1 Destination Host Unreachable
    traceroute 1.1.1.1     -> first hop is already * * *

  Fix (runtime)
    ip route replace default via 10.0.2.2 dev eth0
    ping -c2 1.1.1.1

  How to find the real gateway when you do not know it
    grep -r routers /var/lib/dhcp/*.leases   |  nmcli -f IP4.GATEWAY dev show eth0
    ip route show | awk '/proto kernel/{print $1}'   # your subnet; .1 or .254 is usual

  Persistent form (survives a reboot; the lab deliberately did NOT touch these)
    Debian /etc/network/interfaces:   gateway 10.0.2.2
    NetworkManager:                   nmcli con mod "<name>" ipv4.gateway 10.0.2.2 && nmcli con up "<name>"
    systemd-networkd:                 [Route] Gateway=10.0.2.2 in /etc/systemd/network/*.network

 SCENARIO 2 - resolver pointed at a dead nameserver
  Diagnose
    ping -c1 deb.debian.org      -> Temporary failure in name resolution
    ping -c1 1.1.1.1             -> works, so routing is fine
    cat /etc/resolv.conf
      nameserver 203.0.113.53
    dig @203.0.113.53 deb.debian.org
      ;; connection timed out; no servers could be reached
    dig @1.1.1.1 deb.debian.org  -> answers instantly, so the network is fine

  Fix
    printf 'nameserver 1.1.1.1\nnameserver 10.0.2.2\n' > /etc/resolv.conf
    getent hosts deb.debian.org

  If /etc/resolv.conf is a symlink to /run/systemd/resolve/stub-resolv.conf,
  do not overwrite the link - configure the real resolver instead:
    resolvectl status
    resolvectl dns eth0 1.1.1.1
    resolvectl flush-caches

  Why ping by IP still worked: getaddrinfo(3) never runs when the argument is
  already an address literal. Only the name->address step was broken.

 SCENARIO 3 - /etc/hosts poisoned
  Diagnose
    getent hosts deb.debian.org   -> 198.51.100.66 deb.debian.org
    dig +short deb.debian.org     -> the correct public address
    grep -n deb.debian.org /etc/hosts
      12:198.51.100.66   deb.debian.org
    grep ^hosts /etc/nsswitch.conf
      hosts: files dns              <-- 'files' wins, and files is /etc/hosts

  Fix
    cp /etc/hosts /etc/hosts.bak
    sed -i '/198\.51\.100\.66/d' /etc/hosts
    sed -i '/LPIC1-BREAKFIX/d'   /etc/hosts
    getent hosts deb.debian.org

  Exam point: /etc/hosts has no TTL and no cache to flush - the change is
  effective on the next call. Order in nsswitch.conf decides who answers.

 SCENARIO 4 - NSS hosts database missing 'dns'
  Diagnose
    dig +short deb.debian.org     -> correct answer  (dig bypasses NSS)
    getent hosts deb.debian.org   -> nothing, exit status 2
    ping deb.debian.org           -> Name or service not known
    grep ^hosts /etc/nsswitch.conf
      hosts:  files                 <-- no dns source at all

  Fix
    sed -i -E 's/^hosts:.*/hosts:          files dns/' /etc/nsswitch.conf
    getent ahostsv4 deb.debian.org
  (on a systemd host the healthy line is usually:
     hosts: mymachines resolve [!UNAVAIL=return] files myhostname dns )

  Why dig was unaffected: dig/nslookup/host are DNS clients that build their
  own queries to port 53. ping/curl/ssh/apt call getaddrinfo(3) in glibc,
  which consults /etc/nsswitch.conf first. A tool that resolves and a tool
  that does not is nearly always an NSS problem, not a DNS problem.

 SCENARIO 5 - firewall silently dropping outbound DNS
  Diagnose
    dig deb.debian.org
      ;; connection timed out; no servers could be reached     (UDP: silent)
    dig +tcp deb.debian.org
      ;; communications error ... connection reset by peer      (TCP: instant)
    # prove where the packet dies:
    tcpdump -ni any port 53 &            # nothing leaves the interface
    iptables -L OUTPUT -n -v --line-numbers
      1  LPIC1BF  all -- *  *  0.0.0.0/0  0.0.0.0/0
    iptables -S LPIC1BF
      -A LPIC1BF -p udp -m udp --dport 53 -j DROP
      -A LPIC1BF -p tcp -m tcp --dport 53 -j REJECT --reject-with tcp-reset

  Fix (iptables)
    iptables -D OUTPUT -j LPIC1BF
    iptables -F LPIC1BF
    iptables -X LPIC1BF
    getent hosts deb.debian.org

  Fix (nftables)
    nft list ruleset | less
    nft delete table inet lpic1bf

  Reading the symptom: DROP discards without notice, so the client waits for
  its timeout; REJECT sends an RST or an ICMP error, so it fails immediately.
  "Hangs on UDP, fails fast on TCP" is a filter signature, and the counters in
  iptables -L -n -v (pkts/bytes rising as you retry) confirm which rule.

 SCENARIO 6 - wrong netmask on the primary interface
  Diagnose
    ip -br addr show eth0
      eth0  UP   10.0.2.15/32                       <-- prefix is wrong
    ip route show
      (the 10.0.2.0/24 connected route is gone)
    ping 10.0.2.2      -> connect: Network is unreachable
    ip route add default via 10.0.2.2 dev eth0
      Error: Nexthop has invalid gateway.

  Recover the real prefix
    grep -E 'subnet-mask|option routers' /var/lib/dhcp/*.leases
    nmcli -f IP4.ADDRESS,IP4.GATEWAY dev show eth0
    ipcalc 10.0.2.15/24        # confirm network, broadcast and usable range

  Fix
    ip addr del 10.0.2.15/32 dev eth0
    ip addr add 10.0.2.15/24 dev eth0
    ip route add default via 10.0.2.2 dev eth0
    ping -c2 10.0.2.2 && ping -c2 1.1.1.1
    # or simply let the DHCP client redo it:  dhclient -r eth0 && dhclient eth0

  Why the whole network died from a netmask: the prefix is what creates the
  on-link (connected) route. With /32 the kernel believes the only host on the
  segment is itself, so it has no interface route through which to ARP for the
  gateway - hence "Network is unreachable" from the routing layer, before a
  single packet is ever sent.

 Sources
   LPI exam 101-500 objectives: https://www.lpi.org/our-certifications/exam-101-objectives/
   LPI exam 102-500 objectives: https://www.lpi.org/our-certifications/exam-102-objectives/
   ip(8), ip-route(8), ip-address(8): https://man7.org/linux/man-pages/man8/ip.8.html
   nsswitch.conf(5): https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html
   resolv.conf(5):   https://man7.org/linux/man-pages/man5/resolv.conf.5.html
   ss(8):            https://man7.org/linux/man-pages/man8/ss.8.html
   nftables wiki:    https://wiki.nftables.org/wiki-nftables/index.php/Main_Page
   RFC 5737 (documentation address blocks): https://www.rfc-editor.org/rfc/rfc5737
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/109.3/lab)
