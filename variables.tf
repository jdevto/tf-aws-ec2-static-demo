variable "aws_region" {
  type        = string
  description = "AWS region for all resources."
  default     = "ap-southeast-2"
}

variable "use_alb" {
  type        = bool
  description = "If true, create an internet-facing ALB and send HTTP to the instance; instance is not reachable on :80 from the internet directly. Subnet count follows az_count (default 3 AZs)."
  default     = false
}

variable "az_count" {
  type        = number
  description = "When use_alb is true: number of public subnets, one per distinct AZ (ALB spans all of them). When use_alb is false: ignored; a single subnet is created."
  default     = 3

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 6 && (!var.use_alb || var.az_count >= 2)
    error_message = "az_count must be between 1 and 6, and at least 2 when use_alb is true (ALB requirement)."
  }
}

variable "allowed_http_cidr" {
  type        = string
  description = "When use_alb is false: CIDR allowed to reach the instance on port 80. When use_alb is true: CIDR allowed to reach the ALB on port 80."
  default     = "0.0.0.0/0"
}

variable "enable_ssm" {
  type        = bool
  description = "Attach an instance profile with AmazonSSMManagedInstanceCore so you can use Session Manager (no SSH key). Requires outbound internet or SSM VPC endpoints."
  default     = true
}
