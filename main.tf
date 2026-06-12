locals {
  name_prefix = "${var.project}-${var.environment}"
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── Default VPC + subnets ─────────────────────────────────────────────────────

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ── Security groups ───────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Allow HTTP and HTTPS from the internet"
  vpc_id      = data.aws_vpc.default.id
  tags        = local.common_tags

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
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

# ── ALB — target group + HTTPS listener + HTTP→HTTPS redirect ─────────────────

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

# HTTPS listener — forwards to the app target group
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.app.certificate_arn
  tags              = local.common_tags

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# HTTP listener — permanent redirect to HTTPS (no plaintext traffic)
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"
  tags              = local.common_tags

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
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

  project           = var.project
  environment       = var.environment
  github_repo       = var.github_repo
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
  db_password = module.secrets.db_secret_string
}

# ── Compute module ────────────────────────────────────────────────────────────

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

# ── ACM certificate + DNS validation ──────────────────────────────────────────

resource "aws_acm_certificate" "app" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.common_tags
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = var.route53_zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "alb_dns_name" {
  description = "ALB DNS — browse to https://<domain> after DNS propagates"
  value       = aws_lb.app.dns_name
}

output "compute_role_arn" {
  value = module.iam.compute_role_arn
}

output "ci_runner_role_arn" {
  description = "Paste this ARN as AWS_CI_ROLE_ARN in GitHub Secrets"
  value       = module.iam.ci_runner_role_arn
}

output "kms_key_arn" {
  value = module.secrets.kms_key_arn
}

output "db_secret_arn" {
  value     = module.secrets.db_secret_arn
  sensitive = true
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}

output "certificate_arn" {
  value = aws_acm_certificate_validation.app.certificate_arn
}
