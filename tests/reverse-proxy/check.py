#!/usr/bin/env python3
"""Test client for the reverse-proxy examples. Talks to the proxy the way a browser would.

--mode protocol  against tests/reverse-proxy/backend.py behind the proxy
--mode app       against the real web-terminal-server behind the proxy
"""

import argparse
import base64
import http.client
import json
import os
import socket
import ssl
import struct
import sys
import time

SPOOFED = "203.0.113.7"
# marotte's MaxBytesReader caps a whole upload request at this size.
LARGEST_BODY = 256 << 20
failures = 0


def report(ok: bool, what: str) -> None:
    global failures
    print(("ok: " if ok else "FAIL: ") + what, flush=True)
    if not ok:
        failures += 1


class Proxy:
    def __init__(self, args: argparse.Namespace) -> None:
        self.scheme = args.scheme
        self.host = args.host
        self.connect = args.connect
        self.port = args.port or (443 if args.scheme == "https" else 80)
        self.http_port = args.http_port
        self.client_ip = args.client_ip
        self.auth = {}
        if args.password_env:
            token = base64.b64encode(f"admin:{os.environ[args.password_env]}".encode()).decode()
            self.auth = {"Authorization": f"Basic {token}"}

    def tls(self) -> ssl.SSLContext:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE  # test certificates only
        return ctx

    def request(self, method: str, path: str, body: bytes | None = None, headers: dict | None = None):
        # A pre-connected socket lets one HTTPConnection carry SNI and Host for app.example.com.
        conn = http.client.HTTPConnection(self.connect, self.port, timeout=30)
        conn.sock = self.socket(30)
        all_headers = {"Host": self.host, "User-Agent": "docs-check", **self.auth, **(headers or {})}
        sock = conn.sock
        conn.request(method, path, body=body, headers=all_headers)
        resp = conn.getresponse()
        resp.raw_socket = sock
        return conn, resp

    def socket(self, timeout: float) -> socket.socket:
        sock = socket.create_connection((self.connect, self.port), timeout=timeout)
        if self.scheme == "https":
            sock = self.tls().wrap_socket(sock, server_hostname=self.host)
        return sock

    def websocket(self, path: str, timeout: float = 30) -> tuple[socket.socket, int]:
        sock = self.socket(timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        lines = [
            f"GET {path} HTTP/1.1",
            f"Host: {self.host}",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Key: {key}",
            "Sec-WebSocket-Version: 13",
            "User-Agent: docs-check",
            *(f"{k}: {v}" for k, v in self.auth.items()),
        ]
        sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = sock.recv(1)
            if not chunk:
                break
            head += chunk
        status = int(head.split(b" ", 2)[1]) if head else 0
        return sock, status


def send_text(sock: socket.socket, text: str) -> None:
    payload = text.encode()
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(bytes([0x81, 0x80 | len(payload)]) + mask + masked)


def recv_exact(sock: socket.socket, n: int) -> bytes:
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    return data


def recv_frame(sock: socket.socket) -> tuple[int, bytes]:
    first, second = recv_exact(sock, 2)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", recv_exact(sock, 8))[0]
    return first & 0x0F, recv_exact(sock, length)


def first_event_delay(proxy: Proxy, path: str, deadline: float) -> tuple[float | None, str]:
    """Seconds from sending the request until the first SSE data line arrives, or None."""
    start = time.monotonic()
    _, resp = proxy.request("GET", path, headers={"Accept": "text/event-stream"})
    resp.raw_socket.settimeout(deadline)
    try:
        while True:
            line = resp.fp.readline()
            if not line:
                return None, resp.getheader("Content-Type", "")
            if line.startswith(b"data:"):
                return time.monotonic() - start, resp.getheader("Content-Type", "")
    except TimeoutError:
        return None, resp.getheader("Content-Type", "")
    finally:
        resp.raw_socket.close()


def redirect(proxy: Proxy) -> None:
    """Plain HTTP on port 80 must send the browser to the same address over HTTPS."""
    path = "/headers?from=http&n=1"
    conn = http.client.HTTPConnection(proxy.connect, proxy.http_port, timeout=30)
    conn.request("GET", path, headers={"Host": proxy.host, "User-Agent": "docs-check"})
    resp = conn.getresponse()
    location = resp.getheader("Location", "")
    report(
        resp.status in (301, 308) and location == f"https://{proxy.host}{path}",
        f"plain HTTP for {path} answers {resp.status} to {location!r}",
    )
    conn.close()


def large_upload(proxy: Proxy) -> None:
    """The largest body any app accepts, marotte's 256 MiB upload, must reach the backend whole."""
    total = LARGEST_BODY
    chunk = b"x" * (1 << 20)
    sock = proxy.socket(120)
    head = (
        f"POST /upload HTTP/1.1\r\nHost: {proxy.host}\r\nUser-Agent: docs-check\r\n"
        f"Content-Type: application/octet-stream\r\nContent-Length: {total}\r\nConnection: close\r\n\r\n"
    )
    try:
        sock.sendall(head.encode())
        for _ in range(total // len(chunk)):
            sock.sendall(chunk)
        resp = http.client.HTTPResponse(sock)
        resp.begin()
        body = resp.read()
        got = json.loads(body).get("bytes") if resp.status == 200 else f"status {resp.status}"
    except (ConnectionError, OSError, http.client.HTTPException, ValueError) as err:
        got = f"error {err}"
    finally:
        sock.close()
    report(got == total, f"a {total >> 20} MiB upload reaches the backend ({got})")


def slow_upload(proxy: Proxy, seconds: int) -> None:
    """An upload that takes longer than a minute to arrive must still reach the backend."""
    chunk = b"x" * 16384
    total = len(chunk) * seconds
    sock = proxy.socket(seconds + 60)
    head = (
        f"POST /upload HTTP/1.1\r\nHost: {proxy.host}\r\nUser-Agent: docs-check\r\n"
        f"Content-Type: application/octet-stream\r\nContent-Length: {total}\r\nConnection: close\r\n\r\n"
    )
    print(f"sending a {total} byte upload over {seconds}s", flush=True)
    try:
        sock.sendall(head.encode())
        for _ in range(seconds):
            sock.sendall(chunk)
            time.sleep(1)
        resp = http.client.HTTPResponse(sock)
        resp.begin()
        body = resp.read()
        got = json.loads(body).get("bytes") if resp.status == 200 else f"status {resp.status}"
    except (ConnectionError, OSError, http.client.HTTPException, ValueError) as err:
        got = f"error {err}"
    finally:
        sock.close()
    report(got == total, f"an upload that takes {seconds}s reaches the backend ({got})")


def protocol(proxy: Proxy, idle: int, slow: int) -> None:
    if proxy.scheme == "https":
        redirect(proxy)
    _, resp = proxy.request("GET", "/headers", headers={"X-Forwarded-For": SPOOFED})
    seen = json.loads(resp.read())
    report(seen.get("host") == proxy.host, f"the backend sees Host {seen.get('host')!r}")
    report(
        seen.get("x-forwarded-proto") == proxy.scheme,
        f"the backend sees X-Forwarded-Proto {seen.get('x-forwarded-proto')!r}",
    )
    forwarded = [part.strip() for part in seen.get("x-forwarded-for", "").split(",") if part.strip()]
    report(
        bool(forwarded) and forwarded[-1] == proxy.client_ip,
        f"X-Forwarded-For ends with this client's address {proxy.client_ip}: {forwarded}",
    )

    delay, _ = first_event_delay(proxy, "/sse", deadline=4)
    report(delay is not None and delay < 1.0, f"the first SSE event arrives unbuffered, after {delay}s")

    sock, status = proxy.websocket("/ws")
    report(status == 101, f"the WebSocket upgrade answers {status}")
    if status == 101:
        send_text(sock, "hello")
        report(recv_frame(sock) == (0x1, b"hello"), "the WebSocket echoes a message")
        print(f"waiting {idle}s with the WebSocket idle", flush=True)
        sock.settimeout(idle + 30)
        time.sleep(idle)
        try:
            send_text(sock, "still there")
            report(recv_frame(sock) == (0x1, b"still there"), f"the WebSocket survives {idle}s idle")
        except (ConnectionError, OSError) as err:
            report(False, f"the WebSocket survives {idle}s idle ({err})")
        sock.close()

    large_upload(proxy)
    slow_upload(proxy, slow)


def app(proxy: Proxy) -> None:
    _, resp = proxy.request("GET", "/healthz")
    report(resp.status == 200, f"GET /healthz through the proxy answers {resp.status}")

    # A spoofed first hop, so the app's log proves it reads X-Forwarded-For from the right.
    _, resp = proxy.request("POST", "/api/sessions", headers={"X-Forwarded-For": SPOOFED})
    created = json.loads(resp.read()) if resp.status == 201 else {}
    report(resp.status == 201, f"creating a terminal session answers {resp.status}")
    session = created.get("id", "")

    delay, content_type = first_event_delay(proxy, "/api/sessions/events", deadline=5)
    report(content_type.startswith("text/event-stream"), f"the session stream is {content_type!r}")
    report(delay is not None and delay < 2.0, f"the session stream's first event arrives after {delay}s")

    sock, status = proxy.websocket(f"/ws?session={session}", timeout=5)
    report(status == 101, f"the terminal WebSocket for a real session answers {status}")
    sock.settimeout(3)
    try:
        opcode, _ = recv_frame(sock)
        report(opcode != 0x8, "the terminal WebSocket stays open and sends data")
    except TimeoutError:
        report(True, "the terminal WebSocket stays open")
    sock.close()

    sock, status = proxy.websocket("/ws?session=unknown", timeout=10)
    code = None
    if status == 101:
        opcode, payload = recv_frame(sock)
        code = struct.unpack("!H", payload[:2])[0] if opcode == 0x8 and len(payload) >= 2 else None
    report(status == 101 and code == 4004, f"an unknown session upgrades, then closes with {code}")
    sock.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["protocol", "app"], required=True)
    parser.add_argument("--scheme", choices=["http", "https"], default="https")
    parser.add_argument("--host", default="app.example.com")
    parser.add_argument("--connect", default="172.30.0.2", help="the proxy's address")
    parser.add_argument("--port", type=int)
    parser.add_argument("--http-port", type=int, default=80, help="the proxy's plain HTTP port")
    parser.add_argument("--idle", type=int, default=100)
    parser.add_argument("--slow", type=int, default=70, help="seconds a slow upload takes to send")
    parser.add_argument("--password-env", help="environment variable holding the app password")
    parser.add_argument("--client-ip", default="172.30.0.10", help="this client's own address, as the proxy sees it")
    args = parser.parse_args()
    proxy = Proxy(args)
    if args.mode == "protocol":
        protocol(proxy, args.idle, args.slow)
    else:
        app(proxy)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
