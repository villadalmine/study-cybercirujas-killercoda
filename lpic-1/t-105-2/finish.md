## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION - do not read before you have run check.sh at least once

Throughout, LAB=/opt/lpic1-lab/105.2 (or whatever you passed to --root):

    LAB=/opt/lpic1-lab/105.2
    cd "$LAB"

DEFECT 1 - CR LF line endings, so the interpreter line is "/bin/bash\r"
Diagnose:

    file bin/siteback
        bin/siteback: Bourne-Again shell script, ASCII text executable,
        with CRLF line terminators
    head -1 bin/siteback | cat -A
        #!/bin/bash^M$

The kernel takes everything after #! up to the newline as the interpreter
path, so it tries to exec "/bin/bash\r", which does not exist. The error
message names /bin/bash, which is why it reads as nonsense.

Fix (any one of these):

    sed -i 's/\r$//' bin/siteback
    # or:  dos2unix bin/siteback
    # or:  tr -d '\r' < bin/siteback > /tmp/s && cat /tmp/s > bin/siteback

Verify:

    head -1 bin/siteback | cat -A      # -> #!/bin/bash$
    bash -n bin/siteback               # syntax check, no output = OK
    siteback --help

DEFECT 2 - the rotation helper is not executable
Diagnose:

    ls -l bin/
        -rwxr-xr-x 1 root root ... siteback
        -rw-r--r-- 1 root root ... rotate-archives.sh

A script with the read bit but not the execute bit can be sourced or passed
to an interpreter, but it cannot be exec'd; bash returns 126 and prints
"Permission denied".

Fix:

    chmod +x bin/rotate-archives.sh          # or: chmod 755 bin/rotate-archives.sh

Note the wrong fix: changing the caller to `bash bin/rotate-archives.sh`
hides the mode problem and breaks the moment the helper's shebang differs
from bash. Fix the file, not the call.

DEFECT 3 - the configuration file is not valid shell
etc/siteback.conf is read with `. "$CONF"`, i.e. executed by the current
shell. `SITE_DIR = "..."` is not an assignment: it is the command SITE_DIR
with the arguments "=" and the path. Hence "command not found", and then
"unbound variable" under `set -u` when the script uses $SITE_DIR.

In a shell assignment there is no whitespace around the equals sign.

Fix - edit etc/siteback.conf to read:

    SITE_DIR="$LAB_ROOT/data/www"
    BACKUP_DIR="$LAB_ROOT/var/backups/site data"
    RETENTION=3

Verify the file on its own before trusting it:

    bash -n etc/siteback.conf
    ( LAB_ROOT="$LAB" ; . etc/siteback.conf ; echo "[$SITE_DIR] [$BACKUP_DIR] [$RETENTION]" )

Hardening worth knowing for real systems: a sourced config runs arbitrary
code. When you only need KEY=VALUE, parse it instead of sourcing it, e.g.
with `grep -E '^[A-Z_]+=' | while IFS='=' read -r k v; do ... done`.

DEFECT 4 - unquoted expansions meet a path containing a space
BACKUP_DIR is ".../var/backups/site data". Unquoted, the shell performs word
splitting on it after expansion, so

    [ ! -d $BACKUP_DIR ]      becomes   [ ! -d .../site data ]

which is four arguments to test -> "[: too many arguments" (exit status 2).
Likewise `tar -czf $archive -C $src .` splits the archive path and creates a
FILE called ".../var/backups/site" while feeding "data/..." to tar as an
operand. That leftover file is what T2 complains about; delete it:

    rm -f "$LAB/var/backups/site"

Fix - in bin/siteback, quote every expansion in the backup branch:

    if [ ! -d "$src" ]; then
        printf 'siteback: source directory not found: %s\n' "$src" >&2
        exit 1
    fi

    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR" || {
            printf 'siteback: cannot create %s\n' "$BACKUP_DIR" >&2
            exit 1
        }
    fi

    stamp="$(date +%Y%m%d-%H%M%S)"
    archive="$BACKUP_DIR/site-$stamp-$$.tar.gz"

    tar -czf "$archive" -C "$src" .

    "$LAB_ROOT/bin/rotate-archives.sh" "$BACKUP_DIR" "$RETENTION"

Rule of thumb for the exam and for production: expand inside double quotes
unless you specifically want splitting and globbing. "$@" (never $*) when
forwarding arguments; "${var}" when concatenating.

DEFECT 5 - the exit status is invented, and the retention math is off by one
5a. bin/siteback ends the backup branch with a hardcoded `exit 0` and throws
    away tar's status (and the helper's) - it even redirects tar's stderr to
    /dev/null. That is why "the job never fails": it cannot.

    Fix the branch to propagate failure, and stop hiding the errors:

        if ! tar -czf "$archive" -C "$src" .; then
            log "FAILED to create $archive"
            printf 'siteback: tar failed for %s\n' "$src" >&2
            exit 1
        fi
        log "created $archive"

        if ! "$LAB_ROOT/bin/rotate-archives.sh" "$BACKUP_DIR" "$RETENTION"; then
            log "FAILED to rotate $BACKUP_DIR"
            printf 'siteback: rotation failed in %s\n' "$BACKUP_DIR" >&2
            exit 1
        fi

        printf 'siteback: backup completed\n'
        exit 0

    Belt and braces, add the standard preamble near the top of the script:

        set -euo pipefail

    -e abort on an unchecked failure, -u abort on an unset variable,
    -o pipefail make a pipeline fail if ANY stage fails, not just the last.
    With -e, remember that `cmd || true` is how you mark a failure as
    tolerated, and that `if ! cmd; then` does not trigger it.

5b. bin/rotate-archives.sh keeps the wrong number of files:

        ls -1t -- *.tar.gz | tail -n +"$keep"

    `tail -n +N` prints starting AT line N. To keep the newest $keep files you
    must start deleting at line $keep + 1:

        ls -1t -- *.tar.gz 2>/dev/null | tail -n +"$((keep + 1))" | while read -r old; do
            rm -f -- "$old"
        done

    Check the arithmetic by hand before believing it:

        ls -1t *.tar.gz | tail -n +4          # with RETENTION=3 -> the 4th onwards

    Two extras worth internalising: parsing ls is fragile (a filename with a
    newline defeats it), and the `while` in a pipeline runs in a subshell, so
    counters set inside it do not survive. Robust alternative:

        mapfile -t archives < <(ls -1t -- *.tar.gz 2>/dev/null)
        for old in "${archives[@]:keep}"; do rm -f -- "$old"; done

FINAL VERIFICATION

    bash -n bin/siteback bin/rotate-archives.sh etc/siteback.conf
    command -v shellcheck >/dev/null && shellcheck bin/siteback bin/rotate-archives.sh

    rm -f "$LAB/var/backups/site data"/*.tar.gz
    siteback backup ; echo "exit=$?"
    siteback backup /definitely/not/here ; echo "exit=$?"     # must be non-zero

    "$LAB/check.sh"        # -> 5 passed, 0 failed

Then remove the lab:  ./lab-105.2-break.sh --clean --root "$LAB"

WHAT 105.2 WANTED YOU TO TAKE AWAY
  - #! must be the first two bytes and the interpreter path must be exact;
    invisible bytes (CR) are a real, common failure.
  - Execute permission is what makes a script a command; the read bit is not.
  - A sourced config is executed: assignments take no spaces around "=".
  - Quote your expansions. Word splitting is the single most common bug in
    shell scripts, and it only shows up when a value contains whitespace.
  - Exit status is the contract with cron, systemd, make and every caller.
    Check $?, propagate failures, and never end a branch with a blind exit 0.
  - Off-by-one belongs to shell too: tail -n +N, ${array[@]:n}, seq bounds.

Sources: LPI exam objectives, https://www.lpi.org/our-certifications/exam-101-objectives/
         bash(1) - SHELL BUILTIN COMMANDS (set, test, shift, exit)
         GNU Coreutils manual (tail, ls), https://www.gnu.org/software/coreutils/manual/
         Bash Reference Manual - Word Splitting and Quoting,
         https://www.gnu.org/software/bash/manual/bash.html#Word-Splitting
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/105.2/lab)
