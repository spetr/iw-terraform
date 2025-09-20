locals {
  nlb_ports     = local.mail_ports
  nlb_tcp_ports = [for p in local.nlb_ports : p if !contains(local.mail_tls_ports, p)]
  nlb_tls_ports = [for p in local.nlb_ports : p if contains(local.mail_tls_ports, p)]
  nlb_target_ports = {
    for port in local.nlb_ports :
    tostring(port) => lookup(local.mail_tls_target_map, tostring(port), port)
  }
  alb_name              = substr(format("%s-alb", local.name_prefix), 0, 32)
  alb_target_group_name = substr(format("%s-alb-tg", local.name_prefix), 0, 32)
  nlb_name              = substr(format("%s-nlb-eip", local.name_prefix), 0, 32)
}

# Application Load Balancer for HTTP/HTTPS
resource "aws_lb" "alb" {
  name               = local.alb_name
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [for s in aws_subnet.private : s.id]
  idle_timeout       = 60

  dynamic "access_logs" {
    for_each = var.enable_lb_access_logs && var.lb_logs_bucket != null ? [1] : []
    content {
      bucket  = var.lb_logs_bucket
      prefix  = coalesce(var.lb_logs_prefix, format("%s/%s/alb", var.project, var.environment))
      enabled = true
    }
  }

  lifecycle {
    precondition {
      condition     = !var.enable_lb_access_logs || var.lb_logs_bucket != null
      error_message = "lb_logs_bucket must be set when enable_lb_access_logs is true."
    }
  }
}

resource "aws_lb_target_group" "alb_tg" {
  name     = local.alb_target_group_name
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  stickiness {
    type            = "lb_cookie"
    enabled         = true
    cookie_duration = 86400
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
      protocol    = "HTTPS"
      port        = "443"
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

resource "aws_wafv2_web_acl_association" "alb" {
  count        = var.waf_web_acl_arn == null ? 0 : 1
  resource_arn = aws_lb.alb.arn
  web_acl_arn  = var.waf_web_acl_arn
}

resource "aws_wafv2_web_acl" "basic" {
  count       = var.waf_web_acl_arn == null && var.enable_waf_basic ? 1 : 0
  name        = format("%s-waf-basic", local.name_prefix)
  description = "Basic WAF REGIONAL with AWS managed rule groups"
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

resource "aws_eip" "nlb" {
  for_each = aws_subnet.public
  domain   = "vpc"
  tags = {
    Name = format("%s-nlb-eip-%s", local.name_prefix, each.key)
  }
}

resource "aws_lb" "nlb" {
  name               = local.nlb_name
  internal           = false
  load_balancer_type = "network"
  ip_address_type    = "dualstack"

  dynamic "access_logs" {
    for_each = var.enable_lb_access_logs && var.lb_logs_bucket != null ? [1] : []
    content {
      bucket  = var.lb_logs_bucket
      prefix  = coalesce(var.lb_logs_prefix, format("%s/%s/nlb", var.project, var.environment))
      enabled = true
    }
  }

  dynamic "subnet_mapping" {
    for_each = aws_subnet.public
    content {
      subnet_id     = subnet_mapping.value.id
      allocation_id = aws_eip.nlb[subnet_mapping.key].id
    }
  }
}

resource "aws_lb_target_group" "nlb_tg" {
  for_each    = toset([for p in local.nlb_ports : tostring(p)])
  name        = substr(format("%s-nlb-tg-%s", local.name_prefix, each.key), 0, 32)
  port        = local.nlb_target_ports[each.key]
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

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

resource "aws_lb_target_group" "nlb_to_alb_80" {
  name        = substr(format("%s-nlb-alb-80", local.name_prefix), 0, 32)
  port        = 80
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "alb"
}

resource "aws_lb_target_group_attachment" "nlb_to_alb_80" {
  target_group_arn = aws_lb_target_group.nlb_to_alb_80.arn
  target_id        = aws_lb.alb.arn
  port             = 80
  depends_on       = [aws_lb_listener.http_redirect]
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
  name        = substr(format("%s-nlb-alb-443", local.name_prefix), 0, 32)
  port        = 443
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "alb"
}

resource "aws_lb_target_group_attachment" "nlb_to_alb_443" {
  target_group_arn = aws_lb_target_group.nlb_to_alb_443.arn
  target_id        = aws_lb.alb.arn
  port             = 443
  depends_on       = [aws_lb_listener.https]
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
        key   = "${port}-${idx}"
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
  port             = local.nlb_target_ports[each.value.port]
}
