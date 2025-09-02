resource "aws_db_subnet_group" "this" {
  name       = "${var.project}-${var.environment}-db-subnets"
  subnet_ids = [for s in aws_subnet.private : s.id]
  tags = {
    Name = "${var.project}-${var.environment}-db-subnets"
  }
}

resource "aws_db_instance" "mysql" {
  identifier              = "${var.project}-${var.environment}-mysql"
  engine                  = "mysql"
  engine_version          = "8.4"
  instance_class          = var.db_instance_class
  username                = var.db_username
  password                = var.db_password
  allocated_storage       = var.db_allocated_storage
  skip_final_snapshot     = true
  deletion_protection     = false
  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
  multi_az                = false
  publicly_accessible     = false
  storage_encrypted       = true
  backup_retention_period = 7
  apply_immediately       = true

  tags = {
    Name = "${var.project}-${var.environment}-mysql"
  }
}
