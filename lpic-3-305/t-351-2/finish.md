## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
#   SOLUTION — read only after you have genuinely tried to fix it          #
#   =====================================================================  #
#                                                                          #
#   Root cause: the guest's `vif` line in its /etc/xen/<guest>.cfg names   #
#   a Linux bridge (`bridge=xenbr-lab-broken`) that does not exist. When   #
#   `xl create` runs, libxl calls the hotplug script                      #
#   /etc/xen/scripts/vif-bridge, which tries to add the guest's vifX.Y     #
#   device to that bridge, fails, and tears the interface down. The domain #
#   object may exist but has no working network.                          #
#                                                                          #
#   STEP 1 — Observe the failure and read the logs                        #
#   ---------------------------------------------------------------------  #
#     # xl create -c /etc/xen/<guest>.cfg                                  #
#     # xl dmesg | tail                                                    #
#     # ls -t /var/log/xen/ | head                                        #
#     # less /var/log/xen/xl-<guest>.log                                  #
#   Expected line:                                                         #
#     /etc/xen/scripts/vif-bridge: could not find bridge device           #
#     xenbr-lab-broken                                                     #
#                                                                          #
#   STEP 2 — List the bridges that ACTUALLY exist on Dom0                 #
#   ---------------------------------------------------------------------  #
#     # ip -o link show type bridge                                        #
#     # brctl show            # (bridge-utils, if installed)               #
#     # bridge link                                                        #
#   Expected: a real bridge such as `xenbr0` (or `br0`) is listed. That    #
#   is the name the guest must reference. If NO bridge exists, the host    #
#   networking itself is unconfigured — create one, e.g.:                  #
#     # ip link add name xenbr0 type bridge                                #
#     # ip link set xenbr0 up                                              #
#     # ip link set eth0 master xenbr0            # enslave the uplink     #
#   (or configure it persistently via the distro network stack).          #
#                                                                          #
#   STEP 3 — Correlate: where is the wrong name written?                  #
#   ---------------------------------------------------------------------  #
#     # grep -n vif /etc/xen/<guest>.cfg                                   #
#   You will see, for example:                                            #
#     vif = [ 'mac=00:16:3e:aa:bb:cc,bridge=xenbr-lab-broken' ]           #
#                                                                          #
#   STEP 4 — Fix the config: point the vif at the real bridge            #
#   ---------------------------------------------------------------------  #
#     # vi /etc/xen/<guest>.cfg                                            #
#   Change bridge=xenbr-lab-broken  ->  bridge=xenbr0   (your real one)   #
#     vif = [ 'mac=00:16:3e:aa:bb:cc,bridge=xenbr0' ]                     #
#                                                                          #
#   STEP 5 — Recreate the guest and prove the interface is attached      #
#   ---------------------------------------------------------------------  #
#     # xl destroy <guest>              # clear the broken instance        #
#     # xl create /etc/xen/<guest>.cfg                                     #
#     # xl list                          # <guest> should be running       #
#     # xl network-list <guest>                                            #
#   Expected xl network-list output:                                       #
#     Idx BE Mac Addr.          handle state evt-ch tx-/rx-ring-ref BE-path#
#     0   0  00:16:3e:aa:bb:cc  0      4     <n>    <..>/<..>       /local..#
#   state 4 == 'connected'. From Dom0 you should also see the backend vif: #
#     # ip link show | grep vif                                           #
#     # brctl show xenbr0            # the guest's vifX.Y is now enslaved   #
#                                                                          #
#   STEP 6 — Confirm connectivity from inside the guest                  #
#   ---------------------------------------------------------------------  #
#     # xl console <guest>                                                 #
#     (guest)# ip addr show eth0     # link UP, address present            #
#     (guest)# ping -c1 <gateway>                                          #
#     Detach console with:  Ctrl-]                                         #
#                                                                          #
#   Grade it:   sudo ./351.2-xen-breakfix.sh verify                        #
#                                                                          #
#   Why this matters (exam 351.2): the xl toolstack does not validate      #
#   that the bridge in a vif exists — it delegates attachment to the       #
#   vif-bridge hotplug script at create time. Diagnosing DomU networking   #
#   therefore means reading /var/log/xen/, knowing `xl network-list`       #
#   state codes, and reconciling the guest config against the real Dom0    #
#   bridge topology (ip link / brctl).                                     #
#                                                                          #
############################################################################
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpic-3-305/351.2/lab)
