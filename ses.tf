locals {
  ses_enabled = var.enable_ses
}

resource "aws_ses_email_identity" "this" {
  count = local.ses_enabled && var.ses_identity_type == "email" && var.ses_email_identity != null ? 1 : 0
  email = var.ses_email_identity
}

resource "aws_ses_domain_identity" "this" {
  count  = local.ses_enabled && var.ses_identity_type == "domain" && var.ses_domain != null ? 1 : 0
  domain = var.ses_domain
}

resource "aws_ses_domain_dkim" "this" {
  count  = length(aws_ses_domain_identity.this) > 0 ? 1 : 0
  domain = aws_ses_domain_identity.this[0].domain
}

resource "aws_route53_record" "ses_verification" {
  count   = length(aws_ses_domain_identity.this) > 0 && var.ses_route53_zone_id != null ? 1 : 0
  zone_id = var.ses_route53_zone_id
  name    = "${aws_ses_domain_identity.this[0].domain}"
  type    = "TXT"
  ttl     = 600
  records = [aws_ses_domain_identity.this[0].verification_token]
}

resource "aws_route53_record" "ses_dkim" {
  count   = length(aws_ses_domain_dkim.this) > 0 && var.ses_route53_zone_id != null ? 3 : 0
  zone_id = var.ses_route53_zone_id
  name    = "${element(aws_ses_domain_dkim.this[0].dkim_tokens, count.index)}._domainkey.${aws_ses_domain_identity.this[0].domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${element(aws_ses_domain_dkim.this[0].dkim_tokens, count.index)}.dkim.amazonses.com"]
}

resource "aws_iam_policy" "ses_send_email" {
  count       = local.ses_enabled ? 1 : 0
  name        = "${var.project}-${var.environment}-ses-send-email"
  description = "Allow sending email via Amazon SES"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ses" {
  count      = local.ses_enabled ? 1 : 0
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = aws_iam_policy.ses_send_email[0].arn
}
