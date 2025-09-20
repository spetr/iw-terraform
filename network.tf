data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  requested_subnet_count = max(length(var.public_subnets), length(var.private_subnets), 1)
  available_azs          = length(var.availability_zones) > 0 ? var.availability_zones : data.aws_availability_zones.available.names
  az_selection_count     = max(1, min(local.requested_subnet_count, length(local.available_azs)))
  azs                    = slice(local.available_azs, 0, local.az_selection_count)
  single_nat_effective   = var.app_instance_count <= 1
}

resource "aws_vpc" "main" {
  cidr_block                       = var.vpc_cidr
  enable_dns_hostnames             = true
  enable_dns_support               = true
  assign_generated_ipv6_cidr_block = true

  tags = {
    Name = format("%s-vpc", local.name_prefix)
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = format("%s-igw", local.name_prefix)
  }
}

resource "aws_subnet" "public" {
  for_each                        = { for idx, cidr in var.public_subnets : idx => cidr }
  vpc_id                          = aws_vpc.main.id
  cidr_block                      = each.value
  availability_zone               = element(local.azs, tonumber(each.key))
  map_public_ip_on_launch         = true
  assign_ipv6_address_on_creation = true
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.main.ipv6_cidr_block, 8, tonumber(each.key))

  tags = {
    Name = format("%s-public-%s", local.name_prefix, each.key)
  }
}

resource "aws_subnet" "private" {
  for_each                        = { for idx, cidr in var.private_subnets : idx => cidr }
  vpc_id                          = aws_vpc.main.id
  cidr_block                      = each.value
  availability_zone               = element(local.azs, tonumber(each.key))
  assign_ipv6_address_on_creation = true
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.main.ipv6_cidr_block, 8, 100 + tonumber(each.key))

  tags = {
    Name = format("%s-private-%s", local.name_prefix, each.key)
  }
}

resource "aws_eip" "nat" {
  # Allocate one EIP per public subnet unless single NAT mode is enabled
  for_each = { for key, subnet in aws_subnet.public : key => subnet if !local.single_nat_effective || key == "0" }

  domain = "vpc"
  tags = {
    Name = format("%s-nat-eip-%s", local.name_prefix, local.single_nat_effective ? "0" : each.key)
  }
}

resource "aws_nat_gateway" "nat" {
  # Keys aligned with aws_eip.nat to reuse EIPs 1:1
  for_each = { for key, subnet in aws_subnet.public : key => subnet if !local.single_nat_effective || key == "0" }

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = each.value.id

  tags = {
    Name = format("%s-nat-%s", local.name_prefix, each.key)
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
    Name = format("%s-public-rt", local.name_prefix)
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
    Name = format("%s-private-rt-%s", local.name_prefix, each.key)
  }
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# S3 Gateway VPC Endpoint for private subnets (reduces NAT traffic)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [for rt in aws_route_table.private : rt.id]

  tags = {
    Name = format("%s-s3-endpoint", local.name_prefix)
  }
}

resource "aws_security_group" "ec2_sg" {
  name        = format("%s-ec2", local.name_prefix)
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

  ingress {
    description = "ICMP from VPC"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.vpc_cidr]
  }

  dynamic "ingress" {
    for_each = toset(local.mail_ports)
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
    Name = format("%s-ec2-sg", local.name_prefix)
  }
}

resource "aws_security_group" "alb_sg" {
  name        = format("%s-alb", local.name_prefix)
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
  name        = format("%s-rds", local.name_prefix)
  description = "RDS SG"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "SQL 3306 from EC2"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }

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
  name        = format("%s-valkey", local.name_prefix)
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
  name        = format("%s-efs", local.name_prefix)
  description = "EFS SG"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "NFS from EC2"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }

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
  name        = format("%s-client-vpn", local.name_prefix)
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
