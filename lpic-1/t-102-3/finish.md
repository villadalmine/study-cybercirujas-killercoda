## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION -- do not read until you have worked the lab.

 STEP 0 -- Reproduce and classify the failure
     $ greetctl
     greetctl: error while loading shared libraries: libgreet.so.1: cannot open
     shared object file: No such file or directory

     $ ldd /usr/local/bin/greetctl
             linux-vdso.so.1 (0x00007ffd...)
             libgreet.so.1 => not found
             libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f...)

 "not found" means the loader searched and came up empty. Confirm the binary is
 asking for the right name and is not relying on a baked-in path:

     $ readelf -d /usr/local/bin/greetctl | head -n 5
      0x0000000000000001 (NEEDED)   Shared library: [libgreet.so.1]
      0x0000000000000001 (NEEDED)   Shared library: [libc.so.6]

 No RPATH and no RUNPATH entry => resolution depends entirely on LD_LIBRARY_PATH,
 on /etc/ld.so.cache, and on the default trusted directories.


 STEP 1 -- Fault 1: the library directory is no longer in the search path
 The file itself is still on disk:

     $ ls -l /opt/greet/lib/
     -rwxr-xr-x 1 root root 15864 ... libgreet.so.1.0.0

 ...but the cache does not know about it, and neither does the configuration:

     $ ldconfig -p | grep -c libgreet
     0
     $ ls /etc/ld.so.conf.d/
     libc.conf  x86_64-linux-gnu.conf        # the greet.conf drop-in is gone
     $ grep -v '^#' /etc/ld.so.conf
     include /etc/ld.so.conf.d/*.conf        # the include line is intact -- good

 Recreate the drop-in. One directory per line; the filename must end in .conf so
 the glob in /etc/ld.so.conf picks it up:

     # echo '/opt/greet/lib' > /etc/ld.so.conf.d/greet.conf
     # chmod 0644 /etc/ld.so.conf.d/greet.conf

 STEP 2 -- Fault 2: rebuild the cache, which also repairs the SONAME symlink
 Look at what is missing before rebuilding:

     $ ls /opt/greet/lib/
     libgreet.so.1.0.0                       # no libgreet.so.1, no libgreet.so

 The binary needs libgreet.so.1 -- the SONAME -- not libgreet.so.1.0.0. That
 version symlink is not something you must create by hand: ldconfig reads the
 SONAME out of each ELF object it scans and recreates the link itself.

     $ readelf -d /opt/greet/lib/libgreet.so.1.0.0 | grep SONAME
      0x000000000000000e (SONAME)   Library soname: [libgreet.so.1]

     # ldconfig -v 2>/dev/null | grep -A2 '^/opt/greet/lib'
     /opt/greet/lib:
             libgreet.so.1 -> libgreet.so.1.0.0        # created by ldconfig

 Plain `ldconfig` (no options) does the same silently: it walks /etc/ld.so.conf,
 every *.conf under /etc/ld.so.conf.d/, the trusted directories and any dirs given
 on the command line, refreshes the version symlinks, and rewrites /etc/ld.so.cache.

     # ldconfig
     $ ldconfig -p | grep libgreet
             libgreet.so.1 (libc6,x86-64) => /opt/greet/lib/libgreet.so.1

     $ ldd /usr/local/bin/greetctl | grep greet
             libgreet.so.1 => /opt/greet/lib/libgreet.so.1 (0x00007f...)
     $ greetctl
     greetctl: libgreet.so.1 resolved correctly

 Useful variants to know for the exam:
     ldconfig -n DIR    process ONLY DIR, update symlinks, do NOT touch the cache
     ldconfig -N        update symlinks only, skip the cache rebuild
     ldconfig -X        rebuild the cache only, skip the symlinks
     ldconfig -p        print the current cache without changing anything
     ldconfig -r ROOT   chroot to ROOT first (rescue / chroot repair)


 STEP 3 -- Fault 3: the environment overrides that outrank your fix
 The current shell works now, but a login shell still fails, differently:

     $ bash -lc greetctl
     ERROR: ld.so: object '/opt/greet/decoy/libaudit-shim.so' from LD_PRELOAD cannot
     be preloaded (cannot open shared object file): ignored.
     greetctl: error while loading shared libraries: /opt/greet/decoy/libgreet.so.1:
     file too short

 Two distinct signals:
   * LD_PRELOAD names a file that does not exist. glibc prints the warning and
     carries on ("ignored") -- noise, not a fatal error, but it pollutes every
     command and every script that parses stderr.
   * LD_LIBRARY_PATH points at /opt/greet/decoy, which is searched BEFORE the
     cache. It contains a file with the right name and a truncated body, so the
     loader opens it and dies with "file too short". Your correct cache entry is
     never even consulted.

 Find where the variables come from -- they are not exported by the binary:

     $ bash -lc 'env | grep ^LD_'
     LD_LIBRARY_PATH=/opt/greet/decoy
     LD_PRELOAD=/opt/greet/decoy/libaudit-shim.so

     $ grep -rn 'LD_LIBRARY_PATH\|LD_PRELOAD' /etc/profile /etc/profile.d/ \
           /etc/environment /etc/bash.bashrc ~/.bash_profile ~/.bashrc 2>/dev/null
     /etc/profile.d/zz-greet-lab.sh:3:export LD_LIBRARY_PATH="/opt/greet/decoy..."
     /etc/profile.d/zz-greet-lab.sh:4:export LD_PRELOAD="/opt/greet/decoy/libaudit-shim.so"

 Remove the offending drop-in (it is lab-owned; in production you would inspect it,
 and back it up, before deleting):

     # rm -f /etc/profile.d/zz-greet-lab.sh

 ...and clear the variables from any shell that already inherited them:

     $ unset LD_LIBRARY_PATH LD_PRELOAD

 Verify in a genuinely fresh login shell -- not in the one you have been editing in:

     $ bash -lc greetctl
     greetctl: libgreet.so.1 resolved correctly


 STEP 4 -- Bonus: the linker name, the one symlink ldconfig will not create
     $ cc -L/opt/greet/lib -lgreet -o /tmp/t /opt/greet/src/greetctl.c
     /usr/bin/ld: cannot find -lgreet: No such file or directory

 `-lgreet` looks for the unversioned name libgreet.so. ldconfig deliberately does
 not manage it: the version symlink is a RUNTIME concern, while the linker name is
 a BUILD-TIME concern shipped by the -dev / -devel package. Create it by hand:

     # ln -sfn libgreet.so.1 /opt/greet/lib/libgreet.so

 So the canonical three-name chain for a shared library is:
     libgreet.so         -> libgreet.so.1        (linker name, dev package)
     libgreet.so.1       -> libgreet.so.1.0.0    (SONAME, created by ldconfig)
     libgreet.so.1.0.0                           (real name, the actual object)


 STEP 5 -- Final verification
     # greet-lab-check
     == LPIC-1 102.3 -- lab self-check ==
       [ OK ] SONAME symlink /opt/greet/lib/libgreet.so.1 -> libgreet.so.1.0.0
       [ OK ] ldconfig -p lists libgreet.so.1 from /opt/greet/lib
       [ OK ] ldd /usr/local/bin/greetctl resolves every dependency
       [ OK ] greetctl prints the expected banner in a login shell
       [ OK ] no LD_PRELOAD / LD_LIBRARY_PATH noise in a login shell
       [ OK ] BONUS: linker name libgreet.so present (cc -lgreet can link again)
     RESULT: lab solved. Every check passed.


 ONE-SHOT REPAIR (after you understand each step)
     echo '/opt/greet/lib' > /etc/ld.so.conf.d/greet.conf
     chmod 0644 /etc/ld.so.conf.d/greet.conf
     ldconfig
     ln -sfn libgreet.so.1 /opt/greet/lib/libgreet.so
     rm -f /etc/profile.d/zz-greet-lab.sh
     unset LD_LIBRARY_PATH LD_PRELOAD
     greet-lab-check


 PRODUCTION NOTES WORTH CARRYING OUT OF THE LAB
 * LD_LIBRARY_PATH is a debugging and development tool, not a deployment mechanism.
   Exporting it globally in /etc/profile.d is a recurring production incident: it
   silently overrides a correct cache for every process started from a login shell,
   and it is inherited by children, including services launched from that session.
   The supported alternatives are an /etc/ld.so.conf.d/ drop-in plus ldconfig, or
   a DT_RUNPATH baked in at link time (cc -Wl,-rpath,/opt/greet/lib), which is per
   binary and cannot leak into unrelated processes.
 * The loader ignores LD_LIBRARY_PATH and LD_PRELOAD for set-user-ID/set-group-ID
   binaries, which is why "it works for me but not under sudo/systemd" is a classic
   symptom of an environment-based workaround. See ld.so(8), section "Secure mode".
 * /etc/ld.so.cache is a generated binary file. Never edit it, never copy it between
   machines, and never restore it from a backup -- regenerate it with ldconfig.
   If it is deleted, the loader falls back to searching directories, which is slower
   but still functional; running ldconfig rebuilds it.
 * After installing or upgrading a library outside a package manager, run ldconfig.
   Package managers already do this in their post-install scriptlets; tarball and
   "make install" deployments do not.
 * When a running process holds an old library open, replacing the file on disk does
   not affect it. Use "lsof +L1" or "lsof -p PID | grep DEL" to find processes still
   mapping a deleted library, and restart those services after the upgrade.
 * LD_DEBUG=libs (also =files, =symbols, =bindings) makes the loader narrate every
   directory it tries. It is the fastest way to answer "why is it picking THAT copy?".

 References
     LPI 101-500 objectives: https://www.lpi.org/our-certifications/exam-101-objectives/
     LPI 102-500 objectives: https://www.lpi.org/our-certifications/exam-102-objectives/
     ld.so(8):    https://man7.org/linux/man-pages/man8/ld.so.8.html
     ldconfig(8): https://man7.org/linux/man-pages/man8/ldconfig.8.html
     ldd(1):      https://man7.org/linux/man-pages/man1/ldd.1.html
     GNU ld (-soname, -rpath): https://sourceware.org/binutils/docs/ld/Options.html
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-1/102.3/lab)
