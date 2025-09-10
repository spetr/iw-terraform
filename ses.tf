locals {
  ses_enabled       = var.enable_ses
  email_identities  = var.ses_email_identities
  domain_identities = var.ses_domain_identities

  # ARNs of identities actually created by this stack (email or domain, depending on config)
  ses_identity_arns = concat(
    [for i in aws_ses_email_identity.this : i.arn],
    [for d in aws_ses_domain_identity.this : d.arn]
  )
  # Use specific identity ARNs when available; fall back to "*" if none exist
  ses_send_policy_resource = length(local.ses_identity_arns) > 0 ? local.ses_identity_arns : ["*"]
}

resource "aws_ses_email_identity" "this" {
  for_each = local.ses_enabled && var.ses_identity_type == "email" ? toset(local.email_identities) : []
  email    = each.value
}

resource "aws_ses_domain_identity" "this" {
  for_each = local.ses_enabled && var.ses_identity_type == "domain" ? toset(local.domain_identities) : []
  domain   = each.value
}

resource "aws_ses_domain_dkim" "this" {
  for_each = aws_ses_domain_identity.this
  domain   = each.value.domain
}

resource "aws_route53_record" "ses_verification" {
  for_each = {
    for d, di in aws_ses_domain_identity.this : d => di if(
      contains(keys(var.ses_route53_zone_ids), d) || var.ses_route53_zone_id != null
    )
  }
  zone_id = lookup(var.ses_route53_zone_ids, each.key, var.ses_route53_zone_id)
  name    = each.key
  type    = "TXT"
  ttl     = 600
  records = [each.value.verification_token]
}

# Create DKIM records with explicit resources (3 per domain)
resource "aws_route53_record" "ses_dkim_0" {
  for_each = {
    for d, dk in aws_ses_domain_dkim.this : d => dk if(
      contains(keys(var.ses_route53_zone_ids), d) || var.ses_route53_zone_id != null
    )
  }
  zone_id = lookup(var.ses_route53_zone_ids, each.key, var.ses_route53_zone_id)
  name    = "${element(each.value.dkim_tokens, 0)}._domainkey.${each.key}"
  type    = "CNAME"
  ttl     = 600
  records = ["${element(each.value.dkim_tokens, 0)}.dkim.amazonses.com"]
}

resource "aws_route53_record" "ses_dkim_1" {
  for_each = {
    for d, dk in aws_ses_domain_dkim.this : d => dk if(
      contains(keys(var.ses_route53_zone_ids), d) || var.ses_route53_zone_id != null
    )
  }
  zone_id = lookup(var.ses_route53_zone_ids, each.key, var.ses_route53_zone_id)
  name    = "${element(each.value.dkim_tokens, 1)}._domainkey.${each.key}"
  type    = "CNAME"
  ttl     = 600
  records = ["${element(each.value.dkim_tokens, 1)}.dkim.amazonses.com"]
}

resource "aws_route53_record" "ses_dkim_2" {
  for_each = {
    for d, dk in aws_ses_domain_dkim.this : d => dk if(
      contains(keys(var.ses_route53_zone_ids), d) || var.ses_route53_zone_id != null
    )
  }
  zone_id = lookup(var.ses_route53_zone_ids, each.key, var.ses_route53_zone_id)
  name    = "${element(each.value.dkim_tokens, 2)}._domainkey.${each.key}"
  type    = "CNAME"
  ttl     = 600
  records = ["${element(each.value.dkim_tokens, 2)}.dkim.amazonses.com"]
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
        Resource = local.ses_send_policy_resource
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ses" {
  count      = local.ses_enabled ? 1 : 0
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = aws_iam_policy.ses_send_email[0].arn
}
