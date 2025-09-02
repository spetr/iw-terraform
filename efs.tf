resource "aws_efs_file_system" "data" {
  encrypted = true
  tags = {
    Name = "${var.project}-${var.environment}-efs-data"
  }
}

resource "aws_efs_file_system" "config" {
  encrypted = true
  tags = {
    Name = "${var.project}-${var.environment}-efs-config"
  }
}

resource "aws_efs_mount_target" "data" {
  for_each        = aws_subnet.private
  file_system_id  = aws_efs_file_system.data.id
  subnet_id       = each.value.id
  security_groups = [aws_security_group.efs_sg.id]
}

resource "aws_efs_mount_target" "config" {
  for_each        = aws_subnet.private
  file_system_id  = aws_efs_file_system.config.id
  subnet_id       = each.value.id
  security_groups = [aws_security_group.efs_sg.id]
}
