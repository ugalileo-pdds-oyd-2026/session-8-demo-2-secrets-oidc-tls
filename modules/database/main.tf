locals {
  name_prefix = "${var.project}-${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── DB security group ─────────────────────────────────────────────────────────
# Port 5432 is open ONLY from the app security group — no public access.

resource "aws_security_group" "db" {
  name        = "${local.name_prefix}-db-sg"
  description = "Allow PostgreSQL only from the app security group"
  vpc_id      = var.vpc_id
  tags        = local.tags

  ingress {
    description     = "PostgreSQL from app"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.app_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ── DB subnet group ───────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = var.subnet_ids
  tags       = local.tags
}

# ── RDS PostgreSQL instance ───────────────────────────────────────────────────
# Storage encryption is OFF in start/ — enabling it with a KMS CMK is part of
# the upgrade demonstrated in end/.

resource "aws_db_instance" "main" {
  identifier        = "${local.name_prefix}-postgres"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password # ⚠️ plaintext in state — removed in end/

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  skip_final_snapshot    = true

  # Storage encryption is OFF in start/ — the gap KMS closes in end/
  storage_encrypted = false

  tags = local.tags
}
