project     = "demo2"
environment = "dev"
github_repo = "ugalileo-pdds-oyd-2026/session-8-demo-2-secrets-oidc-tls"
db_username = "appuser"

# ⚠️  This plaintext password is injected into EC2 user_data at apply time
# and stored in terraform.tfstate in cleartext — the gap we close in end/.
db_password = "changeme-before-prod"
