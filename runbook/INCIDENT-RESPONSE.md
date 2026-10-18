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
2. Check the SNS email - what alarm fired and when?
3. Note current time and correlate with any recent deploys.

## Scenario A - "Users see 502 / app is down"
1. **ALB targets healthy?** EC2 -> Target Groups -> `tg-app` -> Health tab.
   - All `unhealthy` -> check the app next.
   - All `healthy` but 502 -> check CloudFront origin settings.
2. **App running on instances?** SSM Session Manager -> instance -> `systemctl status ha3tier`.
3. **App logs?** `journalctl -u ha3tier -n 200 --no-pager`.
4. **Recent crash?** `cat /var/log/user-data.log | tail -100`.
5. **DB reachable?** `nc -zv ha3tier-db.xxxx.us-east-1.rds.amazonaws.com 3306`.
   - If timeout -> check `sg-db` has `sg-app` as source.
   - If "connection refused" -> wrong endpoint, or DB is restarting.
6. **Fix the issue**, then `systemctl restart ha3tier` and watch `/health`.

## Scenario B - "ASG CPU is high"
1. Check ALB request count: is this real traffic or a runaway loop?
2. If real traffic: confirm target tracking is working (instance count should rise).
3. If 3-4 instances already at 80%+ CPU: scale up the instance type, or add a caching layer.

## Scenario C - "RDS failover alarm"
1. RDS -> Databases -> click `ha3tier-db` -> check Event log.
2. If failover: app should reconnect automatically. Watch `/health` for 5 minutes.
3. If still failing: read replica promotion issue. Check RDS events for root cause.

## Scenario D - "CloudWatch says storage low"
1. RDS -> Modify -> increase allocated storage (gp3 supports online resize).
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
