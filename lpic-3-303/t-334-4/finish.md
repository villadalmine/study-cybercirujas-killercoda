## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTIONS -- read only after you have tried. One block per scenario, step by step.

SCENARIO 1 -- data-channel cipher negotiation (NCP)
1. Read the first error, not the reconnect loop:
       tail -n 60 /opt/vpn334-lab/server/server.log
       tail -n 60 /opt/vpn334-lab/client/client.log
   Server: "OPTIONS ERROR: failed to negotiate cipher with client."
   Client: "OPTIONS ERROR: failed to negotiate cipher with server."
   The TLS handshake completed -- certificates are fine. The failure is at the
   OCC/NCP option-negotiation step, after authentication.

2. Compare the two lists:
       grep -H 'data-ciphers' /opt/vpn334-lab/server/server.conf \
                              /opt/vpn334-lab/client/client.conf
       server: data-ciphers AES-256-GCM
       client: data-ciphers AES-128-CBC
   Since OpenVPN 2.5 the data-channel cipher is NEGOTIATED (Negotiable Crypto
   Parameters). --data-ciphers is an ordered preference list; the server picks
   the first entry it also allows. Empty intersection => hard failure.
   --cipher is deprecated and only sets the fallback for pre-2.4 peers; in 2.6
   it exists as --data-ciphers-fallback.

3. Fix the CLIENT (never widen the server to a 64-bit-block-free-but-unauthenticated
   CBC mode just to silence an error):
       sed -i 's/^data-ciphers .*/data-ciphers AES-256-GCM/;\
               s/^data-ciphers-fallback .*/data-ciphers-fallback AES-256-GCM/' \
           /opt/vpn334-lab/client/client.conf

4. Restart and verify the negotiated cipher, do not assume it:
       ./334.4-vpn-break-fix.sh restart
       grep -E "Data Channel|Outgoing Data Channel" /opt/vpn334-lab/client/client.log
       ip netns exec vpn-right ping -c2 10.8.0.1

5. Production note: AES-256-GCM and CHACHA20-POLY1305 are AEAD; they authenticate
   the payload as part of the cipher. AES-256-CBC needs a separate --auth HMAC and
   is the reason the old "cipher + auth" pair existed. Prefer
       data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
   Reference: https://openvpn.net/community-resources/reference-manual-for-openvpn-2-6/

SCENARIO 2 -- tls-crypt control-channel key mismatch
1. Establish that the transport is healthy -- this is the step most students skip:
       ip netns exec vpn-right ping -c2 10.10.0.1                       # OK
       ip netns exec vpn-right timeout 5 tcpdump -ni veth-r udp port 1194
   You will see outbound datagrams and ZERO replies. So the server process is
   receiving and discarding, not the network dropping.

2. Client log says only:
       TLS Error: TLS key negotiation failed to occur within 60 seconds
       TLS Error: TLS handshake failed
   That message is generic: it means "no valid control-channel packet came back".
   Raise the server's verbosity to see the real cause:
       sed -i 's/^verb .*/verb 5/' /opt/vpn334-lab/server/server.conf
       ./334.4-vpn-break-fix.sh restart
       grep -iE 'tls-crypt|unwrap|authenticat' /opt/vpn334-lab/server/server.log

3. --tls-crypt wraps AND authenticates every control-channel packet with a
   pre-shared 2048-bit static key before TLS is parsed. A packet that fails the
   HMAC is dropped SILENTLY and cheaply -- that is the point: it hides the TLS
   stack from scanners and absorbs DoS. Same idea as the older --tls-auth, which
   only authenticated (and needed --key-direction 0/1 -- a classic exam trap:
   tls-auth requires OPPOSITE key directions on the two peers, tls-crypt does not).

4. Prove the keys differ and re-distribute the correct one:
       cmp /opt/vpn334-lab/pki/tc.key /opt/vpn334-lab/pki/tc-client.key
       cp  /opt/vpn334-lab/pki/tc.key /opt/vpn334-lab/pki/tc-client.key
       chmod 600 /opt/vpn334-lab/pki/tc-client.key
       ./334.4-vpn-break-fix.sh restart
       ip netns exec vpn-right ping -c2 10.8.0.1

5. Regenerating with `openvpn --genkey secret ta.key` is how you ROTATE it, but
   the new key must reach every client at the same time. For per-client keys use
   --tls-crypt-v2 (2.5+), which lets each client hold a distinct wrapped key.

SCENARIO 3 -- X.509 extendedKeyUsage (EKU) on the client certificate
1. The log distinguishes the two failures precisely:
       VERIFY OK: depth=1, ... CN=teach-plat 334.4 Lab CA      <- chain is fine
       VERIFY EKU ERROR: require extendedKeyUsage TLS Web Client Authentication
   Chain validation and purpose validation are different checks (RFC 5280 s4.2.1.12).

2. Inspect what the client actually presents:
       grep -E '^(cert|key) ' /opt/vpn334-lab/client/client.conf
       openssl x509 -noout -subject -issuer -dates \
           -ext extendedKeyUsage,keyUsage,basicConstraints \
           -in /opt/vpn334-lab/pki/client-bad.crt
   Output shows:  X509v3 Extended Key Usage: TLS Web Server Authentication
   while  openssl verify -CAfile /opt/vpn334-lab/pki/ca.crt \
                         /opt/vpn334-lab/pki/client-bad.crt   ->  OK
   A perfectly valid certificate, issued for the wrong PURPOSE.

3. --remote-cert-tls client is shorthand for
       --remote-cert-ku (digitalSignature / keyEncipherment)
       --remote-cert-eku "TLS Web Client Authentication"
   Keeping it is what stops a leaked SERVER certificate from being replayed as a
   client credential -- the classic OpenVPN MITM described in the HOWTO.

4. Point the client at the correctly issued certificate and restart:
       sed -i 's#^cert .*#cert /opt/vpn334-lab/pki/client.crt#;\
               s#^key .*#key /opt/vpn334-lab/pki/client.key#' \
           /opt/vpn334-lab/client/client.conf
       ./334.4-vpn-break-fix.sh restart
       openssl x509 -noout -ext extendedKeyUsage -in /opt/vpn334-lab/pki/client.crt
       ip netns exec vpn-right ping -c2 10.8.0.1

5. If instead you must RE-ISSUE, the extension file is what matters:
       printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\n%s\n' \
              'extendedKeyUsage=clientAuth' > client.ext
       openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
               -days 825 -sha256 -extfile client.ext -out client.crt
   With easy-rsa the equivalent is:  ./easyrsa build-client-full vpn-client nopass

SCENARIO 4 -- --route (kernel) vs --iroute (OpenVPN internal routing)
1. Separate the two layers before touching anything:
       ip netns exec vpn-right ping -c2 10.8.0.1              # tunnel OK
       ip netns exec vpn-right ping -c2 -I 172.16.20.1 172.16.10.1   # LAN fails
       ip netns exec vpn-right ip route            # 172.16.10.0/24 via 10.8.0.1 -> present
       ip netns exec vpn-left  ip route            # 172.16.20.0/24 dev tun0     -> present
   Both kernel tables are correct, so the problem is INSIDE openvpn.

2. The server log names the culprit:
       grep -i 'bad source address' /opt/vpn334-lab/server/server.log
       MULTI: bad source address from client [172.16.20.1], packet dropped
   The multi-client server received a packet whose source is not in ANY connected
   client's internal route list, so it refuses it (anti-spoofing).

3. The distinction that this objective exists to test:
       --route  172.16.20.0 255.255.255.0   in server.conf
                -> tells the SERVER'S KERNEL to hand that subnet to tun0
       --iroute 172.16.20.0 255.255.255.0   in the client-config-dir file
                -> tells OPENVPN which connected client owns that subnet
   Both are required for a client-side LAN. Only the second one was removed.

4. Recreate the CCD entry. The FILE NAME must equal the client certificate's
   common name (X509 CN = vpn-client) -- or the value of --username-as-common-name
   when using --auth-user-pass-verify:
       grep -H client-config-dir /opt/vpn334-lab/server/server.conf
       printf 'iroute 172.16.20.0 255.255.255.0\n' \
           > /opt/vpn334-lab/server/ccd/vpn-client
       ./334.4-vpn-break-fix.sh restart

5. Verify at both layers, and read the internal table:
       ip netns exec vpn-right ping -c2 -I 172.16.20.1 172.16.10.1
       cat /opt/vpn334-lab/server/status.log      # ROUTING TABLE section lists
                                                  # 172.16.20.0/24 -> vpn-client
   Common variants of the same bug in production: the CCD file is named after the
   wrong CN, --client-config-dir is a relative path and openvpn chrooted/chdir'd
   away from it, or the file is unreadable after --user nobody drops privileges.

SCENARIO 5 -- IPsec ESP Security Association key mismatch (XFRM/SAD)
1. Confirm ciphertext actually arrives, so this is not a routing/firewall issue:
       ip netns exec vpn-right timeout 5 tcpdump -ni veth-r esp
       -> ESP(spi=0x0334a001,seq=0x1), length 132     (packets ARE arriving)

2. Read the counters, which is what separates a guess from a diagnosis:
       ip netns exec vpn-left  ip -s xfrm state     # outbound SA: packets climbing
       ip netns exec vpn-right ip -s xfrm state     # inbound  SA: still 0 packets
       ip netns exec vpn-right cat /proc/net/xfrm_stat | grep -v ' 0$'
       ip netns exec vpn-right nstat -az | grep -i xfrm
   Exactly one XfrmIn* error counter grows once per ping. The SA exists and the
   SPI matches (otherwise you would see XfrmInNoStates); the packet is being
   rejected during ESP processing => the crypto material disagrees.
   Live view of every SA/policy event:  ip netns exec vpn-right ip xfrm monitor

3. Diff the two halves of the same one-way SA:
       ip netns exec vpn-left  ip xfrm state get src 10.10.0.1 dst 10.10.0.2 \
                                   proto esp spi 0x0334a001
       ip netns exec vpn-right ip xfrm state get src 10.10.0.1 dst 10.10.0.2 \
                                   proto esp spi 0x0334a001
   The auth-trunc hmac(sha256) key differs. An SA is a UNIDIRECTIONAL contract:
   (dst, SPI, protocol) identifies it, and mode, reqid, algorithms and key
   material must be byte-identical on both peers (RFC 4301 s4.4.2).

4. Repair gateway B's inbound SA with the sender's key (states are immutable in
   the relevant fields -- delete, then re-add):
       AUTH=<the auth-trunc key printed by the vpn-left dump>
       ENC=<the enc key printed by the vpn-left dump>
       ip netns exec vpn-right ip xfrm state delete \
           src 10.10.0.1 dst 10.10.0.2 proto esp spi 0x0334a001
       ip netns exec vpn-right ip xfrm state add \
           src 10.10.0.1 dst 10.10.0.2 proto esp spi 0x0334a001 reqid 3341 mode tunnel \
           auth-trunc 'hmac(sha256)' $AUTH 128 enc 'cbc(aes)' $ENC
       ip netns exec vpn-left ping -c2 -I 172.16.10.1 172.16.20.1

5. What this maps to in the real world -- you almost never key IPsec by hand:
   charon installs exactly these SAD/SPD entries after IKEv2 (RFC 7296). The
   equivalent troubleshooting on a strongSwan box is
       swanctl --list-conns          # what is configured
       swanctl --list-sas            # IKE_SA + CHILD_SA, with the negotiated proposal
       swanctl --initiate --child net-net
       swanctl --load-all            # after editing /etc/swanctl/swanctl.conf
       journalctl -u strongswan -f   # or charon's filelog
       ip xfrm state ; ip xfrm policy ; ip -s xfrm state    # the kernel's own view
   and the classic causes of "IKE_SA established, no traffic passes" are: mismatched
   proposals / esp_proposals, traffic selectors (local_ts/remote_ts) that do not
   mirror, a missing NAT-T UDP/4500 hole, or a firewall dropping ESP (protocol 50)
   -- never a "wrong password", which would have failed at IKE_AUTH instead.
   Docs: https://docs.strongswan.org/docs/latest/swanctl/swanctlConf.html

 When you are done:   ./334.4-vpn-break-fix.sh clean
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-3-303/334.4/lab)
