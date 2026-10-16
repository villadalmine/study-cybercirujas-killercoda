## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION — do not read this until you have solved it, or until you have
genuinely stalled. Each step is the reasoning first, the command second.

GATE 1 — COLLECTION: the journal is dropping everything

Symptom: the unit is active, it clearly runs (you can strace it, or watch
`ps`), yet `journalctl -u lab-order-service` is empty or near-empty, and
`systemctl status` shows no recent lines either. When a service is running
but its output is nowhere, the service is not the suspect — the sink is.

1. Ask what the effective journald configuration actually is. Never read
   /etc/systemd/journald.conf alone: drop-ins in *.conf.d/ win, and this is
   the single most common reason a config "looks right" and behaves wrong.

       systemd-analyze cat-config systemd/journald.conf

   The output is the merged view with each source file named. You will see:

       # /etc/systemd/journald.conf.d/99-lab-logging.conf
       [Journal]
       Storage=none
       RateLimitIntervalSec=60s
       RateLimitBurst=2

   Storage=none means journald receives every message and drops it on the
   floor. Forwarding to console/kernel/syslog would still work — which is
   exactly why this fault is invisible if you only test with `logger`.
   The rate limit is the second fault hiding behind the first: 2 messages
   per 60 s per service, so even with storage on you would lose ~58 of every
   60 events and see "Suppressed N messages from ..." in the journal.

2. Confirm the black hole from the other side:

       journalctl --disk-usage          # "Archived and active journals take up 0B"
       ls -ld /var/log/journal          # missing => volatile or disabled

3. Fix the drop-in. Keep it as a drop-in — that is the right shape — and set
   persistent storage with a sane rate limit. Editing the vendor file instead
   would work and would be worse practice.

       sudo tee /etc/systemd/journald.conf.d/99-lab-logging.conf >/dev/null <<'EOF'
       [Journal]
       Storage=persistent
       RateLimitIntervalSec=30s
       RateLimitBurst=10000
       SystemMaxUse=200M
       EOF

   Storage=persistent creates /var/log/journal and keeps logs across reboots.
   (Storage=auto only becomes persistent if /var/log/journal already exists —
   that asymmetry is exam material.) SystemMaxUse caps the growth so the fix
   does not create a disk-full incident later.

4. Apply it. Editing is not applying.

       sudo systemctl restart systemd-journald
       sudo systemctl restart lab-order-service
       journalctl -u lab-order-service -f -o short-precise

   You should now see one line per second — and, crucially, the evidence for
   gate 2 that was invisible until now:

       logger: failed to connect to 127.0.0.1 port 20514: Connection refused
       WARN collector 127.0.0.1:20514 unreachable, event dropped

   That chain is the lesson: a broken observability layer hides the outage
   beneath it. Always repair the pipeline top-down.

GATE 2 — TRANSPORT: the collector is listening on the wrong port

5. Take the client at its word. It says port 20514. Confirm what the
   application is contractually sending to:

       grep -n 'COLLECTOR_PORT' /usr/local/bin/lab-order-service
       # COLLECTOR_PORT="20514"

6. Ask what rsyslog actually opened:

       sudo ss -lntp | grep rsyslog
       # LISTEN 0 25 0.0.0.0:20515 ... users:(("rsyslogd",pid=...))

   Listening, healthy, and wrong. A listener on the wrong port is not a
   daemon failure, so nothing in `systemctl status rsyslog` hints at it.

7. Fix the input in /etc/rsyslog.d/60-lab-collector.conf:

       sudo sed -i 's/port="20515"/port="20514"/' /etc/rsyslog.d/60-lab-collector.conf

   Validate the configuration BEFORE restarting — rsyslog will happily start
   with half a config and log the rest as errors:

       sudo rsyslogd -N1
       # rsyslogd: version ..., config validation run (level 1), master config /etc/rsyslog.conf
       # rsyslogd: End of config validation run. Bye.

       sudo systemctl restart rsyslog
       sudo ss -lntp | grep 20514
       tail -f /var/log/lab/central/orders.log
       # 2026-09-18T12:41:07+00:00 lab-vm order-service ts=... order_id=412 ... status=accepted

8. If the port binds but nothing is written and the journal shows an rsyslog
   AVC or a "could not bind" error, you are on an SELinux box: 20514/tcp is
   labelled syslogd_port_t, which is why this lab uses it. For any other
   port you would need:

       sudo semanage port -a -t syslogd_port_t -p tcp <port>
       sudo ausearch -m avc -ts recent -c rsyslogd

GATE 3 — RETENTION: logrotate ignores the config, and then rotation orphans
         the writer

9. The file grows and never rotates. Do not guess — logrotate tells you, in
   dry-run mode, exactly what it skipped and why:

       sudo logrotate -d /etc/logrotate.conf 2>&1 | grep -i lab-app
       # Ignoring lab-app because of bad file mode - must be 0644 or 0444

   logrotate runs as root and executes postrotate scripts as root; a config
   file that any user can rewrite is a privilege-escalation path, so it
   refuses to read it. Same rule applies to configs owned by a non-root user
   (that error reads "because the file owner is wrong").

       stat -c '%a %U:%G %n' /etc/logrotate.d/lab-app
       # 666 root:root /etc/logrotate.d/lab-app
       sudo chmod 0644 /etc/logrotate.d/lab-app

10. Now force a rotation and watch what happens — this is the second, subtler
    fault, and the one that bites in production:

       sudo logrotate -f /etc/logrotate.d/lab-app
       ls -l /var/log/lab/central/
       # -rw-r----- 1 root adm      0 Sep 18 12:44 orders.log      <- frozen at 0
       # -rw-r----- 1 root adm 131072 Sep 18 12:45 orders.log.1    <- still growing

       sudo lsof -p "$(pidof rsyslogd)" | grep /var/log/lab
       # rsyslogd ... 7w REG 253,0 ... /var/log/lab/central/orders.log.1

    logrotate renamed the file; rsyslog still holds the old file descriptor,
    which follows the inode, not the name. Every new event lands in the
    rotated generation. Retention is now actively destroying data: five
    rotations later the events are deleted while orders.log sits empty.

11. Fix it by telling the writer to reopen its files after the rename:

       sudo tee /etc/logrotate.d/lab-app >/dev/null <<'EOF'
       /var/log/lab/central/orders.log {
           size 64k
           rotate 5
           compress
           delaycompress
           missingok
           notifempty
           create 0640 root adm
           sharedscripts
           postrotate
               /usr/bin/systemctl kill -s HUP rsyslog.service >/dev/null 2>&1 || true
           endscript
       }
       EOF
       sudo chmod 0644 /etc/logrotate.d/lab-app

    (On a host whose group 'adm' does not exist, use `create 0640 root root`.)

    Then verify the whole cycle end to end:

       sudo logrotate -f /etc/logrotate.d/lab-app
       sleep 5 && ls -l /var/log/lab/central/
       # orders.log is non-zero and climbing again

12. The alternative is `copytruncate`: logrotate copies the file and
    truncates the original in place, so the writer's fd stays valid and no
    signal is needed. Know the trade-off, because it is an exam favourite
    and a real operational choice:
      - copytruncate loses any event written between the copy and the
        truncate — a small, guaranteed data loss window every rotation;
      - it keeps the same inode, which a file-tailing shipper (Filebeat,
        Fluent Bit, Promtail) tracks — so the shipper does not re-read the
        file from byte 0, but it can miss the tail of the copy;
      - postrotate+HUP loses nothing but requires the writer to support
        reopening. rsyslog, nginx and haproxy all do. Use it when you can.

13. Confirm the timer that would have done this unattended, and why nothing
    rotated on its own during the lab (it runs daily, not on size):

       systemctl list-timers logrotate.timer
       systemctl cat logrotate.timer
       cat /var/lib/logrotate/status   # or /var/lib/logrotate.status on Debian

WHAT THIS MAPS TO ON THE EXAM (701-100, Log Management and Analysis)

- systemd-journald: Storage=, rate limiting, persistent vs volatile vs none,
  drop-in precedence, journalctl -u/-f/--since/--disk-usage/--verify.
- rsyslog as a central collector: module(load="imtcp"), input()/ruleset()/
  action() in RainerScript, templates and property replacers, rsyslogd -N1.
- The client side: RFC5424 framing, facility/severity (local3.info,
  local3.err), and why an application should not care where the aggregator is.
- logrotate: config discovery in /etc/logrotate.d, file-mode/ownership
  refusal, size vs daily, create vs copytruncate, postrotate/sharedscripts,
  and the rotated-inode problem shared by every long-running writer.
- The pipeline idea: this single file is the seam where a shipper
  (Filebeat/Fluentd) picks up, a parser (Logstash grok/dissect) structures
  `key=value` pairs, and a store (Elasticsearch/OpenSearch) indexes them for
  Kibana. Every fault above breaks that chain before it starts — which is why
  log pipelines are debugged from the source outwards, never from the
  dashboard inwards.

Source for the objectives:
  https://www.lpi.org/our-certifications/exam-701-objectives/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpi-devops/704.3/lab)
