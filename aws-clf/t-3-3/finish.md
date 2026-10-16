## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTIONS - read only after you have tried. One section per scenario.
 Each follows the same shape: observe, narrow, prove, fix, confirm.

GENERAL OPENING MOVE (all scenarios)
  1. Ask the load balancer what it thinks:
       curl -si http://127.0.0.1:8080/ | head -5
     A 503 body that says "N target(s) registered, 0 healthy" separates the
     first branch immediately:
       N = 0  -> nothing was ever launched  -> capacity problem (scenario 3)
       N > 0  -> instances exist but fail health checks (scenarios 1, 2, 5)
     A healthy 200 here means the EC2 path is fine and the failure is on the
     serverless path (scenario 4).
  2. Ask the group and the target state:
       cat /var/lib/awslab/instances.json
       cat /var/lib/awslab/target-health.json
       systemctl list-units 'awslab-*'
  3. Only then look at a single instance. This is the same order you would use
     in the console: ALB -> target group -> Auto Scaling group -> instance.

SCENARIO 1 - sg-ingress-blocked  (security group / firewall)
  OBSERVE
    curl -si http://127.0.0.1:8080/            -> 503, 2 registered, 0 healthy
    systemctl is-active awslab-app@1           -> active
    journalctl -u awslab-app@1 -n 20           -> clean, "listening on 0.0.0.0:8101"

  NARROW - the decisive test is refused vs. timed out:
    ss -ltnp | grep 810
      LISTEN 0 5 0.0.0.0:8101 ... users:(("python3",pid=...))
    curl -m 3 -v http://127.0.0.1:8101/health
      * Connection timed out after 3000 milliseconds
    A socket in LISTEN plus a connect timeout = packets are being dropped in
    the kernel path, not refused by the application. Refused would mean nothing
    is bound. This is precisely the signature of a security group that does not
    allow the load balancer's port.

  PROVE
    nft list ruleset | grep -A5 'table inet awslab'
      table inet awslab {
        chain input { type filter hook input priority filter; policy accept;
          tcp dport 8101-8108 counter packets N bytes M drop
        }
      }
    The counter increments every time you retry the curl - that is your proof.

  FIX - delete the offending rule. Deleting the lab's own table is the cleanest
  equivalent of removing a bad security group rule; never flush the whole ruleset
  on a machine you care about:
    nft delete table inet awslab
    # or, surgically:  nft -a list table inet awslab   # find the rule handle
    #                  nft delete rule inet awslab input handle <N>

  CONFIRM
    curl -s http://127.0.0.1:8101/health        -> OK   (immediately)
    sleep 12 && curl -s http://127.0.0.1:8080/  -> 200  (after 2 healthy checks)
    ./awslab-compute.sh verify

  WHY THE DELAY: the target group needs HealthyThresholdCount consecutive
  successes (2 here, interval 5 s) before it puts a target back in rotation.
  On a real ALB this is why "I fixed it but it is still 503" is normal for up to
  interval x threshold seconds.

  EXAM POINT: an EC2 instance can be perfectly healthy and still be unreachable.
  Security groups are stateful and allow-list only - there is no deny rule; the
  absence of an allow rule IS the drop. Instance status checks pass, the ELB
  health check does not, and that gap is the whole lesson.

SCENARIO 2 - ami-config-drift  (the instance itself)
  OBSERVE
    curl -si http://127.0.0.1:8080/   -> 503, targets registered, none healthy
    systemctl status awslab-app@1
      Active: activating (auto-restart) ... or failed
    curl -m 3 http://127.0.0.1:8101/health
      curl: (7) Failed to connect ... Connection refused     <- refused, not timeout

  NARROW - refused means the process is not listening; read why it died:
    journalctl -u awslab-app@1 -n 20 --no-pager
      FATAL: application configuration unreadable
             (/opt/awslab/app/config.json): [Errno 2] No such file or directory
    journalctl -u awslab-asg -n 20
      Launching instance i-0aa...0001 in slot 1   (repeatedly - the group is
      doing its job; the workload is what fails)

  FIX - restore the file the "AMI" was supposed to carry, then let the loop heal:
    ls -l /opt/awslab/app/
    cp /opt/awslab/app/config.json.ami-baseline /opt/awslab/app/config.json
    systemctl reset-failed 'awslab-app@*'
    systemctl restart awslab-app@1 awslab-app@2

  CONFIRM
    systemctl is-active awslab-app@1 awslab-app@2      -> active active
    sleep 12 && curl -s http://127.0.0.1:8080/         -> 200 with version 2.4.1
    ./awslab-compute.sh verify

  EXAM POINT: with EC2 (IaaS) the operating system, the runtime and everything
  the application needs on disk are YOUR responsibility under the shared
  responsibility model. AWS keeps the instance running; it has no idea your
  process is exiting. That division - "the instance is up" vs. "the application
  works" - is exactly why ELB health checks exist, and why an Auto Scaling group
  configured with EC2-type health checks will never rescue you from this.

SCENARIO 3 - asg-capacity-zero  (EC2 Auto Scaling)
  OBSERVE
    curl -si http://127.0.0.1:8080/
      503 ... target group awslab-tg: 0 target(s) registered, 0 healthy
    cat /var/lib/awslab/instances.json      -> {}
    systemctl list-units 'awslab-app@*'     -> nothing
    journalctl -u awslab-asg -n 10          -> quiet, or a ValidationError line

  NARROW - zero registered targets is not a workload failure. Nothing crashed;
  nothing was ever asked to exist. Go to the thing that decides how many:
    cat /etc/awslab/asg.conf
      MIN_SIZE=0
      MAX_SIZE=4
      DESIRED_CAPACITY=0        <- here

  FIX
    sed -i 's/^DESIRED_CAPACITY=.*/DESIRED_CAPACITY=2/; s/^MIN_SIZE=.*/MIN_SIZE=1/' \
        /etc/awslab/asg.conf
    systemctl restart awslab-asg        # (the loop also re-reads the file on its own)
    journalctl -u awslab-asg -f         # watch: "Launching instance i-0aa...0001"

  Keep min <= desired <= max. Break that ordering and the loop logs
  "ValidationError: DESIRED_CAPACITY must satisfy MIN_SIZE <= DESIRED_CAPACITY
  <= MAX_SIZE - group left unchanged", which is the same class of error the real
  API returns and a very common way to "fix" this into a second outage.

  CONFIRM
    sleep 15 && curl -s http://127.0.0.1:8080/     -> 200
    curl -s http://127.0.0.1:8080/ | grep instance_id   # run twice: two ids
    ./awslab-compute.sh verify

  EXAM POINT: minimum, maximum and desired capacity are three different things.
  Desired capacity is what the group actively drives toward; minimum is the floor
  it will never go below (including after a scale-in policy fires) and maximum is
  the ceiling a scaling policy may reach. Scaling policies move desired capacity -
  they do not move the bounds. Availability comes from spreading that capacity
  across Availability Zones, which is why the group, not the instance, is the
  unit of resilience.

SCENARIO 4 - lambda-timeout  (AWS Lambda)
  OBSERVE
    curl -s http://127.0.0.1:8080/ | head -3          -> 200, EC2 side is fine
    awslab-lambda invoke orders-api '{"items":[1,2,3]}'
      START RequestId: 1f0c... Version: $LATEST
      1f0c... Task timed out after 1.00 seconds
      END RequestId: 1f0c...
      REPORT ... Duration: 1002.41 ms Billed Duration: 1003 ms Memory Size: 256 MB
    echo $?                                            -> 1

  NARROW - there is no instance to inspect and no OS to log into; the only thing
  you own is the function configuration:
    cat /etc/awslab/functions/orders-api.json
      "Handler": "orders.handler",
      "Timeout": 1,              <- the code needs ~2 s of downstream latency
      "MemorySize": 256
    grep DOWNSTREAM /opt/awslab/lambda/orders.py
      DOWNSTREAM_LATENCY_S = 2.0

  FIX - a configuration change, not a code change:
    python3 - <<'EOF'
    import json
    p = "/etc/awslab/functions/orders-api.json"
    c = json.load(open(p)); c["Timeout"] = 10
    open(p, "w").write(json.dumps(c, indent=2) + "\n")
    EOF
    # On real AWS this is exactly:
    #   aws lambda update-function-configuration \
    #       --function-name orders-api --timeout 10

  CONFIRM
    awslab-lambda invoke orders-api '{"items":[1,2,3]}'
      {"statusCode": 200, "body": {"orders_processed": 3, "remaining_ms": 79xx}}
      REPORT ... Duration: 2003.11 ms Billed Duration: 2004 ms
    echo $?                                            -> 0
    ./awslab-compute.sh verify

  EXAM POINTS
    * Timeout is a per-function ceiling, maximum 900 seconds (15 minutes). Work
      that legitimately runs longer belongs on ECS/Fargate, AWS Batch or EC2 -
      a favourite exam distinction.
    * You are billed for requests and for duration (rounded up to the ms) x the
      memory configured. Memory and vCPU are coupled: raising MemorySize also
      raises CPU, so an over-tight memory setting can itself cause timeouts, and
      more memory sometimes costs LESS because the function finishes sooner.
    * A wrong Handler string produces Runtime.HandlerNotFound instead - the other
      classic configuration failure, and equally invisible from the code.
    * Nothing here involved patching, capacity or a health check. That absence is
      the definition of serverless for the exam: no servers to provision or manage,
      automatic scaling, pay for what you use.

SCENARIO 5 - imds-unreachable  (instance metadata / instance profile)
  OBSERVE
    curl -si http://127.0.0.1:8080/          -> 503, targets registered, unhealthy
    journalctl -u awslab-app@1 -n 10
      FATAL: instance metadata unavailable at http://169.254.169.254
             (URLError: <urlopen error [Errno 101] Network is unreachable>)
    systemctl status awslab-imds
      Active: activating (auto-restart)
    journalctl -u awslab-imds -n 10
      OSError: [Errno 99] Cannot assign requested address

  NARROW - "cannot assign requested address" is a bind failure, not a logic bug.
  The daemon is asking for an address the host no longer has:
    ip -4 addr show dev lo
      inet 127.0.0.1/8 scope host lo          <- 169.254.169.254 is gone

  FIX
    ip addr add 169.254.169.254/32 dev lo
    systemctl restart awslab-imds
    systemctl reset-failed 'awslab-app@*'
    systemctl restart awslab-app@1 awslab-app@2

  CONFIRM - always with IMDSv2's two steps, never a bare GET:
    TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token \
              -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')
    curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
         http://169.254.169.254/latest/meta-data/instance-id
    sleep 12 && curl -s http://127.0.0.1:8080/       -> 200
    ./awslab-compute.sh verify

  A GET without that token returns 401 by design. If you ever see a 401 from a
  real instance, the SDK or script is speaking IMDSv1 to an instance where
  HttpTokens=required.

  EXAM POINTS: 169.254.169.254 is link-local - it never leaves the instance and
  is not billed as traffic. It is how an instance learns its own identity
  (instance id, type, AZ, region) and, critically, how the AWS SDKs obtain the
  temporary credentials of the attached IAM instance profile. That is why you
  attach a ROLE to an instance instead of copying access keys onto it: the
  credentials are short-lived, rotated automatically, and never stored on disk.
  Lose the metadata path and an instance loses its identity and its permissions
  at once - which is also why IMDSv2's session-token requirement matters as an
  SSRF defence.

ONE-LINE SUMMARY TO CARRY INTO THE EXAM
  The 503 is never the diagnosis. Walk the layers in order - load balancer,
  target group, Auto Scaling group, instance, and finally the process - and the
  layer where the answer changes is the AWS compute service the question is
  actually about.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/aws-clf/3.3/lab)
