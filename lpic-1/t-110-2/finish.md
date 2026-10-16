## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION -- do not read this until you have tried the lab

 F1 -- SHADOW PASSWORDS
 1. Confirm the exposure. The second field of /etc/passwd should be "x";
    here it holds the real hash, in a file mode 0644:

      # ls -l /etc/passwd /etc/shadow
      -rw-r--r--. 1 root root 2109 Aug 31 10:02 /etc/passwd
      ls: cannot access '/etc/shadow': No such file or directory
      # getent passwd root | cut -d: -f1,2
      root:$y$j9T$Xk1oI0h...

 2. Move the hashes back into the shadow file. pwconv reads /etc/passwd,
    recreates /etc/shadow with the correct restrictive mode, and replaces
    each hash with "x". It is the exact inverse of pwunconv:

      # pwconv
      # grpconv          # same operation for /etc/group -> /etc/gshadow

 3. Verify content and permissions. Debian-family ships 0640 root:shadow,
    RHEL-family ships 0000 root:root -- both are correct, what matters is
    that "other" has no access at all:

      # getent passwd root | cut -d: -f1,2
      root:x
      # ls -l /etc/shadow
      -rw-r-----. 1 root shadow 1284 Aug 31 10:05 /etc/shadow
      # chmod 0640 /etc/shadow && chown root:shadow /etc/shadow    # if needed
      # chmod 0644 /etc/passwd && chown root:root  /etc/passwd

 4. Sanity-check the databases before you log out:

      # pwck -r
      # grpck -r

    Reference: shadow(5), pwconv(8), pwck(8).


 F2 -- SUDO
 1. Audit what the user can actually do. Never guess from the file, ask sudo:

      # sudo -l -U labuser
      Matching Defaults entries for labuser on lab:
          !authenticate
      User labuser may run the following commands on lab:
          (ALL : ALL) NOPASSWD: ALL

 2. Find where it comes from. /etc/sudoers pulls in a directory:

      # grep -E '^@?include' /etc/sudoers
      @includedir /etc/sudoers.d
      # ls -l /etc/sudoers.d/
      -r--r-----. 1 root root 221 Aug 31 10:02 99-lab-legacy

 3. Fix it. Either drop the rule entirely:

      # rm -f /etc/sudoers.d/99-lab-legacy

    ...or, if the role genuinely needs something, edit it with visudo so the
    file is syntax-checked before it is saved, and grant least privilege:

      # visudo -f /etc/sudoers.d/99-lab-legacy
        labuser ALL=(root) /usr/bin/systemctl status *, /usr/bin/journalctl
      # chmod 0440 /etc/sudoers.d/99-lab-legacy

    Note that even that narrow rule deserves scrutiny: a wildcard on a
    command that can spawn a pager or a shell is a privilege escalation.

 4. Re-check the whole policy and the resulting privileges:

      # visudo -c
      /etc/sudoers: parsed OK
      /etc/sudoers.d/99-lab-legacy: parsed OK
      # sudo -l -U labuser

    Reference: sudoers(5), visudo(8) -- https://www.sudo.ws/docs/man/sudoers.man/


 F3 -- THE UNNEEDED NETWORK SERVICE
 1. Enumerate listening sockets and attribute each one to a process:

      # ss -ltnp
      State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
      LISTEN 0      5      127.0.0.1:8099     0.0.0.0:*  users:(("python3",pid=921,fd=3))
      LISTEN 0      128    0.0.0.0:22         0.0.0.0:*  users:(("sshd",pid=744,fd=3))

      (equivalents: netstat -ltnp, lsof -i -P -n, fuser -n tcp 8099)

 2. Trace the PID back to its unit / super-server entry:

      systemd VM:  # systemctl status 921
                   # systemctl disable --now lab-legacy-fileshare.service
                   # rm /etc/systemd/system/lab-legacy-fileshare.service
                   # systemctl daemon-reload

      xinetd VM:   # grep -R . /etc/xinetd.d/lab-echo
                   edit the file:  disable = yes      (or delete the file)
                   # systemctl reload xinetd

      inetd VM:    # grep echo /etc/inetd.conf
                   comment the line out with a leading '#'
                   # systemctl restart inetd

    On SysV-init systems the persistent-enable step is the runlevel symlink
    set: 'chkconfig <svc> off' or 'update-rc.d <svc> disable', over
    /etc/init.d/ and /etc/rc?.d/.

 3. Prove the socket is gone and does not come back:

      # ss -ltnp | grep -c ':8099'
      0
      # systemctl is-enabled lab-legacy-fileshare.service
      Failed to get unit file state ...: No such file or directory

    Reference: xinetd.conf(5), inetd.conf(5), systemctl(1).


 F4 -- TCP WRAPPERS
 1. Understand the evaluation order: /etc/hosts.allow is read first and the
    FIRST matching rule wins; /etc/hosts.deny is consulted only if nothing
    matched. Access is granted if neither file matches. So a default-deny in
    hosts.deny plus explicit exceptions in hosts.allow is the correct shape --
    the bug here is that the only exception names a daemon ("ssdh") that does
    not exist.

      # cat /etc/hosts.deny
      ALL: ALL
      # cat /etc/hosts.allow
      ssdh: LOCAL
      # tcpdmatch in.telnetd 127.0.0.1
      matched:  /etc/hosts.deny line 3
      access:   denied

 2. Write real exceptions. Keep the default-deny, fix the daemon name, and
    allow the loopback interface explicitly:

      # cat > /etc/hosts.allow <<'RULES'
      ALL: 127.0.0.1 [::1]
      in.telnetd: LOCAL
      RULES
      # chmod 0644 /etc/hosts.allow

    'LOCAL' matches hostnames without a dot; 127.0.0.1 and [::1] are the
    unambiguous forms. Never write 'ALL: ALL' in hosts.allow -- it silently
    disables the entire policy.

 3. Validate statically, then re-test the match:

      # tcpdchk -v
      # tcpdmatch in.telnetd 127.0.0.1
      matched:  /etc/hosts.allow line 1
      access:   granted

 4. Know the limit of this mechanism: it only applies to daemons linked
    against libwrap (ldd $(which vsftpd) | grep libwrap) or launched through
    tcpd from a super-server. OpenSSH removed libwrap support in 6.7, and
    most modern distributions no longer ship wrapped daemons at all -- on
    those systems the equivalent controls are nftables/firewalld and
    systemd socket options (IPAddressAllow=, IPAddressDeny=).

    Reference: hosts_access(5), hosts_options(5), tcpdchk(8), tcpdmatch(8).


 F5 -- /etc/nologin
 1. Reproduce and read the message -- pam_nologin prints the file's contents
    and then refuses the session for every account whose UID is not 0:

      $ ssh labuser@localhost
      System maintenance in progress. Interactive logins are disabled.
      Connection closed by 127.0.0.1 port 22

 2. Find the enforcing module:

      # grep -R nologin /etc/pam.d/
      /etc/pam.d/sshd:account    required     pam_nologin.so
      /etc/pam.d/login:auth      requisite    pam_nologin.so

 3. Remove the marker files. pam_nologin honours /etc/nologin and, on systemd
    systems, /run/nologin (created by shutdown to fence off late logins):

      # rm -f /etc/nologin /run/nologin
      $ ssh labuser@localhost      # logs in normally again

    Note there is no daemon restart involved: the file is checked at every
    authentication. And note the deliberate asymmetry -- root is exempt, which
    is what makes this a safe maintenance switch instead of a self-inflicted
    lockout.

    Reference: pam_nologin(8), nologin(5).


 FINAL STEP
      # ./lpic1-110.2-break-and-fix.sh --verify
        [ PASS ] F1: shadow passwords restored and permissions are sane
        [ PASS ] F2: the blanket sudo grant is gone
        [ PASS ] F3: the unneeded service is down and stays down
        [ PASS ] F4: /etc/hosts.allow grants loopback and the default-deny is intact
        [ PASS ] F5: interactive logins are allowed again
        All checks passed -- the host is back to a defensible state.

 If you got stuck, '--restore' rolls everything back from the snapshots and
 you can run '--break' again from a clean baseline.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/110.2/lab)
