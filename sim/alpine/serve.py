"""Stand-ins for the two servers the setup plays reach, for sim/alpine/run-setup-plays.sh.

    python3 -I serve.py <port> <dir>

GET /stable/<file>  serves <dir>/<file>, as pkgs.tailscale.com/stable/ serves tarballs.
POST /<anything>    is an ntfy topic: it records the path and body and answers with the
                    status set through /__control (200 until then).
GET /__state        the posts so far, as JSON.
POST /__control     {"ntfy_status": <int>}.
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
ROOT = os.path.realpath(sys.argv[2])
STATE = {"posts": [], "ntfy_status": 200}


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body=b"", ctype="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/__state":
            return self._send(200, json.dumps(STATE).encode())
        if self.path.startswith("/stable/"):
            name = os.path.basename(self.path)
            path = os.path.join(ROOT, name)
            if name and os.path.isfile(path):
                with open(path, "rb") as f:
                    return self._send(200, f.read(), "application/gzip")
        return self._send(404, b'{"error": "not found"}')

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == "/__control":
            STATE.update(json.loads(body))
            return self._send(200, b"{}")
        STATE["posts"].append({
            "path": self.path,
            "title": self.headers.get("Title", ""),
            "body": body.decode(errors="replace"),
        })
        return self._send(STATE["ntfy_status"], b'{"id": "sim"}')

    def log_message(self, fmt, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
