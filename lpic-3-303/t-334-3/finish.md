## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
BEGIN SOLUTION — do not read until you have tried the lab

STEP 0 — Prove the service is innocent before touching the firewall
  # ss -ltnp | grep 8080
  LISTEN 0  5  0.0.0.0:8080  0.0.0.0:*  users:(("python3",pid=1042,fd=3))

  The socket is bound and listening. A packet-filtering fault and an
  application fault look identical from curl; they do not look identical
  from ss(8). Always separate the two before editing rules.

  Read the failure mode, not just the failure:
    * "Connection timed out"       -> the packet was DROPped, or the reply was.
    * "Connection refused"         -> a TCP RST came back: REJECT, or no listener.
    * "No route to host"           -> ICMP type 3 code 1, typically reject with
                                      icmp type host-unreachable, or real routing.
  Here it is a timeout, so: silent drop. That is netfilter, not the app.

STEP 1 — Read the WHOLE ruleset, and read it in evaluation order
  # nft -a list ruleset

  Two things must jump out:

  (a) There are TWO base chains attached to the input hook:
          chain pre_input { type filter hook input priority -10; policy accept; }
          chain input     { type filter hook input priority 0;   policy drop;   }

      Netfilter evaluates base chains on the same hook in ASCENDING priority
      order. -10 runs before 0. Whatever pre_input drops never reaches input.
      nft prints chains in creation order, NOT in evaluation order — this is
      the single most common misreading of an nftables dump.
      (Reference: https://wiki.nftables.org/wiki-nftables/index.php/Configuring_chains)

  (b) Inside 'input', rules run top to bottom, first terminal verdict wins.
      A 'drop' above an 'accept' for the same match makes the accept dead code.

  Get the handles, you will need them to delete anything:
  # nft -a list chain inet lab_filter input
  table inet lab_filter {
    chain input { # handle 3
      type filter hook input priority filter; policy drop;
      tcp dport 22 ct state new,established counter packets 41 bytes 3204 accept # handle 5
      icmpv6 type { nd-neighbor-solicit, ... } counter packets 0 bytes 0 accept  # handle 6
      ip protocol tcp th dport 8080 counter packets 3 bytes 180 drop             # handle 7
      udp dport 8081 counter packets 0 bytes 0 accept                            # handle 8
      counter packets 27 bytes 2106                                              # handle 9
    }
  }

STEP 2 — Let the counters do the diagnosis
  # nft reset counters table inet lab_filter
  # curl --max-time 3 http://127.0.0.1:8080/ ; ping -c1 -W2 8.8.8.8
  # nft list table inet lab_filter | grep -E 'counter|chain'

  Interpretation:
    * pre_input's drop counter incremented   -> traffic dies before 'input'.
    * handle 8 (udp dport 8081) still at 0   -> that rule matches nothing;
                                                wrong protocol and wrong port.
    * handle 9 (the bare counter above the
      implicit policy drop) incremented a lot -> loopback and return traffic
                                                are falling through to policy.

  For a packet-by-packet view, tag the traffic and watch it walk the chains:
  # nft add rule inet lab_filter input tcp dport 8080 meta nftrace set 1
  # nft monitor trace
  trace id 3f2a inet lab_filter pre_input packet: iif "lo" ip saddr 127.0.0.1 ...
  trace id 3f2a inet lab_filter pre_input rule tcp dport 8080 counter drop (verdict drop)
  That line is the whole answer to fault 3/aggravator, printed by the kernel.
  (nft monitor: https://www.netfilter.org/projects/nftables/manpage.html)

STEP 3 — Remove the chain that runs first
  Either delete the offending rule, or delete the whole chain. Because
  pre_input exists only to shadow the real policy, delete the chain — but a
  base chain must be flushed before it can be dropped:

  # nft flush chain inet lab_filter pre_input
  # nft delete chain inet lab_filter pre_input

  Verify no other base chain sits on the input hook:
  # nft list ruleset | grep -B1 'hook input'

STEP 4 — Restore stateful filtering and loopback (faults 1 and 2)
  These two rules belong at the TOP of the chain, in this order, for both
  correctness and performance: conntrack lookup is one hash lookup and it
  short-circuits the rest of the chain for the 99% of packets that belong to
  an existing flow.

  # nft insert rule inet lab_filter input iif "lo" counter accept \
        comment "loopback is trusted"
  # nft insert rule inet lab_filter input ct state established,related counter accept \
        comment "stateful fast path"
  # nft insert rule inet lab_filter input ct state invalid counter drop \
        comment "no state, no service"

  'insert' puts a rule at the HEAD of the chain; 'add' appends at the tail.
  Because each insert goes to the head, the LAST insert ends up FIRST. The
  resulting order is: ct invalid drop, ct established accept, iif lo accept.
  That is exactly what you want.

  Why 'ct state invalid drop' explicitly: packets conntrack cannot classify
  (out-of-window TCP, unexpected RST, fragments it could not reassemble)
  would otherwise be evaluated as NEW by later rules.
  (Reference: https://wiki.nftables.org/wiki-nftables/index.php/Matching_connection_tracking_stateful_metainformation)

  This one rule is what fixes symptom 3 and 4 in the briefing: the SYN/ACK
  from 8.8.8.8 and the DNS response are RELATED/ESTABLISHED, not NEW. A
  default-drop input chain with no conntrack rule breaks every outbound
  connection on the host while looking like it only affects ingress.

STEP 5 — Delete the dead code (faults 3 and 4)
  Re-read the handles, they do not change when you insert, but read anyway:
  # nft -a list chain inet lab_filter input

  # nft delete rule inet lab_filter input handle 7    # the shadowing drop
  # nft delete rule inet lab_filter input handle 8    # udp dport 8081, never matches

  Deleting is by handle only. There is no "delete rule by text" in nft, and
  handles are stable for the life of the rule — which is why '-a' is the
  flag you will use most in an incident.

STEP 6 — Add the rule that was supposed to be there
  # nft add rule inet lab_filter input tcp dport 8080 ct state new counter accept \
        comment "lab web service"

  Note 'ct state new': combined with the established/related rule from
  step 4, this is a complete stateful policy. Writing 'tcp dport 8080 accept'
  works too, but it re-evaluates every packet of every established flow
  against the full chain instead of short-circuiting at the conntrack rule.

  Also give the host a usable ICMP policy — do not blanket-drop ICMP, you
  will break Path MTU Discovery and produce "works for small requests,
  hangs on large ones" bugs that take days to find:

  # nft add rule inet lab_filter input meta l4proto icmp icmp type \
        { echo-request, destination-unreachable, time-exceeded, parameter-problem } \
        counter accept
  # nft add rule inet lab_filter input meta l4proto ipv6-icmp counter accept

  And close the chain with a visible, rate-limited log before the policy so
  the next incident has evidence:

  # nft add rule inet lab_filter input limit rate 5/minute burst 10 packets \
        log prefix "nft-input-drop: " level info counter

STEP 7 — Verify, including the negative case
  # curl -sS http://127.0.0.1:8080/            -> the HTML page
  # curl -sS http://<host_ip>:8080/            -> the HTML page
  # ping -c1 8.8.8.8                           -> 1 received
  # getent hosts www.lpi.org                   -> an address
  # nft list chain inet lab_filter input | head -3   -> 'policy drop' still there

  The negative test matters as much as the positive one. From another host:
  # nmap -Pn -p 22,3306,8080 <host_ip>
  PORT     STATE    SERVICE
  22/tcp   open     ssh
  3306/tcp filtered mysql        <- filtered, not closed: DROP, as intended
  8080/tcp open     http-proxy

  'filtered' proves the default-deny survived. 'closed' would mean a RST is
  being returned — that is REJECT behaviour and it advertises the host.

  # /root/lab-334.3/lab-334.3-check

STEP 8 — Write it down properly and make it survive a reboot
  Everything above was done imperatively, which is right for an incident and
  wrong for a configuration. The final artefact is a file:

  # nft list ruleset > /etc/nftables.conf
  # sed -i '1i #!/usr/sbin/nft -f' /etc/nftables.conf
  # nft -c -f /etc/nftables.conf        # -c = check syntax, load nothing
  # systemctl enable --now nftables.service

  The correct minimal ruleset, written the way it should have been:

    #!/usr/sbin/nft -f
    flush ruleset
    table inet filter {
      chain input {
        type filter hook input priority filter; policy drop;
        ct state invalid counter drop
        ct state established,related counter accept
        iif "lo" counter accept
        meta l4proto ipv6-icmp counter accept
        icmp type { echo-request, destination-unreachable, time-exceeded } counter accept
        tcp dport 22 ct state new counter accept comment "ssh"
        tcp dport 8080 ct state new counter accept comment "lab web"
        limit rate 5/minute burst 10 packets log prefix "nft-input-drop: " counter
      }
      chain forward { type filter hook forward priority filter; policy drop; }
      chain output  { type filter hook output  priority filter; policy accept; }
    }

WHAT THIS LAB TEACHES, MAPPED TO OBJECTIVE 334.3
  * nftables families (inet covers IPv4 and IPv6 in one table), tables,
    base chains, hooks and PRIORITY — including that priority, not print
    order, decides evaluation between chains on the same hook.
  * Rule order within a chain, terminal verdicts, and shadowed rules.
  * Stateful filtering with conntrack: new / established / related /
    invalid, and why a default-drop input chain without it breaks egress.
  * DROP vs REJECT and what each one tells an attacker and a troubleshooter.
  * Handles, counters, 'nft reset counters', 'nft monitor trace' and
    'meta nftrace set 1' as the primary diagnostic loop.
  * Atomic ruleset loading with 'nft -f' and syntax checking with 'nft -c'.
  * Persistence via nftables.service instead of hand-run commands.

  Adjacent knowledge the exam also expects (not broken here, worth reading):
    - iptables / ip6tables / iptables-nft equivalence and the
      iptables-translate helper: https://wiki.nftables.org/wiki-nftables/index.php/Moving_from_iptables_to_nftables
    - ebtables and arptables for bridge/ARP filtering.
    - firewalld and ufw as front ends that write nftables underneath, and
      why mixing a front end with hand-written rules causes exactly the
      "my rule disappeared after a reload" incident.
    - conntrack-tools for connection tracking inspection and accounting.
    - nftables sets, maps, verdict maps and intervals for scaling a
      ruleset past a few dozen lines.

  Official objectives: https://www.lpi.org/our-certifications/exam-303-objectives/

END SOLUTION
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-3-303/334.3/lab)
