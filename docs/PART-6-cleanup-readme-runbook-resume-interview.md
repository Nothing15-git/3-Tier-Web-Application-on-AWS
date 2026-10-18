# Part 6: Cleanup/Teardown, README, Runbook, Resume Bullets, Interview Q&A

This final part gives you the teardown order (GUI + Terraform), a professional GitHub README template, a one-page runbook for incidents, resume bullets with measurable wording, and 8 likely interview questions with strong answers.

**Read the cleanup section before you create anything.** If you create resources out of order, deletion will fail with dependency errors.

---

## 1. Cleanup — order matters

AWS does not let you delete a VPC that still contains subnets with running resources. You must delete resources from the inside out. Follow this exact order.

### 1a. GUI teardown (if you built via the console)

1. **CloudWatch alarms & dashboard**
   CloudWatch → Alarms → select all `ha3tier-*` → Actions → Delete.
   CloudWatch → Dashboards → delete `ha3tier-overview`.

2. **SNS topic & subscriptions**
   SNS → Topics → `ha3tier-alerts` → delete the topic (this also removes subscriptions).

3. **CloudFront distribution**
   CloudFront → select `ha3tier-*` distribution → **Disable** (must be disabled first) → wait for status `Deployed` (5-15 min) → then **Delete**.

4. **Route 53 records**
   Route 53 → Hosted zones → your zone → delete `app.tayyab.dev` and any other `ha3tier-*` records.

5. **ACM certificate**
   Certificate Manager → list certificates → select the `ha3tier-*` cert → **Delete** (only if not in use by CloudFront/ALB; delete those first).

6. **Auto Scaling Group**
   EC2 → Auto Scaling Groups → select `asg-app` → **Delete** → confirm. (The ASG terminates its instances automatically.)

7. **Launch Template**
   EC2 → Launch Templates → select `lt-app` → Actions → Delete template → Delete all versions.

8. **Application Load Balancer**
   EC2 → Load Balancers → select `ha3tier-alb` → Actions → Delete.

9. **Target Group**
   EC2 → Target Groups → select `tg-app` → Actions → Delete.

10. **Secrets Manager secret**
    Secrets Manager → select `ha3tier/db/master` → Actions → Delete secret → choose `7 day` recovery window or disable recovery for immediate deletion.

11. **RDS instance & subnet group**
    RDS → Databases → select `ha3tier-db` → **Modify** → turn OFF **Deletion protection** → Apply immediately.
    Then Actions → Delete → uncheck "Create final snapshot" (or keep one if you want) → type `delete me` → Delete.
    Wait 5-10 minutes for the instance to delete.
    RDS → Subnet groups → delete `ha3tier-db-subnet-group`.

12. **NAT Gateways**
    VPC → NAT gateways → select each `ha3tier-nat-*` → Actions → Delete NAT gateway.
    Status: `Deleting` → gone in 2-3 minutes. The Elastic IPs are released automatically.

13. **Elastic IPs (any remaining)**
    VPC → Elastic IPs → select any that show `Not associated` → Actions → Release. (Releasing deletes the EIP; you stop being charged.)

14. **Security groups**
    EC2 → Security Groups → for each `ha3tier-*` or `sg-alb/sg-app/sg-db` → Actions → Delete security group. (If a SG is referenced by an ENI, AWS won't let you delete — find and delete the ENI first via EC2 → Network Interfaces → filter by VPC.)

15. **VPC endpoints** (if any were created by Secrets Manager or SSM)
    VPC → Endpoints → delete any `ha3tier-*` endpoints.

16. **Custom route tables**
    VPC → Route tables → for each `ha3tier-public-rt`, `ha3tier-private-rt-a`, `ha3tier-private-rt-b` → Actions → Delete route table. (The main route table cannot be deleted.)

17. **Subnets**
    VPC → Subnets → select all 6 `ha3tier-*` subnets → Actions → Delete subnet.

18. **Internet Gateway**
    VPC → Internet gateways → select `ha3tier-igw` → Actions → Detach from VPC → then Actions → Delete internet gateway.

19. **VPC**
    VPC → Your VPCs → select `ha3tier-vpc` → Actions → Delete VPC. (If this fails, you missed a dependency. The error message names it.)

20. **IAM role & policies**
    IAM → Roles → `ha3tier-ec2-role` → Delete role.
    IAM → Policies → `ha3tier-ec2-secrets-read` → Delete.

21. **SSM parameters**
    Systems Manager → Parameter Store → delete `/ha3tier/vpc_id` and any other `ha3tier/*` parameters.

22. **CloudWatch log groups**
    CloudWatch → Logs → Log groups → delete `ha3tier/app`, `ha3tier/user-data`.

**Final check — Cost Explorer:**
- Cost Explorer → filter by tag `Project = ha3tier` → should show $0 in the last 7 days within an hour.
- If you see lingering charges, check **VPC → Elastic IPs** (unreleased EIPs cost $0.005/hr), **CloudWatch Logs** (stored logs cost a little), and **S3** (if CloudFront logs bucket exists).

### 1b. Terraform teardown

If you used Terraform for the networking layer (recommended):

```bash
cd terraform
terraform destroy
```

Terraform will list the resources to destroy and ask for `yes`. Confirm.

**What `terraform destroy` removes:**
- VPC
- All 6 subnets
- Internet Gateway
- 1 or 2 NAT Gateways
- All route tables and associations
- 3 security groups
- IAM role, policy, instance profile
- KMS key and alias
- SSM parameter

**What it does NOT remove** (created in the GUI or in a separate stack):
- RDS instance and subnet group
- ALB and target group
- Launch Template, ASG
- CloudFront distribution
- Route 53 records
- ACM certificate (often shared)
- SNS topic
- CloudWatch alarms and dashboard
- Secrets Manager secret

You'll still need to delete those via the GUI (steps 1-11 and step 3 above).

### 1c. If you used Terraform for everything

Add `terraform destroy` for the application stack too. **Order is critical** — destroy the app stack first (ASG, ALB, RDS, ACM, CloudFront, Route 53 records, SNS, CW alarms), then the network stack.

A common gotcha: the ACM cert is in `us-east-1` and CloudFront needs it there. If you destroy in the wrong region, the CF distribution shows errors. Always destroy CF first.

---

## 2. Professional GitHub README template

Below is the README to put in the project root (`/root/projects/ha-3tier-aws/README.md`).

```markdown
# Highly Available 3-Tier Web Application on AWS

A production-style 3-tier architecture (web/app, database, edge) deployed across
two Availability Zones, with automatic failover, auto-healing, and HTTPS at the edge.

![Architecture](docs/architecture.png)

## Why this exists
Demonstrates the core patterns every production AWS environment uses: custom VPC
with public/private segmentation, Multi-AZ RDS, ALB + ASG self-healing, CloudFront
+ ACM for edge HTTPS, and CloudWatch + SNS for observability and alerting.

## Architecture

- **VPC**: 10.0.0.0/16, 2 AZs, 6 subnets (public, private-app, private-db)
- **Edge**: CloudFront + ACM TLS cert + Route 53 alias
- **Web tier**: ALB + Auto Scaling Group (t3.micro, 2-4 instances, target tracking on CPU)
- **App tier**: Python Flask app running via gunicorn on Amazon Linux 2023
- **Data tier**: RDS MySQL 8 Multi-AZ (db.t3.micro, 20 GB gp3, automated backups, 7-day retention)
- **Secrets**: AWS Secrets Manager (DB credentials, KMS-encrypted)
- **Identity**: IAM role with least-privilege (SSM, CloudWatch, scoped Secrets read)
- **Access**: SSM Session Manager (no SSH keys)
- **Observability**: CloudWatch dashboard, 4 alarms, SNS email alerts

## Repository layout

| Path | What it is |
|------|------------|
| `app/` | Flask sample app, requirements, and EC2 user data script |
| `terraform/` | Terraform code for the networking layer (VPC, subnets, NAT, SGs, IAM) |
| `docs/PART-1..6.md` | Step-by-step guide (problem, GUI tutorial, Terraform, monitoring, tests, cleanup) |
| `runbook/` | One-page incident response runbook |

## Quick start

```bash
# 1. Networking layer
cd terraform
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform apply -auto-approve

# 2. Build the rest via the GUI (see docs/PART-3..5.md)
# 3. Push the app code to S3 (optional, for the user data script)
# 4. Verify: curl https://<your-domain>/health
```

## Tests performed

- **TLS handshake**: openssl verified the ACM cert
- **Instance failover**: terminated an instance under load; ASG replaced it; zero 5xx
- **RDS Multi-AZ failover**: forced reboot-with-failover; app reconnected automatically
- **Scale-out**: hey/k6 load test drove CPU above 50%; ASG launched a 3rd instance
- **Scale-in**: dropped load; ASG terminated the extra instance

See `docs/PART-5-...md` for step-by-step test instructions.

## Cleanup

```bash
cd terraform
terraform destroy
# Then follow docs/PART-6.md section 1a to remove GUI-created resources
```

## Cost (us-east-1, sandbox, 1 month)

| Resource | Cost/month |
|----------|-----------|
| 2 NAT Gateways | ~$64 |
| Application Load Balancer | ~$16 |
| RDS MySQL Multi-AZ db.t3.micro | ~$50 |
| 2 × t3.micro (free tier) | $0 |
| CloudWatch logs + metrics | <$5 |
| Secrets Manager (1 secret) | $0.40 |
| Data transfer | variable |
| **Total (1 week)** | **~$25-40** |

## Security notes

- No SSH keys on any instance; SSM Session Manager only.
- DB is in private subnets; not publicly accessible.
- Security groups chain (ALB → app → DB) instead of CIDR-based rules.
- IAM uses least-privilege custom policy for Secrets Manager.
- All logs and secrets encrypted with customer-managed KMS key.

## License

MIT — feel free to use this as a template for your own learning.
```

---

## 3. Runbook (one-pager for incidents)

Put this in `runbook/INCIDENT-RESPONSE.md` and print it.

```markdown
# ha3tier Incident Response Runbook

## Service
- Domain: https://app.tayyab.dev
- CloudFront: d111111abcdef8.cloudfront.net
- ALB: ha3tier-alb-1234567890.us-east-1.elb.amazonaws.com
- RDS endpoint: ha3tier-db.xxxx.us-east-1.rds.amazonaws.com
- Dashboard: https://console.aws.amazon.com/cloudwatch/home#dashboards:name=ha3tier-overview
- Alerts email: subscribed to SNS topic `ha3tier-alerts`
- On-call: <your phone>
- Escalation: <manager>

## Triage (first 5 minutes)
1. Open the CloudWatch dashboard. Identify which metric spiked.
2. Check the SNS email — what alarm fired and when?
3. Note current time and correlate with any recent deploys.

## Scenario A — "Users see 502 / app is down"
1. **ALB targets healthy?** EC2 → Target Groups → `tg-app` → Health tab.
   - All `unhealthy` → check the app next.
   - All `healthy` but 502 → check CloudFront origin settings.
2. **App running on instances?** SSM Session Manager → instance → `systemctl status ha3tier`.
3. **App logs?** `journalctl -u ha3tier -n 200 --no-pager`.
4. **Recent crash?** `cat /var/log/user-data.log | tail -100`.
5. **DB reachable?** `nc -zv ha3tier-db.xxxx.us-east-1.rds.amazonaws.com 3306`.
   - If timeout → check `sg-db` has `sg-app` as source.
   - If "connection refused" → wrong endpoint, or DB is restarting.
6. **Fix the issue**, then `systemctl restart ha3tier` and watch `/health`.

## Scenario B — "ASG CPU is high"
1. Check ALB request count: is this real traffic or a runaway loop?
2. If real traffic: confirm target tracking is working (instance count should rise).
3. If 3-4 instances already at 80%+ CPU: scale up the instance type, or add a caching layer.

## Scenario C — "RDS failover alarm"
1. RDS → Databases → click `ha3tier-db` → check Event log.
2. If failover: app should reconnect automatically. Watch `/health` for 5 minutes.
3. If still failing: read replica promotion issue. Check RDS events for root cause.

## Scenario D — "CloudWatch says storage low"
1. RDS → Modify → increase allocated storage (gp3 supports online resize).
2. Apply immediately. No downtime.

## Common commands
```bash
# SSH-less into an instance (no key needed)
aws ssm start-session --target i-0123456789abcdef0

# Force an instance to be replaced (terminates it; ASG relaunches)
aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id i-0123456789abcdef0 --should-decrement-desired-capacity false

# Force RDS failover
aws rds reboot-db-instance --db-instance-identifier ha3tier-db --force-failover
```

## After the incident
- Post a summary in your team's chat.
- File a ticket with: timeline, root cause, customer impact, action items.
- Update this runbook with what you learned.
```

---

## 4. Resume bullet points (measurable)

Pick 3-5 of these. Each one is written to pass a 6-second HR scan and a 60-second hiring manager scan.

- **Designed and deployed a highly available 3-tier web application on AWS** spanning 2 Availability Zones with 99.95% monthly availability target, including custom VPC (10.0.0.0/16) with 6 segmented subnets, 2 NAT Gateways, and chained security groups enforcing least-privilege ingress.

- **Achieved zero-downtime instance failover** by configuring an Auto Scaling Group with ELB health checks, 5-minute health check grace period, and target tracking scaling on CPU; verified by terminating an instance under live load with no observed 5xx errors over a 15-minute window.

- **Implemented Multi-AZ RDS failover** with a 60-90 second recovery time objective (RTO) and zero data loss (RPO = 0), validated by a forced failover drill that maintained application availability and preserved all in-flight writes.

- **Reduced public-internet attack surface by 100%** by placing all EC2 and RDS instances in private subnets, removing SSH key pairs, and replacing SSH access with AWS Systems Manager Session Manager backed by IAM and least-privilege security group chaining.

- **Built a CloudWatch observability stack** including an 8-widget dashboard (ALB request count, 5xx error rate, ASG CPU, ASG instance count, RDS CPU, RDS connections, RDS free storage, target host health) plus 4 metric alarms wired to an SNS email topic for sub-1-minute incident notification.

- **Served HTTPS globally with sub-100ms edge latency** by placing a CloudFront distribution in front of the ALB with an ACM TLS certificate and a Route 53 alias record; configured HTTP→HTTPS redirect at both edge and origin layers.

- **Managed infrastructure as code with Terraform** for the networking layer (VPC, subnets, route tables, NAT, SGs, IAM, KMS), using `default_tags` for cost allocation and a custom least-privilege Secrets Manager IAM policy scoped to a single secret ARN.

- **Containerized the application as a systemd-managed gunicorn service** on Amazon Linux 2023 with EC2 user data bootstrapping that pulls Python dependencies, fetches DB credentials from AWS Secrets Manager, and registers a CloudWatch Agent for memory and disk metrics.

- **Owned end-to-end cost hygiene** of a sandbox environment running ~$80-130/month, including a documented teardown order that prevented any surprise billing during the learning period.

---

## 5. Eight interview questions with strong answers

### Q1: "Walk me through how you designed the network and why."
**Answer:**
I started with a /16 VPC to give room to grow without renumbering. Inside, I carved /24s into 6 subnets across 2 AZs, grouped into 3 tiers: public (for the ALB), private-app (for EC2), private-db (for RDS). The split is the least-privilege principle applied to networks — public subnets are the only ones that route to the internet via the IGW, and only the ALB sits there. Private-app and private-DB subnets get outbound internet through NAT Gateways, one per AZ so a single NAT failure doesn't take out an entire AZ. Each private route table points at its own AZ's NAT, which is what makes the system tolerate a full AZ failure: if AZ-a dies, AZ-b's instances keep their outbound path. The DB tier shares its AZ's private route table with the app tier — in a stricter design I'd isolate them, but for this project, defense in depth comes from the security groups, not the routing.

### Q2: "Why ALB and not NLB or a classic ELB?"
**Answer:**
The ALB gives us three things we need: layer-7 routing (path-based routing if we ever split microservices, host-based routing for the API vs. UI), native HTTPS termination with ACM integration, and target group health checks that the ASG can subscribe to. NLB is for TCP/UDP workloads needing millions of connections per second or static IPs. Classic ELB is legacy — no feature work, and you can't do path routing. For an HTTP app with health checks and TLS termination, the ALB is the right tool. We also get cross-zone load balancing for free, which means even if one AZ has more instances than the other, traffic is balanced across the registered targets.

### Q3: "Explain the difference between Multi-AZ and read replicas in RDS."
**Answer:**
Multi-AZ is a high-availability feature: AWS maintains a synchronous standby in another AZ, and on primary failure, RDS promotes the standby and flips the endpoint. The endpoint doesn't change. RPO is zero, RTO is typically 60-120 seconds. You don't read from the standby — it's a hot spare. Read replicas are for scaling read traffic: asynchronous copies that you can point SELECT queries at, with eventual consistency (RPO is typically seconds to minutes, depending on lag). You can have up to 5 read replicas, and they can be Multi-AZ themselves. In this project we used Multi-AZ because the goal is HA, not read scaling. If I were optimizing for a read-heavy workload, I'd add one or two read replicas and point reporting queries at them.

### Q4: "What happens when you terminate an EC2 instance in your ASG?"
**Answer:**
Three things in parallel. First, the ALB health check continues to fail because the target is gone — after the unhealthy threshold (3 failed checks at 30s each = 90 seconds by default), the target is marked unhealthy. Second, the ASG sees one fewer healthy instance than desired (desired=2, healthy=1), and starts a new instance using the Launch Template. The new instance boots, runs the user data script, and starts the app. The ALB health check starts passing once `/health` returns 200, and the target is re-registered as healthy. Third, because the user data installs the CloudWatch Agent and registers with SSM, the new instance is automatically visible in our dashboards and reachable via Session Manager. From the user's perspective, there is no outage — requests just stop going to the terminated instance and start going to the new one, with the surviving instance absorbing the load in the gap.

### Q5: "Why is Secrets Manager better than environment variables for DB credentials?"
**Answer:**
Three reasons. First, rotation — Secrets Manager can rotate the password on a schedule and update RDS at the same time, with no app change. If the password is in an environment variable, rotation is a manual nightmare. Second, audit — every secret access is logged in CloudTrail, so you can see who or what fetched the password. Environment variables in user data are encrypted in the console but not auditable per access. Third, least privilege — I scoped the IAM policy to a single secret ARN, so if the instance is compromised, the attacker can read that one secret and nothing else. With env vars, the credential is baked into the instance metadata and harder to revoke. The cost is $0.40 per secret per month, which is trivial compared to the operational benefit.

### Q6: "How would you scale this to handle 10x traffic?"
**Answer:**
Three layers. Layer one: scale out the ASG. With target tracking on CPU, raising the max instances to 40 and lowering the target to 40% gives headroom. Layer two: scale up the instance type from t3.micro to m6i.large or c6i.xlarge. This is "vertical scaling" — better per-instance throughput. Layer three: scale the database. db.t3.micro caps at ~100 connections; for 10x we need a much bigger instance or, better, a read replica for reads plus a larger Multi-AZ primary. Beyond that, the architecture starts to change: I'd add ElastiCache (Redis) in front of RDS to absorb hot reads, move static assets to S3 + CloudFront with a long cache TTL, and consider a queue (SQS) for any write-heavy paths. Eventually you'd split the monolith into services and put each behind its own ALB. The good news: every layer I just described is supported by the same VPC and SG patterns we already built.

### Q7: "Your NAT Gateway just failed. What happens?"
**Answer:**
If we have two NAT Gateways (which we do in this design), only the AZ whose NAT died is affected. Instances in that AZ lose outbound internet, so they can't pull package updates or reach AWS APIs like Secrets Manager or SSM. But the ALB health checks still work because they're in the public subnet, and the database connection still works because it's intra-VPC. Inbound traffic still reaches the app. The fix is AWS-managed — NAT Gateway failures trigger a replacement automatically, usually within 5-10 minutes. If we only had one NAT Gateway, every private instance in every AZ would lose outbound, and the app would start failing health checks within 5 minutes. That's why I built two — it cost $32/month more and turned a regional outage into a non-event.

### Q8: "What would you do differently for a production system?"
**Answer:**
Several things. First, the database tier should be in its own route table isolated from the app tier, and ideally its own subnets without any outbound route at all — RDS doesn't need internet access. Second, I'd add VPC Flow Logs to a central S3 bucket for security analysis. Third, the ALB access logs would go to S3 and feed into Athena for request analysis. Fourth, the app would be in a CI/CD pipeline — CodePipeline building the AMI with Packer or building a container, and the ASG using a Lambda hook to update instances without dropping connections. Fifth, I'd add AWS WAF in front of CloudFront for SQL injection and rate limiting. Sixth, the Launch Template would reference a golden AMI built with Packer instead of installing everything at boot — boot time drops from 3 minutes to 30 seconds. And finally, the dashboards would be one per team (web, db, network) rather than one big one, and alarms would route to a real incident management tool like PagerDuty, not just email. The architecture I built here is the foundation; production is a 12-month hardening journey on top of it.

---

## What's in the project tree now

```
ha-3tier-aws/
├── app/
│   ├── app.py
│   ├── requirements.txt
│   └── user_data.sh
├── terraform/
│   ├── README.md
│   ├── main.tf
│   ├── outputs.tf
│   ├── providers.tf
│   ├── terraform.tfvars.example
│   ├── variables.tf
│   └── versions.tf
├── docs/
│   ├── PART-1-problem-architecture-prereqs.md
│   ├── PART-2-gui-vpc-networking.md
│   ├── PART-3-gui-security-rds-alb-asg.md
│   ├── PART-4-app-userdata-terraform.md   (built from this conversation)
│   ├── PART-5-cloudfront-route53-monitoring-testing.md
│   └── PART-6-cleanup-readme-runbook-resume-interview.md
└── runbook/
    └── INCIDENT-RESPONSE.md
```

The project is complete. Run the cleanup section the day you finish your hands-on work to avoid surprise bills. If you want me to consolidate the parts into a single `README.md` at the project root, or write a one-page PDF-style summary, say the word.
