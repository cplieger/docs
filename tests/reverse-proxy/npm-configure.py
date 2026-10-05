#!/usr/bin/env python3
"""Sets up Nginx Proxy Manager through its API with the values docs/reverse-proxy.md
tells a reader to enter: the first-start admin account, a custom certificate, then one
proxy host from npm-proxy-host.json with that certificate, Force SSL and
examples/reverse-proxy/nginx-proxy-manager/advanced.conf.

A runner cannot get a Let's Encrypt certificate, so the test certificate goes through the
Custom Certificate path the guide gives for names on a home network.

    npm-configure.py CERT_FILE KEY_FILE
"""

import json
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

API = "http://127.0.0.1:81/api"
HERE = Path(__file__).resolve().parent
EXAMPLE = HERE.parents[1] / "examples/reverse-proxy/nginx-proxy-manager"
EMAIL = "admin@example.com"
PASSWORD = "docs-test-password"


def call(method: str, path: str, body: dict | None = None, token: str = ""):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{API}{path}", data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read() or b"null")


def upload(path: str, files: dict[str, bytes], token: str):
    """POST files as multipart/form-data, the way the Custom Certificate dialog sends them."""
    boundary = uuid.uuid4().hex
    body = b""
    for name, content in files.items():
        body += (
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; filename="{name}.pem"\r\n'
            "Content-Type: application/x-pem-file\r\n\r\n"
        ).encode() + content + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    req = urllib.request.Request(f"{API}{path}", data=body, method="POST")
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read() or b"null")


def wait_for_api() -> dict:
    for _ in range(60):
        try:
            return call("GET", "/")
        except (urllib.error.URLError, ConnectionError):
            time.sleep(5)
    sys.exit("FAIL: the Nginx Proxy Manager API never answered")


def main() -> int:
    cert, key = (Path(arg).read_bytes() for arg in sys.argv[1:3])
    status = wait_for_api()
    if not status.get("setup"):
        # The first-start page posts exactly this when you create the admin account.
        call("POST", "/users", {
            "name": "Admin",
            "nickname": "Admin",
            "email": EMAIL,
            "auth": {"type": "password", "secret": PASSWORD},
        })
        print("ok: created the admin account")
    token = call("POST", "/tokens", {"identity": EMAIL, "secret": PASSWORD})["token"]
    if call("GET", "/nginx/proxy-hosts", token=token):
        print("ok: the proxy host already exists")
        return 0

    # Certificates, Add Certificate, Custom Certificate: create the entry, then upload both files.
    created = call("POST", "/nginx/certificates", {"provider": "other", "nice_name": "app.example.com"}, token=token)
    upload(f"/nginx/certificates/{created['id']}/upload", {"certificate": cert, "certificate_key": key}, token)
    print(f"ok: added custom certificate {created['id']}")

    host = json.loads((HERE / "npm-proxy-host.json").read_text())
    host["certificate_id"] = created["id"]
    host["advanced_config"] = (EXAMPLE / "advanced.conf").read_text()
    proxy = call("POST", "/nginx/proxy-hosts", host, token=token)
    print(f"ok: created proxy host {proxy['id']} for {proxy['domain_names']} with Force SSL")
    return 0


if __name__ == "__main__":
    sys.exit(main())
