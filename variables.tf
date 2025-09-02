variable "project" {
  description = "Project name used for tagging and naming."
  type        = string
  default     = "iw"
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region to deploy resources in."
  type        = string
  default     = "eu-central-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets" {
  description = "List of public subnet CIDRs."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnets" {
  description = "List of private subnet CIDRs."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "availability_zones" {
  description = "AZs to use. If empty, will use data source to fetch."
  type        = list(string)
  default     = []
}

variable "ec2_instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "ec2_instance_count" {
  description = "Number of EC2 instances to launch."
  type        = number
  default     = 1
}

variable "ec2_key_name" {
  description = "Name of an existing EC2 Key Pair to enable SSH access."
  type        = string
  default     = null
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH to instances (for bastion or SSM optional)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "db_username" {
  description = "Master username for RDS MySQL."
  type        = string
  default     = "admin"
}

variable "db_password" {
  description = "Master password for RDS MySQL. Use a secret manager in production."
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "RDS storage in GB."
  type        = number
  default     = 20
}

variable "redis_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_engine_version" {
  description = "Redis engine version."
  type        = string
  default     = "7.0"
}

variable "alb_certificate_arn" {
  description = "ACM certificate ARN for HTTPS on ALB."
  type        = string
  default     = null
}

variable "client_vpn_cidr" {
  description = "CIDR range for client VPN. Must be from RFC1918 and non-overlapping."
  type        = string
  default     = "172.16.0.0/22"
}

variable "client_vpn_certificate_arn" {
  description = "ACM server certificate for the Client VPN endpoint."
  type        = string
}

variable "client_vpn_client_root_certificate_arn" {
  description = "ACM certificate ARN for the client certificate root CA used for mutual TLS auth."
  type        = string
  default     = null
}

variable "client_vpn_auth_saml_provider_arn" {
  description = "Optional SAML provider ARN for federated auth; if null, will use mutual cert auth only."
  type        = string
  default     = null
}


variable "create_bastion" {
  description = "Whether to create a small bastion host in a public subnet for troubleshooting."
  type        = bool
  default     = false
}
