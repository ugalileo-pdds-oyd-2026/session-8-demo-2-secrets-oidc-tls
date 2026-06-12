locals {
  name_prefix = "${var.project}-${var.environment}"
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── Default VPC + subnets (avoids a full network module in the demo) ──────────

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ── Security groups (created at root so both compute and database can reference) ──

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Allow HTTP from the internet"
  vpc_id      = data.aws_vpc.default.id
  tags        = local.common_tags

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "app" {
  name        = "${local.name_prefix}-app-sg"
  description = "Allow traffic from ALB; allow outbound"
  vpc_id      = data.aws_vpc.default.id
  tags        = local.common_tags

  ingress {
    description     = "App port from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ── Application Load Balancer ─────────────────────────────────────────────────

resource "aws_lb" "app" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
  tags               = local.common_tags
}

resource "aws_lb_target_group" "app" {
  name        = "${local.name_prefix}-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "instance"
  tags        = local.common_tags

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"
  tags              = local.common_tags

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}


# ── GitHub Actions OIDC provider ──────────────────────────────────────────────
# Registered once per AWS account. Allows GitHub to present short-lived JWT tokens
# that AWS STS can verify without any stored access keys.
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # SHA-1 thumbprint of the GitHub OIDC TLS certificate (stable).
  # Verified at: https://docs.github.com/en/actions/security-guides/security-hardening-with-openid-connect
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = local.common_tags
}


# ── Secrets module (KMS + Secrets Manager) ────────────────────────────────────

module "secrets" {
  source = "./modules/secrets"

  project     = var.project
  environment = var.environment
  db_username = var.db_username
}

# ── IAM module ────────────────────────────────────────────────────────────────

module "iam" {
  source = "./modules/iam"

  project     = var.project
  environment = var.environment
  github_repo = var.github_repo
  oidc_provider_arn = aws_iam_openid_connect_provider.github.arn
  db_secret_arn     = module.secrets.db_secret_arn
  kms_key_arn       = module.secrets.kms_key_arn
}

# ── Database module ───────────────────────────────────────────────────────────

module "database" {
  source = "./modules/database"

  project     = var.project
  environment = var.environment
  vpc_id      = data.aws_vpc.default.id
  subnet_ids  = data.aws_subnets.default.ids
  app_sg_id   = aws_security_group.app.id
  db_name     = var.project
  db_username = var.db_username
  db_password = var.db_password
}

# ── Compute module ────────────────────────────────────────────────────────────
# Note: compute depends on database (needs db_endpoint) — no circular dependency
# because the app SG is managed at root level, not inside the compute module.

module "compute" {
  source = "./modules/compute"

  project               = var.project
  environment           = var.environment
  subnet_id             = data.aws_subnets.default.ids[0]
  app_sg_id             = aws_security_group.app.id
  alb_target_group_arn  = aws_lb_target_group.app.arn
  instance_profile_name = module.iam.compute_instance_profile_name

  # Secret name (not a credential) injected into user_data — fetched by boto3 at runtime
  db_secret_name = module.secrets.db_secret_name
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "alb_dns_name" {
  description = "ALB DNS — test with: curl http://<dns>/health"
  value       = aws_lb.app.dns_name
}

output "compute_role_arn" {
  value = module.iam.compute_role_arn
}

output "compute_instance_profile_name" {
  value = module.iam.compute_instance_profile_name
}
