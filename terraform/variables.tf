variable "aws_region" {
  description = "AWS region to deploy in"
  type        = string
  default     = "us-east-1"
}

variable "owner" {
  description = "Owner tag value (your name or email)"
  type        = string
  default     = "tayyab"
}

variable "environment" {
  description = "Environment tag value"
  type        = string
  default     = "sandbox"
}

variable "vpc_cidr" {
  description = "CIDR for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Two /24s for public subnets across 2 AZs"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "app_subnet_cidrs" {
  description = "Two /24s for private-app subnets across 2 AZs"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "db_subnet_cidrs" {
  description = "Two /24s for private-db subnets across 2 AZs"
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24"]
}

variable "azs" {
  description = "Two AZs to use"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "enable_dual_nat" {
  description = "If true, create a NAT GW per AZ (HA). If false, one NAT GW in AZ-a (cheaper, single point of failure)"
  type        = bool
  default     = true
}

variable "db_secret_name" {
  description = "Name of the DB credentials secret in AWS Secrets Manager"
  type        = string
  default     = "ha3tier/db/master"
}
