#!/usr/bin/env bash
#
# ============================================================================
#  LPIC-1 (exams 101-500 / 102-500, version 5.0)
#  Topic 108.1 - Maintain system time
#  Break & Fix lab exercise
# ============================================================================
#
#  WHAT THIS IS
#    A controlled sabotage script. It injects four related, realistic faults
#    into the time subsystem of a DISPOSABLE lab VM, tells the student which
#    symptoms to expect and what the success criteria are, and then gets out
#    of the way. The step-by-step solution is at the bottom of this file, in
#    comments - do not read it until you have tried.
#
#  MODES
#    sudo ./108.1-break-fix.sh            break the box (default)
#    sudo ./108.1-break-fix.sh --verify   grade your repair, non-destructive
#    sudo ./108.1-break-fix.sh --restore  emergency escape hatch (undo all)
#    sudo ./108.1-break-fix.sh --help
#
#  SAFETY MODEL
#    - refuses to run as non-root
#    - refuses to run inside a container: the kernel clock is shared with the
#      host unless a time namespace is in use, so skewing it would move the
#      host clock, not the lab's
#    - refuses to run on bare metal unless ALLOW_BARE_METAL=yes is exported
#    - every file it touches is copied to /var/tmp/lpic1-1081-breakfix first
#    - --restore puts the machine back, including the RTC
#
#  REFERENCES (official)
#    LPI 101 objectives .... https://www.lpi.org/our-certifications/exam-101-objectives/
#    LPI 102 objectives .... https://www.lpi.org/our-certifications/exam-102-objectives/
#    timedatectl(1) ........ https://www.freedesktop.org/software/systemd/man/timedatectl.html
#    systemd-timesyncd(8) .. https://www.freedesktop.org/software/systemd/man/systemd-timesyncd.service.html
#    hwclock(8) ............ https://man7.org/linux/man-pages/man8/hwclock.8.html
#    date(1) ............... https://man7.org/linux/man-pages/man1/date.1.html
#    chrony documentation .. https://chrony-project.org/documentation.html
#    chrony.conf(5) ........ https://chrony-project.org/doc/4.5/chrony.conf.html
#    ntp.conf(5) ........... https://docs.ntpsec.org/latest/ntp_conf.html
#    tzdata / zoneinfo ..... https://www.iana.org/time-zones
#
# ----------------------------------------------------------------------------

set -uo pipefail

STATE_DIR="/var/tmp/lpic1-1081-breakfix"
STATE_FILE="${STATE_DIR}/state.env"
BACKUP_DIR="${STATE_DIR}/backup"
BROKEN_TZ="Pacific/Kiritimati"          # UTC+14, impossible to confuse with anything sane
BOGUS_NTP_1="192.0.2.10"                # TEST-NET-1 (RFC 5737): guaranteed unroutable
BOGUS_NTP_2="192.0.2.11"
SKEW_SPEC="27 hours 17 minutes 42 seconds"   # far enough to break repo metadata and Kerberos

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
    C_BLU=$'\033[1;34m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_OFF=""
fi

log()    { printf '%s[*]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()     { printf '%s[+]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn()   { printf '%s[!]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
fail()   { printf '%s[-]%s %s\n' "$C_RED" "$C_OFF" "$*"; }
die()    { fail "$*"; exit 1; }
banner() { printf '\n%s%s%s\n' "$C_BLU" "$(printf '=%.0s' {1..76})" "$C_OFF"; printf ' %s\n' "$*"; printf '%s%s%s\n' "$C_BLU" "$(printf '=%.0s' {1..76})" "$C_OFF"; }

# ---------------------------------------------------------------------------
# guards
# ---------------------------------------------------------------------------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "run me as root (sudo $0 $*)"
}

require_disposable_host() {
    local virt="unknown"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        if systemd-detect-virt --container --quiet; then
            die "container detected ($(systemd-detect-virt)). The clock is the host's. Use a VM."
        fi
        virt="$(systemd-detect-virt || true)"
        if [ "$virt" = "none" ] && [ "${ALLOW_BARE_METAL:-no}" != "yes" ]; then
            die "bare metal detected. This is almost certainly your workstation. Export ALLOW_BARE_METAL=yes only if this machine is truly disposable."
        fi
    else
        warn "systemd-detect-virt not found; cannot confirm this is a VM"
    fi
    log "virtualization: ${virt}"
}

require_consent() {
    local phrase="BREAK MY LAB VM"
    if [ "${LPIC_LAB_CONFIRM:-}" = "yes" ]; then
        log "consent supplied via LPIC_LAB_CONFIRM=yes"
        return 0
    fi
    [ -t 0 ] || die "non-interactive run without LPIC_LAB_CONFIRM=yes; refusing"
    cat <<EOF

${C_YEL}This script will deliberately corrupt the time configuration of THIS machine:
system clock, RTC, timezone and the NTP client. Do not run it on anything you
care about. Snapshot the VM first if your hypervisor supports it.${C_OFF}

Type exactly:  ${phrase}
EOF
    local answer
    read -r -p "> " answer
    [ "$answer" = "$phrase" ] || die "consent not given; nothing was changed"
}

# ---------------------------------------------------------------------------
# discovery
# ---------------------------------------------------------------------------
detect_time_unit() {
    local candidates=(chronyd.service chrony.service systemd-timesyncd.service ntpd.service ntpsec.service ntp.service)
    local u
    # prefer whatever is actually running
    for u in "${candidates[@]}"; do
        systemctl is-active --quiet "$u" 2>/dev/null && { echo "$u"; return 0; }
    done
    # otherwise whatever is installed
    for u in "${candidates[@]}"; do
        if systemctl list-unit-files "$u" --no-legend 2>/dev/null | grep -q .; then
            echo "$u"; return 0
        fi
    done
    echo ""
}

detect_time_config() {
    # $1 = unit name -> prints the primary config file, or "" if none applies
    case "$1" in
        chrony*)
            for f in /etc/chrony/chrony.conf /etc/chrony.conf; do
                [ -f "$f" ] && { echo "$f"; return 0; }
            done ;;
        systemd-timesyncd*)
            echo "/etc/systemd/timesyncd.conf" ;;
        ntp*)
            for f in /etc/ntpsec/ntp.conf /etc/ntp.conf; do
                [ -f "$f" ] && { echo "$f"; return 0; }
            done ;;
    esac
    echo ""
}

have_rtc() { [ -e /dev/rtc0 ] || [ -e /dev/rtc ]; }

# ---------------------------------------------------------------------------
# backup / state
# ---------------------------------------------------------------------------
backup_file() {
    local src="$1"
    [ -e "$src" ] || [ -L "$src" ] || return 0
    local dst="${BACKUP_DIR}${src}"
    mkdir -p "$(dirname "$dst")"
    cp -a --no-dereference "$src" "$dst"
    log "backed up ${src}"
}

save_state() {
    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
# generated by $0 - do not edit
ORIG_TZ='${ORIG_TZ}'
ORIG_LOCAL_RTC='${ORIG_LOCAL_RTC}'
ORIG_NTP='${ORIG_NTP}'
TIME_UNIT='${TIME_UNIT}'
TIME_CONF='${TIME_CONF}'
UNIT_WAS_ENABLED='${UNIT_WAS_ENABLED}'
BROKEN_AT_UTC='${BROKEN_AT_UTC}'
EOF
    chmod 0600 "$STATE_FILE"
}

load_state() {
    [ -f "$STATE_FILE" ] || die "no lab state found at ${STATE_FILE} - was this machine ever broken by this script?"
    # shellcheck disable=SC1090
    . "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# the four faults
# ---------------------------------------------------------------------------
fault_1_disable_and_mask_ntp() {
    banner "fault 1/4 - the NTP client is stopped and masked"
    timedatectl set-ntp false >/dev/null 2>&1 || true
    if [ -n "$TIME_UNIT" ]; then
        systemctl stop "$TIME_UNIT"  >/dev/null 2>&1 || true
        systemctl disable "$TIME_UNIT" >/dev/null 2>&1 || true
        systemctl mask "$TIME_UNIT"  >/dev/null 2>&1 || true
        ok "${TIME_UNIT}: stopped, disabled, masked"
    else
        warn "no NTP implementation installed - the student will have to install one"
    fi
}

fault_2_poison_ntp_servers() {
    banner "fault 2/4 - the NTP client points at unreachable servers"
    case "$TIME_UNIT" in
        chrony*)
            [ -n "$TIME_CONF" ] || { warn "no chrony.conf found; skipping"; return 0; }
            backup_file "$TIME_CONF"
            sed -i -E 's/^[[:space:]]*(server|pool|peer)[[:space:]]/#LAB-DISABLED \1 /' "$TIME_CONF"
            printf '\n# LAB-INJECTED (108.1 break-and-fix)\nserver %s iburst\nserver %s iburst\n' \
                   "$BOGUS_NTP_1" "$BOGUS_NTP_2" >> "$TIME_CONF"
            ok "${TIME_CONF}: real sources commented out, TEST-NET-1 servers injected"
            ;;
        systemd-timesyncd*)
            backup_file /etc/systemd/timesyncd.conf
            mkdir -p /etc/systemd/timesyncd.conf.d
            backup_file /etc/systemd/timesyncd.conf.d
            cat > /etc/systemd/timesyncd.conf.d/99-lab-break.conf <<EOF
# LAB-INJECTED (108.1 break-and-fix) - delete this file to repair
[Time]
NTP=${BOGUS_NTP_1} ${BOGUS_NTP_2}
FallbackNTP=${BOGUS_NTP_1}
EOF
            ok "/etc/systemd/timesyncd.conf.d/99-lab-break.conf written (drop-in beats the main file)"
            ;;
        ntp*)
            [ -n "$TIME_CONF" ] || { warn "no ntp.conf found; skipping"; return 0; }
            backup_file "$TIME_CONF"
            sed -i -E 's/^[[:space:]]*(server|pool|peer)[[:space:]]/#LAB-DISABLED \1 /' "$TIME_CONF"
            printf '\n# LAB-INJECTED (108.1 break-and-fix)\nserver %s iburst\n' "$BOGUS_NTP_1" >> "$TIME_CONF"
            ok "${TIME_CONF}: real sources commented out, TEST-NET-1 server injected"
            ;;
        *)
            warn "no known NTP config to poison"
            ;;
    esac
}

fault_3_skew_clock_and_rtc() {
    banner "fault 3/4 - the system clock is skewed and the RTC is set to local time"
    backup_file /etc/adjtime

    # RTC interpreted as local time: the classic dual-boot misconfiguration.
    if timedatectl set-local-rtc 1 >/dev/null 2>&1; then
        ok "RTC now declared to be in local time (/etc/adjtime -> LOCAL)"
    else
        warn "timedatectl set-local-rtc failed; writing /etc/adjtime by hand"
        printf '0.0 0 0.0\n0\nLOCAL\n' > /etc/adjtime
    fi

    local target
    target="$(date -d "now + ${SKEW_SPEC}" '+%Y-%m-%d %H:%M:%S')"
    if timedatectl set-time "$target" >/dev/null 2>&1; then
        ok "system clock pushed forward by ${SKEW_SPEC} -> $(date)"
    elif date -s "$target" >/dev/null 2>&1; then
        ok "system clock pushed forward with date -s -> $(date)"
    else
        warn "could not set the system clock (CAP_SYS_TIME denied?)"
    fi

    if have_rtc; then
        hwclock --systohc >/dev/null 2>&1 && ok "wrong time written to the RTC (survives a reboot)" \
            || warn "hwclock --systohc failed"
    else
        warn "no /dev/rtc device; the skew will not survive a reboot on this VM"
    fi
}

fault_4_break_timezone() {
    banner "fault 4/4 - the timezone is wrong AND structurally broken"
    backup_file /etc/localtime
    backup_file /etc/timezone

    local zonefile="/usr/share/zoneinfo/${BROKEN_TZ}"
    if [ -f "$zonefile" ]; then
        rm -f /etc/localtime
        # deliberately a COPY, not a symlink: timedatectl can no longer name the zone
        cp "$zonefile" /etc/localtime
        ok "/etc/localtime replaced by a plain copy of ${BROKEN_TZ} (UTC+14)"
    else
        warn "${zonefile} missing (tzdata not installed?); skipping the copy"
    fi

    if [ -f /etc/timezone ]; then
        echo "Europe/Lisbon" > /etc/timezone     # lies, and disagrees with /etc/localtime
        ok "/etc/timezone now claims Europe/Lisbon - inconsistent on purpose"
    fi
}

# ---------------------------------------------------------------------------
# briefing
# ---------------------------------------------------------------------------
print_briefing() {
    cat <<EOF

$(banner "MISSION BRIEFING - topic 108.1, maintain system time")

${C_YEL}THE STORY${C_OFF}
  This VM came back from a technician who "fixed the clock by hand". Since
  then Ansible runs fail, the monitoring agent is flagged as reporting from
  the future, and nobody can log in with Kerberos.

${C_YEL}SYMPTOMS YOU WILL SEE${C_OFF}
  1. ${C_DIM}date${C_OFF} and ${C_DIM}timedatectl${C_OFF} disagree with reality by more than a day, and the
     UTC offset is absurd (+14).
  2. ${C_DIM}timedatectl${C_OFF} reports:
         Time zone: n/a (n/a, +1400)
         System clock synchronized: no
         NTP service: inactive
         RTC in local TZ: yes
     plus a loud warning about the RTC not being in UTC.
  3. On Debian/Ubuntu ${C_DIM}apt update${C_OFF} fails with "Release file ... is not valid
     yet"; on RHEL family ${C_DIM}dnf${C_OFF} complains about repomd/GPG timestamps. HTTPS
     to some sites fails with "certificate is not yet valid".
  4. ${C_DIM}systemctl start${C_OFF} on the time daemon returns
         Failed to start ...: Unit ... is masked.
     and ${C_DIM}timedatectl set-ntp true${C_OFF} fails for the same reason.
  5. Even once it starts, the client never synchronizes: its only sources are
     unreachable (${C_DIM}chronyc sources${C_OFF} shows all '?', or timesync-status shows
     no server).
  6. Every file written from now until you fix this carries a future mtime.
  7. If you reboot before repairing, the clock jumps again - the RTC is now
     both wrong and declared to be in local time.

${C_YEL}YOUR OBJECTIVE${C_OFF}
  Return the machine to a correct, self-maintaining state. Success means ALL
  of the following are true:
    [ ] /etc/localtime is a symlink into /usr/share/zoneinfo, and the zone is
        ${ORIG_TZ} again (and /etc/timezone agrees, where that file exists)
    [ ] the RTC is interpreted as UTC ("RTC in local TZ: no")
    [ ] the time daemon is unmasked, enabled and active
    [ ] its configuration points at real, reachable NTP sources - no TEST-NET
        addresses left behind
    [ ] timedatectl says "System clock synchronized: yes" and "NTP service: active"
    [ ] the hardware clock matches the system clock (within a couple of seconds)

${C_YEL}RULES OF ENGAGEMENT${C_OFF}
  - No reinstalling the OS, no VM snapshot rollback.
  - Fix it with the tools the objective covers: ${C_DIM}date, hwclock, timedatectl,${C_OFF}
    ${C_DIM}/usr/share/zoneinfo, /etc/timezone, /etc/localtime, /etc/adjtime,${C_OFF}
    ${C_DIM}chronyc / ntpq / systemd-timesyncd, systemctl, journalctl${C_OFF}.
  - If the lab VM has no internet access, you may set the time manually - but
    you must still leave a valid client configuration behind.

${C_YEL}WHERE TO START${C_OFF}
    timedatectl                       # one screen, six answers
    timedatectl show                  # the same, machine-readable
    ls -l /etc/localtime ; cat /etc/timezone ; cat /etc/adjtime
    systemctl status ${TIME_UNIT:-<your ntp unit>}
    journalctl -u ${TIME_UNIT:-<your ntp unit>} -b --no-pager | tail -30

${C_YEL}GRADE YOURSELF${C_OFF}
    sudo $0 --verify

  Backups of every file touched: ${BACKUP_DIR}
  Emergency undo (only after you have really tried): sudo $0 --restore

EOF
}

# ---------------------------------------------------------------------------
# verification
# ---------------------------------------------------------------------------
PASS=0
FAILED=0
check() {
    # check "description" <boolean-command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok   "$desc"; PASS=$((PASS+1))
    else                          fail "$desc"; FAILED=$((FAILED+1))
    fi
}

tz_now()        { timedatectl show -p Timezone --value 2>/dev/null; }
localrtc_now()  { timedatectl show -p LocalRTC --value 2>/dev/null; }
ntp_now()       { timedatectl show -p NTP --value 2>/dev/null; }
synced_now()    { timedatectl show -p NTPSynchronized --value 2>/dev/null; }

no_bogus_servers() {
    local hits=""
    hits="$(grep -rlE '192\.0\.2\.(10|11)' /etc/chrony /etc/chrony.conf /etc/ntp.conf \
            /etc/ntpsec /etc/systemd/timesyncd.conf /etc/systemd/timesyncd.conf.d 2>/dev/null || true)"
    [ -z "$hits" ]
}

rtc_matches_system() {
    have_rtc || return 0
    local rtc_str rtc_epoch sys_epoch delta
    rtc_str="$(hwclock --show 2>/dev/null)" || return 1
    rtc_epoch="$(date -d "$rtc_str" +%s 2>/dev/null)" || return 1
    sys_epoch="$(date +%s)"
    delta=$(( rtc_epoch > sys_epoch ? rtc_epoch - sys_epoch : sys_epoch - rtc_epoch ))
    [ "$delta" -le 3 ]
}

do_verify() {
    load_state
    banner "grading - topic 108.1"
    printf '  system time : %s\n' "$(date)"
    printf '  UTC         : %s\n' "$(date -u)"
    have_rtc && printf '  RTC         : %s\n' "$(hwclock --show 2>/dev/null || echo 'unreadable')"
    echo

    check "/etc/localtime is a symlink into /usr/share/zoneinfo" \
          bash -c '[ -L /etc/localtime ] && readlink -f /etc/localtime | grep -q "^/usr/share/zoneinfo/"'
    check "timezone restored to ${ORIG_TZ} (current: $(tz_now))" \
          bash -c "[ \"\$(timedatectl show -p Timezone --value)\" = '${ORIG_TZ}' ]"
    if [ -f /etc/timezone ]; then
        check "/etc/timezone agrees with /etc/localtime" \
              bash -c "[ \"\$(cat /etc/timezone)\" = \"\$(timedatectl show -p Timezone --value)\" ]"
    fi
    check "RTC is interpreted as UTC (RTC in local TZ: no)" \
          bash -c '[ "$(timedatectl show -p LocalRTC --value)" = "no" ]'
    if [ -n "$TIME_UNIT" ]; then
        check "${TIME_UNIT} is not masked" \
              bash -c "[ \"\$(systemctl is-enabled '${TIME_UNIT}' 2>/dev/null)\" != 'masked' ]"
        check "${TIME_UNIT} is enabled at boot" \
              systemctl is-enabled --quiet "$TIME_UNIT"
        check "${TIME_UNIT} is running" \
              systemctl is-active --quiet "$TIME_UNIT"
    fi
    check "no TEST-NET-1 servers left in any time configuration" no_bogus_servers
    check "NTP service is active according to timedatectl (current: $(ntp_now))" \
          bash -c '[ "$(timedatectl show -p NTP --value)" = "yes" ]'
    check "system clock is synchronized (current: $(synced_now))" \
          bash -c '[ "$(timedatectl show -p NTPSynchronized --value)" = "yes" ]'
    check "hardware clock matches the system clock" rtc_matches_system

    echo
    if [ "$FAILED" -eq 0 ]; then
        ok "${PASS}/${PASS} checks passed - the machine keeps its own time again."
        echo
        cat <<'EOF'
  Follow-up worth doing before you call it done:
    find / -xdev -newermt "+1 day" -printf '%T+ %p\n' 2>/dev/null | head
        ...files stamped in the future while the clock was skewed.
    journalctl --since "-2 days" | grep -i "time has been changed"
        ...systemd logs every step of the clock; correlate with your repair.
EOF
        return 0
    fi
    fail "${FAILED} check(s) still failing, ${PASS} passing. Keep going."
    return 1
}

# ---------------------------------------------------------------------------
# restore
# ---------------------------------------------------------------------------
do_restore() {
    load_state
    banner "restoring the pre-lab state"

    if [ -n "$TIME_UNIT" ]; then
        systemctl unmask "$TIME_UNIT" >/dev/null 2>&1 || true
    fi

    rm -f /etc/systemd/timesyncd.conf.d/99-lab-break.conf
    rmdir /etc/systemd/timesyncd.conf.d 2>/dev/null || true

    if [ -d "$BACKUP_DIR" ]; then
        ( cd "$BACKUP_DIR" && find . -mindepth 1 -maxdepth 20 \( -type f -o -type l \) -print0 |
          while IFS= read -r -d '' rel; do
              target="/${rel#./}"
              mkdir -p "$(dirname "$target")"
              cp -a --no-dereference "$rel" "$target"
              printf '    restored %s\n' "$target"
          done )
    fi

    timedatectl set-local-rtc 0 >/dev/null 2>&1 || true
    timedatectl set-timezone "$ORIG_TZ" >/dev/null 2>&1 || true

    if [ -n "$TIME_UNIT" ]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        [ "$UNIT_WAS_ENABLED" = "enabled" ] && systemctl enable "$TIME_UNIT" >/dev/null 2>&1
        systemctl restart "$TIME_UNIT" >/dev/null 2>&1 || true
    fi
    timedatectl set-ntp true >/dev/null 2>&1 || true

    command -v chronyc >/dev/null 2>&1 && chronyc makestep >/dev/null 2>&1
    sleep 3
    have_rtc && hwclock --systohc >/dev/null 2>&1

    ok "restore attempted. Current state:"
    timedatectl || true
    warn "if the clock is still wrong, this VM had no reachable NTP source; set it by hand:"
    echo "    timedatectl set-ntp false && timedatectl set-time 'YYYY-MM-DD HH:MM:SS' && hwclock --systohc && timedatectl set-ntp true"
}

# ---------------------------------------------------------------------------
# break
# ---------------------------------------------------------------------------
do_break() {
    require_disposable_host
    if [ -f "$STATE_FILE" ]; then
        warn "this machine was already broken by this script (${STATE_FILE})."
        warn "use --verify to grade your repair, or --restore to undo. Refusing to break it twice."
        exit 1
    fi
    require_consent

    mkdir -p "$BACKUP_DIR"
    chmod 0700 "$STATE_DIR"

    ORIG_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)"
    ORIG_LOCAL_RTC="$(timedatectl show -p LocalRTC --value 2>/dev/null || echo no)"
    ORIG_NTP="$(timedatectl show -p NTP --value 2>/dev/null || echo no)"
    TIME_UNIT="$(detect_time_unit)"
    TIME_CONF="$(detect_time_config "$TIME_UNIT")"
    UNIT_WAS_ENABLED="$( [ -n "$TIME_UNIT" ] && systemctl is-enabled "$TIME_UNIT" 2>/dev/null || echo unknown )"
    BROKEN_AT_UTC="$(date -u '+%Y-%m-%d %H:%M:%S')"

    log "original timezone .... ${ORIG_TZ}"
    log "time daemon .......... ${TIME_UNIT:-none installed}"
    log "its configuration .... ${TIME_CONF:-n/a}"
    save_state

    fault_1_disable_and_mask_ntp
    fault_2_poison_ntp_servers
    fault_3_skew_clock_and_rtc
    fault_4_break_timezone

    save_state
    print_briefing
}

usage() {
    sed -n '2,40p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'
}

main() {
    case "${1:---break}" in
        --break|break)     require_root "$@"; do_break ;;
        --verify|verify)   require_root "$@"; do_verify ;;
        --restore|restore) require_root "$@"; do_restore ;;
        --help|-h|help)    usage ;;
        *)                 die "unknown option '$1' (try --help)" ;;
    esac
}

main "$@"
