resource "aws_efs_file_system" "data" {
  performance_mode                = "generalPurpose"
  throughput_mode                 = var.efs_throughput_mode
  provisioned_throughput_in_mibps = var.efs_throughput_mode == "provisioned" && var.efs_provisioned_throughput_mibps != null ? var.efs_provisioned_throughput_mibps : null
  encrypted                       = true
  tags = {
    Name = "${var.project}-${var.environment}-efs-data"
  }
}

resource "aws_efs_file_system" "config" {
  performance_mode                = "generalPurpose"
  throughput_mode                 = var.efs_throughput_mode
  provisioned_throughput_in_mibps = var.efs_throughput_mode == "provisioned" && var.efs_provisioned_throughput_mibps != null ? var.efs_provisioned_throughput_mibps : null
  encrypted                       = true
  tags = {
    Name = "${var.project}-${var.environment}-efs-config"
  }
}

resource "aws_efs_mount_target" "data" {
  for_each        = var.app_instance_count <= 1 ? { "0" = aws_subnet.private["0"] } : aws_subnet.private
  file_system_id  = aws_efs_file_system.data.id
  subnet_id       = each.value.id
  security_groups = [aws_security_group.efs_sg.id]
}

resource "aws_efs_mount_target" "config" {
  for_each        = var.app_instance_count <= 1 ? { "0" = aws_subnet.private["0"] } : aws_subnet.private
  file_system_id  = aws_efs_file_system.config.id
  subnet_id       = each.value.id
  security_groups = [aws_security_group.efs_sg.id]
}

# Optional EFS: archive
resource "aws_efs_file_system" "archive" {
  count                           = var.enable_efs_archive ? 1 : 0
  performance_mode                = "generalPurpose"
  throughput_mode                 = var.efs_throughput_mode
  provisioned_throughput_in_mibps = var.efs_throughput_mode == "provisioned" && var.efs_provisioned_throughput_mibps != null ? var.efs_provisioned_throughput_mibps : null
  encrypted                       = true
  tags = {
    Name = "${var.project}-${var.environment}-efs-archive"
  }
}

resource "aws_efs_mount_target" "archive" {
  for_each        = var.enable_efs_archive ? (var.app_instance_count <= 1 ? { "0" = aws_subnet.private["0"] } : aws_subnet.private) : {}
  file_system_id  = aws_efs_file_system.archive[0].id
  subnet_id       = each.value.id
  security_groups = [aws_security_group.efs_sg.id]
}
