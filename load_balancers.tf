locals {
  mail_tcp_ports = [25, 465, 587, 143, 993, 110, 995] # smtp, smtps, submission, imap, imaps, pop3, pop3s
}

# Application Load Balancer for HTTP/HTTPS
resource "aws_lb" "alb" {
  name               = "${var.project}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [for s in aws_subnet.public : s.id]
  idle_timeout       = 60
}

resource "aws_lb_target_group" "alb_tg" {
  name     = "${var.project}-${var.environment}-alb-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

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

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_tg.arn
  }
}

resource "aws_lb_listener" "https" {
  count             = var.alb_certificate_arn == null ? 0 : 1
  load_balancer_arn = aws_lb.alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = var.alb_certificate_arn

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

# Network Load Balancer for TCP ports (mail protocols)
resource "aws_lb" "nlb" {
  name               = "${var.project}-${var.environment}-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = [for s in aws_subnet.public : s.id]
}

resource "aws_lb_target_group" "nlb_tg" {
  for_each = toset([for p in local.mail_tcp_ports : tostring(p)])
  name     = "${var.project}-${var.environment}-nlb-tg-${each.key}"
  port     = tonumber(each.key)
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id
  target_type = "instance"
}

resource "aws_lb_listener" "nlb_listener" {
  for_each          = toset([for p in local.mail_tcp_ports : tostring(p)])
  load_balancer_arn = aws_lb.nlb.arn
  port              = tonumber(each.key)
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_tg[each.key].arn
  }
}

locals {
  nlb_pairs = flatten([
    for port, tg in aws_lb_target_group.nlb_tg : [
      for i in aws_instance.app : {
        key  = "${port}-${i.id}"
        port = port
        id   = i.id
      }
    ]
  ])
}

resource "aws_lb_target_group_attachment" "nlb_ec2" {
  for_each = { for p in local.nlb_pairs : p.key => p }

  target_group_arn = aws_lb_target_group.nlb_tg[each.value.port].arn
  target_id        = each.value.id
  port             = tonumber(each.value.port)
}
