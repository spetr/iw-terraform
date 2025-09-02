############################################
# Project & Environment
############################################

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

############################################
# Networking (VPC & Subnets)
############################################

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

############################################
# Compute (EC2) & Access
############################################

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

variable "ec2_ami_id" {
  description = "Optional explicit AMI ID to use for EC2 and bastion. If null, Terraform will try to find Rocky Linux 9.6 automatically."
  type        = string
  default     = null
}

variable "ec2_key_name" {
  description = "Name of an existing EC2 Key Pair to enable SSH access."
  type        = string
  default     = null
}

############################################
# Storage (EFS)
############################################

variable "enable_efs_archive" {
  description = "Whether to create an optional third EFS filesystem named 'archive'."
  type        = bool
  default     = false
}

# EFS throughput configuration
# efs_throughput_mode options:
# - "bursting"    (default): Baseline scales with filesystem size with short bursts.
# - "provisioned": Fixed throughput in MiB/s regardless of size; set efs_provisioned_throughput_mibps.
# - "elastic"     : Auto-scales throughput based on workload; billed per usage.
variable "efs_throughput_mode" {
  description = "EFS throughput mode for all EFS filesystems: bursting | provisioned | elastic."
  type        = string
  default     = "bursting"
  validation {
    condition     = contains(["bursting", "provisioned", "elastic"], var.efs_throughput_mode)
    error_message = "efs_throughput_mode must be one of: bursting, provisioned, elastic."
  }
}

variable "efs_provisioned_throughput_mibps" {
  description = "Provisioned throughput in MiB/s when efs_throughput_mode = 'provisioned' (e.g., 32)."
  type        = number
  default     = null
}

############################################
# Databases (RDS MySQL)
############################################

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

############################################
# Caching (ElastiCache Redis)
############################################

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

############################################
# Load Balancing / Certificates
############################################

variable "alb_certificate_arn" {
  description = "ACM certificate ARN for HTTPS on ALB."
  type        = string
  default     = null
}

############################################
# Email Amazon SES (optional)
############################################

variable "enable_ses" {
  description = "Enable Amazon SES setup (identity and permissions)."
  type        = bool
  default     = false
}

variable "ses_identity_type" {
  description = "SES identity type to verify: 'email' or 'domain'."
  type        = string
  default     = "email"
  validation {
    condition     = contains(["email", "domain"], var.ses_identity_type)
    error_message = "ses_identity_type must be 'email' or 'domain'."
  }
}


variable "ses_route53_zone_id" {
  description = "Optional Route53 Hosted Zone ID for creating SES DNS records automatically for domain identity."
  type        = string
  default     = null
}

# New: support multiple identities
variable "ses_email_identities" {
  description = "List of email identities to verify for SES."
  type        = list(string)
  default     = []
}

variable "ses_domain_identities" {
  description = "List of domains to verify for SES."
  type        = list(string)
  default     = []
}

variable "ses_route53_zone_ids" {
  description = "Optional map of domain => Route53 Hosted Zone ID for creating SES DNS records per domain. If provided, overrides ses_route53_zone_id for matching domains."
  type        = map(string)
  default     = {}
}

############################################
# Remote Access - Bastion Host (optional)
############################################

variable "create_bastion" {
  description = "Whether to create a small bastion host in a public subnet for troubleshooting."
  type        = bool
  default     = false
}

variable "bastion_instance_type" {
  description = "Bastion EC2 instance type (SSM-only bastion)."
  type        = string
  default     = "t3.micro"
}

############################################
# Remote Access - SSH (optional)
############################################

variable "enable_ssh_access" {
  description = "Enable direct SSH (port 22) to EC2 instances. When false, SSH ingress is not created."
  type        = bool
  default     = false
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH to instances (for bastion or SSM optional)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

############################################
# Remote Access - Client VPN (optional)
############################################

variable "enable_client_vpn" {
  description = "Whether to create the AWS Client VPN endpoint and related resources."
  type        = bool
  default     = false
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