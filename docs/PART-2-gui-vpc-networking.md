# Part 2: GUI Tutorial — VPC, Subnets, Route Tables, Gateways

Region assumption: **us-east-1**. If you use another region, substitute it everywhere. Every step is numbered, and you'll see a **Verify** block at the end of each step so you know you're on track before moving on.

---

## Step 1 — Create the VPC

**Why this matters:** A custom VPC is your own isolated network in AWS. Without it, you can't control routing, subnets, or have private subnets that protect your database.

**Console path:** AWS Console (top search bar) → type **VPC** → click **VPC** (the service, not "Your VPCs").

1. Left menu → **Your VPCs** → top-right **Create VPC**.
2. **Resources to create:** `VPC only`
3. **Name tag:** `ha3tier-vpc`
4. **IPv4 CIDR block:** `10.0.0.0/16`
5. **IPv6 CIDR block:** `No IPv6 CIDR block`
6. **Tenancy:** `Default`
7. **Tags:** click **Add new tag** → Key `Project` → Value `ha3tier` (this tag is critical — it lets you find every resource for cleanup later).
8. Click **Create VPC**.

**Verify:**
- Status shows `Available`
- CIDR shows `10.0.0.0/16`
- You see `ha3tier-vpc` in the list

If you don't see it, click the refresh icon (top right of the table). A common gotcha is being in the wrong region — check the top-right region selector and stay there for the whole project.

---

## Step 2 — Create the subnets (6 total)

**Why 6 subnets:** 2 AZs × 3 tiers (public, private-app, private-DB) = 6 subnets. Each tier has a different routing rule, so they need to be separate subnets.

**Why 2 AZs and not 3:** Multi-AZ typically means 2 in AWS docs. Using 2 is the minimum for HA and the cheapest. 3 is more resilient but doubles the NAT cost.

**Pick your AZs:** Before you create subnets, you need to know which two AZs your region offers. Most regions have at least three (e.g., `us-east-1a`, `us-east-1b`, `us-east-1c`). Pick any two, but **use the same two throughout this project**. This guide uses `us-east-1a` and `us-east-1b`.

**Console path:** VPC → left menu → **Subnets** → top-right **Create subnet**.

### 2a. Public subnet for ALB — AZ-a
- **VPC:** `ha3tier-vpc`
- **Subnet name:** `ha3tier-public-a`
- **Availability Zone:** `us-east-1a`
- **IPv4 CIDR block:** `10.0.1.0/24`
- Click **Create subnet**

### 2b. Public subnet for ALB — AZ-b
- **VPC:** `ha3tier-vpc`
- **Subnet name:** `ha3tier-public-b`
- **Availability Zone:** `us-east-1b`
- **IPv4 CIDR block:** `10.0.2.0/24`
- Click **Create subnet**

### 2c. Private-app subnet — AZ-a
- **VPC:** `ha3tier-vpc`
- **Subnet name:** `ha3tier-app-a`
- **Availability Zone:** `us-east-1a`
- **IPv4 CIDR block:** `10.0.10.0/24`

### 2d. Private-app subnet — AZ-b
- **VPC:** `ha3tier-vpc`
- **Subnet name:** `ha3tier-app-b`
- **Availability Zone:** `us-east-1b`
- **IPv4 CIDR block:** `10.0.11.0/24`

### 2e. Private-DB subnet — AZ-a
- **VPC:** `ha3tier-vpc`
- **Subnet name:** `ha3tier-db-a`
- **Availability Zone:** `us-east-1a`
- **IPv4 CIDR block:** `10.0.20.0/24`

### 2f. Private-DB subnet — AZ-b
- **VPC:** `ha3tier-vpc`
- **Subnet name:** `ha3tier-db-b`
- **Availability Zone:** `us-east-1b`
- **IPv4 CIDR block:** `10.0.21.0/24`

**Verify:** Subnets page shows 6 rows. Each row has the right CIDR, the right AZ, and a `Project = ha3tier` tag. The VPC column shows `ha3tier-vpc`.

### Why those CIDR blocks

| Subnet | CIDR | Hosts available | Purpose |
|--------|------|-----------------|---------|
| public-a | 10.0.1.0/24 | 251 | ALB node in AZ-a |
| public-b | 10.0.2.0/24 | 251 | ALB node in AZ-b |
| app-a | 10.0.10.0/24 | 251 | EC2 in AZ-a |
| app-b | 10.0.11.0/24 | 251 | EC2 in AZ-b |
| db-a | 10.0.20.0/24 | 251 | RDS primary in AZ-a |
| db-b | 10.0.21.0/24 | 251 | RDS standby in AZ-b |

The gaps (10.0.3-9, 10.0.12-19, 10.0.22-255) leave room to add more subnets later without renumbering. A /24 gives 251 usable IPs, which is plenty for any tier.

---

## Step 3 — Create the Internet Gateway (IGW)

**Why:** The IGW is the door between your VPC and the public internet. Without it, nothing in your public subnets can reach the internet, and the ALB cannot accept user traffic.

**Console path:** VPC → left menu → **Internet gateways** → top-right **Create internet gateway**.

1. **Name tag:** `ha3tier-igw`
2. Click **Create internet gateway**.
3. You'll see state `Detached`. Click **Attach to VPC** (button top right or in the success screen).
4. Select `ha3tier-vpc` → **Attach internet gateway**.

**Verify:** IGW state = `Attached`, VPC = `ha3tier-vpc`.

---

## Step 4 — Create the public route table and associate public subnets

**Why:** Public subnets need a route table that sends `0.0.0.0/0` (all traffic) to the IGW. The VPC comes with a "main" route table that has no internet route — we won't touch that. We'll create a new one and associate it with the public subnets only.

**Console path:** VPC → left menu → **Route tables** → top-right **Create route table**.

1. **Name:** `ha3tier-public-rt`
2. **VPC:** `ha3tier-vpc`
3. Click **Create route table**.

**Add the default route to the IGW:**

1. Select the new route table (checkbox).
2. Bottom panel → **Routes** tab → **Edit routes** → **Add route**.
3. **Destination:** `0.0.0.0/0`
4. **Target:** `Internet Gateway` → select `ha3tier-igw`
5. **Save changes**.

**Verify:** Routes tab now shows two rows:
- `10.0.0.0/16` → local
- `0.0.0.0/0` → igw-id (the IGW you just attached)

**Associate public subnets with this route table:**

1. With `ha3tier-public-rt` selected → bottom panel **Subnet associations** tab → **Edit subnet associations**.
2. Check `ha3tier-public-a` and `ha3tier-public-b`.
3. **Save associations**.

**Verify:** Subnet associations tab shows both public subnets.

---

## Step 5 — Create NAT Gateway(s)

**Cost decision:**
- **1 NAT Gateway in AZ-a** → cheaper (~$32/month), but if AZ-a dies, AZ-b instances lose outbound internet until you manually fix. App still serves inbound traffic but cannot pull OS updates.
- **2 NAT Gateways (one per AZ)** → more resilient (~$64/month), no single point of failure.

For learning, build **2 NAT Gateways** so you understand the HA pattern. You can tear one down later to save money.

**Prerequisite:** Allocate an Elastic IP for each NAT first.

### 5a. Allocate Elastic IPs

**Console path:** VPC → left menu → **Elastic IPs** → top-right **Allocate Elastic IP address**.

1. **Network border group:** leave default (your region).
2. **Public IPv4 address pool:** `Amazon's pool of IPv4 addresses`.
3. **Allocate**.
4. Name it `ha3tier-nat-eip-a` (after allocation, click the Name field at the top of the screen, type the name).
5. Repeat: allocate another, name `ha3tier-nat-eip-b`.

**Verify:** Elastic IPs page shows 2 addresses. State will be `Associated = No` until you attach them — that's fine for now.

### 5b. Create NAT Gateway in AZ-a

**Console path:** VPC → left menu → **NAT gateways** → top-right **Create NAT gateway**.

1. **Name:** `ha3tier-nat-a`
2. **Subnet:** select `ha3tier-public-a` (NAT must live in a public subnet so it can reach the IGW)
3. **Connectivity type:** `Public`
4. **Elastic IP allocation ID:** select `ha3tier-nat-eip-a`
5. Click **Create NAT gateway**.

**State will be `Pending` for ~1 minute**, then `Available`.

### 5c. Create NAT Gateway in AZ-b

Same as above:
- **Name:** `ha3tier-nat-b`
- **Subnet:** `ha3tier-public-b`
- **Elastic IP:** `ha3tier-nat-eip-b`
- **Create**.

**Verify:** NAT gateways page shows 2 rows, both `Available`, each in a different AZ.

---

## Step 6 — Create private route tables and associate private subnets

**Why we need two private RTs (one per AZ):** Each private subnet needs a route to its own AZ's NAT Gateway. If you put both private-app subnets in one RT pointing at one NAT, AZ-b loses outbound if AZ-a's NAT dies. Two RTs is the HA pattern.

**Console path:** VPC → left menu → **Route tables** → **Create route table**.

### 6a. Private RT for AZ-a
1. **Name:** `ha3tier-private-rt-a`
2. **VPC:** `ha3tier-vpc`
3. **Create**.
4. Select it → **Routes** tab → **Edit routes** → **Add route**:
   - Destination: `0.0.0.0/0`
   - Target: `NAT Gateway` → `ha3tier-nat-a`
   - **Save changes**.
5. **Subnet associations** tab → **Edit subnet associations** → check `ha3tier-app-a` AND `ha3tier-db-a` → **Save**.

**Why app and DB share an RT in the same AZ:** They both need outbound via the same NAT. Later, in production, you'd separate DB from app RTs for extra defense-in-depth. For this project, sharing is fine.

### 6b. Private RT for AZ-b
1. **Name:** `ha3tier-private-rt-b`
2. **VPC:** `ha3tier-vpc`
3. **Create**.
4. **Routes** → **Add route**:
   - Destination: `0.0.0.0/0`
   - Target: `NAT Gateway` → `ha3tier-nat-b`
   - **Save**.
5. **Subnet associations** → check `ha3tier-app-b` AND `ha3tier-db-b` → **Save**.

**Verify:** Route tables page shows:
- `ha3tier-public-rt` — local + IGW
- `ha3tier-private-rt-a` — local + nat-a
- `ha3tier-private-rt-b` — local + nat-b
- (the main RT still exists with just the local route — that's normal)

**Subnet associations verify:**
- `ha3tier-public-rt` → public-a, public-b
- `ha3tier-private-rt-a` → app-a, db-a
- `ha3tier-private-rt-b` → app-b, db-b

---

## Step 7 — Quick network sanity test (optional but recommended)

Before moving to ALB/RDS, confirm the network actually routes. Launch a tiny temporary EC2 in a public subnet and try to reach the internet.

1. EC2 → **Launch instances** → name `sandbox-net-check` → AMI: **Amazon Linux 2023** → instance type: `t3.micro` → key pair: **Proceed without a key pair** (we use SSM later) → **Network settings**:
   - VPC: `ha3tier-vpc`
   - Subnet: `ha3tier-public-a`
   - Auto-assign public IP: **Enable**
   - Firewall (security group): **Create new** → name `sg-temp-check` → allow SSH from `My IP` (or `0.0.0.0/0` for the test, then delete)
2. **Advanced details** → IAM instance profile: leave blank for now → **Launch**.
3. After state `running`, select instance → **Connect** → **EC2 Instance Connect** → **Connect**.
4. In the browser shell:
   ```bash
   curl -s https://checkip.amazonaws.com
   ```
   You should see a public IP (one of your EIPs or the auto-assigned one).

If that returns an IP, the IGW + public RT + public subnet are working.

5. **Terminate the instance** and **delete the security group** to stop charges.

---

## What you have so far

- Custom VPC `10.0.0.0/16`
- 6 subnets across 2 AZs and 3 tiers
- Internet Gateway attached
- 2 NAT Gateways with Elastic IPs
- 1 public route table + 2 private route tables, correctly associated

**Your AWS bill is now ~$64/month** from the two NAT Gateways. Don't leave this running for weeks. We'll add ALB and RDS in Part 3, and you'll get the cleanup steps in Part 6.

---

## Network CIDR reference table (for later parts)

| Resource | CIDR |
|----------|------|
| VPC | 10.0.0.0/16 |
| public-a | 10.0.1.0/24 |
| public-b | 10.0.2.0/24 |
| app-a | 10.0.10.0/24 |
| app-b | 10.0.11.0/24 |
| db-a | 10.0.20.0/24 |
| db-b | 10.0.21.0/24 |

| Route table | Routes | Subnets |
|-------------|--------|---------|
| ha3tier-public-rt | local + IGW | public-a, public-b |
| ha3tier-private-rt-a | local + nat-a | app-a, db-a |
| ha3tier-private-rt-b | local + nat-b | app-b, db-b |

---

**Say "continue" for Part 3:** Security groups, IAM role for EC2, SSM Session Manager, RDS Multi-AZ, Secrets Manager, then the ALB, Launch Template, and Auto Scaling Group. We finish the GUI build.
