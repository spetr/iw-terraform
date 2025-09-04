# Architecture diagram

Následující Mermaid schéma zobrazuje architekturu po přechodu na jednu síť (sjednocené subnety, bez NATu a bez rozlišení public/private).

```mermaid
flowchart LR
  Internet[[Internet]]
  Client[[Client VPN user]]

  subgraph AWS["AWS Account (Region)"]
    subgraph VPC["VPC (10.0.0.0/16)"]
      IGW["Internet Gateway"]

      subgraph Unified["Unified Subnets (AZ a,b)"]
        ALB["ALB (HTTP/HTTPS)"]
        NLB["NLB (TCP: 25,465,587,143,993,110,995)"]
        EC2["EC2 App instance(s)"]
        Bastion["Bastion (SSM-only)"]
        CVPN["Client VPN Endpoint"]
        EFS1["EFS (data)"]
        EFS2["EFS (config)"]
        RDS[("RDS MySQL")]
        Redis[("ElastiCache Redis")]
      end
    end
  end

  %% Inbound from Internet
  Internet --> IGW
  IGW -->|80/443| ALB
  IGW -->|25,465,587,143,993,110,995| NLB

  %% Load balancers to EC2
  ALB -->|HTTP 80| EC2
  NLB -->|TCP mail ports| EC2

  %% East-west inside VPC
  EC2 -- "NFS 2049" --> EFS1
  EC2 -- "NFS 2049" --> EFS2
  EC2 -->|"MySQL 3306"| RDS
  EC2 -->|"Redis 6379"| Redis

  %% Egress (no NAT)
  EC2 -->|egress| IGW

  %% VPN access into VPC
  Client --> CVPN --> Unified
```

Legend
- Jediná sada „Unified Subnets“ slouží všem komponentám (ALB, NLB, EC2, RDS, Redis, EFS, Client VPN).
- ALB terminates HTTP/HTTPS a posílá HTTP 80 na EC2.
- NLB předává TCP pro mail protokoly přímo na EC2.
- EC2 mountuje EFS (data/config) přes NFS 2049; přistupuje k RDS (3306) a Redis (6379).
- Egress z EC2 jde přímo přes Internet Gateway (bez NAT Gateway).
- Client VPN endpoint je asociován do sjednocených subnetů.

Notes
- CIDR rozsahy sjednocených subnetů nastavíte ve `variables.tf` (`var.subnets`).
- Security Groups definované v `network.tf` omezují příchozí/příchozí provoz; povolen je ICMP v rámci VPC pro diagnostiku.
- Pro S3 je zřízen Gateway VPC Endpoint na route table sjednocené sítě (omezuje egress přes Internet).
