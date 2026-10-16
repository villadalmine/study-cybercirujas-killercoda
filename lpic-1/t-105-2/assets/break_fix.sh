#!/usr/bin/env bash
#
# lab-105.2-break.sh
#
# LPIC-1 (exams 101-500 / 102-500, version 5.0)
# Topic 105.2 - Customize or write simple scripts
#
# WHAT THIS IS
#   A "break & fix" lab. It installs a small, self-contained shell toolkit
#   (a site backup + rotation utility) into a lab directory, then injects five
#   defects that are exactly the ones 105.2 asks you to recognise: a broken
#   interpreter line, a missing execute bit, a configuration file that is not
#   valid shell, unquoted variable expansions, and a script that reports
#   success no matter what happened.
#
#   Nothing outside the lab directory is modified. No system service, no
#   package, no /etc file, no user account is touched. Still: run it on a
#   disposable lab VM, never on a machine you care about.
#
# USAGE
#   ./lab-105.2-break.sh                 # build the lab and break it
#   ./lab-105.2-break.sh --root DIR      # use a different lab root
#   ./lab-105.2-break.sh --verify        # grade your repair (5 tests)
#   ./lab-105.2-break.sh --clean         # remove the lab directory
#
# THE STEP-BY-STEP SOLUTION IS AT THE BOTTOM OF THIS FILE, COMMENTED OUT.
# Do not read it until you have run --verify at least once.
#
# Reference: LPI exam 101/102 objectives, https://www.lpi.org/our-certifications/exam-101-objectives/
#            Bash Reference Manual, https://www.gnu.org/software/bash/manual/bash.html
#            POSIX Shell Command Language, https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html

set -euo pipefail

LAB_ID="lpic1-105.2"
MARKER=".lpic1-lab-105.2"
LAB_ROOT="${LAB_ROOT:-/opt/lpic1-lab/105.2}"
ASSUME_YES=0
FORCE=0
ACTION="build"

die() { printf 'lab-105.2: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

usage() {
    cat <<'USAGE'
Usage: lab-105.2-break.sh [OPTIONS]

  --root DIR     lab root directory (default: /opt/lpic1-lab/105.2)
  -y, --yes      do not ask for confirmation
  --force        rebuild the lab even if the directory already exists
  --verify       run the grader against an existing lab and exit
  --clean        remove the lab directory and exit
  -h, --help     this text

Run only on a disposable lab VM.
USAGE
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --root)    [ $# -ge 2 ] || die "--root needs an argument"; LAB_ROOT="$2"; shift 2 ;;
            --root=*)  LAB_ROOT="${1#*=}"; shift ;;
            -y|--yes)  ASSUME_YES=1; shift ;;
            --force)   FORCE=1; shift ;;
            --verify)  ACTION="verify"; shift ;;
            --clean)   ACTION="clean"; shift ;;
            -h|--help) usage; exit 0 ;;
            *)         usage >&2; die "unknown option: $1" ;;
        esac
    done

    case "$LAB_ROOT" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/proc|/root|/run|/sbin|/sys|/usr|/var)
            die "refusing to use '$LAB_ROOT' as a lab root" ;;
        /*) : ;;
        *)  die "lab root must be an absolute path (got '$LAB_ROOT')" ;;
    esac
}

confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    say ""
    say "This will create and then deliberately break a shell toolkit under:"
    say "    $LAB_ROOT"
    say "Only that directory is written to. Use a throwaway lab VM anyway."
    say ""
    printf 'Type BREAK to continue: '
    local answer=""
    read -r answer || true
    [ "$answer" = "BREAK" ] || die "aborted by user"
}

# ---------------------------------------------------------------------------
# Build the toolkit "as the previous admin left it"
# ---------------------------------------------------------------------------

build_lab() {
    if [ -e "$LAB_ROOT" ] && [ "$FORCE" -ne 1 ]; then
        die "$LAB_ROOT already exists (use --force to rebuild, --clean to remove)"
    fi
    if [ -e "$LAB_ROOT" ]; then
        clean_lab
    fi

    mkdir -p "$LAB_ROOT"/{bin,etc,var/log} "$LAB_ROOT/data/www/notes"
    printf '%s\n' "$LAB_ID" > "$LAB_ROOT/$MARKER"

    # Payload the toolkit is supposed to archive.
    cat > "$LAB_ROOT/data/www/index.html" <<'EOF'
<!doctype html>
<html><head><title>lab site</title></head><body><h1>lab site</h1></body></html>
EOF
    cat > "$LAB_ROOT/data/www/style.css" <<'EOF'
body { font-family: monospace; margin: 2rem; }
EOF
    cat > "$LAB_ROOT/data/www/notes/todo.txt" <<'EOF'
- rotate the backups, the disk filled up twice last month
- the backup job "never fails" according to the logs. suspicious.
EOF

    # --- etc/siteback.conf -------------------------------------------------
    # DEFECT 3 lives here: a configuration file that is sourced by the shell
    # must be valid shell. "NAME = value" is not an assignment.
    cat > "$LAB_ROOT/etc/siteback.conf" <<'EOF'
# siteback configuration
# This file is read with the dot (.) builtin, so it must be valid shell.

# Directory tree to archive.
SITE_DIR = "$LAB_ROOT/data/www"

# Where the archives are written. Yes, the directory name contains a space.
# That is intentional and it is NOT the bug. Do not rename it.
BACKUP_DIR="$LAB_ROOT/var/backups/site data"

# How many archives to keep.
RETENTION = 3
EOF

    # --- bin/siteback ------------------------------------------------------
    # DEFECTS 4 and 5 live here: unquoted expansions, and exit status that is
    # invented rather than propagated.
    cat > "$LAB_ROOT/bin/siteback" <<'EOF'
#!/bin/bash
#
# siteback - archive the site tree and rotate old archives
#
#   siteback --help
#   siteback backup [SOURCE_DIR]
#
# Configuration: $LAB_ROOT/etc/siteback.conf (override with $SITEBACK_CONF)

set -u

LAB_ROOT="${LAB_ROOT:-__LAB_ROOT__}"
CONF="${SITEBACK_CONF:-$LAB_ROOT/etc/siteback.conf}"
LOG_FILE="$LAB_ROOT/var/log/siteback.log"

log() {
    printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$*" >> "$LOG_FILE"
}

usage() {
    cat <<'USAGE'
Usage: siteback COMMAND [ARG]

  backup [SOURCE_DIR]   archive SOURCE_DIR (default: SITE_DIR from the config)
                        into BACKUP_DIR, then prune to RETENTION archives
  --help                this text
USAGE
}

. "$CONF"

cmd="${1:-help}"
shift || true

case "$cmd" in
    -h|--help|help)
        usage
        exit 0
        ;;
    backup)
        src="${1:-$SITE_DIR}"

        if [ ! -d $src ]; then
            printf 'siteback: source directory not found: %s\n' "$src" >&2
            exit 1
        fi

        if [ ! -d $BACKUP_DIR ]; then
            mkdir -p $BACKUP_DIR
        fi

        stamp=$(date +%Y%m%d-%H%M%S)
        archive=$BACKUP_DIR/site-$stamp-$$.tar.gz

        tar -czf $archive -C $src . 2>/dev/null
        log "created $archive"

        $LAB_ROOT/bin/rotate-archives.sh $BACKUP_DIR $RETENTION

        printf 'siteback: backup completed\n'
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
EOF

    # --- bin/rotate-archives.sh -------------------------------------------
    # Off-by-one in the retention arithmetic. tail -n +N starts printing AT
    # line N, so keeping N files means skipping N, not N-1.
    cat > "$LAB_ROOT/bin/rotate-archives.sh" <<'EOF'
#!/bin/bash
#
# rotate-archives.sh DIRECTORY KEEP
#
# Delete the oldest *.tar.gz in DIRECTORY, keeping the KEEP newest ones.

set -u

dir="${1:-}"
keep="${2:-}"

if [ -z "$dir" ] || [ -z "$keep" ]; then
    printf 'rotate-archives.sh: usage: rotate-archives.sh DIRECTORY KEEP\n' >&2
    exit 2
fi

cd "$dir" || exit 1

ls -1t -- *.tar.gz 2>/dev/null | tail -n +"$keep" | while read -r old; do
    rm -f -- "$old"
done

exit 0
EOF

    # --- check.sh (the grader; read-only, it never repairs anything) -------
    cat > "$LAB_ROOT/check.sh" <<'EOF'
#!/usr/bin/env bash
#
# Grader for LPIC-1 lab 105.2. It only observes: it never fixes anything.

set -uo pipefail

LAB_ROOT="__LAB_ROOT__"
BIN="$LAB_ROOT/bin/siteback"
CONF="$LAB_ROOT/etc/siteback.conf"

pass=0
fail=0

ok() { printf '  [ PASS ] %s\n' "$1"; pass=$((pass + 1)); }
ko() {
    printf '  [ FAIL ] %s\n' "$1"
    [ -n "${2:-}" ] && printf '           hint: %s\n' "$2"
    fail=$((fail + 1))
}

# Read one value from the config the same way siteback does.
conf_value() {
    ( LAB_ROOT="$LAB_ROOT"; . "$CONF" >/dev/null 2>&1; printf '%s\n' "${!1:-}" )
}

printf '\nGrading lab 105.2 in %s\n\n' "$LAB_ROOT"

# T1 - the entry point is executable and its interpreter line works.
if "$BIN" --help >/dev/null 2>&1; then
    ok "T1 siteback --help runs and exits 0"
else
    ko "T1 siteback --help runs and exits 0" \
       "look at the very first line of the file and at its mode bits"
fi

backup_dir="$(conf_value BACKUP_DIR)"
retention="$(conf_value RETENTION)"

# T2 - the config parses and a backup lands in the configured directory.
if [ -z "$backup_dir" ] || [ -z "$retention" ]; then
    ko "T2 one backup is written to BACKUP_DIR" \
       "BACKUP_DIR/RETENTION are empty: the config file is not valid shell"
    ko "T3 exactly RETENTION archives survive repeated runs" "fix the config first"
else
    rm -f -- "$backup_dir"/*.tar.gz 2>/dev/null
    "$BIN" backup >/dev/null 2>&1
    rc=$?
    count=$(ls -1 -- "$backup_dir"/*.tar.gz 2>/dev/null | wc -l)
    stray="${backup_dir%% *}"
    if [ "$rc" -eq 0 ] && [ "$count" -eq 1 ] && [ ! -e "$stray" ]; then
        ok "T2 one backup is written to BACKUP_DIR"
    elif [ -e "$stray" ]; then
        ko "T2 one backup is written to BACKUP_DIR" \
           "'$stray' was created by word splitting: quote your expansions, then delete it"
    else
        ko "T2 one backup is written to BACKUP_DIR" \
           "siteback backup returned $rc and left $count archive(s) in '$backup_dir'"
    fi

    # T3 - retention arithmetic.
    rm -f -- "$backup_dir"/*.tar.gz 2>/dev/null
    for _ in 1 2 3 4 5; do "$BIN" backup >/dev/null 2>&1; done
    count=$(ls -1 -- "$backup_dir"/*.tar.gz 2>/dev/null | wc -l)
    if [ "$count" -eq "$retention" ]; then
        ok "T3 exactly RETENTION ($retention) archives survive 5 runs"
    else
        ko "T3 exactly RETENTION ($retention) archives survive 5 runs" \
           "found $count: is the rotation helper even being executed, and is 'tail -n +N' the right N?"
    fi
fi

# T4 - a failed backup must be reported as a failure.
tmp="$(mktemp -d)"
: > "$tmp/blocked"
cat > "$tmp/conf" <<CONFEOF
SITE_DIR="$LAB_ROOT/data/www"
BACKUP_DIR="$tmp/blocked/out"
RETENTION=3
CONFEOF
SITEBACK_CONF="$tmp/conf" "$BIN" backup >/dev/null 2>&1
rc=$?
rm -rf -- "$tmp"
if [ "$rc" -ne 0 ]; then
    ok "T4 an impossible backup exits non-zero"
else
    ko "T4 an impossible backup exits non-zero" \
       "the destination could not even be created, yet the script exited 0: check \$? of every command"
fi

# T5 - every successful run leaves a trace.
logfile="$LAB_ROOT/var/log/siteback.log"
before=$(wc -l < "$logfile" 2>/dev/null || echo 0)
"$BIN" backup >/dev/null 2>&1
after=$(wc -l < "$logfile" 2>/dev/null || echo 0)
if [ "$after" -gt "$before" ]; then
    ok "T5 a successful run appends to the log"
else
    ko "T5 a successful run appends to the log" "expected a new line in $logfile"
fi

printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
printf '  Lab 105.2 repaired. \n\n'
exit 0
EOF

    # Bake the real lab root into the generated files.
    sed -i "s|__LAB_ROOT__|$LAB_ROOT|g" \
        "$LAB_ROOT/bin/siteback" "$LAB_ROOT/check.sh"

    chmod 755 "$LAB_ROOT/bin/siteback" "$LAB_ROOT/bin/rotate-archives.sh" "$LAB_ROOT/check.sh"
    chmod 644 "$LAB_ROOT/etc/siteback.conf"
    : > "$LAB_ROOT/var/log/siteback.log"
}

# ---------------------------------------------------------------------------
# Injected damage
# ---------------------------------------------------------------------------

inject_faults() {
    # DEFECT 1: the file was "edited on a Windows workstation". Every line now
    # ends with CR LF, including the shebang, so the kernel looks for an
    # interpreter literally named "/bin/bash\r".
    awk '{ printf "%s\r\n", $0 }' "$LAB_ROOT/bin/siteback" > "$LAB_ROOT/bin/.siteback.tmp"
    mv -- "$LAB_ROOT/bin/.siteback.tmp" "$LAB_ROOT/bin/siteback"
    chmod 755 "$LAB_ROOT/bin/siteback"

    # DEFECT 2: the rotation helper was copied off a FAT stick / restored from
    # an archive without permissions. Readable, not executable.
    chmod 644 "$LAB_ROOT/bin/rotate-archives.sh"

    # DEFECTS 3, 4 and 5 are already in the sources written above:
    #   3 - etc/siteback.conf uses "NAME = value"
    #   4 - bin/siteback expands $BACKUP_DIR, $src and $archive unquoted
    #   5 - bin/siteback hardcodes "exit 0" and ignores every exit status,
    #       and bin/rotate-archives.sh is off by one in its retention math
    :
}

brief() {
    sed "s|__LAB_ROOT__|$LAB_ROOT|g" <<'BRIEF'

================================================================================
 LPIC-1 105.2 - Customize or write simple scripts        BREAK & FIX LAB
================================================================================

 THE STORY

   The admin before you left a backup toolkit in __LAB_ROOT__:

       bin/siteback              entry point: archives the site tree
       bin/rotate-archives.sh    helper: prunes old archives
       etc/siteback.conf         configuration, read with the dot builtin
       data/www/                 the tree that gets archived
       var/log/siteback.log      where runs are recorded
       check.sh                  the grader

   The cron job that calls it has "never failed" for months. The disk still
   filled up twice. Both statements are true at the same time, and that is
   your first clue.

 START HERE

       export PATH="__LAB_ROOT__/bin:$PATH"
       cd __LAB_ROOT__
       siteback backup

 THE SYMPTOMS YOU WILL WALK THROUGH, IN ORDER

   1. bash: .../bin/siteback: /bin/bash^M: bad interpreter: No such file or
      directory        (some systems say: cannot execute: required file not found)
      The file is executable and /bin/bash exists. Read the first line as bytes,
      not as characters:  head -1 bin/siteback | cat -A

   2. Once it starts: ".../siteback: line NN: SITE_DIR = ...: command not found"
      followed by "SITE_DIR: unbound variable". The configuration file is fed to
      the shell itself; the shell has opinions about what an assignment is.

   3. Then: "[: too many arguments", and a stray thing appears next to the
      backup directory. The backup directory name contains a space. That is
      deliberate, it is not the bug, and renaming it is not the fix.

   4. Then: ".../rotate-archives.sh: Permission denied" - and siteback still
      prints "backup completed" and still exits 0. ls -l bin/ .

   5. Finally, with everything running: the number of surviving archives is not
      RETENTION, and a backup that cannot possibly have worked is still reported
      as a success. Compare `siteback backup ...; echo $?` with reality.

 YOUR MISSION

       __LAB_ROOT__/check.sh          (or: ./lab-105.2-break.sh --verify)

   must print 5 passed, 0 failed.

 THE RULES

   - Fix the scripts and the configuration file. Do not edit check.sh.
   - Do not rename the backup directory and do not remove the space from it.
     Handling paths with spaces is the point of that test.
   - Keep the command-line contract: `siteback --help`, `siteback backup`,
     `siteback backup SOURCE_DIR`, and the $SITEBACK_CONF override.
   - Useful tools: bash -n script (syntax only), bash -x script (trace),
     cat -A file (see CR and tabs), ls -l (mode bits), echo $? (exit status),
     type/file/head, and shellcheck if it is installed.

 WHEN YOU ARE DONE (or truly stuck)

   The full step-by-step solution is at the end of lab-105.2-break.sh, commented.
   Remove the lab with:  ./lab-105.2-break.sh --clean --root __LAB_ROOT__

================================================================================

BRIEF
}

verify_lab() {
    [ -x "$LAB_ROOT/check.sh" ] || die "no grader at $LAB_ROOT/check.sh (build the lab first)"
    "$LAB_ROOT/check.sh"
}

clean_lab() {
    [ -d "$LAB_ROOT" ] || die "nothing to clean: $LAB_ROOT does not exist"
    [ -f "$LAB_ROOT/$MARKER" ] || die "$LAB_ROOT has no $MARKER file; refusing to delete it"
    rm -rf -- "$LAB_ROOT"
    say "lab-105.2: removed $LAB_ROOT"
}

main() {
    parse_args "$@"
    case "$ACTION" in
        verify) verify_lab ;;
        clean)  clean_lab ;;
        build)
            command -v tar >/dev/null 2>&1 || die "tar is required"
            command -v awk >/dev/null 2>&1 || die "awk is required"
            confirm
            build_lab
            inject_faults
            brief
            ;;
    esac
}

main "$@"
