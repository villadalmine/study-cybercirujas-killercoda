#!/usr/bin/env bash
#
# ==============================================================================
#  LPIC-1 (Exams 101-500 / 102-500, version 5.0)
#  Topic 108.3 — Mail Transfer Agent (MTA) basics
#  Exam weight: 3 (per the official LPI 102-500 objectives; see citations below)
#
#  BREAK & FIX laboratory — Postfix local delivery, aliases and .forward
#
#  Official reference sources
#    LPI 101-500 objectives : https://www.lpi.org/our-certifications/exam-101-objectives/
#    LPI 102-500 objectives : https://www.lpi.org/our-certifications/exam-102-objectives/
#    postconf(5)            : https://www.postfix.org/postconf.5.html
#    local(8)               : https://www.postfix.org/local.8.html
#    aliases(5)             : https://www.postfix.org/aliases.5.html
#    newaliases(1)/postalias: https://www.postfix.org/postalias.1.html
#    mailq / postqueue(1)   : https://www.postfix.org/postqueue.1.html
#    postsuper(1)           : https://www.postfix.org/postsuper.1.html
#    Postfix standard config: https://www.postfix.org/STANDARD_CONFIGURATION_README.html
#
#  WARNING — DESTRUCTIVE BY DESIGN.
#  This script rewrites Postfix configuration, /etc/aliases and user ~/.forward
#  files. Run it ONLY on a disposable lab VM or container that carries no real
#  mail. It refuses to run on bare metal unless you pass --force.
#
#  Everything it touches is snapshotted first under /var/backups/lpic1-lab-108.3
#  and can be rolled back with:  sudo ./break-and-fix-108.3.sh restore
#
#  Usage:
#    sudo ./break-and-fix-108.3.sh break     # prepare the VM and inject the faults
#    sudo ./break-and-fix-108.3.sh hints     # diagnostic approach, no answers
#    sudo ./break-and-fix-108.3.sh verify    # end-to-end grading of your fix
#    sudo ./break-and-fix-108.3.sh restore   # instructor reset (undo the breakage)
#    sudo ./break-and-fix-108.3.sh purge     # restore + delete the lab users/mailboxes
#
#  Flags: --yes (no interactive confirmation)  --force (skip the virtualisation check)
# ==============================================================================

set -euo pipefail

LAB_ID="108.3"
LAB_USER="mtalab"          # the ticket owner; must keep a local copy of their mail
TEAM_USER="mtaops"         # the on-call team mailbox; must receive a copy too
LAB_ALIAS="helpdesk"       # alias that must expand to both users
BACKUP_ROOT="/var/backups/lpic1-lab-${LAB_ID}"
PROBE_TIMEOUT=30           # seconds to wait for a delivery during verification
ASSUME_YES=0
FORCE=0

# ------------------------------------------------------------------ output ---
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\e[1;31m'; C_GRN=$'\e[1;32m'; C_YEL=$'\e[1;33m'
    C_BLU=$'\e[1;34m'; C_DIM=$'\e[2m';    C_OFF=$'\e[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_OFF=""
fi

log()  { printf '%s[lab]%s %s\n'  "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
fail() { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$*"; }
die()  { printf '%s[fatal]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
hr()   { printf '%s\n' "$C_DIM--------------------------------------------------------------------------$C_OFF"; }

trap 'rc=$?; [ $rc -ne 0 ] && printf "%s[fatal]%s aborted at line %s (exit %s)\n" "$C_RED" "$C_OFF" "$LINENO" "$rc" >&2; exit $rc' ERR

# ------------------------------------------------------------- environment ---
PKG=""; MAILLOG=""; NOLOGIN=""

detect_os() {
    local id="" like=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id="${ID:-}"; like="${ID_LIKE:-}"
    fi
    case "$id $like" in
        *debian*|*ubuntu*) PKG="apt";    MAILLOG="/var/log/mail.log" ;;
        *fedora*|*rhel*|*centos*|*almalinux*|*rocky*) PKG="dnf"; MAILLOG="/var/log/maillog" ;;
        *suse*)            PKG="zypper"; MAILLOG="/var/log/mail" ;;
        *arch*)            PKG="pacman"; MAILLOG="/var/log/mail.log" ;;
        *)                 PKG="";       MAILLOG="/var/log/maillog" ;;
    esac
    command -v dnf >/dev/null 2>&1 || [ "$PKG" != "dnf" ] || PKG="yum"
}

need_root() { [ "$(id -u)" -eq 0 ] || die "run this as root (sudo $0 $*)"; }

safety_gate() {
    local virt="physical"
    command -v systemd-detect-virt >/dev/null 2>&1 && virt="$(systemd-detect-virt || echo none)"
    if [ "$virt" = "none" ] || [ "$virt" = "physical" ]; then
        if [ -f /.dockerenv ]; then virt="docker"; fi
    fi
    if [ "$virt" = "none" ] || [ "$virt" = "physical" ]; then
        [ "$FORCE" -eq 1 ] || die "no virtualisation detected. This host may be real. Re-run with --force only if it is disposable."
        warn "no virtualisation detected — continuing because --force was given"
    else
        log "virtualisation detected: ${virt}"
    fi
    [ "$ASSUME_YES" -eq 1 ] && return 0
    printf '\n%sThis will rewrite Postfix config, /etc/aliases and ~/.forward on THIS host.%s\n' "$C_YEL" "$C_OFF"
    printf 'Type %sBREAK%s to continue: ' "$C_RED" "$C_OFF"
    local answer; read -r answer
    [ "$answer" = "BREAK" ] || die "confirmation not given; nothing was modified"
}

pkg_install() {
    case "$PKG" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq "$@" >/dev/null
            ;;
        dnf|yum) "$PKG" -y -q install "$@" >/dev/null ;;
        zypper)  zypper -n -q install "$@" >/dev/null ;;
        pacman)  pacman -Sy --noconfirm --needed "$@" >/dev/null ;;
        *) die "unsupported package manager; install postfix manually and re-run" ;;
    esac
}

fqdn_of_host() {
    local f=""
    f="$(hostname -f 2>/dev/null || true)"
    [ -n "$f" ] || f="$(hostname)"
    case "$f" in
        *.*) : ;;
        *)   f="${f}.lab.local" ;;
    esac
    printf '%s' "$f"
}

MYHOST=""

# ------------------------------------------------------------ lab baseline ---
ensure_postfix() {
    if command -v postconf >/dev/null 2>&1 && [ -f /etc/postfix/main.cf ]; then
        log "postfix already installed: $(postconf -h mail_version)"
    else
        if command -v exim4 >/dev/null 2>&1 || command -v exim >/dev/null 2>&1; then
            warn "exim is present; installing postfix will replace it as the system MTA"
        fi
        log "installing postfix (this lab is built on postfix)"
        if [ "$PKG" = "apt" ]; then
            echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
            echo "postfix postfix/mailname string ${MYHOST}"          | debconf-set-selections
        fi
        pkg_install postfix
    fi
    # a mail(1) client is convenient but not required — the lab uses sendmail(1)
    if ! command -v mail >/dev/null 2>&1 && ! command -v mailx >/dev/null 2>&1; then
        for candidate in bsd-mailx s-nail mailx mailutils; do
            pkg_install "$candidate" 2>/dev/null && { log "installed mail client: $candidate"; break; } || true
        done
    fi
    systemctl enable --now postfix >/dev/null 2>&1 || service postfix start >/dev/null 2>&1 || \
        die "cannot start postfix; inspect 'journalctl -u postfix'"
}

ensure_hosts_entry() {
    local short="${MYHOST%%.*}"
    grep -qE "[[:space:]]${MYHOST}([[:space:]]|$)" /etc/hosts && return 0
    log "adding a resolvable FQDN for ${MYHOST} to /etc/hosts"
    printf '127.0.1.1\t%s %s\n' "$MYHOST" "$short" >> /etc/hosts
}

harden_local_only() {
    # The lab must never touch the outside world: loopback only, no relayhost.
    log "pinning postfix to local-only delivery (safety, not part of the exercise)"
    postconf -e "myhostname = ${MYHOST}"
    postconf -e "mydomain = ${MYHOST#*.}"
    postconf -e "myorigin = \$myhostname"
    postconf -e "mydestination = \$myhostname, localhost, localhost.\$mydomain, ${MYHOST%%.*}"
    postconf -e "inet_interfaces = loopback-only"
    postconf -e "inet_protocols = ipv4"
    postconf -e "mynetworks = 127.0.0.0/8"
    postconf -e "relayhost ="
    postconf -e "smtpd_banner = \$myhostname ESMTP (LPIC-1 ${LAB_ID} offline lab)"
    postconf -e "home_mailbox ="
    postconf -e "defer_transports ="
    postconf -e "maximal_queue_lifetime = 1d"
    systemctl reload postfix >/dev/null 2>&1 || postfix reload >/dev/null 2>&1 || true
}

ensure_lab_users() {
    local u
    for u in "$LAB_USER" "$TEAM_USER"; do
        if id -u "$u" >/dev/null 2>&1; then
            log "lab user already present: ${u}"
        else
            log "creating lab user: ${u}"
            useradd -m -s /bin/bash -c "LPIC-1 ${LAB_ID} lab account" "$u"
            passwd -l "$u" >/dev/null
        fi
    done
}

# --------------------------------------------------------------- snapshots ---
snapshot() {
    local stamp dir
    stamp="$(date +%Y%m%d-%H%M%S)"
    dir="${BACKUP_ROOT}/${stamp}"
    mkdir -p "$dir"
    log "snapshotting the known-good baseline to ${dir}"
    cp -a /etc/postfix/main.cf     "${dir}/main.cf"
    cp -a /etc/postfix/master.cf   "${dir}/master.cf"
    cp -a /etc/aliases             "${dir}/aliases"
    cp -a /etc/hosts               "${dir}/hosts"
    postconf -n > "${dir}/postconf-n.txt"
    local u home
    for u in "$LAB_USER" "$TEAM_USER"; do
        home="$(getent passwd "$u" | cut -d: -f6)"
        if [ -n "$home" ] && [ -f "${home}/.forward" ]; then
            cp -a "${home}/.forward" "${dir}/forward.${u}"
        fi
    done
    printf 'LPIC-1 lab %s baseline taken at %s on %s\n' "$LAB_ID" "$stamp" "$MYHOST" > "${dir}/MANIFEST"
    ln -sfn "$dir" "${BACKUP_ROOT}/latest"
}

# ------------------------------------------------------------- mail probes ---
mailbox_of() {
    local u="$1" hm spool home
    hm="$(postconf -h home_mailbox 2>/dev/null || true)"
    home="$(getent passwd "$u" | cut -d: -f6)"
    if [ -n "$hm" ]; then
        printf '%s/%s' "$home" "$hm"
    else
        spool="$(postconf -h mail_spool_directory)"
        printf '%s/%s' "${spool%/}" "$u"
    fi
}

send_probe() {
    # send_probe <recipient> <subject-token>
    local to="$1" token="$2"
    /usr/sbin/sendmail -f "root@${MYHOST}" -t <<EOF
From: LPIC-1 lab ${LAB_ID} <root@${MYHOST}>
To: ${to}
Subject: ${token}

Probe message generated by the LPIC-1 ${LAB_ID} break & fix lab.
Token: ${token}
EOF
}

mailbox_has() {
    # mailbox_has <user> <token>  — works for both mbox files and Maildir trees
    local path; path="$(mailbox_of "$1")"
    grep -rqs -- "$2" "$path" 2>/dev/null
}

wait_for_delivery() {
    # wait_for_delivery <user> <token> ; NO queue flush on purpose — a globally
    # deferred transport must stay visible as a failure.
    local u="$1" token="$2" waited=0
    while [ "$waited" -lt "$PROBE_TIMEOUT" ]; do
        mailbox_has "$u" "$token" && return 0
        sleep 2; waited=$((waited + 2))
    done
    return 1
}

queue_depth() { mailq 2>/dev/null | grep -cE '^[0-9A-F]{6,}' || true; }

# ------------------------------------------------------------------ BREAK ----
inject_faults() {
    hr
    log "injecting faults"

    # --- Fault A: every local delivery is parked in the queue -----------------
    # postconf(5): defer_transports — "the list of transports that should not
    # deliver mail unless someone issues 'sendmail -q' or equivalent".
    postconf -e "defer_transports = local"
    systemctl reload postfix >/dev/null 2>&1 || postfix reload >/dev/null 2>&1

    # --- Fault B: /etc/aliases edited, alias database never rebuilt -----------
    # The text file is right, the compiled map (aliases.db / .lmdb) is stale.
    sed -i "/^${LAB_ALIAS}:/d" /etc/aliases
    newaliases                       # database is now in sync WITHOUT the alias
    {
        printf '\n# ops ticket #4711 - shared queue for first-level support\n'
        printf '%s:\t%s, %s\n' "$LAB_ALIAS" "$LAB_USER" "$TEAM_USER"
    } >> /etc/aliases                # deliberately NOT recompiled

    # --- Fault C: a ~/.forward that points at its own owner -------------------
    # local(8) stamps Delivered-To: before expanding ~/.forward, so the second
    # pass is detected as a forwarding loop and the mail bounces.
    local home; home="$(getent passwd "$LAB_USER" | cut -d: -f6)"
    printf '%s@%s\n' "$LAB_USER" "$MYHOST" > "${home}/.forward"
    chown "${LAB_USER}:$(id -gn "$LAB_USER")" "${home}/.forward"
    chmod 644 "${home}/.forward"

    # --- seed the queue so mailq is not empty when the student arrives --------
    send_probe "$TEAM_USER" "[TICKET-4711] on-call handover"
    send_probe "$LAB_USER"  "[TICKET-4711] printer in floor 2 is down"
    send_probe "$LAB_ALIAS" "[TICKET-4711] password reset request"
    sleep 2
    ok "faults injected; ${C_OFF}$(queue_depth) message(s) currently in the queue"
}

briefing() {
    hr
    cat <<EOF
${C_YEL}LPIC-1 ${LAB_ID} — Mail Transfer Agent (MTA) basics — BREAK & FIX${C_OFF}

${C_BLU}THE STORY${C_OFF}
  ${MYHOST} is the internal mail relay for a support team. Overnight a
  colleague "improved" the MTA configuration and the alias file. Since then the
  support team receives nothing. Nothing was deleted: every message is still on
  this host. Three independent defects are stacked, and they surface in layers —
  you only see the second one once the first is fixed.

${C_BLU}SYMPTOMS YOU WILL OBSERVE${C_OFF}
  1. ${C_RED}Nothing is ever delivered.${C_OFF} 'mailq' (equivalently
     'postqueue -p' or 'sendmail -bp') lists messages that stay there. The queue
     grows, no bounce is generated, and the mail log shows the messages being
     accepted by cleanup/qmgr but never handed to a delivery agent.
       $ mailq
       -Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------
       3F2A1C0A2B      451 $(date '+%a %b %e %H:%M:%S')  root@${MYHOST}
                                                 ${TEAM_USER}@${MYHOST}

  2. ${C_RED}Once mail starts flowing, mail to '${LAB_ALIAS}' bounces.${C_OFF}
     The bounce reads roughly:
       <${LAB_ALIAS}@${MYHOST}>: unknown user: "${LAB_ALIAS}"
     ...even though 'grep ${LAB_ALIAS} /etc/aliases' clearly shows the entry.

  3. ${C_RED}Mail addressed to ${LAB_USER} bounces back to the sender${C_OFF}
     with a message of the form:
       <${LAB_USER}@${MYHOST}>: mail forwarding loop for ${LAB_USER}@${MYHOST}
     ${LAB_USER}'s mailbox stays empty; ${TEAM_USER} never gets a copy either.

${C_BLU}WHAT YOU MUST ACHIEVE (this is exactly what 'verify' grades)${C_OFF}
  A. No transport is globally deferred any more, and the queue drains to empty.
  B. A message sent to '${LAB_ALIAS}' reaches ${LAB_USER} AND ${TEAM_USER}.
  C. A message sent to '${LAB_USER}' is delivered to ${LAB_USER}'s own mailbox
     AND is also copied to ${TEAM_USER} — the forwarding requirement is real, do
     not simply delete the forwarding rule and call it done.
  D. The fixes must be persistent: they must survive 'systemctl restart postfix'.
     Flushing the queue by hand is a workaround, not a fix.

${C_BLU}TOOLBOX${C_OFF}
  postconf -n | postconf -d | postconf -e | postconf -X   (effective vs default config)
  mailq | postqueue -p | postqueue -f | postsuper -d | postcat -q <QID>
  newaliases | postalias | postmap -q <key> <maptype:file>
  journalctl -u postfix -f   ${C_DIM}(or: tail -f ${MAILLOG})${C_OFF}
  su -s /bin/bash ${LAB_USER} -c mail    ${C_DIM}(read a lab mailbox)${C_OFF}

${C_BLU}RULES${C_OFF}
  * Do not reinstall postfix and do not restore ${BACKUP_ROOT}/latest — the
    point is to diagnose, not to roll back.
  * Read the logs before editing anything. Every one of these faults announces
    itself in the mail log.

  Diagnostic guidance without answers : ${C_GRN}sudo $0 hints${C_OFF}
  Grade your work                     : ${C_GRN}sudo $0 verify${C_OFF}
  Instructor reset                    : ${C_GRN}sudo $0 restore${C_OFF}
EOF
    hr
}

cmd_break() {
    need_root; detect_os; MYHOST="$(fqdn_of_host)"; safety_gate
    ensure_hosts_entry
    ensure_postfix
    ensure_lab_users
    harden_local_only
    newaliases
    snapshot
    inject_faults
    briefing
}

# ------------------------------------------------------------------ HINTS ----
cmd_hints() {
    detect_os; MYHOST="$(fqdn_of_host)"
    cat <<EOF
${C_BLU}Hint 1 — compare the running configuration with the defaults.${C_OFF}
  'postconf -n' prints only what main.cf overrides. Read every line of it and
  ask, for each one, "would a working relay need this?". 'postconf -d <param>'
  shows what the default would have been.

${C_BLU}Hint 2 — a queued message is not a lost message.${C_OFF}
  'mailq' tells you WHERE mail is; the log tells you WHY. Pick a queue ID and
  run 'postcat -q <QID>' to see envelope and headers. Then look for that queue
  ID in ${MAILLOG} (or 'journalctl -u postfix'). Absence of a delivery line for
  that ID is itself the clue: the queue manager never handed the message to a
  delivery agent.

${C_BLU}Hint 3 — Postfix does not read /etc/aliases at delivery time.${C_OFF}
  local(8) consults the indexed map named by 'alias_maps'. Ask the map itself,
  not the text file:
      postconf -h alias_maps ; postconf -h alias_database
      postmap -q ${LAB_ALIAS} \$(postconf -h alias_database)
  If the text file and the map disagree, the map wins. Also compare timestamps:
      ls -l --time-style=full-iso /etc/aliases*

${C_BLU}Hint 4 — read the bounce, it names the mechanism.${C_OFF}
  Bounces land in the envelope sender's mailbox (root here): 'mail -u root' or
  'less /var/mail/root'. A bounce that says "forwarding loop" is produced by
  local(8) when it finds its own Delivered-To: header again. Something is
  re-submitting the message instead of writing it to disk. aliases(5) explains
  the leading-backslash form that stops further expansion.

${C_BLU}Hint 5 — after a config change.${C_OFF}
  'postfix reload' (or 'systemctl reload postfix') re-reads main.cf. Deferred
  messages are NOT retried immediately: 'minimal_backoff_time' is 300s by
  default, so use 'postqueue -f' once to force a queue run and confirm.
EOF
}

# ----------------------------------------------------------------- VERIFY ----
check() {
    # check <description> <0|1 result>
    if [ "$2" -eq 0 ]; then ok "$1"; else fail "$1"; FAILED=$((FAILED + 1)); fi
}

cmd_verify() {
    need_root; detect_os; MYHOST="$(fqdn_of_host)"
    FAILED=0
    local stamp token_a token_b token_c dt depth
    stamp="$(date +%s)-$$"
    token_a="LPIC1083-A-${stamp}"
    token_b="LPIC1083-B-${stamp}"
    token_c="LPIC1083-C-${stamp}"

    hr
    log "grading LPIC-1 ${LAB_ID} on ${MYHOST}"

    id -u "$LAB_USER"  >/dev/null 2>&1 || die "lab user ${LAB_USER} is missing; run '$0 break' first"
    id -u "$TEAM_USER" >/dev/null 2>&1 || die "lab user ${TEAM_USER} is missing; run '$0 break' first"
    systemctl is-active --quiet postfix || die "postfix is not running"

    dt="$(postconf -h defer_transports 2>/dev/null || true)"
    [ -z "$dt" ]; check "A1: no transport is globally deferred (defer_transports is empty)" $?

    log "probe 1/3 -> ${TEAM_USER}  (plain local delivery)"
    send_probe "$TEAM_USER" "$token_a"
    wait_for_delivery "$TEAM_USER" "$token_a"; check "A2: mail to ${TEAM_USER} lands in $(mailbox_of "$TEAM_USER")" $?

    log "probe 2/3 -> ${LAB_USER}   (local copy + forward)"
    send_probe "$LAB_USER" "$token_b"
    wait_for_delivery "$LAB_USER"  "$token_b"; check "C1: mail to ${LAB_USER} is kept in ${LAB_USER}'s own mailbox" $?
    wait_for_delivery "$TEAM_USER" "$token_b"; check "C2: mail to ${LAB_USER} is also copied to ${TEAM_USER}" $?

    log "probe 3/3 -> ${LAB_ALIAS}  (alias expansion)"
    send_probe "$LAB_ALIAS" "$token_c"
    wait_for_delivery "$LAB_USER"  "$token_c"; check "B1: alias '${LAB_ALIAS}' reaches ${LAB_USER}" $?
    wait_for_delivery "$TEAM_USER" "$token_c"; check "B2: alias '${LAB_ALIAS}' reaches ${TEAM_USER}" $?

    depth="$(queue_depth)"
    [ "$depth" -eq 0 ]; check "D1: the mail queue is empty (currently ${depth} message(s))" $?

    hr
    if [ "$FAILED" -eq 0 ]; then
        printf '%sALL CHECKS PASSED%s — the relay delivers, the alias resolves and the forward keeps a local copy.\n' "$C_GRN" "$C_OFF"
        printf 'Bonus, for the exam: state the queue-inspection command for exim, sendmail and qmail.\n'
        return 0
    fi
    printf '%s%d CHECK(S) FAILED%s — re-read the mail log for the probe tokens %s / %s / %s\n' \
        "$C_RED" "$FAILED" "$C_OFF" "$token_a" "$token_b" "$token_c"
    printf 'Queue right now:\n'; mailq | head -n 20
    return 1
}

# ---------------------------------------------------------------- RESTORE ----
cmd_restore() {
    need_root; detect_os; MYHOST="$(fqdn_of_host)"
    local dir="${BACKUP_ROOT}/latest"
    [ -d "$dir" ] || die "no snapshot found under ${BACKUP_ROOT}; nothing to restore"
    warn "restoring the baseline and DELETING every message currently queued"
    cp -a "${dir}/main.cf"   /etc/postfix/main.cf
    cp -a "${dir}/master.cf" /etc/postfix/master.cf
    cp -a "${dir}/aliases"   /etc/aliases
    newaliases
    local u home
    for u in "$LAB_USER" "$TEAM_USER"; do
        home="$(getent passwd "$u" | cut -d: -f6 || true)"
        [ -n "$home" ] || continue
        if [ -f "${dir}/forward.${u}" ]; then
            cp -a "${dir}/forward.${u}" "${home}/.forward"
            chown "${u}:$(id -gn "$u")" "${home}/.forward"
        else
            rm -f "${home}/.forward"
        fi
    done
    systemctl reload postfix >/dev/null 2>&1 || postfix reload >/dev/null 2>&1 || true
    postsuper -d ALL >/dev/null 2>&1 || true
    ok "baseline restored from ${dir}"
}

cmd_purge() {
    need_root; detect_os; MYHOST="$(fqdn_of_host)"
    cmd_restore
    local u
    for u in "$LAB_USER" "$TEAM_USER"; do
        if id -u "$u" >/dev/null 2>&1; then
            log "removing lab user ${u} and their mailbox"
            userdel -r "$u" 2>/dev/null || userdel "$u" || true
            rm -f "$(postconf -h mail_spool_directory)/${u}" 2>/dev/null || true
        fi
    done
    sed -i "/^${LAB_ALIAS}:/d;/ops ticket #4711/d" /etc/aliases
    newaliases
    ok "lab purged"
}

usage() {
    sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'
}

# -------------------------------------------------------------------- main ---
SUBCMD=""
for arg in "$@"; do
    case "$arg" in
        --yes|-y)   ASSUME_YES=1 ;;
        --force)    FORCE=1 ;;
        -h|--help)  usage; exit 0 ;;
        break|verify|hints|restore|purge) SUBCMD="$arg" ;;
        *) die "unknown argument: $arg (try --help)" ;;
    esac
done
[ -n "$SUBCMD" ] || SUBCMD="break"

case "$SUBCMD" in
    break)   cmd_break ;;
    verify)  cmd_verify ;;
    hints)   cmd_hints ;;
    restore) cmd_restore ;;
    purge)   cmd_purge ;;
esac
