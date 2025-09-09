resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.project}-${var.environment}-redis-subnets"
  subnet_ids = [for s in aws_subnet.private : s.id]
}

# When there is only 1 app instance, deploy Redis as a single-node cluster
resource "aws_elasticache_cluster" "redis_app" {
  count               = var.app_instance_count > 1 ? 0 : 1
  cluster_id          = "${var.project}-${var.environment}-redis"
  engine              = "redis"
  engine_version      = var.redis_app_engine_version
  node_type           = var.redis_app_node_type
  num_cache_nodes     = 1
  parameter_group_name = "default.redis7"
  port                = 6379
  subnet_group_name   = aws_elasticache_subnet_group.this.name
  security_group_ids  = [aws_security_group.redis_sg.id]

  tags = {
    Name = "${var.project}-${var.environment}-redis-app"
  }
}

# When app instances are spread across AZs, deploy Redis as HA (primary + replica) across both AZs
resource "aws_elasticache_replication_group" "redis_app" {
  count                         = var.app_instance_count > 1 ? 1 : 0
  # Use a distinct identifier to avoid clashes with the single-node cluster identifier
  replication_group_id          = "${var.project}-${var.environment}-redis-app-rg"
  description                   = "${var.project}-${var.environment} Redis (Multi-AZ)"
  engine                        = "redis"
  engine_version                = var.redis_app_engine_version
  node_type                     = var.redis_app_node_type
  num_node_groups               = 1
  replicas_per_node_group       = 1
  automatic_failover_enabled    = true
  multi_az_enabled              = true
  parameter_group_name          = "default.redis7"
  port                          = 6379
  subnet_group_name             = aws_elasticache_subnet_group.this.name
  security_group_ids            = [aws_security_group.redis_sg.id]

  tags = {
    Name = "${var.project}-${var.environment}-redis"
  }
}

# Terraform moved statements to preserve state across resource rename
moved {
  from = aws_elasticache_cluster.redis
  to   = aws_elasticache_cluster.redis_app
}

moved {
  from = aws_elasticache_replication_group.redis
  to   = aws_elasticache_replication_group.redis_app
}

# Dedicated Redis for Fulltext (HA across AZs) when there are 2+ fulltext instances
resource "aws_elasticache_replication_group" "redis_fulltext" {
  count                         = var.fulltext_instance_count >= 2 ? 1 : 0
  replication_group_id          = "${var.project}-${var.environment}-redis-fulltext-rg"
  description                   = "${var.project}-${var.environment} Fulltext Redis (Multi-AZ)"
  engine                        = "redis"
  engine_version                = var.redis_fulltext_engine_version
  node_type                     = var.redis_fulltext_node_type
  num_node_groups               = 1
  replicas_per_node_group       = 1
  automatic_failover_enabled    = true
  multi_az_enabled              = true
  parameter_group_name          = "default.redis7"
  port                          = 6379
  subnet_group_name             = aws_elasticache_subnet_group.this.name
  security_group_ids            = [aws_security_group.redis_sg.id]

  tags = {
    Name = "${var.project}-${var.environment}-redis-fulltext"
  }
}
