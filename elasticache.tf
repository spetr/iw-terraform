resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.project}-${var.environment}-valkey-subnets"
  subnet_ids = [for s in aws_subnet.private : s.id]
}

# When there is only 1 app instance, deploy Valkey as a single-node cluster
resource "aws_elasticache_cluster" "valkey_app" {
  count               = var.app_instance_count > 1 ? 0 : 1
  cluster_id          = "${var.project}-${var.environment}-valkey"
  engine              = "valkey"
  engine_version      = var.valkey_app_engine_version
  node_type           = var.valkey_app_node_type
  num_cache_nodes     = 1
  parameter_group_name = "default.valkey8"
  port                = 6379
  subnet_group_name   = aws_elasticache_subnet_group.this.name
  security_group_ids  = [aws_security_group.valkey_sg.id]

  tags = {
    Name = "${var.project}-${var.environment}-valkey-app"
  }
}

# When app instances are spread across AZs, deploy Valkey as HA (primary + replica) across both AZs
resource "aws_elasticache_replication_group" "valkey_app" {
  count                         = var.app_instance_count > 1 ? 1 : 0
  # Use a distinct identifier to avoid clashes with the single-node cluster identifier
  replication_group_id          = "${var.project}-${var.environment}-valkey-app-rg"
  description                   = "${var.project}-${var.environment} Valkey (Multi-AZ)"
  engine                        = "valkey"
  engine_version                = var.valkey_app_engine_version
  node_type                     = var.valkey_app_node_type
  num_node_groups               = 1
  replicas_per_node_group       = 1
  automatic_failover_enabled    = true
  multi_az_enabled              = true
  parameter_group_name          = "default.valkey8"
  port                          = 6379
  subnet_group_name             = aws_elasticache_subnet_group.this.name
  security_group_ids            = [aws_security_group.valkey_sg.id]

  tags = {
    Name = "${var.project}-${var.environment}-valkey"
  }
}

# Dedicated Valkey for Fulltext (HA across AZs) when there are 2+ fulltext instances
resource "aws_elasticache_replication_group" "valkey_fulltext" {
  count                         = var.fulltext_instance_count >= 2 ? 1 : 0
  replication_group_id          = "${var.project}-${var.environment}-valkey-fulltext-rg"
  description                   = "${var.project}-${var.environment} Fulltext Valkey (Multi-AZ)"
  engine                        = "valkey"
  engine_version                = var.valkey_fulltext_engine_version
  node_type                     = var.valkey_fulltext_node_type
  num_node_groups               = 1
  replicas_per_node_group       = 1
  automatic_failover_enabled    = true
  multi_az_enabled              = true
  parameter_group_name          = "default.valkey8"
  port                          = 6379
  subnet_group_name             = aws_elasticache_subnet_group.this.name
  security_group_ids            = [aws_security_group.valkey_sg.id]

  tags = {
    Name = "${var.project}-${var.environment}-valkey-fulltext"
  }
}
