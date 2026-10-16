## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
STEP-BY-STEP SOLUTION (STUDENT REFERENCE & INSTRUCTOR GUIDE)

STEP 1: DIAGNOSE NAME RESOLUTION (DNS)
Command:
  # drill lpi.org
Symptom:
  ;; Connection timed out; no servers could be reached

Root Cause Analysis:
  Inspect /etc/resolv.conf. The active nameserver is set to dummy IP 192.0.2.53.
  # cat /etc/resolv.conf

Fix:
  Replace the invalid nameserver with a valid upstream public DNS server
  (e.g., Cloudflare 1.1.1.1 or Google 8.8.8.8).
  # cat << 'EOF' > /etc/resolv.conf
  nameserver 1.1.1.1
  nameserver 8.8.8.8
  EOF

Verification:
  # drill lpi.org
  ;; ANSWER SECTION:
  lpi.org.  300  IN  A  198.51.100.42

STEP 2: DIAGNOSE ROUTING TABLE & DEFAULT GATEWAY
Command:
  # netstat -rn
Symptom:
  Routing table displays an invalid default gateway:
  default 192.0.2.1 UGS em0

Root Cause Analysis:
  The default gateway points to 192.0.2.1, which is unreachable on the local subnet.

Fix:
  Identify your valid local interface network and actual gateway IP (e.g., 10.0.2.2 or 192.168.1.1).
  Delete the broken route and add the correct default route:
  # route delete default
  # route add default 10.0.2.2   # Replace 10.0.2.2 with your lab subnet's gateway IP

Verification:
  # netstat -rn | grep default
  default            10.0.2.2           UGS         em0
  # route get 1.1.1.1
  route to: 1.1.1.1
  destination: default
  gateway: 10.0.2.2
  interface: em0

STEP 3: DIAGNOSE PACKET FILTER (PF FIREWALL) BLOCK RULES
Command:
  # pfctl -sr
Symptom:
  Active rules output:
  block drop out quick proto tcp from any to any port = 80
  block drop out quick proto tcp from any to any port = 443
  block drop out quick proto icmp from any to any

Root Cause Analysis:
  PF is loaded with quick drop rules targeting outbound TCP HTTP/HTTPS and ICMP traffic.

Fix:
  Option A: Flush all active rules or disable PF temporarily:
    # pfctl -F all
    # pfctl -d

  Option B: Edit /etc/pf.conf to allow outbound stateful traffic and reload:
    # cat << 'EOF' > /etc/pf.conf
    set skip on lo
    scrub in all
    block in all
    pass out all keep state
    EOF
    # pfctl -f /etc/pf.conf

Verification:
  # pfctl -sr
  pass out all flags S/SA keep state

STEP 4: FINAL END-TO-END VALIDATION
Execute the automated lab verification tool:
  # ./break_fix_714_3.sh --verify

Expected Final Output:
  1. Testing Name Resolution (DNS)... [PASS]
  2. Testing Default Gateway Configuration... [PASS]
  3. Testing Outbound TCP Reachability... [PASS]
   SUCCESS: ALL NETWORK TROUBLESHOOTING CHECKS PASSED!
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpi-702/714.3/lab)
