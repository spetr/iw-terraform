# Architecture diagram

Below is a Mermaid diagram showing the components and how they connect within AWS.

```mermaid
flowchart LR
  Internet[[Internet]]
  Client[[Client VPN user]]

  subgraph AWS["AWS Account (Region)"]
    subgraph VPC["VPC (10.0.0.0/16)"]
      IGW["Internet Gateway"]

      subgraph Public["Public Subnets (AZ a,b)"]
        ALB["ALB (HTTP/HTTPS)"]
        NLB["NLB (TCP: 25,465,587,143,993,110,995)"]
        NAT["NAT Gateway (per AZ)"]
        CVPN["Client VPN Endpoint"]
        EC2P["EC2 (public-facing representation)"]
      end

      subgraph Private["Private Subnets (AZ a,b)"]
        EC2["EC2 App instance(s)"]
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

  %% Load balancer to EC2 (public representation)
  ALB -->|HTTP 80| EC2P
  NLB -->|TCP mail ports| EC2P
  EC2P -. same instances -.-> EC2

  %% East-west inside VPC
  EC2 -- "NFS 2049" --> EFS1
  EC2 -- "NFS 2049" --> EFS2
  EC2 -->|"MySQL 3306"| RDS
  EC2 -->|"Redis 6379"| Redis

  %% Egress
  EC2 -->|egress| NAT
  NAT --> IGW
  IGW --> Internet

  %% VPN access into VPC
  Client --> CVPN --> Private

  classDef ghost fill:#ffffff,stroke:#888,stroke-dasharray: 5 5,color:#666;
  class EC2P ghost;
```

Legend
- EC2P is jen vizuální zobrazení EC2 „na hraně“ veřejné vrstvy (ve skutečnosti běží v private subnets, publikováno přes ALB/NLB).
- ALB terminates HTTP/HTTPS a předává HTTP 80 na EC2.
- NLB předává TCP pro mail protokoly přímo na EC2.
- EC2 mountuje obě EFS (data/config) přes NFS 2049.
- EC2 přistupuje k RDS na 3306 a k Redis na 6379.
- Egress z EC2 jde přes NAT Gateway do Internetu.
- Client VPN endpoint umožňuje přístup do VPC subnetů.

Notes
- Skutečné názvy AZ a subnet CIDRs jsou v `variables.tf`.
- Security Groups omezují provoz dle konfigurace v `network.tf`.
