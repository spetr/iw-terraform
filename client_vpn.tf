resource "aws_ec2_client_vpn_endpoint" "this" {
  description            = "${var.project}-${var.environment} client vpn"
  server_certificate_arn = var.client_vpn_certificate_arn
  client_cidr_block      = var.client_vpn_cidr
  vpc_id                 = aws_vpc.main.id
  split_tunnel           = true
  dns_servers            = ["8.8.8.8", "1.1.1.1"]

  authentication_options {
  type                       = var.client_vpn_auth_saml_provider_arn == null ? "certificate-authentication" : "federated-authentication"
  root_certificate_chain_arn = var.client_vpn_auth_saml_provider_arn == null ? var.client_vpn_client_root_certificate_arn : null
    saml_provider_arn          = var.client_vpn_auth_saml_provider_arn
  }

  connection_log_options {
    enabled = false
  }

  security_group_ids = [aws_security_group.client_vpn_sg.id]

  tags = {
    Name = "${var.project}-${var.environment}-client-vpn"
  }
}

resource "aws_ec2_client_vpn_network_association" "this" {
  for_each               = aws_subnet.public
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  subnet_id              = each.value.id
}

resource "aws_ec2_client_vpn_authorization_rule" "this" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  target_network_cidr    = var.vpc_cidr
  authorize_all_groups   = true
}

resource "aws_ec2_client_vpn_route" "this" {
  for_each               = aws_ec2_client_vpn_network_association.this
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  destination_cidr_block = var.vpc_cidr
  target_vpc_subnet_id   = each.value.subnet_id
}
