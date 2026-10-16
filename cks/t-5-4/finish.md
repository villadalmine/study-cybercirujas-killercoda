## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — do not read until you have tried, or until `verify` passes.

STEP 0 — Triage: separate "never created" from "created then died"
  kubectl -n hardening-lab get pods

    NAME                           READY   STATUS                 RESTARTS
    audit-agent-6c9f4d8b7-2xk4p    0/1     CreateContainerError   0
    log-shipper-7f8b6c5d94-r8ttm   0/1     CrashLoopBackOff       4
    secure-web-5d7c8b9f6-pq2vn     0/1     CreateContainerError   0

  CreateContainerError / RunContainerError => the kubelet or the OCI runtime
  refused to build the container. The workload's own code never ran; its logs
  are empty. Look at EVENTS.
  CrashLoopBackOff with a non-empty log => the container was built correctly,
  the security profile applied cleanly, and the application is being told
  "no" by the kernel at runtime. Look at LOGS.

  This distinction is worth ~30 seconds in the exam and saves five minutes of
  looking in the wrong place.

FAULT A — secure-web: the AppArmor profile is not loaded on the node
Diagnose:
  kubectl -n hardening-lab describe pod -l app=secure-web | tail -25

    Warning  Failed  ...  Error: failed to create containerd task: failed to
    create shim task: OCI runtime create failed: unable to start container
    process: error during container init: apply apparmor profile: apparmor
    failed to apply profile: write /proc/self/attr/apparmor/exec:
    no such file or directory: unknown

  Confirm what the Pod is asking for, then what the kernel actually has:

  kubectl -n hardening-lab get deploy secure-web \
    -o jsonpath='{.spec.template.spec.securityContext.appArmorProfile}{"\n"}'
    {"localhostProfile":"k8s-apparmor-example-deny-write","type":"Localhost"}

  aa-status | head -5
    apparmor module is loaded.
    34 profiles are loaded.
    34 profiles are in enforce mode.
       ...
  aa-status --profiled 2>/dev/null; grep k8s-apparmor /sys/kernel/security/apparmor/profiles
    (no output)  <-- the profile the Pod demands does not exist in this kernel

  KEY MENTAL MODEL: `type: Localhost` for AppArmor means "a profile already
  present in this node's kernel, by name". Kubernetes never ships, compiles or
  distributes AppArmor profiles. There is no AppArmor equivalent of the
  kubelet seccomp directory. Getting the profile onto every node is an
  infrastructure problem (config management, a DaemonSet with a privileged
  loader, or the Security Profiles Operator's AppArmorProfile CRD).

Fix — recreate the profile file and load it into the kernel:

  cat > /etc/apparmor.d/k8s-apparmor-example-deny-write <<'EOF'
  #include <tunables/global>

  profile k8s-apparmor-example-deny-write flags=(attach_disconnected) {
    #include <abstractions/base>
    file,
    deny /** w,
    deny /** l,
    deny /** k,
  }
  EOF

  apparmor_parser -q -r /etc/apparmor.d/k8s-apparmor-example-deny-write
  grep k8s-apparmor /sys/kernel/security/apparmor/profiles
    k8s-apparmor-example-deny-write (enforce)

  The `profile <name>` line, not the filename, is what Kubernetes matches
  against localhostProfile. Renaming the file changes nothing; renaming the
  profile breaks every Pod that references it.
  `apparmor_parser -r` replaces an existing profile; `-a` adds and fails if it
  already exists; `-R` removes it. In scripts always use `-r` for idempotency.

  Now force a new container. Deleting the Pod is enough — the profile is read
  at container create time, so no rollout of the Deployment is required:

  kubectl -n hardening-lab delete pod -l app=secure-web
  kubectl -n hardening-lab rollout status deploy/secure-web

Verify the confinement is real, not merely declared:

  kubectl -n hardening-lab exec deploy/secure-web -- cat /proc/1/attr/current
    k8s-apparmor-example-deny-write (enforce)

  kubectl -n hardening-lab exec deploy/secure-web -- sh -c 'echo x > /tmp/x'
    sh: can't create /tmp/x: Permission denied
    command terminated with exit code 1

  dmesg -T | grep -i apparmor | tail -3
    [...] audit: type=1400 apparmor="DENIED" operation="mknod"
          profile="k8s-apparmor-example-deny-write" name="/tmp/x" ...
          requested_mask="c" denied_mask="c" fsuid=0 ouid=0

  Reading those DENIED lines is the core AppArmor debugging skill:
  `operation` + `name` + `denied_mask` tell you exactly which rule to add.
  Mask letters: r read, w write, a append, c create, l link, k lock, x execute,
  m mmap-exec. `aa-logprof` / `aa-genprof` turn those log lines into rules
  interactively; `aa-complain <profile>` switches a profile to complain mode,
  where violations are logged but permitted — the AppArmor analogue of
  SCMP_ACT_LOG, and the right first move when you must not cause an outage.

PERSISTENCE (the part people forget): a profile loaded with apparmor_parser is
gone after reboot unless the file lives in /etc/apparmor.d and the distro's
apparmor service is enabled (`systemctl enable --now apparmor`). Because this
lab's fault was "the golden image lost the file", the durable fix is the file
on disk plus the enabled unit — not just the parser invocation.

FAULT B — audit-agent: the Localhost seccomp profile file is missing
Diagnose:
  kubectl -n hardening-lab describe pod -l app=audit-agent | tail -15

    Warning  Failed  ...  Error: failed to generate spec: failed to generate
    seccomp spec opts: open /var/lib/kubelet/seccomp/profiles/audit.json:
    no such file or directory

  The error hands you the absolute path. Note how it was assembled:

    <kubelet --root-dir>/seccomp  +  localhostProfile
    /var/lib/kubelet/seccomp      +  profiles/audit.json

  Confirm the root dir instead of assuming it (k3s, RKE2 and hardened images
  move it, and then your `ls` of /var/lib/kubelet looks correctly empty):

  ps -eo args= -C kubelet | tr ' ' '\n' | grep -- --root-dir
  ls -l /var/lib/kubelet/seccomp/profiles/
    total 4
    -rw-r--r-- 1 root root 187 ... shipper.json      <-- audit.json is gone

  Also note what did NOT happen: the API server accepted this Pod. It only
  validates that localhostProfile is a relative path with no "..". Existence
  is a node-local, create-time concern. This is why a Localhost seccomp
  profile is a node prerequisite, exactly like an AppArmor profile, and why
  admission control cannot protect you from this class of outage.

Fix:
  mkdir -p /var/lib/kubelet/seccomp/profiles
  cat > /var/lib/kubelet/seccomp/profiles/audit.json <<'EOF'
  {
    "defaultAction": "SCMP_ACT_LOG"
  }
  EOF
  chmod 0644 /var/lib/kubelet/seccomp/profiles/audit.json

  kubectl -n hardening-lab delete pod -l app=audit-agent
  kubectl -n hardening-lab rollout status deploy/audit-agent

  kubectl -n hardening-lab exec deploy/audit-agent -- grep Seccomp /proc/1/status
    Seccomp:        2
    Seccomp_filters:        1

  Seccomp: 0 = disabled, 1 = strict mode, 2 = filter mode (BPF). A container
  that reports 0 has NO filter at all — if you ever "fix" a seccomp problem
  and the value drops to 0, you did not fix it, you removed the control.

  SCMP_ACT_LOG never blocks anything; it writes an audit record per unmatched
  syscall. That is what makes audit.json safe to deploy everywhere and the
  correct starting point for building a real allow-list. Harvest with:
    ausearch -m SECCOMP -ts recent | ausyscall --dump
  or read /var/log/audit/audit.log directly. Requires kernel >= 4.14 and
  libseccomp >= 2.4; on older stacks the profile is rejected at create time.

FAULT C — log-shipper: the seccomp profile denies a syscall the app needs
Diagnose:
  kubectl -n hardening-lab logs -l app=log-shipper --previous --tail=5
    chmod: /var/log/shipper/shipper.log: Operation not permitted
    [log-shipper] FATAL: cannot enforce 0600 on the spool file

  "Operation not permitted" (EPERM) from root, on a file root owns, on a
  writable emptyDir. Nothing about DAC, capabilities or the read-only root
  filesystem explains that. Rule the alternatives out fast:

    kubectl -n hardening-lab get pod -l app=log-shipper \
      -o jsonpath='{.items[0].spec.containers[0].securityContext}{"\n"}'
    # runAsUser 0, no readOnlyRootFilesystem, caps dropped but chmod on your
    # own file needs no capability => not a capability problem.

  Then read the profile the Pod points at:

  kubectl -n hardening-lab get deploy log-shipper -o jsonpath=\
    '{.spec.template.spec.containers[0].securityContext.seccompProfile}{"\n"}'
    {"localhostProfile":"profiles/shipper.json","type":"Localhost"}

  cat /var/lib/kubelet/seccomp/profiles/shipper.json
    ... "names": [ ..., "chmod", "fchmod", "fchmodat" ],
        "action": "SCMP_ACT_ERRNO", "errnoRet": 1

  errnoRet 1 == EPERM == "Operation not permitted". The symptom and the
  configuration match exactly.

  If the deny list had been long or obfuscated, the empirical route is:
    - change that rule's "action" to "SCMP_ACT_LOG" (or set the whole file to
      {"defaultAction":"SCMP_ACT_LOG"}), recreate the Pod, reproduce, then:
        dmesg -T | grep -i seccomp | tail
        type=SECCOMP audit(...): auid=... pid=... comm="chmod" ...
                                 syscall=268 compat=0 ip=0x... code=0x50000
        ausyscall 268
          fchmodat
    - `code=0x50000` is SECCOMP_RET_ERRNO; 0x7ffc0000 is ALLOW,
      0x00000000 is KILL_THREAD, 0x80000000 is KILL_PROCESS (which shows up as
      a container exiting with SIGSYS / exit code 159, with NO log line at all
      — the hardest seccomp failure to diagnose, and the reason ERRNO is
      preferred over KILL in profiles you have not fully validated).

Fix — remove only the offending family, keep the rest of the deny list:

  cat > /var/lib/kubelet/seccomp/profiles/shipper.json <<'EOF'
  {
    "defaultAction": "SCMP_ACT_ALLOW",
    "syscalls": [
      {
        "names": [
          "kexec_load", "kexec_file_load",
          "init_module", "finit_module", "delete_module",
          "bpf", "perf_event_open",
          "ptrace", "process_vm_readv", "process_vm_writev",
          "mount", "umount2", "pivot_root",
          "reboot", "swapon", "swapoff"
        ],
        "action": "SCMP_ACT_ERRNO",
        "errnoRet": 1
      }
    ]
  }
  EOF

  # THE STEP EVERYONE MISSES: the filter is installed by runc immediately
  # before execve() of the entrypoint. Editing the JSON has zero effect on a
  # container that already exists. You must create a new container.
  kubectl -n hardening-lab delete pod -l app=log-shipper
  kubectl -n hardening-lab rollout status deploy/log-shipper
  kubectl -n hardening-lab logs -l app=log-shipper --tail=3
    (no chmod error; the pod stays Running with a stable restart count)

  Confirm the remaining denials still bite:
  kubectl -n hardening-lab exec deploy/log-shipper -- sh -c \
    'cat /proc/1/status | grep Seccomp'
    Seccomp:        2

FINAL CHECK
  kubectl -n hardening-lab get deploy
    NAME          READY   UP-TO-DATE   AVAILABLE
    audit-agent   1/1     1            1
    log-shipper   1/1     1            1
    secure-web    1/1     1            1

  sudo ./<this-script> verify

WHY THIS LAB IS SHAPED THIS WAY — production notes worth internalising
1. Both mechanisms are NODE-LOCAL prerequisites, not cluster objects.
   An AppArmor Localhost profile must be in the node's kernel; a seccomp
   Localhost profile must be a file under <kubelet-root-dir>/seccomp. A Pod
   referencing either will pass admission on any cluster and then fail to
   start on precisely the nodes that lack it. In a heterogeneous cluster this
   presents as "the Deployment works until it lands on node-7". Fix the fleet,
   not the Pod: config management, a privileged loader DaemonSet, or the
   Security Profiles Operator (which reconciles SeccompProfile and
   AppArmorProfile CRDs onto every node and garbage-collects them).

2. Profiles are applied at container CREATE time.
   Editing a profile does nothing to running workloads; unloading one breaks
   nothing until the next reschedule. Node drift is therefore a LATENT
   outage — it detonates on the next reboot, eviction, scale-up or image
   update, hours or weeks after the change. This is why the golden-image
   scenario is realistic and why "it worked yesterday" is not evidence.

3. The two symptom classes, memorised:
     CreateContainerError / RunContainerError + 'apparmor'/'seccomp' in the
       event text  -> the profile could not be RESOLVED or APPLIED. The node
       is missing something, or the path/name is wrong.
     Container starts, then EPERM / "Operation not permitted", or dies with
       SIGSYS and no message -> the profile WAS applied and is working as
       written. The profile is wrong, not missing.

4. Field syntax for CKS 1.34 (annotations are gone; do not write them):
     spec.securityContext.appArmorProfile.{type,localhostProfile}       (Pod)
     spec.containers[].securityContext.appArmorProfile.{...}      (container)
       type: RuntimeDefault | Localhost | Unconfined
     spec.securityContext.seccompProfile.{type,localhostProfile}        (Pod)
     spec.containers[].securityContext.seccompProfile.{...}       (container)
       type: RuntimeDefault | Localhost | Unconfined
     Container-level overrides Pod-level. localhostProfile is REQUIRED when
     type is Localhost and FORBIDDEN otherwise.

5. Reach for RuntimeDefault first. The runtime's built-in seccomp profile
   blocks ~44 syscalls of the ~350 available and breaks almost nothing; it is
   a one-line change per workload with a fraction of the operational cost of a
   bespoke profile. Enable it fleet-wide with the kubelet flag
   `--seccomp-default=true` (KEP-2413, GA in 1.27) so unannotated Pods are
   confined by default, and reserve custom Localhost profiles for the few
   workloads that justify the maintenance. Pod Security Admission's
   `restricted` level requires a seccompProfile of RuntimeDefault or Localhost
   and forbids Unconfined — which is the enforcement lever that keeps someone
   from "fixing" the next incident the way this lab's verifier refuses to
   accept.

6. Portability traps that produce exactly these symptoms in real clusters:
   - Adding "architectures": ["SCMP_ARCH_X86_64"] to a profile silently
     disables the entire filter on arm64 nodes. Omit the key unless you need
     multi-arch compat entries, and never assume a mixed-arch fleet is x86.
   - Unknown syscall names in a profile are skipped with a warning by runc, so
     a typo'd deny rule fails OPEN, not closed. Validate profiles in CI.
   - AppArmor exists on Debian/Ubuntu/SUSE; RHEL-family nodes use SELinux and
     will reject Localhost AppArmor profiles outright. Mixed-distro node pools
     need seLinuxOptions on one side and appArmorProfile on the other.
   - `deny /** w` style profiles interact badly with anything that writes at
     startup (log files, PID files, tmp scratch). Always develop a profile in
     complain mode (`aa-complain`) under real traffic before enforcing.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cks/5.4/lab)
