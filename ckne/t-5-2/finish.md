## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION (spoilers: try it yourself first)

STEP 1: Reproduce and correlate the client span with the server span
  /run/ckne-lab/bin/ckne-trace /small

  Expected (approximately):
    traceparent : 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
    client span : connect=0.151s ttfb=0.303s total=0.303s bytes=3 http=200
    curl exit   : 0
    server hdr  : Server-Timing: app;dur=5.1
    server span :
    {"ts": ..., "name": "GET /small", "trace_id": "4bf92f35...", "app_ms": 5.1, ...}

  How to read it:
  - total (303 ms) minus app_ms (5 ms) is ~298 ms spent outside the app.
  - connect=0.151s: the TCP handshake alone takes ~150 ms. The SYN is slow.
  - ttfb - connect = ~150 ms more: the request travels client->server and
    is slow again. Two slow one-way trips, both client->backend. The
    response direction adds nothing measurable.
  - Hypothesis: a one-way delay of ~150 ms somewhere on the path from the
    client to the backend.

  The same reasoning applies in Kubernetes with OpenTelemetry: when
  (client span duration) >> (server span duration) for one trace_id, the
  gap is network, proxy queueing or connection setup, not code.

STEP 2: Localize hop by hop
  ip netns exec ckne-client ping -c3 10.52.1.1    # near side of gw
    rtt min/avg/max/mdev = 0.040/0.050/0.061/0.008 ms
  ip netns exec ckne-client ping -c3 10.52.2.1    # far side of gw (gw answers itself)
    rtt min/avg/max/mdev = 0.041/0.052/0.066/0.010 ms
  ip netns exec ckne-client ping -c3 10.52.2.2    # the backend
    rtt min/avg/max/mdev = 150.1/150.2/150.3/0.08 ms

  Optional: ip netns exec ckne-client mtr -n -c 10 -r 10.52.2.2
    1.|-- 10.52.1.1   0.0%  10   0.1   0.1 ...
    2.|-- 10.52.2.2   0.0%  10 150.2 150.2 ...

  Conclusion: the gw itself is fast. The latency sits on the gw <-> backend
  link, so look at veth-gb (gw egress) and veth-be.

STEP 3: Inspect the queueing discipline on the suspect interface
  ip netns exec ckne-gw tc -s qdisc show dev veth-gb
    qdisc netem 8001: root refcnt 2 limit 1000 delay 150ms
     Sent 18230 bytes 160 pkt (dropped 0, overlimits 0 requeues 0)

  netem is an emulator; it has no place on a production path. In real life
  the equivalent is a forgotten shaping/policing rule, a bandwidth
  annotation on a CNI (for example kubernetes.io/egress-bandwidth), or a
  congested uplink. `tc -s` counters tell you whether traffic really goes
  through it.

  Fix 1:
  ip netns exec ckne-gw tc qdisc del dev veth-gb root

  Re-test:
  /run/ckne-lab/bin/ckne-trace /small
    client span : connect=0.000s ttfb=0.007s total=0.007s bytes=3 http=200

STEP 4: Second symptom, large responses stall
  /run/ckne-lab/bin/ckne-trace /large
    client span : connect=0.000s ttfb=0.006s total=10.001s bytes=0 http=200
    curl exit   : 28 (timeout)
    server span : {"name": "GET /large", "app_ms": 5.1, "write_ms": 0.3, "status": "ok", ...}

  Key trace lesson: the server span says "ok" with write_ms ~0 because
  write() only copies 256 KiB into the kernel socket buffer. The app has
  no way to know those bytes never reached the client. Server-side spans
  cannot see transport-level loss, so you have to go below L7.

  Signature: ttfb is fast (small packets get through), the body never
  arrives (full-size packets do not). Small works and big hangs is the
  classic MTU / PMTUD black hole.

STEP 5: Confirm from the TCP sender's point of view
  ip netns exec ckne-client curl -s -o /dev/null --max-time 20 http://10.52.2.2:8080/large &
  sleep 3
  ip netns exec ckne-backend ss -tin dst 10.52.1.2
    ESTAB 0 245760 10.52.2.2:8080 10.52.1.2:41234
      cubic rto:3200 backoff:4 mss:1448 pmtu:1500 ... unacked:10 retrans:1/5 lost:10 ...
  ip netns exec ckne-backend nstat -az TcpRetransSegs
    TcpRetransSegs   42   0.0      <- keeps rising

  A growing send queue, exponential backoff, retransmissions and pmtu:1500
  all mean the sender still believes 1500 bytes fits the path.

STEP 6: Packet capture on both sides of the router
  ip netns exec ckne-gw tcpdump -ni veth-gb 'tcp port 8080 or icmp'
    IP 10.52.2.2.8080 > 10.52.1.2.41234: Flags [.], seq 1:1449, ack 1, length 1448
    IP 10.52.2.2.8080 > 10.52.1.2.41234: Flags [.], seq 1:1449, ack 1, length 1448   <- retransmission
    (no ICMP back toward 10.52.2.2 at all)

  ip netns exec ckne-gw tcpdump -ni veth-gc 'tcp port 8080'
    (the length-1448 segments NEVER appear on the client-facing interface)

  The packets enter the router and do not come out. With DF set, a router
  that cannot forward a packet must reply with ICMP type 3 code 4
  (fragmentation needed, carrying the next-hop MTU; RFC 1191). No ICMP
  is leaving, so something is suppressing it.

STEP 7: Find both halves of the black hole
  ip netns exec ckne-gw ip -d link show veth-gc | grep -o 'mtu [0-9]*'
    mtu 1280
  ip netns exec ckne-client ip link show veth-cl | grep -o 'mtu [0-9]*'
    mtu 1500          <- mismatch: the client advertised MSS 1460 in its SYN

  ip netns exec ckne-gw nft list ruleset
    table ip ckne_lab {
      chain output {
        type filter hook output priority filter; policy accept;
        icmp type destination-unreachable icmp code frag-needed drop comment "hardening-baseline-v2"
      }
    }

  Root cause 2 = an MTU mismatch (common in Kubernetes: VXLAN overlays cost
  50 bytes, Geneve ~50+, WireGuard 60-80, IPsec more) PLUS "hardening" that
  drops ICMP. Each alone is survivable; together they black-hole every
  full-size packet.

STEP 8: Fix it
  Proper fix, make the MTU consistent on the link:
    ip netns exec ckne-gw ip link set dev veth-gc mtu 1500

  Fix the filter too (never drop ICMP frag-needed / ICMPv6 Packet Too Big):
    ip netns exec ckne-gw nft delete table ip ckne_lab

  Drop any stale PMTU exceptions the sender may have cached:
    ip netns exec ckne-backend ip route flush cache

  Alternatives when the MTU really must stay lower (e.g. an overlay):
  a) Let PMTUD work (allow ICMP type 3 code 4). The sender learns 1280 and
     caches it: `ip netns exec ckne-backend ip route get 10.52.1.2` then
     shows "mtu 1280" in the route cache.
  b) Clamp the TCP MSS to the route MTU on the router (TCP only):
       ip netns exec ckne-gw nft add table ip mss
       ip netns exec ckne-gw nft add chain ip mss fwd '{ type filter hook forward priority mangle; }'
       ip netns exec ckne-gw nft add rule ip mss fwd tcp flags syn tcp option maxseg size set rt mtu
  c) Enable black-hole detection on the endpoints (RFC 4821):
       sysctl net.ipv4.tcp_mtu_probing=1
  In Kubernetes, set the pod/veth MTU in the CNI to match the underlay minus
  the encapsulation overhead (for example Calico `veth_mtu`, Cilium `mtu`,
  Flannel derives it from the VXLAN device) and do not filter ICMP between
  nodes.

STEP 9: Verify
  /run/ckne-lab/bin/ckne-trace /large
    client span : connect=0.000s ttfb=0.006s total=0.008s bytes=262144 http=200
  sudo ./ckne-5.2-break-fix.sh verify
    [ OK ] /small attempt 1: 0.006s ...
    [ OK ] /large attempt 1: 262144 bytes in 0.009s ...
    [ OK ] All checks passed. Incident resolved.

  Clean up:  sudo ./ckne-5.2-break-fix.sh cleanup

METHOD TAKEAWAYS (how this maps onto a cluster)
  1. Start from traces: propagate `traceparent`, then compare client span
     against server span for the SAME trace_id. The difference is time
     outside the application.
  2. Break the client span into phases (connect / TLS / ttfb / transfer).
     A slow connect points at the path or SYN handling; a slow transfer
     with a fast ttfb points at MTU, loss or window problems.
  3. Localize hop by hop (pod -> node -> remote node -> pod) with ping,
     mtr or tracepath. In Cilium, `hubble observe --pod <pod> -o json`
     gives per-flow verdicts and, with L7 visibility enabled, HTTP latency.
  4. Look at the sender: `ss -tin` (rtt, mss, pmtu, retrans, backoff) and
     `nstat` counters. Use `kubectl debug node/<node> -it --image=<tools>`
     or a netshoot ephemeral container to get these tools into a pod netns.
  5. Capture on both sides of the suspect hop. A packet that goes in and
     never comes out, with no ICMP in reply, is a black hole.
  6. Application spans report "ok" when the kernel accepts the bytes, not
     when the peer receives them. Never close a network incident on L7
     evidence alone.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/5.2/lab)
