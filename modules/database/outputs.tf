output "db_endpoint" {
  description = "RDS endpoint hostname"
  value       = aws_db_instance.main.address
}

output "db_port" {
  description = "RDS port"
  value       = aws_db_instance.main.port
}

output "db_sg_id" {
  description = "Security group ID for the RDS instance"
  value       = aws_security_group.db.id
}
