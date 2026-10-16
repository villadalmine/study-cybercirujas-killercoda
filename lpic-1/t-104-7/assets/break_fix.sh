#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-1 (exams 101-500 / 102-500, version 5.0)
#  Topic 104.7 - Find system files and place files in the correct location
#  Exam weight: 3.12
#
#  BREAK & FIX LAB - RUN ONLY ON A DISPOSABLE LABORATORY VM.
#
#  This script deliberately breaks a small, well-scoped set of things that map
#  one-to-one onto the 104.7 objective: the FHS, and the tools used to locate
#  files (find, locate/updatedb, whereis, which, type, command -v).
#
#  Reference material used to build this lab:
#    - LPI exam 101 objectives .... https://www.lpi.org/our-certifications/exam-101-objectives/
#    - FHS 3.0 (authoritative) ..... https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html
#    - find(1), locate(1), updatedb(1), updatedb.conf(5), whereis(1), which(1)
#
#  Usage:
#    sudo ./104.7-break-and-fix.sh break     # break the system + print the briefing
#    sudo ./104.7-break-and-fix.sh brief     # print the briefing again
#    sudo ./104.7-break-and-fix.sh verify    # grade your repair
#    sudo ./104.7-break-and-fix.sh restore   # instructor escape hatch (undo everything)
#
#  Non-interactive: export LPIC_LAB_CONFIRM=yes  (or pass --yes)
#  Bare metal is refused on purpose: pass --force-baremetal if you really mean it.
# =============================================================================

set -euo pipefail

LAB_ID="lpic-104.7"
LAB_DIR="/var/tmp/${LAB_ID}-lab"
BACKUP_DIR="${LAB_DIR}/backup"
STATE_FILE="${LAB_DIR}/lab.state"

PKG_ROOT="/opt/hostinv-1.4/pkg"                    # where a sloppy vendor tarball was unpacked
DECOY_DIR="/srv/pkgcache/hostinv-0.9"              # an older build left behind by someone else
ROGUE_FIND="/usr/local/bin/find"                   # shadows /usr/bin/find via PATH order
STRAY_CONF="/usr/bin/hostinv.conf"                 # config file dumped into a binary directory
STRAY_STATE="/etc/hostinv-state.db"                # variable state dumped into /etc

FHS_BIN="/usr/local/bin/hostinv"                   # FHS 4.x  - local binaries
FHS_CONF_DIR="/etc/hostinv"                        # FHS 3.7  - host-specific configuration
FHS_CONF="${FHS_CONF_DIR}/hostinv.conf"
FHS_STATE_DIR="/var/lib/hostinv"                   # FHS 5.8  - variable state information
FHS_STATE="${FHS_STATE_DIR}/state.db"
FHS_LOG_DIR="/var/log/hostinv"                     # FHS 5.10 - log files
FHS_MAN_DIR="/usr/local/share/man/man8"            # FHS 4.11 - local man pages

ASSUME_YES=0
FORCE_BAREMETAL=0

if [ -t 1 ]; then
    C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'; C_HDR=$'\033[1;36m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_BAD=""; C_WARN=""; C_HDR=""; C_OFF=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '[*] %s\n' "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_BAD" "$C_OFF" "$*" >&2; exit 1; }
hdr()  { printf '\n%s== %s ==%s\n' "$C_HDR" "$*" "$C_OFF"; }

trap 'printf "%s[x]%s aborted at line %s\n" "$C_BAD" "$C_OFF" "$LINENO" >&2' ERR

# -----------------------------------------------------------------------------
# Guard rails. A break & fix lab that runs on the wrong machine is not a lab.
# -----------------------------------------------------------------------------
preflight() {
    [ "$(id -u)" -eq 0 ] || die "run this as root (sudo)."

    local virt="none"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt="$(systemd-detect-virt 2>/dev/null || echo none)"
    fi
    if [ "$virt" = "none" ] && [ "$FORCE_BAREMETAL" -ne 1 ]; then
        die "this looks like bare metal (systemd-detect-virt: none). Use a throwaway VM or container, or pass --force-baremetal."
    fi

    # Immutable /usr images (ostree, Silverblue, some appliances) cannot host this lab.
    for d in /usr/bin /usr/local/bin /etc /var/lib; do
        [ -w "$d" ] || die "$d is not writable (read-only /usr image?). This lab needs a mutable filesystem."
    done

    command -v install >/dev/null 2>&1 || die "coreutils 'install' is required."
}

confirm() {
    [ "${LPIC_LAB_CONFIRM:-}" = "yes" ] && return 0
    [ "$ASSUME_YES" -eq 1 ] && return 0
    if [ ! -t 0 ]; then
        die "refusing to break a system non-interactively without --yes or LPIC_LAB_CONFIRM=yes."
    fi
    say ""
    warn "This will modify /usr/local/bin, /usr/bin, /etc, /var and the locate database on $(hostname)."
    printf 'Type BREAK to continue: '
    local ans; read -r ans
    [ "$ans" = "BREAK" ] || die "aborted by operator."
}

# locate/updatedb come as mlocate or plocate depending on the distribution.
LOCATE_BIN=""
UPDATEDB_BIN=""
detect_locate_stack() {
    if command -v locate >/dev/null 2>&1; then
        LOCATE_BIN="$(command -v locate)"
    elif command -v plocate >/dev/null 2>&1; then
        LOCATE_BIN="$(command -v plocate)"
    fi
    if command -v updatedb >/dev/null 2>&1; then
        UPDATEDB_BIN="$(command -v updatedb)"
    elif [ -x /usr/sbin/updatedb ]; then
        UPDATEDB_BIN=/usr/sbin/updatedb
    fi
}

backup_file() {
    # backup_file <path> ; keeps the absolute path inside the backup tree
    local src="$1" dst="${BACKUP_DIR}$1"
    [ -e "$src" ] || return 0
    [ -e "$dst" ] && return 0
    install -d -m 0700 "$(dirname "$dst")"
    cp -a "$src" "$dst"
}

# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------
write_hostinv_binary() {
    local target="$1" version="$2"
    install -d -m 0755 "$(dirname "$target")"
    cat > "$target" <<'HOSTINV_EOF'
#!/bin/sh
# hostinv - minimal host inventory reporter (LPIC-1 104.7 lab artifact)
# It hardcodes FHS-correct locations on purpose: the program is right,
# the file placement done by the packager is wrong.
CONF=/etc/hostinv/hostinv.conf
STATE=/var/lib/hostinv/state.db
LOGDIR=/var/log/hostinv
VERSION="__VERSION__"

case "${1:-}" in
    -V|--version) echo "hostinv ${VERSION}"; exit 0 ;;
    -h|--help)    echo "usage: hostinv [-V|--version]"; exit 0 ;;
esac

rc=0
[ -r "$CONF" ]      || { echo "hostinv: cannot read configuration: $CONF" >&2; rc=1; }
[ -s "$STATE" ]     || { echo "hostinv: state database missing or empty: $STATE" >&2; rc=1; }
[ -d "$LOGDIR" ]    || { echo "hostinv: log directory missing: $LOGDIR" >&2; rc=1; }
[ "$rc" -eq 0 ]     || { echo "hostinv: FHS layout incomplete, refusing to run" >&2; exit 1; }

# shellcheck disable=SC1090
. "$CONF"
entries=$(wc -l < "$STATE" | tr -d ' ')
printf '%s hostinv %s run by %s\n' "$(date -Is)" "$VERSION" "$(id -un)" >> "$LOGDIR/hostinv.log"
echo "hostinv: OK (version=${VERSION} profile=${INVENTORY_PROFILE:-unset} entries=${entries})"
HOSTINV_EOF
    sed -i "s/__VERSION__/${version}/" "$target"
}

write_manpage() {
    local target="$1"
    install -d -m 0755 "$(dirname "$target")"
    cat > "$target" <<'MAN_EOF'
.TH HOSTINV 8 "2026-08-26" "hostinv 1.4" "Lab utilities"
.SH NAME
hostinv \- minimal host inventory reporter (LPIC-1 104.7 lab artifact)
.SH SYNOPSIS
.B hostinv
.RI [ -V | --version ]
.SH DESCRIPTION
Reads its configuration from
.IR /etc/hostinv/hostinv.conf ,
its state from
.IR /var/lib/hostinv/state.db ,
and appends one line per run to
.IR /var/log/hostinv/hostinv.log .
Those three locations are fixed by the FHS and are not configurable.
.SH FILES
.TP
.I /etc/hostinv/hostinv.conf
Host-specific configuration (FHS 3.7).
.TP
.I /var/lib/hostinv/state.db
Variable state information (FHS 5.8).
.SH SEE ALSO
.BR find (1),
.BR locate (1),
.BR updatedb (1),
.BR updatedb.conf (5),
.BR whereis (1),
.BR hier (7)
MAN_EOF
    chmod 0644 "$target"
}

# -----------------------------------------------------------------------------
# BREAK
# -----------------------------------------------------------------------------
do_break() {
    preflight
    detect_locate_stack
    confirm

    install -d -m 0755 "$LAB_DIR"
    install -d -m 0700 "$BACKUP_DIR"

    hdr "Breaking things (fault 1/5): a tool that is not where it belongs"
    # The vendor tarball was extracted under /opt and never installed. The payload
    # is not executable and is not in any PATH directory.
    write_hostinv_binary "${PKG_ROOT}/usr/local/bin/hostinv" "1.4"
    chmod 0644 "${PKG_ROOT}/usr/local/bin/hostinv"
    write_manpage "${PKG_ROOT}/usr/local/share/man/man8/hostinv.8"
    install -d -m 0755 "${PKG_ROOT}/usr/share/doc/hostinv"
    printf 'hostinv 1.4 - unpacked, NOT installed. See man8/hostinv.8\n' \
        > "${PKG_ROOT}/usr/share/doc/hostinv/README"
    # A decoy: an older build someone left in a staging area.
    write_hostinv_binary "${DECOY_DIR}/hostinv" "0.9"
    chmod 0755 "${DECOY_DIR}/hostinv"
    touch -d '2019-03-04 11:12:13' "${DECOY_DIR}/hostinv"
    info "unpacked payload under ${PKG_ROOT} (mode 0644), decoy under ${DECOY_DIR}"

    hdr "Breaking things (fault 2/5): files placed in the wrong FHS directory"
    backup_file "$STRAY_CONF"
    backup_file "$STRAY_STATE"
    cat > "$STRAY_CONF" <<'CONF_EOF'
# hostinv configuration (LPIC-1 104.7 lab)
INVENTORY_PROFILE=lab-104-7
INVENTORY_SCOPE=host
CONF_EOF
    chmod 0644 "$STRAY_CONF"
    cat > "$STRAY_STATE" <<'STATE_EOF'
cpu:cores=4
mem:total=8192
disk:root=40G
net:iface=eth0
STATE_EOF
    chmod 0644 "$STRAY_STATE"
    rm -rf "$FHS_CONF_DIR" "$FHS_STATE_DIR" "$FHS_LOG_DIR" "$FHS_BIN" "${FHS_MAN_DIR}/hostinv.8"
    info "config landed in ${STRAY_CONF}, state landed in ${STRAY_STATE}"

    hdr "Breaking things (fault 3/5): a shadowed command"
    backup_file "$ROGUE_FIND"
    install -d -m 0755 /usr/local/bin
    cat > "$ROGUE_FIND" <<'ROGUE_EOF'
#!/bin/sh
# "compliance wrapper" dropped here by a rushed change window.
# It swallows every search and exits successfully. Nobody noticed.
exit 0
ROGUE_EOF
    chmod 0755 "$ROGUE_FIND"
    hash -r 2>/dev/null || true
    local resolved; resolved="$(command -v find || true)"
    if [ "$resolved" != "$ROGUE_FIND" ]; then
        warn "PATH order puts '$resolved' before ${ROGUE_FIND}; the student's shell may still see the real find."
    fi
    info "installed ${ROGUE_FIND} ahead of /usr/bin/find in PATH"

    hdr "Breaking things (fault 4/5): the locate database lies"
    if [ -n "$UPDATEDB_BIN" ]; then
        backup_file /etc/updatedb.conf
        cat > /etc/updatedb.conf <<'UDB_EOF'
# /etc/updatedb.conf - EDITED DURING AN INCIDENT, NEVER REVIEWED
PRUNE_BIND_MOUNTS="yes"
PRUNENAMES=".git .bzr .hg .svn"
PRUNEFS="NFS nfs nfs4 afs binfmt_misc proc smbfs autofs iso9660 ncpfs coda devpts ftpfs devfs mfs shfs sysfs cifs lustre tmpfs usbfs udf fuse.glusterfs fuse.sshfs curlftpfs ecryptfs fusesmb devtmpfs ext2 ext3 ext4 xfs btrfs"
PRUNEPATHS="/tmp /var/spool /media /var/lib/os-prober /var/lib/ceph /home /srv /opt /usr/local /etc"
UDB_EOF
        chmod 0644 /etc/updatedb.conf
        info "rewrote /etc/updatedb.conf, rebuilding the database with it (this can take a moment)"
        "$UPDATEDB_BIN" >/dev/null 2>&1 || warn "updatedb returned non-zero; the database may already be empty"
    else
        warn "no updatedb found: fault 4 skipped. Install mlocate or plocate to practise it."
    fi

    hdr "Breaking things (fault 5/5): documentation nobody can reach"
    rm -f "${FHS_MAN_DIR}/hostinv.8"
    info "man page exists only inside ${PKG_ROOT}"

    printf 'broken_at=%s\nhost=%s\n' "$(date -Is)" "$(hostname)" > "$STATE_FILE"
    print_brief
}

# -----------------------------------------------------------------------------
# BRIEFING
# -----------------------------------------------------------------------------
print_brief() {
    cat <<'BRIEF_EOF'

===============================================================================
 LPIC-1 104.7 - BREAK & FIX BRIEFING
===============================================================================

SCENARIO
  A change window went badly. A colleague "installed" the hostinv 1.4 utility by
  extracting a vendor tarball somewhere under /opt, and a hand-written
  postinstall scattered the rest of the package across the filesystem. During
  the same window somebody also touched /usr/local/bin and /etc/updatedb.conf.
  You inherit the machine. Nobody remembers the exact paths.

SYMPTOMS YOU WILL OBSERVE
  1. $ hostinv
     bash: hostinv: command not found
     The program exists on this disk. It is not in any PATH directory and it is
     not even executable.

  2. $ find / -name 'hostinv*' 2>/dev/null
     (prints nothing, exit status 0)
     Your search tool is lying to you. Trust nothing you have not resolved with
     `type -a`, `which -a` or `command -v`. This is the first fault to fix,
     because every other step depends on being able to search the filesystem.

  3. $ locate hostinv
     (nothing, or an error about a missing database)
     Even after you place files correctly, locate keeps missing them. The index
     is not the filesystem: it is a database, built by a program, driven by a
     configuration file.

  4. Once hostinv is runnable, it refuses to work:
     hostinv: cannot read configuration: /etc/hostinv/hostinv.conf
     hostinv: state database missing or empty: /var/lib/hostinv/state.db
     hostinv: log directory missing: /var/log/hostinv
     hostinv: FHS layout incomplete, refusing to run
     The files exist. They are in the wrong directories. The program hardcodes
     the FHS locations and will not be argued with.

  5. $ man hostinv
     No manual entry for hostinv
     $ whereis hostinv
     hostinv:

YOUR MISSION
  a. Restore a trustworthy `find`: `type -a find` must resolve to /usr/bin/find
     (or /bin/find) and searches must return results again.
  b. Put the hostinv 1.4 program where a locally installed binary belongs per
     the FHS, with executable permissions. Beware: there is more than one copy
     of hostinv on this disk and only version 1.4 is acceptable
     (`hostinv --version`). Distinguish them with find: -newer, -size, -perm,
     -mtime, -type, or by reading them.
  c. Move - do not copy - the configuration and the state database to their
     FHS-correct directories, and create the log directory. When you are done,
     no hostinv file may remain in a directory the FHS reserves for something
     else. `hostinv` must print a line starting with "hostinv: OK".
  d. Make `locate` useful again: repair /etc/updatedb.conf so that a normal
     system is indexed, then rebuild the database. `locate hostinv` must list
     both the installed binary and the installed configuration file.
  e. (extra credit) Install the man page so that `man hostinv` and
     `whereis hostinv` both find it.

TOOLS THIS OBJECTIVE EXPECTS YOU TO USE
  find, locate, updatedb, /etc/updatedb.conf, whereis, which, type
  and the FHS itself: /, /var, /etc, /usr, /usr/local, /opt, /srv, /bin, /sbin,
  /lib, plus hier(7).

USEFUL FIRST MOVES
  type -a find; which -a find; ls -l /usr/local/bin
  /usr/bin/find / -xdev -name 'hostinv*' -print 2>/dev/null
  /usr/bin/find /opt -type f ! -perm -u+x -ls
  man 5 updatedb.conf; man 7 hier

RULES
  - Do not edit the hostinv program. It is correct; the layout is not.
  - Everything you need is already on this machine. No network required.

WHEN YOU THINK YOU ARE DONE
  sudo /path/to/this-script.sh verify

===============================================================================
BRIEF_EOF
}

# -----------------------------------------------------------------------------
# VERIFY
# -----------------------------------------------------------------------------
PASS_N=0
FAIL_N=0
check() {
    # check <description> <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  %s[PASS]%s %s\n' "$C_OK" "$C_OFF" "$desc"
        PASS_N=$((PASS_N + 1))
    else
        printf '  %s[FAIL]%s %s\n' "$C_BAD" "$C_OFF" "$desc"
        FAIL_N=$((FAIL_N + 1))
    fi
}

find_is_sane() {
    local p; p="$(command -v find || true)"
    case "$p" in
        /usr/bin/find|/bin/find) : ;;
        *) return 1 ;;
    esac
    [ ! -e "$ROGUE_FIND" ] || return 1
    [ -n "$("$p" /etc -maxdepth 1 -name hosts -print 2>/dev/null)" ] || return 1
}

hostinv_installed() {
    local p; p="$(command -v hostinv || true)"
    [ "$p" = "$FHS_BIN" ] || return 1
    [ -x "$FHS_BIN" ] || return 1
    "$FHS_BIN" --version 2>/dev/null | grep -q '1\.4'
}

hostinv_runs() {
    "$FHS_BIN" 2>/dev/null | grep -q '^hostinv: OK'
}

fhs_layout_clean() {
    [ -f "$FHS_CONF" ] || return 1
    [ -s "$FHS_STATE" ] || return 1
    [ -d "$FHS_LOG_DIR" ] || return 1
    [ ! -e "$STRAY_CONF" ] || return 1
    [ ! -e "$STRAY_STATE" ] || return 1
}

locate_works() {
    [ -n "$LOCATE_BIN" ] || return 1
    local out
    out="$("$LOCATE_BIN" hostinv 2>/dev/null || true)"
    printf '%s\n' "$out" | grep -Fxq "$FHS_BIN" || return 1
    printf '%s\n' "$out" | grep -Fxq "$FHS_CONF" || return 1
}

manpage_installed() {
    command -v man >/dev/null 2>&1 || return 1
    man -w hostinv >/dev/null 2>&1
}

do_verify() {
    [ "$(id -u)" -eq 0 ] || die "run verify as root (sudo)."
    detect_locate_stack
    hash -r 2>/dev/null || true

    hdr "Grading LPIC-1 104.7"
    check "a. 'find' resolves to the real binary and returns results"      find_is_sane
    check "b. hostinv 1.4 is executable and first in PATH at ${FHS_BIN}"   hostinv_installed
    check "c. config, state and log directory follow the FHS"              fhs_layout_clean
    check "c. 'hostinv' runs and reports OK"                               hostinv_runs
    if [ -n "$LOCATE_BIN" ] && [ -n "$UPDATEDB_BIN" ]; then
        check "d. 'locate hostinv' lists the binary and the config"        locate_works
    else
        printf '  %s[SKIP]%s d. locate/updatedb are not installed on this host\n' "$C_WARN" "$C_OFF"
    fi
    if command -v man >/dev/null 2>&1; then
        check "e. (extra) 'man hostinv' finds the page"                    manpage_installed
    else
        printf '  %s[SKIP]%s e. man is not installed on this host\n' "$C_WARN" "$C_OFF"
    fi

    say ""
    if [ "$FAIL_N" -eq 0 ]; then
        printf '%sAll %d checks passed. Objective 104.7 repaired.%s\n' "$C_OK" "$PASS_N" "$C_OFF"
        say "Now explain out loud, without looking: why /usr/local/bin and not /usr/bin?"
        say "Why /var/lib and not /etc? What exactly does locate read, and when?"
        return 0
    fi
    printf '%s%d check(s) still failing, %d passed.%s\n' "$C_BAD" "$FAIL_N" "$PASS_N" "$C_OFF"
    say "Re-read the symptoms with 'brief'. The step-by-step solution is at the bottom of this script."
    return 1
}

# -----------------------------------------------------------------------------
# RESTORE (instructor escape hatch)
# -----------------------------------------------------------------------------
do_restore() {
    preflight
    detect_locate_stack
    hdr "Restoring the machine to its pre-lab state"

    rm -f "$ROGUE_FIND" "$STRAY_CONF" "$STRAY_STATE" "$FHS_BIN" "${FHS_MAN_DIR}/hostinv.8"
    rm -rf "$FHS_CONF_DIR" "$FHS_STATE_DIR" "$FHS_LOG_DIR" /opt/hostinv-1.4 "$DECOY_DIR"
    rmdir --ignore-fail-on-non-empty /srv/pkgcache 2>/dev/null || true

    if [ -f "${BACKUP_DIR}/etc/updatedb.conf" ]; then
        cp -a "${BACKUP_DIR}/etc/updatedb.conf" /etc/updatedb.conf
        info "restored /etc/updatedb.conf from backup"
    fi
    if [ -n "$UPDATEDB_BIN" ]; then
        "$UPDATEDB_BIN" >/dev/null 2>&1 || true
        info "rebuilt the locate database"
    fi
    if command -v mandb >/dev/null 2>&1; then
        mandb -q >/dev/null 2>&1 || true
    fi
    rm -f "$STATE_FILE"
    hash -r 2>/dev/null || true
    say "Restore complete. Backups kept under ${BACKUP_DIR}."
}

usage() {
    cat <<USAGE_EOF
usage: $0 {break|brief|verify|restore} [--yes] [--force-baremetal]

  break     break the system and print the student briefing
  brief     print the briefing again
  verify    grade the repair
  restore   undo everything (instructor only)
USAGE_EOF
}

MODE=""
for arg in "$@"; do
    case "$arg" in
        break|brief|verify|restore) MODE="$arg" ;;
        --yes|-y)                   ASSUME_YES=1 ;;
        --force-baremetal)          FORCE_BAREMETAL=1 ;;
        -h|--help)                  usage; exit 0 ;;
        *)                          usage; exit 2 ;;
    esac
done
[ -n "$MODE" ] || { usage; exit 2; }

case "$MODE" in
    break)   do_break ;;
    brief)   print_brief ;;
    verify)  do_verify ;;
    restore) do_restore ;;
esac
