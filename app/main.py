#!/usr/bin/env python3
"""
media-app — end/ version: fetches DB credentials from AWS Secrets Manager at startup.

Key difference from start/:
  BEFORE  os.environ.get("DB_PASSWORD")            ← plaintext in state + env
  AFTER   boto3 get_secret_value(SecretId=name)    ← runtime fetch, never in state

The only thing in the environment now is DB_SECRET_NAME (the secret's name/ARN),
which is safe to log and commit — it is NOT a credential.
The instance profile's IAM policy grants secretsmanager:GetSecretValue + kms:Decrypt
scoped to this specific secret and KMS key.
"""

import json
import os
import boto3
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.environ.get("PORT", "8080"))


def fetch_db_config():
    """Retrieve DB credentials from Secrets Manager at startup (not from env vars)."""
    secret_name = os.environ["DB_SECRET_NAME"]  # the secret name — safe to expose
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


# Credentials are loaded once at startup. A rotation agent would restart the process.
DB_CONFIG = fetch_db_config()
print(f"Credentials loaded from Secrets Manager: {os.environ['DB_SECRET_NAME']}")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ok"})
        elif self.path == "/config":
            cfg = {**DB_CONFIG, "password": "***"}
            self._respond(200, {
                "credential_source": "secrets_manager",   # ← the fix
                "secret_name": os.environ["DB_SECRET_NAME"],
                "db": cfg,
            })
        else:
            self._respond(404, {"error": "not found"})

    def _respond(self, status, body):
        payload = json.dumps(body, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    print(f"Starting on :{PORT}")
    HTTPServer(("", PORT), Handler).serve_forever()
