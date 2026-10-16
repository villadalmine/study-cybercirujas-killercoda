#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-3 303 Security  —  Exam 303-300, objectives version 3.0.0
#  Topic 331.3 : Encrypted File Systems          Exam weight: 5
#
#  break-fix-331.3-encrypted-filesystems.sh
#
#  A self-contained "break & fix" lab. It builds a realistic encrypted-storage
#  stack on LOOPBACK-BACKED IMAGE FILES ONLY, proves it works, then breaks it
#  in one of six controlled, reversible ways. Each break ships with a briefing
#  (symptom + goal), progressive hints, and a self-grading verifier.
#
#  Covered key knowledge for 331.3:
#    * dm-crypt / LUKS1 / LUKS2 with cryptsetup
#    * LUKS header anatomy, primary + secondary header, keyslot areas
#    * luksHeaderBackup / luksHeaderRestore / repair  (and their security cost)
#    * keyslots: luksAddKey / luksKillSlot / luksRemoveKey / luksChangeKey
#    * /etc/crypttab, systemd-cryptsetup@.service, keyfiles, /etc/fstab
#    * plain dm-crypt (headerless) and why it never says "wrong password"
#    * eCryptfs: mount.ecryptfs, ecryptfs-stat, per-file cryptographic headers
#
#  Reference (authoritative objective list):
#    https://www.lpi.org/our-certifications/exam-303-objectives/
#  Upstream documentation used while writing this lab:
#    https://gitlab.com/cryptsetup/cryptsetup/-/wikis/home
#    https://gitlab.com/cryptsetup/cryptsetup/-/wikis/FrequentlyAskedQuestions
#    https://gitlab.com/cryptsetup/cryptsetup/-/blob/main/docs/on-disk-format-luks2.pdf
#    https://www.freedesktop.org/software/systemd/man/latest/crypttab.html
#    https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-crypt.html
#    https://www.kernel.org/doc/html/latest/filesystems/ecryptfs.html
#
# -----------------------------------------------------------------------------
#  !!  DISPOSABLE LAB VM ONLY  !!
#  This script writes to /etc/crypttab, /etc/fstab and /etc/luks-keys, loads
#  kernel modules and runs `dd` against device-mapper targets. It never touches
#  a physical disk: every block device it uses is a loop device it created from
#  a file under the lab directory, and it refuses to accept a device path from
#  you. Even so: run it on a throwaway VM you can delete. Snapshot first.
# -----------------------------------------------------------------------------
#
#  Usage:
#     ./break-fix-331.3-encrypted-filesystems.sh build
#     ./break-fix-331.3-encrypted-filesystems.sh list
#     ./break-fix-331.3-encrypted-filesystems.sh break   <scenario>
#     ./break-fix-331.3-encrypted-filesystems.sh hint    <scenario>
#     ./break-fix-331.3-encrypted-filesystems.sh verify  <scenario>
#     ./break-fix-331.3-encrypted-filesystems.sh status
#     ./break-fix-331.3-encrypted-filesystems.sh rebuild
#     ./break-fix-331.3-encrypted-filesystems.sh reset
#     ./break-fix-331.3-encrypted-filesystems.sh solution        # prints the
#                                                                # commented
#                                                                # answer key
#  Global flag: -y | --yes   (skip the destructive-action countdown)
# =============================================================================

set -Eeuo pipefail

# ------------------------------ configuration --------------------------------

LAB_ROOT="/var/lib/breakfix-331-3"
IMG_LUKS="${LAB_ROOT}/images/luks.img"
IMG_PLAIN="${LAB_ROOT}/images/plain.img"
BACKUP_DIR="${LAB_ROOT}/backup"
EVIDENCE_DIR="${LAB_ROOT}/evidence"
RUNBOOK_DIR="${LAB_ROOT}/runbook"
ECRYPTFS_DIR="${LAB_ROOT}/ecryptfs"

HDR_BACKUP="${BACKUP_DIR}/luks-header-lab331.img"
KEYDIR="/etc/luks-keys"
KEYFILE="${KEYDIR}/lab331.key"

MAPNAME="lab331"
MOUNTPOINT="/mnt/lab331"
PLAIN_MAPNAME="lab331_plain"
PLAIN_MOUNTPOINT="/mnt/lab331_plain"
ECRYPTFS_LOWER="${ECRYPTFS_DIR}/.Private"
ECRYPTFS_UPPER="${ECRYPTFS_DIR}/Private"

# Lab secrets. Obviously not production material; they are printed on screen.
PASS='Lab-331.3-cryptsetup'
ECRYPTFS_PASS='Lab-331.3-ecryptfs'

CANARY_TEXT='LUKS lab canary 331.3 :: if you can read this, the data survived'
CANARY_NAME='CANARY.txt'

# Marker used to find (and surgically remove) the lines this lab adds to
# /etc/crypttab and /etc/fstab. No regex metacharacters in the tag on purpose.
TAG='breakfix-331-3'

# Correct plain dm-crypt parameters (headerless: nothing on disk records them).
PLAIN_CIPHER='aes-xts-plain64'
PLAIN_KEYSIZE='512'
PLAIN_HASH='sha512'

# eCryptfs parameters actually used at build time.
ECRYPTFS_CIPHER='aes'
ECRYPTFS_KEY_BYTES='32'

ASSUME_YES=0

# ------------------------------- output helpers ------------------------------

if [[ -t 1 ]]; then
    C_RST=$'\033[0m'; C_B=$'\033[1m'; C_R=$'\033[31m'
    C_G=$'\033[32m';  C_Y=$'\033[33m'; C_C=$'\033[36m'
else
    C_RST=''; C_B=''; C_R=''; C_G=''; C_Y=''; C_C=''
fi

hdr()  { printf '\n%s%s%s\n%s\n' "$C_B$C_C" "$*" "$C_RST" \
                "$(printf '=%.0s' $(seq 1 ${#1}))"; }
info() { printf '%s[*]%s %s\n' "$C_C" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_RST" "$*" >&2; exit 1; }

trap 'die "aborted at line $LINENO (command: ${BASH_COMMAND})"' ERR

# ------------------------------- safety rails --------------------------------

require_root() {
    [[ $EUID -eq 0 ]] || die "run as root (dm-crypt, losetup and /etc edits need it)"
}

require_tools() {
    local missing=() t
    for t in cryptsetup losetup blkid dmsetup mkfs.ext4 dd od udevadm; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if ((${#missing[@]})); then
        die "missing tools: ${missing[*]} — install cryptsetup/util-linux/e2fsprogs"
    fi
}

confirm_destructive() {
    (( ASSUME_YES )) && return 0
    warn "This modifies /etc/crypttab, /etc/fstab and creates loop devices."
    warn "Use a DISPOSABLE lab VM. Press Ctrl-C now to abort."
    local i
    for i in 5 4 3 2 1; do printf '   continuing in %s...\r' "$i"; sleep 1; done
    printf '                              \r'
}

# --------------------------- loop-device plumbing ----------------------------

# Re-attaching is idempotent and survives a reboot of the lab VM.
loop_for() {
    local img="$1" dev
    dev="$(losetup -j "$img" 2>/dev/null | head -n1 | cut -d: -f1)"
    if [[ -z "$dev" ]]; then
        dev="$(losetup --find --show "$img")"
    fi
    printf '%s\n' "$dev"
}

luks_dev()  { loop_for "$IMG_LUKS"; }
plain_dev() { loop_for "$IMG_PLAIN"; }

# ------------------------------ small utilities ------------------------------

# First six bytes of a LUKS container: "LUKS" 0xba 0xbe  ->  4c554b53babe
# The LUKS2 secondary header at offset 16384 starts with "SKUL" 0xba 0xbe.
magic_at() {
    local dev="$1" off="$2"
    dd if="$dev" bs=1 skip="$off" count=6 status=none 2>/dev/null \
        | od -An -v -tx1 | tr -d ' \n'
}

flip_last_hex() {
    local u="$1" last c
    last="${u: -1}"
    if [[ "$last" == "0" ]]; then c=1; else c=0; fi
    printf '%s%s\n' "${u:0:$(( ${#u} - 1 ))}" "$c"
}

is_mounted() { mountpoint -q "$1" 2>/dev/null; }

close_stack() {
    is_mounted "$MOUNTPOINT"       && umount "$MOUNTPOINT"
    is_mounted "$PLAIN_MOUNTPOINT" && umount "$PLAIN_MOUNTPOINT"
    is_mounted "$ECRYPTFS_UPPER"   && umount "$ECRYPTFS_UPPER"
    [[ -e "/dev/mapper/${MAPNAME}"       ]] && cryptsetup close "$MAPNAME"
    [[ -e "/dev/mapper/${PLAIN_MAPNAME}" ]] && cryptsetup close "$PLAIN_MAPNAME"
    return 0
}

# ------------------------------ /etc file edits ------------------------------

etc_backup() {
    install -d -m 0755 "$BACKUP_DIR"
    [[ -f "${BACKUP_DIR}/crypttab.orig" ]] || cp -a /etc/crypttab "${BACKUP_DIR}/crypttab.orig" 2>/dev/null || : 
    [[ -f "${BACKUP_DIR}/fstab.orig"    ]] || cp -a /etc/fstab    "${BACKUP_DIR}/fstab.orig"
}

etc_strip_block() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    sed -i "/# ${TAG} BEGIN/,/# ${TAG} END/d" "$file"
}

write_crypttab_entry() {
    local uuid="$1" keyfile="$2" opts="$3"
    touch /etc/crypttab
    etc_strip_block /etc/crypttab
    {
        printf '# %s BEGIN\n' "$TAG"
        printf '# <name> <source device>          <key file>   <options>\n'
        printf '%s\tUUID=%s\t%s\t%s\n' "$MAPNAME" "$uuid" "$keyfile" "$opts"
        printf '# %s END\n' "$TAG"
    } >> /etc/crypttab
}

write_fstab_entry() {
    local mapper="$1"
    etc_strip_block /etc/fstab
    {
        printf '# %s BEGIN\n' "$TAG"
        printf '%s\t%s\text4\tdefaults,nofail,x-systemd.device-timeout=10s\t0 2\n' \
               "$mapper" "$MOUNTPOINT"
        printf '# %s END\n' "$TAG"
    } >> /etc/fstab
}

reload_units() {
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl daemon-reload >/dev/null 2>&1 || true
}

# =============================================================================
#  BUILD
# =============================================================================

cmd_build() {
    require_root; require_tools; confirm_destructive
    hdr "Building the 331.3 lab"

    modprobe dm_crypt 2>/dev/null || true
    install -d -m 0755 "$LAB_ROOT" "${LAB_ROOT}/images" "$BACKUP_DIR" \
                       "$EVIDENCE_DIR" "$RUNBOOK_DIR" "$MOUNTPOINT" \
                       "$PLAIN_MOUNTPOINT"
    install -d -m 0700 "$KEYDIR"
    etc_backup

    # ---- 1. LUKS2 container --------------------------------------------------
    if [[ ! -f "$IMG_LUKS" ]]; then
        info "allocating ${IMG_LUKS} (384 MiB: 16 MiB LUKS2 header + data)"
        truncate -s 384M "$IMG_LUKS"
        chmod 0600 "$IMG_LUKS"
    fi
    local dev; dev="$(luks_dev)"
    ok "LUKS container backed by loop device ${dev}"

    if ! cryptsetup isLuks "$dev" 2>/dev/null; then
        info "cryptsetup luksFormat --type luks2  (PBKDF weakened for lab speed)"
        # --pbkdf pbkdf2 --pbkdf-force-iterations 1000 keeps the lab fast on a
        # tiny VM. NEVER do this on real data: it is the minimum allowed and
        # cripples brute-force resistance. Production default is argon2id.
        printf '%s' "$PASS" | cryptsetup luksFormat \
            --type luks2 \
            --cipher aes-xts-plain64 --key-size 512 --hash sha256 \
            --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
            --batch-mode --key-file - "$dev"

        info "adding a second keyslot backed by a 512-byte binary keyfile"
        dd if=/dev/urandom of="$KEYFILE" bs=512 count=1 status=none
        chmod 0400 "$KEYFILE"
        printf '%s' "$PASS" | cryptsetup luksAddKey \
            --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
            --batch-mode --key-file - "$dev" "$KEYFILE"
    else
        ok "container already formatted, keeping it"
    fi

    local uuid; uuid="$(cryptsetup luksUUID "$dev")"
    ok "LUKS UUID = ${uuid}"

    info "taking a header backup (this is the nightly-runbook artefact)"
    rm -f "$HDR_BACKUP"
    cryptsetup luksHeaderBackup "$dev" --header-backup-file "$HDR_BACKUP"
    chmod 0400 "$HDR_BACKUP"
    ok "header backup: ${HDR_BACKUP} ($(stat -c %s "$HDR_BACKUP") bytes)"

    # ---- 2. filesystem + canary ---------------------------------------------
    if [[ ! -e "/dev/mapper/${MAPNAME}" ]]; then
        printf '%s' "$PASS" | cryptsetup open --key-file - "$dev" "$MAPNAME"
    fi
    if ! blkid "/dev/mapper/${MAPNAME}" >/dev/null 2>&1; then
        info "mkfs.ext4 on /dev/mapper/${MAPNAME}"
        mkfs.ext4 -q -L lab331 "/dev/mapper/${MAPNAME}"
    fi
    is_mounted "$MOUNTPOINT" || mount "/dev/mapper/${MAPNAME}" "$MOUNTPOINT"
    printf '%s\n' "$CANARY_TEXT" > "${MOUNTPOINT}/${CANARY_NAME}"
    sync
    ok "canary written to ${MOUNTPOINT}/${CANARY_NAME}"

    cryptsetup status "$MAPNAME" > "${EVIDENCE_DIR}/luks-cryptsetup-status.txt"
    cryptsetup luksDump "$dev"   > "${EVIDENCE_DIR}/luks-luksDump.txt"

    # ---- 3. boot-time wiring: crypttab + fstab ------------------------------
    info "wiring /etc/crypttab and /etc/fstab (nofail everywhere, on purpose)"
    write_crypttab_entry "$uuid" "$KEYFILE" "luks,nofail,keyfile-timeout=5s"
    write_fstab_entry "/dev/mapper/${MAPNAME}"
    reload_units
    udevadm settle 2>/dev/null || true

    # Prove the declarative path really works before we break it.
    umount "$MOUNTPOINT"
    cryptsetup close "$MAPNAME"
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl start "systemd-cryptsetup@${MAPNAME}.service" 2>/dev/null; then
            ok "systemd-cryptsetup@${MAPNAME}.service activated the mapping"
        else
            warn "unit start failed; falling back to a manual open"
            cryptsetup open --key-file "$KEYFILE" "$dev" "$MAPNAME"
        fi
    else
        cryptsetup open --key-file "$KEYFILE" "$dev" "$MAPNAME"
    fi
    mount "$MOUNTPOINT"
    ok "mounted via /etc/fstab: $(grep -c . "${MOUNTPOINT}/${CANARY_NAME}") canary line"

    # ---- 4. plain dm-crypt container (headerless) ---------------------------
    if [[ ! -f "$IMG_PLAIN" ]]; then
        info "allocating ${IMG_PLAIN} (128 MiB, plain dm-crypt: zero metadata)"
        truncate -s 128M "$IMG_PLAIN"
        chmod 0600 "$IMG_PLAIN"
    fi
    local pdev; pdev="$(plain_dev)"
    printf '%s' "$PASS" | cryptsetup open --type plain \
        --cipher "$PLAIN_CIPHER" --key-size "$PLAIN_KEYSIZE" \
        --hash "$PLAIN_HASH" --offset 0 --skip 0 \
        --key-file - "$pdev" "$PLAIN_MAPNAME"
    blkid "/dev/mapper/${PLAIN_MAPNAME}" >/dev/null 2>&1 \
        || mkfs.ext4 -q -L lab331plain "/dev/mapper/${PLAIN_MAPNAME}"
    mount "/dev/mapper/${PLAIN_MAPNAME}" "$PLAIN_MOUNTPOINT"
    printf '%s\n' "$CANARY_TEXT" > "${PLAIN_MOUNTPOINT}/${CANARY_NAME}"
    sync
    # Archive the evidence the student will be allowed to use later.
    cryptsetup status "$PLAIN_MAPNAME" > "${EVIDENCE_DIR}/plain-cryptsetup-status.txt"
    dmsetup table "$PLAIN_MAPNAME"     > "${EVIDENCE_DIR}/plain-dmsetup-table.txt"
    umount "$PLAIN_MOUNTPOINT"
    cryptsetup close "$PLAIN_MAPNAME"
    ok "plain dm-crypt container built and archived (kept closed)"

    # ---- 5. eCryptfs (optional) ---------------------------------------------
    if command -v mount.ecryptfs >/dev/null 2>&1 && modprobe ecryptfs 2>/dev/null; then
        install -d -m 0700 "$ECRYPTFS_LOWER" "$ECRYPTFS_UPPER"
        if ! is_mounted "$ECRYPTFS_UPPER"; then
            mount -t ecryptfs "$ECRYPTFS_LOWER" "$ECRYPTFS_UPPER" \
                -o "key=passphrase:passphrase_passwd=${ECRYPTFS_PASS},ecryptfs_cipher=${ECRYPTFS_CIPHER},ecryptfs_key_bytes=${ECRYPTFS_KEY_BYTES},ecryptfs_passthrough=n,ecryptfs_enable_filename_crypto=n,no_sig_cache=yes"
        fi
        printf '%s\n' "$CANARY_TEXT" > "${ECRYPTFS_UPPER}/${CANARY_NAME}"
        sync
        umount "$ECRYPTFS_UPPER"
        ok "eCryptfs pair built: lower=${ECRYPTFS_LOWER} upper=${ECRYPTFS_UPPER}"
    else
        warn "ecryptfs-utils / ecryptfs module not available — scenario 'ecryptfs'"
        warn "will be skipped. Install the distro package 'ecryptfs-utils' to enable it."
    fi

    # ---- 6. the sysadmin runbook the student inherits ------------------------
    cat > "${RUNBOOK_DIR}/README.txt" <<EOF
LAB 331.3 RUNBOOK  (this is what the previous sysadmin left behind)

LUKS2 container
  image      : ${IMG_LUKS}
  mapping    : ${MAPNAME}     mountpoint: ${MOUNTPOINT}
  passphrase : ${PASS}
  keyfile    : ${KEYFILE}      (512 random bytes, keyslot 1)
  header bkp : ${HDR_BACKUP}   (taken nightly)

plain dm-crypt container  (NO header on disk - parameters live here or nowhere)
  image      : ${IMG_PLAIN}
  mapping    : ${PLAIN_MAPNAME}   mountpoint: ${PLAIN_MOUNTPOINT}
  passphrase : ${PASS}
  parameters : see ${RUNBOOK_DIR}/plain-parameters.txt

eCryptfs
  lower      : ${ECRYPTFS_LOWER}
  upper      : ${ECRYPTFS_UPPER}
  passphrase : ${ECRYPTFS_PASS}
  mount opts : see ${RUNBOOK_DIR}/ecryptfs-mount.txt

Archived evidence from when everything still worked: ${EVIDENCE_DIR}/
EOF

    cat > "${RUNBOOK_DIR}/plain-parameters.txt" <<EOF
Plain dm-crypt parameters for ${PLAIN_MAPNAME}.
The notes were water-damaged; three candidate parameter sets survived and we no
longer know which one is real. Only one produces a mountable filesystem.

  A)  --cipher aes-cbc-essiv:sha256  --key-size 256  --hash ripemd160
  B)  --cipher aes-xts-plain64       --key-size 512  --hash sha256
  C)  --cipher aes-xts-plain64       --key-size 512  --hash sha512

All of them use --offset 0 --skip 0 and the passphrase in README.txt.
EOF

    cat > "${RUNBOOK_DIR}/ecryptfs-mount.txt" <<EOF
mount -t ecryptfs ${ECRYPTFS_LOWER} ${ECRYPTFS_UPPER} \\
  -o key=passphrase:passphrase_passwd=${ECRYPTFS_PASS},\\
ecryptfs_cipher=${ECRYPTFS_CIPHER},ecryptfs_key_bytes=${ECRYPTFS_KEY_BYTES},\\
ecryptfs_passthrough=n,ecryptfs_enable_filename_crypto=n,no_sig_cache=yes
EOF

    hdr "Lab is UP and healthy"
    lsblk -f 2>/dev/null | sed -n '1p;/loop/,+2p' || true
    printf '\n'
    ok "runbook: ${RUNBOOK_DIR}/README.txt"
    ok "next: $0 list   then   $0 break <scenario>"
}

# =============================================================================
#  SCENARIO CATALOGUE
# =============================================================================

cmd_list() {
    hdr "Available break scenarios"
    cat <<'EOF'
  header     LUKS2 primary header destroyed, secondary copy intact.
             Difficulty: *          Concepts: LUKS2 dual header, cryptsetup repair

  nuke       Entire 16 MiB LUKS2 header area destroyed (both copies + keyslots).
             Difficulty: **         Concepts: luksHeaderBackup/luksHeaderRestore

  keyslot    The passphrase keyslot has been killed. Only the keyfile survives.
             Difficulty: **         Concepts: luksKillSlot, luksAddKey, keyslot
                                              resurrection via header backups

  crypttab   Three independent faults injected into the boot-time wiring.
             Difficulty: ***        Concepts: /etc/crypttab, systemd-cryptsetup@,
                                              keyfile hygiene, /etc/fstab

  plain      Headerless plain dm-crypt mapping with lost parameters.
             Difficulty: ***        Concepts: plain vs LUKS, silent wrong-key
                                              behaviour, dmsetup/cryptsetup status

  ecryptfs   eCryptfs stacked FS remounted with the wrong crypto parameters.
             Difficulty: **         Concepts: mount.ecryptfs, ecryptfs-stat,
                                              per-file headers, lower vs upper
EOF
    printf '\n'
    info "$0 break <scenario>   |   $0 hint <scenario>   |   $0 verify <scenario>"
}

# =============================================================================
#  BREAKERS
# =============================================================================

break_header() {
    local dev; dev="$(luks_dev)"
    close_stack
    info "overwriting the first 4096 bytes of ${dev} with zeroes"
    dd if=/dev/zero of="$dev" bs=4096 count=1 conv=fsync status=none
    udevadm settle 2>/dev/null || true

    hdr "SCENARIO: header — the primary LUKS2 header is gone"
    cat <<EOF
WHAT I DID
  I zeroed the first 4 KiB of ${dev}. That is exactly the LUKS2 primary binary
  header plus part of its JSON metadata area. I did not touch anything else.

SYMPTOM YOU WILL SEE
  \$ sudo cryptsetup luksDump ${dev}
  ... a warning that the primary header is invalid/corrupted, while the dump
  itself still succeeds. Depending on your cryptsetup version you may also see
  it on every open:
      Primary LUKS2 header is corrupted.
  \$ sudo blkid ${dev}
  ... may no longer report TYPE="crypto_LUKS", because blkid reads offset 0.

  The container may still OPEN. That is the interesting part — figure out why.

YOUR GOAL
  1. Explain, with evidence from the device itself, why the container still
     works even though offset 0 is zeroed.
  2. Restore a valid primary header WITHOUT using ${HDR_BACKUP}.
  3. Prove it: the first six bytes of ${dev} must again be 4c 55 4b 53 ba be.
  4. Open the mapping '${MAPNAME}' with the passphrase and read the canary.

TOOLS THAT MATTER
  cryptsetup luksDump / repair / isLuks -v, dd, od -A d -t x1z, blkid, lsblk -f

VERIFY WHEN DONE
  $0 verify header
EOF
}

break_nuke() {
    local dev; dev="$(luks_dev)"
    close_stack
    info "overwriting the whole 16 MiB header area of ${dev}"
    dd if=/dev/urandom of="$dev" bs=1M count=16 conv=fsync status=none
    udevadm settle 2>/dev/null || true

    hdr "SCENARIO: nuke — the entire LUKS2 header area is destroyed"
    cat <<EOF
WHAT I DID
  I overwrote the first 16 MiB of ${dev} with random bytes. In a default LUKS2
  container that region holds the primary header, the secondary header AND the
  whole keyslot area. The ciphertext of your filesystem, which starts at the
  data offset, is untouched.

SYMPTOM YOU WILL SEE
  \$ sudo cryptsetup open ${dev} ${MAPNAME}
  Device ${dev} is not a valid LUKS device.

  \$ sudo cryptsetup isLuks -v ${dev}
  Device ${dev} is not a valid LUKS device.
  Command failed with code -1 (wrong or missing parameters).

  \$ sudo blkid ${dev}
  (no output — nothing recognises the device any more)

  Note there is no "wrong passphrase" message. The passphrase is irrelevant:
  the master key it was protecting no longer exists on this disk.

YOUR GOAL
  Recover the plaintext. Everything you need was created before the incident;
  read ${RUNBOOK_DIR}/README.txt. Then open '${MAPNAME}', mount ${MOUNTPOINT}
  and read the canary file.

  Bonus, answer in one sentence: if an attacker had stolen a copy of that same
  artefact six months ago, what exactly could they decrypt today?

TOOLS THAT MATTER
  cryptsetup luksHeaderRestore --header-backup-file, luksDump, isLuks -v

VERIFY WHEN DONE
  $0 verify nuke
EOF
}

break_keyslot() {
    local dev; dev="$(luks_dev)"
    close_stack

    # Find the slot the interactive passphrase lives in and kill precisely that
    # one. Keyslot 0 in this lab holds the passphrase, keyslot 1 the keyfile.
    info "killing the keyslot that holds the interactive passphrase"
    cryptsetup luksKillSlot --batch-mode --key-file "$KEYFILE" "$dev" 0
    udevadm settle 2>/dev/null || true

    hdr "SCENARIO: keyslot — the passphrase no longer opens the container"
    cat <<EOF
WHAT I DID
  I removed one keyslot from an otherwise perfectly healthy LUKS2 header.
  The header is valid, the UUID is unchanged, the master key is unchanged.

SYMPTOM YOU WILL SEE
  \$ sudo cryptsetup open ${dev} ${MAPNAME}
  Enter passphrase for ${dev}: ${PASS}
  No key available with this passphrase.

  \$ sudo cryptsetup luksDump ${dev} | sed -n '/Keyslots:/,/Tokens:/p'
  ... one keyslot fewer than the two the runbook documents.

YOUR GOAL
  1. Get the container open again (there is more than one way — find at least
     two, and be able to say which one you would use on a production host).
  2. Restore the documented state: the passphrase '${PASS}' must work again,
     AND the keyfile must keep working. Two live keyslots when you are done.
  3. Read the canary at ${MOUNTPOINT}/${CANARY_NAME}.

THINK ABOUT
  ${HDR_BACKUP} still exists and predates the deletion. What does that tell you
  about the security value of LUKS header backups? Write the answer down before
  you look at the solution — this is a favourite exam-adjacent discussion point.

TOOLS THAT MATTER
  cryptsetup open --key-file, luksAddKey, luksDump, luksHeaderRestore,
  cryptsetup luksChangeKey, cryptsetup --key-slot

VERIFY WHEN DONE
  $0 verify keyslot
EOF
}

break_crypttab() {
    local dev; dev="$(luks_dev)"
    close_stack
    local uuid bad
    uuid="$(cryptsetup luksUUID "$dev")"
    bad="$(flip_last_hex "$uuid")"

    info "injecting fault 1/3: wrong UUID in /etc/crypttab"
    write_crypttab_entry "$bad" "$KEYFILE" "luks,nofail,keyfile-timeout=5s"

    info "injecting fault 2/3: corrupting the keyfile (trailing newline)"
    printf '\n' >> "$KEYFILE"

    info "injecting fault 3/3: /etc/fstab refers to a mapper name that does not exist"
    write_fstab_entry "/dev/mapper/${MAPNAME}-data"

    reload_units
    hdr "SCENARIO: crypttab — the encrypted volume no longer comes up at boot"
    cat <<EOF
WHAT I DID
  I introduced THREE independent faults into the boot-time wiring of the
  '${MAPNAME}' volume. The LUKS header itself is pristine — do not touch it.
  I set 'nofail' so a mistake will not strand your VM at boot; a real system
  without nofail would drop into emergency mode instead.

SYMPTOM YOU WILL SEE
  \$ sudo systemctl start systemd-cryptsetup@${MAPNAME}.service
  Job for systemd-cryptsetup@${MAPNAME}.service failed ...

  \$ sudo journalctl -u systemd-cryptsetup@${MAPNAME}.service -n 20 --no-pager
  ... first failure, roughly:
      Failed to open device ... No such file or directory
  ... and once that is fixed, a second, different failure:
      Failed to activate with key file '${KEYFILE}': Operation not permitted
      (or: No key available with this passphrase)
  ... and once THAT is fixed, 'mount ${MOUNTPOINT}' still fails.

  \$ ls -l /dev/mapper/
  ... no '${MAPNAME}' node.

YOUR GOAL
  Fix all three faults so that, from a cold state, this sequence succeeds with
  no interactive prompt and no manual cryptsetup call:

      sudo systemctl daemon-reload
      sudo systemctl start systemd-cryptsetup@${MAPNAME}.service
      sudo mount ${MOUNTPOINT}
      cat ${MOUNTPOINT}/${CANARY_NAME}

  Do NOT restore the header, do NOT reformat, do NOT change the passphrase.
  Fault 2 is the subtle one: the file is still there and still readable.

TOOLS THAT MATTER
  cryptsetup luksUUID, blkid, ls /dev/disk/by-uuid/, man 5 crypttab,
  systemctl daemon-reload, journalctl -u, systemd-cryptsetup (the generator),
  xxd/od on the keyfile, cryptsetup luksAddKey --key-file, mount -a
  On a non-systemd Debian host the equivalent is: cryptdisks_start ${MAPNAME}

VERIFY WHEN DONE
  $0 verify crypttab
EOF
}

break_plain() {
    close_stack
    hdr "SCENARIO: plain — headerless dm-crypt with lost parameters"
    cat <<EOF
WHAT I DID
  Nothing destructive at all. The plain dm-crypt container ${IMG_PLAIN} is
  byte-for-byte intact. It is simply closed, and plain dm-crypt stores NO
  metadata whatsoever on disk: no magic, no UUID, no cipher name, no salt.
  Everything needed to derive the key lives in the command line you type.

SYMPTOM YOU WILL SEE
  \$ sudo blkid \$(losetup -j ${IMG_PLAIN} | cut -d: -f1)
  (no output — the device looks like random noise, which is the point)

  \$ sudo cryptsetup open --type plain --cipher aes-xts-plain64 \\
        --key-size 512 --hash sha256 <loopdev> ${PLAIN_MAPNAME}
  Enter passphrase for <loopdev>:
  (SUCCEEDS. It always succeeds.)

  \$ sudo mount /dev/mapper/${PLAIN_MAPNAME} ${PLAIN_MOUNTPOINT}
  mount: ${PLAIN_MOUNTPOINT}: wrong fs type, bad option, bad superblock on
  /dev/mapper/${PLAIN_MAPNAME}, missing codepage or helper program, or other error.

  This is THE defining behaviour of plain mode and a classic exam trap:
  a wrong passphrase or a wrong parameter is not an error, it is a different
  key, and a different key is a mapping full of garbage. There is nothing on
  disk to compare against, so nothing can tell you "no".

YOUR GOAL
  Mount the plaintext at ${PLAIN_MOUNTPOINT} and read the canary.
  Your evidence:
    - ${RUNBOOK_DIR}/plain-parameters.txt  (three candidates, one is real)
    - ${EVIDENCE_DIR}/plain-cryptsetup-status.txt  (captured while it worked)
    - ${EVIDENCE_DIR}/plain-dmsetup-table.txt
  Use the evidence to eliminate candidates BEFORE brute-forcing, and say out
  loud which field the evidence can never tell you.

  Extra credit: state the one-line reason why LUKS exists, in terms of what
  this exercise just cost you.

TOOLS THAT MATTER
  cryptsetup open --type plain (--cipher/--key-size/--hash/--offset/--skip),
  cryptsetup status, dmsetup table --showkeys, blkid, mount, cryptsetup close

VERIFY WHEN DONE
  $0 verify plain
EOF
}

break_ecryptfs() {
    command -v mount.ecryptfs >/dev/null 2>&1 \
        || die "ecryptfs-utils not installed — scenario unavailable on this VM"
    close_stack

    info "rewriting the eCryptfs runbook with the wrong crypto parameters"
    cat > "${RUNBOOK_DIR}/ecryptfs-mount.txt" <<EOF
mount -t ecryptfs ${ECRYPTFS_LOWER} ${ECRYPTFS_UPPER} \\
  -o key=passphrase:passphrase_passwd=${ECRYPTFS_PASS},\\
ecryptfs_cipher=blowfish,ecryptfs_key_bytes=16,\\
ecryptfs_passthrough=n,ecryptfs_enable_filename_crypto=n,no_sig_cache=yes
EOF

    hdr "SCENARIO: ecryptfs — the stacked filesystem mounts, but the data is gone"
    cat <<EOF
WHAT I DID
  I unmounted the eCryptfs pair and replaced the recorded mount options with
  wrong ones. No file was deleted or modified. The passphrase in the runbook is
  still correct.

SYMPTOM YOU WILL SEE
  \$ ls -l ${ECRYPTFS_LOWER}
  ... your files are there by name, but 'cat' shows binary garbage prefixed by
  an eCryptfs per-file header. Students routinely report this as "data loss".

  \$ sudo mount -t ecryptfs ... (using ${RUNBOOK_DIR}/ecryptfs-mount.txt)
  Either:
      Error mounting eCryptfs: [-22] Invalid argument
      Check your system logs; visit <https://launchpad.net/ecryptfs>
  or the mount succeeds and reading the canary gives:
      cat: ${CANARY_NAME}: Input/output error

YOUR GOAL
  1. Recover the REAL cipher and key size. You are not allowed to guess: the
     information is stored on disk, in every encrypted file. Find where.
  2. Mount ${ECRYPTFS_UPPER} correctly and read the canary.
  3. Explain the difference between the "lower" and "upper" directory, and why
     eCryptfs can encrypt a home directory while dm-crypt cannot do so per-user.

TOOLS THAT MATTER
  ecryptfs-stat <lower-file>, mount -t ecryptfs -o ..., mount | grep ecryptfs,
  keyctl show, ecryptfs-add-passphrase, man 7 ecryptfs, man mount.ecryptfs
  dmesg -T | tail   (eCryptfs is chatty in the kernel log)

VERIFY WHEN DONE
  $0 verify ecryptfs
EOF
}

# =============================================================================
#  HINTS
# =============================================================================

cmd_hint() {
    local s="${1:-}"
    case "$s" in
    header)
        cat <<'EOF'
1. LUKS2 keeps TWO copies of its metadata. Where is the second one?
   Try: sudo dd if=<loopdev> bs=1 skip=16384 count=6 status=none | od -c
2. "LUKS" reversed is "SKUL". That is not a coincidence.
3. cryptsetup has a subcommand whose entire job is reconciling the two copies.
   It is one word, and it is destructive if you get the direction wrong — read
   `man cryptsetup` on it first.
EOF
        ;;
    nuke)
        cat <<'EOF'
1. Nothing in the header survived. Stop trying to read the device.
2. Read the runbook: something was taken nightly, precisely for this.
3. cryptsetup luksHeaderRestore --header-backup-file <file> <device>
   It will refuse politely and ask for confirmation; --batch-mode skips that.
4. Bonus answer: a stolen header backup contains keyslots that still wrap the
   SAME master key. Rotating a passphrase does not rotate the master key.
EOF
        ;;
    keyslot)
        cat <<'EOF'
1. Two keyslots existed. Only one was removed. What is the other one?
   sudo cryptsetup open --key-file /etc/luks-keys/lab331.key <dev> lab331
2. Once open, you still need the passphrase back. luksAddKey takes the EXISTING
   credential via --key-file and the NEW one as a positional argument or via
   an interactive prompt. Keep --pbkdf pbkdf2 --pbkdf-force-iterations 1000
   so the lab stays fast.
3. Second route: luksHeaderRestore from the backup resurrects keyslot 0. That
   is the security lesson — a header backup un-deletes a revoked credential.
EOF
        ;;
    crypttab)
        cat <<'EOF'
1. Fault 1: compare `cryptsetup luksUUID <loopdev>` with the UUID= in
   /etc/crypttab, character by character. Also: ls -l /dev/disk/by-uuid/
2. Fault 2: `wc -c /etc/luks-keys/lab331.key`. A keyfile is RAW BYTES. Every
   byte counts, including one you cannot see. Compare with `od -c` tail.
   Fixing it means either restoring the exact original bytes (truncate -s 512)
   or accepting the new file as a credential with luksAddKey.
3. Fault 3: `findmnt --verify --verbose` and read the device path in /etc/fstab
   next to /mnt/lab331. Does that node exist under /dev/mapper?
4. After ANY /etc/crypttab edit: systemctl daemon-reload. The unit is generated
   by systemd-cryptsetup-generator at reload time, not read live.
EOF
        ;;
    plain)
        cat <<'EOF'
1. Read evidence/plain-cryptsetup-status.txt FIRST. It was captured while the
   mapping was live and it names the cipher and the key size explicitly.
2. That eliminates candidate A outright, and it cannot tell you the hash —
   the hash is only used to derive the key from the passphrase, it never
   appears in the dm table. So you have exactly two candidates left.
3. Try one, `mount`, and if it fails: `cryptsetup close` BEFORE trying the
   next. Leaving stale mappings around is how people corrupt lab images.
4. `blkid /dev/mapper/lab331_plain` is a faster test than mount: with the
   right key it prints TYPE="ext4"; with the wrong key it prints nothing.
EOF
        ;;
    ecryptfs)
        cat <<'EOF'
1. Every eCryptfs file carries its own header, and there is a tool that prints
   it: ecryptfs-stat /var/lib/breakfix-331-3/ecryptfs/.Private/CANARY.txt
   Look for "Cipher:" and "Key bytes:".
2. Mount options must match what that header says, or the derived key differs.
3. Filename encryption is off in this lab (ecryptfs_enable_filename_crypto=n),
   which is why you can still see the names in the lower directory. With it on
   you would see ECRYPTFS_FNEK_ENCRYPTED.* blobs instead.
4. no_sig_cache=yes suppresses the interactive "proceed with the mount?" prompt
   that appears when the key signature is not in ~/.ecryptfs/sig-cache.txt.
EOF
        ;;
    *) die "unknown scenario '$s' — run: $0 list" ;;
    esac
}

# =============================================================================
#  VERIFIERS
# =============================================================================

check_canary() {
    local mp="$1"
    [[ -f "${mp}/${CANARY_NAME}" ]] || { warn "canary file missing at ${mp}"; return 1; }
    grep -qF "$CANARY_TEXT" "${mp}/${CANARY_NAME}" \
        || { warn "canary content does not match — decrypted with the wrong key?"; return 1; }
    return 0
}

# Closes, reopens with the PASSPHRASE, mounts, checks the canary.
verify_luks_roundtrip() {
    local dev; dev="$(luks_dev)"
    close_stack
    cryptsetup isLuks "$dev" 2>/dev/null \
        || { warn "cryptsetup isLuks: still not a valid LUKS device"; return 1; }
    printf '%s' "$PASS" | cryptsetup open --key-file - "$dev" "$MAPNAME" 2>/dev/null \
        || { warn "the documented passphrase still does not open the container"; return 1; }
    mount "/dev/mapper/${MAPNAME}" "$MOUNTPOINT" 2>/dev/null \
        || { warn "ext4 mount failed — the data area may be damaged"; return 1; }
    check_canary "$MOUNTPOINT"
}

verify_report() {
    if (( $1 == 0 )); then
        ok "PASS — scenario '${2}' is fixed."
    else
        printf '%s[FAIL]%s scenario %s is not fixed yet. Try: %s hint %s\n' \
               "$C_R" "$C_RST" "$2" "$0" "$2"
        return 1
    fi
}

cmd_verify() {
    require_root
    local s="${1:-}" rc=0 dev
    case "$s" in
    header)
        dev="$(luks_dev)"
        local m1 m2
        m1="$(magic_at "$dev" 0)"
        m2="$(magic_at "$dev" 16384)"
        info "primary magic  @0     = ${m1:-<empty>}   (want 4c554b53babe = 'LUKS'\\xba\\xbe)"
        info "secondary magic @16384 = ${m2:-<empty>}   (want 534b554cbabe = 'SKUL'\\xba\\xbe)"
        [[ "$m1" == "4c554b53babe" ]] || { warn "primary header still not restored"; rc=1; }
        verify_luks_roundtrip || rc=1
        verify_report "$rc" header
        ;;
    nuke)
        verify_luks_roundtrip || rc=1
        verify_report "$rc" nuke
        ;;
    keyslot)
        dev="$(luks_dev)"
        verify_luks_roundtrip || rc=1
        local slots
        slots="$(cryptsetup luksDump "$dev" 2>/dev/null \
                 | grep -cE '^[[:space:]]+[0-9]+: luks2' || true)"
        info "active keyslots: ${slots} (want 2 — passphrase and keyfile)"
        [[ "${slots:-0}" -ge 2 ]] || { warn "the keyfile keyslot must survive too"; rc=1; }
        if [[ -e "/dev/mapper/${MAPNAME}" ]]; then
            cryptsetup luksOpen --test-passphrase --key-file "$KEYFILE" "$dev" 2>/dev/null \
                || { warn "the keyfile no longer opens the container"; rc=1; }
        fi
        verify_report "$rc" keyslot
        ;;
    crypttab)
        close_stack
        reload_units
        udevadm settle 2>/dev/null || true
        if command -v systemctl >/dev/null 2>&1; then
            systemctl start "systemd-cryptsetup@${MAPNAME}.service" 2>/dev/null \
                || { warn "systemd-cryptsetup@${MAPNAME}.service still fails"; rc=1; }
        else
            cryptsetup open --key-file "$KEYFILE" "$(luks_dev)" "$MAPNAME" 2>/dev/null \
                || { warn "unattended keyfile activation still fails"; rc=1; }
        fi
        [[ -e "/dev/mapper/${MAPNAME}" ]] \
            || { warn "/dev/mapper/${MAPNAME} does not exist"; rc=1; }
        mount "$MOUNTPOINT" 2>/dev/null \
            || { warn "'mount ${MOUNTPOINT}' from /etc/fstab still fails"; rc=1; }
        check_canary "$MOUNTPOINT" || rc=1
        verify_report "$rc" crypttab
        ;;
    plain)
        [[ -e "/dev/mapper/${PLAIN_MAPNAME}" ]] \
            || { warn "no /dev/mapper/${PLAIN_MAPNAME} mapping is open"; rc=1; }
        is_mounted "$PLAIN_MOUNTPOINT" \
            || { warn "${PLAIN_MOUNTPOINT} is not mounted"; rc=1; }
        (( rc == 0 )) && { check_canary "$PLAIN_MOUNTPOINT" || rc=1; }
        verify_report "$rc" plain
        ;;
    ecryptfs)
        is_mounted "$ECRYPTFS_UPPER" \
            || { warn "${ECRYPTFS_UPPER} is not an eCryptfs mount"; rc=1; }
        (( rc == 0 )) && { check_canary "$ECRYPTFS_UPPER" || rc=1; }
        verify_report "$rc" ecryptfs
        ;;
    *) die "unknown scenario '$s' — run: $0 list" ;;
    esac
}

# =============================================================================
#  STATUS / RESET
# =============================================================================

cmd_status() {
    require_root
    hdr "Lab state"
    printf '%slab root%s        : %s\n' "$C_B" "$C_RST" "$LAB_ROOT"
    if [[ -f "$IMG_LUKS" ]]; then
        local dev; dev="$(luks_dev)"
        printf '%sLUKS image%s      : %s -> %s\n' "$C_B" "$C_RST" "$IMG_LUKS" "$dev"
        printf '%sprimary magic%s   : %s\n' "$C_B" "$C_RST" "$(magic_at "$dev" 0)"
        printf '%ssecondary magic%s : %s\n' "$C_B" "$C_RST" "$(magic_at "$dev" 16384)"
        if cryptsetup isLuks "$dev" 2>/dev/null; then
            printf '%sLUKS UUID%s       : %s\n' "$C_B" "$C_RST" "$(cryptsetup luksUUID "$dev")"
            printf '%skeyslots%s        : %s\n' "$C_B" "$C_RST" \
                "$(cryptsetup luksDump "$dev" | grep -cE '^[[:space:]]+[0-9]+: luks2' || echo 0)"
        else
            printf '%sLUKS UUID%s       : %s(header unreadable)%s\n' "$C_B" "$C_RST" "$C_R" "$C_RST"
        fi
    else
        warn "not built yet — run: $0 build"
    fi
    printf '\n%s/etc/crypttab%s:\n' "$C_B" "$C_RST"
    sed -n "/# ${TAG} BEGIN/,/# ${TAG} END/p" /etc/crypttab 2>/dev/null || echo '  (nothing)'
    printf '\n%s/etc/fstab%s:\n' "$C_B" "$C_RST"
    sed -n "/# ${TAG} BEGIN/,/# ${TAG} END/p" /etc/fstab 2>/dev/null || echo '  (nothing)'
    printf '\n%skeyfile%s         : ' "$C_B" "$C_RST"
    if [[ -f "$KEYFILE" ]]; then
        printf '%s (%s bytes, mode %s)\n' "$KEYFILE" \
               "$(stat -c %s "$KEYFILE")" "$(stat -c %a "$KEYFILE")"
    else
        printf '%smissing%s\n' "$C_R" "$C_RST"
    fi
    printf '\n%sactive dm targets%s:\n' "$C_B" "$C_RST"
    dmsetup ls 2>/dev/null || echo '  (none)'
    printf '\n%smounts%s:\n' "$C_B" "$C_RST"
    findmnt -n -o TARGET,SOURCE,FSTYPE "$MOUNTPOINT" "$PLAIN_MOUNTPOINT" \
            "$ECRYPTFS_UPPER" 2>/dev/null || echo '  (none)'
    printf '\n'
}

cmd_reset() {
    require_root; confirm_destructive
    hdr "Tearing the lab down"
    close_stack
    for img in "$IMG_LUKS" "$IMG_PLAIN"; do
        [[ -f "$img" ]] || continue
        losetup -j "$img" 2>/dev/null | cut -d: -f1 | while read -r d; do
            [[ -n "$d" ]] && losetup -d "$d" 2>/dev/null || true
        done
    done
    etc_strip_block /etc/crypttab
    etc_strip_block /etc/fstab
    [[ -f "${BACKUP_DIR}/crypttab.orig" ]] && cp -a "${BACKUP_DIR}/crypttab.orig" /etc/crypttab
    [[ -f "${BACKUP_DIR}/fstab.orig"    ]] && cp -a "${BACKUP_DIR}/fstab.orig"    /etc/fstab
    reload_units
    rm -f "$KEYFILE"
    rmdir "$KEYDIR" 2>/dev/null || true
    rm -rf "$LAB_ROOT"
    rmdir "$MOUNTPOINT" "$PLAIN_MOUNTPOINT" 2>/dev/null || true
    ok "lab removed; /etc/crypttab and /etc/fstab restored"
}

cmd_solution() {
    sed -n '/^# ==== SOLUTION START/,/^# ==== SOLUTION END/p' "$0"
}

# =============================================================================
#  DISPATCH
# =============================================================================

usage() {
    sed -n '2,60p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
}

main() {
    local args=() a
    for a in "$@"; do
        case "$a" in
            -y|--yes) ASSUME_YES=1 ;;
            *) args+=("$a") ;;
        esac
    done
    set -- "${args[@]:-}"

    case "${1:-help}" in
        build)   cmd_build ;;
        rebuild) cmd_reset; cmd_build ;;
        list)    cmd_list ;;
        status)  cmd_status ;;
        reset)   cmd_reset ;;
        solution) cmd_solution ;;
        hint)    cmd_hint "${2:-}" ;;
        verify)  cmd_verify "${2:-}" ;;
        break)
            require_root; require_tools
            [[ -f "$IMG_LUKS" ]] || die "lab not built — run: $0 build"
            confirm_destructive
            case "${2:-}" in
                header)   break_header ;;
                nuke)     break_nuke ;;
                keyslot)  break_keyslot ;;
                crypttab) break_crypttab ;;
                plain)    break_plain ;;
                ecryptfs) break_ecryptfs ;;
                *) die "unknown scenario '${2:-}' — run: $0 list" ;;
            esac
            ;;
        help|-h|--help) usage ;;
        *) die "unknown command '${1}' — run: $0 help" ;;
    esac
}

main "$@"
exit 0
