############################################
# Global Accelerator (optional)
############################################

locals {
  # TCP ports exposed through the NLB (mail and optional 443 passthrough)
  ga_nlb_ports = local.nlb_ports
  # ALB ports we want accessible via GA
  ga_alb_ports = var.alb_certificate_arn == null ? [80] : [80, 443]
}

resource "aws_globalaccelerator_accelerator" "this" {
  count        = var.enable_global_accelerator ? 1 : 0
  name         = "${var.project}-${var.environment}-ga"
  enabled      = true
  ip_address_type = "IPV4"

  attributes {
    flow_logs_enabled = false
  }
}

# Listener for ALB HTTP/HTTPS
resource "aws_globalaccelerator_listener" "alb" {
  count               = var.enable_global_accelerator ? 1 : 0
  accelerator_arn     = aws_globalaccelerator_accelerator.this[0].id
  protocol            = "TCP"
  client_affinity     = "NONE"

  port_range {
    from_port = 80
    to_port   = 80
  }

  dynamic "port_range" {
    for_each = var.alb_certificate_arn == null ? [] : [1]
    content {
      from_port = 443
      to_port   = 443
    }
  }
}

resource "aws_globalaccelerator_endpoint_group" "alb" {
  count           = var.enable_global_accelerator ? 1 : 0
  listener_arn    = aws_globalaccelerator_listener.alb[0].id
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
  count               = var.enable_global_accelerator ? 1 : 0
  accelerator_arn     = aws_globalaccelerator_accelerator.this[0].id
  protocol            = "TCP"
  client_affinity     = "NONE"

  # Cover full range used by NLB to avoid many listeners; GA requires contiguous ranges, so we use 25-995 which includes our used ports.
  # Note: Only the ports actually opened on the NLB/targets will respond.
  port_range {
    from_port = 25
    to_port   = 995
  }
}

resource "aws_globalaccelerator_endpoint_group" "nlb" {
  count        = var.enable_global_accelerator ? 1 : 0
  listener_arn = aws_globalaccelerator_listener.nlb[0].id
  health_check_protocol = "TCP"
  health_check_port     = 25
  health_check_interval_seconds = 30

  endpoint_configuration {
    endpoint_id = aws_lb.nlb.arn
    weight      = 100
  }
}
