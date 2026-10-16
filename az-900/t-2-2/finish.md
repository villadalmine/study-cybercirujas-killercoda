## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION - DO NOT READ UNTIL YOU HAVE TRIED

 Shared first move for every fault: classify the failure by the SHAPE of the
 failure, before touching any configuration.

   $ curl -m 8 -o /dev/null -w '%{http_code} %{time_total}\n' http://<PIP>/healthz

   200  0.04    -> the path is fine, the problem is elsewhere (fault 4)
   000  8.00    -> timeout: something DROPS the packet silently. NSG deny,
                   a missing/detached public IP, or a blackhole route.
                   (curl exit 28)
   exit 7, "Connection refused" -> a RST came back. The packet REACHED the
                   guest and the guest had nothing on :80. Compute layer.

 Azure drops (Deny) rather than rejects, so "timeout" points at the network
 and "refused" points at the OS. That single distinction resolves fault 3 in
 five seconds and is worth more than any portal blade.

 FAULT 1 - Subnet NSG deny shadows the NIC NSG allow
 Step 1. Confirm the app is healthy, so the fault is not compute:
     $ ssh azureuser@<PIP> 'curl -s localhost/healthz'
     ok

 Step 2. Ask Azure to simulate the packet instead of guessing. Network Watcher
 evaluates all effective rules in the real order and names the rule that wins:
     $ az network watcher test-ip-flow -g rg-az900-breakfix --vm vm-web01 \
         --direction Inbound --protocol TCP \
         --local 10.20.1.4:80 --remote <YOUR_IP>:54321
     {
       "access": "Deny",
       "ruleName": "securityRules/lab-fault-deny-http-in"
     }
 (If the region has no Network Watcher yet:
     az network watcher configure -g NetworkWatcherRG -l eastus --enabled true)

 Step 3. See BOTH NSGs that apply to the NIC - this is the step people skip:
     $ az network nic list-effective-nsg -g rg-az900-breakfix -n <nic> \
         --query "value[].networkSecurityGroup.id" -o tsv
     .../networkSecurityGroups/nsg-nic-web
     .../networkSecurityGroups/nsg-snet-web        <-- the second one

 Step 4. List the subnet NSG rules by priority. Lower number = evaluated first
 and, once a rule matches, evaluation STOPS:
     $ az network nsg rule list -g rg-az900-breakfix --nsg-name nsg-snet-web \
         --include-default -o table --query \
         "sort_by([].{P:priority,Name:name,Dir:direction,Access:access,Port:destinationPortRange},&P)"
     P     Name                    Dir       Access  Port
     ----  ----------------------  --------  ------  ----
     100   lab-fault-deny-http-in  Inbound   Deny    80     <-- wins
     200   allow-http-in           Inbound   Allow   80     <-- never reached
     210   allow-ssh-in            Inbound   Allow   22
     65000 AllowVnetInBound        Inbound   Allow   *
     65500 DenyAllInBound          Inbound   Deny    *

 Step 5. Remove the offending rule (the constraint forbade touching
 allow-http-in, and correctly so - the Allow was never the problem):
     $ az network nsg rule delete -g rg-az900-breakfix \
         --nsg-name nsg-snet-web -n lab-fault-deny-http-in
     $ curl -s -o /dev/null -w '%{http_code}\n' http://<PIP>/healthz
     200

 What to retain: inbound is filtered SUBNET first, then NIC; outbound is NIC
 first, then subnet; the traffic must be allowed by both. Within one NSG the
 lowest priority number wins and evaluation stops there - so an Allow at 200
 is dead code behind a Deny at 100.

 FAULT 2 - Public IP dissociated from the NIC ipConfiguration
 Step 1. Ask what addresses the VM actually has:
     $ az vm list-ip-addresses -g rg-az900-breakfix -n vm-web01 -o table
     VirtualMachine    PublicIPAddresses    PrivateIPAddresses
     ----------------  -------------------  --------------------
     vm-web01                               10.20.1.4
 The PublicIPAddresses column is empty: the VM has no public frontend at all.

 Step 2. Look at the public IP resource from the other side. It exists, it
 still holds the address, but it is attached to nothing:
     $ az network public-ip show -g rg-az900-breakfix -n pip-web01 \
         --query "{ip:ipAddress, allocation:publicIPAllocationMethod, attachedTo:ipConfiguration}" -o json
     { "ip": "20.x.x.x", "allocation": "Static", "attachedTo": null }
 Static allocation is why the address survived the detach - a Standard SKU
 public IP is always static, so re-attaching gives you the SAME address.

 Step 3. Prove compute is healthy without any network path, using the agent:
     $ az vm run-command invoke -g rg-az900-breakfix -n vm-web01 \
         --command-id RunShellScript --scripts "curl -s localhost/healthz" \
         --query "value[0].message" -o tsv
     Enable succeeded: [stdout] ok [stderr]

 Step 4. Re-associate the public IP with the NIC's ipConfiguration:
     $ NIC=$(az vm show -g rg-az900-breakfix -n vm-web01 \
             --query "networkProfile.networkInterfaces[0].id" -o tsv | xargs basename)
     $ IPCFG=$(az network nic show -g rg-az900-breakfix -n "$NIC" \
             --query "ipConfigurations[0].name" -o tsv)
     $ az network nic ip-config update -g rg-az900-breakfix \
         --nic-name "$NIC" -n "$IPCFG" --public-ip-address pip-web01 -o none
     $ curl -s -o /dev/null -w '%{http_code}\n' http://<PIP>/healthz
     200
 (The detach is the same command with --public-ip-address "" - an empty string
 is how the CLI expresses "remove the association".)

 What to retain: a VM's public IP is not a property of the VM. It is a
 separate resource associated with an ipConfiguration on a NIC. The VM, the
 NIC, the private IP and the public IP have independent lifecycles - which is
 precisely why you can rebuild a VM and keep the address.

 FAULT 3 - nginx stopped and masked (compute layer)
 Step 1. Read the error text, not just the failure:
     $ curl -m 8 http://<PIP>/healthz
     curl: (7) Failed to connect to 20.x.x.x port 80: Connection refused
 Refused, not timed out => the SYN reached the guest and the guest answered
 RST. Every network component in front of it is therefore working. Do not
 open a single NSG blade.

 Step 2. Confirm nothing is listening:
     $ ssh azureuser@<PIP>
     $ ss -lntp | grep ':80' || echo "nothing on 80"
     nothing on 80

 Step 3. Ask systemd why:
     $ systemctl status nginx --no-pager
     o nginx.service
          Loaded: masked (Reason: Unit nginx.service is masked.)
          Active: inactive (dead)
     $ ls -l /etc/systemd/system/nginx.service
     lrwxrwxrwx 1 root root 9 ... /etc/systemd/system/nginx.service -> /dev/null
 A masked unit is symlinked to /dev/null: it cannot be started manually, by a
 dependency, or at boot. This is why 'systemctl start nginx' returns
     Failed to start nginx.service: Unit nginx.service is masked.
 Masking is stronger than disabling - 'disable' only removes the boot-time
 wants/ symlink; 'mask' blocks activation entirely.

 Step 4. Unmask, then start AND enable so it survives a reboot:
     $ sudo systemctl unmask nginx
     Removed /etc/systemd/system/nginx.service.
     $ sudo systemctl enable --now nginx
     $ systemctl is-active nginx && systemctl is-enabled nginx
     active
     enabled
     $ curl -s localhost/healthz
     ok

 Same fix without SSH, through the VM agent (useful when the fault IS the SSH
 path - this is the out-of-band channel the lab always preserves):
     $ az vm run-command invoke -g rg-az900-breakfix -n vm-web01 \
         --command-id RunShellScript \
         --scripts "systemctl unmask nginx; systemctl enable --now nginx; systemctl is-active nginx"

 Step 5. Confirm from outside:
     $ curl -s -o /dev/null -w '%{http_code}\n' http://<PIP>/healthz
     200

 What to retain: IaaS splits responsibility. Azure guarantees the VM runs;
 what runs INSIDE it is yours. Run Command and the serial console are the
 compute-layer tools that keep working when the guest network does not.

 FAULT 4 - Outbound NSG rule blocks egress to the Internet service tag
 Step 1. Note precisely what still works. Inbound HTTP returns 200 while
 outbound hangs. NSGs are STATEFUL: the reply packets of a flow that was
 allowed inbound need no outbound rule, so an outbound Deny is invisible to
 your browser and lethal to apt, agents, backups and any API call the VM makes.

 Step 2. From inside, distinguish DNS from transport:
     $ nslookup learn.microsoft.com
     Server: 168.63.129.16      <-- Azure-provided DNS still answers
     Address: 168.63.129.16#53
     Non-authoritative answer: ...
     $ curl -v -m 8 https://learn.microsoft.com/
     * Trying 23.x.x.x:443...
     * Connection timed out after 8001 milliseconds
 Name resolution fine, TCP handshake dead => a filter on the way OUT, not DNS.

 Step 3. Simulate the outbound packet:
     $ az network watcher test-ip-flow -g rg-az900-breakfix --vm vm-web01 \
         --direction Outbound --protocol TCP \
         --local 10.20.1.4:49152 --remote 23.221.222.250:443
     {
       "access": "Deny",
       "ruleName": "securityRules/lab-fault-deny-egress"
     }

 Step 4. Read the rule before deleting it - direction, priority, destination:
     $ az network nsg rule list -g rg-az900-breakfix --nsg-name nsg-nic-web \
         --include-default -o table --query \
         "sort_by([?direction=='Outbound'].{P:priority,Name:name,Access:access,Dest:destinationAddressPrefix,Port:destinationPortRange},&P)"
     P      Name                                Access  Dest       Port
     -----  ----------------------------------  ------  ---------  ----
     110    lab-allow-platform-168-63-129-16    Allow   168.63...  *
     120    lab-fault-deny-egress               Deny    Internet   80,443
     65000  AllowVnetOutBound                   Allow   VirtualNetwork  *
     65001  AllowInternetOutBound               Allow   Internet   *
     65500  DenyAllOutBound                     Deny    *          *
 'Internet' and 'VirtualNetwork' are SERVICE TAGS - Microsoft-maintained,
 auto-updated address groups. Note default rule 65001: outbound Internet is
 allowed by default, which is why only an explicit lower-priority Deny can
 break it.

 Step 5. Remove only the injected Deny, keeping the platform allow:
     $ az network nsg rule delete -g rg-az900-breakfix \
         --nsg-name nsg-nic-web -n lab-fault-deny-egress
     $ az vm run-command invoke -g rg-az900-breakfix -n vm-web01 \
         --command-id RunShellScript \
         --scripts "curl -s -o /dev/null -w '%{http_code}' -m 10 https://learn.microsoft.com/" \
         --query "value[0].message" -o tsv
     Enable succeeded: [stdout] 200 [stderr]

 What to retain: 168.63.129.16 is Azure's virtual public IP for DHCP, DNS,
 health probes and the VM agent. Any real "deny all egress" design must allow
 it explicitly or the VM loses DNS and Run Command - which is exactly how a
 hardening change turns a reachable VM into an unrecoverable one.

 Exam-level summary (topic 2.2)
 * Compute:  the VM runs; what runs inside it is the customer's job. Run
             Command / serial console are the out-of-band levers.
 * NIC:      holds the ipConfiguration; the private IP and any public IP are
             associated to it, each with its own lifecycle.
 * Subnet:   carries its own NSG and, optionally, a route table (UDR).
 * NSG:      stateful, priority-ordered (100-4096, lowest wins, first match
             stops evaluation), evaluated at BOTH subnet and NIC, with default
             rules at 65000+ that allow VNet and outbound Internet.
 * Diagnosis order that never wastes time:
             refused vs timeout -> test-ip-flow -> list-effective-nsg
             -> show-next-hop -> only then read manifests by eye.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/az-900/2.2/lab)
