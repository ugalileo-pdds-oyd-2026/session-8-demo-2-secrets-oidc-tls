output "db_endpoint" {
  description = "RDS endpoint hostname — passed to the compute module as DB_HOST"
  value       = aws_db_instance.main.address
}

output "db_port" {
  description = "RDS port (always 5432 for PostgreSQL)"
  value       = aws_db_instance.main.port
}

output "db_sg_id" {
  description = "Security group ID for the RDS instance"
  value       = aws_security_group.db.id
}
