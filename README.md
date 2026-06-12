# Session 8 — Secrets Manager, OIDC Keyless Auth & TLS

A Python web app + EC2 + RDS stack evolves from a plaintext database password in Terraform state to runtime secret retrieval via Secrets Manager, keyless GitHub Actions authentication via OIDC, and HTTPS enforcement at the ALB — all wired with Terraform modules.

## What students learn

- Why storing secrets in `terraform.tfstate` (or `tfvars`) is a critical exposure vector and where else passwords can leak (CI logs, AMI snapshots, process lists, shell history)
- How to use a KMS Customer Managed Key (CMK) to encrypt a Secrets Manager secret, and why the key policy must explicitly grant Secrets Manager access
- Why `ignore_changes = [secret_string]` is required to prevent Terraform from overwriting rotated passwords on every apply
- Why a defined-but-unattached IAM policy has zero effect, and how the policy attachment is the actual activation step
- How GitHub Actions authenticates to AWS without stored keys using OIDC web identity federation, and why both the `aud` and `sub` conditions must use `StringEquals`
- How to issue and validate an ACM certificate via DNS and enforce HTTPS at the ALB with a permanent HTTP → HTTPS redirect

## Project structure

```
.
├── start/                          # insecure baseline (plaintext password)
│   ├── app/
│   │   └── main.py                 # reads DB_PASSWORD from env var
│   ├── modules/
│   │   ├── compute/
│   │   ├── iam/
│   │   └── networking/
│   ├── main.tf
│   ├── variables.tf
│   └── dev.tfvars                  # contains db_password in plaintext
└── end/                            # secure target state
    ├── app/
    │   └── main.py                 # fetches credentials from Secrets Manager at runtime
    ├── modules/
    │   ├── secrets/
    │   │   └── main.tf             # KMS CMK + Secrets Manager secret
    │   ├── iam/
    │   │   └── main.tf             # compute role + OIDC CI runner role + policy attachments
    │   └── compute/
    │       └── main.tf             # passes DB_SECRET_NAME (not a password)
    ├── .github/
    │   └── workflows/
    │       └── terraform-ci.yml    # keyless OIDC auth — no stored AWS keys
    ├── main.tf                     # wires all modules + OIDC provider + ACM + ALB listeners
    ├── variables.tf                # db_password variable removed entirely
    └── dev.tfvars
```

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.6
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) configured with valid credentials

Verify both before starting:

```bash
terraform -version
aws sts get-caller-identity
```

## Demo workflow

### 1. Inspect the insecure baseline

```bash
cd start/
tree .
```

Open `app/main.py` and note how the password is sourced:

```python
"password": os.environ.get("DB_PASSWORD", "not-set"),  # ⚠️ plaintext
```

Open `dev.tfvars` and note the plaintext value:

```hcl
db_password = "changeme-before-prod"
```

Open `main.tf` and trace how it propagates into state:

```hcl
module "compute" {
  ...
  db_password = var.db_password  # ⚠️ lands in terraform.tfstate
}
```

The current (insecure) request path:
```
User → ALB (HTTP:80) → EC2 app → DB_PASSWORD env var ← terraform.tfstate (plaintext)
```

The target path after this demo:
```
User → ALB (HTTPS:443) → EC2 app → boto3 GetSecretValue → Secrets Manager (KMS-encrypted)
```

### 2. Scaffold the secrets module: KMS CMK + Secrets Manager secret

Work in `end/`. Open `modules/secrets/main.tf` and add the KMS Customer Managed Key:

```hcl
data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"
  tags = { Project = var.project, Environment = var.environment, ManagedBy = "terraform" }
}

resource "aws_kms_key" "app" {
  description             = "${local.name_prefix} application CMK"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = local.tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RootAccountAdmin"
        Effect = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action   = ["kms:*"]
        Resource = ["*"]
      },
      {
        Sid    = "AllowSecretsManager"
        Effect = "Allow"
        Principal = { Service = "secretsmanager.amazonaws.com" }
        Action   = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_kms_alias" "app" {
  name          = "alias/${local.name_prefix}-app-key"
  target_key_id = aws_kms_key.app.key_id
}
```

Then add the Secrets Manager secret:

```hcl
resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name_prefix}/db/credentials"
  description             = "PostgreSQL credentials for the ${local.name_prefix} app"
  kms_key_id              = aws_kms_key.app.arn
  recovery_window_in_days = 7
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    username = var.db_username
    password = "REPLACE_BEFORE_APPLY"
    host     = "REPLACE_WITH_RDS_ENDPOINT"
    port     = 5432
    dbname   = var.project
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
```

### 3. Attach the secret-read policy to the compute role

Open `end/modules/iam/main.tf` and add after the existing compute role block:

```hcl
resource "aws_iam_policy" "read_db_secret" {
  name = "${local.name_prefix}-read-db-secret"
  tags = local.tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GetSecret"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [var.db_secret_arn]
      },
      {
        Sid    = "DecryptWithCMK"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = [var.kms_key_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "compute_read_secret" {
  role       = aws_iam_role.compute.name
  policy_arn = aws_iam_policy.read_db_secret.arn
}
```

### 4. Rewrite `app/main.py` to fetch credentials at runtime

Replace the `get_db_config` function in `end/app/main.py`:

```python
import boto3

def fetch_db_config():
    secret_name = os.environ["DB_SECRET_NAME"]   # a name, not a secret — safe to log
    client = boto3.client("secretsmanager")
    response = client.get_secret_value(SecretId=secret_name)
    creds = json.loads(response["SecretString"])
    return {
        "host":     creds["host"],
        "port":     int(creds.get("port", 5432)),
        "dbname":   creds["dbname"],
        "user":     creds["username"],
        "password": creds["password"],  # fetched at runtime — never in terraform.tfstate
    }

DB_CONFIG = fetch_db_config()
```

Also update `modules/compute/main.tf` — replace the injected env var:

```bash
# Before:  Environment=DB_PASSWORD=${db_password}
# After:   Environment=DB_SECRET_NAME=${db_secret_name}
```

### 5. Add the GitHub OIDC provider and CI runner trust policy

In `end/main.tf`, register the OIDC provider:

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags            = local.common_tags
}
```

In `end/modules/iam/main.tf`, update the `ci_runner` role trust policy:

```hcl
Principal = { Federated = var.oidc_provider_arn }
Action    = "sts:AssumeRoleWithWebIdentity"
Condition = {
  StringEquals = {
    "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
    "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main"
  }
}
```

Open `end/.github/workflows/terraform-ci.yml` and note:
- `permissions: id-token: write` — required to request the OIDC token
- `role-to-assume: ${{ secrets.AWS_CI_ROLE_ARN }}` — the role ARN stored as a non-secret config value
- No `aws-access-key-id` or `aws-secret-access-key` inputs anywhere in the file

### 6. Wire modules in root `main.tf`

In `end/main.tf`, add the secrets and updated IAM module blocks:

```hcl
module "secrets" {
  source      = "./modules/secrets"
  project     = var.project
  environment = var.environment
  db_username = var.db_username
}

module "iam" {
  source            = "./modules/iam"
  project           = var.project
  environment       = var.environment
  github_repo       = var.github_repo
  oidc_provider_arn = aws_iam_openid_connect_provider.github.arn
  db_secret_arn     = module.secrets.db_secret_arn
  kms_key_arn       = module.secrets.kms_key_arn
}
```

Update `module "compute"` — replace the password input with the secret name:

```hcl
# Before:  db_password    = var.db_password
# After:
db_secret_name = module.secrets.db_secret_name
```

### 7. Add the ACM certificate and HTTPS listener

In `end/main.tf`, add the certificate and DNS validation resources:

```hcl
resource "aws_acm_certificate" "app" {
  domain_name       = var.domain_name
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
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
  name    = each.value.name; type = each.value.type
  ttl     = 60; records = [each.value.record]
}

resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}
```

Replace the HTTP forward listener with an HTTPS listener and an HTTP redirect:

```hcl
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443; protocol = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.app.certificate_arn
  default_action { type = "forward"; target_group_arn = aws_lb_target_group.app.arn }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.app.arn
  port = 80; protocol = "HTTP"
  default_action {
    type = "redirect"
    redirect { port = "443"; protocol = "HTTPS"; status_code = "HTTP_301" }
  }
}
```

### 8. Format, validate, and plan

```bash
cd end/
terraform fmt -recursive
terraform init -backend=false
terraform validate
```

Expected output:

```
Success! The configuration is valid.
```

```bash
terraform plan -var-file=dev.tfvars
```

Confirm these resources appear in the plan:
- `aws_iam_openid_connect_provider.github` — OIDC provider
- `module.secrets.aws_kms_key.app` — KMS CMK
- `module.secrets.aws_secretsmanager_secret.db` — encrypted secret
- `module.iam.aws_iam_role_policy_attachment.compute_read_secret` — the activation attachment
- `aws_lb_listener.https` — HTTPS forward listener
- `aws_lb_listener.http_redirect` — HTTP → HTTPS permanent redirect

## Expected outcomes

By the end of this demo, students should be able to:

1. Explain why plaintext secrets in Terraform state are a high-severity exposure and enumerate the additional leak vectors (CI logs, AMI snapshots, shell history, process lists)
2. Write a KMS key policy that grants both root admin access and Secrets Manager service access to prevent `InvalidKeyId` errors
3. Use `ignore_changes = [secret_string]` to allow secret rotation without Terraform overwriting the value on every apply
4. Attach an IAM policy to a role and explain why the policy resource alone grants no permissions (IAM is deny-by-default)
5. Configure a GitHub OIDC trust policy with scoped `StringEquals` conditions on `aud` and `sub` to eliminate stored AWS credentials from CI
6. Issue an ACM certificate with DNS validation and configure TLS 1.3 enforcement and HTTP-to-HTTPS redirect on an ALB
