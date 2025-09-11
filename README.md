# AWS VPC + EC2 + EFS x2 + RDS MariaDB + ElastiCache Valkey + ALB/NLB + Client VPN

This Terraform stack creates:
- VPC with public and private subnets (2 AZs)
- EC2 instance in private subnet (with SSM, mounts two EFS: data and config)
- EFS filesystems (data, config) with mount targets in private subnets
- RDS MariaDB in private subnets
- ElastiCache Valkey in private subnets
- ALB for HTTP/HTTPS to EC2, NLB for TCP ports: 25, 465, 587, 143, 993, 110, 995
- ECS Fargate service (docconvert) in private subnets; consumed by EC2 app via Cloud Map (no Internet egress)
- AWS Client VPN endpoint associated to public subnets for access into VPC

See also: ARCHITECTURE.md for a Mermaid diagram of the architecture.
See also: SERVICES.md for usage of services and AZ behavior.

### ECS docconvert (private-only)

- Purpose: run a private Fargate service "docconvert" reachable only inside the VPC by EC2 app.
- Discovery: Cloud Map private DNS at `docconvert.<service_discovery_namespace>` (default `docconvert.svc.local`).
- Security: Internet egress from tasks via NAT Gateway (tasks in private subnets). EC2 SG allowed to reach task SG on `docconvert_container_port`.
- Cross-account ECR: image is pulled from `598044228206.dkr.ecr.eu-central-1.amazonaws.com/mundi/prod` (another account). The source ECR repo must allow this account to pull.
- Optionally, to avoid NAT egress you can use VPC Interface Endpoints: `com.amazonaws.<region>.ecr.api`, `com.amazonaws.<region>.ecr.dkr`, `com.amazonaws.<region>.logs`.

Variables (defaults shown):
```
docconvert_image            = "598044228206.dkr.ecr.eu-central-1.amazonaws.com/mundi/prod:2.27.18"  # repo only or repo:tag
docconvert_container_port   = 25798
docconvert_cpu              = 256
docconvert_memory           = 512
docconvert_desired_count    = 1
service_discovery_namespace = "svc.local"
```
Usage from EC2 app:
```
curl http://docconvert.svc.local:8080/health
```

### Utilities
- scripts/list-ips.sh — vypíše všechny přidělené IP adresy (privátní, veřejné, IPv6) v nasazené VPC.
	- Příklad: `scripts/list-ips.sh --just-ips`
- scripts/unlock-tf.sh — zruší zaseknutý Terraform lock (lokální i DynamoDB).
	- Příklad: `scripts/unlock-tf.sh -y`

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
# Scale EC2 app instances
app_instance_count    = 2

# Optional SES configuration
# enable_ses            = true
# ses_identity_type     = "email"                # or "domain"
# # Emails
# ses_email_identities  = ["user1@example.com", "user2@example.com"]
# # Domains
# ses_domain_identities = ["example.com", "example.org"]
# # One zone for all domains, or per-domain mapping
# # ses_route53_zone_id = "Z1234567890"         # apply to all
# # ses_route53_zone_ids = {                     # overrides per domain
# #   "example.com" = "Z1111111111"
# #   "example.org" = "Z2222222222"
# # }

# Optional EFS archive
# enable_efs_archive = true

# EFS throughput configuration (applies to all EFS in this stack)
# efs_throughput_mode = "bursting"        # or "provisioned" | "elastic"
# efs_provisioned_throughput_mibps = 32    # required if mode = provisioned
```

Then:

```
terraform init
terraform plan
terraform apply
```

### Remote State (S3 + DynamoDB)

Pro produkční použití doporučuji ukládat Terraform state do S3 a zamykání přes DynamoDB.

1) Vytvořte S3 bucket a DynamoDB tabulku (jednorázově):

   - S3 bucket (zapněte versioning):
     - Name: např. `my-tfstate-bucket-name`
     - Region: např. `eu-central-1`
     - Versioning: Enabled
   - DynamoDB table pro zámky:
     - Name: `terraform-locks`
     - Partition key: `LockID` (String)

   Příklad přes AWS CLI:
   ```
   aws s3api create-bucket --bucket my-tfstate-bucket-name --region eu-central-1 \
     --create-bucket-configuration LocationConstraint=eu-central-1
   aws s3api put-bucket-versioning --bucket my-tfstate-bucket-name \
     --versioning-configuration Status=Enabled
   aws dynamodb create-table --table-name terraform-locks \
     --attribute-definitions AttributeName=LockID,AttributeType=S \
     --key-schema AttributeName=LockID,KeyType=HASH \
     --billing-mode PAY_PER_REQUEST --region eu-central-1
   ```

2) Zkopírujte `backend.hcl.example` → `backend.hcl` a vyplňte hodnoty:
   - `bucket` = jméno vašeho S3 bucketu
   - `key` = cesta k souboru se stavem, např. `iw/dev/terraform.tfstate`
   - `region` = region bucketu
   - `dynamodb_table` = `terraform-locks`
   - volitelně `profile`, `kms_key_id`

3) Inicializace s migrací stavu:
   - `./init.sh`
   - Skript detekuje `backend.hcl`, spustí `terraform init -reconfigure -migrate-state` a přesune lokální state do S3.

4) Ověření:
   - `terraform state list` – kontrola, že načítá vzdálený stav
   - ve S3 uvidíte `key` s verzováním; v DynamoDB záznamy zámků při běhu `plan/apply`.

Poznámky:
- `backend.hcl` je v `.gitignore` – necommitujte přístupové či environment‑specifické údaje.
- Pokud měníte backend nebo cestu `key`, znovu spusťte `./init.sh` (používá `-reconfigure`).

### ALB/NLB Access Logs (volitelné)

- Proměnné:
  - `enable_lb_access_logs` (bool): výchozí `false`.
  - `lb_logs_bucket` (string): S3 bucket pro logy (nutná správná bucket policy pro ELB log delivery).
  - `lb_logs_prefix` (string, volitelné): prefix v bucketu; pokud není, použije se `project/environment/alb` a `project/environment/nlb`.

- Příklad `terraform.tfvars`:
```
enable_lb_access_logs = true
lb_logs_bucket        = "my-elb-logs-bucket"
# lb_logs_prefix      = "custom/prefix"
```

- Poznámky:
  - Ujistěte se, že S3 bucket má povolen zápis z ELBv2 logovací služby (bucket policy). Viz dokumentace „Elastic Load Balancing access logs“ pro správný JSON.
  - Logy se ukládají zvlášť pro ALB i NLB (různý prefix).

## Notes
- AMI: Uses Amazon Linux 2023 by default (via SSM Parameter Store). No Marketplace subscription needed.
- Private EC2 instances have Internet egress via NAT Gateways in each public subnet (HA egress).
- Security is permissive for demo. Tighten CIDR ranges and consider SSM-only access (disable SSH).
- SSH access is disabled by default. To enable direct SSH to EC2, set `enable_ssh_access = true` and adjust `allowed_ssh_cidr`.
- For production, place EC2 behind Auto Scaling groups and use Target Group health checks.
- RDS: set db_max_allocated_storage to enable storage autoscaling, choose db_storage_type (gp3/gp2/io1/io2), and optionally tune db_iops/db_storage_throughput.
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

### HTTPS certifikát pro ALB (ACM)

Co je potřeba:
- Doména (např. `app.example.com`) a přístup k DNS (ideálně Route53 v téže AWS účtu/regionu jako ALB).

Postup:
1) ACM (Certificate Manager) v regionu nasazení ALB → Request public certificate.
	- Zadejte FQDN (např. `app.example.com` nebo `*.example.com`).
	- Zvolte DNS validation. Pokud máte Hosted Zone v Route53, ACM může vytvořit CNAME automaticky.
2) Po vystavení certifikátu zkopírujte jeho ARN a vložte do `terraform.tfvars`:
	- `alb_certificate_arn = "arn:aws:acm:<region>:<account>:certificate/<id>"`
3) `terraform apply` a v DNS vytvořte A/ALIAS záznam na hodnotu výstupu `alb_dns_name` (Route53: Alias na ALB).

Poznámka: Když `alb_certificate_arn = null`, ALB nasadí pouze HTTP (80).

### Certifikát pro Client VPN (server) a klientská autentizace

Client VPN endpoint vyžaduje v ACM serverový certifikát v tomtéž regionu. Autentizace může být:
- Mutual TLS (klientské certifikáty): potřebujete
  - server certifikát (ARN → `client_vpn_certificate_arn`),
  - root CA cert klientů (ARN → `client_vpn_client_root_certificate_arn`).
- SAML federace: stačí server certifikát (ARN → `client_vpn_certificate_arn`) a `client_vpn_auth_saml_provider_arn`.

Rychlý příklad (vlastní privátní CA pro Mutual TLS):
1) Vygenerujte CA a server certifikát (OpenSSL; zjednodušený příklad):
```
# Root CA (chránit soukromý klíč!)
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -subj "/CN=Example VPN Root CA" -out ca.crt

# Server key + CSR
openssl genrsa -out server.key 2048
openssl req -new -key server.key -subj "/CN=vpn.example.com" -out server.csr

# Podepište CSR root CA (přidejte SAN dle potřeby)
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 825 -sha256
```
2) Import do ACM (region Client VPN):
	- Server cert: ACM → Import certificate → `server.crt` (Certificate), `server.key` (Private key), `ca.crt` (Certificate chain, pokud relevantní).
	- Root CA klientů: ACM → Import certificate → `ca.crt` (jen certifikát; bez privátního klíče).
3) Do `terraform.tfvars` vložte:
```
client_vpn_certificate_arn              = "arn:aws:acm:<region>:<account>:certificate/<server-id>"
client_vpn_client_root_certificate_arn  = "arn:aws:acm:<region>:<account>:certificate/<ca-id>"
```
4) Vygenerujte klientské certifikáty podepsané stejnou CA (např. `client.key` + `client.crt`) a distribuujte uživatelům; vložte je do `client.ovpn` nebo nastavte v klientovi.

Poznámky:
- Certifikáty musí být v ACM ve stejném regionu jako ALB/Client VPN endpoint.
- Pro SAML není potřeba `client_vpn_client_root_certificate_arn` ani klientské certifikáty.

### Client VPN – konfigurace klienta (Windows, macOS)

Předpoklady:
- Endpoint je nasazen (`enable_client_vpn = true`).
- Používáte buď:
	- vzájemnou TLS autentizaci (server cert v ACM + klientský cert podepsaný stejným root CA jako `client_vpn_client_root_certificate_arn`), nebo
	- SAML federaci (`client_vpn_auth_saml_provider_arn`).

1) Získání klientské konfigurace (.ovpn)
- Konzole AWS: VPC → Client VPN Endpoints → váš endpoint → Download client configuration.
- Nebo AWS CLI:
	- (volitelné) uložte do souboru, např. `client.ovpn`.

2) Mutual TLS (klientský certifikát)
- Vytvořte klientský certifikát a privátní klíč podepsané vaším klientským root CA (stejným, který je v ACM jako root pro endpoint).
- Do `client.ovpn` vložte certifikát a klíč buď jako cesty:
	- `cert client.crt`
	- `key client.key`
	nebo přímo vložte bloky:
	- `<cert>...</cert>` a `<key>...</key>`

3) Windows
- Doporučeno: AWS VPN Client for Windows.
	- Stáhněte a nainstalujte (AWS Client VPN Desktop Application).
	- Add Profile → Importujte `client.ovpn` (pokud není cert zakomponován, vyberte klientský cert/klíč dle výzvy).
	- Connect.
- Alternativa: OpenVPN GUI – import `client.ovpn` a připojte se.

4) macOS
- Doporučeno: AWS VPN Client for macOS.
	- Nainstalujte, Add Profile → import `client.ovpn` (případně přiložte cert/klíč).
	- Connect.
- Alternativy: Tunnelblick/Viscosity – import `client.ovpn` a připojte se.

Poznámky k routování a DNS:
- Split tunneling je zapnutý; klient dostane výhradně trasy do VPC (`var.vpc_cidr`).
- Internetový provoz klienta zůstává mimo tunel (není přidána 0.0.0.0/0).
- Volitelné DNS servery jsou v endpointu nastaveny (`dns_servers`); klient je může použít pro dotazy k prostředkům ve VPC.

### SAML federace pro Client VPN (IAM + IdP)

Co budete potřebovat:
- IdP kompatibilní se SAML 2.0 (Azure AD, Okta, ADFS, …).
- V AWS IAM vytvořený SAML provider založený na metadatech z vašeho IdP.

Kroky v IdP (nová SAML aplikace pro AWS Client VPN):
1) Nastavte SSO/ACS URL (Assertion Consumer Service):
	 - `https://self-service.clientvpn.amazonaws.com/api/auth/sso/saml`
2) Audience/Entity ID (SP Entity ID):
	 - `urn:amazon:webservices:clientvpn`
3) NameID: běžně EmailAddress/Unspecified (dle IdP, nevyžaduje speciální formát).
4) Podepisujte SAML assertion (doporučeno).
5) Atributy (pro skupinové řízení přístupu): přidejte atribut např. `memberOf` (nebo `Groups`) s hodnotami názvů/skupin, které chcete používat pro autorizaci v Client VPN.
6) Exportujte metadata IdP (XML).

Kroky v AWS IAM:
1) IAM → Identity providers → Add provider → SAML.
2) Zadejte název, nahrajte metadata z předchozího kroku.
3) Uložte a poznamenejte si ARN providera.

V Terraformu (tento projekt):
- Do `terraform.tfvars` nastavte:
	- `client_vpn_auth_saml_provider_arn = "arn:aws:iam::<account-id>:saml-provider/<name>"`
- Serverový certifikát stále musí být v ACM: `client_vpn_certificate_arn = "arn:aws:acm:..."`.

Autorizace přístupu (skupiny vs. všichni):
- Tento stack defaultně povoluje všechny skupiny v rámci VPC (`authorize_all_groups = true`).
- Chcete‑li omezit dle skupin ze SAML assertion, upravte `aws_ec2_client_vpn_authorization_rule`:
	- nastavte `authorize_all_groups = false` a `access_group_id = "<název_skupiny_ze_SAML>"` (musí odpovídat hodnotě atributu, např. `memberOf`).

Důležité:
- SAML federace nepoužívá IAM uživatele. Uživatelé a jejich skupiny se spravují v IdP; v IAM pouze registrujete SAML provider a v Client VPN referencujete jeho ARN.

## Clean up

```
terraform destroy
```

data "aws_ssm_parameter" "al2023_ami" {
	name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

# v aws_instance:
# ami = data.aws_ssm_parameter.al2023_ami.value
