## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — step by step. Do not read this until you have tried, and until
 `verify` has told you at least once which layer is still red.

 STEP 0 — Frame the incident with the Azure Monitor data flow.
 Azure Monitor collects two kinds of telemetry: metrics (numeric, time-series,
 stored in a metrics database) and logs (records, stored in a Log Analytics
 workspace and queried with KQL). Heartbeat and Syslog are LOGS. Everything
 above the workspace — workbooks, log-search alert rules, Advisor's reliability
 recommendations for this VM — reads from that workspace. Therefore, if the
 workspace has no rows, every layer above it is blind, and none of them can
 tell you why. That is the first conclusion, and it is a conceptual one, not a
 command:  "No data" != "nothing is wrong".
     https://learn.microsoft.com/en-us/azure/azure-monitor/overview

 STEP 1 — Confirm the outage from the data plane, not from the VM.
 In the workspace (Portal > Log Analytics workspace > Logs), or from the CLI:

     az monitor log-analytics query -w "$AZ_WORKSPACE_ID" --analytics-query '
         Heartbeat
         | where TimeGenerated > ago(1h)
         | summarize LastSeen = max(TimeGenerated) by Computer
         | order by LastSeen asc' -o table

 A Computer whose LastSeen froze at a point in time is a shipping failure, not
 a workload failure. Note the timestamp — it is your incident start.
 In sim mode the equivalent evidence is:  tail -n 5 /var/log/teach-plat/agent.log

 STEP 2 — Rule the platform out before you debug your own VM.
 Portal > Service Health > Service issues, filtered to your region and to
 "Azure Monitor". Azure Service Health reports incidents, planned maintenance
 and health advisories that affect YOUR resources; Azure Status is the public,
 global page. If Service Health is clean, the fault is on your side of the
 shared responsibility line. Thirty seconds spent here saves an hour.
     https://learn.microsoft.com/en-us/azure/service-health/overview

 STEP 3 — Fault 1: the agent is masked.
     systemctl status azuremonitoragent        # (or teachplat-ama in sim mode)
     #  Loaded: masked (Reason: Unit ... is masked.)
     systemctl start azuremonitoragent
     #  Failed to start ...: Unit azuremonitoragent.service is masked.

 A masked unit is symlinked to /dev/null, so start/enable are refused outright.
 Unmask it, then start and enable it so the fix survives a reboot:

     sudo systemctl unmask azuremonitoragent
     sudo systemctl enable --now azuremonitoragent
     systemctl is-active azuremonitoragent      # -> active

 Do NOT stop here. `active` means the process runs; it says nothing about the
 process succeeding. This is exactly the trap the incident is built around.

 STEP 4 — Fault 2: the agent runs but cannot reach the workspace.
     journalctl -u azuremonitoragent -n 50 --no-pager
     tail -n 20 /var/log/teach-plat/agent.log          # sim mode
     # ... ERROR ingestion endpoint unreachable ... resolved=198.51.100.13

 Resolve the endpoint by hand and compare it with what it should be:

     getent hosts <workspace-id>.ods.opinsights.azure.com
     grep -n -iE 'opinsights|handler.control.monitor|teach-plat' /etc/hosts

 A monitoring endpoint answering 127.0.0.1 (or a TEST-NET address) is a local
 override, never DNS. Remove the injected block from /etc/hosts — it is fenced
 between the two teach-plat markers, so delete from the BEGIN line through the
 END line inclusive, and leave the rest of the file untouched:

     sudo cp /etc/hosts /root/hosts.bak
     sudo sed -i '/>>> teach-plat az-900-3.4 BEGIN >>>/,/<<< teach-plat az-900-3.4 END <<</d' /etc/hosts
     getent hosts <workspace-id>.ods.opinsights.azure.com   # now a public IP

 In sim mode the endpoint entry is a single line; point it back at 127.0.0.1:
     sudo sed -i 's/^198\.51\.100\.13 lab-workspace/127.0.0.1 lab-workspace/' /etc/hosts

 On a real Azure VM also clear the outbound block. AMA needs HTTPS 443 to the
 workspace ingestion and control endpoints, and HTTP to the Instance Metadata
 Service at 169.254.169.254 to obtain its managed identity token; block IMDS
 and the agent authenticates against nothing, which surfaces as a token error,
 not as a network error:

     sudo iptables -S OUTPUT | grep teach-plat-az900-34
     sudo iptables -D OUTPUT -d 169.254.169.254 -p tcp --dport 80 \
          -m comment --comment teach-plat-az900-34 -j DROP
     curl -s -H Metadata:true \
          "http://169.254.169.254/metadata/instance?api-version=2021-02-01" | head -c 200

 Then restart the agent so it re-resolves and re-authenticates immediately
 instead of waiting out its backoff:
     sudo systemctl restart azuremonitoragent

 Heartbeat should reappear within a couple of minutes (real Log Analytics
 ingestion latency is typically 1-3 minutes; do not mistake latency for failure).
     https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-network-configuration

 STEP 5 — Fault 3: Heartbeat is back, Syslog is still empty.
 This is the discriminating observation of the whole lab. Heartbeat is emitted
 BY the agent about itself, so it proves only the agent-to-workspace hop.
 Syslog is produced by rsyslog and handed to the agent over a unix socket; the
 Data Collection Rule tells the agent which facilities to keep. If the rsyslog
 drop-in that performs the handoff is gone, the agent is healthy and the table
 stays empty forever.

     ls -l /etc/rsyslog.d/
     #  10-azuremonitoragent-omfwd.conf is missing
     sudo cp /var/lib/teach-plat/az-900-3.4/backup/10-azuremonitoragent-omfwd.conf.bak \
             /etc/rsyslog.d/10-azuremonitoragent-omfwd.conf
     sudo systemctl restart rsyslog
     ls -l /run/azuremonitoragent/default_syslog.socket     # the receiving end

 (On a real VM you can also force AMA to rewrite that drop-in by re-applying the
 Data Collection Rule association from the portal or with `az monitor
 data-collection rule association create` — the DCR is the source of truth for
 what gets collected, the file on disk is only its rendering.)

 Prove it end to end with a marker of your own instead of trusting the config:
     logger -p user.notice "restore-probe-$(id -u)-$$"
     # then, after ingestion latency:
     #   Syslog | where SyslogMessage has "restore-probe" | project TimeGenerated, Computer
     https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-collection-rule-overview

 STEP 6 — Fault 4 (only if you enabled the cloud fault): the silent alert rule.
     az monitor metrics alert list -g "$AZ_RG" -o table      # Enabled: False
     az monitor metrics alert update -g "$AZ_RG" -n "$AZ_ALERT_RULE" --enabled true

 An Azure Monitor alert rule has three parts: a scope (what to watch), a
 condition (signal + threshold + evaluation frequency) and an action group
 (who gets told: email, SMS, webhook, Logic App, ITSM). A rule with no action
 group fires into a dashboard nobody is looking at; a disabled rule does not
 evaluate at all. Both look like "no alerts" from a distance, which is why the
 exam insists you can name the three parts separately.
     https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-overview

 STEP 7 — Grade and reflect.
     ./az900-3.4-breakfix.sh verify        # expect [1]..[5] (and [6]) green

 Map the incident back onto the four AZ-900 3.4 tools, in the order they would
 actually have helped:

   Azure Service Health — scoped to YOUR subscriptions and resources: active
     incidents, planned maintenance, health advisories, plus resource health
     per VM. Told you the platform was fine. Cost: nothing. Always check first.

   Azure Monitor — the collection and analysis platform: metrics (numeric,
     near-real-time) and logs (KQL over a Log Analytics workspace). It showed
     the absence of data. It could not show the cause, because the cause was
     upstream of the collector. Log-search alert rules can be configured to
     alert on that absence — that is the design fix for this incident class.

   Application Insights — the APM member of the Azure Monitor family for
     applications: requests, dependencies, exceptions, availability tests,
     distributed tracing, live metrics. Irrelevant to a stopped VM agent, and
     exactly the tool you would add if this VM served a web application whose
     users complained about latency rather than about a missing chart.

   Azure Advisor — the recommendation engine across Reliability, Security,
     Performance, Cost and Operational Excellence. It is advisory, not
     diagnostic: it would have suggested enabling diagnostics or alert rules
     BEFORE the incident. It has nothing to say once you are already blind.

 Exam-shaped takeaway: Advisor recommends, Service Health reports on Azure,
 Azure Monitor observes your resources, Application Insights observes your
 application code. Any question that asks "which tool would you use to ..."
 is asking you to place the verb — recommend / report / observe / instrument.

 CLEANUP
     sudo TEACH_LAB_CONFIRM=yes ./az900-3.4-breakfix.sh purge
     # then delete the VM. It is a lab VM. It has served its purpose.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/az-900/3.4/lab)
