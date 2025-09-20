locals {
  name_prefix    = "${var.project}-${var.environment}"
  mail_ports     = [25, 465, 587, 143, 993, 110, 995]
  mail_tls_ports = [465, 993, 995]
  mail_tls_target_map = {
    465 = 25
    993 = 143
    995 = 110
  }
}
