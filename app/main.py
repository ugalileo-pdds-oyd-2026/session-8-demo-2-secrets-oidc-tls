#!/usr/bin/env python3
"""
media-app — minimal HTTP server for the Demo 2 start/ baseline.

Reads database credentials from ENVIRONMENT VARIABLES injected via EC2 user_data.
This is the INSECURE baseline the demo closes.

Security gap:
  - DB_PASSWORD arrives through Terraform user_data  → lands in terraform.tfstate in cleartext
  - Anyone with read access to state owns the database password
"""

import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.environ.get("PORT", "8080"))


def get_db_config():
    """Return DB connection config — sourced from plaintext environment variables."""
    return {
        "host": os.environ.get("DB_HOST", "not-set"),
        "port": int(os.environ.get("DB_PORT", "5432")),
        "dbname": os.environ.get("DB_NAME", "not-set"),
        "user": os.environ.get("DB_USER", "appuser"),
        # ⚠️  Plaintext password — injected via Terraform user_data, stored in state
        "password": os.environ.get("DB_PASSWORD", "not-set"),
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ok"})
        elif self.path == "/config":
            cfg = get_db_config()
            cfg["password"] = "***"   # masked in response, but still in process env + state
            self._respond(200, {
                "credential_source": "environment_variable",  # ← the problem
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
        pass  # suppress access-log noise in demo output


if __name__ == "__main__":
    print(f"Starting on :{PORT}")
    print("⚠️  Credential source: DB_PASSWORD environment variable (plaintext in state)")
    HTTPServer(("", PORT), Handler).serve_forever()
