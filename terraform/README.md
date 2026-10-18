# Highly Available 3-Tier Web App on AWS — Terraform

This directory recreates the **networking layer** (VPC, subnets, route tables, gateways, security groups) and the **shared infrastructure primitives** (KMS, IAM for EC2, SSM parameters) from the GUI tutorial in Part 2/3.

The application layer (RDS, ALB, ASG, CloudFront, Route 53, ACM, CloudWatch dashboards, SNS) is intentionally separate — you'll wire it up after the network is verified to work. This is the production pattern: bootstrap network first, then add workloads.

## File structure

```
terraform/
├── main.tf              # VPC, subnets, IGW, NAT, route tables, SGs
├── variables.tf         # Input variables with defaults
├── outputs.tf           # Output values for use by other stacks
├── versions.tf          # Terraform + provider versions
├── providers.tf         # AWS provider config
├── terraform.tfvars.example
└── README.md            # This file
```

## Files explained (resource by resource)

### `versions.tf`
Pins the Terraform version and the AWS provider version. Pinning prevents "it broke after an upgrade" surprises.

### `providers.tf`
Configures the AWS provider. We use the `us-east-1` region by default; override with `-var aws_region=...`.

### `variables.tf`
All inputs in one place. Defaults match the GUI tutorial. If you change `vpc_cidr`, update the public/private subnet CIDRs to stay inside it.

### `main.tf` (the heart of it)

| Resource | What it does | Why it matters |
|----------|--------------|----------------|
| `aws_vpc.ha3tier` | The custom VPC | Isolated network |
| `aws_subnet.public_a/b` | Public subnets in 2 AZs | Hold the ALB |
| `aws_subnet.app_a/b` | Private-app subnets | Hold EC2 |
| `aws_subnet.db_a/b` | Private-DB subnets | Hold RDS |
| `aws_internet_gateway.igw` | Door to the internet | Required for ALB |
| `aws_eip.nat_a/b` | Static public IPs | NAT needs them |
| `aws_nat_gateway.nat_a/b` | Outbound for private subnets | OS updates, AWS APIs |
| `aws_route_table.public_rt` | Sends public subnets to IGW | One RT, both public subnets |
| `aws_route_table.private_rt_a` | Sends app-a/db-a to nat-a | HA: each AZ has its own NAT |
| `aws_route_table.private_rt_b` | Sends app-b/db-b to nat-b | HA |
| `aws_route_table_association.*` | Binds subnets to RTs | Without this, subnets use the main RT (no internet) |
| `aws_security_group.alb_sg` | ALB firewall | HTTP/HTTPS from internet |
| `aws_security_group.app_sg` | EC2 firewall | HTTP from ALB SG only |
| `aws_security_group.db_sg` | DB firewall | MySQL from app SG only |
| `aws_iam_role.ec2_role` | EC2 instance profile | SSM, CloudWatch, Secrets Manager |
| `aws_iam_role_policy_attachment.*` | Attaches AWS-managed policies | Least privilege: SSM core, CW agent, custom secrets read |
| `aws_iam_policy.secrets_read` | Custom least-privilege policy | Only the project's secret ARN is readable |
| `aws_iam_instance_profile.ec2_profile` | Container for the role | Attached to Launch Template |
| `aws_kms_key.ha3tier` | KMS key for encryption | Used by Secrets Manager, CloudWatch logs |

## Usage

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars if you want to override defaults

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

## Outputs

After apply, `terraform output` shows:
- `vpc_id`
- `public_subnet_ids`, `app_subnet_ids`, `db_subnet_ids`
- `alb_sg_id`, `app_sg_id`, `db_sg_id`
- `ec2_instance_profile_name`
- `secrets_manager_kms_key_arn`

These are what you'd pass to a second Terraform stack (or a Helm chart, or a CloudFormation template) for the application tier.

## Cleanup

```bash
terraform destroy
```

This removes everything Terraform created. It does NOT remove resources created in the GUI tutorial that aren't managed here (RDS, ALB, ASG, CloudFront, etc.) — see Part 6 for full teardown.

## Cost note

Running this stack costs ~$64/month from the two NAT Gateways alone. Run `terraform destroy` when not learning. For a cheaper learning setup, set `enable_dual_nat = false` to get only one NAT (~$32/month, no AZ-failure resilience).
