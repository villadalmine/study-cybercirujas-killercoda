## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION -- step by step

 Mental model first. A Falco alert only exists if FOUR layers all work:

     driver (syscall capture) -> rule LOADED -> condition MATCHES -> output CHANNEL

 Triage always walks that chain in order. This lab breaks layers 2, 2 and 3;
 layer 1 and 4 are healthy, which is why the service looks perfectly green.

 STEP 0 -- confirm the sensor itself is alive (layer 1)

    systemctl status falco-modern-bpf.service      # or falco-bpf / falco-kmod
    journalctl -u falco-modern-bpf.service -n 60 --no-pager

 Expect: "Falco initialized with configuration files", "Starting health
 webserver", "Loading rules from file ...". If you see driver errors instead
 ("cannot open BPF probe", "kernel module not loaded") that is a layer-1
 problem and nothing else matters -- it is NOT the case here.

 Also confirm events are actually flowing (no capture, no analytics):

    journalctl -u falco-modern-bpf.service | grep -i 'syscall event drop'
    curl -s localhost:8765/healthz          # if the health webserver is on

 STEP 1 -- FAULT #1: the ruleset is never loaded

    falco -L | grep CKS-6.1        # -> empty: the engine does not know the rules
    ls -l /etc/falco/rules.d/cks-6.1-behavioral.yaml   # the file IS on disk

 So the file exists but is not in the load list. Inspect it:

    grep -nE '^(rules_file|rules_files):' -A6 /etc/falco/falco.yaml

 You will find the directory entry commented out:

    rules_files:
      - /etc/falco/falco_rules.yaml
      - /etc/falco/falco_rules.local.yaml
      #- /etc/falco/rules.d          <-- sabotage

 Fix -- uncomment it (order matters: later files override earlier ones, which
 is exactly how falco_rules.local.yaml is meant to customise the defaults):

    sudo sed -ri 's|^([[:space:]]*)#-([[:space:]]*)(/etc/falco/rules\.d/?)$|\1-\2\3|' \
         /etc/falco/falco.yaml
    sudo systemctl restart falco-modern-bpf.service
    falco -L | grep CKS-6.1

 (With the default `watch_config_files: true`, Falco also hot-reloads on file
  changes; an explicit restart or `kill -HUP $(pidof falco)` removes doubt.)

 Now only ONE rule appears: "CKS-6.1-R1 Shell Spawned by Web Server Binary".
 Two rules are still missing -> the next fault.

 STEP 2 -- FAULT #2: the minimum priority threshold hides two rules

 The engine tells you, if you read its startup log:

    journalctl -u falco-modern-bpf.service -n 80 --no-pager | grep -iE 'skip|priority'

 Falco skips at LOAD TIME every rule whose priority is below the configured
 minimum. Confirm the knob:

    grep -nE '^priority:' /etc/falco/falco.yaml
    priority: critical            <-- sabotage (default is `debug`)

 Severity order (highest to lowest):
    emergency > alert > critical > error > warning > notice > informational > debug

 With `critical`, R2 (WARNING) and R3 (NOTICE) are never even compiled. That is
 the subtle part: they do not "fail to match", they do not exist for the engine.

 Fix:

    sudo sed -ri 's|^priority:.*|priority: debug|' /etc/falco/falco.yaml
    sudo systemctl restart falco-modern-bpf.service
    falco -L | grep -c CKS-6.1     # -> 3

 Production note: raising this threshold is a legitimate noise-control lever,
 but it is the wrong one. Prefer tuning the offending rule with an override /
 exception (`- rule: X` + `override: {exceptions: append}`) so you keep the
 detection and drop only the known-benign path.

 STEP 3 -- FAULT #3: R2's condition is logically inverted

    sudo /opt/cks-lab/6.1/bin/cks-nginx      # -> R1 fires (CRITICAL)
    sudo cp /bin/true /usr/local/bin/x; sudo rm /usr/local/bin/x   # -> R3 fires
    sudo cat /etc/shadow > /dev/null         # -> silence, still

 The rule is loaded (`falco -l 'CKS-6.1-R2 Credential File Read'`) but never
 matches. Read the condition:

    - rule: CKS-6.1-R2 Credential File Read
      condition: >
        cks_open_write                       <-- wrong: this is a READ detection
        and fd.name in (cks_credential_files)
        and not proc.name in (cks_credential_readers)

 `cks_open_write` requires evt.is_open_write=true. An attacker EXFILTRATING
 /etc/shadow opens it O_RDONLY, so the rule can only fire if the attacker
 writes to the file -- a detection that describes the wrong behaviour. This is
 the most dangerous class of failure in behavioral analytics: green pipeline,
 loaded rule, zero coverage.

 Fix -- swap the macro for the read one:

    sudo sed -i '/CKS-6.1-R2 Credential File Read/,/priority:/ s/cks_open_write/cks_open_read/' \
         /etc/falco/rules.d/cks-6.1-behavioral.yaml

 Validate the syntax BEFORE restarting (this is the habit that saves you in the
 exam and in production -- a bad rules file makes Falco refuse to start):

    falco -V /etc/falco/rules.d/cks-6.1-behavioral.yaml
    sudo systemctl restart falco-modern-bpf.service

 The corrected rule:

    - rule: CKS-6.1-R2 Credential File Read
      desc: A non-authentication process opened a credential store.
      condition: >
        cks_open_read
        and fd.name in (cks_credential_files)
        and not proc.name in (cks_credential_readers)
      output: >
        CKS-6.1-R2 credential file accessed
        (user=%user.name uid=%user.uid proc=%proc.name cmdline=%proc.cmdline
         parent=%proc.pname file=%fd.name container_id=%container.id
         image=%container.image.repository)
      priority: WARNING
      tags: [host, container, filesystem, mitre_credential_access, T1552.001]

 STEP 4 -- verify

    sudo ./break_fix.sh verify        # -> R1, R2, R3 DETECTED, LAB PASSED

 Watch it live in a second terminal while the attacks replay:

    journalctl -u falco-modern-bpf.service -f | grep CKS-6.1

 Same detections inside a container (the fields container.id / container.image
 stop being <NA>, which is how you separate node activity from workload
 activity in the SIEM):

    kubectl run rce-sim --image=busybox --restart=Never -it -- \
        sh -c 'cat /etc/shadow > /dev/null; cp /bin/true /usr/local/bin/implant'

 CHECKLIST -- why a Falco detection is silent, in triage order

  1. Sensor/driver:  unit active? driver loaded? `syscall event drop` messages?
                     -> drops mean the buffer overflowed: raise
                        syscall_buf_size_preset / tune base_syscalls.
  2. Rule loaded:    `falco -L`; is the file in rules_files? is it shadowed by
                     a later definition with the same name? `falco -V <file>`.
  3. Load filters:   falco.yaml `priority:` threshold; `load_plugins`;
                     rule `enabled: false`; `-T <tag>` / `-t <tag>` in the unit's
                     ExecStart; `--disable-source`.
  4. Condition:      does it describe the behaviour you are hunting (read vs
                     write, evt.dir=< vs >, container vs host)? Test the field
                     values with `falco -l <rule>` and by reading %evt.args.
  5. Exceptions:     an over-broad `not proc.name in (...)` allow-list is how
                     real detections die quietly -- attackers rename binaries
                     to whatever your exception list contains.
  6. Output channel: `stdout_output`, `file_output`, `json_output`,
                     `buffered_outputs`, the `outputs` rate limiter, and
                     whether falcosidekick/the SIEM forwarder is alive.

 Sources:
   - CKS v1.34 curriculum: https://github.com/cncf/curriculum
   - Falco rules reference: https://falco.org/docs/reference/rules/
   - Falco config reference: https://falco.org/docs/reference/daemon/config-options/
   - Supported fields: https://falco.org/docs/reference/rules/supported-fields/
   - MITRE ATT&CK for Containers: https://attack.mitre.org/matrices/enterprise/containers/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/cks/6.1/lab)
