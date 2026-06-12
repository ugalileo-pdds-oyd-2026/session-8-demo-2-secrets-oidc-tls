data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  name_prefix = "${var.project}-${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # DB_PASSWORD env var is GONE.
  # DB_SECRET_NAME (the Secrets Manager secret name) is safe to inject — it is not a credential.
  user_data = <<-EOF
    #!/bin/bash
    set -e
    dnf update -y
    dnf install -y python3 python3-pip

    pip3 install boto3 psycopg2-binary

    mkdir -p /opt/media-app

    cat > /opt/media-app/main.py << 'PYEOF'
    import json, os, boto3
    from http.server import BaseHTTPRequestHandler, HTTPServer

    PORT = int(os.environ.get("PORT", "8080"))

    def fetch_db_config():
        secret_name = os.environ["DB_SECRET_NAME"]
        client = boto3.client("secretsmanager")
        response = client.get_secret_value(SecretId=secret_name)
        creds = json.loads(response["SecretString"])
        return {"host": creds["host"], "port": int(creds.get("port", 5432)),
                "dbname": creds["dbname"], "user": creds["username"], "password": creds["password"]}

    DB_CONFIG = fetch_db_config()
    print(f"Credentials loaded from: {os.environ['DB_SECRET_NAME']}")

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/health":
                self._respond(200, {"status": "ok"})
            elif self.path == "/config":
                cfg = {**DB_CONFIG, "password": "***"}
                self._respond(200, {"credential_source": "secrets_manager",
                                    "secret_name": os.environ["DB_SECRET_NAME"], "db": cfg})
            else:
                self._respond(404, {"error": "not found"})
        def _respond(self, s, b):
            p = json.dumps(b, indent=2).encode()
            self.send_response(s); self.send_header("Content-Type","application/json")
            self.send_header("Content-Length",str(len(p))); self.end_headers(); self.wfile.write(p)
        def log_message(self, f, *a): pass

    HTTPServer(("", PORT), Handler).serve_forever()
    PYEOF

    cat > /etc/systemd/system/media-app.service << SVCEOF
    [Unit]
    Description=Media App
    After=network.target

    [Service]
    Environment=PORT=8080
    Environment=DB_SECRET_NAME=${var.db_secret_name}
    ExecStart=/usr/bin/python3 /opt/media-app/main.py
    Restart=always

    [Install]
    WantedBy=multi-user.target
    SVCEOF

    systemctl daemon-reload
    systemctl enable --now media-app
  EOF
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.app_sg_id]
  iam_instance_profile   = var.instance_profile_name
  user_data              = local.user_data

  tags = merge(local.tags, { Name = "${local.name_prefix}-app" })
}

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = var.alb_target_group_arn
  target_id        = aws_instance.app.id
  port             = 8080
}
