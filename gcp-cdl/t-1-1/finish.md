## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — do not read until you have tried. Every step ends with the one
 cloud command that replaces it, because that mapping IS objective 1.1.

 STEP 0 — Diagnose before touching anything (2 min)
   curl -s -i http://127.0.0.1:8080/orders | head -n 20
   curl -s    http://127.0.0.1:8080/healthz
   df -h /var/tmp/gcp-cdl-lab-1.1/mnt
   du -h --max-depth=1 /var/tmp/gcp-cdl-lab-1.1/mnt
   journalctl -u lab-orders-api@8080 -n 50 --no-pager
   systemctl show lab-orders-api@8080 -p CPUQuota,CPUQuotaPerSecUSec,MemoryMax,TasksMax
   systemd-cgtop -1 -n 2 | grep lab-orders

 Read: two independent constraints. Storage is at 100% (Errno 28), and CPU is
 clamped at 10% of one core. Fixing only one leaves the burst failing. Also
 note that /healthz stayed 200 the entire time — your first post-incident
 action item is a probe that exercises the ledger write.

 STEP 1 — Reclaim the obvious waste (the on-prem reflex)
   ls -lh /var/tmp/gcp-cdl-lab-1.1/mnt
   rm -f  /var/tmp/gcp-cdl-lab-1.1/mnt/legacy_nightly_dump.bin
   sync; df -h /var/tmp/gcp-cdl-lab-1.1/mnt
   curl -s http://127.0.0.1:8080/orders          # 200 again — orders flow

 Orders settle again, and check [3] still fails: 48 MiB of volume cannot show
 200 MiB free. This is the honest lesson. Deleting files buys hours, not
 headroom; the ceiling is the purchase order. On premises the next move is a
 capacity request with a lead time measured in weeks.

 STEP 2 — Grow the volume WITHOUT downtime (elastic block storage)
   IMG=/var/tmp/gcp-cdl-lab-1.1/ledger-lun.img
   MNT=/var/tmp/gcp-cdl-lab-1.1/mnt
   LOOP=$(losetup -j "$IMG" | cut -d: -f1)

   truncate -s 512M "$IMG"      # the array grows                (provider side)
   losetup -c "$LOOP"           # the block device re-reads size (guest side)
   resize2fs "$LOOP"            # the filesystem takes the space (guest side)

   df -h "$MNT"                 # ~470 MiB free, service never stopped

 Note that traffic kept flowing: ext4 online resize needs no unmount. That is
 the point. Three commands, seconds, zero downtime.

   On Google Cloud the first command is the whole first half:
     gcloud compute disks resize ledger-lun --size=500GB --zone=us-central1-a
     # then, inside the guest: sudo resize2fs /dev/sdb
   Persistent Disk grows online, is billed per provisioned GiB-month, and
   never required anyone to open a rack.
     https://cloud.google.com/compute/docs/disks/resize-persistent-disk

 STEP 3 — Fix compute. Pick vertical, horizontal, or both.
 3a) VERTICAL — resize the machine (fastest, still one failure domain):

       systemctl edit lab-orders-api@8080
       # in the drop-in editor:
       #   [Service]
       #   CPUQuota=400%
       #   MemoryMax=512M
       systemctl restart lab-orders-api@8080

     or edit /etc/systemd/system/lab-orders-api@8080.service.d/10-capex-allocation.conf
     directly, then: systemctl daemon-reload && systemctl restart lab-orders-api@8080

     Cloud equivalent — a stop, one flag, a start; no hardware, no window:
       gcloud compute instances stop orders-vm --zone=us-central1-a
       gcloud compute instances set-machine-type orders-vm \
         --machine-type=c4-standard-8 --zone=us-central1-a
       gcloud compute instances start orders-vm --zone=us-central1-a
       https://cloud.google.com/compute/docs/instances/changing-machine-type-of-stopped-instance

 3b) HORIZONTAL — more instances behind one front door (the cloud answer):

       # move the app off the customer-facing port, then add nodes
       systemctl stop lab-orders-api@8080
       systemctl start lab-orders-api@8081
       systemctl start lab-orders-api@8082
       curl -s -D- http://127.0.0.1:8081/orders | grep X-Served-By   # node-8081

       # put a load balancer on :8080 (nginx shown; haproxy works the same)
       cat >/etc/nginx/conf.d/orders-lab.conf <<'NGINX'
       upstream orders_backends {
           server 127.0.0.1:8081;
           server 127.0.0.1:8082;
       }
       server {
           listen 127.0.0.1:8080;
           location / {
               proxy_pass http://orders_backends;
               proxy_next_upstream error timeout http_500;
           }
       }
       NGINX
       nginx -t && systemctl reload nginx

     If nginx/haproxy is not installed on your lab VM, take path 3a — the
     grader only measures the customer's experience on :8080.

     Cloud equivalent — capacity that follows demand instead of forecasts:
       gcloud compute instance-templates create orders-tmpl \
         --machine-type=c4-standard-4 --image-family=debian-12 \
         --image-project=debian-cloud
       gcloud compute instance-groups managed create orders-mig \
         --template=orders-tmpl --size=2 --zone=us-central1-a
       gcloud compute instance-groups managed set-autoscaling orders-mig \
         --max-num-replicas=20 --min-num-replicas=2 --target-cpu-utilization=0.6 \
         --cool-down-period=90 --zone=us-central1-a
       # + a global external Application Load Balancer in front of the MIG
       https://cloud.google.com/compute/docs/autoscaler
       https://cloud.google.com/load-balancing/docs/load-balancing-overview

     The autoscaler is the sentence "the cloud is revolutionizing businesses"
     written as a command: the burst adds nodes at 20:40 and removes them at
     02:00, and you pay for the second-level consumption, not the peak.

 STEP 4 — Prove it
   sudo bash THIS_SCRIPT verify
   # expect: [1] PASS  [2] PASS  [3] PASS  [4] PASS

 If [4] still fails, your CPU allocation is still the bottleneck: check
 `systemctl show lab-orders-api@<port> -p CPUQuota` on the units that are
 actually serving, and confirm the load balancer is spreading traffic
 (`grep X-Served-By` across several requests).

 STEP 5 — Clean up
   sudo bash THIS_SCRIPT cleanup
   rm -f /etc/nginx/conf.d/orders-lab.conf && systemctl reload nginx   # if used

 WHAT YOU JUST PROVED (this is what the exam asks in words)
 * CAPEX -> OPEX. The 48 MiB LUN and the 10% CPU quota were money spent before
   demand was known. Both were wrong, in the expensive direction and the
   outage direction at once. Resize and autoscale convert that bet into
   metered consumption: you pay for the burst during the burst.
 * ELASTICITY IS NOT "BIG". Overprovisioning for peak is how on-prem survives
   Black Friday, and it wastes the other 364 days. Elastic means capacity
   tracks demand in both directions.
 * TIME TO MARKET. Time your fix. Now price the same fix when the storage
   shelf must be quoted, approved, shipped, racked and zoned — weeks. Every
   week is a feature your competitor shipped and you did not. That, not the
   hourly rate, is the number executives are buying.
 * TCO IS NOT THE INVOICE. The invoice is a line item; TCO includes the rack,
   the power, the spare shelf that sits idle, the maintenance window, the
   on-call night, and the revenue lost during it.
   https://cloud.google.com/architecture/framework/cost-optimization
 * MANAGED SERVICES MOVE THE LINE. You still ran resize2fs inside the guest.
   Move this ledger to a managed database or object storage and even that step
   disappears; the undifferentiated work becomes the provider's problem while
   your team keeps the part customers pay for.
 * MEASURE THE BUSINESS TRANSACTION. /healthz was 200 through the entire
   outage. A digital transformation that migrates infrastructure but keeps
   monitoring the process instead of the order is a lift-and-shift with a
   green dashboard.

 Reference: Cloud Digital Leader exam guide, section 1.1
 https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/gcp-cdl/1.1/lab)
