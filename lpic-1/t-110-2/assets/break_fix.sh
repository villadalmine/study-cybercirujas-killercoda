#!/usr/bin/env bash
# =============================================================================
#  LPIC-1 v5.0  --  Exams 101-500 / 102-500
#  Topic 110.2: Setup host security
#  BREAK & FIX laboratory  --  RUN ONLY ON A DISPOSABLE LAB VM
# =============================================================================
#
#  What this script does
#  ---------------------
#  It takes a healthy lab VM and introduces five *controlled* host-security
#  faults, every one of them straight out of objective 110.2:
#
#    F1  Shadow passwords disabled       (/etc/passwd, /etc/shadow, pwconv)
#    F2  Over-broad sudo rule            (/etc/sudoers, /etc/sudoers.d/)
#    F3  Unneeded network service up     (super-server or systemd unit)
#    F4  Broken TCP wrappers policy      (/etc/hosts.allow, /etc/hosts.deny)
#    F5  Logins blocked by /etc/nologin  (pam_nologin)
#
#  Everything it touches is snapshotted first under /var/lib/lpic1-110.2/backup,
#  every listener it starts is bound to 127.0.0.1 (the lab never exposes the VM
#  to the LAN), and `--restore` puts the machine back exactly as it was.
#
#  Usage
#  -----
#    ./lpic1-110.2-break-and-fix.sh --break     # apply the faults + briefing
#    ./lpic1-110.2-break-and-fix.sh --brief     # reprint the briefing
#    ./lpic1-110.2-break-and-fix.sh --verify    # grade yourself (exit 0 = fixed)
#    ./lpic1-110.2-break-and-fix.sh --restore   # emergency rollback
#
#  Environment overrides: LAB_USER (default labuser), ROGUE_PORT (default 8099),
#  LPIC_LAB_CONFIRM=yes (skip the interactive confirmation, for automation).
#
#  Official references
#  -------------------
#    LPI exam 101 objectives  https://www.lpi.org/our-certifications/exam-101-objectives/
#    LPI exam 102 objectives  https://www.lpi.org/our-certifications/exam-102-objectives/
#    shadow(5)                https://man7.org/linux/man-pages/man5/shadow.5.html
#    pwconv(8) / pwunconv(8)  https://man7.org/linux/man-pages/man8/pwconv.8.html
#    sudoers(5)               https://www.sudo.ws/docs/man/sudoers.man/
#    hosts_access(5)          https://man7.org/linux/man-pages/man5/hosts_access.5.html
#    xinetd.conf(5)           https://man7.org/linux/man-pages/man5/xinetd.conf.5.html
#    inetd.conf(5)            https://man7.org/linux/man-pages/man5/inetd.conf.5.html
#    pam_nologin(8)           https://man7.org/linux/man-pages/man8/pam_nologin.8.html
#    systemctl(1)             https://www.freedesktop.org/software/systemd/man/systemctl.html
# =============================================================================

set -Eeuo pipefail
trap 'printf "[ERROR] %s failed at line %s\n" "${BASH_SOURCE[0]}" "$LINENO" >&2' ERR

readonly LAB_ID="lpic1-110.2"
readonly STATE_DIR="/var/lib/${LAB_ID}"
readonly BACKUP_DIR="${STATE_DIR}/backup"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly SHARE_DIR="${STATE_DIR}/share"
readonly SUDO_DROPIN="/etc/sudoers.d/99-lab-legacy"
readonly XINETD_FILE="/etc/xinetd.d/lab-echo"
readonly UNIT_NAME="lab-legacy-fileshare.service"
readonly UNIT_FILE="/etc/systemd/system/${UNIT_NAME}"
readonly WRAP_DAEMON="in.telnetd"

LAB_USER="${LAB_USER:-labuser}"
ROGUE_PORT="${ROGUE_PORT:-8099}"
LAB_MODE="none"          # systemd | xinetd | inetd | none
LAB_PORT="${ROGUE_PORT}"
APPLIED=""

if [ -t 1 ]; then
    C_HDR=$'\033[1;36m'; C_OK=$'\033[1;32m'; C_BAD=$'\033[1;31m'
    C_WARN=$'\033[1;33m'; C_OFF=$'\033[0m'
else
    C_HDR=""; C_OK=""; C_BAD=""; C_WARN=""; C_OFF=""
fi

# ---------------------------------------------------------------- helpers ---
log()  { printf '%s\n' "$*"; }
hdr()  { printf '\n%s=== %s ===%s\n' "$C_HDR" "$*" "$C_OFF"; }
warn() { printf '%s[WARN]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s[FATAL]%s %s\n' "$C_BAD" "$C_OFF" "$*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "This lab must run as root (it edits /etc/shadow, sudoers and unit files)."
}

have() { command -v "$1" >/dev/null 2>&1; }

# Snapshot a file once, preserving mode/owner, under the backup tree.
snapshot() {
    local f
    for f in "$@"; do
        [ -e "$f" ] || continue
        [ -e "${BACKUP_DIR}${f}" ] && continue
        mkdir -p "$(dirname "${BACKUP_DIR}${f}")"
        cp -a "$f" "${BACKUP_DIR}${f}"
    done
}

port_listening() {
    local port="$1"
    if have ss; then
        ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
    elif have netstat; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
    else
        return 1
    fi
}

save_state() {
    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
# ${LAB_ID} lab state -- written by $(basename "$0")
LAB_USER='${LAB_USER}'
LAB_MODE='${LAB_MODE}'
LAB_PORT='${LAB_PORT}'
APPLIED='${APPLIED}'
EOF
    chmod 0600 "$STATE_FILE"
}

load_state() {
    [ -f "$STATE_FILE" ] || die "No lab state found. Run '$0 --break' first."
    # shellcheck source=/dev/null
    . "$STATE_FILE"
}

applied() { case " $APPLIED " in *" $1 "*) return 0;; *) return 1;; esac; }

confirm_disposable_vm() {
    hdr "READ THIS BEFORE YOU CONTINUE"
    cat <<'EOF'
This script deliberately DAMAGES host security configuration:

  * it disables shadow passwords (hashes move into world-readable /etc/passwd)
  * it installs a deliberately dangerous sudo rule
  * it starts a network service you are supposed to hunt down
  * it installs a default-deny TCP wrappers policy
  * it creates /etc/nologin, which blocks non-root logins

Do NOT run it on anything you care about. Before continuing, make sure you
have a WORKING ROOT SESSION on the console (or the root password): faults F1
and F5 can lock a normal user out of the machine, and that is the point.
EOF
    if [ "${LPIC_LAB_CONFIRM:-}" = "yes" ]; then
        log "LPIC_LAB_CONFIRM=yes -- proceeding without prompting."
        return 0
    fi
    [ -t 0 ] || die "Not a terminal. Re-run with LPIC_LAB_CONFIRM=yes if you really mean it."
    local answer=""
    printf '\nType exactly: BREAK MY LAB VM\n> '
    read -r answer
    [ "$answer" = "BREAK MY LAB VM" ] || die "Confirmation mismatch. Nothing was changed."
}

ensure_lab_user() {
    if ! id -u "$LAB_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash -c "LPIC-1 110.2 lab user" "$LAB_USER"
        printf '%s:Lab-110.2-Pass\n' "$LAB_USER" | chpasswd
        log "Created unprivileged lab user '${LAB_USER}' (password: Lab-110.2-Pass)."
    else
        log "Using existing lab user '${LAB_USER}'."
    fi
}

detect_service_mode() {
    if [ -d /etc/xinetd.d ] && have xinetd; then
        LAB_MODE="xinetd"; LAB_PORT=7
    elif [ -f /etc/inetd.conf ] && { have inetd || have inetutils-inetd; }; then
        LAB_MODE="inetd";  LAB_PORT=7
    elif have systemctl && [ -d /run/systemd/system ] && have python3; then
        LAB_MODE="systemd"; LAB_PORT="$ROGUE_PORT"
    else
        LAB_MODE="none"
    fi
}

# ------------------------------------------------------------ break: F1 -----
break_f1_shadow() {
    have pwunconv || { warn "F1 skipped: pwunconv (shadow-utils) is not installed."; return 0; }
    snapshot /etc/passwd /etc/shadow /etc/group /etc/gshadow
    pwunconv
    chmod 0644 /etc/passwd
    APPLIED="${APPLIED} F1"
    log "F1 applied: shadow passwords disabled (pwunconv)."
}

# ------------------------------------------------------------ break: F2 -----
break_f2_sudo() {
    have sudo || { warn "F2 skipped: sudo is not installed."; return 0; }
    snapshot /etc/sudoers
    cat > "${SUDO_DROPIN}" <<EOF
# Added by "the previous admin" so the helpdesk could reboot printers.
# It survived three audits. It should not survive this one.
${LAB_USER} ALL=(ALL:ALL) NOPASSWD: ALL
Defaults:${LAB_USER} !authenticate
EOF
    chmod 0440 "${SUDO_DROPIN}"
    if ! visudo -cf "${SUDO_DROPIN}" >/dev/null 2>&1; then
        rm -f "${SUDO_DROPIN}"
        warn "F2 skipped: the generated drop-in did not pass 'visudo -c'; sudo left untouched."
        return 0
    fi
    APPLIED="${APPLIED} F2"
    log "F2 applied: ${SUDO_DROPIN} grants ${LAB_USER} unrestricted passwordless root."
}

# ------------------------------------------------------------ break: F3 -----
break_f3_service() {
    case "$LAB_MODE" in
        xinetd)
            snapshot /etc/xinetd.conf
            cat > "${XINETD_FILE}" <<'EOF'
# Legacy diagnostic service re-enabled "temporarily" in 2011.
service echo
{
    disable         = no
    id              = echo-stream
    type            = INTERNAL
    socket_type     = stream
    protocol        = tcp
    user            = root
    wait            = no
    bind            = 127.0.0.1
    only_from       = 0.0.0.0/0
}
EOF
            chmod 0644 "${XINETD_FILE}"
            systemctl reload xinetd 2>/dev/null || systemctl restart xinetd 2>/dev/null || pkill -HUP xinetd 2>/dev/null || true
            ;;
        inetd)
            snapshot /etc/inetd.conf
            printf '127.0.0.1:echo\tstream\ttcp\tnowait\troot\tinternal\n' >> /etc/inetd.conf
            systemctl restart inetd 2>/dev/null || systemctl restart openbsd-inetd 2>/dev/null || pkill -HUP inetd 2>/dev/null || true
            ;;
        systemd)
            mkdir -p "${SHARE_DIR}"
            printf 'Anything in this directory is served to the network by an unneeded daemon.\n' \
                > "${SHARE_DIR}/README.txt"
            cat > "${UNIT_FILE}" <<EOF
[Unit]
Description=Lab legacy file share (an unneeded network service)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server ${LAB_PORT} --bind 127.0.0.1 --directory ${SHARE_DIR}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
            chmod 0644 "${UNIT_FILE}"
            systemctl daemon-reload
            systemctl enable --now "${UNIT_NAME}" >/dev/null 2>&1 || true
            ;;
        *)
            warn "F3 skipped: no xinetd, no inetd and no systemd+python3 available."
            return 0
            ;;
    esac
    APPLIED="${APPLIED} F3"
    log "F3 applied: an unneeded service is listening on 127.0.0.1:${LAB_PORT} (${LAB_MODE})."
}

# ------------------------------------------------------------ break: F4 -----
break_f4_wrappers() {
    snapshot /etc/hosts.allow /etc/hosts.deny
    cat > /etc/hosts.deny <<'EOF'
# TCP wrappers: default-deny policy. This line is CORRECT and must stay.
ALL: ALL
EOF
    cat > /etc/hosts.allow <<'EOF'
# Exceptions to /etc/hosts.deny. Consulted first; first match wins.
# Somebody typed the daemon name from memory. Nothing here matches anything.
ssdh: LOCAL
EOF
    chmod 0644 /etc/hosts.allow /etc/hosts.deny
    APPLIED="${APPLIED} F4"
    log "F4 applied: default-deny in /etc/hosts.deny with a typo'd exception in /etc/hosts.allow."
}

# ------------------------------------------------------------ break: F5 -----
break_f5_nologin() {
    snapshot /etc/nologin
    cat > /etc/nologin <<'EOF'
System maintenance in progress. Interactive logins are disabled.
EOF
    chmod 0644 /etc/nologin
    APPLIED="${APPLIED} F5"
    log "F5 applied: /etc/nologin now blocks non-root logins (pam_nologin)."
}

# ----------------------------------------------------------- the briefing ---
briefing() {
    hdr "LPIC-1 110.2 -- BREAK & FIX BRIEFING"
    cat <<EOF
Lab user      : ${LAB_USER} (password Lab-110.2-Pass)
Faults applied: ${APPLIED:- none}
Self-grading  : $0 --verify        Emergency rollback: $0 --restore

Fix them in the order below. Nothing here needs a network connection, an
extra package, or a reboot.
EOF

    if applied F1; then
        cat <<'EOF'

-----------------------------------------------------------------------------
F1  Shadow passwords are gone
-----------------------------------------------------------------------------
SYMPTOM     /etc/shadow no longer exists and every password hash is now sitting
            in the second field of a file every user on the box can read.

OBSERVE     ls -l /etc/shadow
              ls: cannot access '/etc/shadow': No such file or directory
            getent passwd root | cut -d: -f1,2
              root:$y$j9T$Xk1...            <-- the hash, world-readable

OBJECTIVE   Put the hashes back into a shadow file that non-root users cannot
            read, without losing or altering a single account, and leave
            /etc/passwd owned by root with mode 0644.
SUCCESS     /etc/shadow exists, no account carries an inline hash in
            /etc/passwd, and /etc/shadow is not readable by "other".
EOF
    fi

    if applied F2; then
        cat <<EOF

-----------------------------------------------------------------------------
F2  A sudo rule that gives away the machine
-----------------------------------------------------------------------------
SYMPTOM     ${LAB_USER} can become root, for any command, without ever typing
            a password -- so a stolen session or an XSS-grade mistake is
            instantly a full host compromise.

OBSERVE     sudo -l -U ${LAB_USER}
              User ${LAB_USER} may run the following commands on this host:
                  (ALL : ALL) NOPASSWD: ALL
            ls -l ${SUDO_DROPIN}

OBJECTIVE   Remove the blanket grant. Either delete the drop-in entirely, or
            narrow it to the specific commands the role actually needs and
            make sudo authenticate again. Edit sudoers files with visudo ONLY
            -- a syntax error there costs you every privilege escalation path
            on the machine.
SUCCESS     'visudo -c' is clean, and 'sudo -l -U ${LAB_USER}' contains no
            unrestricted NOPASSWD grant and no '!authenticate' default.
EOF
    fi

    if applied F3; then
        cat <<EOF

-----------------------------------------------------------------------------
F3  A network service nobody asked for
-----------------------------------------------------------------------------
SYMPTOM     Something is accepting TCP connections on 127.0.0.1:${LAB_PORT}
            and it is not part of this host's job. It is also configured to
            come back after a reboot.

OBSERVE     ss -ltnp | grep ':${LAB_PORT}'
              LISTEN 0  5  127.0.0.1:${LAB_PORT}  0.0.0.0:*  users:(("...",pid=...))
            (started via: ${LAB_MODE})

OBJECTIVE   Identify who owns that socket, stop it, and make sure it does NOT
            return on the next boot. Reducing the listening surface is the
            whole point of this objective: a service that is not running
            cannot be exploited.
SUCCESS     Nothing listens on port ${LAB_PORT} and the service is disabled
            persistently (systemd: not enabled; xinetd: disable = yes or the
            file removed; inetd: the line commented out).
EOF
    fi

    if applied F4; then
        cat <<EOF

-----------------------------------------------------------------------------
F4  TCP wrappers deny everything, including you
-----------------------------------------------------------------------------
SYMPTOM     /etc/hosts.deny now carries 'ALL: ALL' and the only exception in
            /etc/hosts.allow is misspelled, so every libwrap-linked daemon
            refuses every client -- including 127.0.0.1.

OBSERVE     tcpdmatch ${WRAP_DAEMON} 127.0.0.1
              client:   hostname localhost
              client:   address  127.0.0.1
              server:   process  ${WRAP_DAEMON}
              matched:  /etc/hosts.deny line 3
              access:   denied

NOTE        Only daemons compiled against libwrap honour these files. OpenSSH
            dropped libwrap in 6.7 (2014), so sshd is NOT affected -- checking
            with tcpdmatch/tcpdchk, or with a genuinely wrapped daemon, is the
            only honest way to test this.

OBJECTIVE   Keep the default-deny in /etc/hosts.deny (that part is correct
            practice) and write a real exception in /etc/hosts.allow that
            grants the loopback interface. Remove the typo'd rule.
SUCCESS     /etc/hosts.deny still ends in 'ALL: ALL', /etc/hosts.allow grants
            127.0.0.1 / LOCAL (never 'ALL: ALL'), and the 'ssdh' line is gone.
EOF
    fi

    if applied F5; then
        cat <<'EOF'

-----------------------------------------------------------------------------
F5  Nobody can log in any more
-----------------------------------------------------------------------------
SYMPTOM     A normal user authenticating over ssh or on a console gets the
            maintenance banner and is disconnected. root still gets in.

OBSERVE     ssh labuser@localhost
              System maintenance in progress. Interactive logins are disabled.
              Connection closed by 127.0.0.1 port 22
            cat /etc/nologin

OBJECTIVE   Restore interactive logins. Understand which PAM module enforces
            this and where else it looks -- pam_nologin also honours
            /run/nologin, which systemd creates during shutdown.
SUCCESS     Neither /etc/nologin nor /run/nologin exists, and labuser can log
            in again.
EOF
    fi
    printf '\n'
}

# ---------------------------------------------------------------- verify ----
FAILED=0
pass() { printf '  %s[ PASS ]%s %s\n' "$C_OK" "$C_OFF" "$1"; }
fail() { printf '  %s[ FAIL ]%s %s\n' "$C_BAD" "$C_OFF" "$1"; FAILED=$((FAILED+1)); }

check_f1() {
    if [ ! -f /etc/shadow ]; then
        fail "F1: /etc/shadow does not exist"; return
    fi
    if awk -F: '$2 != "x" && $2 != "*" && $2 != "!" && $2 != "!!" && $2 != "!*" {found=1} END{exit !found}' /etc/passwd; then
        fail "F1: /etc/passwd still carries inline password material"; return
    fi
    local mode; mode="$(stat -c %a /etc/shadow)"
    if [ $(( 0"$mode" & 0007 )) -ne 0 ]; then
        fail "F1: /etc/shadow is readable/writable by others (mode ${mode})"; return
    fi
    if [ "$(stat -c %U /etc/passwd)" != "root" ] || [ "$(stat -c %a /etc/passwd)" != "644" ]; then
        fail "F1: /etc/passwd should be root-owned, mode 0644"; return
    fi
    pass "F1: shadow passwords restored and permissions are sane"
}

check_f2() {
    if ! have sudo; then pass "F2: sudo not installed, nothing to check"; return; fi
    if ! visudo -c >/dev/null 2>&1; then
        fail "F2: 'visudo -c' reports a syntax error -- fix it before anything else"; return
    fi
    local out; out="$(sudo -l -U "$LAB_USER" 2>/dev/null || true)"
    if printf '%s' "$out" | grep -qE 'NOPASSWD:[[:space:]]*ALL'; then
        fail "F2: ${LAB_USER} still has an unrestricted NOPASSWD grant"; return
    fi
    if grep -rqs '!authenticate' /etc/sudoers /etc/sudoers.d 2>/dev/null; then
        fail "F2: a '!authenticate' Defaults line is still in place"; return
    fi
    pass "F2: the blanket sudo grant is gone"
}

check_f3() {
    if port_listening "$LAB_PORT"; then
        fail "F3: something still listens on port ${LAB_PORT}"; return
    fi
    case "$LAB_MODE" in
        systemd)
            if systemctl is-enabled "$UNIT_NAME" >/dev/null 2>&1; then
                fail "F3: ${UNIT_NAME} is stopped but still enabled at boot"; return
            fi
            ;;
        xinetd)
            if [ -f "$XINETD_FILE" ] && ! grep -qE '^[[:space:]]*disable[[:space:]]*=[[:space:]]*yes' "$XINETD_FILE"; then
                fail "F3: ${XINETD_FILE} is still enabled (disable = no)"; return
            fi
            ;;
        inetd)
            if grep -qE '^[^#]*echo[[:space:]]+stream' /etc/inetd.conf 2>/dev/null; then
                fail "F3: the echo line is still active in /etc/inetd.conf"; return
            fi
            ;;
    esac
    pass "F3: the unneeded service is down and stays down"
}

check_f4() {
    if ! grep -qE '^[[:space:]]*ALL[[:space:]]*:[[:space:]]*ALL' /etc/hosts.deny 2>/dev/null; then
        fail "F4: /etc/hosts.deny no longer carries the default-deny 'ALL: ALL'"; return
    fi
    if grep -qE '^[[:space:]]*ALL[[:space:]]*:[[:space:]]*ALL' /etc/hosts.allow 2>/dev/null; then
        fail "F4: /etc/hosts.allow contains 'ALL: ALL' -- that cancels the whole policy"; return
    fi
    if grep -qs 'ssdh' /etc/hosts.allow; then
        fail "F4: the typo'd 'ssdh' rule is still in /etc/hosts.allow"; return
    fi
    if have tcpdmatch; then
        if tcpdmatch "$WRAP_DAEMON" 127.0.0.1 2>/dev/null | grep -qE 'access:[[:space:]]*granted'; then
            pass "F4: tcpdmatch confirms loopback access is granted again"
        else
            fail "F4: tcpdmatch still denies ${WRAP_DAEMON} from 127.0.0.1"
        fi
        return
    fi
    if grep -qE '^[^#]*:.*(127\.0\.0\.1|LOCAL|\[::1\])' /etc/hosts.allow 2>/dev/null; then
        pass "F4: /etc/hosts.allow grants loopback and the default-deny is intact"
    else
        fail "F4: /etc/hosts.allow has no rule granting the loopback interface"
    fi
}

check_f5() {
    if [ -e /etc/nologin ] || [ -e /run/nologin ]; then
        fail "F5: a nologin file still exists (/etc/nologin or /run/nologin)"
    else
        pass "F5: interactive logins are allowed again"
    fi
}

do_verify() {
    load_state
    hdr "LPIC-1 110.2 -- VERIFICATION"
    set +e
    FAILED=0
    applied F1 && check_f1
    applied F2 && check_f2
    applied F3 && check_f3
    applied F4 && check_f4
    applied F5 && check_f5
    set -e
    printf '\n'
    if [ "$FAILED" -eq 0 ]; then
        printf '%sAll checks passed -- the host is back to a defensible state.%s\n\n' "$C_OK" "$C_OFF"
        return 0
    fi
    printf '%s%d check(s) still failing. Re-read the briefing with: %s --brief%s\n\n' \
        "$C_BAD" "$FAILED" "$0" "$C_OFF"
    return 1
}

# --------------------------------------------------------------- restore ----
do_restore() {
    load_state
    hdr "LPIC-1 110.2 -- ROLLBACK"
    rm -f /etc/nologin /run/nologin "$SUDO_DROPIN" "$XINETD_FILE"
    if have systemctl; then
        systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
        rm -f "$UNIT_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if [ -d "$BACKUP_DIR" ]; then
        while IFS= read -r -d '' rel; do
            cp -a "${BACKUP_DIR}/${rel#./}" "/${rel#./}"
            log "restored /${rel#./}"
        done < <(cd "$BACKUP_DIR" && find . -type f -print0)
    fi
    have pwconv && pwconv || true
    have restorecon && restorecon -F /etc/passwd /etc/shadow /etc/hosts.allow /etc/hosts.deny >/dev/null 2>&1 || true
    case "$LAB_MODE" in
        xinetd) systemctl reload xinetd 2>/dev/null || systemctl restart xinetd 2>/dev/null || true ;;
        inetd)  systemctl restart inetd 2>/dev/null || systemctl restart openbsd-inetd 2>/dev/null || true ;;
    esac
    log "Rollback complete. The lab user '${LAB_USER}' was left in place."
}

# ----------------------------------------------------------------- break ----
do_break() {
    confirm_disposable_vm
    mkdir -p "$STATE_DIR" "$BACKUP_DIR"
    chmod 0700 "$STATE_DIR"
    ensure_lab_user
    detect_service_mode
    hdr "APPLYING FAULTS"
    break_f1_shadow
    break_f2_sudo
    break_f3_service
    break_f4_wrappers
    break_f5_nologin
    APPLIED="${APPLIED# }"
    save_state
    briefing
}

usage() {
    cat <<EOF
LPIC-1 110.2 -- Setup host security: break & fix lab

  $0 --break     apply the faults and print the briefing (DISPOSABLE VM ONLY)
  $0 --brief     reprint the briefing for the faults currently applied
  $0 --verify    grade your work; exit status 0 means everything is fixed
  $0 --restore   emergency rollback from ${BACKUP_DIR}
  $0 --help      this text
EOF
}

main() {
    require_root
    case "${1:---help}" in
        --break)   do_break ;;
        --brief)   load_state; briefing ;;
        --verify)  do_verify ;;
        --restore) do_restore ;;
        --help|-h) usage ;;
        *)         usage; exit 2 ;;
    esac
}

main "$@"
