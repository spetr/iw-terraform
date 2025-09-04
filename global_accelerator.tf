############################################
# Global Accelerator (optional)
############################################

locals {
  ga_nlb_ports = local.nlb_ports
}

resource "aws_globalaccelerator_accelerator" "this" {
  name         = "${var.project}-${var.environment}-ga"
  enabled      = true
  ip_address_type = "IPV4"

  attributes {
    flow_logs_enabled = false
  }
}

# Listener for ALB HTTP/HTTPS
resource "aws_globalaccelerator_listener" "alb" {
  accelerator_arn     = aws_globalaccelerator_accelerator.this.id
  protocol            = "TCP"
  client_affinity     = "NONE"

  port_range {
    from_port = 80
    to_port   = 80
  }

  port_range {
    from_port = 443
    to_port   = 443
  }
}

resource "aws_globalaccelerator_endpoint_group" "alb" {
  listener_arn    = aws_globalaccelerator_listener.alb.id
  health_check_protocol = "TCP"
  health_check_port     = 80
  health_check_interval_seconds = 30

  endpoint_configuration {
    endpoint_id = aws_lb.alb.arn
    weight      = 100
  }
}

# Listener for NLB TCP ports (mail, optional 443 passthrough)
resource "aws_globalaccelerator_listener" "nlb" {
  accelerator_arn     = aws_globalaccelerator_accelerator.this.id
  protocol            = "TCP"
  client_affinity     = "NONE"

  # Explicitly enumerate all used NLB ports (single-port ranges)
  dynamic "port_range" {
    for_each = toset(local.ga_nlb_ports)
    content {
      from_port = port_range.value
      to_port   = port_range.value
    }
  }
}

resource "aws_globalaccelerator_endpoint_group" "nlb" {
  listener_arn = aws_globalaccelerator_listener.nlb.id
  health_check_protocol = "TCP"
  health_check_port     = 25
  health_check_interval_seconds = 30

  endpoint_configuration {
    endpoint_id = aws_lb.nlb.arn
    weight      = 100
  }
}
