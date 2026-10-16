## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
  because resolution already finished.

  Fix:
    mv /opt/srm-lab/home/srmapp/.aws/credentials \
       /opt/srm-lab/home/srmapp/.aws/credentials.revoked-$(date +%F)
    # in the real world you would also do the part that actually matters:
    #   aws iam update-access-key --access-key-id AKIA... --status Inactive \
    #       --user-name legacy-deploy-user
    #   aws iam delete-access-key --access-key-id AKIA... --user-name legacy-deploy-user
    systemctl restart srm-webapp

  Verify:
    curl -s http://127.0.0.1:8080/ | head -4
      -> credential source : instance-profile
      -> principal         : arn:aws:sts::123456789012:assumed-role/srm-lab-app-role/i-0abc1234lab5678de

  Real AWS equivalent of the whole remediation:
    aws ec2 associate-iam-instance-profile --instance-id i-... \
        --iam-instance-profile Name=srm-lab-app-role
    aws ec2 modify-instance-metadata-options --instance-id i-... \
        --http-tokens required --http-put-response-hop-limit 1

  Exam sentence: AWS runs IAM and guarantees it evaluates policies correctly.
  WHO your principals are, what they may do, whether you use short-lived role
  credentials or leave a 3-year-old access key on a disk — all customer.

STEP 3 — Data protection (customer: exposure, encryption at rest and in transit)
  Diagnosis:
    s3ctl describe srm-lab-customer-data
      -> PublicAccessBlockConfiguration: all four false
      -> ACL: public-read
      -> ServerSideEncryptionConfiguration: null
      -> bucket policy: 0 statements
    head -c 16 /opt/srm-lab/s3/buckets/srm-lab-customer-data/objects/customer-records.csv
      -> readable CSV, i.e. no ciphertext, no "Salted__" envelope
    curl -s http://<primary-ip>:8080/public/customer-records.csv
      -> the records, to anybody, with no credentials

  Fix, in this order (close the exposure first, then harden):
    rm -f /opt/srm-lab/www/public/customer-records.csv
    s3ctl block-public-access srm-lab-customer-data
    s3ctl set-acl srm-lab-customer-data private
    s3ctl encrypt-bucket srm-lab-customer-data
    s3ctl put-policy srm-lab-customer-data \
          /opt/srm-lab/templates/bucket-policy-tls-only.json

  Verify:
    s3ctl get srm-lab-customer-data customer-records.csv            # works
    s3ctl get srm-lab-customer-data customer-records.csv --no-tls   # AccessDenied
    curl -s http://<primary-ip>:8080/public/customer-records.csv    # 404

  Real AWS equivalents:
    aws s3api put-public-access-block --bucket <b> \
      --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,\
    BlockPublicPolicy=true,RestrictPublicBuckets=true
    aws s3api put-bucket-acl --bucket <b> --acl private
    aws s3api put-bucket-encryption --bucket <b> \
      --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":
        {"SSEAlgorithm":"aws:kms","KMSMasterKeyID":"arn:aws:kms:...:key/..."},
        "BucketKeyEnabled":true}]}'
    aws s3api put-bucket-policy --bucket <b> --policy file://tls-only.json

  The TLS-only statement, verbatim (this is the one to memorise):
    {"Version":"2012-10-17","Statement":[{
      "Sid":"DenyInsecureTransport","Effect":"Deny","Principal":"*",
      "Action":"s3:*",
      "Resource":["arn:aws:s3:::<b>","arn:aws:s3:::<b>/*"],
      "Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}

  Exam sentence: AWS gives you the durability, the KMS HSMs, the TLS
  endpoints and Block Public Access. Whether the bucket is public, whether
  encryption is on, and WHAT you put in the object are the customer's — the
  customer always owns the data itself and its classification.

STEP 4 — Guest OS patching (customer on EC2; AWS on managed services)
  Diagnosis:
    cat /opt/srm-lab/agent/VERSION            -> 1.0.2
    cat /opt/srm-lab/agent/advisories.json    -> LAB-2026-0001 fixed in 1.0.3

  Fix:
    srm-patch

  Real AWS equivalents:
    sudo dnf -y update                                  # or apt-get upgrade
    aws ssm send-command --document-name AWS-RunPatchBaseline \
        --targets Key=instanceids,Values=i-... --parameters Operation=Install
    # or bake a new AMI with EC2 Image Builder and replace the instance

  Then read, and do NOT modify:
    cat /opt/srm-lab/aws-managed/managed-service-patch-level.txt

  Exam sentence: the same task changes owner with the service model.
  EC2 (IaaS): guest OS, kernel, packages, agents -> CUSTOMER.
  RDS / ElastiCache / OpenSearch (managed): engine and underlying OS -> AWS.
  Lambda / S3 / DynamoDB (serverless): the entire runtime -> AWS, and the
  customer's surface shrinks to IAM, data and configuration.
  This is why the model is sometimes drawn as a dial rather than a wall:
  "inherited controls" grow as you move from EC2 toward serverless.

STEP 5 — The trap: leave the AWS side alone
  Nothing to do. If AWS-SIDE-INTEGRITY fails, you edited a file under
  /opt/srm-lab/aws-managed/ — hypervisor firmware, physical datacenter
  controls, or a managed engine's patch level. In a real account there is no
  command that does that, and reaching for one is a diagnosis error, not a
  permissions error. The correct customer actions on that side of the line
  are exactly three:
    1. rely on the SLA and the AWS Health Dashboard for availability events,
    2. download the third-party attestations from AWS Artifact for auditors,
    3. open a support case — you do not remediate, you escalate.
  If you did modify a file, restore it and re-baseline honestly:
    sudo /path/to/srm-lab.sh clean && sudo /path/to/srm-lab.sh run

STEP 6 — Final verification
  srm-audit ; echo "exit=$?"          # expect 8/8 PASS and exit=0
  curl -s http://<primary-ip>:8080/ | head -5

  Then tear the VM down:
    sudo /path/to/srm-lab.sh clean

 THE ONE-PARAGRAPH TAKEAWAY (this is what Task 2.1 actually tests)
 AWS is responsible for security OF the cloud: the hardware, the global
 infrastructure (Regions, AZs, edge locations), the hypervisor and the
 software of managed services. The customer is responsible for security IN
 the cloud: guest OS and patching on EC2, network and firewall configuration,
 IAM principals and policies, client- and server-side encryption choices,
 and the data itself, always. Some controls are shared (patch management,
 configuration management, awareness and training), and the boundary moves
 with the service model — never with the vendor. Four failures in this lab,
 four customer-side root causes, zero AWS-side actions available. That ratio
 is the point.

 SOURCES
  - CLF-C02 exam guide:
    https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
  - https://aws.amazon.com/compliance/shared-responsibility-model/
  - https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-security-groups.html
  - https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html
  - https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html
  - https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html
  - https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html
  - https://docs.aws.amazon.com/AmazonS3/latest/userguide/serv-side-encryption.html
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/aws-clf/2.1/lab)
