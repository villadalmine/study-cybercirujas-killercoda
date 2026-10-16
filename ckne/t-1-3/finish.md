## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
STEP-BY-STEP SOLUTION (spoilers)

Method: follow the packet hop by hop with tcpdump. The fault is at the first
interface where the packet you expect stops appearing. Keep one terminal
generating traffic:

  sudo ip netns exec bf13-client curl -sS --max-time 5 http://10.10.2.2:8080/small.txt

FAULT B: SYN dropped in the router's raw table
1) Client: the SYN leaves, gets retransmitted, and nothing comes back.
     sudo ip netns exec bf13-client tcpdump -ni eth0 tcp port 8080
     IP 10.10.1.2.43512 > 10.10.2.2.8080: Flags [S], seq 1234, win 64240,
        options [mss 1460,sackOK,TS val ... ecr 0,nop,wscale 7], length 0
     IP 10.10.1.2.43512 > 10.10.2.2.8080: Flags [S], seq 1234, ...   <- retransmission (1s, 3s...)

2) Router ingress (eth1): the SYN DOES arrive.
     sudo ip netns exec bf13-router tcpdump -ni eth1 tcp port 8080
   Router egress (eth2): NOTHING. So the packet dies inside the router.
     sudo ip netns exec bf13-router tcpdump -ni eth2 tcp port 8080

3) The obvious check turns up nothing, because 'iptables -L' only shows the filter table:
     sudo ip netns exec bf13-router iptables -L -n -v
     (FORWARD policy ACCEPT, no rules)
   Routing is fine:
     sudo ip -n bf13-router route get 10.10.2.2 from 10.10.1.2 iif eth1
     10.10.2.2 from 10.10.1.2 dev eth2 ...

4) Look at ALL tables. iptables-save dumps them all, and the counters point at the culprit:
     sudo ip netns exec bf13-router iptables-save -c
     *raw
     [5:300] -A PREROUTING -i eth1 -p tcp -m tcp --dport 8080 --tcp-flags FIN,SYN,RST,ACK SYN
             -m comment --comment "conntrack-bypass: legacy app ports" -j DROP
   or:
     sudo ip netns exec bf13-router iptables -t raw -L PREROUTING -n -v --line-numbers
   With the nft backend you also see it in:  nft list ruleset
   Remember the order of the hooks: raw PREROUTING runs BEFORE conntrack,
   mangle, nat and filter. Nothing you do in filter/FORWARD can "unblock" it.

5) Fix: delete the rule.
     sudo ip netns exec bf13-router iptables -t raw -D PREROUTING 1

FAULT A: the server has a bogus default gateway
6) curl still times out. Now the SYN does come out of router eth2 and reaches
   the server, but no SYN-ACK comes back:
     sudo ip netns exec bf13-server tcpdump -ni eth0 -e
     IP 10.10.1.2.43514 > 10.10.2.2.8080: Flags [S], ...
     ARP, Request who-has 10.10.2.254 tell 10.10.2.2, length 28
     ARP, Request who-has 10.10.2.254 tell 10.10.2.2, length 28
   The server DOES answer (the socket is LISTENing and the kernel builds the
   SYN-ACK), but it needs the MAC of the next hop for 10.10.1.2, and that next hop does not exist.

7) Confirm with ip:
     sudo ip -n bf13-server route
     default via 10.10.2.254 dev eth0
     10.10.2.0/24 dev eth0 proto kernel scope link src 10.10.2.2
     sudo ip -n bf13-server route get 10.10.1.2
     10.10.1.2 via 10.10.2.254 dev eth0 src 10.10.2.2 uid 0
     sudo ip -n bf13-server neigh
     10.10.2.254 dev eth0 FAILED            (or INCOMPLETE)
   Also: 'ss -tn state syn-recv' in the server shows half-open connections.

8) Fix: point the default route at the real router.
     sudo ip -n bf13-server route replace default via 10.10.2.1 dev eth0
   Now small.txt comes back: "hello from bf13-server".

FAULT C: PMTU black hole (ICMP "fragmentation needed" dropped)
9) big.bin hangs: the TCP handshake and the HTTP headers get through (small packets),
   the full-size data segments do not.
     sudo ip netns exec bf13-client curl -sS --max-time 10 -o /dev/null \
          -w '%{http_code} %{size_download}\n' http://10.10.2.2:8080/big.bin
     curl: (28) Operation timed out after 10001 milliseconds with 0 out of 2000000 bytes received

10) Look at SIZES. On the router, at the server side:
     sudo ip netns exec bf13-router tcpdump -ni eth2 'tcp port 8080 or icmp'
     IP 10.10.2.2.8080 > 10.10.1.2.43520: Flags [.], seq 1:1449, ack 90, length 1448
     IP 10.10.2.2.8080 > 10.10.1.2.43520: Flags [.], seq 1:1449, ack 90, length 1448  <- retransmission
   On the client side (eth1): those segments NEVER show up. And there is no ICMP at all.
   The handshake negotiated MSS 1460 (both ends have MTU 1500): 1448 of payload + 12 of
   TCP timestamps + 40 of IP/TCP headers = 1500 bytes > 1400 on eth1. The packets carry DF,
   so the router cannot fragment them. It has to send ICMP type 3 code 4.

11) Evidence that the router is discarding them:
     sudo ip netns exec bf13-router nstat -az IpFragFails
     IpFragFails                     37                 0.0     <- keeps climbing
     sudo ip -n bf13-router link show eth1          -> mtu 1400
     sudo ip netns exec bf13-router iptables -L OUTPUT -n -v --line-numbers
     1   37  ...  DROP  icmp -- * * 0.0.0.0/0 0.0.0.0/0  icmptype 3 code 4 /* hardening: no ICMP info leak */
   The server never learns the path MTU. Check its route cache, which has no "mtu":
     sudo ip -n bf13-server route get 10.10.1.2

12) Root-cause fix: let the router emit Fragmentation Needed.
     sudo ip netns exec bf13-router iptables -D OUTPUT 1
   Verify PMTUD working:
     sudo ip netns exec bf13-router tcpdump -ni eth2 icmp
     IP 10.10.2.1 > 10.10.2.2: ICMP 10.10.1.2 unreachable - need to frag (mtu 1400), length 556
     sudo ip -n bf13-server route get 10.10.1.2
     10.10.1.2 via 10.10.2.1 dev eth0 src 10.10.2.2 uid 0
         cache expires 598sec mtu 1400                    <- PMTU learned
   (If an old test left a stale entry: sudo ip -n bf13-server route flush cache)

   Complementary / alternative fix for TCP (what CNIs and VPN gateways often do):
     sudo ip netns exec bf13-router iptables -t mangle -A FORWARD -p tcp \
          --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
   This rewrites the MSS in the SYN/SYN-ACK to 1360, so TCP never exceeds 1400.
   It does NOT fix UDP or any other protocol, so dropping ICMP type 3 code 4 is
   still a bug.

13) Final check:
     sudo ./bf13-packet-level.sh check        -> Result: 4/4

LESSONS FOR KUBERNETES
- 'iptables -L' shows only the filter table. kube-proxy, Calico and Cilium write
  rules to raw, mangle and nat as well. Use 'iptables-save -c' or 'nft list ruleset'.
- "The pod is Running and the socket is LISTENing" says nothing about the return
  path. A SYN arriving with no SYN-ACK leaving means look at routes/ARP at the destination.
- Small works and large does not: think MTU first. Overlays (VXLAN -50 B, Geneve,
  WireGuard -60/-80 B) make the pod MTU smaller than the node MTU. Any firewall
  (security group, NetworkPolicy, host rules) that drops ICMP type 3 code 4
  creates a PMTU black hole.
- Always follow the same packet interface by interface: the first hop where it
  disappears tells you which layer to look at.

References:
  https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
  https://man7.org/linux/man-pages/man8/ip-route.8.html
  https://man7.org/linux/man-pages/man8/iptables-extensions.8.html
  https://www.tcpdump.org/manpages/tcpdump.1.html
  https://www.rfc-editor.org/rfc/rfc1191   (Path MTU Discovery)
  https://www.rfc-editor.org/rfc/rfc2923   (TCP problems with PMTUD, black holes)
  https://kubernetes.io/docs/concepts/services-networking/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/1.3/lab)
