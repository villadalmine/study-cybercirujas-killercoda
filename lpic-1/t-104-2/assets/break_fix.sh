#!/usr/bin/env bash
#
# lpic1-104.2-break-and-fix.sh
#
# LPIC-1 v5.0 -- Exam 101-500 -- Topic 104.2: Maintain the integrity of filesystems
# Exam weight: 3.12
# Objective reference: https://www.lpi.org/our-certifications/exam-101-objectives/
#
# Key knowledge exercised here (all of it is on the objective list):
#   fsck / e2fsck / mke2fs / tune2fs / dumpe2fs / debugfs
#   du / df / lsof (deleted-but-open descriptors)
#   xfs_info / xfs_repair / xfs_db  (xfs_fsr is mentioned in the solution notes)
#
# WHAT THIS SCRIPT DOES
#   It builds five self-contained, loop-device-backed filesystems under a scratch
#   directory, breaks each one in a controlled and reproducible way, and tells you
#   the symptom you are about to see and the mission you must accomplish.
#   It NEVER touches a real block device: every destructive command is guarded by
#   assert_lab_loop(), which refuses to run unless the target loop device is backed
#   by a file inside "$LAB_ROOT".
#
# SAFETY CONTRACT
#   * Run it as root on a DISPOSABLE lab VM. Nothing else.
#   * All state lives under $LAB_ROOT (default /var/tmp/lpic1-104.2-lab).
#   * "cleanup" kills the helper process, unmounts, detaches every loop device it
#     created and deletes the scratch directory.
#
# USAGE
#   ./lpic1-104.2-break-and-fix.sh list
#   ./lpic1-104.2-break-and-fix.sh break 1        # break one scenario
#   ./lpic1-104.2-break-and-fix.sh break all      # break all five
#   ./lpic1-104.2-break-and-fix.sh check 1        # grade your repair
#   ./lpic1-104.2-break-and-fix.sh status
#   ./lpic1-104.2-break-and-fix.sh solution       # spoilers
#   ./lpic1-104.2-break-and-fix.sh cleanup
#
# Set LPIC_LAB_CONFIRMED=yes to skip the interactive confirmation (unattended runs).

set -euo pipefail

LAB_ROOT=${LAB_ROOT:-/var/tmp/lpic1-104.2-lab}
MNT_ROOT="$LAB_ROOT/mnt"
STATE="$LAB_ROOT/state"

# --------------------------------------------------------------------------- #
# Output helpers
# --------------------------------------------------------------------------- #

hr()    { printf '%s\n' "-----------------------------------------------------------------------"; }
say()   { printf '%s\n' "$*"; }
info()  { printf '[*] %s\n' "$*"; }
warn()  { printf '[!] %s\n' "$*" >&2; }
die()   { printf '[X] %s\n' "$*" >&2; exit 1; }

title() {
    printf '\n'
    hr
    printf '  %s\n' "$*"
    hr
}

section() { printf '\n%s\n' "$*"; }

# Run a command that is EXPECTED to fail, and show the student the real output.
show_failure() {
    printf '    $ %s\n' "$*"
    "$@" 2>&1 | sed 's/^/    /' || true
}

# --------------------------------------------------------------------------- #
# Preflight and safety
# --------------------------------------------------------------------------- #

require_tools() {
    local missing=()
    local t
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if ((${#missing[@]})); then
        die "missing required tools: ${missing[*]} (install e2fsprogs / util-linux)"
    fi
}

preflight() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run this as root on a disposable lab VM"

    require_tools losetup mount umount mkfs.ext4 e2fsck dumpe2fs tune2fs debugfs \
                  df du find dd sha256sum truncate

    modprobe loop >/dev/null 2>&1 || true
    [[ -e /dev/loop-control ]] || die "no loop device support in this kernel"

    mkdir -p "$LAB_ROOT" "$MNT_ROOT" "$STATE"
}

confirm_destructive() {
    [[ ${LPIC_LAB_CONFIRMED:-no} == yes ]] && return 0

    title "LPIC-1 104.2 lab -- destructive filesystem exercises"
    say "  host          : $(hostname)"
    say "  scratch area  : $LAB_ROOT"
    say ""
    say "  This lab creates loop-backed filesystem images and then corrupts them"
    say "  on purpose. It does not write to any device outside $LAB_ROOT, but you"
    say "  should still only run it on a VM you are willing to throw away."
    say ""
    if [[ ! -t 0 ]]; then
        die "not an interactive terminal; re-run with LPIC_LAB_CONFIRMED=yes if you are sure"
    fi
    local ans=""
    read -r -p "  Type LAB to continue: " ans
    [[ $ans == LAB ]] || die "aborted by user"
}

# Hard guard: the only block devices this script is ever allowed to write to are
# loop devices whose backing file lives inside $LAB_ROOT.
assert_lab_loop() {
    local dev=$1 backing=""
    [[ -b $dev ]] || die "refusing: '$dev' is not a block device"
    backing=$(losetup -n -O BACK-FILE "$dev" 2>/dev/null || true)
    case "$backing" in
        "$LAB_ROOT"/*) return 0 ;;
        *) die "refusing to touch $dev: backing file '$backing' is outside $LAB_ROOT" ;;
    esac
}

save_state() {
    local id=$1; shift
    printf '%s\n' "$@" > "$STATE/$id.env"
}

load_state() {
    local id=$1
    [[ -f $STATE/$id.env ]] || die "scenario $id has not been broken yet (run: $0 break $id)"
    # shellcheck disable=SC1090
    . "$STATE/$id.env"
}

new_image() {
    # new_image <id> <size> -> prints the loop device
    local id=$1 size=$2 img dev
    img="$LAB_ROOT/$id.img"
    rm -f "$img"
    truncate -s "$size" "$img"
    dev=$(losetup --find --show "$img")
    printf '%s\n' "$dev"
}

# --------------------------------------------------------------------------- #
# Scenario 1 -- ext4 primary superblock and group descriptors destroyed
# --------------------------------------------------------------------------- #

break_1() {
    local id=s1 dev mnt img
    mnt="$MNT_ROOT/$id"
    mkdir -p "$mnt"

    info "scenario 1: building a 512M ext4 filesystem (forced 4K blocks)"
    dev=$(new_image "$id" 512M)
    img="$LAB_ROOT/$id.img"
    assert_lab_loop "$dev"

    mkfs.ext4 -q -F -b 4096 -L LAB1042SB "$dev"
    mount "$dev" "$mnt"

    mkdir -p "$mnt/srv/payroll" "$mnt/etc"
    printf 'employee,net\nada,4210.00\ngrace,5180.00\n' > "$mnt/srv/payroll/2026-08.csv"
    dd if=/dev/urandom of="$mnt/srv/payroll/archive.bin" bs=1M count=12 status=none
    printf 'THIS FILE MUST SURVIVE THE REPAIR\n' > "$mnt/etc/canary.txt"
    ( cd "$mnt" && find srv etc -type f -print0 | xargs -0 sha256sum ) > "$STATE/$id.sha256"
    sync
    umount "$mnt"

    # Record the backup superblock locations for the grader (the student must
    # rediscover them with mke2fs -n / dumpe2fs).
    local backups
    backups=$(dumpe2fs "$dev" 2>/dev/null | awk '/Backup superblock at/ {gsub(",","",$4); print $4}' | tr '\n' ' ')

    info "scenario 1: wiping the primary superblock and the first group descriptors"
    dd if=/dev/zero of="$dev" bs=1024 seek=1 count=8 conv=notrunc status=none
    sync
    blockdev --flushbufs "$dev" 2>/dev/null || true

    save_state "$id" "IMG=$img" "DEV=$dev" "MNT=$mnt" "BACKUPS='$backups'" "BLOCKSIZE=4096"

    title "SCENARIO 1 -- 'the disk is dead' (ext4, destroyed superblock)"
    say "  Device      : $dev   (backing file: $img)"
    say "  Mount point : $mnt   (currently NOT mounted)"

    section "SYMPTOM -- this is what you get right now:"
    show_failure mount "$dev" "$mnt"
    say ""
    say "    ...and the kernel ring buffer says something like:"
    say "    EXT4-fs (loop0): VFS: Can't find ext4 filesystem"
    say ""
    say "    dumpe2fs is equally unhappy:"
    show_failure dumpe2fs -h "$dev"

    section "WHAT ACTUALLY HAPPENED (mechanics)"
    say "  An ext4 filesystem keeps its primary superblock at byte offset 1024 of"
    say "  the volume, followed by the block group descriptor table. Eight kilobytes"
    say "  starting at offset 1024 were overwritten with zeroes -- exactly what a"
    say "  stray 'dd of=/dev/sdX' or a partition-table tool writing to the wrong"
    say "  device does. The DATA is untouched: only the map to it is gone."
    say "  mke2fs writes redundant copies of the superblock and of the descriptor"
    say "  table in later block groups (sparse_super puts them in groups 1, 3, 5, 7,"
    say "  9, 25, ...), and e2fsck can rebuild the front of the disk from any of them."

    section "YOUR MISSION"
    say "  1. Discover where the backup superblocks are, WITHOUT writing to the device."
    say "  2. Repair the filesystem from a backup superblock."
    say "  3. Mount it at $mnt and prove nothing was lost:"
    say "       cd $mnt && sha256sum -c $STATE/$id.sha256"
    say "  Then grade yourself:  $0 check 1"

    section "HINTS"
    say "  * mke2fs -n  simulates a mkfs and prints the layout; it writes NOTHING."
    say "  * The block size matters. This filesystem was made with -b 4096."
    say "  * e2fsck needs both the backup superblock number and the block size."
    say "  * dumpe2fs can read a backup directly: -o superblock=N -o blocksize=4096"
}

check_1() {
    local id=s1
    load_state "$id"
    mountpoint -q "$MNT" || { warn "scenario 1: $MNT is not mounted -- repair it and mount it"; return 1; }
    if ( cd "$MNT" && sha256sum -c "$STATE/$id.sha256" >/dev/null 2>&1 ); then
        info "scenario 1: PASS -- filesystem repaired and every checksum matches"
        return 0
    fi
    warn "scenario 1: FAIL -- mounted, but the payload does not match the manifest"
    return 1
}

# --------------------------------------------------------------------------- #
# Scenario 2 -- df says full, du says empty (unlinked file held open)
# --------------------------------------------------------------------------- #

break_2() {
    local id=s2 dev mnt img holder target pid
    mnt="$MNT_ROOT/$id"
    mkdir -p "$mnt"

    info "scenario 2: building a 400M ext4 filesystem for /var/log"
    dev=$(new_image "$id" 400M)
    img="$LAB_ROOT/$id.img"
    assert_lab_loop "$dev"

    mkfs.ext4 -q -F -L LAB1042LOG "$dev"
    mount "$dev" "$mnt"
    mkdir -p "$mnt/var/log"
    printf 'Aug 26 09:00:01 lab lab-appd[1]: service started\n' > "$mnt/var/log/messages"

    holder="$STATE/$id-holder.sh"
    cat > "$holder" <<'HOLDER'
#!/usr/bin/env bash
# Simulates a long-running daemon whose log file was deleted by a well-meaning
# operator (or by a broken logrotate rule) while the daemon still holds the fd.
target="$1"
exec 9>"$target"
dd if=/dev/zero bs=1M count=300 status=none >&9 || true
rm -f -- "$target"
while :; do sleep 3600; done
HOLDER
    chmod 0755 "$holder"

    target="$mnt/var/log/app.log"
    nohup bash -c 'exec -a lab-appd /usr/bin/env bash "$0" "$1"' "$holder" "$target" \
        >/dev/null 2>&1 &
    pid=$!
    disown "$pid" 2>/dev/null || true

    info "scenario 2: waiting for the fake daemon (pid $pid) to fill and unlink its log"
    local i
    for i in $(seq 1 180); do
        [[ -e $target ]] || break
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    sleep 1

    save_state "$id" "IMG=$img" "DEV=$dev" "MNT=$mnt" "PID=$pid"

    title "SCENARIO 2 -- 'the disk is full but there are no files' (df vs du)"
    say "  Device      : $dev"
    say "  Mount point : $mnt   (mounted, and this is a production-style /var/log)"

    section "SYMPTOM -- this is what you get right now:"
    printf '    $ df -h %s\n' "$mnt"
    df -h "$mnt" | sed 's/^/    /'
    printf '\n    $ du -sh %s\n' "$mnt"
    du -sh "$mnt" | sed 's/^/    /'
    printf '\n    $ ls -lR %s/var/log\n' "$mnt"
    ls -lR "$mnt/var/log" | sed 's/^/    /'

    section "WHAT ACTUALLY HAPPENED (mechanics)"
    say "  du walks the directory tree and adds up what it can SEE. df asks the"
    say "  filesystem how many blocks are allocated. They disagree whenever blocks"
    say "  are allocated to an inode that no longer has any directory entry."
    say "  On Unix, unlink() only removes the name. The inode -- and every block it"
    say "  owns -- is freed when link count AND open descriptor count both reach"
    say "  zero. A daemon holding the fd of a deleted 300 MB log keeps those blocks"
    say "  pinned until it closes the descriptor, exits, or the fs is unmounted."

    section "YOUR MISSION"
    say "  Reclaim the space WITHOUT unmounting $mnt and WITHOUT rebooting."
    say "  Identify which process is pinning the blocks, which descriptor number it"
    say "  is using, and free the space. Bonus: free it while keeping the process"
    say "  alive (that is what you must do to a real database or web server)."
    say "  Then grade yourself:  $0 check 2"

    section "HINTS"
    say "  * lsof +L1              lists open files whose link count is below 1."
    say "  * lsof -nP $mnt | grep deleted   works too."
    say "  * No lsof installed? /proc/<pid>/fd is a directory of symlinks, and the"
    say "    kernel appends ' (deleted)' to the target of an unlinked file."
    say "  * Writing to /proc/<pid>/fd/<n> writes to the SAME open file description."
}

check_2() {
    local id=s2 used
    load_state "$id"
    mountpoint -q "$MNT" || { warn "scenario 2: $MNT is not mounted; the mission was to fix it online"; return 1; }
    used=$(df -B1 --output=used "$MNT" | tail -n1 | tr -d ' ')
    if (( used < 52428800 )); then
        info "scenario 2: PASS -- space reclaimed ($(numfmt --to=iec "$used" 2>/dev/null || echo "$used") in use, filesystem still mounted)"
        return 0
    fi
    warn "scenario 2: FAIL -- $(numfmt --to=iec "$used" 2>/dev/null || echo "$used") still allocated; the descriptor is still open"
    return 1
}

# --------------------------------------------------------------------------- #
# Scenario 3 -- ENOSPC with 95% of the blocks free (inode exhaustion)
# --------------------------------------------------------------------------- #

break_3() {
    local id=s3 dev mnt img i iavail
    mnt="$MNT_ROOT/$id"
    mkdir -p "$mnt"

    info "scenario 3: building a 128M ext4 filesystem with a deliberately small inode table"
    dev=$(new_image "$id" 128M)
    img="$LAB_ROOT/$id.img"
    assert_lab_loop "$dev"

    mkfs.ext4 -q -F -N 1024 -L LAB1042INO "$dev"
    mount "$dev" "$mnt"

    mkdir -p "$mnt/srv/data" "$mnt/var/spool/lab-mailq"
    for i in $(seq 1 8); do
        printf 'critical business record #%s\n' "$i" > "$mnt/srv/data/record-$i.txt"
    done
    ( cd "$mnt" && find srv -type f -print0 | xargs -0 sha256sum ) > "$STATE/$id.sha256"

    info "scenario 3: flooding the inode table with a stuck mail queue"
    i=0
    while :; do
        iavail=$(df -i --output=iavail "$mnt" | tail -n1 | tr -d ' ')
        (( iavail <= 2 )) && break
        (( i++ > 5000 )) && break
        : > "$mnt/var/spool/lab-mailq/qf$(printf '%05d' "$i").msg" 2>/dev/null || break
    done
    sync

    save_state "$id" "IMG=$img" "DEV=$dev" "MNT=$mnt"

    title "SCENARIO 3 -- 'No space left on device' on a 5%-full filesystem"
    say "  Device      : $dev"
    say "  Mount point : $mnt   (mounted)"

    section "SYMPTOM -- this is what you get right now:"
    show_failure touch "$mnt/srv/data/new-record.txt"
    printf '\n    $ df -h %s\n' "$mnt"
    df -h "$mnt" | sed 's/^/    /'

    section "WHAT ACTUALLY HAPPENED (mechanics)"
    say "  ext2/3/4 allocate the inode table statically at mkfs time. The number of"
    say "  inodes is fixed by -N (absolute count) or -i (bytes-per-inode) and it can"
    say "  never be raised afterwards on a filesystem of the same size: tune2fs has"
    say "  no knob for it. Every file, directory, symlink and device node consumes"
    say "  exactly one inode regardless of its size, so a runaway queue of zero-byte"
    say "  files exhausts the inode table long before it exhausts the data blocks."
    say "  The kernel then returns ENOSPC -- the same errno as a truly full disk,"
    say "  which is why 'df -h' sends people chasing the wrong problem."

    section "YOUR MISSION"
    say "  1. Prove with a command that blocks are NOT the problem."
    say "  2. Locate the directory responsible for the inode consumption."
    say "  3. Restore the ability to create files, WITHOUT destroying $mnt/srv/data."
    say "  4. Report the two mkfs options you would use to build this filesystem"
    say "     correctly for a mail spool workload."
    say "  Then grade yourself:  $0 check 3"

    section "HINTS"
    say "  * df -i   is the whole first half of the diagnosis."
    say "  * find <mnt> -xdev -printf '%h\\n' | sort | uniq -c | sort -rn | head"
    say "  * tune2fs -l <dev> | grep -i inode   shows the fixed inode count."
}

check_3() {
    local id=s3 iavail
    load_state "$id"
    mountpoint -q "$MNT" || { warn "scenario 3: $MNT is not mounted"; return 1; }
    iavail=$(df -i --output=iavail "$MNT" | tail -n1 | tr -d ' ')
    if (( iavail < 100 )); then
        warn "scenario 3: FAIL -- only $iavail free inodes; the queue is still there"
        return 1
    fi
    if ! ( cd "$MNT" && sha256sum -c "$STATE/$id.sha256" >/dev/null 2>&1 ); then
        warn "scenario 3: FAIL -- you freed inodes by deleting business data in srv/data"
        return 1
    fi
    info "scenario 3: PASS -- $iavail inodes free and every record in srv/data survived"
    return 0
}

# --------------------------------------------------------------------------- #
# Scenario 4 -- unattached inode: the file is gone, the blocks are not
# --------------------------------------------------------------------------- #

break_4() {
    local id=s4 dev mnt img ino hash
    mnt="$MNT_ROOT/$id"
    mkdir -p "$mnt"

    info "scenario 4: building a 256M ext4 filesystem"
    dev=$(new_image "$id" 256M)
    img="$LAB_ROOT/$id.img"
    assert_lab_loop "$dev"

    mkfs.ext4 -q -F -L LAB1042ORPH "$dev"
    mount "$dev" "$mnt"

    mkdir -p "$mnt/finance"
    {
        printf 'quarter,revenue,cogs\n'
        for q in Q1 Q2 Q3 Q4; do printf '%s,%s,%s\n' "$q" "$((RANDOM + 100000))" "$((RANDOM + 40000))"; done
    } > "$mnt/finance/report-2026.csv"
    dd if=/dev/urandom bs=1M count=6 status=none >> "$mnt/finance/report-2026.csv"

    ino=$(stat -c '%i' "$mnt/finance/report-2026.csv")
    hash=$(sha256sum "$mnt/finance/report-2026.csv" | awk '{print $1}')
    printf '%s  report-2026.csv\n' "$hash" > "$STATE/$id.sha256"
    sync
    umount "$mnt"

    info "scenario 4: removing the directory entry with debugfs, leaving the inode allocated"
    debugfs -w -R "unlink /finance/report-2026.csv" "$dev" >/dev/null 2>&1
    # Mark the filesystem as not cleanly unmounted so the next boot forces a check.
    tune2fs -C 40 -c 30 "$dev" >/dev/null 2>&1 || true
    sync

    mount "$dev" "$mnt"

    save_state "$id" "IMG=$img" "DEV=$dev" "MNT=$mnt" "INODE=$ino" "SHA=$hash"

    title "SCENARIO 4 -- the vanished quarterly report (unattached inode)"
    say "  Device      : $dev"
    say "  Mount point : $mnt   (mounted)"

    section "SYMPTOM -- this is what you get right now:"
    printf '    $ ls -la %s/finance\n' "$mnt"
    ls -la "$mnt/finance" | sed 's/^/    /'
    printf '\n    $ du -sh %s   (the tree is empty...)\n' "$mnt"
    du -sh "$mnt" | sed 's/^/    /'
    printf '\n    $ df -h %s   (...but the blocks are still allocated)\n' "$mnt"
    df -h "$mnt" | sed 's/^/    /'

    section "WHAT ACTUALLY HAPPENED (mechanics)"
    say "  A directory is just a file containing (name -> inode number) records."
    say "  The record for report-2026.csv was removed without decrementing the"
    say "  inode's link count and without freeing its blocks. The inode is still"
    say "  marked in use in the inode bitmap, its data blocks are still marked in"
    say "  use in the block bitmap, and its i_links_count is still 1 -- but no"
    say "  directory anywhere points at it. e2fsck calls this an 'unattached inode'."
    say "  This is exactly what a crash mid-rename or a bad block in a directory"
    say "  block produces, and it is why filesystem checks exist at all."

    section "YOUR MISSION"
    say "  Recover the file, byte for byte. Its SHA-256 is:"
    say "      $hash"
    say "  Two independent routes exist -- know both:"
    say "    (a) a read-only rescue with debugfs, without repairing anything;"
    say "    (b) a real repair with e2fsck, which reconnects orphans to lost+found"
    say "        under their inode number."
    say "  Note the inode number BEFORE you repair: e2fsck names the recovered file"
    say "  after it. Finding it is part of the exercise."
    say "  Then grade yourself:  $0 check 4"

    section "HINTS"
    say "  * NEVER run e2fsck on a mounted read-write filesystem. Unmount first."
    say "  * fsck -n <dev>  and  e2fsck -fn <dev>  are read-only dry runs."
    say "  * debugfs -R 'ncheck <ino>' <dev>   maps an inode back to a path."
    say "  * debugfs -R 'dump <NN> /tmp/out' <dev>   extracts an inode's data."
    say "  * tune2fs -l <dev> | grep -iE 'mount count|state|check'  explains why"
    say "    this filesystem would also be force-checked at the next boot."

    section "SIDE QUEST (same objective, no extra breakage needed)"
    say "  Read the current values of 'Maximum mount count' and 'Check interval',"
    say "  then set a sane policy with tune2fs -c and -i, and explain in one"
    say "  sentence why servers with 40 TB of ext4 usually set -c 0 -i 0."
}

check_4() {
    local id=s4 found=""
    load_state "$id"
    mountpoint -q "$MNT" || { warn "scenario 4: mount $DEV at $MNT so I can grade it"; return 1; }
    found=$(find "$MNT" -xdev -type f -size +5M -exec sha256sum {} + 2>/dev/null \
            | awk -v h="$SHA" '$1 == h {print $2; exit}')
    if [[ -n $found ]]; then
        info "scenario 4: PASS -- content recovered at $found (sha256 matches)"
        return 0
    fi
    if [[ -f /tmp/report-2026.csv ]] && sha256sum /tmp/report-2026.csv | grep -q "$SHA"; then
        info "scenario 4: PASS -- recovered out-of-band to /tmp/report-2026.csv (sha256 matches)"
        return 0
    fi
    warn "scenario 4: FAIL -- no file with sha256 $SHA on $MNT (check lost+found)"
    return 1
}

# --------------------------------------------------------------------------- #
# Scenario 5 -- XFS primary superblock destroyed
# --------------------------------------------------------------------------- #

break_5() {
    local id=s5 dev mnt img
    if ! command -v mkfs.xfs >/dev/null 2>&1 || ! command -v xfs_repair >/dev/null 2>&1; then
        warn "scenario 5 skipped: xfsprogs is not installed (dnf install xfsprogs / apt install xfsprogs)"
        return 0
    fi
    mnt="$MNT_ROOT/$id"
    mkdir -p "$mnt"

    info "scenario 5: building a 600M XFS filesystem"
    dev=$(new_image "$id" 600M)
    img="$LAB_ROOT/$id.img"
    assert_lab_loop "$dev"

    mkfs.xfs -q -f -L LAB1042XFS "$dev"
    mount "$dev" "$mnt"
    mkdir -p "$mnt/var/lib/containers" "$mnt/srv"
    dd if=/dev/urandom of="$mnt/var/lib/containers/layer.tar" bs=1M count=40 status=none
    printf 'xfs payload must survive xfs_repair\n' > "$mnt/srv/marker.txt"
    ( cd "$mnt" && find var srv -type f -print0 | xargs -0 sha256sum ) > "$STATE/$id.sha256"
    sync
    umount "$mnt"

    info "scenario 5: overwriting sector 0 (primary superblock of AG 0)"
    dd if=/dev/urandom of="$dev" bs=512 count=1 conv=notrunc status=none
    sync
    blockdev --flushbufs "$dev" 2>/dev/null || true

    save_state "$id" "IMG=$img" "DEV=$dev" "MNT=$mnt"

    title "SCENARIO 5 -- XFS with a shredded primary superblock"
    say "  Device      : $dev"
    say "  Mount point : $mnt   (currently NOT mounted)"

    section "SYMPTOM -- this is what you get right now:"
    show_failure mount "$dev" "$mnt"
    say ""
    say "    ...and dmesg shows:"
    say "    XFS (loop4): Invalid superblock magic number"
    say ""
    show_failure xfs_info "$dev"

    section "WHAT ACTUALLY HAPPENED (mechanics)"
    say "  XFS divides the volume into allocation groups (AGs). Each AG carries its"
    say "  own superblock at its first sector; AG 0's copy at sector 0 is the primary"
    say "  and the only one the mount path reads. Sector 0 is now random bytes, so"
    say "  the magic number 'XFSB' is gone and the kernel refuses the mount."
    say "  The AG 1..N copies are intact, and xfs_repair knows how to scan for them."
    say "  Note the tooling difference from ext4: there is no fsck.xfs that repairs"
    say "  anything (it is a no-op that always exits 0, on purpose). Repair is"
    say "  xfs_repair, it only works on an UNMOUNTED filesystem, and it needs RAM"
    say "  proportional to the number of inodes."

    section "YOUR MISSION"
    say "  1. Run a READ-ONLY assessment first and read what it says about the"
    say "     secondary superblock search."
    say "  2. Repair the filesystem, mount it at $mnt, and verify:"
    say "       cd $mnt && sha256sum -c $STATE/$id.sha256"
    say "  3. Explain when 'xfs_repair -L' is legitimate and what it costs you."
    say "  Then grade yourself:  $0 check 5"

    section "HINTS"
    say "  * xfs_repair -n <dev>   dry run, modifies nothing."
    say "  * xfs_db -r -c 'sb 1' -c 'print' <dev>   reads AG 1's superblock copy."
    say "  * -L zeroes the dirty log. It is data loss, not a repair; it is the last"
    say "    resort for a log that cannot be replayed, never a first move."
}

check_5() {
    local id=s5
    [[ -f $STATE/$id.env ]] || { warn "scenario 5 was never built (xfsprogs missing?)"; return 0; }
    load_state "$id"
    mountpoint -q "$MNT" || { warn "scenario 5: $MNT is not mounted"; return 1; }
    if ( cd "$MNT" && sha256sum -c "$STATE/$id.sha256" >/dev/null 2>&1 ); then
        info "scenario 5: PASS -- XFS repaired, mounted, checksums match"
        return 0
    fi
    warn "scenario 5: FAIL -- mounted, but the payload does not match the manifest"
    return 1
}

# --------------------------------------------------------------------------- #
# Subcommands
# --------------------------------------------------------------------------- #

cmd_list() {
    title "LPIC-1 104.2 -- break & fix scenarios"
    say "  1  ext4 primary superblock + group descriptors wiped   -> mke2fs -n, e2fsck -b"
    say "  2  df full / du empty, deleted file held open          -> lsof +L1, /proc/<pid>/fd"
    say "  3  ENOSPC with free blocks (inode exhaustion)          -> df -i, tune2fs -l, mkfs -N/-i"
    say "  4  unattached inode after a lost directory entry       -> e2fsck, lost+found, debugfs"
    say "  5  XFS primary superblock destroyed                    -> xfs_repair (-n first), xfs_db"
    say ""
    say "  break <n|all> | check <n|all> | status | solution | cleanup"
}

cmd_break() {
    local which=${1:-}
    [[ -n $which ]] || die "usage: $0 break <1..5|all>"
    preflight
    confirm_destructive
    case "$which" in
        1) break_1 ;;
        2) break_2 ;;
        3) break_3 ;;
        4) break_4 ;;
        5) break_5 ;;
        all) break_1; break_2; break_3; break_4; break_5 ;;
        *) die "unknown scenario '$which'" ;;
    esac
    printf '\n'
    info "when you are done:  $0 check $which     and then:  $0 cleanup"
}

cmd_check() {
    local which=${1:-all} rc=0
    case "$which" in
        1) check_1 || rc=1 ;;
        2) check_2 || rc=1 ;;
        3) check_3 || rc=1 ;;
        4) check_4 || rc=1 ;;
        5) check_5 || rc=1 ;;
        all) check_1 || rc=1; check_2 || rc=1; check_3 || rc=1; check_4 || rc=1; check_5 || rc=1 ;;
        *) die "unknown scenario '$which'" ;;
    esac
    return "$rc"
}

cmd_status() {
    title "lab status"
    local f
    for f in "$STATE"/*.env; do
        [[ -e $f ]] || { say "  no scenario has been built yet"; return 0; }
        ( # shellcheck disable=SC1090
          . "$f"
          printf '  %-4s dev=%-12s mounted=%-3s img=%s\n' \
                 "$(basename "$f" .env)" "$DEV" \
                 "$(mountpoint -q "$MNT" && echo yes || echo no)" "$IMG" )
    done
    say ""
    losetup -a | grep -F "$LAB_ROOT" | sed 's/^/  /' || true
}

cmd_cleanup() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
    local f
    for f in "$STATE"/*.env; do
        [[ -e $f ]] || continue
        ( # shellcheck disable=SC1090
          . "$f"
          if [[ -n ${PID:-} ]] && kill -0 "$PID" 2>/dev/null; then
              info "killing helper process $PID"
              kill -TERM "$PID" 2>/dev/null || true
              sleep 1
              kill -KILL "$PID" 2>/dev/null || true
          fi
          if mountpoint -q "$MNT"; then
              umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
          fi
          if [[ -b ${DEV:-} ]]; then
              assert_lab_loop "$DEV"
              losetup -d "$DEV" 2>/dev/null || true
          fi )
    done
    # Anything still attached from this lab directory.
    losetup -a 2>/dev/null | awk -F: -v root="$LAB_ROOT" 'index($0, root) {print $1}' \
        | while read -r d; do losetup -d "$d" 2>/dev/null || true; done
    rm -rf "$LAB_ROOT"
    info "lab removed: $LAB_ROOT"
}

cmd_solution() {
    sed -n '/^# =\{2,\} SOLUTION/,$p' "$0" | sed 's/^#\{1,\} \{0,1\}//'
}

main() {
    local cmd=${1:-list}
    shift || true
    case "$cmd" in
        list)      cmd_list ;;
        break)     cmd_break "${1:-}" ;;
        check)     cmd_check "${1:-all}" ;;
        status)    preflight; cmd_status ;;
        solution)  cmd_solution ;;
        cleanup)   cmd_cleanup ;;
        -h|--help|help) cmd_list ;;
        *) die "unknown command '$cmd' (try: $0 list)" ;;
    esac
}

main "$@"

# ============================================================================ #
