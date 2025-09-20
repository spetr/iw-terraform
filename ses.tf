locals {
  ses_enabled       = var.enable_ses
  email_identities  = var.ses_email_identities
  domain_identities = var.ses_domain_identities

  ses_identity_arns = concat(
    [for i in aws_ses_email_identity.this : i.arn],
    [for d in aws_ses_domain_identity.this : d.arn]
  )

  ses_send_policy_resource = length(local.ses_identity_arns) > 0 ? local.ses_identity_arns : ["*"]

  ses_domain_zone_map = {
    for domain, identity in aws_ses_domain_identity.this :
    domain => lookup(var.ses_route53_zone_ids, domain, var.ses_route53_zone_id)
    if lookup(var.ses_route53_zone_ids, domain, var.ses_route53_zone_id) != null
  }

  ses_dkim_records = {
    for item in flatten([
      for domain, dkim in aws_ses_domain_dkim.this : contains(keys(local.ses_domain_zone_map), domain) ? [
        for idx, token in dkim.dkim_tokens : {
          key     = format("%s-%d", domain, idx)
          zone_id = local.ses_domain_zone_map[domain]
          name    = format("%s._domainkey.%s", token, domain)
          record  = format("%s.dkim.amazonses.com", token)
        }
      ] : []
      ]) : item.key => {
      zone_id = item.zone_id
      name    = item.name
      record  = item.record
    }
  }
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
  for_each = local.ses_domain_zone_map
  zone_id  = each.value
  name     = each.key
  type     = "TXT"
  ttl      = 600
  records  = [aws_ses_domain_identity.this[each.key].verification_token]
}

resource "aws_route53_record" "ses_dkim" {
  for_each = local.ses_dkim_records
  zone_id  = each.value.zone_id
  name     = each.value.name
  type     = "CNAME"
  ttl      = 600
  records  = [each.value.record]
}

resource "aws_iam_policy" "ses_send_email" {
  count       = local.ses_enabled ? 1 : 0
  name        = format("%s-ses-send-email", local.name_prefix)
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

  lifecycle {
    precondition {
      condition     = !var.enable_ses || var.ses_identity_type != "email" || length(var.ses_email_identities) > 0
      error_message = "Provide at least one value in ses_email_identities when ses_identity_type is 'email'."
    }
    precondition {
      condition     = !var.enable_ses || var.ses_identity_type != "domain" || length(var.ses_domain_identities) > 0
      error_message = "Provide at least one value in ses_domain_identities when ses_identity_type is 'domain'."
    }
  }
}

resource "aws_iam_role_policy_attachment" "ec2_ses" {
  count      = local.ses_enabled ? 1 : 0
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = aws_iam_policy.ses_send_email[0].arn
}
