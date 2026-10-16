## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
==== SOLUTION START =========================================================

 ANSWER KEY — do not read until you have genuinely tried.
 Every command below is meant to be run as root on the lab VM.
 LOOP=$(losetup -j /var/lib/breakfix-331-3/images/luks.img | cut -d: -f1)
 PLOOP=$(losetup -j /var/lib/breakfix-331-3/images/plain.img | cut -d: -f1)

 SCENARIO 1 — header : primary LUKS2 header destroyed, secondary intact

 Why it still works
 A LUKS2 container carries its metadata twice. The on-disk layout is:

     offset 0      : primary binary header  (4096 B) magic "LUKS" 0xba 0xbe
     offset 4096   : primary JSON area      (12 KiB by default)
     offset 16384  : secondary binary header, magic "SKUL" 0xba 0xbe
     offset 20480  : secondary JSON area
     ...           : keyslot (binary key material) area
     data offset   : the encrypted filesystem itself (16 MiB in by default)

 Zeroing 4 KiB at offset 0 kills only the primary copy. cryptsetup detects the
 checksum mismatch, falls back to the secondary, warns, and carries on. LUKS1
 has no such redundancy — the same dd would have been fatal there. This is one
 of the concrete LUKS2 improvements the objective expects you to name.

 1. Confirm the diagnosis rather than assuming it:

      dd if=$LOOP bs=1 count=6 status=none | od -An -c
      #  \0  \0  \0  \0  \0  \0        <- primary magic gone
      dd if=$LOOP bs=1 skip=16384 count=6 status=none | od -An -c
      #   S   K   U   L 272 276        <- secondary magic present ("SKUL")

      cryptsetup luksDump $LOOP
      #  a warning about the primary header, then a normal dump

 2. Rebuild the primary from the secondary. This is exactly what `repair` does:

      cryptsetup repair $LOOP
      #  WARNING!
      #  ========
      #  Really try to repair LUKS device header?
      #  Are you sure? (Type 'yes' in capital letters): YES

    Read `man cryptsetup` on repair first: it reconciles the two copies and,
    if you run it when the *secondary* is the damaged one, it will happily
    propagate the good primary — but if BOTH are damaged it can make things
    worse. On a production incident, luksHeaderBackup the device as-is before
    running repair, so you always have the "before" state.

 3. Verify the magic came back and the data is reachable:

      dd if=$LOOP bs=1 count=6 status=none | od -An -tx1
      #  4c 55 4b 53 ba be
      cryptsetup open $LOOP lab331          # passphrase: Lab-331.3-cryptsetup
      mount /dev/mapper/lab331 /mnt/lab331
      cat /mnt/lab331/CANARY.txt

      ./break-fix-331.3-encrypted-filesystems.sh verify header

 SCENARIO 2 — nuke : the whole 16 MiB header area is gone

 1. Confirm there is nothing left to repair:

      cryptsetup isLuks -v $LOOP
      #  Device /dev/loop0 is not a valid LUKS device.
      blkid $LOOP                          # silent
      dd if=$LOOP bs=1 skip=16384 count=6 status=none | od -An -c   # noise

    `cryptsetup repair` is useless here: repair needs one intact copy.

 2. Restore the header backup taken before the incident:

      cryptsetup luksHeaderRestore $LOOP \
          --header-backup-file /var/lib/breakfix-331-3/backup/luks-header-lab331.img
      #  Device /dev/loop0 does not contain LUKS header. Replacing header can
      #  destroy data on that device.
      #  Are you sure? (Type 'yes' in capital letters): YES

    Add --batch-mode to skip the prompt in a script. luksHeaderRestore rewrites
    the ENTIRE header area, keyslots included, which is why the passphrase that
    was valid when the backup was taken is valid again now.

 3. Prove recovery:

      cryptsetup luksDump $LOOP | head -20
      cryptsetup open $LOOP lab331
      mount /dev/mapper/lab331 /mnt/lab331 && cat /mnt/lab331/CANARY.txt

 4. Bonus answer — what could an attacker with a six-month-old header backup
    decrypt today? Everything, if they also learn any passphrase that was
    valid at backup time. A LUKS keyslot wraps the MASTER KEY; the master key
    never changes for the life of the container. Deleting a keyslot, or even
    changing every passphrase, does not re-encrypt the data. Consequences:
      - store header backups with the same care as the data itself (encrypted,
        offline, access-logged);
      - after a credential leak the only real remediation is
        `cryptsetup reencrypt` (LUKS2, online) or a fresh container + restore;
      - `cryptsetup luksHeaderBackup` output is a secret, not a config file.

 SCENARIO 3 — keyslot : the passphrase keyslot was killed

 1. Diagnose. The header is fine, one credential is missing:

      cryptsetup luksDump $LOOP | sed -n '/Keyslots:/,/Tokens:/p'
      #  Keyslots:
      #    1: luks2 ...            <- only slot 1; slot 0 is gone

      cryptsetup luksOpen --test-passphrase $LOOP        # type the passphrase
      #  No key available with this passphrase.

    --test-passphrase checks a credential without creating a mapping. Use it
    in scripts and during triage; it is the polite way to ask "does this key
    still work?".

 2. Route A (preferred in production) — open with the surviving credential and
    re-add a passphrase. Nothing is rolled back, the audit trail is intact:

      cryptsetup open --key-file /etc/luks-keys/lab331.key $LOOP lab331

      # --key-file supplies the EXISTING credential; the new one is prompted
      # for interactively. Ask explicitly for slot 0 to restore the documented
      # layout. The weak PBKDF flags are lab-only.
      cryptsetup luksAddKey --key-file /etc/luks-keys/lab331.key \
          --key-slot 0 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 $LOOP
      #  Enter new passphrase for key slot: Lab-331.3-cryptsetup
      #  Verify passphrase: Lab-331.3-cryptsetup

    Related keyslot verbs you are expected to know:
      luksRemoveKey   <dev>            remove the slot matching a passphrase
      luksKillSlot    <dev> <n>        remove slot n (needs another credential)
      luksChangeKey   <dev>            replace a passphrase in place
      luksDump --dump-json-metadata    the LUKS2 JSON, keyslots/segments/digests
      cryptsetup token add/list        LUKS2 tokens (e.g. systemd-tpm2, FIDO2)

 3. Route B — restore the header backup, which un-deletes slot 0:

      cryptsetup luksHeaderRestore $LOOP \
          --header-backup-file /var/lib/breakfix-331-3/backup/luks-header-lab331.img

    It works, and that is precisely the problem. If you had killed that slot
    because the passphrase leaked, restoring the backup silently re-arms the
    leaked credential. Never use header restore as a "fix" for a revocation.
    Route A is the correct production answer; Route B is for disaster recovery
    of a header you did not intend to change.

 4. Verify:

      mount /dev/mapper/lab331 /mnt/lab331 && cat /mnt/lab331/CANARY.txt
      ./break-fix-331.3-encrypted-filesystems.sh verify keyslot

 SCENARIO 4 — crypttab : three faults in the boot-time wiring

 Method: fix ONE fault, re-test, read the NEW error. Each fix reveals the next
 failure, and the error messages are different — that is the whole skill.

 FAULT 1 — the UUID in /etc/crypttab does not match the device.

      cryptsetup luksUUID $LOOP
      #  8e3c...c4a7
      grep -A3 'breakfix-331-3 BEGIN' /etc/crypttab
      #  lab331  UUID=8e3c...c4a6   /etc/luks-keys/lab331.key  luks,nofail,...
      ls -l /dev/disk/by-uuid/ | grep -i 8e3c

    The last character differs. Fix it with the real UUID:

      UUID=$(cryptsetup luksUUID $LOOP)
      sed -i "/^lab331\b/s|UUID=[0-9a-f-]*|UUID=$UUID|" /etc/crypttab
      systemctl daemon-reload      # MANDATORY: the unit is generated, not read
      systemctl start systemd-cryptsetup@lab331.service

    /etc/crypttab field order (man 5 crypttab):
        <target name> <source device> <key file> <options>
    Common options: luks, nofail, discard, tries=, timeout=, keyfile-timeout=,
    keyfile-offset=, keyfile-size=, header=, noauto, x-systemd.device-timeout=.
    The key-file field may be 'none' (prompt), a path, or a device.
    systemd-cryptsetup-generator turns each line into a unit at daemon-reload;
    on sysvinit Debian the equivalent runner is cryptdisks_start/cryptdisks_stop.

 FAULT 2 — the keyfile has an extra byte.

      journalctl -u systemd-cryptsetup@lab331.service -n 20 --no-pager
      #  Failed to activate with key file '/etc/luks-keys/lab331.key' ...

      wc -c /etc/luks-keys/lab331.key        #  513   <- should be 512
      od -c /etc/luks-keys/lab331.key | tail -3
      #  ... \n     <- a newline was appended

    A keyfile is raw key material, not text. cryptsetup hashes every byte it
    reads, so one stray \n from `echo`, an editor's "add final newline", or a
    `cat` through a pipeline produces a completely different key. This is the
    single most common keyfile bug in the field.

    Fix, given we know the original length:

      truncate -s 512 /etc/luks-keys/lab331.key
      chmod 0400 /etc/luks-keys/lab331.key     # root-only; 0644 is a finding
      cryptsetup luksOpen --test-passphrase --key-file /etc/luks-keys/lab331.key $LOOP
      #  (silent = success)

    If you did NOT know the original bytes, the recovery is different: open the
    container with the passphrase and enrol the current file as a new key —
      cryptsetup luksAddKey $LOOP /etc/luks-keys/lab331.key
    which is also how you provision a keyfile in the first place. Alternatively,
    pin the length in crypttab with keyfile-size=512 so trailing junk is ignored.

 FAULT 3 — /etc/fstab points at a mapper node that does not exist.

      systemctl start systemd-cryptsetup@lab331.service     # now succeeds
      ls /dev/mapper/                                       # lab331
      grep -A2 'breakfix-331-3 BEGIN' /etc/fstab
      #  /dev/mapper/lab331-data  /mnt/lab331  ext4  defaults,nofail,...
      findmnt --verify --verbose

    The crypttab target name is 'lab331', so the device-mapper node is
    /dev/mapper/lab331. Fix and mount:

      sed -i 's|/dev/mapper/lab331-data|/dev/mapper/lab331|' /etc/fstab
      systemctl daemon-reload
      mount /mnt/lab331
      cat /mnt/lab331/CANARY.txt

    Better practice than a mapper path: mount by filesystem UUID or LABEL
    (blkid /dev/mapper/lab331) so a rename of the crypttab target does not
    break the mount. Keep 'nofail' + 'x-systemd.device-timeout=' on non-root
    encrypted volumes: without them a missing key drops the host into
    emergency mode at boot, which on a remote server means a console trip.

    Full cold-start test:

      umount /mnt/lab331; cryptsetup close lab331
      systemctl daemon-reload
      systemctl start systemd-cryptsetup@lab331.service && mount -a
      ./break-fix-331.3-encrypted-filesystems.sh verify crypttab

 SCENARIO 5 — plain : headerless dm-crypt with lost parameters

 1. Mine the evidence before touching the device:

      cat /var/lib/breakfix-331-3/evidence/plain-cryptsetup-status.txt
      #  /dev/mapper/lab331_plain is active.
      #    type:    PLAIN
      #    cipher:  aes-xts-plain64
      #    keysize: 512 bits
      #    device:  /dev/loop1
      #    offset:  0 sectors
      #    size:    262144 sectors
      #    mode:    read/write

    That kills candidate A (aes-cbc-essiv:sha256 / 256 bits) outright.
    What it can NEVER tell you is the HASH: in plain mode the hash is used
    only to turn the passphrase into the key, on the host, before the mapping
    is created. It is not a property of the dm target, so it appears in no
    status output, no dm table, and nowhere on disk. Candidates B and C differ
    only in that field, so you must test them.

 2. Test candidate B, then C. `blkid` is a cheaper oracle than `mount`:

      PLOOP=$(losetup -j /var/lib/breakfix-331-3/images/plain.img | cut -d: -f1)

      cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 512 \
          --hash sha256 --offset 0 --skip 0 $PLOOP lab331_plain
      #  Enter passphrase: Lab-331.3-cryptsetup     -> ALWAYS succeeds
      blkid /dev/mapper/lab331_plain
      #  (no output -> wrong key, the "filesystem" is noise)
      cryptsetup close lab331_plain          # ALWAYS close before retrying

      cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 512 \
          --hash sha512 --offset 0 --skip 0 $PLOOP lab331_plain
      blkid /dev/mapper/lab331_plain
      #  /dev/mapper/lab331_plain: LABEL="lab331plain" UUID="..." TYPE="ext4"

      mount /dev/mapper/lab331_plain /mnt/lab331_plain
      cat /mnt/lab331_plain/CANARY.txt
      ./break-fix-331.3-encrypted-filesystems.sh verify plain

 3. What you just learned about plain mode

    - No header, no magic, no UUID, no salt: a plain container is indistinguish-
      able from random data. That is its one advantage (deniability, and the
      ability to encrypt a device with zero metadata overhead).
    - The parameters ARE the credential. Cipher, key size, hash, offset, skip
      and the passphrase must all match exactly. There is no integrity check
      and no key-slot digest, so a mistake in any of them yields a silently
      wrong key — never an error message.
    - There is no key management: no second passphrase, no key rotation, no
      revocation, no way to re-key without rewriting every block.
    - It is still useful for swap with a random key per boot:
          # /etc/crypttab
          swap  /dev/vdb  /dev/urandom  swap,cipher=aes-xts-plain64,size=512
      Here a fresh random key each boot is a feature, and the absence of a
      header is exactly what you want.
    - Extra credit answer: LUKS exists so that the parameters, a salt and
      multiple wrapped copies of the master key live WITH the data, which is
      what makes passphrase changes, multiple keys, revocation and disaster
      recovery possible at all.
    - Related: `dmsetup table --showkeys lab331_plain` prints the live master
      key in hex. Treat any host where you run it as compromised-by-shoulder;
      it is also how you reconstruct a mapping when the passphrase is lost but
      the machine is still up (`dmsetup create ... --table "..."`).

 SCENARIO 6 — ecryptfs : stacked filesystem mounted with the wrong parameters

 1. Understand the layout before touching anything.

    eCryptfs is a STACKED filesystem: it does not own a block device, it sits
    on top of an existing directory in an existing filesystem.

      lower directory  /var/lib/breakfix-331-3/ecryptfs/.Private
                       holds the ciphertext, one encrypted file per plaintext
                       file, each with its own cryptographic header
      upper directory  /var/lib/breakfix-331-3/ecryptfs/Private
                       the mountpoint where plaintext appears while mounted

    Because encryption is per file, eCryptfs can protect one user's home
    directory on a shared machine, be mounted at PAM login (pam_ecryptfs),
    and back up as ordinary files. dm-crypt cannot do any of that: it encrypts
    a whole block device, below the filesystem, all-or-nothing for the host.
    The trade-off is that eCryptfs leaks metadata dm-crypt hides — file count,
    file sizes (rounded), directory structure, and filenames unless filename
    encryption (FNEK) is enabled.

 2. Recover the real parameters from the data itself. Every eCryptfs file
    stores its own header, and ecryptfs-stat prints it:

      ecryptfs-stat /var/lib/breakfix-331-3/ecryptfs/.Private/CANARY.txt
      #  Version: 3
      #  Header Extent Size: 8192
      #  Extent Size: 4096
      #  Cipher: aes
      #  Key Bytes: 32
      #  Flags: 0x00000008
      #  ...

    Cipher = aes, Key Bytes = 32 — not blowfish/16 as the tampered runbook
    claims. Confirm what the file really is:

      file /var/lib/breakfix-331-3/ecryptfs/.Private/CANARY.txt
      head -c 64 /var/lib/breakfix-331-3/ecryptfs/.Private/CANARY.txt | od -An -c

 3. Mount with the correct options:

      mount -t ecryptfs \
        /var/lib/breakfix-331-3/ecryptfs/.Private \
        /var/lib/breakfix-331-3/ecryptfs/Private \
        -o key=passphrase:passphrase_passwd=Lab-331.3-ecryptfs,\
      ecryptfs_cipher=aes,ecryptfs_key_bytes=32,ecryptfs_passthrough=n,\
      ecryptfs_enable_filename_crypto=n,no_sig_cache=yes

      cat /var/lib/breakfix-331-3/ecryptfs/Private/CANARY.txt
      mount | grep ecryptfs
      ./break-fix-331.3-encrypted-filesystems.sh verify ecryptfs

    Notes on the options actually used:
      key=passphrase:passphrase_passwd=   fine for a lab, WRONG for production:
                                          the secret lands in /proc and in the
                                          mount table. Prefer
                                          passphrase_passwd_file=<file>, or
                                          insert the key into the kernel keyring
                                          first with `ecryptfs-add-passphrase`
                                          and then mount with ecryptfs_sig=<sig>.
      ecryptfs_key_bytes=                 must match the header, or you derive
                                          a different key and read garbage.
      ecryptfs_passthrough=n              n = refuse to read non-encrypted files
                                          in the lower dir instead of passing
                                          them through unmodified.
      ecryptfs_enable_filename_crypto=y   encrypts names too; needs an FNEK sig
                                          (ecryptfs_fnek_sig=). Off here so the
                                          lower directory stays readable for
                                          teaching. Turn it on in production.
      no_sig_cache=yes                    suppresses the interactive prompt that
                                          appears when the key signature is not
                                          yet in ~/.ecryptfs/sig-cache.txt.

 4. Tools worth knowing for the objective:
      ecryptfs-setup-private       provision ~/.Private + ~/Private for a user
      ecryptfs-mount-private / -umount-private
      ecryptfs-add-passphrase [--fnek]    insert a key into the kernel keyring
      ecryptfs-wrap-passphrase / -unwrap-passphrase
      ecryptfs-recover-private     rescue a home dir from a dead system
      ecryptfs-migrate-home        convert an existing home to eCryptfs
      keyctl show / keyctl list @u        inspect the keyring the mount uses
      pam_ecryptfs.so              unwraps the mount passphrase at login, which
                                   is why an eCryptfs home is only readable
                                   while that user is logged in

    Awareness items in the same objective, for completeness:
      EncFS   — FUSE, userspace, per-file, no root needed; the 2014 audit found
                weaknesses and upstream is effectively dormant. Know it exists;
                do not deploy it for new work.
      fscrypt — native per-directory encryption inside ext4/F2FS/UBIFS, managed
                with `fscrypt`/`fscryptctl`; no stacking, no separate lower dir.
                This is where the ecosystem moved after eCryptfs.
      cryptmount — an alternative front-end for user-mountable encrypted
                filesystems driven by /etc/cryptmount/cmtab.
      LUKS2 extras — argon2id PBKDF, JSON metadata, tokens (TPM2/FIDO2/PKCS#11),
                dm-integrity via --integrity for authenticated encryption, and
                online `cryptsetup reencrypt`.

 CLEAN UP
      ./break-fix-331.3-encrypted-filesystems.sh reset
 removes the loop devices, the images, /etc/luks-keys, and restores the
 original /etc/crypttab and /etc/fstab from the copies taken at build time.

==== SOLUTION END ===========================================================
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-3-303/331.3/lab)
