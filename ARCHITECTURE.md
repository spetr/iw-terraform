# Architecture diagram

Aktuální architektura: public a private subnets, public NLB s Elastic IP adresami, který předává porty 80/443 na interní ALB; NAT Gateway pro egress privátních instancí.

```mermaid
flowchart TD
  Internet[[Internet]]

  subgraph AWS["AWS Account (Region)"]
  subgraph VPC["VPC (10.0.0.0/16)"]
      IGW["Internet Gateway"]

      subgraph Public["Public Subnets (AZ a,b)"]
        NLB["Public NLB (EIP) - TCP 80/443 + mail ports"]
        NAT["NAT Gateway (per AZ or single by EC2 count)"]
        CVPN["Client VPN Endpoint"]
      end

      subgraph Private["Private Subnets (AZ a,b)"]
        ALB["Internal ALB (HTTP 80 → redirect to HTTPS 443; TLS via ACM)"]
        EC2["EC2 App instance(s)"]
        ECS["ECS Fargate (docconvert)"]
        FT["Fulltext EC2 instance(s)"]
        ZBX["Zabbix Proxy (EC2, active)"]
        Bastion["Bastion (SSM + optional SSH)"]
        EFS1["EFS (data)"]
        EFS2["EFS (config)"]
        EFS3["EFS (archive)"]
        RDS[("RDS MariaDB")]
        ValkeyApp[("ElastiCache Valkey (App)")]
        ValkeyFT[("ElastiCache Valkey (Fulltext)")]
        EBSFT["EBS Volume(s) for Fulltext"]
      end
    end
    SES["Amazon SES"]
    ZabbixSrv["Zabbix Server (external)"]
  end

  Internet <--> IGW

  %% Inbound from Internet
  IGW --> NLB
  NLB -->|"TCP 80/443 passthrough"| ALB
  NLB -->|"TCP mail ports (25,465,587,143,993,110,995)"| EC2

  %% Load balancer to EC2
  ALB -->|"HTTP 80 (behind HTTPS)"| EC2

  %% EC2 app calls private ECS service via Cloud Map
  EC2 -->|"HTTP 25798 (docconvert.svc.local)"| ECS

  %% East-west inside VPC
  EC2 -- "NFS 2049" --> EFS1
  EC2 -- "NFS 2049" --> EFS2
  EC2 -- "NFS 2049" --> EFS3
  EC2 -->|"MariaDB/MySQL 3306"| RDS
  EC2 -->|"Valkey/Redis 6379"| ValkeyApp
  FT  -->|"Valkey/Redis 6379"| ValkeyFT
  EC2 -->|"HTTP 80/443"| FT

  %% App to SES (API/SMTP) – via NAT egress
  EC2 -->|"SES API/SMTP 443/587"| SES

  %% Egress
  EC2 -->|egress| NAT --> IGW
  ECS -->|egress| NAT
  ZBX -->|egress TCP 10051| NAT --> IGW --> ZabbixSrv

  %% Fulltext storage attachment
  FT -- "/dev/sdf" --> EBSFT

  %% VPN access into VPC
  Internet --> CVPN
  CVPN --> Private

  %% Styling for optional components
  classDef optional fill:#f7f7f7,stroke:#888,stroke-width:1px,stroke-dasharray: 5 5,color:#333
  class EFS3,ValkeyFT,SES,CVPN,Bastion,ZBX optional
```

Legend
- Public subnets: NLB (EIP), NAT GW, Client VPN assoc.
- Private subnets: Internal ALB, EC2, ECS Fargate (docconvert), RDS, Valkey (App/Fulltext), EFS, Bastion (bez veřejné IP; přístup přes SSM; SSH volitelně dle flagu).
- Egress z privátních EC2 jde přes NAT Gateway do Internetu.
- S3 Gateway VPC Endpoint je připojen k private route tables.
- Uzly se zvýrazněným (čárkovaným) okrajem jsou nepovinné a vytvářejí se jen při zapnutí příslušných voleb (např. EFS archive, Valkey pro Fulltext).

- Vždy nasazeno: VPC, public/private subnets, IGW, NLB, ALB (internal), EC2 App, ECS Fargate (docconvert), RDS, Valkey (App – single/HA dle počtu app instancí), EFS (data, config), NAT (single nebo per‑AZ podle `app_instance_count`).
- Volitelné: Bastion (SSM‑only), Client VPN endpoint, EFS archive, Valkey (Fulltext, HA), Amazon SES, Fulltext EC2 + jeho EBS svazky (dle `fulltext_instance_count`).
 - Zabbix Proxy (active): volitelný; nasazuje se jako EC2 v privátní síti a navazuje odchozí spojení na externí Zabbix Server (`zabbix_server`). Umožňuje monitoring EC2, RDS a služby docconvert (ECS) přes SG pravidla.
 - Amazon SES: volitelný; aplikace odesílá přes AWS SDK (HTTPS) nebo SMTP, odesílatel musí být ověřen (email/doména, DKIM doporučeno).

Notes
- CIDR pro `public_subnets` a `private_subnets` jsou v `variables.tf`.
- NAT pravidlo: když `app_instance_count <= 1`, vytvoří se jedna NAT GW v public[0]; když je `app_instance_count > 1`, vytvoří se NAT GW v každé public subnet a private RTs routují per‑AZ.
- EFS MT pravidlo: když `app_instance_count <= 1`, EFS má mount target jen v první private subnet; jinak v každé private subnet (per‑AZ).
- Valkey (App): když `app_instance_count <= 1`, jednonodový cluster; když `app_instance_count > 1`, Multi‑AZ replication group s automatickým failoverem.
- Valkey (Fulltext): vytváří se jen když `fulltext_instance_count >= 2` a nasazuje se jako Multi‑AZ replication group.
- Security Groups definované v `network.tf` omezují provoz; ICMP v rámci VPC je povolen pro diagnostiku.
 - Zabbix Proxy: zapíná se přes `zabbix_proxy_enabled = true`; nastavte `zabbix_server` (DNS/IP externího serveru) a případně `zabbix_proxy_hostname`. SG dovolují přístup z proxy na EC2 (monitoring), RDS (TCP 3306) a ECS docconvert.
 - SSH přístup: když `enable_ssh_access = true`, otevře se port 22 v SG pro EC2 (`allowed_ssh_cidr`) a volitelně i pro bastion SG.
 - Hostname: EC2 app i bastion si při bootstrapu nastaví hostname podle Name tagu a zachovají jej napříč rebooty.
 - ECS docconvert: běží jako Fargate v private subnets, bez ALB; přístupný jen z EC2 přes SG → SG na portu `docconvert_container_port` (default 8080). Název služby v privátním DNS (Cloud Map): `docconvert.<service_discovery_namespace>` (default `docconvert.svc.local`).
 - Cross‑account ECR: image `598044228206.dkr.ecr.eu-central-1.amazonaws.com/mundi/prod` je v jiném účtu; repozitář musí mít policy, která povolí pull pro tento účet/roli ECS execution. ECS execution role má `AmazonECSTaskExecutionRolePolicy` (auth do ECR, logy). ECS docconvert má Internet egress přes NAT; volitelně můžete nasadit VPC Interface Endpoints (`ecr.api`, `ecr.dkr`, `logs`) pro privátní přístup bez NAT.
