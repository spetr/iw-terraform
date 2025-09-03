############################################
# Project & Environment
############################################

# Project name (used in names and tags across all resources).
variable "project" {
  description = "Project name used for tagging and naming."
  type        = string
  default     = "iw"
}

# Environment name (e.g., dev, staging, prod); propagated into names/tags.
variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)."
  type        = string
  default     = "dev"
}

# AWS region to deploy into (e.g., eu-central-1).
variable "aws_region" {
  description = "AWS region to deploy resources in."
  type        = string
  default     = "eu-central-1"
}

############################################
# Networking (VPC & Subnets)
############################################

# CIDR block for the VPC (must not overlap with your other networks).
variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

# CIDR list for public subnets (count should match AZs; map_public_ip_on_launch = true).
variable "public_subnets" {
  description = "List of public subnet CIDRs."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

# CIDR list for private subnets (no public IPs).
variable "private_subnets" {
  description = "List of private subnet CIDRs."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

# Optional list of AZs; if empty, the first 2 available will be used.
variable "availability_zones" {
  description = "AZs to use. If empty, will use data source to fetch."
  type        = list(string)
  default     = []
}

# Use a single NAT Gateway in the first public subnet instead of one per AZ
variable "single_nat_gateway" {
  description = "When true, create only one NAT Gateway (in subnet index 0) and route all private subnets through it."
  type        = bool
  default     = false
}

############################################
# Compute (EC2) & Access
############################################

# EC2 instance type for app instances (e.g., t3.micro).
variable "ec2_instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

# Number of app EC2 instances (spread across private subnets/AZs).
variable "ec2_instance_count" {
  description = "Number of EC2 instances to launch."
  type        = number
  default     = 1
}

# Optional: explicit AMI ID for EC2/bastion. If null, Rocky Linux 9.6 will be looked up.
variable "ec2_ami_id" {
  description = "Optional explicit AMI ID to use for EC2 and bastion. If null, Terraform will try to find Rocky Linux 9.6 automatically."
  type        = string
  default     = null
}

# Optional: name of an existing EC2 Key Pair for SSH access.
variable "ec2_key_name" {
  description = "Name of an existing EC2 Key Pair to enable SSH access."
  type        = string
  default     = null
}

############################################
# Storage (EFS)
############################################

# Enable creation of a third EFS "archive" (in addition to data and config).
variable "enable_efs_archive" {
  description = "Whether to create an optional third EFS filesystem named 'archive'."
  type        = bool
  default     = false
}

# Create EFS mount targets only in a single AZ (first private subnet) to reduce costs
variable "efs_single_az_mount_targets" {
  description = "When true, create EFS mount targets only in the first private subnet (single AZ)."
  type        = bool
  default     = false
}

# EFS throughput configuration
# efs_throughput_mode options:
# - "bursting"    (default): Baseline scales with filesystem size with short bursts.
# - "provisioned": Fixed throughput in MiB/s regardless of size; set efs_provisioned_throughput_mibps.
# - "elastic"     : Auto-scales throughput based on workload; billed per usage.
# Throughput mode for all EFS: bursting | provisioned | elastic.
variable "efs_throughput_mode" {
  description = "EFS throughput mode for all EFS filesystems: bursting | provisioned | elastic."
  type        = string
  default     = "bursting"
  validation {
    condition     = contains(["bursting", "provisioned", "elastic"], var.efs_throughput_mode)
    error_message = "efs_throughput_mode must be one of: bursting, provisioned, elastic."
  }
}

# When throughput mode = provisioned: how many MiB/s to reserve.
variable "efs_provisioned_throughput_mibps" {
  description = "Provisioned throughput in MiB/s when efs_throughput_mode = 'provisioned' (e.g., 32)."
  type        = number
  default     = null
}

############################################
# Databases (RDS MySQL)
############################################

# Master username for RDS MySQL.
variable "db_username" {
  description = "Master username for RDS MySQL."
  type        = string
  default     = "admin"
}

# Master password for RDS MySQL (sensitive; pass securely via TF_VAR or SSM/Secrets).
variable "db_password" {
  description = "Master password for RDS MySQL. Use a secret manager in production."
  type        = string
  sensitive   = true
}

# RDS instance class (e.g., db.t3.micro).
variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

# Initial RDS storage size in GB.
variable "db_allocated_storage" {
  description = "RDS storage in GB."
  type        = number
  default     = 20
}

# Maximum storage in GB for autoscaling (enables automatic growth beyond allocated).
variable "db_max_allocated_storage" {
  description = "RDS max storage in GB for autoscaling. When set (> allocated), enables storage autoscaling up to this limit."
  type        = number
  default     = 100
}

# RDS storage type options:
# - gp3 (recommended): configurable IOPS and throughput, better price/perf.
# - gp2: legacy general purpose SSD (fixed IOPS baseline by size).
# - io1/io2: provisioned IOPS (set db_iops); higher performance and cost.

variable "db_storage_type" {
  description = "RDS storage type: gp3 | gp2 | io1 | io2."
  type        = string
  default     = "gp3"
  validation {
    condition     = contains(["gp3", "gp2", "io1", "io2"], var.db_storage_type)
    error_message = "db_storage_type must be one of: gp3, gp2, io1, io2."
  }
}

# Provisioned IOPS: required for io1/io2; optional for gp3.
variable "db_iops" {
  description = "Provisioned IOPS. Required when db_storage_type is io1/io2. Optional for gp3."
  type        = number
  default     = null
}

# Storage throughput (MB/s) — gp3 only.
variable "db_storage_throughput" {
  description = "Storage throughput in MB/s (only for gp3, not necessary but recommended)."
  type        = number
  default     = null
}

# Enable RDS Multi-AZ (creates a synchronous standby in another AZ).
variable "db_multi_az" {
  description = "Whether to enable RDS Multi-AZ for the MySQL instance."
  type        = bool
  default     = false
}

############################################
# Caching (ElastiCache Redis)
############################################

# ElastiCache Redis node type (e.g., cache.t3.micro).
variable "redis_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t3.micro"
}

# Redis engine version.
variable "redis_engine_version" {
  description = "Redis engine version."
  type        = string
  default     = "7.0"
}

############################################
# Load Balancing / Certificates
############################################

# ACM certificate for HTTPS on ALB (if null, only HTTP is enabled).
variable "alb_certificate_arn" {
  description = "ACM certificate ARN for HTTPS on ALB."
  type        = string
  default     = null
}

# Optional: attach AWS WAFv2 Web ACL to the ALB (REGIONAL scope only)
variable "waf_web_acl_arn" {
  description = "Optional ARN of an existing AWS WAFv2 Web ACL (REGIONAL) to associate with the ALB."
  type        = string
  default     = null
}

# If true, create a basic AWS WAFv2 Web ACL (REGIONAL) with common managed rule groups and attach to ALB.
variable "enable_waf_basic" {
  description = "Create a basic AWS WAFv2 Web ACL (REGIONAL) with AWS managed rule groups and attach it to ALB when waf_web_acl_arn is not provided."
  type        = bool
  default     = false
}

############################################
# Email Amazon SES (optional)
############################################

# Enable Amazon SES configuration (identities + send policy for EC2).
variable "enable_ses" {
  description = "Enable Amazon SES setup (identity and permissions)."
  type        = bool
  default     = false
}

# Which SES identity type to verify: "email" or "domain".
variable "ses_identity_type" {
  description = "SES identity type to verify: 'email' or 'domain'."
  type        = string
  default     = "email"
  validation {
    condition     = contains(["email", "domain"], var.ses_identity_type)
    error_message = "ses_identity_type must be 'email' or 'domain'."
  }
}


# Optional Hosted Zone ID to auto-create SES TXT/CNAME records for all domains.
variable "ses_route53_zone_id" {
  description = "Optional Route53 Hosted Zone ID for creating SES DNS records automatically for domain identity."
  type        = string
  default     = null
}

# New: support multiple identities
# List of SES email identities to verify.
variable "ses_email_identities" {
  description = "List of email identities to verify for SES."
  type        = list(string)
  default     = []
}

# List of SES domains to verify.
variable "ses_domain_identities" {
  description = "List of domains to verify for SES."
  type        = list(string)
  default     = []
}

# Optional map domain => Hosted Zone ID (overrides ses_route53_zone_id per domain).
variable "ses_route53_zone_ids" {
  description = "Optional map of domain => Route53 Hosted Zone ID for creating SES DNS records per domain. If provided, overrides ses_route53_zone_id for matching domains."
  type        = map(string)
  default     = {}
}

############################################
# Remote Access - Bastion Host (optional)
############################################

# Create an optional bastion (SSM‑only, no public IP, no inbound SSH).
variable "create_bastion" {
  description = "Whether to create a small bastion host in a public subnet for troubleshooting."
  type        = bool
  default     = false
}

# EC2 instance type for the bastion.
variable "bastion_instance_type" {
  description = "Bastion EC2 instance type (SSM-only bastion)."
  type        = string
  default     = "t3.micro"
}

############################################
# Remote Access - SSH (optional)
############################################

# Enable direct SSH (port 22) to EC2; when false, the SSH ingress rule is omitted.
variable "enable_ssh_access" {
  description = "Enable direct SSH (port 22) to EC2 instances. When false, SSH ingress is not created."
  type        = bool
  default     = false
}

# CIDR allowed for SSH access (narrow this; prefer SSM in production).
variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH to instances (for bastion or SSM optional)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

############################################
# Remote Access - Client VPN (optional)
############################################

# Enable AWS Client VPN endpoint and related resources.
variable "enable_client_vpn" {
  description = "Whether to create the AWS Client VPN endpoint and related resources."
  type        = bool
  default     = false
}

# CIDR pool for VPN clients (RFC1918, must not overlap with VPC/on‑prem).
variable "client_vpn_cidr" {
  description = "CIDR range for client VPN. Must be from RFC1918 and non-overlapping."
  type        = string
  default     = "172.16.0.0/22"
}

# ACM server certificate for the Client VPN endpoint.
variable "client_vpn_certificate_arn" {
  description = "ACM server certificate for the Client VPN endpoint."
  type        = string
}

# ACM certificate ARN for the client certificate root CA (mutual TLS).
variable "client_vpn_client_root_certificate_arn" {
  description = "ACM certificate ARN for the client certificate root CA used for mutual TLS auth."
  type        = string
  default     = null
}

# Optional SAML provider ARN for federated auth (instead of mutual TLS).
variable "client_vpn_auth_saml_provider_arn" {
  description = "Optional SAML provider ARN for federated auth; if null, will use mutual cert auth only."
  type        = string
  default     = null
}