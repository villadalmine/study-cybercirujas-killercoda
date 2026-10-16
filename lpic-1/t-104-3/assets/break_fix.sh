#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-1  (Exam 101-500 / 102-500, version 5.0)
#  Topic 104.3 - Control mounting and unmounting of filesystems
#  Exam weight: 4.69
#
#  BREAK & FIX LAB - lpic1-104.3-mount-breakfix.sh
#
#  Reference: https://www.lpi.org/our-certifications/exam-101-objectives/
#             mount(8), umount(8), fstab(5), findmnt(8), lsof(8), fuser(1),
#             losetup(8), blkid(8), systemd.mount(5)
#
#  WHAT THIS SCRIPT DOES
#    It builds four loopback block devices, formats them, mounts them, seeds
#    them with data, writes /etc/fstab entries for them, and then introduces
#    five realistic, self-contained mount faults. Nothing outside the lab
#    directory, the five /mnt/lab-* mount points and one clearly delimited
#    /etc/fstab block is touched.
#
#  RUN THIS ONLY ON A DISPOSABLE LABORATORY VM.
#    Fault 1 leaves a boot-blocking entry in /etc/fstab on purpose (no
#    'nofail', pass 2). That is the single most important production lesson in
#    this objective, and you cannot learn it from a description. If you reboot
#    before fixing it, systemd will drop you into emergency mode - the recovery
#    procedure is part of the solution at the bottom of this file.
#
#  USAGE
#    sudo ./lpic1-104.3-mount-breakfix.sh --break     # create + break the lab
#    sudo ./lpic1-104.3-mount-breakfix.sh --brief     # reprint the mission
#    sudo ./lpic1-104.3-mount-breakfix.sh --check     # grade your repair
#    sudo ./lpic1-104.3-mount-breakfix.sh --restore   # full, clean teardown
#
#  The solution, step by step, is at the end of this file - commented out.
#  Do not read it until --check refuses to give you five PASS lines.
# =============================================================================

set -Eeuo pipefail

# --- Lab constants -----------------------------------------------------------

LAB_ID="lpic1-104.3"
LAB_HOME="/var/lib/lpic-lab/104.3"
STATE="${LAB_HOME}/state.env"
FSTAB="/etc/fstab"
FSTAB_BACKUP="/etc/fstab.${LAB_ID}.orig"
MARK_BEGIN="# >>> ${LAB_ID} LAB BEGIN >>>"
MARK_END="# <<< ${LAB_ID} LAB END <<<"

MP_DATA="/mnt/lab-data"
MP_ARCHIVE="/mnt/lab-archive"
MP_LOGS="/mnt/lab-logs"
MP_SCRATCH="/mnt/lab-scratch"
MP_SHARED="/mnt/lab-shared"

IMG_DATA="${LAB_HOME}/data.img"
IMG_ARCHIVE="${LAB_HOME}/archive.img"
IMG_LOGS="${LAB_HOME}/logs.img"
IMG_SCRATCH="${LAB_HOME}/scratch.img"

TOKEN_DATA="LAB1043-DATA-OK"
TOKEN_ARCHIVE="LAB1043-ARCHIVE-OK"
TOKEN_LOGS="LAB1043-LOGS-OK"
TOKEN_SHARED="LAB1043-SHARED-OK"

# --- Output helpers ----------------------------------------------------------

if [ -t 1 ]; then
    C_OK=$'\033[1;32m'; C_BAD=$'\033[1;31m'; C_WARN=$'\033[1;33m'
    C_HEAD=$'\033[1;36m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_BAD=""; C_WARN=""; C_HEAD=""; C_OFF=""
fi

info()  { printf '[*] %s\n'  "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_OK"   "$C_OFF" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
bad()   { printf '%s[-]%s %s\n' "$C_BAD"  "$C_OFF" "$*"; }
head_() { printf '\n%s== %s ==%s\n' "$C_HEAD" "$*" "$C_OFF"; }
die()   { printf '%s[FATAL]%s %s\n' "$C_BAD" "$C_OFF" "$*" >&2; exit 1; }

# --- Guard rails -------------------------------------------------------------

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This lab manipulates block devices and ${FSTAB}; run it as root."
    fi
}

require_cmds() {
    local c missing=""
    for c in "$@"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            missing="${missing} ${c}"
        fi
    done
    if [ -n "$missing" ]; then
        die "Missing required command(s):${missing}"
    fi
}

confirm_disposable_vm() {
    if [ "${LAB_ASSUME_YES:-no}" = "yes" ]; then
        warn "LAB_ASSUME_YES=yes - skipping the interactive confirmation."
        return 0
    fi
    if [ ! -t 0 ]; then
        die "Refusing to run non-interactively. Set LAB_ASSUME_YES=yes if this really is a throwaway VM."
    fi
    head_ "CONFIRMATION REQUIRED"
    cat <<'EOF'
This script will:
  * create four loopback disk images under /var/lib/lpic-lab/104.3
  * create and use /mnt/lab-data /mnt/lab-archive /mnt/lab-logs
                   /mnt/lab-scratch /mnt/lab-shared
  * append a clearly delimited block to /etc/fstab, one entry of which
    WILL BLOCK THE NEXT BOOT until you repair it
  * leave a background process holding a mount point busy

It is reversible with --restore, but only from a running system.
EOF
    printf '\nType exactly: BREAK MY LAB VM\n> '
    local answer=""
    IFS= read -r answer || true
    if [ "$answer" != "BREAK MY LAB VM" ]; then
        die "Confirmation not given. Nothing was modified."
    fi
}

# --- State -------------------------------------------------------------------

save_state() {
    umask 077
    cat > "$STATE" <<EOF
# ${LAB_ID} lab state - generated $(date -Is)
LOOP_DATA='${LOOP_DATA}'
LOOP_ARCHIVE='${LOOP_ARCHIVE}'
LOOP_LOGS='${LOOP_LOGS}'
LOOP_SCRATCH='${LOOP_SCRATCH}'
UUID_DATA='${UUID_DATA}'
UUID_LOGS='${UUID_LOGS}'
BAD_UUID='${BAD_UUID}'
ARCHIVE_FSTYPE='${ARCHIVE_FSTYPE}'
ARCHIVE_WRONG_FSTYPE='${ARCHIVE_WRONG_FSTYPE}'
HOLDER_PID='${HOLDER_PID}'
EOF
}

load_state() {
    if [ ! -r "$STATE" ]; then
        die "No lab state at ${STATE}. Run '$0 --break' first."
    fi
    # shellcheck disable=SC1090
    . "$STATE"
}

# --- fstab manipulation ------------------------------------------------------

fstab_strip_lab_block() {
    local tmp
    tmp="$(mktemp "${FSTAB}.lab.XXXXXX")"
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        index($0, b) { skip = 1 }
        !skip        { print }
        index($0, e) { skip = 0 }
    ' "$FSTAB" > "$tmp"
    cat "$tmp" > "$FSTAB"      # preserve inode, mode and SELinux context
    rm -f "$tmp"
}

# Return field $2 of the last non-comment fstab line whose mount point is $1.
fstab_field() {
    awk -v mp="$1" -v f="$2" '
        $0 ~ /^[[:space:]]*#/ { next }
        NF >= 4 && $2 == mp   { val = $f }
        END { if (val != "") print val }
    ' "$FSTAB"
}

# --- Loop device helpers -----------------------------------------------------

make_disk() {   # make_disk <image> <size> <mkfs-cmd...> ; echoes the loop device
    local img="$1"; shift
    local size="$1"; shift
    rm -f "$img"
    truncate -s "$size" "$img"
    local loop
    loop="$(losetup --find --show "$img")"
    "$@" "$loop" >/dev/null 2>&1
    udevadm settle >/dev/null 2>&1 || true
    printf '%s\n' "$loop"
}

detach_loop() {
    local loop="$1"
    if [ -n "$loop" ] && losetup "$loop" >/dev/null 2>&1; then
        losetup --detach "$loop" || true
    fi
}

force_umount() {
    local mp="$1"
    if mountpoint -q "$mp" 2>/dev/null; then
        umount "$mp" 2>/dev/null || umount --lazy "$mp" 2>/dev/null || true
    fi
}

# --- Build the lab -----------------------------------------------------------

build_lab() {
    head_ "BUILDING THE LAB"
    mkdir -p "$LAB_HOME" "$MP_DATA" "$MP_ARCHIVE" "$MP_LOGS" "$MP_SCRATCH" "$MP_SHARED"

    if [ ! -f "$FSTAB_BACKUP" ]; then
        cp -a "$FSTAB" "$FSTAB_BACKUP"
        info "Pristine ${FSTAB} saved to ${FSTAB_BACKUP}"
    fi

    info "Creating loopback devices and filesystems (64 MiB each)..."
    LOOP_DATA="$(make_disk "$IMG_DATA" 64M mkfs.ext4 -q -L LABDATA -F)"
    LOOP_LOGS="$(make_disk "$IMG_LOGS" 64M mkfs.ext4 -q -L LABLOGS -F)"
    LOOP_SCRATCH="$(make_disk "$IMG_SCRATCH" 64M mkfs.ext4 -q -L LABSCRATCH -F)"

    # The archive volume is intentionally a *different* filesystem type from
    # the one /etc/fstab will claim. vfat if dosfstools is installed, ext4
    # otherwise - the diagnostic path the student walks is identical.
    if command -v mkfs.vfat >/dev/null 2>&1; then
        ARCHIVE_FSTYPE="vfat"
        ARCHIVE_WRONG_FSTYPE="ext4"
        LOOP_ARCHIVE="$(make_disk "$IMG_ARCHIVE" 64M mkfs.vfat -n LABARCH)"
    else
        ARCHIVE_FSTYPE="ext4"
        ARCHIVE_WRONG_FSTYPE="xfs"
        LOOP_ARCHIVE="$(make_disk "$IMG_ARCHIVE" 64M mkfs.ext4 -q -L LABARCH -F)"
        warn "mkfs.vfat not found; the archive volume is ext4 declared as xfs."
    fi

    UUID_DATA="$(blkid -s UUID -o value "$LOOP_DATA")"
    UUID_LOGS="$(blkid -s UUID -o value "$LOOP_LOGS")"
    [ -n "$UUID_DATA" ] && [ -n "$UUID_LOGS" ] || die "blkid returned no UUID; is udev running?"

    # A believable typo: same UUID, last four hex digits mangled.
    BAD_UUID="${UUID_DATA%????}dead"

    info "Seeding data..."
    mount "$LOOP_DATA" "$MP_DATA"
    printf 'employee,net\nalice,4210\nbob,3980\n# %s\n' "$TOKEN_DATA" > "${MP_DATA}/payroll.csv"
    umount "$MP_DATA"

    mount -t "$ARCHIVE_FSTYPE" "$LOOP_ARCHIVE" "$MP_ARCHIVE"
    printf 'cold storage - %s\n' "$TOKEN_ARCHIVE" > "${MP_ARCHIVE}/README.txt"
    umount "$MP_ARCHIVE"

    mount "$LOOP_LOGS" "$MP_LOGS"
    printf '%s ingest started - %s\n' "$(date -Is)" "$TOKEN_LOGS" > "${MP_LOGS}/app.log"

    mount "$LOOP_SCRATCH" "$MP_SCRATCH"
    dd if=/dev/zero of="${MP_SCRATCH}/spool.tmp" bs=1M count=4 status=none

    # /mnt/lab-shared holds real files on the ROOT filesystem - no loop device.
    printf 'Q3 revenue report - %s\n' "$TOKEN_SHARED" > "${MP_SHARED}/quarterly-report.txt"
    ok "Lab volumes built."
}

# --- Introduce the faults ----------------------------------------------------

break_lab() {
    head_ "INTRODUCING FAULTS"

    # ---- Fault 1 + 2 + 3 live in /etc/fstab. Comments here are deliberately
    #      realistic: they describe the volume, not the bug.
    fstab_strip_lab_block
    {
        printf '%s\n' "$MARK_BEGIN"
        printf '# payroll volume - migrated from /dev/sdb1 on %s\n' "$(date +%F)"
        printf 'UUID=%s\t%s\text4\tdefaults\t0 2\n' "$BAD_UUID" "$MP_DATA"
        printf '# cold archive volume\n'
        printf 'LABEL=LABARCH\t%s\t%s\tdefaults,nofail\t0 2\n' \
               "$MP_ARCHIVE" "$ARCHIVE_WRONG_FSTYPE"
        printf '# application log volume\n'
        printf 'UUID=%s\t%s\text4\tro,nosuid,nodev,nofail\t0 2\n' "$UUID_LOGS" "$MP_LOGS"
        printf '%s\n' "$MARK_END"
    } >> "$FSTAB"
    info "Fault 1/2/3 written to ${FSTAB}"

    systemctl daemon-reload >/dev/null 2>&1 || true

    # ---- Fault 3, runtime half: the live mount is degraded to read-only.
    mount -o remount,ro "$MP_LOGS"
    info "Fault 3: ${MP_LOGS} remounted read-only."

    # ---- Fault 4: a long-lived process whose CWD is inside the mount point.
    nohup sh -c 'cd "$1" || exit 1; exec sleep 7200' sh "$MP_SCRATCH" \
        >/dev/null 2>&1 </dev/null &
    HOLDER_PID="$!"
    sleep 0.3
    info "Fault 4: PID ${HOLDER_PID} is holding ${MP_SCRATCH} busy."

    # ---- Fault 5: a tmpfs shadow-mounted over a directory that has real data.
    mount -t tmpfs -o size=16M,mode=0755 tmpfs "$MP_SHARED"
    printf 'scratch placeholder\n' > "${MP_SHARED}/placeholder.txt"
    info "Fault 5: ${MP_SHARED} is shadowed by a tmpfs."

    save_state
    ok "Five faults are live. State recorded in ${STATE}"
}

# --- Student briefing --------------------------------------------------------

brief() {
    load_state
    head_ "LPIC-1 104.3 - MOUNT & UMOUNT: BREAK & FIX BRIEFING"
    cat <<EOF

You have inherited a server whose storage layer was "tidied up" by someone in a
hurry. Five things are wrong. Fix all five, using only the tools in this
objective: mount, umount, findmnt, blkid, lsof, fuser, and /etc/fstab.

Every lab volume is a loopback device backed by an image in ${LAB_HOME}.
Nothing outside ${LAB_HOME}, /mnt/lab-* and the delimited block in ${FSTAB}
is part of this exercise - if you find yourself editing anything else, stop.

-----------------------------------------------------------------------------
FAULT 1 - The payroll volume will not mount, and the machine will not boot
-----------------------------------------------------------------------------
  SYMPTOM   'mount -a' fails with something close to:
              mount: ${MP_DATA}: can't find UUID=<something>.
            ${MP_DATA} is empty. 'findmnt --verify' reports an unreachable
            source. Because that entry has no 'nofail' and a non-zero fsck
            pass, a reboot right now would land you in:
              "You are in emergency mode. ... Press Enter for maintenance"
  GOAL      ${MP_DATA} mounted, containing payroll.csv, and the entry in
            ${FSTAB} correct - so 'mount -a' is silent and repeatable.
  DO NOT    Reboot to "see what happens" until this one is fixed.

-----------------------------------------------------------------------------
FAULT 2 - The archive volume is rejected as unformatted
-----------------------------------------------------------------------------
  SYMPTOM   'mount ${MP_ARCHIVE}' fails with:
              mount: ${MP_ARCHIVE}: wrong fs type, bad option, bad superblock
              on /dev/loopN, missing codepage or helper program, or other error
            dmesg shows the driver refusing the superblock.
  GOAL      ${MP_ARCHIVE} mounted with its README.txt readable, and ${FSTAB}
            telling the truth about the on-disk filesystem type.
  HINT      The device is fine. Ask the device what it is, do not trust fstab.

-----------------------------------------------------------------------------
FAULT 3 - The application cannot write its log
-----------------------------------------------------------------------------
  SYMPTOM   echo hello >> ${MP_LOGS}/app.log
              -bash: ${MP_LOGS}/app.log: Read-only file system
            The volume IS mounted; 'findmnt' shows 'ro' in its options.
  GOAL      ${MP_LOGS} writable now, AND still writable after 'mount -a' or a
            reboot. A fix that survives only until the next boot is not a fix.
  HINT      Two places carry the same wrong answer: the running kernel mount
            table and ${FSTAB}.

-----------------------------------------------------------------------------
FAULT 4 - The scratch volume refuses to unmount
-----------------------------------------------------------------------------
  SYMPTOM   umount ${MP_SCRATCH}
              umount: ${MP_SCRATCH}: target is busy.
  GOAL      ${MP_SCRATCH} cleanly unmounted, and you must be able to name the
            PID, the command and the reason it was holding the mount point.
  HINT      'umount -l' hides the problem instead of solving it. Identify the
            offender first; only then decide what to do with it.

-----------------------------------------------------------------------------
FAULT 5 - The quarterly report "disappeared"
-----------------------------------------------------------------------------
  SYMPTOM   ls ${MP_SHARED} shows only placeholder.txt. quarterly-report.txt
            is gone - but no one deleted it, and backups say the bytes are
            still on the root filesystem.
  GOAL      quarterly-report.txt readable at its original path again, with
            ${MP_SHARED} no longer a mount point.
  HINT      A mount does not delete the directory underneath it. It hides it.
            'findmnt ${MP_SHARED}' and 'df -h ${MP_SHARED}' will tell you what
            is sitting on top.

-----------------------------------------------------------------------------
TOOLS WORTH KNOWING BEFORE YOU START
-----------------------------------------------------------------------------
  findmnt                       tree of everything mounted, from /proc/self/mountinfo
  findmnt --verify --verbose    static validation of /etc/fstab - use it
  findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS
  blkid / lsblk -f              what a device actually contains (UUID, LABEL, TYPE)
  mount -a                      mount everything in fstab that is not mounted yet
  mount -o remount,rw <target>  change options of a live mount, no unmount
  fuser -vm <mountpoint>        who is using this filesystem
  lsof +f -- <mountpoint>       same question, more detail
  systemctl daemon-reload       systemd re-reads /etc/fstab into .mount units
  losetup -a                    the loopback devices behind this lab

GRADE YOUR WORK:  sudo $0 --check
TEAR THE LAB DOWN: sudo $0 --restore

EOF
}

# --- Grading -----------------------------------------------------------------

check_lab() {
    load_state
    head_ "GRADING"
    local fails=0
    local mnt_src mnt_fstype mnt_opts fstab_type fstab_opts rc

    # ---- Fault 1
    rc=0
    mount -a >/dev/null 2>&1 || rc=$?
    if mountpoint -q "$MP_DATA" \
       && grep -q "$TOKEN_DATA" "${MP_DATA}/payroll.csv" 2>/dev/null \
       && [ "$rc" -eq 0 ] \
       && ! grep -qi "$BAD_UUID" "$FSTAB"; then
        ok    "FAULT 1  payroll volume mounted, 'mount -a' clean, bad UUID gone"
    else
        bad   "FAULT 1  still open"
        [ "$rc" -eq 0 ] || printf '           'mount -a' exits %s\n' "$rc"
        mountpoint -q "$MP_DATA" || printf '           %s is not mounted\n' "$MP_DATA"
        grep -qi "$BAD_UUID" "$FSTAB" && printf '           the bogus UUID is still in %s\n' "$FSTAB"
        fails=$((fails + 1))
    fi

    # ---- Fault 2
    mnt_fstype="$(findmnt -no FSTYPE "$MP_ARCHIVE" 2>/dev/null || true)"
    fstab_type="$(fstab_field "$MP_ARCHIVE" 3)"
    if [ "$mnt_fstype" = "$ARCHIVE_FSTYPE" ] \
       && grep -q "$TOKEN_ARCHIVE" "${MP_ARCHIVE}/README.txt" 2>/dev/null \
       && { [ "$fstab_type" = "$ARCHIVE_FSTYPE" ] || [ "$fstab_type" = "auto" ]; }; then
        ok    "FAULT 2  archive mounted as ${ARCHIVE_FSTYPE} and fstab agrees"
    else
        bad   "FAULT 2  still open (mounted='${mnt_fstype:-none}' fstab='${fstab_type:-none}' expected='${ARCHIVE_FSTYPE}')"
        fails=$((fails + 1))
    fi

    # ---- Fault 3
    mnt_opts="$(findmnt -no OPTIONS "$MP_LOGS" 2>/dev/null || true)"
    fstab_opts="$(fstab_field "$MP_LOGS" 4)"
    if printf '%s' ",${mnt_opts}," | grep -q ',rw,' \
       && ! printf '%s' ",${fstab_opts}," | grep -q ',ro,' \
       && [ -w "${MP_LOGS}/app.log" ] \
       && ( : >> "${MP_LOGS}/app.log" ) 2>/dev/null; then
        ok    "FAULT 3  log volume writable now and in ${FSTAB}"
    else
        bad   "FAULT 3  still open (live='${mnt_opts:-none}' fstab='${fstab_opts:-none}')"
        fails=$((fails + 1))
    fi

    # ---- Fault 4
    if ! mountpoint -q "$MP_SCRATCH"; then
        ok    "FAULT 4  scratch volume unmounted"
        if [ -n "${HOLDER_PID}" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
            warn "         PID ${HOLDER_PID} is still alive - acceptable if you"
            warn "         moved its CWD out, suspicious if you used 'umount -l'."
        fi
    else
        bad   "FAULT 4  still open - ${MP_SCRATCH} is mounted"
        fails=$((fails + 1))
    fi

    # ---- Fault 5
    if ! mountpoint -q "$MP_SHARED" \
       && grep -q "$TOKEN_SHARED" "${MP_SHARED}/quarterly-report.txt" 2>/dev/null; then
        ok    "FAULT 5  shadowing mount removed, report readable again"
    else
        bad   "FAULT 5  still open - ${MP_SHARED} is still shadowed or the file is unreadable"
        fails=$((fails + 1))
    fi

    # ---- Bonus: static validation of the whole file
    head_ "findmnt --verify"
    rc=0
    findmnt --verify --verbose 2>&1 | tail -n 20 || rc=$?
    if [ "$rc" -ne 0 ]; then
        warn "findmnt --verify is unhappy - read its output above before you call this done."
    fi

    head_ "RESULT"
    if [ "$fails" -eq 0 ]; then
        ok "5/5 faults repaired. Now prove it survives a reboot: 'reboot', then re-run --check."
        return 0
    fi
    bad "${fails} fault(s) still open."
    return 1
}

# --- Teardown ----------------------------------------------------------------

restore_lab() {
    head_ "RESTORING"
    if [ -r "$STATE" ]; then
        # shellcheck disable=SC1090
        . "$STATE"
        if [ -n "${HOLDER_PID:-}" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
            kill "$HOLDER_PID" 2>/dev/null || true
            sleep 0.3
            kill -9 "$HOLDER_PID" 2>/dev/null || true
            info "Holder process ${HOLDER_PID} terminated."
        fi
    fi

    fstab_strip_lab_block
    systemctl daemon-reload >/dev/null 2>&1 || true
    info "Lab block removed from ${FSTAB}"

    local mp
    for mp in "$MP_SHARED" "$MP_SCRATCH" "$MP_LOGS" "$MP_ARCHIVE" "$MP_DATA"; do
        force_umount "$mp"
        force_umount "$mp"          # a second pass clears a stacked mount
    done

    local loop
    for loop in "${LOOP_DATA:-}" "${LOOP_ARCHIVE:-}" "${LOOP_LOGS:-}" "${LOOP_SCRATCH:-}"; do
        detach_loop "$loop"
    done
    # Catch loop devices left behind by an interrupted run.
    losetup -a 2>/dev/null | awk -F: -v d="$LAB_HOME" 'index($0, d) {print $1}' \
        | while read -r loop; do detach_loop "$loop"; done

    for mp in "$MP_DATA" "$MP_ARCHIVE" "$MP_LOGS" "$MP_SCRATCH" "$MP_SHARED"; do
        if ! mountpoint -q "$mp" 2>/dev/null; then
            rm -rf "${mp:?}"
        else
            warn "${mp} is still mounted; leaving it alone."
        fi
    done

    rm -rf "$LAB_HOME"
    ok "Lab removed. Your original ${FSTAB} is still archived at ${FSTAB_BACKUP}"
    warn "Compare it before you trust the result:  diff ${FSTAB_BACKUP} ${FSTAB}"
}

usage() {
    cat <<EOF
${LAB_ID} - break & fix lab for LPIC-1 topic 104.3

  --break     build the lab volumes and introduce the five faults (default)
  --brief     reprint the student briefing
  --check     grade the repair
  --restore   unmount, detach, clean /etc/fstab, delete the lab
  --help      this text

Environment:
  LAB_ASSUME_YES=yes   skip the interactive confirmation (unattended runs)
EOF
}

main() {
    require_root
    case "${1:---break}" in
        --break)
            require_cmds losetup mkfs.ext4 blkid mount umount findmnt awk truncate mountpoint
            if [ -f "$STATE" ]; then
                die "A lab is already active. Run '$0 --restore' first, or '$0 --brief'."
            fi
            confirm_disposable_vm
            build_lab
            break_lab
            brief
            ;;
        --brief)   brief ;;
        --check)   check_lab ;;
        --restore) restore_lab ;;
        --help|-h) usage ;;
        *)         usage; exit 2 ;;
    esac
}

main "$@"
