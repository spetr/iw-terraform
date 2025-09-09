locals {
  # Mail-related TCP ports handled by the NLB (SMTP/IMAP/POP3 family)
  mail_ports = [25, 465, 587, 143, 993, 110, 995] # smtp, smtps, submission, imap, imaps, pop3, pop3s

  # TLS ports will always terminate on the NLB using ACM cert
  mail_tls_ports = [465, 993, 995]

  # NLB listeners cover only mail ports now (no 443 passthrough needed as ALB always has HTTPS)
  nlb_ports = local.mail_ports

  # Partition NLB ports into TCP (non-TLS) and TLS
  nlb_tcp_ports = [for p in local.nlb_ports : p if !contains(local.mail_tls_ports, p)]
  nlb_tls_ports = [for p in local.nlb_ports : p if contains(local.mail_tls_ports, p)]
}

# Application Load Balancer for HTTP/HTTPS
resource "aws_lb" "alb" {
  name               = "${var.project}-${var.environment}-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [for s in aws_subnet.private : s.id]
  idle_timeout       = 60
}

resource "aws_lb_target_group" "alb_tg" {
  name     = "${var.project}-${var.environment}-alb-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  # Enable sticky sessions on ALB using LB cookie
  stickiness {
    type            = "lb_cookie"
    enabled         = true
    cookie_duration = 86400 # 1 day
  }

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    unhealthy_threshold = 2
    healthy_threshold   = 3
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      protocol   = "HTTPS"
      port       = "443"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.imported.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_tg.arn
  }
}

resource "aws_lb_target_group_attachment" "alb_ec2" {
  count            = length(aws_instance.app)
  target_group_arn = aws_lb_target_group.alb_tg.arn
  target_id        = aws_instance.app[count.index].id
  port             = 80
}

# Optionally associate an existing WAFv2 Web ACL to ALB
resource "aws_wafv2_web_acl_association" "alb" {
  count        = var.waf_web_acl_arn == null ? 0 : 1
  resource_arn = aws_lb.alb.arn
  web_acl_arn  = var.waf_web_acl_arn
}

# Optionally create a basic WAF and associate with ALB when no external ARN is provided
resource "aws_wafv2_web_acl" "basic" {
  count = var.waf_web_acl_arn == null && var.enable_waf_basic ? 1 : 0
  name        = "${var.project}-${var.environment}-waf-basic"
  description = "Basic WAF (REGIONAL) with AWS managed rule groups"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 1
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    override_action {
      none {}
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    override_action {
      none {}
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesSQLiRuleSet"
    priority = 3
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }
    override_action {
      none {}
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "sqli"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "basic-acl"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "alb_basic" {
  count        = var.waf_web_acl_arn == null && var.enable_waf_basic ? 1 : 0
  resource_arn = aws_lb.alb.arn
  web_acl_arn  = aws_wafv2_web_acl.basic[0].arn
}

# Network Load Balancer for TCP ports (mail protocols)
resource "aws_eip" "nlb" {
  # Allocate one EIP per public subnet to attach to the NLB (keep keys aligned with subnets)
  for_each = aws_subnet.public
  domain   = "vpc"
  tags = {
    Name = "${var.project}-${var.environment}-nlb-eip-${each.key}"
  }
}

resource "aws_lb" "nlb" {
  name               = "${var.project}-${var.environment}-nlb-eip"
  internal           = false
  load_balancer_type = "network"
  ip_address_type    = "dualstack"

  dynamic "subnet_mapping" {
    # Iterate over the actual public subnet map to ensure subnet_id is always set
    for_each = aws_subnet.public
    content {
      subnet_id     = subnet_mapping.value.id
      allocation_id = aws_eip.nlb[subnet_mapping.key].id
      # Let AWS auto-assign IPv6; only pin IPv4 via EIP
    }
  }
}

resource "aws_lb_target_group" "nlb_tg" {
  for_each = toset([for p in local.nlb_ports : tostring(p)])
  name     = "${var.project}-${var.environment}-nlb-tg-${each.key}"
  port     = tonumber(each.key)
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id
  target_type = "instance"

  # Enable stickiness on NLB by source IP
  stickiness {
    type    = "source_ip"
    enabled = true
  }
}

resource "aws_lb_listener" "nlb_listener_tcp" {
  for_each          = toset([for p in local.nlb_tcp_ports : tostring(p)])
  load_balancer_arn = aws_lb.nlb.arn
  port              = tonumber(each.key)
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_tg[each.key].arn
  }
}

resource "aws_lb_listener" "nlb_listener_tls" {
  for_each          = toset([for p in local.nlb_tls_ports : tostring(p)])
  load_balancer_arn = aws_lb.nlb.arn
  port              = tonumber(each.key)
  protocol          = "TLS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.imported.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_tg[each.key].arn
  }
}

# NLB → ALB forwarding for web ports (80/443) via TCP passthrough
resource "aws_lb_target_group" "nlb_to_alb_80" {
  name        = "${var.project}-${var.environment}-nlb-alb-80"
  port        = 80
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "alb"
}

resource "aws_lb_target_group_attachment" "nlb_to_alb_80" {
  target_group_arn = aws_lb_target_group.nlb_to_alb_80.arn
  target_id        = aws_lb.alb.arn
  port             = 80
}

resource "aws_lb_listener" "nlb_http_to_alb" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_to_alb_80.arn
  }
}

resource "aws_lb_target_group" "nlb_to_alb_443" {
  name        = "${var.project}-${var.environment}-nlb-alb-443"
  port        = 443
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "alb"
}

resource "aws_lb_target_group_attachment" "nlb_to_alb_443" {
  target_group_arn = aws_lb_target_group.nlb_to_alb_443.arn
  target_id        = aws_lb.alb.arn
  port             = 443
}

resource "aws_lb_listener" "nlb_https_to_alb" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_to_alb_443.arn
  }
}

locals {
  nlb_ports_str = [for p in local.nlb_ports : tostring(p)]
  app_indexes   = range(length(aws_instance.app))

  nlb_pairs = flatten([
    for port in local.nlb_ports_str : [
      for idx in local.app_indexes : {
        key   = "${port}-${idx}" // statický klíč známý při planu
        port  = port
        index = idx
      }
    ]
  ])
}

resource "aws_lb_target_group_attachment" "nlb_ec2" {
  for_each = { for p in local.nlb_pairs : p.key => p }

  target_group_arn = aws_lb_target_group.nlb_tg[each.value.port].arn
  target_id        = aws_instance.app[each.value.index].id
  port             = tonumber(each.value.port)
}
