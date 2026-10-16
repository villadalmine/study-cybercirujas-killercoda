## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — read only after you have tried. Step by step.

 STEP 0 — Reconnaissance. Never edit before you have measured.
   # Which MTA actually owns /usr/sbin/sendmail on this box?
   readlink -f /usr/sbin/sendmail          # -> /usr/sbin/postfix-sendmail (postfix)
   postconf -h mail_version
   systemctl status postfix --no-pager

   # The whole delta from the compiled-in defaults, in one screen:
   postconf -n

   # Where is the mail, and how long has it been there?
   mailq                                   # == postqueue -p == sendmail -bp
   postqueue -j | head -n 3                # JSON form, postfix >= 3.1
   postcat -q <QUEUE_ID>                   # envelope + headers + body of one message

   # Why is it there?
   journalctl -u postfix -n 100 --no-pager     # or: tail -n 100 /var/log/mail.log

 STEP 1 — Fault A: local deliveries are parked in the queue on purpose.
 Evidence: 'postconf -n' contains a line that has no business on a working
 relay:

     defer_transports = local

 postconf(5) defines it as the list of transports that must NOT deliver until
 someone issues 'sendmail -q'. The queue manager therefore accepts the mail,
 writes it to the deferred queue and stops — which is why the log shows the
 message being queued but never a "status=sent" line for it.

 Fix (remove the override so the built-in default, an empty list, applies):

     postconf -X defer_transports          # deletes the parameter from main.cf
     # equivalent, if your postfix predates -X:
     # postconf -e 'defer_transports ='
     postconf -n | grep -c defer_transports # -> 0
     systemctl reload postfix

 Deferred mail is not retried instantly (minimal_backoff_time and
 queue_run_delay default to 300s), so force one queue run:

     postqueue -f                          # == sendmail -q
     mailq                                 # -> "Mail queue is empty" (or bounces appear)

 STEP 2 — Fault B: /etc/aliases was edited, the alias map was never rebuilt.
 Evidence: the bounce says  unknown user: "helpdesk"  while the text file has
 the entry. Postfix's local(8) does not parse /etc/aliases at delivery time;
 it queries the indexed database named by alias_maps. Ask the database:

     grep -n '^helpdesk' /etc/aliases                    # the entry IS there
     postconf -h alias_maps                              # e.g. hash:/etc/aliases
     postconf -h alias_database                          # e.g. hash:/etc/aliases
     postmap -q helpdesk "$(postconf -h alias_database)"  # -> no output = not in the map
     ls -l --time-style=full-iso /etc/aliases /etc/aliases.db   # .db older than the text file

 Fix — recompile the map:

     newaliases                                          # == sendmail -bi; uses $alias_database
     # equivalent, explicit form:
     # postalias hash:/etc/aliases      (use lmdb:/etc/aliases if that is your map type)

     postmap -q helpdesk "$(postconf -h alias_database)"  # -> mtalab, mtaops

 Rule to memorise for the exam: EVERY edit of /etc/aliases must be followed by
 newaliases. A reload or a restart of the MTA does NOT rebuild the map.

 STEP 3 — Fault C: a ~/.forward that points back at its own owner.
 Evidence: the bounce reads "mail forwarding loop for mtalab@<host>".
 local(8) writes a "Delivered-To:" header before expanding ~/.forward; when the
 re-submitted copy comes back for the same address, that header is already
 present and Postfix aborts the loop.

     cat ~mtalab/.forward
     mtalab@<host>                 <-- forwards to itself: infinite loop

 The requirement is "keep a local copy AND send one to the team mailbox".
 aliases(5)/local(8): a leading backslash suppresses further alias and
 ~/.forward expansion, i.e. it means "deliver to this local mailbox, stop".

     printf '\\mtalab, mtaops\n' > ~mtalab/.forward
     chown mtalab:mtalab ~mtalab/.forward
     chmod 644           ~mtalab/.forward

 Note the two constraints local(8) enforces on ~/.forward: it must be owned by
 the recipient (or root) and must not be group/world writable, and the home
 directory itself must not be writable by others — otherwise the file is
 silently ignored and you will chase a ghost.

 The same idea expressed centrally, in /etc/aliases, would be:
     mtalab: \mtalab, mtaops        # then: newaliases

 STEP 4 — Prove it, and prove it survives a restart.
     systemctl restart postfix
     echo "test" | /usr/sbin/sendmail -f root helpdesk
     sleep 3; mailq                                   # empty
     grep -c "Delivered-To" /var/mail/mtalab /var/mail/mtaops
     su -s /bin/bash mtalab -c mail                   # read the mailbox interactively
     sudo ./break-and-fix-108.3.sh verify             # all checks PASS

 Then clean up the bounces you generated while debugging:
     mailq                                            # note any leftover IDs
     postsuper -d ALL deferred                        # delete deferred mail
     # postsuper -r ALL                               # requeue instead of deleting

 STEP 5 — What 108.3 actually asks you to know beyond this box.
 The objective is MTA-agnostic: you must recognise Postfix, sendmail, exim and
 qmail, and know the portable interfaces they all provide.

   Portable, present with any of them:
     /usr/sbin/sendmail        submission binary (a symlink to the real MTA)
     sendmail -bp              print the queue        (= mailq)
     sendmail -q               flush the queue
     sendmail -bi              rebuild the alias map  (= newaliases)
     /etc/aliases, ~/.forward  system-wide and per-user delivery redirection
     mail / mailx              read and send from the shell

   MTA-specific equivalents worth remembering:
     postfix : postconf -n | postqueue -p | postqueue -f | postsuper -d | postalias
     exim    : exim -bp | exim -bt <addr> | exim -M <id> | exiqgrep | update-exim4.conf
     sendmail: mailq | /etc/mail/sendmail.mc -> sendmail.cf via m4 | makemap hash
     qmail   : qmail-qstat | qmail-qread | ~/.qmail instead of ~/.forward

   Alias right-hand sides you should be able to read (aliases(5)):
     support: user1, user2      deliver to several local users
     support: \user1            deliver locally, do not expand further
     support: /var/log/tickets  append to a file
     support: |/usr/local/bin/ticket.sh   pipe to a command
     support: :include:/etc/mail/support-list             read the list from a file

   Local-delivery detail that decides where the mail ends up:
     mbox    : one file per user, $mail_spool_directory/$USER (/var/mail/<user>)
     Maildir : one file per message; enabled with 'home_mailbox = Maildir/'
               (the trailing slash is what selects Maildir format)

 Citations: postconf(5), local(8), aliases(5), postqueue(1), postsuper(1) and
 postalias(1) at https://www.postfix.org/documentation.html ; objective wording
 at https://www.lpi.org/our-certifications/exam-102-objectives/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/108.3/lab)
