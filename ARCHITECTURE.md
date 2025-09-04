# Architecture diagram

Aktuální architektura: public a private subnets, Global Accelerator se statickými IP před ALB/NLB a NAT Gateway pro egress privátních instancí.

```mermaid
flowchart LR
  Internet[[Internet]]
  Client[[Client VPN user]]

  subgraph AWS["AWS Account (Region)"]
    subgraph VPC["VPC (10.0.0.0/16)"]
      IGW["Internet Gateway"]

      subgraph Public["Public Subnets (AZ a,b)"]
        GA["AWS Global Accelerator (Anycast IPs)"]
        ALB["ALB (HTTP 80 → redirect to HTTPS 443; TLS via ACM)"]
        NLB["NLB (TCP: 25,465,587,143,993,110,995; TLS on 465/993/995 via ACM)"]
        NAT["NAT Gateway (per AZ or single by EC2 count)"]
        CVPN["Client VPN Endpoint"]
      end

      subgraph Private["Private Subnets (AZ a,b)"]
        EC2["EC2 App instance(s)"]
        Bastion["Bastion (SSM + optional SSH)"]
        EFS1["EFS (data)"]
        EFS2["EFS (config)"]
        RDS[("RDS MariaDB")]
        Redis[("ElastiCache Redis")]
      end
    end
  end

  %% Inbound from Internet
  Internet --> IGW
  IGW --> GA
  GA -->|80/443| ALB
  GA -->|25,465,587,143,993,110,995| NLB

  %% Load balancer to EC2
  ALB -->|"HTTP 80 (behind HTTPS)"| EC2
  NLB -->|"TCP mail ports"| EC2

  %% East-west inside VPC
  EC2 -- "NFS 2049" --> EFS1
  EC2 -- "NFS 2049" --> EFS2
  EC2 -->|"MariaDB/MySQL 3306"| RDS
  EC2 -->|"Redis 6379"| Redis

  %% Egress
  EC2 -->|egress| NAT --> IGW --> Internet

  %% VPN access into VPC
  Client --> CVPN --> Private
```

Legend
- Public subnets: GA, ALB/NLB, NAT GW, Client VPN assoc.
- Private subnets: EC2, RDS, Redis, EFS, Bastion (bez veřejné IP; přístup přes SSM; SSH volitelně dle flagu).
- Egress z privátních EC2 jde přes NAT Gateway do Internetu.
- S3 Gateway VPC Endpoint je připojen k private route tables.

Notes
- CIDR pro `public_subnets` a `private_subnets` jsou v `variables.tf`.
- NAT pravidlo: když `ec2_instance_count <= 1`, vytvoří se jedna NAT GW v public[0]; když je `ec2_instance_count > 1`, vytvoří se NAT GW v každé public subnet a private RTs routují per‑AZ.
- EFS MT pravidlo: když `ec2_instance_count <= 1`, EFS má mount target jen v první private subnet; jinak v každé private subnet (per‑AZ).
- Security Groups definované v `network.tf` omezují provoz; ICMP v rámci VPC je povolen pro diagnostiku.
 - SSH přístup: když `enable_ssh_access = true`, otevře se port 22 v SG pro EC2 (`allowed_ssh_cidr`) a volitelně i pro bastion SG.
 - Hostname: EC2 app i bastion si při bootstrapu nastaví hostname podle Name tagu a zachovají jej napříč rebooty.
