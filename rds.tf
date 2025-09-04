resource "aws_db_subnet_group" "this" {
  name       = "${var.project}-${var.environment}-db-subnets"
  subnet_ids = [for s in aws_subnet.private : s.id]
  tags = {
    Name = "${var.project}-${var.environment}-db-subnets"
  }
}

resource "aws_db_instance" "mysql" {
  identifier              = "${var.project}-${var.environment}-mariadb"
  engine                  = "mariadb"
  engine_version          = "11.8"
  instance_class          = var.db_instance_class
  username                = var.db_username
  password                = var.db_password
  allocated_storage       = var.db_allocated_storage
  max_allocated_storage   = var.db_max_allocated_storage
  storage_type            = var.db_storage_type
  iops                    = (var.db_storage_type == "io1" || var.db_storage_type == "io2" || var.db_storage_type == "gp3") && var.db_iops != null ? var.db_iops : null
  storage_throughput      = var.db_storage_type == "gp3" && var.db_storage_throughput != null ? var.db_storage_throughput : null
  skip_final_snapshot     = true
  deletion_protection     = false
  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
  multi_az                = var.ec2_instance_count > 1
  publicly_accessible     = false
  storage_encrypted       = true
  backup_retention_period = 7
  apply_immediately       = true

  tags = {
    Name = "${var.project}-${var.environment}-mariadb"
  }
}
