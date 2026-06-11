project     = "demo2"
environment = "dev"
github_repo = "YOUR_ORG/YOUR_REPO"
db_username = "appuser"

# ⚠️  This plaintext password is injected into EC2 user_data at apply time
# and stored in terraform.tfstate in cleartext — the gap we close in end/.
db_password = "changeme-before-prod"
