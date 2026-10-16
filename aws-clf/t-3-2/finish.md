## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION - do not read until you have tried, or until you are stuck past hint 3.

 STEP 0 - Observe before touching anything.

   $ ./break-fix-3.2-global-infrastructure.sh status
   $ ./break-fix-3.2-global-infrastructure.sh client
     endpoint: http://orders.eu-west-1.aws-lab.internal:8443/orders
     { "region": "eu-west-1", "availability_zone_id": "euw1-az1",
       "data_jurisdiction": "EU", ... }
     --- http 200 in 0.203s ---

   Two findings in one response: ~200 ms for a Brazilian user (a Region choice
   problem) and BR order data being served out of the EU (a data residency
   problem). Region selection drives both. Reference:
   https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html

 STEP 1 - Fix the Region pinning (client + CLI profile).

   $ sed -i 's/^AWS_REGION=.*/AWS_REGION=sa-east-1/' ~/aws-clf-lab/3.2-global-infrastructure/app/app.env
   $ sed -i 's/^region = .*/region = sa-east-1/'     ~/aws-clf-lab/3.2-global-infrastructure/aws/config

   Real-world equivalents, in increasing order of precedence:
     profile config   ->  aws configure set region sa-east-1 --profile clf-lab
     environment      ->  export AWS_REGION=sa-east-1
     explicit flag    ->  aws s3 ls --region sa-east-1
   Verify what the CLI resolved:
     $ AWS_CONFIG_FILE=~/aws-clf-lab/3.2-global-infrastructure/aws/config \
         aws configure get region --profile clf-lab
     sa-east-1

   $ ./break-fix-3.2-global-infrastructure.sh client
     endpoint: http://orders.sa-east-1.aws-lab.internal:8443/orders
     { "error": "ServiceUnavailable",
       "message": "no healthy targets registered in sa-east-1 ... tg-orders",
       "target_health": [ { "target": "127.0.0.1:8431", "state": "unhealthy" } ] }
     --- http 503 in 0.016s ---

   The 503 is the second fault surfacing, not a regression: latency already
   dropped from ~200 ms to ~16 ms because the request now stays in-Region.

 STEP 2 - Turn the single-AZ deployment into a multi-AZ one.

   $ ./break-fix-3.2-global-infrastructure.sh az list
     sa-east-1  sa-east-1a  sae1-az1  127.0.0.1:8431  stopped / registered
     sa-east-1  sa-east-1b  sae1-az2  127.0.0.1:8432  running / no
     sa-east-1  sa-east-1c  sae1-az3  127.0.0.1:8433  running / no

   Capacity exists in sae1-az2 and sae1-az3; it was simply never registered, so
   the Region's availability collapsed to that of a single AZ. Recover the
   impaired zone AND spread the target group:

   $ ./break-fix-3.2-global-infrastructure.sh az start sa-east-1a
   $ cat > ~/aws-clf-lab/3.2-global-infrastructure/regions/sa-east-1/target-group.txt <<'EOF'
     # target group tg-orders (sa-east-1)
     127.0.0.1:8431   # sa-east-1a / sae1-az1
     127.0.0.1:8432   # sa-east-1b / sae1-az2
     127.0.0.1:8433   # sa-east-1c / sae1-az3
     EOF

   Real-world equivalent (targets must be in the load balancer's own Region;
   there is no such thing as a cross-Region target group):
     $ aws elbv2 register-targets --region sa-east-1 \
           --target-group-arn arn:aws:elasticloadbalancing:sa-east-1:111122223333:targetgroup/tg-orders/abc \
           --targets Id=i-0aaa,AvailabilityZone=sa-east-1b Id=i-0bbb,AvailabilityZone=sa-east-1c
     $ aws elbv2 describe-target-health --region sa-east-1 \
           --target-group-arn ... --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text
     i-0aaa  healthy
     i-0bbb  healthy

   $ ./break-fix-3.2-global-infrastructure.sh client
     { "region": "sa-east-1", "availability_zone_id": "sae1-az2",
       "data_jurisdiction": "BR", ... }
     --- http 200 in 0.018s ---
   Repeat it a few times: sae1-az1 / sae1-az2 / sae1-az3 alternate. Spreading
   across AZ IDs (not AZ names) is what actually buys independence, because
   "sa-east-1a" maps to a different physical zone in a different account:
   https://docs.aws.amazon.com/ram/latest/userguide/working-with-az-ids.html

 STEP 3 - Repair the global/edge endpoint.

   $ curl -sS --noproxy '*' http://edge.aws-lab.internal:8443/orders
     curl: (7) Failed to connect to edge.aws-lab.internal port 8443: Connection refused
   $ getent hosts edge.aws-lab.internal
     127.0.99.254    edge.aws-lab.internal        <- black hole
   $ ./break-fix-3.2-global-infrastructure.sh status | grep edge
     edge   127.0.99.1:8443   pop=GRU50 (Sao Paulo, BR)   up   <- where it really listens

   $ sudo sed -i 's/^127\.0\.99\.254\([[:space:]]\+edge\.aws-lab\.internal\)/127.0.99.1\1/' /etc/hosts

   Real-world equivalent: the distribution was healthy all along; the Route 53
   alias record pointed somewhere else. Only the DNS layer was broken - which is
   the point: an edge location is a separate global layer, not part of a Region.
     $ aws route53 list-resource-record-sets --hosted-zone-id Z123456ABCDEF \
           --query "ResourceRecordSets[?Name=='cdn.example.com.']"
     $ aws cloudfront get-distribution --id E1LABGLOBAL \
           --query 'Distribution.[Status,DomainName,DistributionConfig.Origins.Items[].DomainName]'
     Deployed  d111111abcdef8.cloudfront.net  [ "orders.sa-east-1.example.internal" ]

   $ curl -sSI --noproxy '*' http://edge.aws-lab.internal:8443/orders | grep -i x-cache
     X-Cache: Miss from lab-edge      # first request: fetched from the sa-east-1 origin
   $ curl -sSI --noproxy '*' http://edge.aws-lab.internal:8443/orders | grep -i x-cache
     X-Cache: Hit from lab-edge       # second: served by the PoP, origin untouched

 STEP 4 - Grade the fix.

   $ ./break-fix-3.2-global-infrastructure.sh verify
     [ ok ] [1] client and CLI profile pinned to sa-east-1
     [ ok ] [2a] sa-east-1 endpoint returns 200 with jurisdiction BR
     [ ok ] [2b] latency under 60 ms (in-Region user)
     [ ok ] [3] sa-east-1 serves from >= 2 Availability Zone IDs
     [ ok ] [4] every registered target lives in sa-east-1
     [ ok ] [5a] global endpoint edge.aws-lab.internal returns 200 from sa-east-1 origin
     [ ok ] [5b] second request served from the edge cache
     All 7 checks passed - the workload is in-Region, multi-AZ and edge-fronted.

   $ ./break-fix-3.2-global-infrastructure.sh reset

 WHAT THE THREE FAULTS TEACH, IN EXAM TERMS
   Fault 1 (Region pinning): choosing a Region is choosing latency, legal
     jurisdiction, price and service availability at once. A Region is an
     isolated geographic area; data does not leave it unless you replicate it.
   Fault 2 (single AZ): an AZ is a discrete failure domain with its own power,
     cooling and networking, connected to sibling AZs by low-latency private
     links. High availability inside a Region means >= 2 AZs; the Well-Architected
     Reliability pillar's cheapest win is spreading a target group across them.
   Fault 3 (edge layer): edge locations / PoPs are global and separate from
     Regions - they cache and route, they do not store your system of record.
     Their failure modes are DNS and origin reachability, not AZ capacity.
   Not exercised here but on the exam: Local Zones (metro-adjacent compute tied
     to a parent Region), Wavelength Zones (inside a telco 5G network) and
     Outposts (AWS racks in your own data centre for residency/hybrid) - all
     opt-in extensions of the same Region model.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/aws-clf/3.2/lab)
