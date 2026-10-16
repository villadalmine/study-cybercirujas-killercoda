#!/usr/bin/env bash
#
# break_fix.sh — LPI DevOps Tools Engineer, exam 701-100 (version 2.0.0)
# Topic 704.3 — Log Management and Analysis  (exam weight 3.33)
#
# Objectives reference:
#   https://www.lpi.org/our-certifications/exam-701-objectives/
#
# What this script does
# ---------------------
# It builds a miniature centralized-logging pipeline on a throwaway VM:
#
#     lab-order-service (the "application")
#        |                                  \
#        | stdout/stderr                     \  RFC5424 over TCP/20514
#        v                                    v
#     systemd-journald                      rsyslog imtcp collector
#        (journalctl -u ...)                  -> /var/log/lab/central/orders.log
#                                                -> logrotate retention
#
# ...then it breaks that pipeline in three places, one per layer:
# collection (journald), transport (rsyslog), retention (logrotate).
# The student has to bring all three gates back to green.
#
# The worked solution is at the bottom of this file, commented out.
# Do not read it until you have burned at least one honest hour on the box.
#
# SAFETY / SCOPE
# --------------
# This script edits real system configuration: it disables journald storage
# for the WHOLE machine while the lab is running, and it restarts rsyslog and
# systemd-journald. Run it ONLY on a disposable lab VM you can throw away.
# Everything it creates is namespaced (lab-*, 99-lab-*) and `restore` removes
# it. It never touches /etc/rsyslog.conf, /etc/logrotate.conf or
# /etc/systemd/journald.conf — only drop-ins and files it owns.
#
# Usage:
#   sudo ./break_fix.sh            # build the scenario and inject the faults
#   sudo ./break_fix.sh verify     # grade the three gates (takes ~35 s)
#   sudo ./break_fix.sh restore    # remove everything this script created
#   sudo ./break_fix.sh help
#
# The guard requires either /etc/teach-plat-lab to exist, or
# LAB_I_UNDERSTAND=yes in the environment.

set -euo pipefail

LAB_TOPIC="704.3"
LAB_UNIT="lab-order-service"
LAB_BIN="/usr/local/bin/lab-order-service"
LAB_UNIT_FILE="/etc/systemd/system/${LAB_UNIT}.service"
LAB_LOGDIR="/var/log/lab"
LAB_CENTRAL_DIR="${LAB_LOGDIR}/central"
LAB_LOGFILE="${LAB_CENTRAL_DIR}/orders.log"
RSYSLOG_CONF="/etc/rsyslog.d/60-lab-collector.conf"
LOGROTATE_CONF="/etc/logrotate.d/lab-app"
JOURNALD_DROPIN_DIR="/etc/systemd/journald.conf.d"
JOURNALD_DROPIN="${JOURNALD_DROPIN_DIR}/99-lab-logging.conf"
PORT_GOOD=20514          # SELinux labels 20514/tcp as syslogd_port_t
PORT_BAD=20515           # the fault
SENTINEL="/etc/teach-plat-lab"
LOG_GROUP="root"         # recomputed in preflight (adm where it exists)

c_red=''; c_grn=''; c_ylw=''; c_bld=''; c_off=''
if [[ -t 1 ]]; then
    c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'
    c_bld=$'\e[1m';  c_off=$'\e[0m'
fi

say()   { printf '%s\n' "$*"; }
head1() { printf '\n%s=== %s ===%s\n\n' "$c_bld" "$*" "$c_off"; }
step()  { printf '  %s->%s %s\n' "$c_bld" "$c_off" "$*"; }
pass()  { printf '%s[ PASS ]%s %s\n' "$c_grn" "$c_off" "$*"; }
fail()  { printf '%s[ FAIL ]%s %s\n' "$c_red" "$c_off" "$*"; }
hint()  { printf '         %shint:%s %s\n' "$c_ylw" "$c_off" "$*"; }
note()  { printf '%s[ note ]%s %s\n' "$c_ylw" "$c_off" "$*"; }
die()   { printf '%s[ stop ]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

preflight() {
    [[ ${EUID} -eq 0 ]] || die "run me as root:  sudo $0 ${1:-break}"

    [[ -d /run/systemd/system ]] || \
        die "this lab needs systemd as PID 1 (journald, systemctl, units)."

    if [[ ! -e ${SENTINEL} && ${LAB_I_UNDERSTAND:-no} != "yes" ]]; then
        die "refusing to run: I cannot tell this is a disposable lab VM.
        This script disables journald storage for the whole machine and
        restarts rsyslog. If this box is expendable, mark it once with:
            sudo touch ${SENTINEL}
        or export LAB_I_UNDERSTAND=yes for a single run."
    fi

    command -v systemctl >/dev/null || die "systemctl not found."
    command -v logger    >/dev/null || die "logger not found (package util-linux)."
    command -v logrotate >/dev/null || \
        die "logrotate not found:  apt-get install -y logrotate  |  dnf install -y logrotate"
    command -v rsyslogd  >/dev/null || \
        die "rsyslog not found:  apt-get install -y rsyslog  |  dnf install -y rsyslog"

    local helptext
    helptext=$(logger --help 2>&1 || true)
    [[ ${helptext} == *--rfc5424* ]] || \
        die "this lab needs the util-linux logger (--rfc5424/--tcp). Yours is a different implementation."

    if getent group adm >/dev/null 2>&1; then
        LOG_GROUP="adm"
    fi
}

write_workload() {
    step "installing the workload: ${LAB_BIN}"
    cat >"${LAB_BIN}" <<'EMITTER'
#!/usr/bin/env bash
# Lab workload for LPI 701-100, topic 704.3.
#
# This is "the application". Treat it as code you do not own: it is the
# contract, not the problem. It logs the same event twice, on purpose:
#   1. to stdout/stderr, which systemd captures into the journal;
#   2. to the central collector as RFC5424 over TCP, which is what a real
#      service does when the aggregator is not on this host.
set -u

COLLECTOR_HOST="127.0.0.1"
COLLECTOR_PORT="20514"
TAG="order-service"

emit() {
    local prio="$1" line="$2"
    logger --tcp --server "${COLLECTOR_HOST}" --port "${COLLECTOR_PORT}" \
           --rfc5424=notq --tag "${TAG}" --priority "${prio}" -- "${line}" \
        || printf 'WARN collector %s:%s unreachable, event dropped\n' \
                  "${COLLECTOR_HOST}" "${COLLECTOR_PORT}" >&2
}

i=0
while :; do
    i=$(( i + 1 ))
    ts="$(date --iso-8601=seconds)"
    line="ts=${ts} order_id=${i} customer=cust-$(( (i % 13) + 1 )) amount=$(( (i * 7) % 400 + 20 )).00 status=accepted"
    printf '%s\n' "${line}"
    emit local3.info "${line}"

    if (( i % 9 == 0 )); then
        bad="ts=${ts} order_id=${i} status=failed reason=payment_gateway_timeout latency_ms=$(( 3000 + (i % 500) ))"
        printf '%s\n' "${bad}" >&2
        emit local3.err "${bad}"
    fi
    sleep 1
done
EMITTER
    chmod 0755 "${LAB_BIN}"

    step "installing the unit: ${LAB_UNIT_FILE}"
    cat >"${LAB_UNIT_FILE}" <<UNIT
[Unit]
Description=Lab order service (log source for topic ${LAB_TOPIC})
Documentation=https://www.lpi.org/our-certifications/exam-701-objectives/
After=network.target rsyslog.service

[Service]
Type=simple
ExecStart=${LAB_BIN}
Restart=always
RestartSec=2
SyslogIdentifier=${LAB_UNIT}

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now "${LAB_UNIT}" >/dev/null 2>&1
}

write_collector() {
    step "installing the rsyslog collector: ${RSYSLOG_CONF}"
    install -d -m 0755 "${LAB_CENTRAL_DIR}"
    cat >"${RSYSLOG_CONF}" <<COLLECTOR
# Lab collector for LPI 701-100, topic ${LAB_TOPIC}.
# Receives RFC5424 events over TCP from the order service and lands them in a
# single file, which is exactly the shape a Filebeat/Logstash file input would
# harvest downstream.
module(load="imtcp")

template(name="lab_orders" type="string"
         string="%TIMESTAMP:::date-rfc3339% %HOSTNAME% %syslogtag% %msg:::drop-last-lf%\\n")

ruleset(name="lab_orders_rs") {
    action(type="omfile"
           file="${LAB_LOGFILE}"
           template="lab_orders")
    stop
}

input(type="imtcp" port="${PORT_BAD}" ruleset="lab_orders_rs")
COLLECTOR
    chmod 0644 "${RSYSLOG_CONF}"
    systemctl restart rsyslog
}

write_retention() {
    step "installing the retention policy: ${LOGROTATE_CONF}"
    cat >"${LOGROTATE_CONF}" <<ROTATE
${LAB_LOGFILE} {
    size 64k
    rotate 5
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root ${LOG_GROUP}
}
ROTATE
    # FAULT 3: a file mode logrotate will not touch.
    chmod 0666 "${LOGROTATE_CONF}"
}

break_journald() {
    step "adjusting journald: ${JOURNALD_DROPIN}"
    install -d -m 0755 "${JOURNALD_DROPIN_DIR}"
    # FAULT 1: storage off, plus a rate limit tight enough to shred what is left.
    cat >"${JOURNALD_DROPIN}" <<'JOURNALD'
# Lab drop-in for topic 704.3.
[Journal]
Storage=none
RateLimitIntervalSec=60s
RateLimitBurst=2
JOURNALD
    chmod 0644 "${JOURNALD_DROPIN}"
    systemctl restart systemd-journald
    systemctl restart "${LAB_UNIT}"
}

show_broken_state() {
    head1 "current state of the box"
    say "\$ systemctl is-active ${LAB_UNIT}"
    say "  $(systemctl is-active "${LAB_UNIT}" 2>/dev/null || true)"
    say ""
    say "\$ journalctl -u ${LAB_UNIT} -n 3 --no-pager -o cat"
    journalctl -u "${LAB_UNIT}" -n 3 --no-pager -o cat 2>/dev/null | sed 's/^/  /' || true
    say ""
    if command -v ss >/dev/null; then
        say "\$ ss -lntp | grep -E ':(2051[0-9])'"
        ss -lntp 2>/dev/null | grep -E ':(2051[0-9])' | sed 's/^/  /' || say "  (nothing)"
        say ""
    fi
    say "\$ ls -l ${LAB_CENTRAL_DIR}"
    ls -l "${LAB_CENTRAL_DIR}" 2>/dev/null | sed 's/^/  /' || say "  (empty)"
}

briefing() {
    head1 "Topic ${LAB_TOPIC} — Log Management and Analysis :: break & fix"

    cat <<BRIEF
THE STORY

  The payments team ships ${LAB_UNIT}. It logs every order twice: once to
  stdout (systemd picks that up) and once as RFC5424 over TCP to the host's
  rsyslog collector, which writes ${LAB_LOGFILE}. That
  file is the tail-point for the aggregator downstream — the place a Filebeat
  or Logstash file input would harvest from.

  Someone "hardened" the box last night. This morning the on-call engineer
  has no logs at all, and the disk is quietly filling.

THE SYMPTOMS YOU WILL SEE

  1. The service is running — 'systemctl is-active ${LAB_UNIT}' says active —
     but 'journalctl -u ${LAB_UNIT}' shows nothing, or a couple of lines and
     then silence. 'systemctl status' shows no recent output either.
  2. ${LAB_LOGFILE} never appears, or never grows.
  3. Once logs do flow, the file grows without bound: no .1, no .gz, ever.

YOUR OBJECTIVE — three gates, in this order. They chain: gate 1 gives you the
evidence you need for gate 2.

  GATE 1  COLLECTION.  'journalctl -u ${LAB_UNIT}' must show a steady stream,
          roughly one line per second, and it must survive a reboot.
  GATE 2  TRANSPORT.   ${LAB_LOGFILE} must exist and grow,
          one formatted line per order, tagged order-service.
  GATE 3  RETENTION.   logrotate must actually rotate that file — AND the live
          file must keep receiving events after a rotation. A rotation that
          leaves you writing into orders.log.1 forever is not a fix.

  Grade yourself at any time:   sudo $0 verify

GROUND RULES

  - Do not edit ${LAB_BIN} or its unit file. The application is
    the contract; the platform is what is broken.
  - Fix configuration, then make the daemon load it. Editing a file is not
    applying it.
  - Everything you need is in: ${JOURNALD_DROPIN_DIR}/,
    ${RSYSLOG_CONF}, ${LOGROTATE_CONF}.

TOOLBOX WORTH REACHING FOR

  systemd-analyze cat-config systemd/journald.conf     # the merged, effective config
  journalctl -u ${LAB_UNIT} -f -o short-precise
  journalctl --disk-usage ; journalctl --verify
  systemctl status systemd-journald rsyslog
  rsyslogd -N1                                         # config syntax check, no restart
  ss -lntp | grep rsyslog
  logrotate -d /etc/logrotate.conf                     # dry run: says what it IGNORES and why
  lsof -p "\$(pidof rsyslogd)" | grep /var/log/lab      # which inode is rsyslog holding open?
  stat -c '%a %U:%G %n' ${LOGROTATE_CONF}

  When you are done, clean the box:   sudo $0 restore
BRIEF
}

do_break() {
    head1 "building the scenario (topic ${LAB_TOPIC})"
    write_workload
    write_collector
    write_retention
    break_journald
    step "letting the workload run for a few seconds"
    sleep 6
    show_broken_state
    briefing
}

gate_collection() {
    local mark count storage rc=0
    printf '%sGATE 1 — collection (journald)%s\n' "${c_bld}" "${c_off}"

    if ! systemctl is-active --quiet "${LAB_UNIT}"; then
        fail "${LAB_UNIT} is not running; start it before grading."
        hint "systemctl start ${LAB_UNIT}"
        return 1
    fi

    mark=$(date '+%Y-%m-%d %H:%M:%S')
    printf '         sampling the journal for 12 s ...\n'
    sleep 12
    count=$(journalctl -u "${LAB_UNIT}" --since "${mark}" -o cat -q 2>/dev/null \
            | grep -c 'order_id=' || true)

    if (( count >= 8 )); then
        pass "journal captured ${count} events in 12 s"
    else
        rc=1
        fail "journal captured only ${count} events in 12 s (expected >= 8)"
        hint "the service emits one line per second — so either journald is storing nothing, or it is rate-limiting the unit."
        if journalctl --since "${mark}" --no-pager -q 2>/dev/null | grep -qi 'suppress'; then
            hint "journald is logging a suppression message. Look at RateLimitIntervalSec= / RateLimitBurst=."
        fi
    fi

    storage=""
    if command -v systemd-analyze >/dev/null; then
        storage=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null \
                  | grep -E '^[[:space:]]*Storage=' | tail -n1 | cut -d= -f2- || true)
    fi
    if [[ ${storage} == "none" ]]; then
        rc=1
        fail "effective journald Storage=none — the journal is a black hole"
        hint "systemd-analyze cat-config systemd/journald.conf   shows which drop-in wins"
    elif [[ -d /var/log/journal ]]; then
        pass "journal storage is persistent (/var/log/journal exists)"
    else
        rc=1
        fail "no /var/log/journal — the journal will not survive a reboot"
        hint "Storage=persistent, then restart systemd-journald"
    fi
    return ${rc}
}

gate_transport() {
    local before after rc=0
    printf '\n%sGATE 2 — transport (rsyslog collector)%s\n' "${c_bld}" "${c_off}"

    if command -v ss >/dev/null; then
        if ss -lnt 2>/dev/null | grep -q ":${PORT_GOOD}[[:space:]]"; then
            pass "something is listening on tcp/${PORT_GOOD}"
        else
            rc=1
            fail "nothing is listening on tcp/${PORT_GOOD}"
            hint "the application hard-codes that port; read ${LAB_BIN} and make the collector agree"
            hint "ss -lntp | grep rsyslog   and   rsyslogd -N1"
        fi
    fi

    if [[ ! -f ${LAB_LOGFILE} ]]; then
        fail "${LAB_LOGFILE} does not exist"
        hint "journalctl -u ${LAB_UNIT} | grep -i 'refused\\|unreachable'  — the client is telling you the port"
        return 1
    fi

    before=$(stat -c %s "${LAB_LOGFILE}")
    printf '         watching the collector file for 10 s ...\n'
    sleep 10
    after=$(stat -c %s "${LAB_LOGFILE}")

    if (( after > before )); then
        pass "collector file grew by $(( after - before )) bytes in 10 s"
    else
        rc=1
        fail "collector file did not grow (still ${after} bytes)"
        hint "is rsyslog bound to the right port, and is the ruleset attached to that input?"
    fi

    if tail -n 20 "${LAB_LOGFILE}" 2>/dev/null | grep -q 'order-service.*order_id='; then
        pass "events are tagged order-service and carry the order payload"
    else
        rc=1
        fail "the last lines do not look like order events"
        hint "check the template= on the omfile action and the ruleset= on the input"
    fi
    return ${rc}
}

gate_retention() {
    local mode rc=0 dbg live
    printf '\n%sGATE 3 — retention (logrotate)%s\n' "${c_bld}" "${c_off}"

    if [[ ! -f ${LOGROTATE_CONF} ]]; then
        fail "${LOGROTATE_CONF} is gone; the file must exist and be honoured"
        return 1
    fi

    mode=$(stat -c %a "${LOGROTATE_CONF}")
    if (( 8#${mode} & 8#22 )); then
        rc=1
        fail "${LOGROTATE_CONF} is mode ${mode} — group/world writable"
        hint "logrotate silently skips configs anyone could edit; 'logrotate -d /etc/logrotate.conf' names the file it ignores"
    else
        pass "${LOGROTATE_CONF} is mode ${mode}"
    fi

    dbg=$(logrotate -d /etc/logrotate.conf 2>&1 || true)
    if grep -qi 'ignoring.*lab-app' <<<"${dbg}"; then
        rc=1
        fail "logrotate still ignores lab-app"
        grep -i 'ignoring.*lab-app' <<<"${dbg}" | head -n 2 | sed 's/^/         /'
    else
        pass "logrotate parses and accepts lab-app"
    fi

    [[ -f ${LAB_LOGFILE} ]] || { fail "no ${LAB_LOGFILE} to rotate — clear gate 2 first"; return 1; }

    printf '         forcing a rotation and watching the live file for 10 s ...\n'
    logrotate -f "${LOGROTATE_CONF}" >/dev/null 2>&1 || true
    sleep 10

    if compgen -G "${LAB_LOGFILE}.1*" >/dev/null; then
        pass "a rotated generation exists ($(basename "$(compgen -G "${LAB_LOGFILE}.1*" | head -n1)"))"
    else
        rc=1
        fail "no rotated file appeared after 'logrotate -f'"
    fi

    live=$(stat -c %s "${LAB_LOGFILE}" 2>/dev/null || echo 0)
    if (( live > 0 )); then
        pass "the live file is receiving events after rotation (${live} bytes)"
    else
        rc=1
        fail "the live file is empty ${live} bytes after rotation — rsyslog is still writing into the rotated inode"
        hint "lsof -p \$(pidof rsyslogd) | grep ${LAB_CENTRAL_DIR}"
        hint "rotation renames the file; the daemon keeps the old fd. Tell it to reopen (postrotate + HUP) or rotate by copytruncate."
    fi
    return ${rc}
}

do_verify() {
    local r1=0 r2=0 r3=0
    head1 "grading topic ${LAB_TOPIC} (this takes about 35 s)"
    gate_collection || r1=1
    gate_transport  || r2=1
    gate_retention  || r3=1

    head1 "result"
    if (( r1 + r2 + r3 == 0 )); then
        pass "all three gates green — collection, transport, retention"
        say ""
        say "Now answer these out loud before you move on:"
        say "  - Which drop-in was overriding journald, and how would you have found it"
        say "    without knowing where it lived?"
        say "  - Why does rsyslog need a signal after rotation, and when is copytruncate"
        say "    the wrong answer (hint: what does a file-tailing shipper do with inodes)?"
        say "  - Where would a Logstash grok/dissect filter sit in this pipeline, and what"
        say "    would it key on in these lines?"
        say ""
        say "Clean the box:  sudo $0 restore"
        return 0
    fi
    fail "$(( r1 + r2 + r3 )) of 3 gates still failing — keep going"
    say ""
    say "Read the symptoms again, not the config. The config is where you look last."
    return 1
}

do_restore() {
    head1 "restoring the box"
    systemctl disable --now "${LAB_UNIT}" >/dev/null 2>&1 || true
    rm -f "${LAB_UNIT_FILE}" "${LAB_BIN}"
    systemctl daemon-reload
    step "removed the workload unit and binary"

    rm -f "${RSYSLOG_CONF}" "${LOGROTATE_CONF}" "${JOURNALD_DROPIN}"
    step "removed ${RSYSLOG_CONF}, ${LOGROTATE_CONF}, ${JOURNALD_DROPIN}"

    if [[ ${LAB_LOGDIR} == "/var/log/lab" && -d ${LAB_LOGDIR} ]]; then
        rm -rf "${LAB_LOGDIR}"
        step "removed ${LAB_LOGDIR}"
    fi

    systemctl restart systemd-journald || true
    systemctl restart rsyslog || true
    step "restarted systemd-journald and rsyslog"

    note "journald storage is back to whatever your distro ships by default."
    note "verify with: systemd-analyze cat-config systemd/journald.conf | grep -i storage"
}

usage() {
    cat <<USAGE
break_fix.sh — topic ${LAB_TOPIC}, Log Management and Analysis (LPI 701-100)

  sudo $0 [break]     build the scenario and inject three faults (default)
  sudo $0 verify      grade the three gates
  sudo $0 restore     remove everything this script created
  sudo $0 help        this text

Disposable lab VM only. Requires systemd, rsyslog, logrotate and the
util-linux logger. Gate the guard with:  sudo touch ${SENTINEL}
USAGE
}

main() {
    local action="${1:-break}"
    case "${action}" in
        break)   preflight "${action}"; do_break ;;
        verify)  preflight "${action}"; do_verify ;;
        restore) preflight "${action}"; do_restore ;;
        help|-h|--help) usage ;;
        *) usage; die "unknown action: ${action}" ;;
    esac
}

main "$@"
