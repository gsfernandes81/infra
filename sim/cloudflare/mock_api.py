"""A stand-in for the parts of Cloudflare's API that ansible/playbooks/_cf-api-token.yml and
_cf-tunnel.yml call, so server-create-host-tunnel.yml can be run end to end with no account.
It keeps its state in memory, answers in Cloudflare's envelope (success, errors, result),
and never records an Authorization header. Two paths are not Cloudflare's: GET /__state
returns what it holds, and POST /__control changes how it behaves, for the test's adverse
cases. Run with python3 -I; the one argument is the port."""
import json
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

TOKEN = "sim-token"
ZONE_ID = "zone-sim"
ACCOUNT_ID = "acct-sim"
STATE = {"tunnels": {}, "records": {}, "requests": [],
         "refuse_writes": False, "tunnel_secrets": {}}


def envelope(result=None, errors=None):
    return {"success": not errors, "errors": errors or [], "messages": [], "result": result}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}")

    def authed(self):
        return self.headers.get("Authorization") == f"Bearer {TOKEN}"

    def route(self, method):
        url = urlparse(self.path)
        path, query = url.path, parse_qs(url.query)
        if path == "/__state":
            return self.reply(200, STATE)
        if path == "/__control" and method == "POST":
            change = self.body()
            STATE["refuse_writes"] = bool(change.get("refuse_writes", STATE["refuse_writes"]))
            if change.get("delete_tunnels"):
                for t in STATE["tunnels"].values():
                    t["deleted_at"] = "2026-11-02T00:00:00Z"
            if change.get("repoint_records"):
                for r in STATE["records"].values():
                    r["content"] = "elsewhere.example.invalid"
            if change.get("reset"):
                STATE.update(tunnels={}, records={}, refuse_writes=False, tunnel_secrets={})
            return self.reply(200, {"ok": True})

        STATE["requests"].append(f"{method} {path}")
        if not self.authed():
            return self.reply(401, envelope(errors=[{"code": 1000, "message": "Invalid API Token"}]))
        p = path.removeprefix("/client/v4")

        if p == "/user/tokens/verify":
            return self.reply(200, envelope({"id": "tok-sim", "status": "active"}))
        if p == "/zones" and method == "GET":
            name = query.get("name", [""])[0]
            return self.reply(200, envelope([{"id": ZONE_ID, "name": name,
                                               "account": {"id": ACCOUNT_ID}}]))

        tunnels = f"/accounts/{ACCOUNT_ID}/cfd_tunnel"
        if p == tunnels and method == "POST":
            if STATE["refuse_writes"]:
                return self.reply(403, envelope(errors=[{"code": 10000, "message": "Authentication error: this token may not edit tunnels"}]))
            b = self.body()
            if b.get("config_src") != "local" or not b.get("name") or not b.get("tunnel_secret"):
                return self.reply(400, envelope(errors=[{"code": 1001, "message": f"bad tunnel body: {sorted(b)}"}]))
            tid = str(uuid.uuid4())
            STATE["tunnels"][tid] = {"id": tid, "name": b["name"], "deleted_at": None,
                                     "config_src": b["config_src"]}
            STATE["tunnel_secrets"][tid] = b["tunnel_secret"]
            return self.reply(200, envelope(STATE["tunnels"][tid]))
        if p.startswith(tunnels + "/") and method == "GET":
            t = STATE["tunnels"].get(p.rsplit("/", 1)[1])
            if not t:
                return self.reply(404, envelope(errors=[{"code": 1003, "message": "Tunnel not found"}]))
            return self.reply(200, envelope(t))

        records = f"/zones/{ZONE_ID}/dns_records"
        if p == records and method == "GET":
            want_type = query.get("type", [""])[0]
            want_name = query.get("name", [""])[0]
            found = [r for r in STATE["records"].values()
                     if r["type"] == want_type and r["name"] == want_name]
            return self.reply(200, envelope(found))
        if (p == records and method == "POST") or (p.startswith(records + "/") and method == "PUT"):
            if STATE["refuse_writes"]:
                return self.reply(403, envelope(errors=[{"code": 10000, "message": "Authentication error: this token may not edit DNS"}]))
            b = self.body()
            rid = p.rsplit("/", 1)[1] if method == "PUT" else str(uuid.uuid4())
            if method == "PUT" and rid not in STATE["records"]:
                return self.reply(404, envelope(errors=[{"code": 81044, "message": "Record not found"}]))
            STATE["records"][rid] = {"id": rid, "type": b.get("type"), "name": b.get("name"),
                                     "content": b.get("content"), "proxied": b.get("proxied"),
                                     "comment": b.get("comment")}
            return self.reply(200, envelope(STATE["records"][rid]))

        return self.reply(404, envelope(errors=[{"code": 7003, "message": f"no route {method} {p}"}]))

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
