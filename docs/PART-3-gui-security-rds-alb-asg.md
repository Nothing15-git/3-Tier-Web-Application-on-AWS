# Part 3: Security Groups, IAM, SSM, RDS, Secrets Manager, ALB, ASG

This part finishes the GUI build. We add security groups, the EC2 IAM role, SSM access, RDS Multi-AZ, Secrets Manager, the ALB, the Launch Template, and the Auto Scaling Group. By the end you'll have a working 3-tier app hitting a real database.

---

## Step 1 — Create security groups (4 of them)

**Why separate SGs:** A security group (SG) is a stateful firewall on instances or load balancers. Best practice is one SG per role so you can apply least-privilege rules independently. If you put app and DB on the same SG and later open port 80 to the world, the DB is also exposed.

**Console path:** EC2 → left menu → **Security Groups** (under **Network & Security**) → top-right **Create security group**.

### 1a. ALB security group — `sg-alb`
- **Security group name:** `sg-alb`
- **Description:** `Allow HTTP/HTTPS from internet to ALB`
- **VPC:** `ha3tier-vpc`
- **Inbound rules:**
  - **Add rule** → Type: `HTTP` → Port: `80` → Source: `Custom 0.0.0.0/0` (we redirect 80 → 443 later, but ALB needs to accept 80 to do the redirect)
  - **Add rule** → Type: `HTTPS` → Port: `443` → Source: `Custom 0.0.0.0/0`
- **Outbound rules:** leave default (All traffic, 0.0.0.0/0). The ALB must be able to reach the EC2 instances in private subnets.
- Click **Create security group**.

**Verify:** New SG `sg-alb` appears with 2 inbound rules, VPC = `ha3tier-vpc`.

### 1b. App/EC2 security group — `sg-app`
- **Name:** `sg-app`
- **Description:** `Allow HTTP from ALB only; allow SSM outbound`
- **VPC:** `ha3tier-vpc`
- **Inbound rules:**
  - **Add rule** → Type: `HTTP` → Port: `80` → Source: **Custom** → select `sg-alb` (this is the magic — instead of an IP, you reference another SG)
- **Outbound rules:**
  - Leave `All traffic` to `0.0.0.0/0` for now (we'll tighten later)
- Click **Create security group**.

**Why source = sg-alb:** When the ALB sends traffic to the EC2, the source IP is the ALB's private IP, which is dynamic. By saying "any traffic from instances that have `sg-alb` attached", you don't need to know the IP. This is the AWS-native way to chain SGs.

### 1c. DB security group — `sg-db`
- **Name:** `sg-db`
- **Description:** `Allow MySQL from app tier only`
- **VPC:** `ha3tier-vpc`
- **Inbound rules:**
  - **Add rule** → Type: `MYSQL/Aurora` → Port: `3306` → Source: **Custom** → select `sg-app`
- **Outbound rules:** default (All traffic)
- Click **Create security group**.

### 1d. Bastion / SSM-only security group — `sg-bastion` (optional)
You can skip this — we're using SSM Session Manager, not SSH bastion. Listed here for completeness in case you want SSH access later.

---

## Step 2 — Create the IAM role for EC2

**Why:** EC2 instances need a role to call AWS APIs: SSM for Session Manager, CloudWatch for logs/metrics, Secrets Manager for DB credentials. Without this role, the user data script can't fetch the DB password.

**Console path:** IAM → left menu → **Roles** → top-right **Create role**.

1. **Trusted entity type:** `AWS service`
2. **Use case:** `EC2` → click **Next**.
3. **Permissions policies** — search and check these AWS-managed policies:
   - `AmazonSSMManagedInstanceCore` (required for SSM Session Manager)
   - `CloudWatchAgentServerPolicy` (for CloudWatch Agent — push custom metrics and logs)
   - `SecretsManagerReadWrite` (or use a tighter custom policy — see below)
4. **Next**.
5. **Role name:** `ha3tier-ec2-role`
6. **Next** → **Create role**.

### Tighter Secrets Manager policy (recommended)

The `SecretsManagerReadWrite` policy is too broad. Replace it with a least-privilege custom policy.

1. IAM → **Policies** → **Create policy** → **JSON** tab.
2. Paste:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
         "Resource": "arn:aws:secretsmanager:us-east-1:<YOUR_ACCOUNT_ID>:secret:ha3tier/db/*"
       }
     ]
   }
   ```
   Replace `<YOUR_ACCOUNT_ID>` with your 12-digit AWS account ID (top-right menu → click your username → copy Account ID).
3. **Next** → Name: `ha3tier-ec2-secrets-read` → **Create policy**.
4. Go back to **Roles** → `ha3tier-ec2-role` → **Permissions** → **Add permissions** → **Attach policies** → check `ha3tier-ec2-secrets-read` and detach `SecretsManagerReadWrite` (or just leave both — for the sandbox, leaving is fine).

**Verify:** Role exists. Trusted entity = `ec2.amazonaws.com`. Has 3-4 policies attached.

---

## Step 3 — Enable SSM Session Manager access

**Why:** SSM Manager needs the SSM agent (preinstalled on Amazon Linux 2/2023) and the instance needs the role from Step 2 + an outbound route to SSM endpoints. The NAT Gateway from Part 2 handles that.

**No console action needed for the basic path**, but verify:

1. EC2 → left menu → **Session Manager** (under **Systems Manager** section, or search `Session Manager` in the top bar).
2. You should see "Session Manager is configured" message.

If you see "Session Manager is not configured", open Systems Manager → **Quick Setup** → **Enable** for "EC2 Session Manager" → it creates the necessary service-linked roles.

**Verify:** You can open the Session Manager page without errors. After Part 4 when instances launch, you'll connect here.

---

## Step 4 — Create the DB credentials in Secrets Manager

**Why:** The app code will read the DB password from Secrets Manager on boot. We pre-create the secret so the user data script can fetch it.

**Console path:** Secrets Manager → top-right **Store a new secret**.

1. **Secret type:** `Credentials for RDS database`
2. **User name:** `admin`
3. **Password:** click **Generate password** → **Generate** → **copy and save this password** (you won't see it again; or use a known one for testing)
4. **Database:** select `ha3tier-db` (we'll create it next) — but Secrets Manager lets you create the secret before the DB exists. Skip this field for now if it's required and we're creating the DB in a minute.
5. **Encryption key:** leave default (`aws/secretsmanager`).
6. **Next** → Secret name: `ha3tier/db/master` → **Next** → **Disable automatic rotation** for now (saves complexity) → **Next** → **Store**.

**Verify:** Secret `ha3tier/db/master` appears. Click it → **Retrieve secret value** → you see the password.

If the password-generation warning worried you: click the secret → **Actions** → **Rotate secret** → generate a new one any time.

---

## Step 5 — Create the DB subnet group

**Why:** RDS asks "which subnets can I put a database in?" The DB subnet group is the answer. We use both DB subnets across 2 AZs.

**Console path:** RDS → left menu → **Subnet groups** → top-right **Create DB subnet group**.

1. **Name:** `ha3tier-db-subnet-group`
2. **Description:** `DB subnets across 2 AZs`
3. **VPC:** `ha3tier-vpc`
4. **Add subnets:**
   - **AZ:** `us-east-1a` → select `ha3tier-db-a` (10.0.20.0/24)
   - **AZ:** `us-east-1b` → select `ha3tier-db-b` (10.0.21.0/24)
5. **Create**.

**Verify:** Subnet group has 2 subnets, one per AZ.

---

## Step 6 — Create the RDS parameter group (optional, default works)

For MySQL 8 default, you can skip this. For PostgreSQL, you might want to set `log_statement = all` for debugging. For this project, defaults are fine.

---

## Step 7 — Create the RDS Multi-AZ database

**Why Multi-AZ:** RDS automatically provisions a synchronous standby in another AZ. If the primary fails, RDS promotes the standby and flips the endpoint DNS — usually in 60-120 seconds. Your app reconnects without code changes.

**Console path:** RDS → left menu → **Databases** → top-right **Create database**.

### 7a. Engine options
- **Choose a database creation method:** `Standard create`
- **Engine type:** `MySQL` (or `PostgreSQL` if you prefer — adjust SG port and sample app code)
- **Engine version:** latest MySQL 8.x (default)
- **Templates:** `Dev/Test` (cheaper than Production)

### 7b. Settings
- **DB instance identifier:** `ha3tier-db`
- **Master username:** `admin`
- **Master password:** **Manage in Secrets Manager** → select the secret `ha3tier/db/master` (this avoids the password being shown in plaintext in the console)

### 7c. Instance configuration
- **DB instance class:** `Burstable classes` → `db.t3.micro` (free tier eligible for first 12 months, single-AZ only — Multi-AZ is NOT free)
- **Storage type:** `gp3`
- **Allocated storage:** `20` GiB
- **Storage autoscaling:** leave enabled with max 100 GiB

### 7d. Availability & durability
- **Multi-AZ deployment:** `Yes` (this is the whole point of the project)

### 7e. Connectivity
- **VPC:** `ha3tier-vpc`
- **DB subnet group:** `ha3tier-db-subnet-group`
- **Public access:** `No` (database must never be public)
- **VPC security group:** choose existing → `sg-db`
- **Availability Zone:** `No preference` (let RDS pick — it'll use db-a as primary, db-b as standby)
- **Database port:** `3306`

### 7f. Database authentication
- **Password authentication** (Secrets Manager handles the rest)

### 7g. Additional configuration
- **Initial database name:** `appdb` (so we have a database to connect to)
- **Backup retention period:** `7 days`
- **Backup window:** `No preference`
- **Monitoring:** leave Performance Insights enabled (free tier covers it)
- **Log exports:** enable `audit` and `error` (optional, costs a bit)
- **Maintenance window:** `No preference`
- **Deletion protection:** `Enable` (prevents accidental deletion — remember to disable before cleanup)

### 7h. Estimated monthly costs
The panel will show ~$50/month. That's correct for Multi-AZ t3.micro.

Click **Create database**.

**Verify:** Status = `Creating` → wait 5-10 minutes → status = `Available`. The endpoint will look like `ha3tier-db.xxxx.us-east-1.rds.amazonaws.com` on port 3306. Copy this endpoint — you'll need it in the user data script.

---

## Step 8 — Test the database connection (optional but wise)

Launch a temporary EC2 in `ha3tier-app-a` (no public IP) with `sg-app` attached and the IAM role from Step 2. Use SSM Session Manager to log in (no SSH needed). Then:

```bash
sudo yum install -y mariadb105    # or `psql` for PostgreSQL
mysql -h ha3tier-db.xxxx.us-east-1.rds.amazonaws.com -u admin -p
# enter password from Secrets Manager
SHOW DATABASES;
```

You should see `appdb` and the system databases. If connection times out, check the SG — the source must be `sg-app` (the SG attached to the EC2).

**Terminate the test instance** when done.

---

## Step 9 — Request a TLS certificate in ACM

**Why:** The ALB and CloudFront need a certificate to terminate HTTPS. ACM gives you a free one.

**Console path:** Certificate Manager → left menu → **Certificates** → top-right **Request a certificate**.

1. **Certificate type:** `Request a public certificate`
2. **Next**.
3. **Domain names:** add your domain. For a real domain: `app.tayyab.dev` (and a wildcard `*.tayyab.dev` if you want). For sandbox testing without a domain: skip this step and use the ALB's default DNS name over HTTP (still works, no HTTPS). I'll assume you have a domain.
4. **Validation method:** `DNS validation` (recommended — Route 53 makes it one-click)
5. **Key algorithm:** `RSA 2048`
6. **Next** → add tags if you want → **Request**.

For each domain, ACM gives you a CNAME record. If your domain is in Route 53, click **Create records in Route 53** button — done. If your domain is elsewhere, copy the CNAME to your DNS provider.

**Verify:** Status = `Pending validation` → wait 5-30 minutes → status = `Issued`. If you used Route 53, it's usually under 5 minutes.

---

## Step 10 — Create the Application Load Balancer (ALB)

**Why:** The ALB terminates HTTPS, runs health checks, and distributes requests across the EC2 instances in both AZs.

**Console path:** EC2 → left menu → **Load Balancers** (under **Network & Load Balancing**) → top-right **Create load balancer** → **Application Load Balancer** → **Create**.

### 10a. Basic configuration
- **Name:** `ha3tier-alb`
- **Scheme:** `Internet-facing`
- **IP address type:** `IPv4`

### 10b. Network mapping
- **VPC:** `ha3tier-vpc`
- **Mappings:** check BOTH `us-east-1a` (public-a) and `us-east-1b` (public-b)

### 10c. Security groups
- Select existing → `sg-alb`

### 10d. Listeners and routing
We'll come back to this — for now, create a default action that forwards to a placeholder target group.
- **Protocol:** `HTTPS` → **Port:** `443`
- **Default action:** we'll create the target group next, then come back
- **Certificate:** select from ACM → choose your issued cert
- **Security policy:** `ELBSecurityPolicy-TLS13-1-2-2021-06` (most modern)
- **Add another listener:** HTTP on port 80 → action: **Redirect to HTTPS** → choose `443`

### 10e. Create the target group first (then return to the ALB)

**Console path:** EC2 → left menu → **Target Groups** → top-right **Create target group**.

- **Target type:** `Instances`
- **Name:** `tg-app`
- **Protocol:** `HTTP` → **Port:** `80`
- **VPC:** `ha3tier-vpc`
- **Health check path:** `/health` (we'll add this endpoint in the app)
- **Health check interval:** `30 seconds`
- **Healthy threshold:** `2`
- **Unhealthy threshold:** `3`
- Click **Next** → **Do not register targets** (the ASG will register them) → **Create target group**.

Now go back to the ALB wizard → **Listener** for HTTPS → **Forward to** `tg-app`.

Click **Create load balancer**. State goes `Provisioning` → `Active` (~1 minute).

**Verify:**
- ALB state = `Active`
- ALB has a DNS name like `ha3tier-alb-1234567890.us-east-1.elb.amazonaws.com`
- Visit it in browser — you should get a 503 (no targets yet) — that confirms the ALB is up

---

## Step 11 — Create the Launch Template

**Why:** A Launch Template is the EC2 blueprint the ASG uses to launch identical instances. It includes the AMI, instance type, SG, IAM role, and user data script.

**Console path:** EC2 → left menu → **Launch Templates** (under **Instances**) → top-right **Create launch template**.

1. **Name:** `lt-app`
2. **Version description:** `v1`
3. **AMI:** `Amazon Linux 2023` (search "al2023-ami-2023.*-x86_64")
4. **Instance type:** `t3.micro`
5. **Key pair:** `Proceed without a key pair` (we use SSM)
6. **Security group:** select existing → `sg-app`
7. **Advanced details:**
   - **IAM instance profile:** `ha3tier-ec2-role`
   - **Purchasing option:** leave off
8. **Advanced → Network:** leave (we set in ASG)
9. **User data:** paste the script from below (Part 4 will have the full version)
10. **Tag:** Key `Project` → Value `ha3tier`
11. Click **Create launch template**.

**Verify:** Launch template `lt-app` exists, version 1.

---

## Step 12 — Create the Auto Scaling Group (ASG)

**Why:** The ASG keeps N healthy instances running, replaces unhealthy ones, and can scale up/down on metrics like CPU.

**Console path:** EC2 → left menu → **Auto Scaling Groups** → top-right **Create Auto Scaling group**.

### 12a. Name and template
- **Name:** `asg-app`
- **Launch template:** `lt-app` (latest version)
- Click **Next**.

### 12b. Network
- **VPC:** `ha3tier-vpc`
- **Subnets:** check `ha3tier-app-a` AND `ha3tier-app-b`
- Click **Next**.

### 12c. Load balancing
- **Attach to an existing load balancer** → **Choose from your load balancer target groups** → select `tg-app`
- **Health check type:** `ELB` (uses the ALB's health check, not just EC2 status checks — much better)
- **Health check grace period:** `300` seconds (give the app 5 min to boot and start responding)
- Click **Next**.

### 12d. Group size and scaling
- **Desired capacity:** `2`
- **Minimum capacity:** `2`
- **Maximum capacity:** `4`
- **Scaling policies:** choose `Target tracking scaling policy`
  - **Metric type:** `Average CPU utilization`
  - **Target value:** `50` (scale up when average CPU > 50%)
  - This gives you automatic scale-out for the load test
- Click **Next**.

### 12e. Notifications (optional)
- Skip for now; we'll do SNS in Part 5.
- Click **Next**.

### 12f. Tags
- Key `Project` → Value `ha3tier`
- Click **Next** → **Create Auto Scaling group**.

**Verify:** ASG state → desired = 2 → launches 2 instances. After 2-5 minutes, instances are `InService` in the target group, ALB health checks pass, the ALB DNS name returns a 200 OK on `/health`.

---

## What you have after Part 3

- 4 security groups with least-privilege rules
- IAM role `ha3tier-ec2-role` with SSM, CloudWatch, and Secrets Manager access
- SSM Session Manager enabled
- Secret `ha3tier/db/master` in Secrets Manager
- DB subnet group covering both AZs
- RDS Multi-AZ MySQL `ha3tier-db` with endpoint ready
- ACM TLS certificate issued
- ALB `ha3tier-alb` with HTTPS + HTTP→HTTPS redirect, attached to target group `tg-app`
- Launch template `lt-app` with IAM role and user data placeholder
- ASG `asg-app` with 2 desired / 2 min / 4 max, target tracking on CPU, attached to ALB target group

**Your bill is now ~$130/month** (NAT $64 + ALB $16 + RDS Multi-AZ $50). Don't leave this on.

---

**Say "continue" for Part 4:** The sample Flask app, the user data script that installs/starts it, the full Terraform code (main.tf, variables.tf, outputs.tf) for the networking layer, plus the testing & troubleshooting guide. Then Part 5 (CloudFront, Route 53, CloudWatch, SNS, dashboards) and Part 6 (cleanup).
