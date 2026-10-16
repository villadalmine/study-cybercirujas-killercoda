## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION — DO NOT READ UNTIL YOU HAVE TRIED

SCENARIO 1 — cmdline (kernel parameter forces emergency mode)
The chain to keep in mind: firmware (BIOS/UEFI) -> boot loader (GRUB 2) ->
kernel + initramfs -> PID 1 (systemd). Here every stage succeeded. systemd
started, read its command line, saw systemd.unit=emergency.target and obeyed.

 1) Log in at the emergency prompt with the root password, then read the
    evidence — the kernel's own copy of what it was launched with:

        # cat /proc/cmdline
        BOOT_IMAGE=/vmlinuz-6.1.0-18-amd64 root=UUID=8f3a... ro systemd.unit=emergency.target
                                                               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    Confirm it from systemd's own point of view:
        # systemctl get-default
        graphical.target            <- the DEFAULT is fine; the cmdline overrode it
        # journalctl -b | grep -i 'emergency\|Reached target'
    Precedence rule to memorise: systemd.unit= on the kernel command line
    BEATS /etc/systemd/system/default.target. The disk was never the problem.

 2) Recover the CURRENT boot without rebooting:
        # systemctl default                       # go to the configured default
        # systemctl isolate multi-user.target     # or an explicit target
    The machine finishes booting: network up, sshd up, getty on the ttys.

 3) Make it permanent. Two families of systems:

    (a) Debian/Ubuntu/openSUSE and any non-BLS GRUB 2 system — edit the SOURCE,
        never /boot/grub/grub.cfg (it is generated and will be overwritten):
            # cp /etc/default/grub /etc/default/grub.bak
            # vi /etc/default/grub
              GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"     <- remove the injected arg
            # update-grub                    # Debian/Ubuntu wrapper
            # grub2-mkconfig -o /boot/grub2/grub.cfg        # RHEL-family equivalent
            Generating grub configuration file ...
            Found linux image: /boot/vmlinuz-6.1.0-18-amd64
            done

    (b) RHEL/CentOS/Alma/Rocky 8+ and Fedora (BootLoaderSpec): grub.cfg does
        NOT hold the command line; /boot/loader/entries/*.conf does.
            # grubby --info=ALL | grep args
            # grubby --update-kernel=ALL --remove-args="systemd.unit=emergency.target"
            # grubby --update-kernel=ALL --args="quiet"
            # grubby --info=ALL | grep args        # verify
        (/etc/kernel/cmdline is the template used for NEW kernels there.)

 4) Reboot and prove it:
        # systemctl reboot
        # cat /proc/cmdline        # the parameter is gone
        # systemctl is-system-running -> running

 Exam-relevant variant you should also be able to do: the ONE-BOOT fix from
 the GRUB menu — highlight the entry, press 'e', move to the line starting
 with 'linux' (or 'linuxefi'), delete the offending parameter (or append
 systemd.unit=multi-user.target, or 'single' / 'init=/bin/bash' for a rescue),
 then Ctrl-x / F10 to boot. Nothing typed in that editor is persistent; that
 is exactly why it is safe, and exactly why step 3 is still required.

SCENARIO 2 — initramfs (missing initial RAM filesystem)
Broken arrow: kernel -> initramfs. GRUB loads vmlinuz fine, then fails to load
the cpio archive that contains the storage/LVM/RAID/crypt modules and the
early /init. Without it the kernel has no driver for the root device, so
"Unable to mount root fs on unknown-block(0,0)" and panic.

 1) Recover ONE boot. Either:
    (a) GRUB menu -> "Advanced options for <distro>" -> pick an OLDER kernel,
        which still has its own initramfs; or
    (b) point this entry at the backup image. Press 'e' and change:
            initrd  /boot/initrd.img-6.1.0-18-amd64
        to
            initrd  /boot/initrd.img-6.1.0-18-amd64.lab-101.2-backup
        Ctrl-x to boot. If you are unsure of the exact filename, press 'c' for
        the GRUB command line and explore — GRUB has its own filesystem drivers:
            grub> ls
            (hd0) (hd0,gpt1) (hd0,gpt2)
            grub> ls (hd0,gpt2)/boot/
            grub> set root=(hd0,gpt2)
            grub> linux /boot/vmlinuz-6.1.0-18-amd64 root=UUID=8f3a... ro
            grub> initrd /boot/initrd.img-6.1.0-18-amd64.lab-101.2-backup
            grub> boot

 2) Rebuild the real image with the distribution's tool:
        Debian/Ubuntu:
            # update-initramfs -c -k 6.1.0-18-amd64     # create
            # update-initramfs -u -k all                # or update all
            update-initramfs: Generating /boot/initrd.img-6.1.0-18-amd64
            # lsinitramfs /boot/initrd.img-6.1.0-18-amd64 | head
        RHEL/Fedora:
            # dracut --force /boot/initramfs-$(uname -r).img $(uname -r)
            # lsinitrd /boot/initramfs-$(uname -r).img | head
    Then verify size and ownership:
            # ls -lh /boot/initrd.img-*        # tens of MB, root:root, 0600/0644

 3) On non-BLS systems refresh the boot loader config so the menu points at the
    correct file, and remove the rescue copy:
            # update-grub          (or: grub2-mkconfig -o /boot/grub2/grub.cfg)
            # rm -f /boot/initrd.img-*.lab-101.2-backup

 4) Reboot on the DEFAULT entry, then confirm the early boot from the logs:
            # uname -r
            # dmesg | head -40
            # journalctl -b -k | grep -i 'Freeing initrd\|Unpacking initramfs'

 Note the difference you may have met on the way: 'grub>' is the full GRUB
shell (modules loaded, you can boot by hand as above); 'grub rescue>' is the
minimal one — there you must 'set prefix=(hdX,Y)/boot/grub', 'insmod normal',
'normal', and afterwards run grub-install + update-grub from the running system.

SCENARIO 3 — default target (rescue.target)
 1) Diagnose:
        # systemctl get-default
        rescue.target
        # ls -l /etc/systemd/system/default.target
        lrwxrwxrwx 1 root root 40 ... /etc/systemd/system/default.target -> /lib/systemd/system/rescue.target
        # systemctl list-units --type=target --all | head
        # journalctl -b | grep 'Reached target'
    'systemctl get-default' simply reads that symlink; 'set-default' rewrites it.

 2) Fix the current boot:
        # systemctl isolate multi-user.target      # or graphical.target
    ('isolate' starts that target and stops everything not required by it —
     the systemd equivalent of 'telinit 3' / 'telinit 5'.)

 3) Fix it permanently:
        # systemctl set-default multi-user.target
        Removed /etc/systemd/system/default.target.
        Created symlink /etc/systemd/system/default.target -> /lib/systemd/system/multi-user.target
    On a desktop VM the target was graphical.target and it was ALSO masked:
        # systemctl is-enabled graphical.target
        masked
        # ls -l /etc/systemd/system/graphical.target
        lrwxrwxrwx 1 root root 9 ... /etc/systemd/system/graphical.target -> /dev/null
        # systemctl unmask graphical.target
        # systemctl set-default graphical.target
    masked (symlink to /dev/null, cannot be started even as a dependency) is
    strictly stronger than disabled (not started at boot, but startable).

 4) Reboot and check:
        # systemctl get-default ; systemctl is-system-running ; systemctl --failed

    Runlevel map worth memorising for the exam: 0 -> poweroff.target,
    1/s/single -> rescue.target, 2/3/4 -> multi-user.target,
    5 -> graphical.target, 6 -> reboot.target; 'runlevel' and 'telinit' still
    work through systemd's compatibility layer. On a SysVinit system the same
    permanent change would be the 'initdefault' line in /etc/inittab
    (id:3:initdefault:), and on Upstart, /etc/init/rc-sysinit.conf.

SCENARIO 4 — fstab (phantom device blocks local-fs.target)
systemd-fstab-generator turns every /etc/fstab line into a .mount unit at boot,
and a fsck-order (6th field) that is not 0 plus the absence of 'nofail' makes
that mount REQUIRED by local-fs.target. The device never appears, the .device
unit times out after 90 s, local-fs.target fails, and systemd falls into
emergency mode.

 1) Diagnose from the emergency shell:
        # systemctl --failed
        UNIT                        LOAD   ACTIVE SUB    DESCRIPTION
        mnt-lab\x2dphantom.mount    loaded failed failed /mnt/lab-phantom
        # journalctl -xb -p err
        Timed out waiting for device /dev/disk/by-uuid/dead1012-...
        Dependency failed for /mnt/lab-phantom.
        # systemd-escape -p --suffix=mount /mnt/lab-phantom
        mnt-lab\x2dphantom.mount
        # blkid            # the UUID in fstab is nowhere in this list
        # lsblk -f

 2) The emergency shell frequently gives you / read-only. Before editing:
        # mount -o remount,rw /

 3) Repair /etc/fstab — remove the line, or keep it and make it non-fatal:
        # vi /etc/fstab
          # either delete the entry, or:
          UUID=dead1012-...  /mnt/lab-phantom  ext4  defaults,nofail,x-systemd.device-timeout=10s  0 0
    'nofail' = do not fail the boot if it is missing; the timeout caps the wait
    at 10 s instead of 90; setting the 6th field to 0 keeps fsck out of the way.
    For a genuinely optional or slow device, 'noauto,x-systemd.automount' is the
    production answer: mount on first access, never at boot.

 4) VALIDATE BEFORE REBOOTING — this is the part that separates an operator
    from a gambler:
        # findmnt --verify --verbose
        Success, no errors or warnings detected
        # systemctl daemon-reload      # regenerate the .mount units from fstab
        # mount -a                     # must print nothing
        # systemctl reset-failed

 5) Finish the current boot and then reboot:
        # systemctl default
        # systemctl reboot
        # systemctl is-system-running          -> running
        # systemctl --failed                   -> 0 loaded units listed
        # journalctl -b -p err                 -> empty

GENERAL DEBUGGING TOOLKIT FOR 101.2 (applies to all four scenarios)
  cat /proc/cmdline                 what the running kernel was actually given
  dmesg | less                      kernel ring buffer (early boot, drivers)
  dmesg -T -l err,warn              human timestamps, errors only
  journalctl -b                     this boot;  -b -1 the previous one
  journalctl -xb -p err             errors of this boot with unit explanations
  journalctl -k                     kernel messages only (= dmesg, persistent)
  systemd-analyze                   total boot time, firmware/loader/kernel split
  systemd-analyze blame             slowest units — where 90 s hangs show up
  systemd-analyze critical-chain    the dependency path that determined the time
  systemctl list-jobs               what is stuck RIGHT NOW during a hang
  /var/log/boot.log , /var/log/messages , /var/log/syslog   (non-journal distros)
  Useful one-boot kernel arguments typed in the GRUB editor:
    systemd.unit=rescue.target | emergency.target   choose the boot target
    single                                          single user (SysVinit style)
    init=/bin/bash                                  bypass init entirely (rw remount needed)
    systemd.log_level=debug systemd.log_target=console   verbose PID 1
    rd.break (dracut) / break (Debian initramfs)    stop inside the initramfs
    nomodeset                                       blank-screen graphics failures

Reference: LPI Exam 101-500 objectives, topic 101.2 —
  https://www.lpi.org/our-certifications/exam-101-objectives/
  https://www.gnu.org/software/grub/manual/grub/grub.html
  https://www.freedesktop.org/software/systemd/man/latest/bootup.html
  https://www.freedesktop.org/software/systemd/man/latest/systemd-fstab-generator.html
  https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/101.2/lab)
