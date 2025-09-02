# AWS VPC + EC2 + EFS x2 + RDS MySQL + ElastiCache Redis + ALB/NLB + Client VPN

This Terraform stack creates:
- VPC with public and private subnets (2 AZs)
- EC2 instance in private subnet (with SSM, mounts two EFS: data and config)
- EFS filesystems (data, config) with mount targets in private subnets
- RDS MySQL in private subnets
- ElastiCache Redis in private subnets
- ALB for HTTP/HTTPS to EC2, NLB for TCP ports: 25, 465, 587, 143, 993, 110, 995
- AWS Client VPN endpoint associated to public subnets for access into VPC

See also: ARCHITECTURE.md for a Mermaid diagram of the architecture.
See also: SERVICES.md for usage of services and AZ behavior.

### Utilities
- scripts/list-ips.sh — vypíše všechny přidělené IP adresy (privátní, veřejné, IPv6) v nasazené VPC.
	- Příklad: `scripts/list-ips.sh --just-ips`

## Usage

1. Export AWS credentials (or use a named profile) and set required variables.
2. Initialize and apply.

### Quick start

Create a `terraform.tfvars` file, e.g.:

```
project               = "iw"
environment           = "dev"
aws_region            = "eu-central-1"
# Provide an ACM certificate for HTTPS on ALB if desired
alb_certificate_arn   = null
# Required: ACM server certificate for Client VPN
client_vpn_certificate_arn = "arn:aws:acm:..."
# Provide DB password securely (example only)
db_password           = "ChangeMe123!"
# Optional SSH key pair name
# ec2_key_name        = "my-key"
# Scale EC2 instances
ec2_instance_count    = 2

# Optional SES configuration
# enable_ses          = true
# ses_identity_type   = "email"          # or "domain"
# ses_email_identity  = "user@example.com"  # when identity_type = email
# ses_domain          = "example.com"       # when identity_type = domain
# ses_route53_zone_id = "Z1234567890"       # to auto-create TXT/CNAME records
```

Then:

```
terraform init
terraform plan
terraform apply
```

## Notes
- Private EC2 instances have Internet egress via NAT Gateways in each public subnet (HA egress).
- Security is permissive for demo. Tighten CIDR ranges and consider SSM-only access (disable SSH).
- SSH access is disabled by default. To enable direct SSH to EC2, set `enable_ssh_access = true` and adjust `allowed_ssh_cidr`.
- For production, place EC2 behind Auto Scaling groups and use Target Group health checks.
- Provide a valid certificate in ACM for the Client VPN endpoint and optionally a SAML provider ARN to use federated auth.
- Ensure the Client VPN CIDR doesn’t overlap with your VPC or on-prem networks.

### Optional Client VPN
To enable Client VPN resources, set:
```
enable_client_vpn              = true
client_vpn_certificate_arn     = "arn:aws:acm:..."
# Optionally use SAML instead of mutual TLS
# client_vpn_client_root_certificate_arn = "arn:aws:acm:..."
# client_vpn_auth_saml_provider_arn      = "arn:aws:iam::123456789012:saml-provider/YourIdP"
```

## Clean up
```
terraform destroy
```
