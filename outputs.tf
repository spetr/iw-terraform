output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  value = [for s in aws_subnet.private : s.id]
}

output "ec2_instance_ids" {
  value = aws_instance.app[*].id
}

output "ec2_private_ips" {
  value = aws_instance.app[*].private_ip
}

output "alb_dns_name" {
  value = aws_lb.alb.dns_name
}

output "nlb_dns_name" {
  value = aws_lb.nlb.dns_name
}

output "rds_endpoint" {
  value = aws_db_instance.mysql.address
}

output "redis_endpoint" {
  value = aws_elasticache_cluster.redis.cache_nodes[0].address
}

output "efs_data_id" {
  value = aws_efs_file_system.data.id
}

output "efs_config_id" {
  value = aws_efs_file_system.config.id
}

output "client_vpn_endpoint_id" {
  value = aws_ec2_client_vpn_endpoint.this.id
}
