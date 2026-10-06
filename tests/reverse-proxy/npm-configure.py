#!/usr/bin/env python3
"""Sets up Nginx Proxy Manager through its API with the values docs/reverse-proxy.md
tells a reader to enter: the first-start admin account, a custom certificate, then one
proxy host from npm-proxy-host.json with that certificate, Force SSL and
examples/reverse-proxy/nginx-proxy-manager/advanced.conf. The login form then follows the
guide's login steps: it adds the access list and edits the existing proxy host to forward
to HOST:PORT behind it.

A runner cannot get a Let's Encrypt certificate, so the test certificate goes through the
Custom Certificate path the guide gives for names on a home network.

    npm-configure.py CERT_FILE KEY_FILE
    npm-configure.py --login-password-env VAR --forward HOST:PORT
"""

import argparse
import json
import os
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
LOGIN_USER = "admin"  # the user name every login example uses


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


def sign_in() -> str:
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
    return call("POST", "/tokens", {"identity": EMAIL, "secret": PASSWORD})["token"]


def create_host(token: str, cert: bytes, key: bytes) -> None:
    if call("GET", "/nginx/proxy-hosts", token=token):
        print("ok: the proxy host already exists")
        return

    # Certificates, Add Certificate, Custom Certificate: create the entry, then upload both files.
    created = call("POST", "/nginx/certificates", {"provider": "other", "nice_name": "app.example.com"}, token=token)
    upload(f"/nginx/certificates/{created['id']}/upload", {"certificate": cert, "certificate_key": key}, token)
    print(f"ok: added custom certificate {created['id']}")

    host = json.loads((HERE / "npm-proxy-host.json").read_text())
    host["certificate_id"] = created["id"]
    host["advanced_config"] = (EXAMPLE / "advanced.conf").read_text()
    proxy = call("POST", "/nginx/proxy-hosts", host, token=token)
    print(f"ok: created proxy host {proxy['id']} for {proxy['domain_names']} with Force SSL")


def add_login(token: str, user: str, password: str, forward: str) -> None:
    # Access Lists, Add Access List: the name, Satisfy Any and Pass Auth to Upstream left off,
    # one Authorization and no Rules. The modal posts exactly this.
    access = call(
        "POST",
        "/nginx/access-lists",
        {
            "name": "login",
            "satisfy_any": False,
            "pass_auth": False,
            "items": [{"username": user, "password": password}],
            "clients": [],
        },
        token=token,
    )
    print(f"ok: created access list {access['id']}")

    hosts = [h for h in call("GET", "/nginx/proxy-hosts", token=token) if h["domain_names"] == ["app.example.com"]]
    if len(hosts) != 1:
        sys.exit(f"FAIL: expected one proxy host for app.example.com, found {len(hosts)}")
    # The proxy host's Edit dialog: the new Forward Hostname / IP and Forward Port, then the access list.
    forward_host, forward_port = forward.rsplit(":", 1)
    proxy = call(
        "PUT",
        f"/nginx/proxy-hosts/{hosts[0]['id']}",
        {"forward_host": forward_host, "forward_port": int(forward_port), "access_list_id": access["id"]},
        token=token,
    )
    print(
        f"ok: proxy host {proxy['id']} now forwards to {proxy['forward_host']}:{proxy['forward_port']}"
        f" behind access list {proxy['access_list_id']}"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("cert", type=Path, nargs="?", help="with KEY, create the proxy host")
    parser.add_argument("key", type=Path, nargs="?")
    parser.add_argument("--login-password-env", help="environment variable holding the access list's password")
    parser.add_argument("--forward", help="HOST:PORT the proxy host forwards to once it has the login")
    args = parser.parse_args()
    login = (args.login_password_env, args.forward)
    if args.cert and args.key and not any(login):
        create_host(sign_in(), args.cert.read_bytes(), args.key.read_bytes())
    elif all(login) and not args.cert:
        add_login(sign_in(), LOGIN_USER, os.environ[args.login_password_env], args.forward)
    else:
        parser.error("give either CERT_FILE KEY_FILE, or --login-password-env and --forward")
    return 0


if __name__ == "__main__":
    sys.exit(main())
