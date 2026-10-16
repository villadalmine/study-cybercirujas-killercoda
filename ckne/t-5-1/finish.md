## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION (don't read it until you've tried)

---- Step 0: quantify the symptom (golden signals) -------------------------

  sudo ./ckne-5.1-break-fix.sh status
    availability: 93.3% (56/60)
    latency p50: 1.180s  p95: 3.900s  max: 5.004s

  Compare it with the baseline (~0.005s per download, RTT ~0.05 ms). Latency
  and errors are up; the service is "up" but unhealthy. That rules out
  "the link is down" and points at loss or latency on the path.

---- Step 1: the interface counters lie by omission ------------------------

  ip -s link show ckne-h0
    RX:  bytes packets errors dropped  missed   mcast
      ...          0       0       0
    TX:  bytes packets errors dropped carrier collsns
      ...          0       0       0

  Zero errors and zero drops. Reason: netem drops packets INSIDE the qdisc,
  before the driver. Those drops are counted in the qdisc statistics, not in
  the device's tx_dropped. In Prometheus this means
  node_network_transmit_drop_total will NOT show it; you need the qdisc
  (node_exporter's qdisc collector, disabled by default) or node_netstat
  counters.

---- Step 2: qdiscs on the node side ---------------------------------------

  tc -s qdisc show dev ckne-h0
    qdisc netem 8002: root refcnt 2 limit 1000 corrupt 3%
     Sent 912345 bytes 8123 pkt (dropped 0, overlimits 0 requeues 0)

  FAULT #1 FOUND: netem corrupt 3% on the node egress (client -> backend).
  Note "dropped 0": corruption does not drop at the sender. The damage is
  counted by the RECEIVER, in its own network stack.

---- Step 3: the counters live in the right netns --------------------------

  A common mistake: running nstat on the host and seeing nothing unusual.
  /proc/net/snmp and /proc/net/netstat are PER NETWORK NAMESPACE. The
  backend (the one sending the 256 KiB and therefore retransmitting) has
  its counters inside the netns:

  # nstat stores its history in /tmp/.nstat.u<uid>; use a separate history
  # file per netns so the deltas don't get mixed up
  export NSTAT_HISTORY=/tmp/nstat.ckne-ns
  ip netns exec ckne-metrics-lab nstat -n          # reset the baseline
  sleep 20                                        # let the probe generate traffic
  ip netns exec ckne-metrics-lab nstat | grep -E 'Retrans|CsumErrors|HdrErrors|Lost|Timeout|SACK'
    IpInHdrErrors                   3        0.0
    IpExtInCsumErrors               3        0.0
    TcpRetransSegs                  412      0.0
    TcpInCsumErrors                 9        0.0
    TcpExtTCPLostRetransmit         17       0.0
    TcpExtTCPTimeouts               6        0.0
    TcpExtTCPSACKReorder            21       0.0

  (The exact numbers vary.) Interpretation:
  - *CsumErrors / IpInHdrErrors: the backend receives corrupted packets.
    This confirms fault #1 from the receiver side. Some corrupted frames get
    the bit flipped in the Ethernet header and are dropped silently; this
    metric is a lower bound.
  - TcpRetransSegs very high and TCPTimeouts > 0: the backend's OWN sent
    segments are getting lost. Corruption in the client->backend direction
    explains lost ACKs, but not this volume. There is something else on the
    backend -> client path.
  - TCPSACKReorder: reordering, a classic sign of jitter.

  Useful ratio (the same thing you would use in PromQL):
    retransmission rate = TcpRetransSegs / TcpOutSegs
  Healthy on a LAN: < 0.1%. Here you'll see several percent.

---- Step 4: per-socket view (ss) ------------------------------------------

  While a download is in flight:
  ip netns exec ckne-metrics-lab ss -tin sport = :8080
    ESTAB 0 101352 10.231.0.2:8080 10.231.0.1:49812
     cubic wscale:7,7 rto:412 rtt:103.5/21.7 ... cwnd:4 ssthresh:7
     ... retrans:1/9 lost:1 ... reordering:5

  rtt:103.5ms on a veth that doesn't leave the machine (baseline < 0.1 ms)
  and a cwnd collapsed to single digits. Latency AND loss on the
  backend -> client path.

---- Step 5: the qdisc the host can't see ----------------------------------

  tc qdisc show                       # on the host: ckne-n0 does not appear
  ip netns exec ckne-metrics-lab tc -s qdisc show dev ckne-n0
    qdisc netem 8001: root refcnt 2 limit 1000 delay 80ms  25ms loss 6%
     Sent 2345678 bytes 2100 pkt (dropped 131, overlimits 0 requeues 0)

  FAULT #2 FOUND: netem on the egress INSIDE the netns (the "Pod eth0").
  Here "dropped" does count: loss 6% is dropped in the qdisc.
  The 25ms jitter explains the reordering (TCPSACKReorder).

---- Step 6: fix it ---------------------------------------------------------

  tc qdisc del dev ckne-h0 root
  ip netns exec ckne-metrics-lab tc qdisc del dev ckne-n0 root

  Deleting the root qdisc on a veth restores the default "noqueue":
  tc qdisc show dev ckne-h0
    qdisc noqueue 0: root refcnt 2

  If you only fix one of the two, verify still fails: with only fault #1
  fixed, RTT stays around 80 ms; with only fault #2 fixed, the backend keeps
  receiving corrupted packets and retransmitting.

---- Step 7: check ----------------------------------------------------------

  sudo ./ckne-5.1-break-fix.sh verify
    [PASS] Node-side egress with no impairment
    [PASS] Pod-side egress with no impairment
    [PASS] ICMP loss 0%
    [PASS] Average RTT 0.048 ms (< 5 ms)
    [PASS] 20/20 downloads OK, max 0.012s
    [PASS] Backend TCP retransmissions during the test: 0
    [PASS] Checksum/header errors received by the backend: 0
    LAB PASSED.

  sudo ./ckne-5.1-break-fix.sh cleanup

---- How it maps to a Kubernetes cluster -----------------------------------

  - Each Pod is a netns. Node-level node_exporter reads the counters of the
    HOST netns: node_netstat_Tcp_RetransSegs does NOT include retransmissions
    from Pods with their own netns. To look inside a Pod:
      PID=$(crictl inspect --output go-template \
            --template '{{.info.pid}}' <container-id>)
      nsenter -t "$PID" -n nstat -az TcpRetransSegs
      nsenter -t "$PID" -n tc -s qdisc
      nsenter -t "$PID" -n ss -tin
    or an ephemeral container: kubectl debug -it <pod> --image=nicolaka/netshoot
  - The kubelet (cAdvisor) exposes per-Pod interface counters:
      container_network_receive_packets_dropped_total
      container_network_transmit_packets_dropped_total
      container_network_receive_errors_total
    They have the same blind spot as ip -s link: drops inside a netem/tbf
    qdisc are NOT counted there.
  - Useful PromQL on the node (host netns):
      rate(node_netstat_Tcp_RetransSegs[5m])
        / rate(node_netstat_Tcp_OutSegs[5m])
    InCsumErrors is not in node_exporter's --collector.netstat.fields regex
    by default; you have to extend it to see it.
  - With Cilium, the drop reason is observed in the datapath:
      cilium_drop_count_total{reason="..."} and, with Hubble enabled,
      hubble_drop_total and hubble_tcp_flags_total (a rise in RST/SYN
      retries). A netem qdisc does not go through Cilium's eBPF drop
      accounting either: always cross-check with tc -s qdisc.
  - Real-world equivalents of this lab: the bandwidth CNI plugin (tbf on the
    host veth + ifb for ingress), a NIC with a broken checksum offload
    (InCsumErrors), or MTU/encapsulation problems on the overlay
    (retransmissions with no drops on the interface).

---- Takeaways ---------------------------------------------------------------
  1. "Interface UP and 0 errors" != "healthy network". Drops can live in
     the qdisc, and corruption shows up only at the receiver.
  2. TCP/IP counters are per netns: measure from the stack that sends
     (retransmissions) AND from the one that receives (checksum errors).
  3. Correlate the four sources: tc -s qdisc (where it drops), nstat (what
     the stack sees), ss -ti (effect per connection: rtt, cwnd, retrans),
     and blackbox probing (effect on the SLO).
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/5.1/lab)
