## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION -- step by step
 Do not read this until you have run 'hint' to exhaustion and written down
 your answers to Q1..Q6. The diagnosis is what the exam tests; the repair
 is three commands and two text edits.

 STEP 0 -- ESTABLISH THE FACTS BEFORE CHANGING ANYTHING
   # ip -brief -4 addr show
   lo               UNKNOWN        127.0.0.1/8
   ens18            UP             192.168.178.42/30

   # ip -4 route show
   192.168.178.40/30 dev ens18 proto kernel scope link src 192.168.178.42

   Two facts jump out. First, there is no 'default' line at all. Second,
   the connected route is a /30 -- network 192.168.178.40, usable hosts
   .41 and .42 only. The gateway on this LAN is 192.168.178.1, which is
   NOT in that range. That single observation explains Q1: the kernel
   decides whether a destination is on-link purely from the prefix. With
   a /30 the gateway looks like a remote host, reachable only through a
   router -- and the only router we had was the gateway itself. Circular,
   therefore unreachable.

   # ping -c1 192.168.178.1
   connect: Network is unreachable

   "Network is unreachable" is emitted by the local kernel (ENETUNREACH)
   before any packet is transmitted -- confirm with 'tcpdump -ni ens18 icmp'
   in another terminal: you will see nothing at all. Contrast with
   "Destination Host Unreachable" (an ICMP type 3 code 1 came BACK from a
   router, so your packet did travel) and with silent 100% loss (the packet
   left, and either it or the reply was dropped somewhere). That is Q2.

 STEP 1 -- FIX THE PREFIX (goal G1)
   Compute what the prefix should be. If the LAN is 192.168.178.0 with 254
   usable hosts, the prefix is /24 (mask 255.255.255.0):

     # ipcalc 192.168.178.42/24
     Address:   192.168.178.42       11000000.10101000.10110010. 00101010
     Netmask:   255.255.255.0 = 24   11111111.11111111.11111111. 00000000
     Network:   192.168.178.0/24
     HostMin:   192.168.178.1
     HostMax:   192.168.178.254
     Broadcast: 192.168.178.255

   The gateway 192.168.178.1 is HostMin -- inside the network. Apply it:

     # ip addr del 192.168.178.42/30 dev ens18
     # ip addr add 192.168.178.42/24 dev ens18
     # ip -4 route show
     192.168.178.0/24 dev ens18 proto kernel scope link src 192.168.178.42

   The connected route was re-derived automatically by the kernel; you never
   add it by hand. Note also that 192.168.0.0/16 is RFC 1918 private space,
   which is why this address can never be the source seen by a public server
   (Q5): the border router performs source NAT (masquerading), rewriting the
   source address to its own public one and tracking the flow in conntrack.

 STEP 2 -- RESTORE THE DEFAULT ROUTE (goal G2)
     # ip route add default via 192.168.178.1 dev ens18
     # ip -4 route show
     default via 192.168.178.1 dev ens18
     192.168.178.0/24 dev ens18 proto kernel scope link src 192.168.178.42

     # ping -c2 192.168.178.1
     PING 192.168.178.1 (192.168.178.1) 56(84) bytes of data.
     64 bytes from 192.168.178.1: icmp_seq=1 ttl=64 time=0.512 ms
     64 bytes from 192.168.178.1: icmp_seq=2 ttl=64 time=0.488 ms
     --- 192.168.178.1 ping statistics ---
     2 packets transmitted, 2 received, 0% packet loss, time 1001ms

   Had you tried this BEFORE step 1, it would have failed with
     Error: Nexthop has invalid gateway.
   -- the kernel refuses a gateway that is not on-link. Order is not
   cosmetic here; it is the proof that step 1 was the real root cause.

   Make it persistent for the distribution in use:
     NetworkManager:  nmcli con mod "System ens18" ipv4.addresses 192.168.178.42/24 \
                        ipv4.gateway 192.168.178.1 ipv4.method manual
                      nmcli con up "System ens18"
     systemd-networkd: edit /etc/systemd/network/*.network -> [Network] Address=/Gateway=
                       then: networkctl reload && networkctl reconfigure ens18
     Debian ifupdown:  /etc/network/interfaces -> address/netmask/gateway

 STEP 3 -- RE-ENABLE ICMP ECHO REPLIES (goal G3)
   From a second machine on the LAN, the signature was: ping to this host
   times out, but 'nc -vz 192.168.178.42 22' connects. TCP up, ICMP down.
   Two plausible causes (Q3): a firewall rule dropping ICMP, or the kernel
   ignoring echo requests. Distinguish them:

     # nft list ruleset            # or: iptables -S
     (empty -- so it is not filtering)

     # sysctl net.ipv4.icmp_echo_ignore_all
     net.ipv4.icmp_echo_ignore_all = 1        <-- there it is

   Fix the runtime value and remove the file that makes it persistent:

     # sysctl -w net.ipv4.icmp_echo_ignore_all=0
     net.ipv4.icmp_echo_ignore_all = 0
     # grep -rn icmp_echo_ignore_all /etc/sysctl.conf /etc/sysctl.d/
     /etc/sysctl.d/99-lab-icmp.conf:2:net.ipv4.icmp_echo_ignore_all = 1
     # rm /etc/sysctl.d/99-lab-icmp.conf
     # sysctl --system | grep icmp_echo          # reload, confirm

   Deleting the file without 'sysctl -w' leaves the box broken until
   reboot; running 'sysctl -w' without deleting the file leaves it broken
   AFTER the next reboot. Both halves are required -- that is why the
   grader checks G3a and G3b separately.

   Protocol note for the exam: ICMP is IP protocol number 1 -- it is not
   carried inside TCP or UDP and has no port numbers at all. That is
   precisely why "I can't ping it" is never sufficient evidence that a
   service is down, and why 'ping' is a poor monitoring check.

 STEP 4 -- REPAIR NAME RESOLUTION (goal G4)
   Split the problem in two: is it the network path, or the resolver?

     # getent hosts 192.168.178.1
     192.168.178.1     gateway              <-- files path fine, nsswitch fine

     # cat /etc/resolv.conf
     nameserver 203.0.113.53
     options timeout:5 attempts:2

     # dig +short @1.1.1.1 www.lpi.org
     104.22.32.163                          <-- an explicit resolver answers

     # dig www.lpi.org
     ;; communications error to 203.0.113.53#53: timed out
     ;; no servers could be reached

   203.0.113.0/24 is TEST-NET-3 (RFC 5737): reserved for documentation and
   never routed on the Internet, so queries vanish. Point the resolver at
   the real one -- on most LANs that is the gateway itself:

     # printf 'nameserver 192.168.178.1\nnameserver 1.1.1.1\noptions timeout:2\n' \
         > /etc/resolv.conf
     # getent hosts www.lpi.org
     104.22.32.163   www.lpi.org

   If /etc/resolv.conf is a symlink into /run/systemd/resolve/ on your VM,
   do NOT hand-edit the target -- it is regenerated. Configure the resolver
   where it belongs and reload:
     # resolvectl dns ens18 192.168.178.1
     # resolvectl status ens18
     # ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
   Likewise, if NetworkManager owns the file, set ipv4.dns on the connection
   and 'nmcli con up' -- otherwise your edit is erased at the next DHCP renew.

   Q4, for the exam: DNS uses UDP/53 by default because a query and its
   answer each fit in a single datagram, and a connectionless exchange
   avoids the three-way handshake -- one round trip instead of three. The
   resolver retries over TCP/53 when the response has the TC (truncated)
   flag set, i.e. the answer exceeded the negotiated size (512 bytes
   classically, or the EDNS0 advertised buffer), and always for zone
   transfers (AXFR/IXFR), which are arbitrarily large and must be reliable.

 STEP 5 -- RESTORE THE WELL-KNOWN PORT NAMES (goal G5)
   The socket was never wrong -- only the label:

     # ss -tulpn | grep :22
     tcp   LISTEN 0  128   0.0.0.0:22    0.0.0.0:*   users:(("sshd",pid=812,fd=3))

     # ss -tulp | grep ssh
     tcp   LISTEN 0  128   0.0.0.0:ssh   0.0.0.0:*   ...     <-- name lookup

     # grep -E '^(ssh|https|domain)[[:space:]]' /etc/services
     ssh             2222/tcp
     ssh             2222/udp
     https           4443/tcp
     domain          5353/tcp
     domain          5353/udp

   getservbyport(3) reads this file; nothing on the wire changed. Restore
   the canonical IANA values:

     # sed -i -e 's|^ssh\t\t2222/|ssh\t\t22/|' \
              -e 's|^https\t\t4443/|https\t\t443/|' \
              -e 's|^domain\t\t5353/|domain\t\t53/|' /etc/services
     # sed -i '/lpic1-109.1 lab marker/d' /etc/services

   Or let the package manager do it, which is what you would do in
   production:
     Debian/Ubuntu:  dpkg -S /etc/services   -> netbase
                     apt-get install --reinstall netbase
     RHEL/Fedora:    rpm -qf /etc/services   -> setup
                     rpm --verify setup ; dnf reinstall setup

   The ports you are expected to recognise on sight for 109.1:
     20  ftp-data (TCP)      21  ftp (TCP)          22  ssh (TCP)
     23  telnet (TCP)        25  smtp (TCP)         53  domain (UDP+TCP)
     80  http (TCP)         110  pop3 (TCP)        123  ntp (UDP)
    139  netbios-ssn (TCP)  143  imap (TCP)        161  snmp (UDP)
    162  snmp-trap (UDP)    389  ldap (TCP)        443  https (TCP)
    465  submissions/SMTPS  514  syslog (UDP)      636  ldaps (TCP)
    993  imaps (TCP)        995  pop3s (TCP)

 STEP 6 -- VERIFY END TO END
     # sudo ./break-109-1-internet-protocols.sh verify
     [ ok ] G1a  interface ens18 carries 192.168.178.42/24
     [ ok ] G1b  the gateway 192.168.178.1 is reachable on-link
     [ ok ] G2   an IPv4 default route exists via 192.168.178.1
     [ ok ] G3a  the kernel answers ICMP Echo Requests (runtime)
     [ ok ] G3b  no sysctl.d file re-enables the drop after reboot
     [ ok ] G4   forward DNS resolution works under 5 s
     [ ok ] G5   /etc/services matches IANA for ssh, https and domain
     [ ok ] 7/7 goals met. Lab solved.

 STEP 7 -- THE IPv6 HALF OF THE OBJECTIVE (Q6)
   Every command above has an IPv6 form; the objective requires you to know
   both. Run these on the repaired VM and compare the output:

     # ip -6 addr show ens18
     inet6 2001:db8:178::2a/64 scope global
     inet6 fe80::5054:ff:fe12:3456/64 scope link      <-- always present

     # ip -6 route show
     2001:db8:178::/64 dev ens18 proto kernel metric 256
     fe80::/64 dev ens18 proto kernel metric 256
     default via fe80::1 dev ens18 proto ra metric 1024   <-- learned by RA

     # ping -6 -c2 2001:4860:4860::8888
     # ip -6 neigh show                 # the ND cache -- IPv6's "arp -n"

   What changed, and what disappeared:
     * 128-bit addresses in eight hextets, written with :: collapsing one
       run of zeros (RFC 4291). No dotted quad, no netmask -- prefix length
       only, and /64 for a normal LAN is effectively mandatory because SLAAC
       depends on it.
     * ARP is gone. Neighbor Discovery (ICMPv6 types 133-137) replaces it,
       which makes ICMPv6 structurally mandatory -- blocking ICMPv6 the way
       this lab blocked ICMPv4 does not "harden" a host, it disconnects it.
     * Broadcast is gone. Multicast replaces it: ff02::1 all-nodes,
       ff02::2 all-routers, plus solicited-node ff02::1:ff00:0/104.
     * Routers never fragment. The source does Path MTU Discovery, so a
       firewall that drops ICMPv6 Packet Too Big (type 2) creates the classic
       "small pages load, large ones hang" black hole.
     * Address autoconfiguration is built in: SLAAC from Router
       Advertisements, optionally with DHCPv6 for other parameters.
     * NAT is not required -- global addresses are the norm; fc00::/7
       (RFC 4193, in practice fd00::/8) is the ULA range, the closest
       equivalent to RFC 1918, and fe80::/10 link-local exists on every
       interface unconditionally.
     * There is no checksum in the IPv6 header, and the header is a fixed
       40 bytes with options moved to extension headers.

 CLEAN UP
     # sudo ./break-109-1-internet-protocols.sh restore
     # sudo rm -rf /var/tmp/lpic1-109.1 /etc/lab-vm-ok
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/109.1/lab)
