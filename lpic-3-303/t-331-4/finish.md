## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
===========================  SOLUTION  =======================================
Everything below is commented out on purpose. Read it after 'verify' passes,
or when you have truly stalled. Paths assume the defaults printed by the lab:
  LAB=/var/cache/bind/lab-331-4 (or /var/named/lab-331-4, or /var/tmp/...)
  ZONE=dnslab.internal, auth 127.0.0.1:5301, resolver 127.0.0.1:5302, TLS 8443

  LAB=$(ls -d /var/cache/bind/lab-331-4 /var/named/lab-331-4 /var/tmp/lab-331-4 2>/dev/null | head -1)
  ZONE=dnslab.internal
  RNDC_AUTH="rndc -c $LAB/rndc-auth.conf"
  RNDC_RES="rndc -c $LAB/rndc-res.conf"

STEP 0 - Establish WHERE the failure is, before touching anything
  dig @127.0.0.1 -p 5302 www.$ZONE A            # SERVFAIL
  dig @127.0.0.1 -p 5302 +cd www.$ZONE A        # NOERROR  <- data exists
  dig @127.0.0.1 -p 5301 +norec www.$ZONE A     # NOERROR  <- source is fine

Reading: the authoritative server has the data, the resolver can reach it, and
the answer only survives when validation is disabled (+cd, Checking Disabled).
Therefore the failure is the validator rejecting the data. Never "restart
named and see"; the verdict is already written down.

  $RNDC_RES trace 3                             # debug level 3
  dig @127.0.0.1 -p 5302 www.$ZONE A >/dev/null
  tail -40 $LAB/resolver/named.log

You will see lines of the form:
    validating dnslab.internal/A: verify failed due to bad signature
    ... RRSIG has expired
    validating dnslab.internal/A: no valid signature found
    broken trust chain resolving 'www.dnslab.internal/A/IN'
  $RNDC_RES trace 0                             # back to normal afterwards

The same conclusion in one command, in plain language:
  delv @127.0.0.1 -p 5302 +rtrace www.$ZONE A
    ;; resolution failed: SERVFAIL       (and with +vtrace, the failing step)

STEP 1 - FAULT A: every RRSIG in the zone is expired
Read the signature's own metadata. RRSIG rdata order (RFC 4034 s3.1):
  type-covered  algorithm  labels  original-TTL  EXPIRATION  INCEPTION
  key-tag  signer-name  signature

  dig @127.0.0.1 -p 5301 +dnssec +norec +multiline www.$ZONE A
  dig @127.0.0.1 -p 5301 +dnssec +norec +noall +answer www.$ZONE A | awk '$4=="RRSIG"{print $9,$10}'
  date -u +%Y%m%d%H%M%S

Expiration is in the past -> RFC 4035 s5.3.1 requires the validator to treat
the RRset as bogus. Nothing is corrupt; the zone is stale.

Fix - re-sign with the default (sane) validity window and reload:

  cd $LAB/auth
  dnssec-signzone -S -K keys -o $ZONE -N INCREMENT -f db.$ZONE.signed db.$ZONE
      # -S  smart signing: find the keys in -K, publish the DNSKEY RRset
      # -N INCREMENT  bump the SOA serial (secondaries need this)
      # default validity: now-1h .. now+30d ; override with -s / -e
      # add -3 $(openssl rand -hex 8) if you want NSEC3 instead of NSEC
  named-checkzone -D -o /dev/null $ZONE db.$ZONE.signed | tail -1   # sanity
  $RNDC_AUTH reload $ZONE
  $RNDC_RES flush                # drop the cached SERVFAIL / bogus state
  dig @127.0.0.1 -p 5302 +dnssec www.$ZONE A | grep -E 'flags|status'
      # -> status: NOERROR ... flags: qr rd ra ad     <- the 'ad' bit is the goal

The 'ad' (Authenticated Data) flag is the only proof that validation actually
happened. NOERROR without 'ad' means "insecure", not "verified".

In production you do not re-sign by hand. Either a scheduled re-signing job,
or - much better on BIND 9.16+ - inline, automatic maintenance:
    zone "example.com" { type primary; file "db.example.com";
                         dnssec-policy default; inline-signing yes; };
which keeps signatures fresh and rolls the ZSK for you.

STEP 2 - (hard mode) FAULT C: the trust anchor no longer matches any DNSKEY
If step 1 did not restore the 'ad' flag, the chain of trust itself is broken.
With no signed parent there is no DS record: the resolver's configured anchor
IS the entry point, so compare key tags.

  # tag of the KSK the zone is actually using (flags 257):
  dnssec-dsfromkey -a SHA-256 $LAB/auth/keys/K$ZONE.+*.key
      # output: dnslab.internal. IN DS <KEYTAG> 13 2 <digest>
  # what the resolver was told to trust:
  cat $LAB/resolver/trust-anchor.conf
  # what actually signs the DNSKEY RRset:
  dig @127.0.0.1 -p 5301 +dnssec +norec $ZONE DNSKEY | awk '$4=="RRSIG"{print "signed by key tag",$11}'

Different tags -> the anchor is from a KSK that no longer exists (a rollover
where the anchor update was forgotten). Rebuild the anchor from the current
KSK - the .key file line is DNSKEY rdata, and static-key takes the same
fields (flags protocol algorithm "base64"):

  KSKFILE=$(grep -l 'key-signing key' $LAB/auth/keys/K$ZONE.+*.key)
  awk '!/^;/{for(i=1;i<=NF;i++) if($i=="DNSKEY"){s="";for(j=i+4;j<=NF;j++)s=s $j;
       printf "trust-anchors {\n    \"'$ZONE'.\" static-key %s %s %s \"%s\";\n};\n",
       $(i+1),$(i+2),$(i+3),s; exit}}' "$KSKFILE" > $LAB/resolver/trust-anchor.conf
  named-checkconf $LAB/named-res.conf
  # a trust-anchors change requires a reconfig + flush (or a restart):
  $RNDC_RES reconfig && $RNDC_RES flush
  dig @127.0.0.1 -p 5302 +dnssec www.$ZONE A | grep flags     # expect 'ad'

Operational lesson: this is why RFC 5011 automated anchor rollover exists, and
why BIND writes anchors as 'initial-key' (managed, auto-updating) rather than
'static-key' (frozen) wherever the zone supports it. A static anchor is a
manual dependency you must include in every key-rollover runbook.

STEP 3 - FAULT B: the DANE pin does not match the served certificate
Now that DNS validates, the TLS monitor is still red. Compare the two halves.

  # what DNS pins (usage 3 = DANE-EE, selector 1 = SPKI, mtype 1 = SHA-256):
  dig +short @127.0.0.1 -p 5302 TLSA _8443._tcp.www.$ZONE
  # what the server is actually presenting, hashed the same way:
  echo Q | openssl s_client -connect 127.0.0.1:8443 2>/dev/null \
    | openssl x509 -pubkey -noout \
    | openssl pkey -pubin -outform DER \
    | openssl dgst -sha256

The hashes differ: the certificate/keypair was rotated and the pin was not
republished. Note the selector - hashing the whole certificate (selector 0)
would give yet another value; TLSA 3 1 1 hashes only the SubjectPublicKeyInfo,
which is why selector 1 survives certificate renewal with the SAME key.

Fix - regenerate the rdata from the live endpoint and publish it in the
UNSIGNED source zone, then re-sign. Never edit db.$ZONE.signed: the next
signing run overwrites it, and an edit there is unsigned data anyway.

  HEX=$(echo Q | openssl s_client -connect 127.0.0.1:8443 2>/dev/null \
        | openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER \
        | openssl dgst -sha256 | awk '{print $NF}')
  echo "$HEX"
  cd $LAB/auth
  sed -i -E "s|^(_8443\._tcp\.www[[:space:]]+IN TLSA 3 1 1 ).*|\1$HEX|" db.$ZONE
  grep TLSA db.$ZONE
  named-checkzone $ZONE db.$ZONE
  dnssec-signzone -S -K keys -o $ZONE -N INCREMENT -f db.$ZONE.signed db.$ZONE
  $RNDC_AUTH reload $ZONE
  $RNDC_RES flush

Verify DANE end to end, taking the rdata from DNS (never from a local file -
the point of DANE is that DNS is the authority):

  RR=$(dig +short @127.0.0.1 -p 5302 TLSA _8443._tcp.www.$ZONE)
  echo Q | openssl s_client -connect 127.0.0.1:8443 -servername www.$ZONE \
      -dane_tls_domain www.$ZONE -dane_tls_rrdata "$RR" 2>&1 | \
      grep -E 'DANE TLSA|Verify return code'
    # -> DANE TLSA 3 1 1 ...ee1... matched EE certificate at depth 0
    # -> Verify return code: 0 (ok)

(A DANE-aware client would fetch that TLSA record through a VALIDATING
 resolver and refuse to proceed on SERVFAIL. openssl s_client does no DNS
 itself, hence -dane_tls_rrdata; tools such as 'danetool --check' or
 hash-slinger's 'tlsa' do the lookup for you.)

STEP 4 - Confirm and close
  ./331.4-break-fix-dns-crypto.sh verify        # all six checks green
  ./331.4-break-fix-dns-crypto.sh clean         # remove the lab

WHAT THE EXAM EXPECTS YOU TO CARRY OUT OF THIS
* dnssec-keygen / dnssec-signzone / dnssec-settime / dnssec-dsfromkey and what
  each artifact is: K<zone>.+<alg>+<tag>.key (public DNSKEY, safe to publish),
  .private (never leaves the signer), dsset-* (what the parent publishes),
  db.zone.signed (what named serves).
* KSK (flags 257, signs the DNSKEY RRset, anchored by the parent's DS) versus
  ZSK (flags 256, signs everything else, rolled often and cheaply).
* RRSIG / DNSKEY / DS / NSEC / NSEC3 / NSEC3PARAM and, for DANE, TLSA - plus
  the sibling records SSHFP, OPENPGPKEY and SMIMEA which use the same idea.
* dig +dnssec / +cd / +multiline and delv (+rtrace, +vtrace, -a anchorfile):
  dig shows you the bytes, delv performs the validation and names the failure.
* The AD flag means validated; the CD flag means "do not validate for me".
  A client that sets CD to make an error disappear has disabled the control.
* Signatures expire, keys roll, anchors go stale: DNSSEC failures are
  overwhelmingly ${operational}, not cryptographic. dnssec-policy exists
  precisely to take those duties away from humans.
* DANE rollover order (RFC 7671 s8): publish the new TLSA record, wait at
  least the record's TTL so caches converge, THEN deploy the new certificate,
  and only afterwards withdraw the old TLSA record. This lab is what happens
  when that order is reversed.
* rndc talks to named over an authenticated channel using a TSIG key
  (hmac-sha256) - the same mechanism (RFC 8945) that authenticates zone
  transfers and dynamic updates.

Objectives: https://www.lpi.org/our-certifications/exam-303-objectives/
BIND DNSSEC guide: https://bind9.readthedocs.io/en/latest/dnssec-guide.html
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-3-303/331.4/lab)
