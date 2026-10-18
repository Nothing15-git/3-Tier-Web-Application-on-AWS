###############################################################################
# Data sources
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

###############################################################################
# KMS key for Secrets Manager and CloudWatch logs encryption
###############################################################################

resource "aws_kms_key" "ha3tier" {
  description             = "KMS key for ha3tier (Secrets Manager, CW logs)"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "ha3tier" {
  name          = "alias/ha3tier"
  target_key_id = aws_kms_key.ha3tier.key_id
}

###############################################################################
# VPC
###############################################################################

resource "aws_vpc" "ha3tier" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "ha3tier-vpc" }
}

###############################################################################
# Subnets: 2 public, 2 private-app, 2 private-db across 2 AZs
###############################################################################

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.ha3tier.id
  cidr_block              = var.public_subnet_cidrs[0]
  availability_zone       = var.azs[0]
  map_public_ip_on_launch = true

  tags = { Name = "ha3tier-public-a", Tier = "public" }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.ha3tier.id
  cidr_block              = var.public_subnet_cidrs[1]
  availability_zone       = var.azs[1]
  map_public_ip_on_launch = true

  tags = { Name = "ha3tier-public-b", Tier = "public" }
}

resource "aws_subnet" "app_a" {
  vpc_id            = aws_vpc.ha3tier.id
  cidr_block        = var.app_subnet_cidrs[0]
  availability_zone = var.azs[0]

  tags = { Name = "ha3tier-app-a", Tier = "app" }
}

resource "aws_subnet" "app_b" {
  vpc_id            = aws_vpc.ha3tier.id
  cidr_block        = var.app_subnet_cidrs[1]
  availability_zone = var.azs[1]

  tags = { Name = "ha3tier-app-b", Tier = "app" }
}

resource "aws_subnet" "db_a" {
  vpc_id            = aws_vpc.ha3tier.id
  cidr_block        = var.db_subnet_cidrs[0]
  availability_zone = var.azs[0]

  tags = { Name = "ha3tier-db-a", Tier = "db" }
}

resource "aws_subnet" "db_b" {
  vpc_id            = aws_vpc.ha3tier.id
  cidr_block        = var.db_subnet_cidrs[1]
  availability_zone = var.azs[1]

  tags = { Name = "ha3tier-db-b", Tier = "db" }
}

###############################################################################
# Internet Gateway
###############################################################################

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.ha3tier.id

  tags = { Name = "ha3tier-igw" }
}

###############################################################################
# Elastic IPs for NAT Gateways
###############################################################################

resource "aws_eip" "nat_a" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]

  tags = { Name = "ha3tier-nat-eip-a" }
}

resource "aws_eip" "nat_b" {
  count      = var.enable_dual_nat ? 1 : 0
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]

  tags = { Name = "ha3tier-nat-eip-b" }
}

###############################################################################
# NAT Gateways (one in AZ-a always; one in AZ-b if enable_dual_nat = true)
###############################################################################

resource "aws_nat_gateway" "nat_a" {
  allocation_id = aws_eip.nat_a.id
  subnet_id     = aws_subnet.public_a.id

  tags = { Name = "ha3tier-nat-a" }

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_nat_gateway" "nat_b" {
  count         = var.enable_dual_nat ? 1 : 0
  allocation_id = aws_eip.nat_b[0].id
  subnet_id     = aws_subnet.public_b.id

  tags = { Name = "ha3tier-nat-b" }

  depends_on = [aws_internet_gateway.igw]
}

###############################################################################
# Route tables
#   public_rt  -> local + IGW (used by both public subnets)
#   private_rt_a -> local + nat_a (used by app-a and db-a)
#   private_rt_b -> local + nat_b (used by app-b and db-b)
###############################################################################

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.ha3tier.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "ha3tier-public-rt" }
}

resource "aws_route_table" "private_rt_a" {
  vpc_id = aws_vpc.ha3tier.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_a.id
  }

  tags = { Name = "ha3tier-private-rt-a" }
}

resource "aws_route_table" "private_rt_b" {
  vpc_id = aws_vpc.ha3tier.id

  dynamic "route" {
    for_each = var.enable_dual_nat ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.nat_b[0].id
    }
  }

  # Fallback route: if dual NAT is off, point both AZs at nat-a
  dynamic "route" {
    for_each = var.enable_dual_nat ? [] : [1]
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.nat_a.id
    }
  }

  tags = { Name = "ha3tier-private-rt-b" }
}

###############################################################################
# Route table associations
###############################################################################

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "app_a" {
  subnet_id      = aws_subnet.app_a.id
  route_table_id = aws_route_table.private_rt_a.id
}

resource "aws_route_table_association" "app_b" {
  subnet_id      = aws_subnet.app_b.id
  route_table_id = aws_route_table.private_rt_b.id
}

resource "aws_route_table_association" "db_a" {
  subnet_id      = aws_subnet.db_a.id
  route_table_id = aws_route_table.private_rt_a.id
}

resource "aws_route_table_association" "db_b" {
  subnet_id      = aws_subnet.db_b.id
  route_table_id = aws_route_table.private_rt_b.id
}

###############################################################################
# Security groups
#   alb_sg  : 80/443 from internet
#   app_sg  : 80 from alb_sg only
#   db_sg   : 3306 from app_sg only
###############################################################################

resource "aws_security_group" "alb_sg" {
  name        = "sg-alb"
  description = "Allow HTTP/HTTPS from internet to ALB"
  vpc_id      = aws_vpc.ha3tier.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sg-alb" }
}

resource "aws_security_group" "app_sg" {
  name        = "sg-app"
  description = "Allow HTTP from ALB only; SSM requires HTTPS egress via NAT"
  vpc_id      = aws_vpc.ha3tier.id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    description = "Outbound for SSM, CW, package updates, Secrets Manager"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sg-app" }
}

resource "aws_security_group" "db_sg" {
  name        = "sg-db"
  description = "Allow MySQL from app tier only"
  vpc_id      = aws_vpc.ha3tier.id

  ingress {
    description     = "MySQL from app tier"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }

  egress {
    description = "All outbound (rarely used for RDS; placeholder)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sg-db" }
}

###############################################################################
# IAM role for EC2 (used by Launch Template in the app stack)
#   - SSM core: Session Manager
#   - CW agent: custom metrics + log streaming
#   - secrets read: least privilege for the DB secret
###############################################################################

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_role" {
  name               = "ha3tier-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "secrets_read" {
  statement {
    sid    = "ReadProjectSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.db_secret_name}*"
    ]
  }
}

resource "aws_iam_policy" "secrets_read" {
  name   = "ha3tier-ec2-secrets-read"
  policy = data.aws_iam_policy_document.secrets_read.json
}

resource "aws_iam_role_policy_attachment" "secrets_read" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.secrets_read.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ha3tier-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

###############################################################################
# SSM parameters (handy for cross-stack wiring without hardcoding IDs)
###############################################################################

resource "aws_ssm_parameter" "vpc_id" {
  name  = "/ha3tier/vpc_id"
  type  = "String"
  value = aws_vpc.ha3tier.id
  tags  = { Name = "ha3tier-vpc-id" }
}
