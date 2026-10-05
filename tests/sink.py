#!/usr/bin/env python3
"""Test-only webhook receiver: stores every POST body, GET /received lists them."""

import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

received: list = []
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            item = json.loads(body)
        except ValueError:
            item = body.decode("utf-8", "replace")
        with lock:
            received.append(item)
        self.send_response(204)
        self.end_headers()

    def do_GET(self) -> None:
        with lock:
            body = json.dumps(received).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    port = int(os.environ.get("SINK_PORT", "8080"))
    ThreadingHTTPServer(("", port), Handler).serve_forever()
