## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
============================  SOLUTION  =====================================
 Stop here unless you have already tried. Everything below is the answer.

STEP 0 — enter the lab and take stock
  source /opt/support-lab/env.sh
  support-lab status
    control plane ..... up (127.0.0.1:4599)
    support plan ...... basic
    configured region . (unset)
  Reading a status line before touching anything is the whole discipline:
  two of the four faults are already visible here.

FAULT 1 — no region configured
  Symptom:
    $ aws sts get-caller-identity
    You must specify a region. You can also configure your region by running "aws configure".

  Diagnosis: the CLI resolves the region in a fixed order — --region flag,
  then AWS_REGION, then AWS_DEFAULT_REGION, then the `region` key of the
  active profile in ~/.aws/config. All four are empty. The rebuild dropped
  the config file.

  Fix (the workload is in us-east-1, so that is the region):
    aws configure set region us-east-1
    aws configure get region          # -> us-east-1
    aws sts get-caller-identity       # -> arn:aws:iam::000000000000:user/lab-student

  Worth knowing for the exam: AWS Support and AWS Health are global services
  whose API endpoint lives in US East (N. Virginia); Service Quotas is
  regional — a quota raised in us-east-1 does nothing for eu-west-1.

FAULT 2 — the account is on Basic Support
  Symptom:
    $ aws support describe-severity-levels
    An error occurred (SubscriptionRequiredException) when calling the
    DescribeSeverityLevels operation: Amazon Web Services Premium Support
    Subscription is required to use this service.
    $ aws health describe-events        # same error
    $ support-lab ta-console            # core checks only

  Diagnosis: Basic Support gives you documentation, whitepapers, re:Post, the
  Knowledge Center, the AWS Health Dashboard, service quota increases, the
  core Trusted Advisor checks, and 24x7 access to account and billing support
  only. It does NOT give you technical support cases, the AWS Support API,
  the AWS Health API, or the full Trusted Advisor check set. Developer adds
  business-hours technical cases but still no API access. The Support API and
  the Health API start at Business.
    https://aws.amazon.com/premiumsupport/plans/
    https://docs.aws.amazon.com/awssupport/latest/APIReference/Welcome.html
    https://docs.aws.amazon.com/health/latest/ug/health-api.html

  Fix (in a real account: Billing and Cost Management -> Support plans, as
  root or an IAM principal with supportplans permissions):
    support-lab plan get              # basic
    support-lab plan set business
    aws support describe-severity-levels
      low     General guidance            24 hours
      normal  System impaired             12 hours
      high    Production system impaired   4 hours
      urgent  Production system down       1 hour

  Note what did NOT appear: `critical` (business-critical system down). That
  severity exists only on Enterprise On-Ramp (30-minute target) and
  Enterprise (15-minute target). This is fault 3, and you have just diagnosed
  it without seeing the error yet.

FAULT 3 — the runbook opens the case at a severity the plan does not have
  Symptom:
    $ bash /opt/support-lab/drafts/10-open-case.sh
    An error occurred (InvalidParameterValueException) when calling the
    CreateCase operation: severityCode 'critical' is not available for support
    plan 'business'. Available: low, normal, high, urgent.

  Diagnosis: the runbook was written for an Enterprise account. Severity is
  not a mood, it is a contract: each code maps to a documented first-response
  target, and the available codes are a function of the plan.
    https://docs.aws.amazon.com/awssupport/latest/user/case-management.html

  Fix — classify the case honestly. Production is down, so `urgent`:
    sed -i 's/--severity-code "critical"/--severity-code "urgent"/' \
      /opt/support-lab/drafts/10-open-case.sh
    bash /opt/support-lab/drafts/10-open-case.sh
    # -> {"caseId": "case-000000000000-lab-2026-00000001"}
    aws support describe-cases

  Equivalent single command, if you prefer not to touch the runbook:
    aws support create-case \
      --subject "[LAB4.3] Auto Scaling cannot launch: EC2 On-Demand quota exhausted in us-east-1" \
      --service-code "amazon-elastic-compute-cloud-linux" \
      --category-code "instance-issue" \
      --severity-code "urgent" \
      --language "en" \
      --communication-body "Production checkout fleet is down..."

  Discover valid classification codes instead of guessing:
    aws support describe-services

FAULT 4 — the quota request targets a non-adjustable quota
  Symptom:
    $ bash /opt/support-lab/drafts/20-raise-quota.sh
    An error occurred (InvalidParameterValueException) when calling the
    RequestServiceQuotaIncrease operation: The quota 'L-LABF1XED' (Lab
    simulated hard limit (NOT adjustable)) is not adjustable and cannot be
    increased.

  Diagnosis: Service Quotas marks every quota as adjustable or not. A
  non-adjustable quota is an architectural constraint — you design around it,
  you do not file a case about it. Somebody pasted the wrong code from chat.
    https://docs.aws.amazon.com/servicequotas/latest/userguide/intro.html

  Fix — list the quotas and pick the adjustable one that matches the failure:
    aws service-quotas list-service-quotas --service-code ec2
      L-1216C47A  Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances  5.0  Adjustable: true
      L-0263D0A3  EC2-VPC Elastic IPs                                               5.0  Adjustable: true
      L-LABF1XED  Lab simulated hard limit (NOT adjustable)                         5.0  Adjustable: false

    aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A
    aws service-quotas request-service-quota-increase \
      --service-code ec2 --quota-code L-1216C47A --desired-value 20
    aws service-quotas list-requested-service-quota-change-history --service-code ec2
      # Status: PENDING

  Two exam-relevant facts hiding in this step: quota increases are available
  on every plan, Basic included — you never need to buy support to raise a
  limit; and the Trusted Advisor "Service Limits" check is one of the core
  free checks precisely because it warns you at ~80% usage, before 03:40.

STEP 5 — read the account-specific health signal
    aws health describe-events
  PUBLIC events are what anyone can read on the AWS Health Dashboard without
  a plan. ACCOUNT_SPECIFIC events — the degraded instance store on
  i-0lab00000000000a1, the scheduled RDS maintenance — are yours, and reaching
  them programmatically is what the Business plan bought you. This is the
  distinction between "Service health" and "Your account health".
    https://docs.aws.amazon.com/health/latest/ug/what-is-aws-health.html

STEP 6 — grade
    support-lab verify
    # score: 6/6

THE CONCEPTUAL ANSWERS
  Plan capability ladder (each tier includes the one below it):
    Basic               docs, whitepapers, re:Post, Knowledge Center, AWS
                        Health Dashboard, quota increases, core Trusted
                        Advisor checks, account and billing support 24x7
    Developer           technical cases in business hours, general guidance
                        (24h) and system impaired (12h)
    Business            24x7 phone/chat/email, ALL Trusted Advisor checks,
                        AWS Support API, AWS Health API, third-party software
                        support, IAM-controlled case access, high (4h) and
                        urgent (1h)
    Enterprise On-Ramp  pooled Technical Account Managers, Concierge for
                        billing, Well-Architected reviews, critical (30 min)
    Enterprise          designated TAM, Incident Detection and Response,
                        Infrastructure Event Management, training, critical
                        (15 min)

  Free versus paid, from this lab: quota increases FREE, public AWS Health
  Dashboard FREE, re:Post FREE, Knowledge Center FREE, core Trusted Advisor
  checks FREE — the AWS Health API, the Support API, the full Trusted Advisor
  set and technical cases are the paid part.

  Who to engage for a six-month migration:
    AWS Professional Services  AWS's own consultants, joint engagement
    APN partner                a vetted third party, often the right answer
    AWS IQ                     short, scoped tasks with independent experts
    AMS                        ongoing operation of your infrastructure,
                               not a migration project
    A TAM                      guidance and advocacy, not delivery capacity

  Run `support-lab docs` for the full resource map with official URLs.

  Cleanup:  ./break-fix-4.3-support.sh --restore
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/aws-clf/4.3/lab)
