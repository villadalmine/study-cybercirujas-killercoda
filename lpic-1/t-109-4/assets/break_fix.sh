#!/usr/bin/env bash
#
# ==============================================================================
#  LPIC-1 (Exam 102-500) — Topic 109.4: Configure client side DNS
#  BREAK & FIX LABORATORY — Level: Production-grade troubleshooting
# ==============================================================================
#
#  WARNING: THIS SCRIPT INTENTIONALLY BREAKS NAME RESOLUTION ON THIS HOST.
#           RUN IT ONLY INSIDE A DISPOSABLE LABORATORY VM / CONTAINER THAT
#           YOU CAN DESTROY AND REBUILD. NEVER RUN IT ON A WORKSTATION,
#           A SERVER, OR ANYTHING YOU CARE ABOUT.
#
#  Exam objective 109.4 — Key knowledge areas:
#     /etc/hosts, /etc/resolv.conf, /etc/nsswitch.conf
#     host, dig, getent
#     systemd-resolved awareness (resolvectl, /run/systemd/resolve/*)
#
#  Official reference:
#     https://www.lpi.org/our-certifications/exam-102-objectives/
#     https://www.lpi.org/our-certifications/exam-101-objectives/
#     man 5 resolv.conf   |  man 5 hosts  |  man 5 nsswitch.conf
#     man 1 dig           |  man 1 host   |  man 1 getent
#     man 8 systemd-resolved | man 1 resolvectl
#
#  Design contract of this lab:
#     * Everything mutated is backed up first to a timestamped directory.
#     * Only client-side resolution is touched. Routing, interfaces, firewall
#       and packet forwarding are left untouched, so IP connectivity keeps
#       working — that asymmetry IS the diagnostic signal.
#     * A rollback script is written to disk. If the student gets stuck,
#       running it restores the machine without a reboot.
#
# ==============================================================================

set -o nounset
set -o pipefail

readonly LAB_ID="lpic1-109.4-clientdns"
readonly STAMP="$(date +%Y%m%d-%H%M%S)"
readonly LAB_ROOT="/var/tmp/${LAB_ID}"
readonly BACKUP_DIR="${LAB_ROOT}/backup-${STAMP}"
readonly STATE_FILE="${LAB_ROOT}/state.env"
readonly ROLLBACK="${LAB_ROOT}/rollback.sh"

# Targets of the breakage. Chosen because they are the three files the exam
# objective names explicitly, plus the systemd-resolved runtime layer that
# modern distributions stack on top of them.
readonly F_RESOLV="/etc/resolv.conf"
readonly F_HOSTS="/etc/hosts"
readonly F_NSSWITCH="/etc/nsswitch.conf"

# The victim name. RFC 2606 reserves .invalid / .test / .example for
# documentation and testing, so nothing here can ever collide with a real
# production zone.
readonly LAB_HOST="app.lab.example"
readonly LAB_IP="203.0.113.42"          # RFC 5737 TEST-NET-3
readonly BLACKHOLE_DNS="198.51.100.253" # RFC 5737 TEST-NET-2, unroutable

# ------------------------------------------------------------------------------
# Presentation helpers
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RST=$'\033[0m'; C_B=$'\033[1m'; C_R=$'\033[31m'
    C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'
else
    C_RST=''; C_B=''; C_R=''; C_G=''; C_Y=''; C_C=''
fi

say()   { printf '%s\n' "$*"; }
info()  { printf '%s[ .. ]%s %s\n' "$C_C" "$C_RST" "$*"; }
ok()    { printf '%s[ ok ]%s %s\n' "$C_G" "$C_RST" "$*"; }
warn()  { printf '%s[warn]%s %s\n' "$C_Y" "$C_RST" "$*"; }
die()   { printf '%s[fail]%s %s\n' "$C_R" "$C_RST" "$*" >&2; exit 1; }
rule()  { printf '%s%s%s\n' "$C_B" "$(printf '=%.0s' {1..78})" "$C_RST"; }
head1() { rule; printf '%s %s%s\n' "$C_B" "$*" "$C_RST"; rule; }

# ------------------------------------------------------------------------------
# Guard rails
# ------------------------------------------------------------------------------
require_root() {
    [[ "${EUID}" -eq 0 ]] || die "This lab must run as root (sudo $0 break)."
}

confirm_disposable_vm() {
    if [[ "${LAB_FORCE:-0}" == "1" ]]; then
        warn "LAB_FORCE=1 — skipping the interactive confirmation."
        return 0
    fi

    head1 "DESTRUCTIVE LABORATORY — CONFIRMATION REQUIRED"
    say "Hostname : $(hostname -f 2>/dev/null || hostname)"
    say "Kernel   : $(uname -sr)"
    say "Distro   : $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
    say ""
    say "This script will deliberately destroy client-side name resolution on"
    say "THIS machine. IP connectivity will keep working; only DNS will fail."
    say ""
    say "Type exactly: ${C_B}I UNDERSTAND THIS IS A DISPOSABLE LAB VM${C_RST}"
    printf '> '
    local answer
    IFS= read -r answer || true
    [[ "${answer}" == "I UNDERSTAND THIS IS A DISPOSABLE LAB VM" ]] \
        || die "Confirmation not given. Nothing was modified."
}

# ------------------------------------------------------------------------------
# Backup / rollback machinery
# ------------------------------------------------------------------------------
backup_file() {
    local src="$1"
    local dst="${BACKUP_DIR}${src//\//__}"

    if [[ -L "${src}" ]]; then
        # Preserve the fact that it WAS a symlink and where it pointed.
        # On systemd-resolved hosts /etc/resolv.conf is normally a symlink to
        # /run/systemd/resolve/stub-resolv.conf — losing that detail is the
        # single most common way students "fix" the lab into a worse state.
        readlink "${src}" > "${dst}.symlink-target"
        printf 'symlink\n' > "${dst}.kind"
        info "Backed up symlink ${src} -> $(readlink "${src}")"
    elif [[ -e "${src}" ]]; then
        cp -a -- "${src}" "${dst}"
        printf 'regular\n' > "${dst}.kind"
        info "Backed up regular file ${src}"
    else
        printf 'absent\n' > "${dst}.kind"
        warn "${src} does not exist; recorded as absent"
    fi
}

write_rollback_script() {
    cat > "${ROLLBACK}" <<ROLLBACK_EOF
#!/usr/bin/env bash
# Auto-generated rollback for ${LAB_ID} (snapshot ${STAMP}).
# Restores /etc/resolv.conf, /etc/hosts and /etc/nsswitch.conf exactly as they
# were — including whether /etc/resolv.conf was a symlink — and restarts
# systemd-resolved if it was running when the lab started.
set -o nounset -o pipefail
[[ "\${EUID}" -eq 0 ]] || { echo "run as root" >&2; exit 1; }

BACKUP_DIR="${BACKUP_DIR}"

restore() {
    local target="\$1"
    local base="\${BACKUP_DIR}\${target//\//__}"
    local kind
    kind="\$(cat "\${base}.kind" 2>/dev/null || echo missing)"

    case "\${kind}" in
        symlink)
            rm -f -- "\${target}"
            ln -s -- "\$(cat "\${base}.symlink-target")" "\${target}"
            echo "restored symlink \${target}"
            ;;
        regular)
            # chattr -i first: the lab may have set the immutable bit.
            chattr -i -- "\${target}" 2>/dev/null || true
            rm -f -- "\${target}"
            cp -a -- "\${base}" "\${target}"
            echo "restored file \${target}"
            ;;
        absent)
            chattr -i -- "\${target}" 2>/dev/null || true
            rm -f -- "\${target}"
            echo "removed \${target} (was absent before the lab)"
            ;;
        *)
            echo "no backup recorded for \${target}" >&2
            ;;
    esac
}

chattr -i /etc/resolv.conf 2>/dev/null || true
restore /etc/resolv.conf
restore /etc/hosts
restore /etc/nsswitch.conf

if [[ "${RESOLVED_WAS_ACTIVE:-no}" == "yes" ]]; then
    systemctl restart systemd-resolved 2>/dev/null || true
    echo "restarted systemd-resolved"
fi

echo "Rollback complete. Verify with: getent hosts www.lpi.org"
ROLLBACK_EOF
    chmod 0755 "${ROLLBACK}"
    ok "Rollback script written to ${ROLLBACK}"
}

# ------------------------------------------------------------------------------
# Environment probe — recorded so the FIX phase can grade fairly
# ------------------------------------------------------------------------------
probe_environment() {
    RESOLVED_WAS_ACTIVE="no"
    if command -v systemctl >/dev/null 2>&1 \
       && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        RESOLVED_WAS_ACTIVE="yes"
    fi

    RESOLV_WAS_SYMLINK="no"
    [[ -L "${F_RESOLV}" ]] && RESOLV_WAS_SYMLINK="yes"

    # Record a nameserver that actually worked before we broke anything, so the
    # student has a realistic target and the grader can tell "fixed" from
    # "lucky". Falls back to a well-known public resolver if none is parseable.
    ORIGINAL_NS="$(awk '/^[[:space:]]*nameserver/ {print $2; exit}' \
                     /run/systemd/resolve/resolv.conf "${F_RESOLV}" 2>/dev/null)"
    [[ -n "${ORIGINAL_NS}" && "${ORIGINAL_NS}" != "${BLACKHOLE_DNS}" ]] \
        || ORIGINAL_NS="1.1.1.1"

    DEFAULT_GW="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
    DEFAULT_GW="${DEFAULT_GW:-unknown}"

    mkdir -p "${LAB_ROOT}"
    {
        echo "LAB_ID=${LAB_ID}"
        echo "STAMP=${STAMP}"
        echo "BACKUP_DIR=${BACKUP_DIR}"
        echo "RESOLVED_WAS_ACTIVE=${RESOLVED_WAS_ACTIVE}"
        echo "RESOLV_WAS_SYMLINK=${RESOLV_WAS_SYMLINK}"
        echo "ORIGINAL_NS=${ORIGINAL_NS}"
        echo "DEFAULT_GW=${DEFAULT_GW}"
        echo "LAB_HOST=${LAB_HOST}"
        echo "LAB_IP=${LAB_IP}"
    } > "${STATE_FILE}"

    ok "Environment probed — systemd-resolved active: ${RESOLVED_WAS_ACTIVE}, /etc/resolv.conf symlink: ${RESOLV_WAS_SYMLINK}"
}

# ==============================================================================
#  THE BREAKAGE
# ==============================================================================
#  Four independent faults are injected. They are layered on purpose: fixing
#  only one of them still leaves the host broken, which forces the student to
#  reason about the RESOLUTION ORDER rather than pattern-match a single file.
#
#   FAULT 1 — nsswitch.conf: the `files` source is removed from the hosts line,
#             so /etc/hosts is never consulted by the NSS layer. `dig` still
#             works (it bypasses NSS entirely and talks to the resolver
#             directly), but `ping`, `curl`, `ssh` and `getent hosts` do not.
#             This dig/getent divergence is the single most instructive symptom
#             in the whole objective.
#
#   FAULT 2 — resolv.conf: every real nameserver is replaced with an unroutable
#             TEST-NET-2 address, and `options timeout:` is inflated so each
#             lookup hangs for many seconds before failing. Slow-then-fail, not
#             fast-fail, is what real broken DNS feels like.
#
#   FAULT 3 — resolv.conf: a bogus `search` domain is prepended and `ndots` is
#             raised, so even after the nameserver is fixed, short names get
#             mangled into wrong FQDNs. Teaches the search/ndots interaction.
#
#   FAULT 4 — hosts: the lab's static A record is present but points at the
#             wrong address, and the file is made immutable with chattr +i so
#             a naive `vim /etc/hosts` fails with "Operation not permitted".
#             Teaches lsattr/chattr as part of real diagnosis.
# ==============================================================================

break_nsswitch() {
    info "FAULT 1 — removing the 'files' source from the hosts line of ${F_NSSWITCH}"

    if [[ ! -f "${F_NSSWITCH}" ]]; then
        # Some minimal images ship without it; create one so the fault is real.
        printf 'passwd: files\ngroup: files\nshadow: files\nhosts: files dns\n' \
            > "${F_NSSWITCH}"
    fi

    # Rewrite ONLY the hosts: line. Everything else is left byte-identical.
    awk '
        /^[[:space:]]*hosts:/ {
            print "# LAB 109.4: original line preserved below, do not trust it blindly"
            print "#" $0
            print "hosts:      dns"
            next
        }
        { print }
    ' "${F_NSSWITCH}" > "${F_NSSWITCH}.lab-tmp"

    cat "${F_NSSWITCH}.lab-tmp" > "${F_NSSWITCH}"
    rm -f "${F_NSSWITCH}.lab-tmp"
    ok "FAULT 1 injected"
}

break_resolv() {
    info "FAULT 2+3 — pointing the resolver at a black hole and poisoning search/ndots"

    # If it is a symlink into /run, replace it with a real file. The student
    # must notice this and decide whether to restore the symlink or manage the
    # file directly — both are defensible, but only one survives a reboot on a
    # systemd-resolved host.
    if [[ -L "${F_RESOLV}" ]]; then
        rm -f -- "${F_RESOLV}"
    fi

    cat > "${F_RESOLV}" <<EOF
# Generated by ${LAB_ID} at ${STAMP} — THIS FILE IS DELIBERATELY WRONG.
search corp.invalid lab.invalid
options ndots:5 timeout:5 attempts:3
nameserver ${BLACKHOLE_DNS}
nameserver ${BLACKHOLE_DNS%.*}.254
EOF

    chmod 0644 "${F_RESOLV}"
    ok "FAULT 2+3 injected (nameserver ${BLACKHOLE_DNS}, ndots:5, timeout:5)"
}

break_hosts() {
    info "FAULT 4 — planting a wrong static record in ${F_HOSTS} and locking the file"

    # Keep the loopback entries: breaking 127.0.0.1 breaks sudo, journald and
    # half the userland, which teaches nothing and wastes the student's VM.
    if ! grep -qE '^[[:space:]]*127\.0\.0\.1' "${F_HOSTS}" 2>/dev/null; then
        printf '127.0.0.1\tlocalhost\n' >> "${F_HOSTS}"
    fi

    cat >> "${F_HOSTS}" <<EOF

# LAB 109.4 — static entry for the exercise. The address below is WRONG.
198.51.100.9	${LAB_HOST}	app
EOF

    # Immutable bit: editors and even root's redirection will be refused until
    # the student runs `chattr -i`. lsattr reveals it.
    if command -v chattr >/dev/null 2>&1; then
        chattr +i -- "${F_HOSTS}" 2>/dev/null \
            && ok "FAULT 4 injected (immutable bit set — lsattr will show 'i')" \
            || warn "FAULT 4 injected, but chattr +i is unsupported on this filesystem"
    else
        warn "chattr not available; FAULT 4 injected without the immutable bit"
    fi
}

neutralize_resolved_stub() {
    # If systemd-resolved is running it will happily keep answering on
    # 127.0.0.53 and mask the breakage. Stop it so /etc/resolv.conf is the real
    # authority for this exercise — and tell the student, because "why did my
    # resolver change back after a reboot?" is the follow-up lesson.
    if [[ "${RESOLVED_WAS_ACTIVE}" == "yes" ]]; then
        info "Stopping systemd-resolved so /etc/resolv.conf is authoritative for this lab"
        systemctl stop systemd-resolved 2>/dev/null || true
        ok "systemd-resolved stopped (it will return on reboot unless disabled)"
    fi
}

# ==============================================================================
#  BRIEFING
# ==============================================================================
print_briefing() {
    cat <<BRIEF

$(rule)
${C_B} LPIC-1 109.4 — INCIDENT BRIEFING${C_RST}
$(rule)

${C_B}SCENARIO${C_RST}

  You are on call. A single application server has stopped talking to every
  other system in the estate. The network team swears the link is fine, and
  they are right: the default gateway (${DEFAULT_GW}) answers ICMP, routes are
  intact, and raw IP traffic flows normally. Everything that needs a NAME is
  dead.

  A colleague "fixed some DNS settings" shortly before the pager went off.

${C_B}SYMPTOMS YOU WILL OBSERVE${C_RST}

  1. Any command that resolves a hostname hangs for roughly 15-30 seconds and
     then fails:

       \$ ping -c1 www.lpi.org
       ping: www.lpi.org: Temporary failure in name resolution

       \$ curl -sS https://www.lpi.org
       curl: (6) Could not resolve host: www.lpi.org

     The long pause before the error is a clue in itself. Instant failure and
     slow failure have different root causes.

  2. Raw IP still works. This proves the fault is in resolution, not in the
     network:

       \$ ping -c1 ${DEFAULT_GW}
       64 bytes from ${DEFAULT_GW}: icmp_seq=1 ttl=64 time=0.4 ms

  3. A static host that is written in /etc/hosts is STILL not resolvable
     through the normal system path, even though you can read the entry with
     your own eyes:

       \$ grep ${LAB_HOST} /etc/hosts
       198.51.100.9	${LAB_HOST}	app

       \$ getent hosts ${LAB_HOST}
       (no output, exit status 2)

     Understand why before you touch anything. Reading /etc/hosts with grep and
     resolving through /etc/hosts are two completely different operations.

  4. Editing /etc/hosts fails even as root:

       # echo "x" >> /etc/hosts
       bash: /etc/hosts: Operation not permitted

  5. dig and getent disagree. When they disagree, the difference tells you
     which layer is broken:

       \$ dig +short ${LAB_HOST}      -> times out / SERVFAIL
       \$ getent hosts ${LAB_HOST}    -> empty

${C_B}YOUR OBJECTIVE${C_RST}

  Restore correct client-side name resolution. Concretely, ALL of the following
  must be true when you are done:

    [ ] getent hosts ${LAB_HOST}  returns exactly  ${LAB_IP}
    [ ] getent hosts www.lpi.org  returns an address (public DNS works again)
    [ ] host www.lpi.org          answers in under 2 seconds, not 15
    [ ] ping -c1 ${LAB_HOST}      reaches ${LAB_IP} (or fails at the network
                                   layer — that address is unroutable by
                                   design — but it must RESOLVE)
    [ ] /etc/hosts is editable again by root
    [ ] No bogus search domain mangles short names any more

${C_B}RULES OF ENGAGEMENT${C_RST}

  * You may not reboot. Fix it live, the way you would at 03:00.
  * You may not install packages — DNS is broken, so you could not anyway.
    That constraint is the lesson.
  * Work top-down through the resolution path:
        application -> NSS (/etc/nsswitch.conf) -> files (/etc/hosts)
                                                -> dns (/etc/resolv.conf)
  * Useful instruments, all already installed on a standard system:
        getent hosts NAME         resolve THROUGH NSS (what apps really do)
        getent ahostsv4 NAME      same, IPv4 only, shows the socket type
        dig NAME / dig @SERVER    query DNS DIRECTLY, bypassing NSS
        dig +trace NAME           follow delegation from the root
        host NAME                 quick DNS-only lookup
        lsattr /etc/hosts         reveal file attributes such as immutable
        resolvectl status         systemd-resolved's view, if it is running
        cat /etc/resolv.conf      the classic resolver configuration
        strace -f -e trace=openat,connect getent hosts NAME
                                  watch exactly which files and sockets the
                                  resolver touches, in order

${C_B}SELF-CHECK${C_RST}

  Verify your work at any time with:

      sudo ${0} verify

${C_B}ESCAPE HATCH${C_RST}

  If you are stuck and want the machine back without a rebuild:

      sudo ${ROLLBACK}

  Backups of every file this lab touched are in:

      ${BACKUP_DIR}

$(rule)

BRIEF
}

# ==============================================================================
#  VERIFICATION / GRADING
# ==============================================================================
verify_lab() {
    [[ -f "${STATE_FILE}" ]] || die "No lab state found at ${STATE_FILE}. Run '$0 break' first."
    # shellcheck disable=SC1090
    . "${STATE_FILE}"

    head1 "LPIC-1 109.4 — VERIFICATION"
    local pass=0 fail=0

    check() {
        local label="$1" outcome="$2" detail="${3:-}"
        if [[ "${outcome}" == "pass" ]]; then
            printf '%s[PASS]%s %s\n' "$C_G" "$C_RST" "${label}"
            [[ -n "${detail}" ]] && printf '        %s\n' "${detail}"
            pass=$((pass + 1))
        else
            printf '%s[FAIL]%s %s\n' "$C_R" "$C_RST" "${label}"
            [[ -n "${detail}" ]] && printf '        %s\n' "${detail}"
            fail=$((fail + 1))
        fi
    }

    # --- 1. NSS must consult files again --------------------------------------
    if grep -qE '^[[:space:]]*hosts:.*\bfiles\b' "${F_NSSWITCH}" 2>/dev/null; then
        check "nsswitch.conf hosts line includes 'files'" pass \
              "$(grep -E '^[[:space:]]*hosts:' "${F_NSSWITCH}" | head -1)"
    else
        check "nsswitch.conf hosts line includes 'files'" fail \
              "current: $(grep -E '^[[:space:]]*hosts:' "${F_NSSWITCH}" 2>/dev/null | head -1)"
    fi

    # --- 2. Static entry resolves to the RIGHT address ------------------------
    local got
    got="$(getent hosts "${LAB_HOST}" 2>/dev/null | awk '{print $1; exit}')"
    if [[ "${got}" == "${LAB_IP}" ]]; then
        check "getent hosts ${LAB_HOST} -> ${LAB_IP}" pass
    else
        check "getent hosts ${LAB_HOST} -> ${LAB_IP}" fail \
              "got: ${got:-<no answer>}"
    fi

    # --- 3. /etc/hosts writable again ----------------------------------------
    if command -v lsattr >/dev/null 2>&1 \
       && lsattr -d "${F_HOSTS}" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
        check "/etc/hosts is no longer immutable" fail \
              "lsattr still shows the 'i' attribute — run: chattr -i /etc/hosts"
    else
        check "/etc/hosts is no longer immutable" pass
    fi

    # --- 4. No black-hole nameserver left ------------------------------------
    if grep -qE "^[[:space:]]*nameserver[[:space:]]+${BLACKHOLE_DNS%.*}\." \
             "${F_RESOLV}" 2>/dev/null; then
        check "resolv.conf no longer points at the black hole" fail \
              "still present: $(grep -E '^[[:space:]]*nameserver' "${F_RESOLV}" | tr '\n' ' ')"
    else
        check "resolv.conf no longer points at the black hole" pass \
              "$(grep -E '^[[:space:]]*nameserver' "${F_RESOLV}" 2>/dev/null | tr '\n' ' ' || echo 'via systemd-resolved')"
    fi

    # --- 5. Bogus search domain gone -----------------------------------------
    if grep -qE '^[[:space:]]*(search|domain).*\binvalid\b' "${F_RESOLV}" 2>/dev/null; then
        check "bogus .invalid search domain removed" fail \
              "$(grep -E '^[[:space:]]*(search|domain)' "${F_RESOLV}")"
    else
        check "bogus .invalid search domain removed" pass
    fi

    # --- 6. ndots sanity ------------------------------------------------------
    if grep -qE '^[[:space:]]*options.*ndots:[5-9]' "${F_RESOLV}" 2>/dev/null; then
        check "ndots is back to a sane value" fail \
              "high ndots turns every short name into multiple wasted queries"
    else
        check "ndots is back to a sane value" pass
    fi

    # --- 7. Public resolution actually works, and quickly ---------------------
    local t0 t1 elapsed pub
    t0="$(date +%s)"
    pub="$(getent hosts www.lpi.org 2>/dev/null | awk '{print $1; exit}')"
    t1="$(date +%s)"
    elapsed=$((t1 - t0))

    if [[ -n "${pub}" ]]; then
        if [[ "${elapsed}" -le 3 ]]; then
            check "public DNS resolves promptly (${elapsed}s)" pass "www.lpi.org -> ${pub}"
        else
            check "public DNS resolves promptly (${elapsed}s)" fail \
                  "resolved to ${pub}, but took ${elapsed}s — check timeout/attempts and dead nameservers"
        fi
    else
        check "public DNS resolves promptly" fail \
              "www.lpi.org did not resolve after ${elapsed}s"
    fi

    rule
    if [[ "${fail}" -eq 0 ]]; then
        printf '%s ALL %d CHECKS PASSED — client-side DNS restored.%s\n' "$C_G" "${pass}" "$C_RST"
        rule
        return 0
    fi
    printf '%s %d passed, %d failed — keep going.%s\n' "$C_Y" "${pass}" "${fail}" "$C_RST"
    say ""
    say "Hint of last resort: the solution is written, step by step, in the"
    say "commented block at the bottom of this script:"
    say "    less +/'SOLUTION' ${0}"
    rule
    return 1
}

# ==============================================================================
#  ENTRY POINT
# ==============================================================================
do_break() {
    require_root
    confirm_disposable_vm

    mkdir -p "${BACKUP_DIR}" || die "Cannot create ${BACKUP_DIR}"
    chmod 0700 "${LAB_ROOT}"

    probe_environment

    head1 "PHASE 1 — SNAPSHOT"
    backup_file "${F_RESOLV}"
    backup_file "${F_HOSTS}"
    backup_file "${F_NSSWITCH}"
    write_rollback_script

    head1 "PHASE 2 — CONTROLLED BREAKAGE"
    neutralize_resolved_stub
    break_nsswitch
    break_resolv
    break_hosts

    head1 "PHASE 3 — BRIEFING"
    print_briefing
}

usage() {
    cat <<USAGE
${LAB_ID} — LPIC-1 objective 109.4, break & fix laboratory

Usage: sudo $0 <command>

  break     Snapshot the current configuration, inject the faults, print the
            incident briefing. DESTRUCTIVE — disposable lab VM only.
  verify    Grade the student's repair against the objective's checklist.
  restore   Roll every change back without a reboot.
  brief     Re-print the briefing for a lab that is already running.

Environment:
  LAB_FORCE=1   skip the interactive "disposable VM" confirmation
                (for automated classroom provisioning only)
USAGE
}

main() {
    case "${1:-}" in
        break)   do_break ;;
        verify)  verify_lab ;;
        restore)
            require_root
            [[ -x "${ROLLBACK}" ]] || die "No rollback script at ${ROLLBACK}"
            "${ROLLBACK}"
            ;;
        brief)
            [[ -f "${STATE_FILE}" ]] || die "No running lab. Start it with '$0 break'."
            # shellcheck disable=SC1090
            . "${STATE_FILE}"
            print_briefing
            ;;
        ""|-h|--help|help) usage ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"

# ==============================================================================
#
