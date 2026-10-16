## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
===============  SOLUTION - STOP READING IF STILL TRYING  ===========

FAULT 1 - /dev/null is a regular file
Diagnosis:
    $ ls -l /dev/null
    -rw------- 1 root root 1483 Aug 26 09:14 /dev/null      <-- '-' not 'c'
    $ stat -c '%F %t:%T %a' /dev/null
    regular file 0:0 600
  A healthy system shows:
    crw-rw-rw- 1 root root 1, 3 Aug 26 09:14 /dev/null
    character special file 1:3 666
  The "1, 3" are the major and minor numbers of the kernel's null driver.
  Because the impostor is mode 600 and root-owned, an unprivileged
  `cmd 2>/dev/null` fails with EACCES; as root it silently GROWS a file that
  was supposed to discard bytes, and `cmd < /dev/null` feeds the command
  whatever junk accumulated instead of EOF.

Fix:
    rm -f /dev/null
    mknod -m 0666 /dev/null c 1 3
    chown root:root /dev/null
  Verify:
    echo test > /dev/null && cat /dev/null | wc -c     # -> 0
  Note: on a systemd host you can also let udev rebuild it
  (`udevadm trigger --name-match=null`), and inside a container the node is
  normally provided by the runtime, not by udev.


FAULT 2 - noclobber set system-wide
Diagnosis:
    $ bash -l
    $ echo hi > /tmp/x ; echo hi > /tmp/x
    bash: /tmp/x: cannot overwrite existing file
    $ set -o | grep noclobber
    noclobber       on
    $ grep -rn noclobber /etc/profile /etc/profile.d/ 2>/dev/null
    /etc/profile.d/lab-noclobber.sh:2:set -o noclobber
  noclobber makes `>` refuse to truncate an EXISTING regular file. It does not
  affect `>>`, and it is bypassed per-redirection by `>|`.

Fix:
    rm -f /etc/profile.d/lab-noclobber.sh
    set +o noclobber            # for the shell you are sitting in
  Escape hatch worth knowing for the exam, when you cannot change the setting:
    echo hi >| /tmp/x


FAULT 3 - the report file is a FIFO
Diagnosis:
    $ ls -l /var/log/labcollect/report.log
    prw-r--r-- 1 root root 0 Aug 26 09:14 report.log      <-- leading 'p'
    $ stat -c %F /var/log/labcollect/report.log
    fifo
  Opening a FIFO for writing BLOCKS until some process opens it for reading.
  That is why lab-collect hung on its very first redirection and never printed
  anything. Proof, from a second terminal while it hangs:
    $ ls -l /proc/$(pgrep -f lab-collect)/fd
    l-wx------ 1 root root 64 ... 1 -> /var/log/labcollect/report.log
  (Reading the other end with `cat report.log` also unblocks it - a useful
  trick to confirm the diagnosis before you change anything.)

Fix:
    rm -f /var/log/labcollect/report.log
    : > /var/log/labcollect/report.log        # or let lab-collect create it
    chmod 0644 /var/log/labcollect/report.log


FAULT 4 - lab-collect, four redirection bugs
4a  Truncate instead of append.
      BROKEN: echo "=== run $(date -Is) ===" > "$LOG"
      FIXED : echo "=== run $(date -Is) ===" >> "$LOG"
    `>` opens with O_TRUNC, `>>` with O_APPEND. Only O_APPEND is safe when
    several writers share a log file: the offset is re-evaluated at every
    write, so records cannot land on top of each other.

4b  `2>&1` on the wrong side of the redirection.
      BROKEN: cat /proc/loadavg /proc/lab-does-not-exist 2>&1 >> "$LOG"
      FIXED : cat /proc/loadavg /proc/lab-does-not-exist >> "$LOG" 2>&1
    Redirections are applied LEFT TO RIGHT. In the broken form, `2>&1` first
    makes fd 2 a duplicate of fd 1 *as it is at that moment* - the terminal -
    and only then is fd 1 moved to the file. fd 2 keeps pointing at the
    terminal: it copied the destination, not the name. In the fixed form fd 1
    is moved to the file first, then fd 2 is pointed at the same open file
    description. The compact bash-only synonym is `&>>` for append and `&>`
    for truncate; `>file 2>&1` is the POSIX-portable spelling you should write
    in scripts that may run under dash.
    Apply the same fix to the `uptime` and `free -m` lines, and give the
    header line an append too:
      uptime  >> "$LOG" 2>&1
      free -m >> "$LOG" 2>&1

4c  Only stdout enters a pipe.
      BROKEN: lab-probe | grep -c '^WARN' >> "$LOG"
      FIXED : lab-probe 2>&1 | grep -c '^WARN' >> "$LOG"
      (bash >= 4 shorthand: lab-probe |& grep -c '^WARN' >> "$LOG")
    `|` connects the writer's fd 1 to the reader's fd 0 and nothing else.
    lab-probe emits its WARN lines on fd 2, so they went straight to the
    terminal and grep counted an empty stream - hence "warnings: 0" while the
    warnings were visible on screen. Note the ORDER again: here `2>&1` must
    come BEFORE the pipe on the command line, because the pipe has already
    redirected fd 1 by the time the command's own redirections are processed.
    If you ever need the opposite - keep stderr out of the pipe but on screen
    - the idiom is `cmd 2>/dev/null | ...`, and to send only stderr down the
    pipe: `cmd 2>&1 1>/dev/null | ...`.

4d  A pipeline that truncates its own input.
      BROKEN: grep -v '^#' "$DATA" | sort -u > "$DATA"
      FIXED : tmp=$(mktemp)
              grep -v '^#' "$DATA" | sort -u > "$tmp" && mv -f "$tmp" "$DATA"
    The shell sets up ALL redirections of a pipeline before executing any
    member, so `> "$DATA"` truncates the file to zero length before grep gets
    a chance to read a single byte. The result is an empty file and, as a
    side effect, "errors: 0". Alternatives to the temp file: `sponge` from
    moreutils (`grep -v '^#' "$DATA" | sort -u | sponge "$DATA"`), or reading
    the whole file into a variable first. `tee "$DATA"` does NOT save you -
    tee opens the file with O_TRUNC just as early.

  Corrected body of lab-collect:
      LOG=/var/log/labcollect/report.log
      DATA=/opt/lab1034/data/app.log
      tmp=$(mktemp)

      echo "=== run $(date -Is) ===" >> "$LOG"

      uptime                                     >> "$LOG" 2>&1
      free -m                                    >> "$LOG" 2>&1
      cat /proc/loadavg /proc/lab-does-not-exist >> "$LOG" 2>&1

      printf 'warnings: ' >> "$LOG"
      lab-probe 2>&1 | grep -c '^WARN' >> "$LOG"

      grep -v '^#' "$DATA" | sort -u > "$tmp" && mv -f "$tmp" "$DATA"

      echo "errors: $(grep -c 'ERROR' "$DATA")" >> "$LOG"

  A tidier idiom worth showing the student - redirect the WHOLE script once
  with exec, so every later command inherits the report as fd 1 and fd 2:
      exec >> "$LOG" 2>&1
  after which the individual `>> "$LOG" 2>&1` suffixes are unnecessary. And if
  you also want the output on screen while it is being stored, the tool is
  `tee -a`:
      { uptime; free -m; } 2>&1 | tee -a "$LOG"
  Remember why `sudo echo x > /root/f` fails but `echo x | sudo tee -a /root/f`
  works: the redirection is performed by YOUR shell, before sudo ever runs.


FAULT 5 - lab-inventory, here-documents and the pipeline subshell
5a  Here-document terminator not recognised.
    The delimiter line was written as "    EOF" (four spaces). With `<<EOF`
    the terminator must be alone at the very start of the line, so bash never
    found it, swallowed the rest of the file into the document and warned:
      bash: warning: here-document at line 6 delimited by end-of-file
    Two valid fixes:
      * put EOF in column 0, or
      * use `<<-EOF` and indent the terminator with TAB characters only
        (`<<-` strips leading tabs from the body and the terminator; spaces
        are NOT stripped - this is the classic trap when an editor expands
        tabs to spaces).

5b  Unquoted delimiter expanded the price.
    With `<<EOF` the body behaves like a double-quoted string: `$50` is read
    as the positional parameter `$5` (unset, empty) followed by `0`, so the
    line printed "cost model : 0 per node". Fixes, in order of preference for
    this script, which still needs `$count` to expand:
      cost model : \$50 per node
    If NOTHING in the body should expand, quote the delimiter instead -
    `<<'EOF'` or `<<"EOF"` - and inject the dynamic value another way.

5c  The counter is lost in a subshell.
      BROKEN: cat hosts.txt | while read -r h; do total=$((total+1)); done
      FIXED : while read -r h; do total=$((total+1)); done < /opt/lab1034/data/hosts.txt
    Every member of a bash pipeline runs in its own subshell, so `total` was
    incremented in a child process and discarded when that child exited -
    the parent still printed 0. Feeding the loop with an input redirection
    keeps it in the current shell. Other legitimate answers:
      * shopt -s lastpipe  (plus `set +m`, and only in a non-interactive
        shell) makes the LAST pipeline member run in the current shell;
      * process substitution: while read -r h; do ...; done < <(cat hosts.txt)
      * do the arithmetic where the data already is: total=$(wc -l < hosts.txt)
    The `cat file |` prefix was also a useless use of cat: `wc -l < file` and
    `done < file` avoid an extra process and an extra pipe entirely.

  Corrected body of lab-inventory:
      count=$(wc -l < /opt/lab1034/data/hosts.txt)

      cat << EOF
          Lab inventory
          hosts file : /opt/lab1034/data/hosts.txt
          host count : $count
          cost model : \$50 per node
      EOF

      total=0
      while read -r h; do
          total=$((total + 1))
      done < /opt/lab1034/data/hosts.txt
      echo "counted hosts: $total"


CLOSING DRILL (do this before you call the topic done)
  1. Send stdout to one file and stderr to another:
       cat /etc/hostname /nope > out.txt 2> err.txt
  2. Send stderr into the pipe and drop stdout:
       cat /etc/hostname /nope 2>&1 1>/dev/null | wc -l
  3. Store and display at the same time, and feed a third consumer:
       lab-probe 2>&1 | tee -a /tmp/probe.log | grep -c WARN
  4. Build a command line from stdin, one argument per line, safely:
       printf '%s\0' /tmp/a /tmp/b | xargs -0 -r -n1 basename
  5. Herestring instead of an echo pipeline:
       read -r a b <<< "left right"; echo "$b/$a"
  6. Prove that fd 3 exists too:
       exec 3> /tmp/fd3.log; echo "via fd 3" >&3; exec 3>&-; cat /tmp/fd3.log
  7. Look at a running process's descriptors:
       sleep 300 > /tmp/s.out 2>/dev/null & ls -l /proc/$!/fd; kill %1

Sources:
  LPI Exam 101-500 objectives, topic 103.4
    https://www.lpi.org/our-certifications/exam-101-objectives/
  GNU Bash Reference Manual - Redirections
    https://www.gnu.org/software/bash/manual/bash.html#Redirections
  GNU Bash Reference Manual - Pipelines / The Set Builtin (noclobber, lastpipe)
    https://www.gnu.org/software/bash/manual/bash.html#Pipelines
    https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
  POSIX.1-2024 Shell Command Language - Redirection
    https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_07
  Linux man-pages: null(4), fifo(7), mknod(1), mkfifo(1), tee(1), xargs(1)
    https://man7.org/linux/man-pages/man4/null.4.html
    https://man7.org/linux/man-pages/man7/fifo.7.html
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/103.4/lab)
