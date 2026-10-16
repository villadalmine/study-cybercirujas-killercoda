## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION WALKTHROUGH - do not read until you have genuinely attempted the fix

 The trap in this lab is that three of the four objectives look like they can
 be solved by editing endpoint.conf. They cannot. Pointing the client at a
 different single port relocates the single point of failure. The fix is
 structural, and it is the same structure AWS sells as managed services.

 STEP 1 - Add capacity, in a second and third "Availability Zone"
 Objectives B and D both require more than one node, so build them first.
 Copy the node-a unit twice, changing PORT, NODE_ID and - for node-c - the
 REGION_ID, and add the Restart= directive node-a is missing (objective C).

   for spec in "b 18082 dc-1" "c 18083 dc-2"; do
     set -- $spec
     name=$1; port=$2; region=$3
     cat > /etc/systemd/system/clf-lab-node-${name}.service <<EOF
   [Unit]
   Description=CLF-C02 lab node-${name}
   After=network.target

   [Service]
   Type=simple
   Environment=PORT=${port}
   Environment=NODE_ID=node-${name}
   Environment=REGION_ID=${region}
   Environment=MAX_CONCURRENCY=4
   ExecStart=/usr/bin/python3 /opt/clf-lab-1-1/app/server.py
   Restart=always
   RestartSec=1
   StandardOutput=append:/opt/clf-lab-1-1/log/node-${name}.log
   StandardError=append:/opt/clf-lab-1-1/log/node-${name}.log

   [Install]
   WantedBy=multi-user.target
   EOF
   done

 Give node-a the same self-healing property. Never hand-edit a unit file that
 a tool generated; use the drop-in mechanism, which is the systemd equivalent
 of not mutating an instance outside its launch template:

   mkdir -p /etc/systemd/system/clf-lab-node-a.service.d
   printf '[Service]\nRestart=always\nRestartSec=1\n' \
     > /etc/systemd/system/clf-lab-node-a.service.d/10-self-heal.conf

   systemctl daemon-reload
   systemctl enable --now clf-lab-node-a clf-lab-node-b clf-lab-node-c

 Confirm all three answer, and note the region labels:

   for p in 18081 18082 18083; do curl -s http://127.0.0.1:$p/region; echo; done
   dc-1:node-a
   dc-1:node-b
   dc-2:node-c

 STEP 2 - Put a load balancer in front, and stop hardcoding the backend
 This is the objective-A fix and the one that carries the exam concept. The
 client must address a STABLE NAME; something else decides which healthy
 target answers. Write a health-checking dispatcher:

   cat > /opt/clf-lab-1-1/bin/elb.sh <<'EOF'
   #!/usr/bin/env bash
   # Minimal Application Load Balancer: health-check, then round-robin over
   # the targets that passed. Mirrors an ALB target group.
   set -uo pipefail
   TARGETS=(18081 18082 18083)
   STATE=/opt/clf-lab-1-1/state/rr

   healthy=()
   for p in "${TARGETS[@]}"; do
     curl -fsS --max-time 1 "http://127.0.0.1:${p}/health" >/dev/null 2>&1 \
       && healthy+=("$p")
   done
   (( ${#healthy[@]} == 0 )) && exit 1        # 503: no healthy targets

   idx=$(( ( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ) % ${#healthy[@]} ))
   echo "$idx" > "$STATE"
   curl -fsS --max-time 3 "http://127.0.0.1:${healthy[$idx]}/work"
   EOF
   chmod 0755 /opt/clf-lab-1-1/bin/elb.sh

 Then repoint the client's run_one at the balancer instead of the hardcoded
 host:port. Edit /opt/clf-lab-1-1/bin/client.sh and replace the body of
 run_one with:

   run_one() { /opt/clf-lab-1-1/bin/elb.sh >/dev/null 2>&1; }

 The health check is what makes this fault tolerant rather than merely
 redundant: a dead target is excluded on the very next request, with no human
 in the loop. That is the mechanism behind an ALB target group, and the
 reason 'unhealthy threshold' and 'health check interval' are tunable knobs -
 they set how fast the system converges after a failure.
     https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html

 Prove objective A the way the grader does:

   systemctl stop clf-lab-node-b
   /opt/clf-lab-1-1/bin/client.sh 10 2
   requests=10 ok=10 failed=0 availability=100%
   systemctl start clf-lab-node-b

 STEP 3 - Elasticity: add nodes, do not enlarge one
 Aggregate capacity is now 2 + 4 + 4 = 10, spread across three nodes, so the
 20-request burst at concurrency 8 clears:

   /opt/clf-lab-1-1/bin/client.sh 20 8
   requests=20 ok=20 failed=0 availability=100%

 Why the rule forbade raising MAX_CONCURRENCY on node-a: that is vertical
 scaling. It has a hard ceiling (the largest instance type in existence), it
 usually requires a restart, and it leaves you paying peak-sized hardware
 during the trough. Horizontal scaling has neither property, which is why
 Auto Scaling groups scale out and in rather than up and down.
     https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html

 Scaling back IN is the half students forget and the half the exam rewards.
 Elasticity is bidirectional; releasing capacity is where the cost benefit
 actually lands:

   systemctl stop clf-lab-node-c      # burst over, stop paying for it

 (Leave it running for the grader - objective D needs region dc-2 alive.)

 STEP 4 - Global reach: prove the second region can take over alone
 node-c carries REGION_ID=dc-2. Simulate the total loss of dc-1:

   systemctl stop clf-lab-node-a clf-lab-node-b
   /opt/clf-lab-1-1/bin/client.sh 10 2
   requests=10 ok=10 failed=0 availability=100%
   curl -s http://127.0.0.1:18083/region
   dc-2:node-c

   systemctl start clf-lab-node-a clf-lab-node-b     # restore before verify

 In AWS the steering is Route 53 failover routing: a primary record with a
 health check, a secondary record that takes the traffic when the primary is
 unhealthy. The important architectural fact is that AWS Regions are isolated
 from each other on purpose - separate control planes, separate failure
 domains - which is exactly what makes a second Region a real disaster
 recovery boundary and a second AZ only a facility-level one.
     https://aws.amazon.com/about-aws/global-infrastructure/regions_az/
     https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html

 STEP 5 - Grade and tear down
   sudo /path/to/this-script verify      # expect 4/4
   sudo /path/to/this-script clean

 MAPPING THE LAB TO THE EXAM VOCABULARY
 What you built by hand      | AWS service                | Benefit named in 1.1
 ----------------------------|----------------------------|---------------------
 elb.sh + /health polling    | Elastic Load Balancing     | High availability,
                             |                            | fault tolerance
 three nodes, two regions    | Multi-AZ / multi-Region    | High availability,
                             |                            | global reach
 adding & removing nodes     | EC2 Auto Scaling           | Elasticity, cost
                             |                            | (pay for what you use)
 Restart=always              | ASG health-check replace   | Self-healing, less
                             |                            | undifferentiated toil
 ~90 seconds to build it     | API-driven provisioning    | Agility, speed to market
 hardware you never bought   | AWS capital expenditure    | Economies of scale,
                             |                            | CapEx -> OpEx

 Three exam-grade distinctions this lab makes concrete:

 1. HIGH AVAILABILITY vs FAULT TOLERANCE. Two nodes behind a health-checked
    balancer is high availability: failures cause a brief, small degradation.
    Fault tolerance is stronger - zero impact from the defined fault. Note
    that in step 2 the in-flight request to node-b still failed; only the
    NEXT one was routed away. Recovery time is never zero.

 2. SCALABILITY vs ELASTICITY. Scalability is the capability to grow.
    Elasticity is growing AND shrinking automatically with demand. Step 3
    without the `systemctl stop` in it is scalability only, and it is why an
    unmonitored Auto Scaling group can still produce a large bill.

 3. WHAT YOU STILL OWN. Nothing here removed your responsibility for the
    application code, its configuration or its data. Under the AWS Shared
    Responsibility Model, AWS is responsible for the security OF the cloud;
    you remain responsible for security IN the cloud. Managed infrastructure
    is not managed correctness.
        https://aws.amazon.com/compliance/shared-responsibility-model/

 A closing caveat on the simulation's limits: everything above ran on ONE
 kernel, ONE disk and ONE power supply. It reproduces the control-flow of a
 resilient architecture, not its physical independence. Real Availability
 Zones are discrete facilities with independent power, cooling and networking,
 meshed with low-latency links - and that physical separation, which no script
 can simulate, is the part you are actually buying.
     https://aws.amazon.com/about-aws/global-infrastructure/regions_az/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/aws-clf/1.1/lab)
