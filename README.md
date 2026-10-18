# Highly Available 3-Tier Web Application on AWS

A production-style 3-tier architecture (web/app, database, edge) deployed across two Availability Zones, with automatic failover, auto-healing, and HTTPS at the edge.

![Architecture](docs/architecture.png)

## Why this exists

Demonstrates the core patterns every production AWS environment uses: custom VPC with public/private segmentation, Multi-AZ RDS, ALB + ASG self-healing, CloudFront + ACM for edge HTTPS, and CloudWatch + SNS for observability and alerting.

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

See `docs/PART-5-cloudfront-route53-monitoring-testing.md` for step-by-step test instructions.

## Cleanup

```bash
cd terraform
terraform destroy
# Then follow docs/PART-6-cleanup-readme-runbook-resume-interview.md section 1a
# to remove GUI-created resources in the right dependency order.
```

## Cost (us-east-1, sandbox, 1 month)

| Resource | Cost/month |
|----------|-----------|
| 2 NAT Gateways | ~$64 |
| Application Load Balancer | ~$16 |
| RDS MySQL Multi-AZ db.t3.micro | ~$50 |
| 2 x t3.micro (free tier) | $0 |
| CloudWatch logs + metrics | <$5 |
| Secrets Manager (1 secret) | $0.40 |
| Data transfer | variable |
| **Total (1 week)** | **~$25-40** |

## Security notes

- No SSH keys on any instance; SSM Session Manager only.
- DB is in private subnets; not publicly accessible.
- Security groups chain (ALB -> app -> DB) instead of CIDR-based rules.
- IAM uses least-privilege custom policy for Secrets Manager.
- All logs and secrets encrypted with customer-managed KMS key.

## License

MIT - feel free to use this as a template for your own learning.
