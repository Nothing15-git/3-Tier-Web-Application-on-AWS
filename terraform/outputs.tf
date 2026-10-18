output "vpc_id" {
  description = "ID of the ha3tier VPC"
  value       = aws_vpc.ha3tier.id
}

output "vpc_cidr" {
  description = "CIDR of the ha3tier VPC"
  value       = aws_vpc.ha3tier.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (2 AZs)"
  value       = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

output "app_subnet_ids" {
  description = "IDs of the private-app subnets (2 AZs)"
  value       = [aws_subnet.app_a.id, aws_subnet.app_b.id]
}

output "db_subnet_ids" {
  description = "IDs of the private-db subnets (2 AZs)"
  value       = [aws_subnet.db_a.id, aws_subnet.db_b.id]
}

output "alb_security_group_id" {
  description = "ID of the ALB security group"
  value       = aws_security_group.alb_sg.id
}

output "app_security_group_id" {
  description = "ID of the app/EC2 security group"
  value       = aws_security_group.app_sg.id
}

output "db_security_group_id" {
  description = "ID of the DB security group"
  value       = aws_security_group.db_sg.id
}

output "ec2_instance_profile_name" {
  description = "Name of the IAM instance profile for EC2 (attach to Launch Template)"
  value       = aws_iam_instance_profile.ec2_profile.name
}

output "ec2_instance_profile_arn" {
  description = "ARN of the IAM instance profile"
  value       = aws_iam_instance_profile.ec2_profile.arn
}

output "ec2_role_arn" {
  description = "ARN of the IAM role for EC2"
  value       = aws_iam_role.ec2_role.arn
}

output "secrets_manager_kms_key_arn" {
  description = "KMS key ARN to use for Secrets Manager and CW log groups"
  value       = aws_kms_key.ha3tier.arn
}

output "igw_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.igw.id
}

output "nat_gateway_a_id" {
  description = "ID of the NAT Gateway in AZ-a"
  value       = aws_nat_gateway.nat_a.id
}

output "nat_gateway_b_id" {
  description = "ID of the NAT Gateway in AZ-b (empty list if dual NAT is disabled)"
  value       = var.enable_dual_nat ? aws_nat_gateway.nat_b[0].id : null
}

output "public_route_table_id" {
  description = "ID of the public route table"
  value       = aws_route_table.public_rt.id
}

output "private_route_table_a_id" {
  description = "ID of the private route table for AZ-a"
  value       = aws_route_table.private_rt_a.id
}

output "private_route_table_b_id" {
  description = "ID of the private route table for AZ-b"
  value       = aws_route_table.private_rt_b.id
}
