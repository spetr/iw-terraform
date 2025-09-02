# Jak používat služby připojené k EC2 a dostupnost (AZ)

Tento dokument popisuje, jak se připojit k jednotlivým službám připojeným k EC2 instanci a jak funguje dostupnost napříč Availability Zones (AZ).

## Předpoklady
- Infrastruktura je nasazená (`terraform apply`).
- Máte nastavené AWS přihlašovací údaje (profil/region).
- Pro soukromé endpointy (RDS/Redis/EFS) jste v síti VPC (např. přes Client VPN nebo z EC2).

Užitečné výstupy z Terraformu:
- ALB DNS: `terraform output -raw alb_dns_name`
- NLB DNS: `terraform output -raw nlb_dns_name`
- RDS endpoint: `terraform output -raw rds_endpoint`
- Redis endpoint: `terraform output -raw redis_endpoint`
- EFS (data): `terraform output -raw efs_data_id`
- EFS (config): `terraform output -raw efs_config_id`

---

## HTTP/HTTPS přes ALB
- Veřejný vstup pro webovou/app vrstvu.
- HTTP 80 je vždy aktivní; HTTPS 443 vyžaduje platný ACM certifikát (proměnná `alb_certificate_arn`).

Příklad testu
```bash
# HTTP
curl -I "http://$(terraform output -raw alb_dns_name)"

# HTTPS (pokud je nakonfigurován certifikát)
curl -Ik "https://$(terraform output -raw alb_dns_name)"
```

Dostupnost (AZ)
- ALB je nasazen v obou public subnets (2 AZ). Při výpadku jedné AZ zůstává provoz dostupný přes druhou AZ.

---

## Mail protokoly přes NLB (TCP)
- NLB publikuje: SMTP(25), SMTPS(465), Submission(587), IMAP(143), IMAPS(993), POP3(110), POP3S(995).
- NLB přeposílá TCP přímo na EC2 instance (v privátní síti). Zabezpečení a protokoly řeší aplikace na EC2.

Příklady testu
```bash
# SMTPS (465) – TLS handshake
openssl s_client -connect "$(terraform output -raw nlb_dns_name)":465 -servername test

# SMTP (25)
nc -vz "$(terraform output -raw nlb_dns_name)" 25
```
Pozn.: Odchozí port 25 může být v AWS účtech omezen – běžná praxe je používat 587 s autentizací/TLS.

Dostupnost (AZ)
- NLB je multi‑AZ (v obou public subnets). Při výpadku AZ obsluhuje druhá AZ.

---

## Amazon SES (volitelné)
- Regionální služba; není AZ‑specifická (vysoká dostupnost zajišťuje AWS).
- Lze ověřit e‑mailovou adresu nebo doménu.
- Při doméně doporučeno nastavit DKIM (CNAME) a SPF (TXT) pro doručitelnost.

Příklad odeslání (AWS CLI)
```bash
aws ses send-email \
	--from "user@example.com" \
	--destination ToAddresses="target@example.com" \
	--message Subject='{Data="Test"}',Body='{Text={Data="Hello"}}'
```

Pozn.: EC2 role má při `enable_ses=true` připojenou policy s `ses:SendEmail`/`ses:SendRawEmail`.

---

## RDS MySQL (privátní)
- Endpoint je neveřejný; připojení pouze z VPC (EC2/VPN).
- Přihlašovací údaje: `db_username` a `db_password` (proměnné Terraformu).

Příklad připojení
```bash
mysql -h "$(terraform output -raw rds_endpoint)" -u "$DB_USER" -p
```

Dostupnost (AZ)
- Konfigurace v repu je single‑AZ. Pro vyšší dostupnost zapněte Multi‑AZ (RDS) – zajistí standby instanci v jiné AZ a automatický failover.

---

## ElastiCache Redis (privátní)
- Endpoint je neveřejný; přístup pouze z VPC (EC2/VPN).

Příklad připojení
```bash
redis-cli -h "$(terraform output -raw redis_endpoint)" -p 6379 ping
```

Dostupnost (AZ)
- Aktuálně single‑node. Pro HA použijte Replication Group s Multi‑AZ (primary + replica, automatic failover).

---

## EFS (data, config) – NFS
- EC2 mountuje EFS pomocí `amazon-efs-utils` (typ `efs`, volba `tls`).
- Mount se provádí v user_data; pro ruční mount:

```bash
sudo dnf install -y amazon-efs-utils nfs-utils
sudo mkdir -p /mnt/data /mnt/config
sudo mount -t efs -o tls $(terraform output -raw efs_data_id):/ /mnt/data
sudo mount -t efs -o tls $(terraform output -raw efs_config_id):/ /mnt/config
```

Dostupnost (AZ)
- EFS má mount target v každé private subnet (v každé AZ). EFS mount helper automaticky volí lokální MT v téže AZ; při výpadku přejde na jiný MT.

---

## Client VPN
- Přístup do VPC z klientského zařízení. Vyžaduje serverový certifikát (ACM) a klientský root CA (nebo SAML autentizaci).
- Po připojení je dostupná privátní síť (EC2, RDS, Redis, EFS) dle SG/route pravidel.

Dostupnost (AZ)
- Endpoint je asociován do public subnets v obou AZ, takže připojení zůstává dostupné i při výpadku jedné AZ.

---

## EC2 přístup (SSM/SSH)
- EC2 instance mají roli s `AmazonSSMManagedInstanceCore` – můžete použít SSM Session Manager (nepotřebujete veřejné IP).
```bash
# příklad: otevřít shell na jedné z instancí (ID z outputs – ec2_instance_ids)
aws ssm start-session --target <INSTANCE_ID>
```
- SSH je povolené v SG (port 22) podle `allowed_ssh_cidr`. Pro produkci zvažte SSM‑only a zrušení 22 z Internetu.

### Bastion (SSM‑only)
- Volitelný bastion (`create_bastion = true`) je EC2 v privátní subnet, bez veřejné IP a bez otevřeného SSH.
- Přístup výhradně přes SSM Session Manager.

Připojení
```bash
# Bastion ID
terraform output -raw bastion_instance_id

# Otevřít relaci na bastionu
aws ssm start-session --target $(terraform output -raw bastion_instance_id)

# Port-forward (např. na cílový host v privátní síti přes bastion)
aws ssm start-session \
	--target $(terraform output -raw bastion_instance_id) \
	--document-name AWS-StartPortForwardingSessionToRemoteHost \
	--parameters host="10.0.10.100",portNumber="3306",localPortNumber="3306"
```

Požadavky účtu (SSM)
- EC2 IAM role: `AmazonSSMManagedInstanceCore` (v repo nastaveno).
- Odchozí přístup z privátní sítě na SSM endpointy (přes NAT nebo VPC endpoints: `com.amazonaws.<region>.ssm`, `ssmmessages`, `ec2messages`).
- Uživatelé/IAM: oprávnění `ssm:StartSession`, `ssm:DescribeInstanceInformation`, případně `ssm:SendCommand`.
- (Volitelné) Logování relací do CloudWatch/S3 a KMS šifrování.

---

## Egress z privátní sítě
- Každá private subnet má default route na NAT Gateway ve stejné AZ (HA egress).

---

## Tipy pro produkci
- RDS: zapnout Multi‑AZ, zvýšit retention a parametrické skupiny dle potřeby.
- Redis: použít Replication Group + Multi‑AZ a parametry (AOF/RDB) dle SLA.
- EC2: Auto Scaling Group + Launch Template + health checks ALB.
- SG a NACL: zpřísnit zdrojové rozsahy, audit.
- Monitoring: CloudWatch Alarms, VPC Flow Logs, ELB access logs.

---

## Troubleshooting
- DNS/LB: `dig +short $(terraform output -raw alb_dns_name)`
- Síť: `scripts/list-ips.sh --just-ips` vypíše všechny IP ve VPC.
- EFS: `mount | grep efs`, `systemctl status` pro služby, `aws efs describe-mount-targets`.
- RDS/Redis: ověřit SG, DNS, směrování (Client VPN), případně EC2 jako bastion.
