## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION - do not read until you have tried it

 STEP 0 - Observe before touching anything
   # lpstat -t
   lpstat: Scheduler is not running

 "lpstat -t" is the single most useful command of this objective: it prints
 the scheduler status, the default destination, every device URI, every
 queue's acceptance state, every queue's enabled state and all pending jobs.
 When it cannot connect, stop diagnosing the queue and go one layer down.

   # systemctl status cups.service cups.socket cups.path
   # systemctl is-enabled cups.service cups.socket
   disabled
   disabled


 STEP 1 - FAULT 5: bring the scheduler back, permanently
   # systemctl enable --now cups.socket cups.service
   # systemctl start cups.path 2>/dev/null || true
   # lpstat -r
   scheduler is running

 Why the socket too: on systemd distributions cupsd is socket-activated.
 cups.socket owns /run/cups/cups.sock and TCP 631 and starts cups.service on
 the first client connection. Enabling only cups.service leaves the machine
 working now and broken after the next reboot for anything that relies on
 activation - and "enabled" is objective A of this lab.
 On a SysV/OpenRC box the equivalent is:
   # /etc/init.d/cups start ; update-rc.d cups enable      (Debian)
   # rc-update add cupsd default ; rc-service cupsd start  (Alpine/OpenRC)


 STEP 2 - FAULT 1: the queue is paused
   # lpstat -p lab-printer
   printer lab-printer disabled since ... - scheduled maintenance - lab fault 1
   # lpq -P lab-printer
   lab-printer is not ready
   Rank    Owner   Job     File(s)                 Total Size
   1st     root    1       monthly-report          1024 bytes
   2nd     root    2       payroll-export          2048 bytes

 Release it:
   # cupsenable lab-printer
   # lpstat -p lab-printer
   printer lab-printer is idle.  enabled since ...

 "disabled" means: the queue keeps ACCEPTING jobs but does not SEND them to
 the device. That is exactly what you want while you service a printer -
 users see no error, the work waits. It is also why a paused queue is such a
 common silent outage.


 STEP 3 - FAULT 2: the queue refuses new jobs
   # lpstat -a lab-printer
   lab-printer not accepting requests since ... - queue closed by helpdesk - lab fault 2
   # lp -d lab-printer /etc/hostname
   lp: Destination "lab-printer" is not accepting jobs.

   # cupsaccept lab-printer
   # lpstat -a lab-printer
   lab-printer accepting requests since ...

 enabled/disabled and accepting/rejecting are ORTHOGONAL. Memorise the pairs:
    cupsenable / cupsdisable  -> printing to the device   (lpstat -p)
    cupsaccept / cupsreject   -> intake of new jobs        (lpstat -a)
 The legacy System V equivalents are "enable/disable" and "accept/reject";
 CUPS ships the cups*-prefixed names to avoid clashing with the shell builtin
 "enable". Both accept "-r 'reason'", and the reason is what the user sees.


 STEP 4 - FAULT 3: the default destination points at a ghost
   # lpstat -d
   system default destination: office-laser-2f
   # lp /etc/hostname
   lp: Error - The printer or class does not exist.
   # grep -r Default /etc/cups/lpoptions ~/.cups/lpoptions 2>/dev/null
   /etc/cups/lpoptions:Default office-laser-2f

 Fix it. Either set the SERVER-side default (applies to every user):
   # lpadmin -d lab-printer
 or the CLIENT-side default in lpoptions (this is what was tampered with):
   # lpoptions -d lab-printer          # writes ~/.cups/lpoptions for this user
   # sed -i 's/^Default .*/Default lab-printer/' /etc/cups/lpoptions   # system-wide
 Cleanest here is to delete the injected line and let the server default win:
   # rm -f /etc/cups/lpoptions
   # lpadmin -d lab-printer
   # lpstat -d
   system default destination: lab-printer

 Precedence, highest first: the -d/-P option on the command line, then
 $PRINTER / $LPDEST in the environment, then ~/.cups/lpoptions, then
 /etc/cups/lpoptions, then the scheduler's default from printers.conf.


 STEP 5 - FAULT 4: the device URI points nowhere
 Submit a job now and it fails, and the queue stops itself again:
   # lp -d lab-printer /etc/hostname
   request id is lab-printer-3 (1 file(s))
   # lpstat -p lab-printer
   printer lab-printer disabled since ... -
           Unable to open device file "/var/spool/cups-lab-typo/lab-printer.out"
   # journalctl -u cups -n 20 --no-pager        # or: tail -20 /var/log/cups/error_log
   E [...] [Job 3] Unable to open file "/var/spool/cups-lab-typo/lab-printer.out": No such file or directory

 Compare configured URI against reachable URIs:
   # lpstat -v
   device for lab-printer: file:///var/spool/cups-lab-typo/lab-printer.out
   # lpinfo -v | grep -i file
   file file:///...

 Repoint it (never hand-edit /etc/cups/printers.conf while cupsd runs - the
 scheduler rewrites that file from memory and your edit disappears):
   # lpadmin -p lab-printer -v file:///var/spool/cups-lab/lab-printer.out
   # lpstat -v lab-printer
   device for lab-printer: file:///var/spool/cups-lab/lab-printer.out

 Clear the poisoned jobs and release the queue again:
   # lpstat -o lab-printer            # or: lpq -P lab-printer
   # cancel -a lab-printer            # or: lprm -P lab-printer -   /  cancel lab-printer-3
   # cupsenable lab-printer

 Note the trap you just walked into: printer-error-policy=stop-printer means
 a single unprintable job pauses the queue for everybody. In production you
 often prefer:
   # lpadmin -p lab-printer -o printer-error-policy=retry-job
 (values: abort-job, retry-job, retry-current-job, stop-printer)


 STEP 6 - Prove it end to end
   # lp -d lab-printer -t proof /etc/os-release
   request id is lab-printer-4 (1 file(s))
   # sleep 3; head -n2 /var/spool/cups-lab/lab-printer.out
   NAME="Debian GNU/Linux"
   VERSION_ID="12"
   # lpstat -t
   scheduler is running
   system default destination: lab-printer
   device for lab-printer: file:///var/spool/cups-lab/lab-printer.out
   lab-printer accepting requests since ...
   printer lab-printer is idle.  enabled since ...

   # <this script> --verify
   Score: 5/5 - PASS


 APPENDIX - the rest of the 108.4 toolbox, and what to check next time
 Legacy BSD/SysV front-ends, all implemented by CUPS:
   lpr -P queue file / lp -d queue file      submit
   lpq -P queue      / lpstat -o queue       list jobs
   lprm -P queue 3   / cancel queue-3        remove a job
   lpc status                                terse per-queue status
 Queue administration:
   lpadmin -p q -E -v <uri> -m everywhere    create/modify (driverless IPP)
   lpadmin -x q                              delete a queue
   lpadmin -p q -c group                     add the queue to a class
   lpoptions -p q -l                         list options and their defaults
   lpinfo -v / lpinfo -m                     available devices / models
   cupsctl --debug-logging                   raise LogLevel without editing files
   cupsctl --remote-any / --share-printers   sharing switches (cupsd.conf)
 Files that matter:
   /etc/cups/cupsd.conf     Listen/Port, Browsing, access control, LogLevel
   /etc/cups/cups-files.conf  User/Group, ErrorLog, FileDevice, SystemGroup
   /etc/cups/printers.conf  queue database - owned by cupsd, not by you
   /etc/cups/ppd/<q>.ppd    per-queue driver
   /var/spool/cups/         c<NNNNN> control files, d<NNNNN>-001 data files
   /var/log/cups/{error,access,page}_log   (or the journal on systemd distros)
 Two more failure modes worth rehearsing on this VM:
   - "Unable to connect to server" after editing cupsd.conf: run
     "cupsd -t" to test the configuration before restarting.
   - Remote clients rejected: Listen bound to localhost only, or the
     <Location /> block still says "Order allow,deny / Allow localhost".

 Sources:
   LPI 101/102 objectives - https://www.lpi.org/our-certifications/exam-101-objectives/
   CUPS documentation     - https://openprinting.github.io/cups/
   man pages              - cupsd.conf(5) cups-files.conf(5) lpadmin(8)
                            lpstat(1) lp(1) lpr(1) cupsenable(8) cupsaccept(8)
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/108.4/lab)
