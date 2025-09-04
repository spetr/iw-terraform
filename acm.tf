############################################
# ACM certificate import from local files
############################################

resource "aws_acm_certificate" "imported" {
  private_key       = file(var.acm_import_key_file)
  certificate_body  = file(var.acm_import_cert_file)
  # certificate_chain can be omitted for self-signed
}
