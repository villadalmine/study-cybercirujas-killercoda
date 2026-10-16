## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION (step by step) - do not read until you have tried

STEP 0 - Confirm the symptom yourself
  kubectl config use-context kind-ckne-enc-lab

  kubectl debug node/ckne-enc-lab-worker -it --profile=netadmin \
    --image=nicolaka/netshoot:v0.13 -- \
    tcpdump -i eth0 -nn -A -s0 'udp port 8472 or udp port 51871'

  # in another terminal, generate traffic:
  kubectl -n enc-lab exec client -- curl -s http://$(kubectl -n enc-lab get pod server -o jsonpath='{.status.podIP}')/

  You will see "IP 172.18.0.x.NNNNN > 172.18.0.y.8472: OTV/VXLAN ..." and,
  a few lines later, "cardholder-record=PAN-4111-...". The overlay
  encapsulates, it does NOT encrypt. VXLAN is a transport, not a
  confidentiality control.

STEP 1 - Check the runtime state of the datapath
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg encrypt status
    Encryption: Disabled

  kubectl -n kube-system get cm cilium-config -o yaml | grep -E 'wireguard|encrypt'
    (enable-wireguard / encrypt-node are missing or not "true")

  Note: cilium-config is what the agents read on START. Editing the
  ConfigMap without restarting the DaemonSet does not change anything at
  runtime unless the chart was installed with rollOutCiliumPods=true.

STEP 2 - Find the trail: who switched it off, and why
  helm --kube-context kind-ckne-enc-lab -n kube-system history cilium
    REVISION  STATUS      DESCRIPTION
    1         superseded  Initial install: WireGuard transparent encryption (pods + nodes)
    2         deployed    INC-4471 mitigation: cross-node timeouts, transparent encryption disabled temporarily

  helm --kube-context kind-ckne-enc-lab -n kube-system get values cilium --revision 1
  helm --kube-context kind-ckne-enc-lab -n kube-system get values cilium --revision 2

  Conclusion: someone saw cross-node timeouts and "mitigated" them by
  turning encryption off. That is a symptom-level fix. Something made
  WireGuard fail FIRST. Keep that in mind: if you only re-enable
  encryption, the original outage will come back.

STEP 3 - Re-enable pod AND node encryption (WireGuard)
  helm --kube-context kind-ckne-enc-lab upgrade cilium cilium/cilium \
    --version 1.18.2 -n kube-system --reuse-values \
    --set encryption.enabled=true \
    --set encryption.type=wireguard \
    --set encryption.nodeEncryption=true \
    --description "INC-4471 fix: re-enable WireGuard pod+node encryption"

  kubectl -n kube-system rollout restart ds/cilium
  kubectl -n kube-system rollout status ds/cilium

  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg encrypt status
    Encryption: Wireguard
    Interface: cilium_wg0
        Public key: <base64>
        Number of peers: 2

  How it works: each agent generates a WireGuard key pair, creates the
  cilium_wg0 interface (UDP 51871) and publishes its public key on its
  CiliumNode object (annotation network.cilium.io/wg-pub-key). Every
  agent adds every other node as a peer, with the remote PodCIDRs (and,
  with nodeEncryption, the node IPs) as AllowedIPs. Keys are never
  distributed by hand, unlike IPsec, where you create and rotate the
  'cilium-ipsec-keys' Secret yourself.

  Node encryption notes: by default, nodes labeled
  node-role.kubernetes.io/control-plane opt out of node-to-node
  encryption (encryption.nodeEncryption opt-out labels), so the API
  server keeps working if the WireGuard mesh breaks. That is why this lab
  measures between the two workers.

STEP 4 - The second layer: cross-node traffic now fails
  ./lab.sh check
    [FAIL] client cannot reach the server pod ...
    [FAIL] hostclient cannot reach the server pod ...

  Isolate it:
  - Only flows that touch ckne-enc-lab-worker fail. worker2 <-> control-plane
    works. That points to ONE node, not to the Cilium config.
  - Health probes:
      kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-health status
    ckne-enc-lab-worker shows as unreachable from the other nodes.
  - WireGuard counters on the node (TX grows, RX stays flat = no handshake):
      docker exec ckne-enc-lab-worker ip -s link show cilium_wg0
      docker exec ckne-enc-lab-worker2 ip -s link show cilium_wg0
  - Is the packet ARRIVING? tcpdump on worker eth0 sees udp/51871 from
    worker2 (tcpdump taps before netfilter), yet no reply goes out:
      kubectl debug node/ckne-enc-lab-worker -it --profile=netadmin \
        --image=nicolaka/netshoot:v0.13 -- tcpdump -i eth0 -nn udp port 51871
  - Arriving but not processed means the host firewall. Look at the
    counters:
      docker exec ckne-enc-lab-worker iptables -L INPUT -v -n --line-numbers
      docker exec ckne-enc-lab-worker iptables -L LAB-HARDENING -v -n --line-numbers
    Chain LAB-HARDENING
    1  ...  ACCEPT  udp dpt:8472   /* SEC-2291 allow overlay */
    2  ...  DROP    udp dpt:51871  /* SEC-2291 deny unapproved UDP service */
           ^^^ pkts counter growing

  Root cause: the hardening ticket allow-listed the overlay (VXLAN 8472)
  but not the encryption transport (WireGuard 51871). WireGuard fails
  closed: it does NOT fall back to plaintext, so traffic just stopped. The
  "mitigation" then removed the encryption instead of fixing the rule.

STEP 5 - Fix the firewall properly (allow WireGuard from nodes only)
  Do not delete the whole LAB-HARDENING chain: that removes the security
  control. Replace the DROP with an ACCEPT scoped to the node network:

  NODE_NET=$(docker network inspect kind \
    -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.')
  echo "$NODE_NET"          # e.g. 172.18.0.0/16

  docker exec ckne-enc-lab-worker iptables -D LAB-HARDENING \
    -p udp --dport 51871 -m comment --comment 'SEC-2291 deny unapproved UDP service' -j DROP
  docker exec ckne-enc-lab-worker iptables -I LAB-HARDENING 2 \
    -p udp --dport 51871 -s "$NODE_NET" \
    -m comment --comment 'SEC-2291 allow Cilium WireGuard between nodes' -j ACCEPT
  docker exec ckne-enc-lab-worker iptables -A LAB-HARDENING \
    -p udp --dport 51871 -m comment --comment 'SEC-2291 deny WireGuard from outside' -j DROP

  The handshake usually recovers within seconds (WireGuard retries the
  handshake automatically). Watch RX grow:
    docker exec ckne-enc-lab-worker ip -s link show cilium_wg0

STEP 6 - Verify
  ./lab.sh check
    [PASS] cilium-config enable-wireguard=true
    [PASS] cilium-config encrypt-node=true
    [PASS] cilium-xxxxx: Encryption: Wireguard     (x3)
    [PASS] client reaches the server pod
    [PASS] hostclient reaches the server pod
    [PASS] pod-to-pod: only WireGuard (udp/51871) observed, payload not readable
    [PASS] node-to-pod: only WireGuard (udp/51871) observed, payload not readable
    LAB SOLVED

  Manual proof: repeat the tcpdump from STEP 0. You now see only
  "172.18.0.x.51871 > 172.18.0.y.51871: UDP, length NNN" with unreadable
  payload, and no udp/8472 carrying the HTTP payload on eth0 for that flow.

PRODUCTION TAKEAWAYS
  - Firewall / security groups between nodes must allow the encryption
    transport: WireGuard = UDP 51871. IPsec = IP protocol 50 (ESP), plus
    the overlay port if you tunnel. Put it in the node firewall IaC, not in
    ad-hoc iptables commands (a node reboot here would also "fix" the lab,
    and then the real rule would come back with the next config push).
  - Encryption that fails closed turns a firewall mistake into an outage.
    That is correct behavior: the incident process must forbid "disable
    encryption" as a mitigation for regulated workloads.
  - Alert on it: scrape Cilium metrics and run "cilium-dbg encrypt status"
    / "cilium-health status" in your checks; a drop in peers or a
    non-WireGuard mode is a compliance incident, not only a network one.
  - WireGuard vs IPsec: WireGuard gives automatic per-node keys and a
    simpler setup. IPsec is the choice when you need FIPS-validated
    algorithms or explicit key management, and then you own key rotation
    (increment the key ID in 'cilium-ipsec-keys').
  - Strict mode (encryption.strictMode.*) can drop unencrypted pod traffic
    to a CIDR instead of letting it leak. Check the Cilium docs for your
    version's routing-mode requirements before you enable it.
  - Encryption in transit does not replace NetworkPolicy or mTLS at L7:
    it protects the node-to-node wire, not same-node traffic or who is
    allowed to talk to whom.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/4.2/lab)
