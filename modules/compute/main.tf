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

  # ⚠️ Plaintext password injected into user_data → stored in terraform.tfstate
  user_data = <<-EOF
    #!/bin/bash
    set -e
    dnf update -y
    dnf install -y python3 python3-pip

    mkdir -p /opt/media-app

    cat > /opt/media-app/main.py << 'PYEOF'
    import json, os
    from http.server import BaseHTTPRequestHandler, HTTPServer

    PORT = int(os.environ.get("PORT", "8080"))

    def get_db_config():
        return {
            "host":     os.environ.get("DB_HOST", "not-set"),
            "port":     int(os.environ.get("DB_PORT", "5432")),
            "dbname":   os.environ.get("DB_NAME", "not-set"),
            "user":     os.environ.get("DB_USER", "appuser"),
            "password": os.environ.get("DB_PASSWORD", "not-set"),  # ⚠️ plaintext
        }

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/health":
                self._respond(200, {"status": "ok"})
            elif self.path == "/config":
                cfg = get_db_config(); cfg["password"] = "***"
                self._respond(200, {"credential_source": "environment_variable", "db": cfg})
            else:
                self._respond(404, {"error": "not found"})
        def _respond(self, s, b):
            p = json.dumps(b, indent=2).encode()
            self.send_response(s); self.send_header("Content-Type","application/json")
            self.send_header("Content-Length",str(len(p))); self.end_headers(); self.wfile.write(p)
        def log_message(self, f, *a): pass

    HTTPServer(("", PORT), Handler).serve_forever()
    PYEOF

    # ⚠️ Plaintext DB credentials in environment — visible in process list and state
    cat > /etc/systemd/system/media-app.service << SVCEOF
    [Unit]
    Description=Media App
    After=network.target

    [Service]
    Environment=PORT=8080
    Environment=DB_HOST=${var.db_host}
    Environment=DB_NAME=${var.db_name}
    Environment=DB_USER=${var.db_username}
    Environment=DB_PASSWORD=${var.db_password}
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
