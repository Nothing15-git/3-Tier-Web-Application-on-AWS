# Changelog

All notable changes to this project are documented here. Dates are in UTC.

## [1.0.0] - 2026-10-18

### Added
- Initial release of the highly available 3-tier web application on AWS.
- Custom VPC across 2 AZs with 6 segmented subnets (public, private-app, private-db).
- Internet Gateway, 2 NAT Gateways (one per AZ for HA), 3 route tables.
- 3 security groups with chained least-privilege ingress (ALB -> app -> DB).
- IAM role for EC2 with SSM Session Manager, CloudWatch Agent, and a custom
  least-privilege Secrets Manager policy scoped to a single secret ARN.
- Sample Flask app with `/`, `/health`, `/visits`, `POST /visit`, `/api/info`.
- EC2 user data script that bootstraps Python 3.11, deploys the app via
  systemd, and configures the CloudWatch Agent.
- Terraform code for the networking layer (VPC, subnets, NAT, SGs, IAM, KMS, SSM).
- GUI walkthrough (Parts 1-6) covering architecture, networking, security, RDS,
  ALB, ASG, CloudFront, Route 53, CloudWatch, SNS, testing, and cleanup.
- Incident response runbook.
- 9 measurable resume bullets and 8 interview Q&As.
