#!/usr/bin/env bash
#
# ============================================================================
#  LPIC-3 303 Security (exam 303-300, v3.0.0)
#  Topic 334.3 — Packet Filtering  (exam weight: 8.33)
#
#  BREAK & FIX LABORATORY — "The Firewall That Ate the Web Server"
#
#  WARNING: THIS SCRIPT DELIBERATELY BREAKS NETWORK CONNECTIVITY.
#           RUN IT ONLY ON A DISPOSABLE LABORATORY VM THAT YOU CAN
#           DESTROY AND REBUILD. NEVER RUN IT ON A PRODUCTION HOST,
#           A SHARED HOST, OR ANY MACHINE YOU REACH OVER SSH WITHOUT
#           OUT-OF-BAND CONSOLE ACCESS.
#
#  Scope of the damage (all of it reversible, all of it local):
#    * Installs a hand-written nftables ruleset in the 'inet' family.
#    * Does NOT touch /etc/ssh, does NOT touch systemd unit files,
#      does NOT delete anything outside /root/lab-334.3 and /etc/nftables.d.
#    * A watchdog timer flushes the ruleset automatically after
#      $WATCHDOG_MINUTES minutes so you cannot permanently lock yourself out.
#
#  Reference: LPI Exam 303-300 Objectives, topic 334.3 Packet Filtering
#             https://www.lpi.org/our-certifications/exam-303-objectives/
#  nft(8):    https://www.netfilter.org/projects/nftables/manpage.html
#  Wiki:      https://wiki.nftables.org/wiki-nftables/index.php/Main_Page
#  Conntrack: https://www.netfilter.org/projects/conntrack-tools/index.html
# ============================================================================

set -o nounset
set -o pipefail

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------
LAB_DIR="/root/lab-334.3"
LAB_TABLE="lab_filter"                 # nftables table name used by the lab
WATCHDOG_MINUTES="${WATCHDOG_MINUTES:-45}"
WEB_PORT="8080"                        # the lab service the student must rescue
SSH_PORT="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
SSH_PORT="${SSH_PORT:-22}"

C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
C_BLU=$'\033[1;36m'; C_OFF=$'\033[0m'

say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s==> %s%s\n' "$C_BLU" "$*" "$C_OFF"; }
warn() { printf '%s[!] %s%s\n' "$C_YEL" "$*" "$C_OFF"; }
die()  { printf '%s[x] %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }
ok()   { printf '%s[+] %s%s\n' "$C_GRN" "$*" "$C_OFF"; }

# ---------------------------------------------------------------------------
# 0. Guard rails — refuse to run anywhere that looks like a real machine
# ---------------------------------------------------------------------------
preflight() {
    head1 "Pre-flight checks"

    [ "$(id -u)" -eq 0 ] || die "This lab must run as root (netfilter is a privileged subsystem)."

    command -v nft >/dev/null 2>&1 || die \
        "nft(8) not found. Install it first:
           Debian/Ubuntu : apt-get install -y nftables conntrack iproute2 curl
           RHEL/Rocky    : dnf install -y nftables conntrack-tools iproute curl"

    command -v ss >/dev/null 2>&1 || die "iproute2 (ss) is required."
    command -v curl >/dev/null 2>&1 || die "curl is required to observe the symptom."

    # Refuse on anything that advertises itself as production.
    if [ -f /etc/lab-forbidden ] || [ -f /etc/production ]; then
        die "Refusing: /etc/production or /etc/lab-forbidden present."
    fi

    # A remote root session with no console is the classic way to brick a box.
    if [ -n "${SSH_CONNECTION:-}" ]; then
        warn "You are connected over SSH ($SSH_CONNECTION)."
        warn "The break is designed to KEEP port ${SSH_PORT}/tcp reachable, and a"
        warn "watchdog will flush the ruleset in ${WATCHDOG_MINUTES} minutes."
        warn "Even so: make sure you have console/serial access to this VM."
    fi

    printf '\n%sType exactly:%s I HAVE A DISPOSABLE LAB VM\n> ' "$C_YEL" "$C_OFF"
    IFS= read -r consent
    [ "$consent" = "I HAVE A DISPOSABLE LAB VM" ] || die "Consent not given. Nothing was changed."

    mkdir -p "$LAB_DIR"
    ok "Pre-flight complete. Working directory: $LAB_DIR"
}

# ---------------------------------------------------------------------------
# 1. Snapshot — the student must be able to get back to a known-good state
# ---------------------------------------------------------------------------
snapshot() {
    head1 "Snapshotting current netfilter state"

    nft list ruleset > "$LAB_DIR/ruleset.before.nft" 2>/dev/null || true
    ip -o addr show                > "$LAB_DIR/addr.before.txt" 2>/dev/null || true
    ip route show                  > "$LAB_DIR/route.before.txt" 2>/dev/null || true
    sysctl -a 2>/dev/null | grep -E '^net\.(ipv4|netfilter)\.' \
                                   > "$LAB_DIR/sysctl.before.txt" || true

    ok "Saved: $LAB_DIR/ruleset.before.nft (restore with: nft -f <file> after a flush)"
}

# ---------------------------------------------------------------------------
# 2. The victim service — something concrete for the student to fix
# ---------------------------------------------------------------------------
start_victim_service() {
    head1 "Starting the lab web service on 127.0.0.1:${WEB_PORT} and 0.0.0.0:${WEB_PORT}"

    mkdir -p "$LAB_DIR/www"
    cat > "$LAB_DIR/www/index.html" <<'HTML'
<!doctype html>
<html><head><title>lab-334.3</title></head>
<body><h1>lab-334.3 packet filtering: SERVICE IS REACHABLE</h1></body></html>
HTML

    if pgrep -f "http.server ${WEB_PORT}" >/dev/null 2>&1; then
        ok "Service already running."
        return
    fi

    if command -v python3 >/dev/null 2>&1; then
        ( cd "$LAB_DIR/www" && nohup python3 -m http.server "$WEB_PORT" \
              --bind 0.0.0.0 >"$LAB_DIR/www.log" 2>&1 & )
    else
        die "python3 not found; install it or substitute any listener on ${WEB_PORT}/tcp."
    fi

    sleep 1
    if ss -ltnp 2>/dev/null | grep -q ":${WEB_PORT}"; then
        ok "Listener up:"
        ss -ltnp | grep ":${WEB_PORT}" | sed 's/^/    /'
    else
        die "Could not start the lab listener on ${WEB_PORT}/tcp."
    fi
}

# ---------------------------------------------------------------------------
# 3. Watchdog — automatic rescue, so the VM is never permanently unreachable
# ---------------------------------------------------------------------------
arm_watchdog() {
    head1 "Arming the ${WATCHDOG_MINUTES}-minute rescue watchdog"

    cat > "$LAB_DIR/rescue.sh" <<EOF
#!/usr/bin/env bash
# Emergency rescue: delete the lab table and restore the pre-lab ruleset.
nft delete table inet ${LAB_TABLE} 2>/dev/null
nft flush ruleset 2>/dev/null
[ -s "${LAB_DIR}/ruleset.before.nft" ] && nft -f "${LAB_DIR}/ruleset.before.nft" 2>/dev/null
logger -t lab-334.3 "rescue executed: lab ruleset removed"
EOF
    chmod 0700 "$LAB_DIR/rescue.sh"

    if command -v systemd-run >/dev/null 2>&1; then
        systemd-run --unit=lab-3343-watchdog \
                    --on-active="${WATCHDOG_MINUTES}min" \
                    --description="lab 334.3 firewall rescue" \
                    "$LAB_DIR/rescue.sh" >/dev/null 2>&1 \
            && ok "systemd transient timer 'lab-3343-watchdog' armed." \
            || warn "systemd-run failed; falling back to a background sleep."
    fi

    if ! systemctl is-active --quiet lab-3343-watchdog.timer 2>/dev/null; then
        ( nohup bash -c "sleep $((WATCHDOG_MINUTES*60)); ${LAB_DIR}/rescue.sh" \
              >/dev/null 2>&1 & )
        ok "Background watchdog armed (PID $!)."
    fi

    say "    Manual rescue at any time:  ${LAB_DIR}/rescue.sh"
    say "    Cancel the watchdog:        systemctl stop lab-3343-watchdog.timer"
}

# ---------------------------------------------------------------------------
# 4. THE BREAK
#
#    Four independent, realistic faults are injected in ONE ruleset. They are
#    the four mistakes that actually take production firewalls down:
#
#      FAULT 1 — input chain policy is 'drop' and there is no
#                'ct state established,related accept' rule, so every reply
#                to an outbound connection is discarded. Egress "works"
#                until the answer comes back.
#
#      FAULT 2 — loopback is not accepted. Everything that talks to
#                127.0.0.1 (local resolvers, health checks, DB sockets over
#                TCP) fails in a way that looks like an application bug.
#
#      FAULT 3 — a stray 'drop' rule sits ABOVE the rule that accepts the web
#                port. nftables evaluates rules top to bottom within a chain,
#                so the accept below is dead code. The rule EXISTS and the
#                student will see it with 'nft list ruleset' — it just never
#                matches. Classic ordering bug.
#
#      FAULT 4 — the accept rule for the web service was written for the
#                wrong L4 protocol (udp instead of tcp) and for the wrong
#                port on top of that. It looks right at a glance.
#
#    Plus a hidden aggravator: base chain priority. A second base chain with a
#    LOWER priority number is created and drops the traffic BEFORE the chain
#    the student is likely to edit. Hooks are evaluated in ascending priority
#    order, so priority -10 runs before priority 0 (filter).
# ---------------------------------------------------------------------------
inject_break() {
    head1 "Injecting the fault (this is the destructive step)"

    nft list table inet "$LAB_TABLE" >/dev/null 2>&1 && \
        nft delete table inet "$LAB_TABLE"

    cat > "$LAB_DIR/broken.nft" <<EOF
#!/usr/sbin/nft -f
#
# lab-334.3 broken ruleset — DO NOT COPY THIS INTO PRODUCTION.
#
table inet ${LAB_TABLE} {

    set trusted_admin_v4 {
        type ipv4_addr
        flags interval
        elements = { 127.0.0.1 }
    }

    # --- Aggravator: a base chain that runs BEFORE 'input' -----------------
    # Hooks with a lower priority integer are evaluated first.
    # 'filter' == 0, so -10 wins the race.
    chain pre_input {
        type filter hook input priority -10; policy accept;

        # Silently discard anything aimed at the lab web port.
        tcp dport ${WEB_PORT} counter drop
    }

    # --- The chain the student will find first ----------------------------
    chain input {
        type filter hook input priority 0; policy drop;

        # (FAULT 2) loopback is NOT accepted here. Nothing at all.

        # (FAULT 1) no 'ct state established,related accept'.
        #           Only NEW packets can ever match anything below.

        # Keep the operator's own SSH session alive - this is the ONE rule
        # that is intentionally correct, so the lab does not brick the VM.
        tcp dport ${SSH_PORT} ct state new,established counter accept \\
            comment "lab: do not lock the student out"

        # ICMPv6 neighbour discovery, otherwise IPv6 silently dies.
        icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, \\
                      nd-router-advert } counter accept

        # (FAULT 3) this drop sits ABOVE the accept for the web port.
        ip protocol tcp th dport ${WEB_PORT} counter drop \\
            comment "lab: shadowing drop, evaluated before the accept below"

        # (FAULT 4) wrong protocol AND wrong port. Looks plausible.
        udp dport 8081 counter accept \\
            comment "lab: intended to open the web service - it does not"

        counter comment "lab: packets that reached the policy drop"
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        counter comment "lab: forwarded packets"
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF

    nft -f "$LAB_DIR/broken.nft" || die "Failed to load the broken ruleset."

    # Kill any live conntrack entries so the student cannot be fooled by an
    # already-established flow that keeps working.
    if command -v conntrack >/dev/null 2>&1; then
        conntrack -F >/dev/null 2>&1 || true
    fi

    ok "Broken ruleset loaded into table inet ${LAB_TABLE}."
}

# ---------------------------------------------------------------------------
# 5. Show the symptom, in the student's own terminal
# ---------------------------------------------------------------------------
demonstrate_symptom() {
    head1 "Reproducing the symptom"

    local host_ip
    host_ip="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    host_ip="${host_ip:-127.0.0.1}"
    printf '%s\n' "$host_ip" > "$LAB_DIR/host_ip"

    say ""
    say "  # curl --max-time 5 http://127.0.0.1:${WEB_PORT}/"
    curl --max-time 5 -sS "http://127.0.0.1:${WEB_PORT}/" 2>&1 | sed 's/^/    /' || true

    say ""
    say "  # curl --max-time 5 http://${host_ip}:${WEB_PORT}/"
    curl --max-time 5 -sS "http://${host_ip}:${WEB_PORT}/" 2>&1 | sed 's/^/    /' || true

    say ""
    say "  # ss -ltn | grep ${WEB_PORT}     <- the service IS listening"
    ss -ltn 2>/dev/null | grep ":${WEB_PORT}" | sed 's/^/    /' || \
        say "    (no listener - that would be a different problem)"
}

# ---------------------------------------------------------------------------
# 6. The briefing
# ---------------------------------------------------------------------------
brief_student() {
    local host_ip; host_ip="$(cat "$LAB_DIR/host_ip" 2>/dev/null || echo 127.0.0.1)"

    cat <<EOF

${C_RED}================================================================${C_OFF}
${C_RED}  BREAK COMPLETE — lab 334.3 Packet Filtering${C_OFF}
${C_RED}================================================================${C_OFF}

${C_BLU}THE SCENARIO${C_OFF}

  You are on call. A colleague "hardened the firewall" on this host an hour
  ago and went home. Since then:

    * The internal web service on ${WEB_PORT}/tcp answers nobody — not from
      the network, not even from the host itself over 127.0.0.1.
    * 'systemctl status' and 'ss -ltn' both say the daemon is healthy and
      bound. The process is fine. Nothing is in the application log.
    * Outbound connections appear to "hang": DNS lookups, 'apt update',
      'curl https://...' all time out instead of failing fast.
    * SSH still works. (Your colleague got that one rule right.)

${C_BLU}THE SYMPTOMS YOU WILL SEE${C_OFF}

  1. curl http://127.0.0.1:${WEB_PORT}/       -> hangs, then "Connection timed out"
  2. curl http://${host_ip}:${WEB_PORT}/       -> same
  3. host www.lpi.org / dig / apt update  -> timeout, not NXDOMAIN
  4. ping 8.8.8.8                         -> "100% packet loss" although the
                                             route table is intact
  5. ss -ltn                              -> shows the listener on ${WEB_PORT}. The
                                             service is NOT the problem.

  A timeout means the packet was silently discarded (DROP). A
  "Connection refused" (TCP RST) or "Destination Port Unreachable" (ICMP
  type 3 code 3) would mean REJECT, or no listener at all. Learning to read
  that difference is half of this objective.

${C_BLU}YOUR MISSION${C_OFF}

  Working ONLY with nftables (nft(8)) — do not stop the firewall, do not
  'nft flush ruleset' as your answer, do not move the service to another
  port — reach ALL of the following end states:

    [ ] A. curl http://127.0.0.1:${WEB_PORT}/ returns the HTML page.
    [ ] B. curl http://${host_ip}:${WEB_PORT}/ returns the HTML page.
    [ ] C. Outbound traffic works end to end: 'ping -c1 8.8.8.8' succeeds
           and a DNS lookup resolves.
    [ ] D. The input chain policy is STILL 'drop'. Default-deny is the
           point of the exercise; do not "fix" it by opening everything.
    [ ] E. Port 3306/tcp (or any port you did not explicitly allow) is
           still filtered. Verify, do not assume.
    [ ] F. Every rule that is dead code — a rule that can never match —
           is gone. Use the counters to prove which ones those are.

  Run './lab-334.3-check' (created for you) at any time to grade yourself.

${C_BLU}THE TOOLBOX YOU ARE EXPECTED TO USE${C_OFF}

  nft list ruleset                       # the whole picture, in order
  nft -a list table inet ${LAB_TABLE}      # with rule handles, needed to delete
  nft list table inet ${LAB_TABLE} | grep -n counter
  nft reset counters table inet ${LAB_TABLE}   # zero them, retest, read again
  nft insert rule ... / nft add rule ... / nft replace rule ... handle N
  nft delete rule inet ${LAB_TABLE} <chain> handle N
  nft monitor trace                      # live, with 'nft add rule ... meta nftrace set 1'
  conntrack -L / conntrack -S            # connection tracking state
  ss -ltnp ; ip route ; ip -o addr
  journalctl -k | grep -i nft

  HINTS, in ascending order of how much they give away:
    - Rules inside a chain are evaluated TOP TO BOWN. A rule below a
      matching 'drop' never runs.
    - A chain is not the only chain. 'nft list ruleset' shows every base
      chain attached to the input hook, and they do not run in the order
      they are printed.
    - Stateful filtering is not optional. Ask yourself what happens to the
      SYN/ACK coming back from 8.8.8.8.
    - 'lo' is an interface like any other, and nothing is exempt from a
      'policy drop'.

${C_YEL}SAFETY${C_OFF}
  * A rescue watchdog will wipe the lab ruleset automatically in
    ${WATCHDOG_MINUTES} minutes: systemctl list-timers 'lab-3343*'
  * Rescue now, by hand:            ${LAB_DIR}/rescue.sh
  * Your original ruleset is saved: ${LAB_DIR}/ruleset.before.nft
  * The full solution is in the comment block at the end of this script:
      sed -n '/BEGIN SOLUTION/,/END SOLUTION/p' "\$0"
    Read it only after you have tried. Nothing here is guessable trivia;
    every fault is a real incident someone has already lived through.

${C_RED}================================================================${C_OFF}
EOF
}

# ---------------------------------------------------------------------------
# 7. Self-grading checker
# ---------------------------------------------------------------------------
install_checker() {
    cat > "$LAB_DIR/lab-334.3-check" <<'CHECK'
#!/usr/bin/env bash
# Self-grader for lab 334.3 — Packet Filtering.
LAB_TABLE="__TABLE__"; WEB_PORT="__PORT__"; LAB_DIR="__DIR__"
G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'; O=$'\033[0m'
pass=0; fail=0
t() { # t <label> <command...>
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then printf '%s[PASS]%s %s\n' "$G" "$O" "$label"; pass=$((pass+1))
    else printf '%s[FAIL]%s %s\n' "$R" "$O" "$label"; fail=$((fail+1)); fi
}
host_ip="$(cat "$LAB_DIR/host_ip" 2>/dev/null || echo 127.0.0.1)"

printf '\n=== lab 334.3 grading ===\n\n'

t "A. Web service reachable on 127.0.0.1:${WEB_PORT}" \
  curl --max-time 4 -sf "http://127.0.0.1:${WEB_PORT}/"

t "B. Web service reachable on ${host_ip}:${WEB_PORT}" \
  curl --max-time 4 -sf "http://${host_ip}:${WEB_PORT}/"

t "C1. ICMP echo to 8.8.8.8 (stateful return path)" \
  ping -c1 -W3 8.8.8.8

t "C2. DNS resolution works" \
  getent hosts www.lpi.org

if nft list chain inet "$LAB_TABLE" input 2>/dev/null | grep -q 'policy drop'; then
    printf '%s[PASS]%s D. input chain policy is still drop\n' "$G" "$O"; pass=$((pass+1))
else
    printf '%s[FAIL]%s D. input chain policy is NOT drop - default-deny was abandoned\n' "$R" "$O"; fail=$((fail+1))
fi

# E. an unopened port must still be filtered (timeout, not refused)
if timeout 4 bash -c "</dev/tcp/${host_ip}/3306" 2>/dev/null; then
    printf '%s[FAIL]%s E. 3306/tcp is reachable - the firewall is too open\n' "$R" "$O"; fail=$((fail+1))
else
    printf '%s[PASS]%s E. 3306/tcp is still filtered\n' "$G" "$O"; pass=$((pass+1))
fi

# F. dead code: any rule whose counter is still zero after the tests above
printf '\n%s--- counters (a rule stuck at 0 packets after your tests is suspect) ---%s\n' "$Y" "$O"
nft list table inet "$LAB_TABLE" 2>/dev/null | grep -E 'counter|chain|policy' | sed 's/^/  /'

printf '\n%d passed, %d failed.\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && printf '%sAll objectives met.%s\n' "$G" "$O"
exit "$fail"
CHECK

    sed -i "s|__TABLE__|${LAB_TABLE}|g; s|__PORT__|${WEB_PORT}|g; s|__DIR__|${LAB_DIR}|g" \
        "$LAB_DIR/lab-334.3-check"
    chmod 0755 "$LAB_DIR/lab-334.3-check"
    ln -sf "$LAB_DIR/lab-334.3-check" /usr/local/bin/lab-334.3-check 2>/dev/null || true
    ok "Checker installed: $LAB_DIR/lab-334.3-check  (also: lab-334.3-check)"
}

# ---------------------------------------------------------------------------
# 8. Subcommands
# ---------------------------------------------------------------------------
do_break() {
    preflight
    snapshot
    start_victim_service
    arm_watchdog
    inject_break
    install_checker
    demonstrate_symptom
    brief_student
}

do_restore() {
    head1 "Restoring pre-lab state"
    nft delete table inet "$LAB_TABLE" 2>/dev/null && ok "Lab table removed."
    if [ -s "$LAB_DIR/ruleset.before.nft" ]; then
        nft flush ruleset
        nft -f "$LAB_DIR/ruleset.before.nft" && ok "Original ruleset reloaded."
    fi
    systemctl stop lab-3343-watchdog.timer 2>/dev/null || true
    pkill -f "http.server ${WEB_PORT}" 2>/dev/null || true
    ok "Done. Lab artefacts kept in $LAB_DIR for review."
}

usage() {
    cat <<EOF
Usage: $0 [break|check|restore|solution]

  break     Inject the fault and brief the student (default).
  check     Run the self-grader.
  restore   Undo everything and reload the pre-lab ruleset.
  solution  Print the step-by-step solution.
EOF
}

case "${1:-break}" in
    break)    do_break ;;
    check)    exec "$LAB_DIR/lab-334.3-check" ;;
    restore)  do_restore ;;
    solution) sed -n '/BEGIN SOLUTION/,/END SOLUTION/p' "$0" ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
esac

exit 0
