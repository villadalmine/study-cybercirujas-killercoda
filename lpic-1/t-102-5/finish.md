## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION - do not read before you have tried, and failed, on your own.

 GENERAL METHOD
 Fix in dependency order. rpm(8) is the foundation: dnf/yum are Python (or
 C++, in dnf5) front ends built on top of librpm, so if librpm cannot open
 the database, every higher-level diagnosis is noise. Then repositories
 (where packages come from), then trust (GPG), then policy (exclude), then
 on-disk integrity.

 FAULT 1 - rpm cannot open its database (%_dbpath override)
 Symptom
     # rpm -qa | wc -l
     error: cannot open /var/lib/rpm.lpic1-102.5.missing/Packages index using
            sqlite: No such file or directory
     0
     # dnf list --installed
     Error: Could not open the rpmdb ...

 Diagnosis
     # rpm -E '%_dbpath'
     /var/lib/rpm.lpic1-102.5.missing

     %_dbpath is an RPM macro, not a compiled-in constant. rpm evaluates its
     macro files in this order (see `rpm --showrc | head -20`):
         /usr/lib/rpm/macros
         /usr/lib/rpm/macros.d/macros.*
         /usr/lib/rpm/platform/<target>/macros
         /etc/rpm/macros.*          <-- our override lives here
         /etc/rpm/macros
         /etc/rpm/<target>/macros
         ~/.rpmmacros
     The LAST definition wins, so anything under /etc/rpm beats the
     distribution defaults.

     # rpm --showrc | grep -i '_dbpath'
     -14: _dbpath   /var/lib/rpm.lpic1-102.5.missing
     # ls -lt /etc/rpm/
     -rw-r--r--. 1 root root 210 ... macros.zz-lpic1-102.5
     # cat /etc/rpm/macros.zz-lpic1-102.5

     Confirm the real database is untouched (it is - only the pointer moved):
     # ls -l /var/lib/rpm/
     # rpm -qa --dbpath /var/lib/rpm | wc -l
     532

 Repair
     # rm -f /etc/rpm/macros.zz-lpic1-102.5
     # rpm -E '%_dbpath'
     /var/lib/rpm
     # rpm -qa | wc -l
     532

     If the database had genuinely been corrupted (stale __db.* locks on the
     old Berkeley DB backend, an interrupted transaction, a full /var):
     # cp -a /var/lib/rpm /var/lib/rpm.bak-$(date +%F)
     # rm -f /var/lib/rpm/__db.*        # BDB backend only (EL7 era)
     # rpm --rebuilddb -vv
     On EL9+/Fedora the backend is sqlite (%_db_backend sqlite):
     # sqlite3 /var/lib/rpm/rpmdb.sqlite 'PRAGMA integrity_check;'

 FAULT 2 - repository metadata cannot be downloaded
 Symptom
     # dnf makecache --refresh
     Errors during downloading metadata for repository 'baseos':
       - Curl error (7): Couldn't connect to server for
         http://127.0.0.1:9/lpic1-102.5/broken/os/repodata/repomd.xml
     Error: Failed to download metadata for repo 'baseos'

 Diagnosis
     # dnf repolist --all
     # dnf config-manager --dump baseos | grep -E 'baseurl|metalink|mirrorlist'
     # grep -n . /etc/yum.repos.d/<distro>.repo
     12:[baseos]
     13:baseurl=http://127.0.0.1:9/lpic1-102.5/broken/os/
     ...
     17:#lpic1-102.5-disabled mirrorlist=https://mirrors.rockylinux.org/...

     The original metadata source was commented out, not deleted. A
     hand-written baseurl pointing at loopback is never a distribution
     default: base repositories use metalink (Fedora) or mirrorlist (EL).

 Repair (option A - edit the file back to its shipped state)
     # cp /etc/yum.repos.d/<distro>.repo{,.bak}
     # sed -i -e '/^baseurl=http:\/\/127\.0\.0\.1:9\//d' \
              -e 's/^#lpic1-102\.5-disabled //' /etc/yum.repos.d/<distro>.repo

 Repair (option B - reinstall the file from its owning package, the robust way)
     # rpm -qf /etc/yum.repos.d/<distro>.repo
     rocky-repos-9.x-...
     # rpm -V rocky-repos
     S.5....T.  c /etc/yum.repos.d/rocky.repo
     # dnf reinstall -y rocky-repos          # .rpmorig/.rpmnew handling applies
     or, without touching the package:
     # dnf download rocky-repos && rpm2cpio rocky-repos-*.rpm | \
           cpio -idmv ./etc/yum.repos.d/rocky.repo

 Validate
     # dnf clean all && rm -rf /var/cache/dnf/*
     # dnf makecache --refresh
     # dnf repolist --enabled
     repo id      repo name
     appstream    Rocky Linux 9 - AppStream
     baseos       Rocky Linux 9 - BaseOS

 FAULT 3 - the signing key is gone from the RPM database
 Symptom
     # dnf install -y tree
     warning: /var/cache/dnf/.../tree-2.1.0-2.el9.x86_64.rpm: Header V4
              RSA/SHA256 Signature, key ID 350d275d: NOKEY
     Public key for tree-2.1.0-2.el9.x86_64.rpm is not installed. Failing
     package is: tree-2.1.0-2.el9.x86_64
     GPG Keys are configured as: file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9

 Diagnosis
     Imported keys are stored as pseudo-packages named gpg-pubkey in the
     rpmdb; the armoured key itself is the package description.
     # rpm -q gpg-pubkey
     package gpg-pubkey is not installed        <-- the trust store is empty
     # ls -l /etc/pki/rpm-gpg/                  <-- but the key files exist
     # rpm -K /var/cache/dnf/*/packages/tree-*.rpm
     tree-2.1.0-2.el9.x86_64.rpm: digests SIGNATURES NOT OK

 Repair
     # rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-*
     # rpm -q gpg-pubkey --qf '%{NAME}-%{VERSION}-%{RELEASE}\t%{SUMMARY}\n'
     gpg-pubkey-350d275d-65e4b7a5   gpg(Rocky Linux 9 Official Signing Key)
     # rpm -qi gpg-pubkey-350d275d-65e4b7a5     # full armoured key + fingerprint
     # rpm -K /var/cache/dnf/*/packages/tree-*.rpm
     tree-2.1.0-2.el9.x86_64.rpm: digests signatures OK

     Never "solve" this with --nogpgcheck or gpgcheck=0: that turns a trust
     failure into a silent supply-chain hole. Always compare the fingerprint
     against the vendor's published value before importing.

 FAULT 4 - an installed file no longer matches the package metadata
 Symptom
     $ passwd                       (as an unprivileged user)
     passwd: Authentication token manipulation error

 Diagnosis
     # rpm -Va | head
     .M.......    /usr/bin/passwd
     # rpm -Vf /usr/bin/passwd
     .M.......    /usr/bin/passwd
     # rpm -qf /usr/bin/passwd
     passwd-0.80-12.el9.x86_64
     # ls -l /usr/bin/passwd
     -rwxr-xr-x. 1 root root 32552 ... /usr/bin/passwd     <-- setuid gone
     # rpm -q --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' passwd | grep passwd
     -rwsr-xr-x /usr/bin/passwd                            <-- what it should be

     'M' means the mode differs; the leading dot in position 3 means the
     content digest is still correct, so the binary itself was not tampered
     with - only its permission bits.

 Repair (preferred: let rpm apply its own metadata, no octal typing)
     # rpm --restore passwd            # rpm >= 4.17 (EL9, Fedora)
     # rpm --setperms passwd           # older rpm (EL7/EL8)
     # rpm -V passwd                   # no output == clean
     # ls -l /usr/bin/passwd
     -rwsr-xr-x. 1 root root 32552 ... /usr/bin/passwd

     Manual equivalent (know it, but prefer the above):
     # chmod 4755 /usr/bin/passwd

     If the digest had also changed (S.5....T.), the file content itself is
     wrong and permissions are not enough:
     # dnf reinstall -y passwd

 FAULT 5 - a package that exists in the repository cannot be installed
 Symptom
     # dnf install tree
     No match for argument: tree
     Error: Unable to find a match: tree

 Diagnosis
     The package IS in the metadata, so this is a client-side policy, not a
     missing package:
     # dnf repoquery tree
     tree-0:2.1.0-2.el9.x86_64
     # dnf --disableexcludes=all list --available tree     # works -> exclusion
     # grep -rn '^[[:space:]]*exclude' /etc/dnf/dnf.conf /etc/yum.repos.d/
     /etc/dnf/dnf.conf:6:exclude=tree*
     # dnf config-manager --dump | grep -i exclude

     exclude= in the [main] section of dnf.conf/yum.conf applies globally;
     the same key inside a [repo] section applies to that repository only.
     versionlock and other plugins can produce an identical symptom:
     # dnf versionlock list ; ls /etc/dnf/plugins/

 Repair
     # cp /etc/dnf/dnf.conf{,.bak}
     # sed -i '/^exclude=tree\*/d;/lpic1-102.5 lab marker/d' /etc/dnf/dnf.conf
     # dnf clean expire-cache
     # dnf list --available tree
     Available Packages
     tree.x86_64            2.1.0-2.el9            baseos

 FINAL VALIDATION
     # rpm -E '%_dbpath'                       -> /var/lib/rpm
     # rpm -qa | wc -l                         -> 532
     # dnf repolist --enabled                  -> base repositories listed
     # rpm -q gpg-pubkey | wc -l               -> >= 1
     # rpm -V passwd                           -> (no output)
     # dnf install -y tree                     -> Complete!
     # rpm -q tree && rpm -qi tree | head -12
     # rpm -ql tree ; rpm -qc tree ; rpm -qd tree
     # dnf history                             -> the transaction is recorded
     # ./lpic1-102.5-rpm-yum-breakfix.sh verify
     RESULT: 5/5 - system restored. Objective 102.5 met.

     Roll back the whole exercise (and remove the lab package) with:
     # ./lpic1-102.5-rpm-yum-breakfix.sh restore
     # dnf history undo last          # or: dnf remove -y tree
     # rm -rf /var/tmp/lpic1-102.5-breakfix

 WHY EACH FAULT MATTERS IN PRODUCTION
  1. %_dbpath / rpmdb corruption is the classic aftermath of a full /var, a
     container image built with two different rpm backends, or a restore that
     copied /etc/rpm from another host. Symptom: "the server thinks nothing
     is installed".
  2. A hard-coded baseurl that survives a distribution major upgrade is the
     single most common cause of "dnf update stopped working" after a
     release rebase - $releasever no longer resolves to a live mirror path.
  3. Missing gpg-pubkey entries appear on golden images built with
     --nogpgcheck. The fleet then installs unverified packages for years.
     `rpm -qa gpg-pubkey` belongs in your compliance baseline.
  4. `rpm -Va` is a poor man's host IDS: it compares every installed file
     against the signed package metadata. Run it from a rescue environment
     when you suspect compromise, and remember it trusts the local rpmdb -
     which an attacker with root can rewrite.
  5. A stale exclude= (usually added to freeze a kernel during an incident
     and never removed) silently keeps hosts unpatched. Audit exclude= and
     versionlock entries the same way you audit firewall rules.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/102.5/lab)
