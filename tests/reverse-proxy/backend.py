#!/usr/bin/env python3
"""Neutral test backend for the reverse-proxy protocol checks. Never shown in a guide.

GET /headers   the request headers as JSON
GET /sse       three events 1.5 s apart, with no X-Accel-Buffering header
POST /upload   the number of body bytes received
GET /ws        a WebSocket that echoes every text frame
"""

import base64
import hashlib
import json
import struct
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def read_exact(sock, n: int) -> bytes:
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("peer closed")
        data += chunk
    return data


def read_frame(sock) -> tuple[int, bytes]:
    first, second = read_exact(sock, 2)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", read_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(sock, 8))[0]
    mask = read_exact(sock, 4) if second & 0x80 else b"\0\0\0\0"
    payload = bytes(b ^ mask[i % 4] for i, b in enumerate(read_exact(sock, length)))
    return first & 0x0F, payload


def write_frame(sock, opcode: int, payload: bytes) -> None:
    header = bytes([0x80 | opcode])
    if len(payload) < 126:
        header += bytes([len(payload)])
    elif len(payload) < 1 << 16:
        header += bytes([126]) + struct.pack("!H", len(payload))
    else:
        header += bytes([127]) + struct.pack("!Q", len(payload))
    sock.sendall(header + payload)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send_json(self, value) -> None:
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if path == "/headers":
            self.send_json({k.lower(): v for k, v in self.headers.items()})
        elif path == "/sse":
            self.serve_sse()
        elif path == "/ws":
            self.serve_ws()
        else:
            self.send_error(404)

    def do_POST(self) -> None:
        if self.path != "/upload":
            self.send_error(404)
            return
        remaining = int(self.headers.get("Content-Length", "0"))
        received = 0
        while remaining:
            chunk = self.rfile.read(min(remaining, 1 << 16))
            if not chunk:
                break
            received += len(chunk)
            remaining -= len(chunk)
        self.send_json({"bytes": received})

    def serve_sse(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        for n in range(1, 4):
            self.wfile.write(f"data: {n}\n\n".encode())
            self.wfile.flush()
            time.sleep(1.5)
        self.close_connection = True

    def serve_ws(self) -> None:
        key = self.headers.get("Sec-WebSocket-Key")
        if "websocket" not in self.headers.get("Upgrade", "").lower() or not key:
            self.send_error(426, "WebSocket upgrade required")
            return
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()
        sock = self.connection
        try:
            while True:
                opcode, payload = read_frame(sock)
                if opcode == 0x8:
                    write_frame(sock, 0x8, payload[:2])
                    break
                if opcode == 0x9:
                    write_frame(sock, 0xA, payload)
                elif opcode in (0x1, 0x2):
                    write_frame(sock, opcode, payload)
        except ConnectionError:
            pass  # the client hung up without a close frame; nothing to answer
        self.close_connection = True

    def log_message(self, fmt: str, *args) -> None:
        print(f"{self.address_string()} {fmt % args}", flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("", 7681), Handler).serve_forever()
