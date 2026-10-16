## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION-BEGIN

STEP-BY-STEP WALKTHROUGH

You are inside `su - lpicstudent`. PATH is "/usr/local/bin", `ls` is a hostile
alias, `which` is a lying function, history is being discarded, and the prompt
is bare. You have exactly one thing to work with: bash itself.

STEP 0 — Understand why the shell is not completely dead

  $ cd /tmp && pwd
  /tmp
  $ echo "hello"
  hello
  $ cat /etc/hostname
  bash: cat: command not found

`cd`, `pwd` and `echo` are SHELL BUILT-INS: they live inside the bash process
and are never looked up in PATH. `cat` is an EXTERNAL BINARY at /usr/bin/cat
and can only be found through PATH (or by absolute/relative path). That single
distinction is the core of objective 103.1, and it is what makes this lab
recoverable at all.

Confirm it with the built-in that answers exactly this question:

  $ type cd
  cd is a shell builtin
  $ type -a echo
  echo is a shell builtin
  echo is /usr/bin/echo          <-- only visible once PATH is fixed
  $ type cat
  bash: type: cat: not found

`type` is itself a built-in, so it keeps working. `which` does not — and here
it is worse than useless, because it has been replaced by a function.

List every built-in available to you right now:

  $ enable -a | head
  $ help                          # one-line summary of every built-in

STEP 1 — See the damage (O1 diagnosis)

  $ echo "$PATH"
  /usr/local/bin

There it is. Two directories short of a working system. Note the quotes around
$PATH: without them the value would be word-split, which usually does not
matter for PATH but is a habit the exam expects.

Look at the wider environment using built-ins only:

  $ set | grep -i hist            # 'grep' is external -> fails right now
  bash: grep: command not found

  $ echo "$HISTFILE $HISTSIZE $HISTFILESIZE"
  /proc/lpic/nonexistent/.bash_history 0 0

`set` (built-in) prints shell variables AND functions; `export -p` prints only
exported ones; `env` is an external command and is unreachable until PATH is
fixed. Use the right tool for the situation you are actually in.

STEP 2 — Repair PATH in the LIVE session (O1, current shell)

`export` is a built-in, so this works even with a broken PATH:

  $ export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  $ echo "$PATH"
  /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  $ uname -a
  Linux lpic-lab 6.1.0-lab #1 SMP x86_64 GNU/Linux

If you preferred to append rather than retype, the idiom is:

  $ export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin"

Never write `PATH=/usr/bin` without `export` if child processes need it, and
never put an empty element or "." in PATH — an empty element means "the
current directory", which is a real privilege-escalation vector:

  PATH="/usr/bin:"      # trailing colon == "." — do not do this

After changing PATH, clear bash's hash table so it re-searches from scratch:

  $ hash -r
  $ hash
  hits    command
     1    /usr/bin/uname

`hash` caches the full path of every external command you have run. If a
binary moves and a command keeps resolving to the old location, `hash -r` is
the answer — a classic exam question.

STEP 3 — Unmask 'ls' (O2)

  $ ls
  ls: permission denied (lab)

That is not the real /bin/ls. Ask bash what it is actually running, and ask
for ALL matches, not just the first:

  $ type -a ls
  ls is aliased to `echo "ls: permission denied (lab)"; false'
  ls is /usr/bin/ls

Bash resolves a command name in this fixed order — memorise it:

  1. alias
  2. shell keyword   (if, for, while, function, [[ ... )
  3. shell function
  4. shell built-in
  5. hashed path
  6. PATH search

Three ways to bypass an alias for a single command (alias expansion is
suppressed when any character of the word is quoted or escaped):

  $ \ls                    # backslash-escape the first character
  $ 'ls'                    # quote the word
  $ command ls              # skip aliases and functions entirely

And the permanent fix for the current session:

  $ unalias ls
  $ type -a ls
  ls is /usr/bin/ls

`unalias -a` removes every alias at once. `alias` with no arguments lists
them all — run it to check nothing else was tampered with.

STEP 4 — Unmask 'which' (O3)

  $ which bash
  /opt/definitely-not-here/bash
  $ type -a which
  which is a function
  which ()
  {
      echo "/opt/definitely-not-here/$1"
  }
  which is /usr/bin/which

A function outranks the external binary, so `which` was lying. Remove it with
the built-in that deletes functions and variables:

  $ unset -f which
  $ type -a which
  which is /usr/bin/which
  $ which bash
  /usr/bin/bash

Note `unset -f` (function) versus `unset -v` (variable). Plain `unset NAME`
tries the variable first, which is why being explicit matters.

LESSON: `which` is an external program. It knows nothing about aliases,
functions or built-ins, and on some systems it reads its own startup files.
`type -a` is a bash built-in and reports the truth about what YOUR shell will
execute. Prefer `type -a` for diagnosis; `which` is only for scripting a path.

STEP 5 — Restore command history (O4)

  $ echo "$HISTFILE"
  /proc/lpic/nonexistent/.bash_history
  $ history
      1  echo $PATH
      2  history

Nothing is being saved because HISTFILE points at an unwritable path and
HISTSIZE=0 means "remember zero commands in memory". Fix both:

  $ export HISTFILE="$HOME/.bash_history"
  $ export HISTSIZE=1000
  $ export HISTFILESIZE=2000

Useful history operations from the objective:

  $ history                 # numbered list of the in-memory list
  $ history 5               # last five entries
  $ history -w              # write the in-memory list to $HISTFILE now
  $ history -a              # append only the new entries of this session
  $ history -r              # read $HISTFILE into memory
  $ history -c              # clear the in-memory list
  $ !42                     # re-run entry 42
  $ !!                      # re-run the previous command

History is written on a clean exit, so a killed terminal loses the session.
`history -a` after important work is a real operational habit.

Prove the fix survives a logout:

  $ echo "MARKER-103-1"
  $ history -a
  $ exit
  $ su - lpicstudent
  $ grep MARKER-103-1 ~/.bash_history
  MARKER-103-1

(Note: HISTCONTROL=ignorespace makes a command prefixed with a space stay out
of history — the correct way to type a one-off command containing a secret.)

STEP 6 — The quoting trap (O5)

  $ echo $LAB_TARGET
  /opt/lpic-lab/103.1/reports $daily
  $ cat $LAB_TARGET/README
  cat: '/opt/lpic-lab/103.1/reports': No such file or directory
  cat: '$daily/README': No such file or directory

Unquoted expansion word-splits on the space, so `cat` receives TWO arguments
instead of one. The value itself is fine; the expansion is not. Quote it:

  $ cat "$LAB_TARGET/README"
  Read this with correct quoting. The flag lives in /opt/lpic-lab/103.1/flag.txt

The three quoting mechanisms, exactly as 103.1 frames them:

  "double quotes"  suppress word splitting and globbing;
                   $ ` \ and (in interactive shells) ! keep their meaning.
  'single quotes'  suppress EVERYTHING. No expansion of any kind is possible,
                   and a single quote cannot appear inside.
  \backslash       escapes exactly the next character.

Which is why the variable was created with single quotes: the literal '$' in
'$daily' survives only because nothing inside single quotes is expanded.

  $ echo '$daily'      ->  $daily
  $ echo "$daily"      ->  (empty: expands an undefined variable)
  $ echo \$daily       ->  $daily

Now collect the flag:

  $ cat /opt/lpic-lab/103.1/flag.txt
  LPIC1-103.1-PATH-RESTORED

STEP 7 — Make the repair permanent

Everything above lives only in the current shell. The sabotage is in
~/.bashrc, so it comes back on the next login. Edit the file and delete the
whole block between the two "LPIC-1 103.1 LAB" comment markers:

  $ vi ~/.bashrc          # or: nano ~/.bashrc

Then reload it in the current shell without logging out:

  $ source ~/.bashrc      # or the POSIX equivalent:  . ~/.bashrc

Verify from a genuinely fresh login shell — this is the only honest test,
because it re-reads the startup files from disk:

  $ exit
  $ su - lpicstudent
  $ echo "$PATH"; type -a ls; type -a which; echo "$HISTFILE $HISTSIZE"

Which startup file does what (103.1 / 105.1 boundary, but always examined):

  Login shell         : /etc/profile -> ~/.bash_profile OR ~/.bash_login OR
                        ~/.profile  (the FIRST one that exists, only that one)
  Interactive non-login: /etc/bash.bashrc -> ~/.bashrc
  Most distributions have ~/.bash_profile source ~/.bashrc, which is why an
  error in ~/.bashrc breaks login shells too.

STEP 8 — Confirm and reflect

  $ exit
  $ sudo /path/to/103.1-break-and-fix.sh verify
  [  ok  ] O1a  PATH includes /usr/bin
  [  ok  ] O1b  'uname -s' resolves by bare name -> Linux
  [  ok  ] O2   'type -t ls' reports 'file' (real binary, alias gone)
  [  ok  ] O3   'which' is no longer a shell function
  [  ok  ] O4a  HISTFILE points at the real history file
  [  ok  ] O4b  HISTSIZE allows history to be kept
  [  ok  ] O5a  "$LAB_TARGET/README" is readable with correct quoting
  [  ok  ] O5b  flag readable: LPIC1-103.1-PATH-RESTORED

COMMAND SUMMARY — the 103.1 toolkit used here

  bash            the shell itself; `bash --version`, `man bash`
  echo            built-in; `echo "$VAR"` — always quote
  env             run a command in a modified environment; `env` alone prints
                  the exported environment; `env -i cmd` starts it empty
  export          mark a shell variable for export to child processes
  pwd             print working directory (built-in; `pwd -P` resolves symlinks)
  set             set shell options / list all shell variables and functions
  unset           remove a variable (-v) or a function (-f)
  type -a         THE diagnostic: what will this name actually run, in order
  which           external; finds a binary in PATH, blind to shell constructs
  man             manual pages; `man 1 bash`, `man -k keyword`, `man 5 passwd`
  uname           system information; `uname -a`, `-r` kernel, `-m` arch
  history         command history; -a append, -w write, -r read, -c clear
  .bash_history   where it is stored, controlled by HISTFILE/HISTSIZE
  hash / hash -r  the cached command-location table, and how to flush it
  command         run bypassing aliases and functions
  alias / unalias define and remove aliases

OFFICIAL SOURCES

  LPI Exam 101-500 Objectives (Topic 103.1, weight 2 — Topic 103 total 26)
    https://www.lpi.org/our-certifications/exam-101-objectives/

  GNU Bash Reference Manual — Shell Expansions, Quoting, Bash History
    https://www.gnu.org/software/bash/manual/bash.html
    https://www.gnu.org/software/bash/manual/bash.html#Quoting
    https://www.gnu.org/software/bash/manual/bash.html#Bash-History-Facilities

  POSIX.1-2024 Shell Command Language (Base Specifications, Vol. 3)
    https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html

  man-pages: bash(1), env(1), which(1), uname(1), history in bash(1)
    https://man7.org/linux/man-pages/man1/bash.1.html
    https://man7.org/linux/man-pages/man1/env.1.html
    https://man7.org/linux/man-pages/man1/uname.1.html

SOLUTION-END
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/103.1/lab)
