output "aws_region" {
  description = "Region passed to the AWS provider (for CLI examples)."
  value       = var.aws_region
}

output "public_subnet_count" {
  description = "Number of public subnets created (1 without ALB; az_count when use_alb is true)."
  value       = local.subnet_count
}

output "private_subnet_count" {
  description = "Number of private subnets (0 without ALB; az_count when use_alb is true)."
  value       = var.use_alb ? var.az_count : 0
}

output "instance_count" {
  description = "Number of EC2 instances (1 without ALB; az_count when use_alb is true — one per private subnet / AZ)."
  value       = local.instance_count
}

output "instance_ids" {
  description = "All web instance IDs (same order as AZ indices when use_alb is true)."
  value       = aws_instance.web[*].id
}

output "instance_id" {
  description = "First web instance ID (convenience for SSM when all instances share the same role)."
  value       = aws_instance.web[0].id
}

output "instance_public_ip" {
  description = "Public IPv4 of the first instance. Empty when use_alb is true (private subnets). When use_alb is false, only one instance exists."
  value       = aws_instance.web[0].public_ip
}

output "ssm_start_session_command" {
  description = "AWS CLI example for Session Manager on the first instance (when enable_ssm is true). Use instance_ids for others."
  value       = var.enable_ssm ? "aws ssm start-session --target ${aws_instance.web[0].id} --region ${var.aws_region}" : null
}

output "website_url_direct" {
  description = "HTTP URL to the instance when use_alb is false (traffic allowed from allowed_http_cidr)."
  value       = var.use_alb ? null : "http://${aws_instance.web[0].public_ip}"
}

output "website_url_alb" {
  description = "HTTP URL via the load balancer when use_alb is true."
  value       = var.use_alb ? "http://${aws_lb.main[0].dns_name}" : null
}

output "verify_commands" {
  description = "Example curl commands after the instance finishes user_data (wait ~1–2 minutes on first boot)."
  value = var.use_alb ? {
    home   = "curl -sS http://${aws_lb.main[0].dns_name}/"
    robots = "curl -sS http://${aws_lb.main[0].dns_name}/robots.txt"
    } : {
    home   = "curl -sS http://${aws_instance.web[0].public_ip}/"
    robots = "curl -sS http://${aws_instance.web[0].public_ip}/robots.txt"
  }
}
