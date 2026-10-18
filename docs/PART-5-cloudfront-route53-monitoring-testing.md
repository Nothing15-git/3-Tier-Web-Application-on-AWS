# Part 5: CloudFront, Route 53, CloudWatch, SNS, and Verification Tests

This part wires the global edge layer (CloudFront + Route 53) on top of the ALB, sets up observability (CloudWatch dashboards + SNS email alerts), then runs the three tests that prove the system is actually highly available: failover, scaling, and HTTPS.

---

## Step 1 — CloudFront distribution in front of the ALB

**Why:** CloudFront puts your content at 600+ edge locations worldwide. A user in Tokyo hits a Tokyo edge node instead of crossing the Pacific to `us-east-1`. It also terminates HTTPS at the edge using the ACM cert (no need to add a public cert to the ALB).

**Console path:** CloudFront → top-right **Create distribution**.

### 1a. Origin
- **Origin domain:** paste your ALB DNS name (e.g., `ha3tier-alb-1234567890.us-east-1.elb.amazonaws.com`). Do NOT select from the dropdown — the ALB isn't an S3 bucket and the dropdown is for known origins. Pasting the DNS is correct.
- **Origin path:** leave blank
- **Name:** `ha3tier-alb-origin` (auto-filled)
- **Enable Origin Shield:** No (costs extra; useful only for very high-traffic origins)
- **Origin access:** `Public` (ALB origin is public)

### 1b. Default cache behavior
- **Viewer protocol policy:** `Redirect HTTP to HTTPS` (users typing `http://` get bumped to `https://`)
- **Allowed HTTP methods:** `GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE`
- **Cache policy:** select `CachingDisabled` for this app. **Why:** the `/visit` endpoint writes to the DB and `/api/info` shows live data. If you cache `/`, `/visits`, or `/visit`, users get stale data. Real production would use multiple cache behaviors: cache `/static/*` aggressively, but bypass `/api/*` and `/visit`.
- **Origin request policy:** select `AllViewerExceptHostHeader` (forwards all headers, query string, cookies to the ALB)
- **Response headers policy:** `SimpleCORS` (optional, helps if you ever call this from a JS frontend)

### 1c. Cache key settings (advanced)
Skip for now; defaults are fine.

### 1d. Settings
- **Price class:** `Use all edge locations for best performance` (slightly more expensive; `North America + Europe` is cheaper and fine for learning)
- **Alternate domain name (CNAME):** `app.tayyab.dev` (your domain; skip if testing without a domain)
- **Custom SSL certificate:** select the ACM cert you created in Part 3 (`*.tayyab.dev` works)
- **Default root object:** `index.html` (CloudFront serves this if no path given; the ALB returns `/`, so this is mostly for cosmetic browser requests)
- **Standard logging:** On → click to create a new S3 bucket for logs (or skip for sandbox; we can add later)
- **IPv6:** On

Click **Create distribution**. Status goes `In Progress` → `Deployed` in 5-15 minutes.

**Verify:** Status = `Deployed`. Click the distribution → copy the **Distribution domain name** (looks like `d111111abcdef8.cloudfront.net`). Visit it in a browser — you should see the Flask app. The URL bar shows a padlock. View certificate in browser → it's your ACM cert.

---

## Step 2 — Route 53 alias record (optional, requires a hosted zone)

**Why:** Route 53 is the DNS layer. An "alias" record is AWS-native: it points your domain directly to an AWS resource (CloudFront, ALB, S3) without paying for DNS lookups and without an IP that could change.

**Console path:** Route 53 → **Hosted zones** → click your zone (e.g., `tayyab.dev`) → **Create record**.

**Single record, simple setup:**

- **Record name:** `app` (becomes `app.tayyab.dev`)
- **Record type:** `A`
- **Alias:** toggle ON
- **Route traffic to:** `Alias to CloudFront distribution`
- **Choose distribution:** pick `ha3tier-alb-origin` from the list (or use the us-east-1 distribution dropdown)
- **Routing policy:** `Simple routing`
- Click **Create records**.

**Verify:**
```bash
dig app.tayyab.dev +short
# Should return something like:
# d111111abcdef8.cloudfront.net.
# 52.85.150.20
# 52.85.150.95
# ...
```

Visit `https://app.tayyab.dev/health` — returns 200, JSON shows `db: ok`.

### Without a Route 53 zone (sandbox)
If your domain is elsewhere, just create an A or CNAME at your registrar pointing to the CloudFront domain. Or skip DNS entirely and use the CloudFront URL directly.

---

## Step 3 — SNS topic for email alerts

**Why:** CloudWatch alarms need a target. SNS is the standard fan-out: one alarm → many subscribers, including email.

**Console path:** SNS → left menu → **Topics** → top-right **Create topic**.

1. **Type:** `Standard` (FIFO is for strict ordering, not needed here)
2. **Name:** `ha3tier-alerts`
3. **Display name:** (optional) `ha3tier alerts`
4. Click **Create topic**.

**Subscribe your email:**

1. Click the new topic → **Create subscription**.
2. **Protocol:** `Email`
3. **Endpoint:** your email address
4. Click **Create subscription**.

**Verify:** Check your inbox. AWS sends a confirmation email. Click the **Confirm subscription** link. Status in the console flips to `Confirmed`. If you skip this, no alerts will reach you.

**Bonus — add a second subscription later:** you can add PagerDuty, Slack (via webhook using AWS Chatbot), or SMS for redundancy.

---

## Step 4 — CloudWatch alarms

**Why:** Alarms turn metric thresholds into notifications. We'll create four high-value alarms that catch the most common production incidents.

**Console path:** CloudWatch → left menu → **Alarms** → top-right **Create alarm**.

### 4a. ALB 5xx errors
- **Select metric:** `ApplicationELB` namespace → `Per AppELB Metrics` → your ALB → `HTTPCode_ELB_5XX_Count`
- **Statistic:** `Sum`
- **Period:** `1 minute`
- **Condition:** `Greater than 10` (5+ 5xx in 1 minute = something is wrong)
- **Notification:** select `ha3tier-alerts` SNS topic
- **Alarm name:** `ha3tier-alb-5xx`
- Click **Create**.

### 4b. ASG CPU high (sustained load)
- **Metric:** `AWS/EC2` → `CPUUtilization` → by Auto Scaling Group → `asg-app`
- **Statistic:** `Average`
- **Period:** `5 minutes`
- **Condition:** `Greater than 70` for `3 consecutive periods` (15 minutes of high CPU)
- **Notification:** `ha3tier-alerts`
- **Alarm name:** `ha3tier-asg-cpu-high`

**Why 15 min and not immediate:** a 1-minute spike during deploy shouldn't page you. Tunable — change to `2 consecutive periods` if you want faster pages.

### 4c. RDS storage low
- **Metric:** `AWS/RDS` → `FreeStorageSpace` → your DB instance
- **Statistic:** `Minimum`
- **Period:** `5 minutes`
- **Condition:** `Less than 2 GB` (gives you time to scale storage before it fills)
- **Notification:** `ha3tier-alerts`
- **Alarm name:** `ha3tier-rds-storage-low`

### 4d. RDS connections high
- **Metric:** `AWS/RDS` → `DatabaseConnections`
- **Statistic:** `Average`
- **Period:** `5 minutes`
- **Condition:** `Greater than 80` (db.t3.micro max is ~100 — this gives warning before exhaustion)
- **Notification:** `ha3tier-alerts`
- **Alarm name:** `ha3tier-rds-conns-high`

**Verify:** All four alarms show state = `OK`. The state will change to `In alarm` when threshold is crossed.

---

## Step 5 — CloudWatch dashboard

**Why:** A dashboard is a single URL with the 4-6 charts you stare at when something breaks. Saves you from clicking through 10 services during an incident.

**Console path:** CloudWatch → left menu → **Dashboards** → **Create dashboard** → name `ha3tier-overview` → **Create dashboard**.

Add widgets. For each: click **Add widget** → pick the type → configure → **Create widget**.

| Widget | Metric source | Config |
|--------|---------------|--------|
| ALB requests by AZ | `ApplicationELB` → `RequestCount` per AZ | Line, last 1h, stat = Sum |
| ALB 5xx | `ApplicationELB` → `HTTPCode_ELB_5XX_Count` | Line, last 1h, Sum |
| ASG CPU | `AWS/EC2` → `CPUUtilization` by ASG | Line, last 1h, Average |
| ASG instance count | `AWS/AutoScaling` → `GroupInServiceInstances` | Line, last 1h, Min |
| RDS CPU | `AWS/RDS` → `CPUUtilization` by DB | Line, last 1h, Average |
| RDS connections | `AWS/RDS` → `DatabaseConnections` | Line, last 1h, Average |
| RDS free storage | `AWS/RDS` → `FreeStorageSpace` | Line, last 1h, Minimum |
| ALB target health | `ApplicationELB` → `HealthyHostCount` / `UnHealthyHostCount` | Stacked area |

Click **Save dashboard**. Bookmark the URL — this is what you check first during an incident.

**Verify:** All widgets render data. The first time, some widgets may show "No data" because the ASG just started — wait 5 minutes and refresh.

---

## Step 6 — Verification tests (the three that matter)

These are the tests you perform live and screenshot for your portfolio. Each one is a 5-15 minute exercise.

### Test 1 — HTTPS check (must pass first)

```bash
# Replace with your CloudFront domain or ALB DNS
TARGET="https://app.tayyab.dev"

# 1. TLS handshake works
echo | openssl s_client -servername app.tayyab.dev -connect app.tayyab.dev:443 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
# Should show: Subject: CN = app.tayyab.dev, Issuer: Amazon, valid dates

# 2. HSTS header (optional, set by CloudFront default? No — only if you set it)
curl -sI "$TARGET/health" | head -20
# Expect: HTTP/2 200, content-type: application/json

# 3. Strict TLS 1.2 minimum
nmap --script ssl-enum-ciphers -p 443 app.tayyab.dev
# Should show only TLS 1.2 and 1.3 ciphers
```

**Pass criteria:** TLS handshake succeeds, `/health` returns 200 JSON, no expired certs.

### Test 2 — Failover test (instance)

**Goal:** prove the ASG replaces a killed instance without user-visible downtime.

1. Open `https://app.tayyab.dev` in your browser. Note the instance ID shown.
2. Open CloudWatch → ASG → `GroupInServiceInstances` widget. Confirm it shows 2.
3. In a terminal, generate a tiny constant load so you can detect downtime:
   ```bash
   while true; do
     curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" https://app.tayyab.dev/
     sleep 0.5
   done
   ```
4. In the EC2 console, find the running instance (the one shown in the browser). Select it → **Instance state** → **Terminate instance**. Confirm.
5. Watch the curl loop. You should see 100% success rate, no timeouts. The curl latency may briefly spike to 2-5 seconds while the ALB health check fails (3 × 30s = 90s default) and the ASG launches a new instance, but the ALB keeps sending to the surviving instance.
6. Refresh the browser. The instance ID has changed. ASG widget briefly shows 1, then returns to 2.
7. **Pass criteria:** no failed HTTP requests (no `000` status, no `5xx`); new instance in a different AZ or same AZ; service available throughout.

### Test 3 — Failover test (RDS Multi-AZ)

**Goal:** prove RDS fails over to the standby in another AZ when the primary is forced to reboot with failover.

1. Confirm current DB endpoint in Secrets Manager (it points to the primary in AZ-a).
2. RDS → Databases → click `ha3tier-db` → top-right **Actions** → **Reboot with failover**.
3. A confirmation dialog warns the DB will reboot. Confirm.
4. Watch the database status: `Rebooting` → `Available`. This takes 60-120 seconds.
5. During the failover, the endpoint DNS name stays the same. App connections drop briefly (a few seconds) and reconnect.
6. Confirm the app still works: `curl https://app.tayyab.dev/visits` returns the same count as before.
7. **Pass criteria:** endpoint name unchanged, app reconnects automatically, no data loss.

### Test 4 — Scaling test (load generation)

**Goal:** prove the ASG launches a new instance when CPU is high.

The fastest free way: use the EC2 instance itself, or a CloudShell terminal, to run a loop. For real load, use a small free tool.

**Option A — built-in shell (light load, may not trigger scale-out):**

```bash
# SSH-less way: SSM Session Manager → Run command
# Or just open CloudShell (top bar, terminal icon) and run:
for i in $(seq 1 1000); do
  curl -s https://app.tayyab.dev/ > /dev/null &
done
wait
```

**Option B — hey or ab (real load):**

```bash
# Install hey (single binary)
wget https://github.com/rakyll/hey/releases/latest/download/hey_linux_amd64 -O /usr/local/bin/hey
chmod +x /usr/local/bin/hey

# 5000 requests, 100 concurrent, from a single source
hey -n 5000 -c 100 https://app.tayyab.dev/
```

**Option C — distributed load (best):**

Use a free service like [k6.io](https://k6.io) cloud free tier, or run k6 from your laptop. k6 script:
```js
import http from 'k6/http';
import { check } from 'k6';
export default function () {
  check(http.get('https://app.tayyab.dev/'), { 'status 200': r => r.status === 200 });
  check(http.get('https://app.tayyab.dev/health'), { 'health ok': r => r.status === 200 });
}
```
Run: `k6 run --vus 50 --duration 60s script.js`

**Watch the dashboard:**
1. CloudWatch dashboard → ASG CPU climbs above 50%
2. ASG triggers scale-out → new instance launches (~2-3 min)
3. ASG widget shows instance count = 3, then maybe 4
4. ALB starts routing requests to the new instance
5. CPU drops as load spreads
6. After 10-15 minutes of low CPU, ASG scales back in (terminates an instance)

**Pass criteria:** ASG scales out under load, scales in when load drops, no 5xx errors, no failed health checks.

### Test 5 — AZ failure (the holy grail)

This is the most expensive to test (you actually break an AZ), so skip for the sandbox. Production teams use AWS Fault Injection Service (FIS) or simply terminate every instance in an AZ and watch the dashboard.

For the sandbox, the **load test scaling proof** and the **RDS failover proof** are enough for a portfolio. Mention the AZ-failure test in the README as "tested in staging, not in sandbox due to cost".

---

## Step 7 — Troubleshooting guide

| Symptom | Most likely cause | Fix |
|---------|-------------------|-----|
| ALB health checks failing | App not listening on port 80, or SG blocked | `curl localhost:80` from instance via SSM; check `sg-app` allows `sg-alb` on 80 |
| 502 Bad Gateway from ALB | App crashed, port not open, or gunicorn not running | SSM into instance → `systemctl status ha3tier`; check journal: `journalctl -u ha3tier -n 100` |
| RDS connection timeout | SG or wrong endpoint | From EC2 via SSM: `nc -zv <rds-endpoint> 3306`. If timeout → SG `sg-db` is missing `sg-app` source. If connection refused → wrong endpoint |
| Secrets Manager AccessDenied | EC2 role not attached, or policy too tight | SSM → `aws sts get-caller-identity` → check role name; `aws secretsmanager get-secret-value --secret-id ha3tier/db/master` from instance |
| SSM Session Manager won't connect | Instance role missing SSM core, or no outbound to SSM endpoints | Verify role has `AmazonSSMManagedInstanceCore`; verify private route table has NAT route |
| CloudFront returns 502 | Origin domain wrong or ALB not reachable from CF | Test ALB directly first; verify CF origin domain is exactly the ALB DNS, no `https://` prefix, no trailing `/` |
| HTTPS cert mismatch | Cert domain doesn't match URL | Re-issue cert with the correct domain, attach to ALB/CloudFront |
| ASG won't scale in | `Health check grace period` too short, or instances keep failing health | Check ALB target health tab; check `Health check grace period` is at least 300s |
| High RDS CPU | Missing index, or app doing full table scans | Enable Performance Insights → find slow queries; add index |
| Email alerts not arriving | SNS subscription not confirmed | SNS → Topics → `ha3tier-alerts` → Subscriptions → check `Confirmed`; check spam |
| NAT Gateway data charges | CloudWatch Agent pushing too much | Reduce metric collection interval or remove the `disk` measurement |
| Terraform `Error: error getting Route Table` | Deleting a subnet still referenced | Run `terraform state list` → remove stale state refs with `terraform state rm` |

### Diagnostic one-liners (run from SSM Session Manager)

```bash
# Who am I, what role
aws sts get-caller-identity
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/ | head

# Can I reach the DB?
nc -zv ha3tier-db.xxxx.us-east-1.rds.amazonaws.com 3306

# Can I reach Secrets Manager?
aws secretsmanager get-secret-value --secret-id ha3tier/db/master --query SecretString --output text

# App logs
journalctl -u ha3tier -n 200 --no-pager

# App is running?
systemctl is-active ha3tier && curl -s http://localhost/health
```

---

## What you have after Part 5

- CloudFront distribution in front of the ALB, with custom domain and ACM cert
- Route 53 alias to CloudFront (optional)
- SNS email topic subscribed and confirmed
- 4 CloudWatch alarms (ALB 5xx, ASG CPU, RDS storage, RDS connections)
- CloudWatch dashboard with 8 widgets
- Verified: HTTPS handshake, instance failover, RDS Multi-AZ failover, ASG scale-out under load
- Troubleshooting playbook

**Total monthly cost now ~$135** (NAT $64, ALB $16, RDS $50, CloudFront $1-5, CW/SNS under $5). Run the cleanup in Part 6 the day you finish.

---

**Say "continue" for Part 6:** cleanup/teardown (GUI + Terraform), GitHub README template, runbook, resume bullets, and the 8 interview questions with strong answers.
