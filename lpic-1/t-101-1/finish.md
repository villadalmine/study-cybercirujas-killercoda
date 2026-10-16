## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION - do not read before you have worked the four faults.

 General method for this objective: the kernel exposes hardware state in
 three places, and every fault below lives in one of them.
   /proc  - process and kernel interface (/proc/modules, /proc/cpuinfo,
            /proc/interrupts, /proc/iomem, /proc/sys/*)
   /sys   - sysfs, the device model (/sys/module, /sys/block,
            /sys/devices/system/cpu, /sys/class)
   /dev   - device nodes, populated by devtmpfs and named by udev
 Persistent configuration for the first two lives in /etc/modprobe.d and
 /etc/sysctl.d; for the third, in /etc/udev/rules.d.

 FAULT A - the module that refuses to load

 1) Confirm the module exists on disk, so this is configuration and not a
    missing kernel package:

      # modinfo -n dummy
      /lib/modules/6.x.y/kernel/drivers/net/dummy.ko.xz

 2) Ask modprobe what it WOULD do, without doing it.  This is the single
    most useful command of the objective:

      # modprobe -n -v dummy
      install /bin/false

    A normal module would print "insmod /lib/modules/.../dummy.ko.xz".
    "install /bin/false" means some configuration file replaced the load
    action with a command that always fails.

 3) Dump the effective configuration and find the offending file:

      # modprobe --showconfig | grep -E '(blacklist|install) dummy'
      blacklist dummy
      install dummy /bin/false

      # grep -R dummy /etc/modprobe.d /lib/modprobe.d /usr/lib/modprobe.d 2>/dev/null
      /etc/modprobe.d/zz-lab-101-1.conf:blacklist dummy
      /etc/modprobe.d/zz-lab-101-1.conf:install dummy /bin/false

    Files are read in lexical order, which is why "zz-" wins over the
    distribution defaults.  See modprobe.d(5).

 4) Remove the override (or comment out the two lines) and load the module:

      # rm -f /etc/modprobe.d/zz-lab-101-1.conf
      # modprobe -n -v dummy
      insmod /lib/modules/6.x.y/kernel/drivers/net/dummy.ko.xz
      # modprobe dummy

 5) Prove it, from both interfaces:

      # lsmod | grep dummy
      dummy                  16384  0
      # grep ^dummy /proc/modules
      dummy 16384 0 - Live 0xffffffffc0a12000
      # ls /sys/module/dummy/
      coresize  drivers  holders  initsize  initstate  notes  refcnt  sections  srcversion  taint  uevent

    Note: "blacklist" alone only stops AUTOloading by alias; an explicit
    "modprobe dummy" would still have worked.  It was the "install" line
    that blocked the manual load.  Recognising which of the two you are
    facing is exactly what the exam asks for.

 FAULT B - the udev symlink that is never created

 1) Identify the real device and check that the kernel side is healthy:

      # losetup -a
      /dev/loop0: [64768]:1234 (/var/lib/lab-101-1/labdisk.img)
      # ls -l /dev/loop0 /dev/labdisk
      brw-rw---- 1 root disk 7, 0 ... /dev/loop0
      ls: cannot access '/dev/labdisk': No such file or directory

    The node exists (devtmpfs created it); only the udev-managed NAME is
    missing.  So the fault is in a rule, not in the driver.

 2) Ask udev to replay the rules for that device.  udevadm test is the
    debugger for this objective:

      # udevadm test /sys/block/loop0 2>&1 | grep -i -E 'labdisk|symlink'
      (no LINK 'labdisk' line at all)

    The rule is parsed without a syntax error, so it is matching wrongly,
    not failing to load.

 3) Read the rule and compare each key against reality:

      # cat /etc/udev/rules.d/99-lab-101-1.rules
      ACTION!="remove", SUBSYSTEM=="block", KERNEL=="loop", \
        ATTR{loop/backing-file}=="/var/lib/lab-101-1/labdisk.img", SYMLINK+="labdisk"

      # udevadm info --query=all --name=/dev/loop0
      P: /devices/virtual/block/loop0
      N: loop0
      E: SUBSYSTEM=block
      E: DEVTYPE=disk

      # udevadm info --attribute-walk --name=/dev/loop0 | grep -i backing
      ATTR{loop/backing_file}="/var/lib/lab-101-1/labdisk.img"

    Two silent mismatches:
      - KERNEL=="loop"  never matches: the kernel name is "loop0".
        Use a glob: KERNEL=="loop*".
      - ATTR{loop/backing-file} does not exist; the sysfs attribute is
        loop/backing_file (underscore).  A non-existent attribute simply
        never matches, which is why nothing is logged.

 4) Write the correct rule:

      # cat > /etc/udev/rules.d/99-lab-101-1.rules <<'RULE'
      ACTION!="remove", SUBSYSTEM=="block", KERNEL=="loop*", \
        ATTR{loop/backing_file}=="/var/lib/lab-101-1/labdisk.img", SYMLINK+="labdisk"
      RULE

    (Keep it on one physical line, or end continued lines with a backslash.)

 5) Reload the rule set and replay the event.  Editing a rule file does
    nothing by itself - this two-step is the point of the exercise:

      # udevadm control --reload
      # udevadm trigger --action=change /sys/block/loop0
      # udevadm settle
      # ls -l /dev/labdisk
      lrwxrwxrwx 1 root root 5 ... /dev/labdisk -> loop0

 6) Cross-check with the persistent names udev builds by default:

      # ls -l /dev/disk/by-path/ /dev/disk/by-id/ 2>/dev/null | head
      # udevadm monitor --udev --subsystem-match=block     (watch live events)

 FAULT C - dmesg denied to unprivileged users

 1) Reproduce as a normal user, then read the tunable:

      $ dmesg
      dmesg: read kernel buffer failed: Operation not permitted
      # cat /proc/sys/kernel/dmesg_restrict
      1
      # sysctl -n kernel.dmesg_restrict
      1

    kernel.dmesg_restrict=1 means only CAP_SYSLOG (in practice root) may
    read the ring buffer.  See the kernel sysctl documentation.

 2) Fix it at runtime AND persistently.  Doing only one of the two is the
    classic half-fix:

      # sysctl -w kernel.dmesg_restrict=0        (runtime, lost on reboot)
      # grep -R dmesg_restrict /etc/sysctl.conf /etc/sysctl.d /usr/lib/sysctl.d
      /etc/sysctl.d/99-lab-101-1.conf:kernel.dmesg_restrict = 1
      # rm -f /etc/sysctl.d/99-lab-101-1.conf
      # sysctl --system | grep dmesg

    If your site policy needs an explicit value, write
    "kernel.dmesg_restrict = 0" into /etc/sysctl.d/99-local.conf instead of
    deleting the file - the grader accepts either, as long as nothing sets 1.

 3) Verify from the unprivileged account:

      $ dmesg -T | tail -n 5
      [Tue Aug 25 10:12:03 2026] loop0: detected capacity change from 0 to 262144

    Note how dmesg is the primary evidence channel for hardware faults:
    driver probe failures, missing firmware, IRQ conflicts and USB resets
    all land here first.

 FAULT D - the missing CPU

 1) Compare what the kernel presents with what the VM really has:

      # nproc
      1
      # lscpu | grep -E 'CPU\(s\)|On-line|Off-line'
      CPU(s):                  2
      On-line CPU(s) list:     0
      Off-line CPU(s) list:    1
      # grep -c ^processor /proc/cpuinfo
      1

    "CPU(s): 2" with "Off-line CPU(s) list: 1" proves the hardware is
    present and the kernel deliberately parked it - not a hypervisor issue.

 2) Confirm in sysfs, which is where the state actually lives:

      # cat /sys/devices/system/cpu/online
      0
      # cat /sys/devices/system/cpu/present
      0-1
      # cat /sys/devices/system/cpu/cpu1/online
      0

 3) Bring it back online - no reboot needed:

      # echo 1 > /sys/devices/system/cpu/cpu1/online
      # nproc
      2
      # lscpu | grep -E 'On-line|Off-line'
      On-line CPU(s) list:     0,1
      # dmesg -T | tail -n 3
      [...] smpboot: Booting Node 0 Processor 1 APIC 0x1

    A loop for a machine with many parked CPUs:
      # for c in /sys/devices/system/cpu/cpu[0-9]*/online; do echo 1 > "$c"; done

    Remember that this state is volatile: it resets on reboot unless a boot
    parameter (maxcpus=, nosmp, possible_cpus=) or a tuning service sets it.
    If a CPU keeps disappearing after every boot, check /proc/cmdline:
      # cat /proc/cmdline

 CLOSING THE LAB

      # sudo ./101.1-break-and-fix.sh --verify     grade the four faults
      # sudo ./101.1-break-and-fix.sh --undo       delete every leftover

 Adjacent commands from the same objective, worth running once on the
 repaired system so the output is familiar on exam day:
      lspci -nnk        PCI devices with the driver bound to each one
      lsusb -t          USB topology by bus and hub
      lsmod / modinfo   loaded modules and their parameters
      cat /proc/interrupts /proc/iomem /proc/ioports /proc/dma
      ls /sys/class/    the device model grouped by class
      udevadm monitor   kernel and udev events, live
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/101.1/lab)
