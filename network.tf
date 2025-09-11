data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 2)
  # Use a single NAT GW when only one EC2 app instance exists; otherwise one per AZ
  single_nat_effective = (var.app_instance_count <= 1)
}

resource "aws_vpc" "main" {
  cidr_block                       = var.vpc_cidr
  enable_dns_hostnames             = true
  enable_dns_support               = true
  assign_generated_ipv6_cidr_block = true

  tags = {
    Name = "${var.project}-${var.environment}-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-${var.environment}-igw"
  }
}

resource "aws_subnet" "public" {
  for_each                        = { for idx, cidr in var.public_subnets : idx => cidr }
  vpc_id                          = aws_vpc.main.id
  cidr_block                      = each.value
  availability_zone               = local.azs[tonumber(each.key)]
  map_public_ip_on_launch         = true
  assign_ipv6_address_on_creation = true
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.main.ipv6_cidr_block, 8, tonumber(each.key))

  tags = {
    Name = "${var.project}-${var.environment}-public-${each.key}"
  }
}

resource "aws_subnet" "private" {
  for_each                        = { for idx, cidr in var.private_subnets : idx => cidr }
  vpc_id                          = aws_vpc.main.id
  cidr_block                      = each.value
  availability_zone               = local.azs[tonumber(each.key)]
  assign_ipv6_address_on_creation = true
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.main.ipv6_cidr_block, 8, 100 + tonumber(each.key))

  tags = {
    Name = "${var.project}-${var.environment}-private-${each.key}"
  }
}

resource "aws_eip" "nat" {
  # vytvoř EIP pro všechny public subnety, nebo jen pro "0" když je single NAT
  for_each = { for k, s in aws_subnet.public : k => s if !local.single_nat_effective || k == "0" }

  domain = "vpc"
  tags = {
    Name = local.single_nat_effective ? "${var.project}-${var.environment}-nat-eip-0" : "${var.project}-${var.environment}-nat-eip-${each.key}"
  }
}

resource "aws_nat_gateway" "nat" {
  # stejné klíče jako u aws_eip.nat
  for_each = { for k, s in aws_subnet.public : k => s if !local.single_nat_effective || k == "0" }

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = each.value.id

  tags = {
    Name = "${var.project}-${var.environment}-nat-${each.key}"
  }
  depends_on = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.project}-${var.environment}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  for_each = aws_subnet.private
  vpc_id   = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = local.single_nat_effective ? aws_nat_gateway.nat["0"].id : aws_nat_gateway.nat[each.key].id
  }

  tags = {
    Name = "${var.project}-${var.environment}-private-rt-${each.key}"
  }
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# S3 Gateway VPC Endpoint for private subnets (reduces NAT usage for S3 traffic)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  # Associate with all private route tables
  route_table_ids = [for rt in aws_route_table.private : rt.id]

  tags = {
    Name = "${var.project}-${var.environment}-s3-endpoint"
  }
}

# Security groups
resource "aws_security_group" "ec2_sg" {
  name        = "${var.project}-${var.environment}-ec2"
  description = "EC2 SG"
  vpc_id      = aws_vpc.main.id

  dynamic "ingress" {
    for_each = var.enable_ssh_access ? [1] : []
    content {
      description      = "SSH"
      from_port        = 22
      to_port          = 22
      protocol         = "tcp"
      cidr_blocks      = var.allowed_ssh_cidr
      ipv6_cidr_blocks = []
    }
  }

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  # Allow ICMP (ping) from within the VPC so instances and bastion can reach each other
  ingress {
    description = "ICMP from VPC"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Allow all traffic from Zabbix Proxy for monitoring (app + fulltext share this SG)
  dynamic "ingress" {
    for_each = var.zabbix_proxy_enabled ? [1] : []
    content {
      description     = "All from Zabbix Proxy"
      from_port       = 0
      to_port         = 0
      protocol        = "-1"
      security_groups = [aws_security_group.zabbix_sg[0].id]
    }
  }

  # HTTPS is always handled by ALB; no NLB 443 passthrough needed

  dynamic "ingress" {
    for_each = toset([25, 465, 587, 143, 993, 110, 995])
    content {
      description = "Mail TCP port ${ingress.value} from anywhere (via NLB)"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project}-${var.environment}-ec2-sg"
  }
}

resource "aws_security_group" "alb_sg" {
  name        = "${var.project}-${var.environment}-alb"
  description = "ALB SG"
  vpc_id      = aws_vpc.main.id

  ingress {
    description      = "HTTP"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    description      = "HTTPS"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_security_group" "rds_sg" {
  name        = "${var.project}-${var.environment}-rds"
  description = "RDS SG"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "SQL 3306 from EC2"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }

  # Allow SQL from Zabbix Proxy for monitoring
  dynamic "ingress" {
    for_each = var.zabbix_proxy_enabled ? [1] : []
    content {
      description     = "SQL 3306 from Zabbix Proxy"
      from_port       = 3306
      to_port         = 3306
      protocol        = "tcp"
      security_groups = [aws_security_group.zabbix_sg[0].id]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "valkey_sg" {
  name        = "${var.project}-${var.environment}-valkey"
  description = "Valkey SG"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Valkey from EC2"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "efs_sg" {
  name        = "${var.project}-${var.environment}-efs"
  description = "EFS SG"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "NFS from EC2"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }

  # Allow NFS from bastion if created (useful for troubleshooting mounts from bastion)
  dynamic "ingress" {
    for_each = var.create_bastion ? [1] : []
    content {
      description     = "NFS from Bastion"
      from_port       = 2049
      to_port         = 2049
      protocol        = "tcp"
      security_groups = [aws_security_group.bastion_sg[0].id]
    }
  }

  # Allow NFS from Client VPN endpoint-associated ENIs when Client VPN is enabled
  dynamic "ingress" {
    for_each = var.enable_client_vpn ? [1] : []
    content {
      description     = "NFS from Client VPN"
      from_port       = 2049
      to_port         = 2049
      protocol        = "tcp"
      security_groups = [aws_security_group.client_vpn_sg[0].id]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "client_vpn_sg" {
  count       = var.enable_client_vpn ? 1 : 0
  name        = "${var.project}-${var.environment}-client-vpn"
  description = "Client VPN SG"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
