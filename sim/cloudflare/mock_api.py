"""A stand-in for the parts of Cloudflare's API that ansible/playbooks/_cf-api-token.yml and
_cf-tunnel.yml call, so server-create-host-tunnel.yml can be run end to end with no account,
and the Access calls server-create-fleet-ssh-access.yml makes (applications, reusable
policies, service tokens). It keeps its state in memory, answers in Cloudflare's envelope
(success, errors, result), and never records an Authorization header. Three paths are not
Cloudflare's: GET /__state returns what it holds, POST /__control changes how it behaves,
for the tests' adverse cases, and GET /__probe/<hostname> stands in for the edge, answering
an unauthenticated request with 403 when an Access application covers the hostname (or it
is `control`) and 200 otherwise. Run with python3 -I; the one argument is the port."""
import json
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

TOKEN = "sim-token"
ZONE_ID = "zone-sim"
ACCOUNT_ID = "acct-sim"
STATE = {"tunnels": {}, "records": {}, "requests": [],
         "refuse_writes": False, "refuse_dns": False, "tunnel_secrets": {},
         "apps": {}, "policies": {}, "service_tokens": [], "never_gate": False}


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
        if path.startswith("/__probe/") and method == "GET":
            host = path.removeprefix("/__probe/")
            covered = any(a.get("domain") == host for a in STATE["apps"].values())
            gated = host == "control" or (covered and not STATE["never_gate"])
            return self.reply(403 if gated else 200, {"probe": host})
        if path == "/__control" and method == "POST":
            change = self.body()
            STATE["never_gate"] = bool(change.get("never_gate", STATE["never_gate"]))
            if "service_tokens" in change:
                STATE["service_tokens"] = change["service_tokens"]
            STATE["refuse_writes"] = bool(change.get("refuse_writes", STATE["refuse_writes"]))
            STATE["refuse_dns"] = bool(change.get("refuse_dns", STATE["refuse_dns"]))
            if change.get("unproxy_records"):
                for r in STATE["records"].values():
                    r["proxied"] = False
            if change.get("plant_a_record"):
                rid = str(uuid.uuid4())
                STATE["records"][rid] = {"id": rid, "type": "A", "name": change["plant_a_record"],
                                         "content": "192.0.2.1", "proxied": False, "comment": None}
            if change.get("delete_tunnels"):
                for t in STATE["tunnels"].values():
                    t["deleted_at"] = "2026-11-02T00:00:00Z"
            if change.get("repoint_records"):
                for r in STATE["records"].values():
                    r["content"] = "elsewhere.example.invalid"
            if change.get("reset"):
                STATE.update(tunnels={}, records={}, refuse_writes=False, refuse_dns=False,
                             tunnel_secrets={}, apps={}, policies={}, never_gate=False)
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
            # Cloudflare refuses a second live tunnel of the same name.
            if any(t["name"] == b["name"] and not t["deleted_at"] for t in STATE["tunnels"].values()):
                return self.reply(409, envelope(errors=[{"code": 1013, "message": "You already have a tunnel with this name"}]))
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
            if STATE["refuse_writes"] or STATE["refuse_dns"]:
                return self.reply(403, envelope(errors=[{"code": 10000, "message": "Authentication error: this token may not edit DNS"}]))
            b = self.body()
            # Cloudflare refuses a CNAME at a name that already holds another record type.
            clash = [r for r in STATE["records"].values()
                     if r["name"] == b.get("name") and r["type"] != b.get("type")]
            if clash:
                return self.reply(400, envelope(errors=[{"code": 81053, "message": "An A, AAAA, or CNAME record with that host already exists."}]))
            rid = p.rsplit("/", 1)[1] if method == "PUT" else str(uuid.uuid4())
            if method == "PUT" and rid not in STATE["records"]:
                return self.reply(404, envelope(errors=[{"code": 81044, "message": "Record not found"}]))
            STATE["records"][rid] = {"id": rid, "type": b.get("type"), "name": b.get("name"),
                                     "content": b.get("content"), "proxied": b.get("proxied"),
                                     "comment": b.get("comment")}
            return self.reply(200, envelope(STATE["records"][rid]))

        access = f"/accounts/{ACCOUNT_ID}/access"
        if p == access + "/service_tokens" and method == "GET":
            return self.reply(200, envelope(STATE["service_tokens"]))

        # Reusable policies: the play writes the whole policy, so PUT replaces it.
        if p == access + "/policies" and method == "GET":
            return self.reply(200, envelope(list(STATE["policies"].values())))
        if (p == access + "/policies" and method == "POST") or \
                (p.startswith(access + "/policies/") and method in ("GET", "PUT")):
            pid = p.rsplit("/", 1)[1] if p != access + "/policies" else str(uuid.uuid4())
            if method != "POST" and pid not in STATE["policies"]:
                return self.reply(404, envelope(errors=[{"code": 12130, "message": "policy not found"}]))
            if method == "GET":
                return self.reply(200, envelope(STATE["policies"][pid]))
            b = self.body()
            if not b.get("name") or not b.get("decision"):
                return self.reply(400, envelope(errors=[{"code": 12000, "message": f"bad policy body: {sorted(b)}"}]))
            STATE["policies"][pid] = {"id": pid, "name": b["name"], "decision": b["decision"],
                                      "include": b.get("include", []), "exclude": b.get("exclude", []),
                                      "require": b.get("require", [])}
            return self.reply(200, envelope(STATE["policies"][pid]))

        # Applications: created already linked to policies by id, as the play asks.
        apps = access + "/apps"
        if p == apps and method == "GET":
            return self.reply(200, envelope(list(STATE["apps"].values())))
        if p == apps and method == "POST":
            b = self.body()
            linked = [x.get("id") for x in b.get("policies", [])]
            if not b.get("domain") or any(pid not in STATE["policies"] for pid in linked):
                return self.reply(400, envelope(errors=[{"code": 12000, "message": f"bad application body: {sorted(b)}"}]))
            aid = str(uuid.uuid4())
            STATE["apps"][aid] = {"id": aid, "name": b.get("name"), "domain": b["domain"],
                                  "destinations": b.get("destinations", []),
                                  "policies": [dict(STATE["policies"][pid], precedence=i + 1)
                                               for i, pid in enumerate(linked)]}
            return self.reply(201, envelope(STATE["apps"][aid]))
        if p.startswith(apps + "/") and method in ("GET", "DELETE"):
            aid = p.rsplit("/", 1)[1]
            if aid not in STATE["apps"]:
                return self.reply(404, envelope(errors=[{"code": 12130, "message": "application not found"}]))
            if method == "DELETE":
                del STATE["apps"][aid]
                return self.reply(202, envelope({"id": aid}))
            return self.reply(200, envelope(STATE["apps"][aid]))

        return self.reply(404, envelope(errors=[{"code": 7003, "message": f"no route {method} {p}"}]))

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")

    def do_DELETE(self):
        self.route("DELETE")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
