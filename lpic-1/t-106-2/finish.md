## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
    -geometry 99999x99999   nonsense resolution; use e.g. 1280x800.
    -rfbauth <file>         the VNC password file must exist and be 0600.
                            It is created with `vncpasswd`, not by hand.
    -localhost no           exposes RFB (5900+display) on every interface
                            in cleartext. VNC has no transport security;
                            the production answer is -localhost yes plus an
                            SSH tunnel: ssh -L 5901:localhost:5901 host.

  A working unit, and the verification:

    $ sudo -u student vncpasswd            # writes ~/.vnc/passwd, mode 0600
    $ sudo sed -i 's|^ExecStart=.*|ExecStart=/usr/bin/vncserver :1 -geometry 1280x800 -depth 24 -localhost yes|' \
          /etc/systemd/system/labvnc@.service
    $ sudo systemctl daemon-reload
    $ sudo systemctl start labvnc@student
    $ ss -lntp | grep 590
    LISTEN 0 5 127.0.0.1:5901 0.0.0.0:* users:(("Xtigervnc",pid=2210,fd=7))

  127.0.0.1, not 0.0.0.0 — that is the line to check. The alternative
  accepted answer for criterion E is to remove the unit entirely:

    $ sudo systemctl disable --now labvnc@student
    $ sudo rm /etc/systemd/system/labvnc@.service && sudo systemctl daemon-reload

  Know the neighbours too, because the objective lists them:
    - XDMCP  — the X protocol's own remote login (port 177/udp). Historic,
               unencrypted, disabled by default; you should be able to say
               why it is off, not how to turn it on.
    - RDP    — Microsoft's protocol; on Linux served by xrdp or by GNOME's
               built-in gnome-remote-desktop. Encrypted, the modern choice.
    - SPICE  — virtualisation-oriented (QEMU/KVM), with device redirection;
               the right answer for a VM console, not for a workstation.

  Reference: https://tigervnc.org/doc/vncserver.html

STEP 6 — Prove it, then prove it survives a reboot

    $ sudo /path/to/this-script.sh verify
      [PASS] A. Default target is graphical.target
      [PASS] B1. Display manager unit is active
      [PASS] B2. No laboratory drop-in override remains
      [PASS] C. Xwrapper allows console/anybody users
      [PASS] D1. At least one session desktop file exists
      [PASS] D2. No configuration still references the missing session
      [PASS] E. labvnc template is either valid or removed

    $ sudo systemctl reboot

  A fix that passes only while you are logged in is not a fix. The reboot
  is the acceptance test: set-default, the removed drop-in and the removed
  greeter drop-in are all persistent-state changes, and the reboot is what
  distinguishes them from a `systemctl isolate` that papered over the
  problem for the length of your session.

WHAT TO CARRY INTO THE EXAM

  * The display manager is selected by the display-manager.service symlink
    (and /etc/X11/default-display-manager on Debian), never by guesswork.
  * graphical.target vs multi-user.target is the modern runlevel 5 vs 3.
  * status=203/EXEC means the binary is missing; exit 127 from a session
    script means the same thing one layer down.
  * Xwrapper.config allowed_users is root | console | anybody.
  * Available sessions live in /usr/share/xsessions and
    /usr/share/wayland-sessions; DM configuration must name one of them.
  * VNC is cleartext: bind it to localhost and tunnel over SSH. XDMCP is
    legacy and unencrypted. RDP (xrdp) is the encrypted remote desktop.
    SPICE belongs to the virtualisation stack.
  * $XDG_SESSION_TYPE / loginctl show-session -p Type answers "X11 or
    Wayland?" without guessing from process names.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/106.2/lab)
