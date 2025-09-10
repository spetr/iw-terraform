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

# CIDR list for public subnets (ALB/NLB, NAT Gateway, IGW).
variable "public_subnets" {
  description = "List of public subnet CIDRs (routed to IGW). Typically one per AZ (e.g., 2 items for 2 AZs). Used for NLB, NAT, Client VPN."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

# CIDR list for private subnets (EC2, RDS, Valkey, EFS; egress via NAT).
variable "private_subnets" {
  description = "List of private subnet CIDRs (no public IPs; egress via NAT). Hosts EC2, RDS, Valkey, EFS."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

# Optional list of AZs; if empty, the first 2 available will be used.
variable "availability_zones" {
  description = "AZs to use. If empty, the first 2 available AZs in the region will be used."
  type        = list(string)
  default     = []
}


############################################
# Compute (EC2) & Access
############################################

# App instance type for EC2 app instances (e.g., t3.small).
variable "app_instance_type" {
  description = "EC2 instance type for App instances (behind ALB)."
  type        = string
  default     = "t3.small"
}

# Number of app EC2 instances (spread across private subnets/AZs).
variable "app_instance_count" {
  description = "Number of App EC2 instances. Affects HA (NAT per‑AZ, EFS MTs, RDS Multi‑AZ, Valkey App HA)."
  type        = number
  default     = 1
}

# Optional: explicit AMI ID for App EC2 only. Others use Amazon Linux 2023 via SSM.
variable "app_ami_id" {
  description = "Optional explicit AMI ID to use for App EC2 instances only. Bastion and Fulltext always use AL2023 via SSM."
  type        = string
  default     = null
}

# Instance type for the dedicated fulltext EC2.
variable "fulltext_instance_type" {
  description = "Instance type for the Fulltext EC2 instance(s)."
  type        = string
  default     = "t4g.small"
}

# EBS volume size (GiB) for the fulltext EC2 instance.
variable "fulltext_ebs_size_gb" {
  description = "EBS size in GiB per Fulltext EC2 instance (one volume per instance)."
  type        = number
  default     = 1
  validation {
    condition     = var.fulltext_ebs_size_gb >= 1 && var.fulltext_ebs_size_gb <= 16384
    error_message = "fulltext_ebs_size_gb must be between 1 and 16384 GiB."
  }
}

# Number of dedicated fulltext EC2 instances.
variable "fulltext_instance_count" {
  description = "Number of Fulltext EC2 instances (each gets its own EBS). When >= 2, a dedicated HA Valkey for Fulltext is created."
  type        = number
  default     = 0
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
  description = "Create optional third EFS filesystem named 'archive' (disabled by default)."
  type        = bool
  default     = false
}

## EFS mount targets are created in a single AZ automatically when app_instance_count <= 1

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
# Databases (RDS MariaDB)
############################################

# Master username for RDS MariaDB.
variable "db_username" {
  description = "Master username for RDS MariaDB."
  type        = string
  default     = "admin"
}

# Master password for RDS MariaDB (sensitive; pass securely via TF_VAR or SSM/Secrets).
variable "db_password" {
  description = "Master password for RDS MariaDB. Use a secret manager in production."
  type        = string
  sensitive   = true
}

# Enhanced Monitoring interval for RDS (seconds). Set 0 to disable.
# Allowed values: 0, 1, 5, 10, 15, 30, 60
variable "db_monitoring_interval" {
  description = "RDS/MariaDB Enhanced Monitoring interval in seconds (0 disables)."
  type        = number
  default     = 60
  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.db_monitoring_interval)
    error_message = "db_monitoring_interval must be one of: 0, 1, 5, 10, 15, 30, 60."
  }
}

# RDS instance class (e.g., db.t4g.small).
variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
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

# Protect the RDS instance from accidental deletion.
variable "db_deletion_protection" {
  description = "Enable deletion protection on the RDS instance to prevent accidental deletes."
  type        = bool
  default     = true
}

# Max SQL connections (RDS MariaDB parameter group: max_connections)
variable "db_max_connections" {
  description = "Max SQL connections for MariaDB (RDS parameter 'max_connections'). Change requires DB reboot!!!"
  type        = number
  default     = 100
}

############################################
# Caching (ElastiCache Valkey)
############################################

# App Valkey
variable "valkey_app_node_type" {
  description = "ElastiCache node type for App Valkey (single node for 1 app; HA replication group when app_instance_count > 1)."
  type        = string
  default     = "cache.t4g.micro"
}

variable "valkey_app_engine_version" {
  description = "Valkey engine version for App cache (e.g., 8.1)."
  type        = string
  default     = "8.1"
}

# Fulltext Valkey
variable "valkey_fulltext_node_type" {
  description = "ElastiCache node type for Fulltext Valkey (created only when fulltext_instance_count >= 2; Multi‑AZ replication group)."
  type        = string
  default     = "cache.t4g.small"
}

variable "valkey_fulltext_engine_version" {
  description = "Valkey engine version for Fulltext cache (e.g., 8.1)."
  type        = string
  default     = "8.1"
}

############################################
# Load Balancing / Certificates
############################################

variable "acm_import_cert_file" {
  description = "Path to PEM certificate to import into ACM (e.g., scripts/service-certs/mail.example.com.crt)."
  type        = string
  default     = "scripts/service-certs/mail.example.com.crt"
}

variable "acm_import_key_file" {
  description = "Path to PEM private key to import into ACM (e.g., scripts/service-certs/mail.example.com.key)."
  type        = string
  default     = "scripts/service-certs/mail.example.com.key"
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

# Access logging for ALB/NLB (optional)
variable "enable_lb_access_logs" {
  description = "Enable access logging to S3 for both ALB and NLB. When true, lb_logs_bucket must be set."
  type        = bool
  default     = false
}

variable "lb_logs_bucket" {
  description = "S3 bucket name to store ALB/NLB access logs (must have appropriate bucket policy). Required if enable_lb_access_logs = true."
  type        = string
  default     = null
}

variable "lb_logs_prefix" {
  description = "Optional S3 key prefix for access logs. When null, a default is used: <project>/<environment>/<alb|nlb>."
  type        = string
  default     = null
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
  description = "Whether to create a small SSM‑only bastion host in a private subnet for troubleshooting."
  type        = bool
  default     = true
}

# EC2 instance type for the bastion.
variable "bastion_instance_type" {
  description = "Bastion EC2 instance type (SSM-only bastion). ARM64 (Graviton) recommended, e.g., t4g.micro."
  type        = string
  default     = "t4g.micro"
}

############################################
# Remote Access - SSH (optional)
############################################

# Enable direct SSH (port 22) to EC2; when false, the SSH ingress rule is omitted.
variable "enable_ssh_access" {
  description = "Enable direct SSH (port 22) to EC2 instances (in addition to SSM). When false, no SSH ingress is created."
  type        = bool
  default     = false
}

# CIDR allowed for SSH access (narrow this; prefer SSM in production).
variable "allowed_ssh_cidr" {
  description = "Allowed CIDR blocks for SSH access (tighten for production)."
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
  description = "ACM server certificate for the Client VPN endpoint. Required only when enable_client_vpn = true."
  type        = string
  default     = null
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
