"""A stand-in for the parts of Cloudflare's API that ansible/playbooks/_cf-api-token.yml and
_cf-tunnel.yml call, so server-create-host-tunnel.yml can be run end to end with no account,
and the Access calls server-create-fleet-ssh-access.yml makes (applications, reusable
policies, service tokens), and those _cf-access-app.yml makes for
server-create-browser-login.yml (an application and its app-scoped policies), with
_cf-dns.yml's records, deletes included. It keeps its state in memory, answers in
Cloudflare's envelope (success, errors, result), and never records an Authorization header.
An application, and an app-scoped policy, is answered as Cloudflare answers one: with ids,
timestamps and defaults the plays never sent, a public destination for its domain when it
holds none, session_duration in Go's long form (24h0m0s for 24h) and a policy's include
rules in reverse order, so _cf-access-app.yml's subset
compare is tested against more than its own echo. /__state holds them as written. Every
application and app-scoped policy write is counted in access_writes, as DNS writes are in
dns_writes, so a test can prove a converged run wrote nothing.
Four paths are not Cloudflare's: GET /__state returns what it holds, POST /__control changes how it behaves,
for the tests' adverse cases, and GET /__probe/<hostname> stands in for the edge, answering
an unauthenticated request with 403 when an Access application covers the hostname (or it
is `control`) and 200 otherwise; and GET /__login/<hostname> is the same edge seen by a
browser, for server-create-browser-login.yml: a 302 to the team's cloudflareaccess.com login
when an application with an `allow` policy covers the hostname (or it is `control`), and
200 otherwise. Every DNS write records whether such an application covered the name at that
moment, so a test can prove the login came first; a record DELETE can be made to answer
403 or 404 through /__control. Run with python3 -I; the one argument is
the port."""
import copy
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
         "apps": {}, "policies": {}, "service_tokens": [], "never_gate": False,
         "refuse_access": False, "dns_writes": [], "delete_answer": None,
         "access_writes": [], "ignore_app_field": None, "omit_on_read": [],
         "app_read_unsuccessful": False}

# What Cloudflare fills in on an application PUT or POST that leaves a field out.
APP_DEFAULTS = {"type": "self_hosted", "session_duration": "24h", "allowed_idps": [],
                "auto_redirect_to_identity": False, "app_launcher_visible": True,
                "options_preflight_bypass": False, "destinations": []}
APP_SETTINGS = ["name", "domain"] + list(APP_DEFAULTS)


def envelope(result=None, errors=None):
    return {"success": not errors, "errors": errors or [], "messages": [], "result": result}


def go_duration(d):
    """Cloudflare stores a duration and answers in Go's Duration.String() form: 24h0m0s."""
    units = {"h": 3600, "m": 60, "s": 1}
    total, num = 0, ""
    for c in str(d):
        if c.isdigit():
            num += c
        elif c in units and num:
            total, num = total + int(num) * units[c], ""
        else:
            return d
    if num:
        return d
    h, rest = divmod(total, 3600)
    m, sec = divmod(rest, 60)
    return f"{h}h{m}m{sec}s" if h else (f"{m}m{sec}s" if m else f"{sec}s")


def policy_view(pol):
    """An app-scoped policy as Cloudflare answers it."""
    return dict(pol, include=list(reversed(pol.get("include", []))), uid=pol["id"],
                created_at="2026-11-19T00:00:00Z", updated_at="2026-11-19T00:00:00Z",
                approval_required=False, isolation_required=False,
                purpose_justification_required=False, session_duration="24h", reusable=False)


def app_view(app):
    """An application as Cloudflare answers it: its defaults, ids and timestamps added."""
    view = dict(APP_DEFAULTS)
    view.update(app)
    view.update(uid=app["id"], aud="aud-" + app["id"][:8], created_at="2026-11-19T00:00:00Z",
                updated_at="2026-11-19T00:00:00Z", enable_binding_cookie=False,
                http_only_cookie_attribute=True, tags=[],
                self_hosted_domains=[app.get("domain")],
                destinations=view["destinations"] or [{"type": "public", "uri": app.get("domain")}],
                session_duration=go_duration(view["session_duration"]),
                policies=[policy_view(p) for p in app.get("policies", [])])
    for field in STATE["omit_on_read"]:
        view.pop(field, None)
    return view


def login_covers(host):
    """An application on `host` carrying an allow policy: what makes the edge ask a browser
    to log in."""
    return any(a.get("domain") == host and any(p.get("decision") == "allow" for p in a["policies"])
               for a in STATE["apps"].values())


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
        if path.startswith("/__login/") and method == "GET":
            host = path.removeprefix("/__login/")
            if host == "control" or (login_covers(host) and not STATE["never_gate"]):
                data = b""
                self.send_response(302)
                self.send_header("Location", f"https://sim.cloudflareaccess.com/cdn-cgi/access/login/{host}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return self.wfile.write(data)
            return self.reply(200, {"login": host, "open": True})
        if path == "/__control" and method == "POST":
            change = self.body()
            STATE["never_gate"] = bool(change.get("never_gate", STATE["never_gate"]))
            STATE["refuse_access"] = bool(change.get("refuse_access", STATE["refuse_access"]))
            # How a record DELETE answers: None as Cloudflare does, "refuse" a 403 that keeps
            # the record, "gone" a 404 with the record removed, as if deleted a moment before.
            if "delete_answer" in change:
                STATE["delete_answer"] = change["delete_answer"]
            if change.get("plant_tunnel"):
                t = change["plant_tunnel"]
                STATE["tunnels"][t["id"]] = {"id": t["id"], "name": t["name"], "deleted_at": None,
                                             "config_src": "local"}
            if change.get("plant_cname"):
                c = change["plant_cname"]
                rid = str(uuid.uuid4())
                STATE["records"][rid] = {"id": rid, "type": "CNAME", "name": c["name"],
                                         "content": c["content"], "proxied": True, "comment": None}
            if change.get("plant_app"):
                a = change["plant_app"]
                aid = str(uuid.uuid4())
                STATE["apps"][aid] = {"id": aid, "name": a["name"], "domain": a["domain"],
                                      "destinations": [], "policies": []}
            # Changes made by hand in the dashboard: fields set on every application, or on
            # the one whose domain is named, fields set on every app-scoped policy, an
            # address taken out of every include.
            for app in STATE["apps"].values():
                app.update(change.get("edit_apps", {}))
                if change.get("edit_app", {}).get("domain") == app.get("domain"):
                    app.update(change["edit_app"]["set"])
                for pol in app["policies"]:
                    pol.update(change.get("edit_app_policies", {}))
                    if change.get("drop_email"):
                        pol["include"] = [i for i in pol["include"]
                                          if i.get("email", {}).get("email") != change["drop_email"]]
            # A field an application PUT leaves as it was, as if Cloudflare ignored it, and
            # fields left out of every application read, as if Cloudflare omitted them.
            if "ignore_app_field" in change:
                STATE["ignore_app_field"] = change["ignore_app_field"]
            if "omit_on_read" in change:
                STATE["omit_on_read"] = change["omit_on_read"]
            # A read of one application answering 200 with success:false and no result, as
            # Cloudflare's envelope allows.
            if "app_read_unsuccessful" in change:
                STATE["app_read_unsuccessful"] = bool(change["app_read_unsuccessful"])
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
                             tunnel_secrets={}, apps={}, policies={}, never_gate=False,
                             refuse_access=False, dns_writes=[], delete_answer=None,
                             access_writes=[], ignore_app_field=None, omit_on_read=[],
                             app_read_unsuccessful=False)
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
            # As Cloudflare does, on 2026-11-19: a comment over 100 characters is refused.
            if len(b.get("comment") or "") > 100:
                return self.reply(400, envelope(errors=[{"code": 9313, "message": "DNS record comment exceeds the maximum length of 100 characters."}]))
            rid = p.rsplit("/", 1)[1] if method == "PUT" else str(uuid.uuid4())
            if method == "PUT" and rid not in STATE["records"]:
                return self.reply(404, envelope(errors=[{"code": 81044, "message": "Record not found"}]))
            STATE["records"][rid] = {"id": rid, "type": b.get("type"), "name": b.get("name"),
                                     "content": b.get("content"), "proxied": b.get("proxied"),
                                     "comment": b.get("comment")}
            STATE["dns_writes"].append({"name": b.get("name"), "login": login_covers(b.get("name"))})
            return self.reply(200, envelope(STATE["records"][rid]))
        if p.startswith(records + "/") and method == "DELETE":
            rid = p.rsplit("/", 1)[1]
            if STATE["delete_answer"] == "refuse":
                return self.reply(403, envelope(errors=[{"code": 10000, "message": "Authentication error: this token may not delete DNS"}]))
            if STATE["delete_answer"] == "gone":
                STATE["records"].pop(rid, None)
            if rid not in STATE["records"]:
                return self.reply(404, envelope(errors=[{"code": 81044, "message": "Record not found"}]))
            del STATE["records"][rid]
            return self.reply(200, envelope({"id": rid}))

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
            return self.reply(200, envelope([app_view(a) for a in STATE["apps"].values()]))
        if STATE["refuse_access"] and p.startswith(apps) and method in ("POST", "PUT"):
            return self.reply(403, envelope(errors=[{"code": 10000, "message": "Authentication error: this token may not edit Access"}]))
        # App-scoped policies, as _cf-access-app.yml writes them: listed, added, replaced.
        parts = p.removeprefix(apps + "/").split("/")
        if p.startswith(apps + "/") and len(parts) in (2, 3) and parts[1] == "policies":
            app = STATE["apps"].get(parts[0])
            if not app:
                return self.reply(404, envelope(errors=[{"code": 12130, "message": "application not found"}]))
            if len(parts) == 2 and method == "GET":
                return self.reply(200, envelope([policy_view(x) for x in app["policies"]]))
            if (len(parts) == 2 and method == "POST") or (len(parts) == 3 and method == "PUT"):
                b = self.body()
                if not b.get("name") or b.get("decision") not in ("allow", "bypass", "deny", "non_identity"):
                    return self.reply(400, envelope(errors=[{"code": 12000, "message": f"bad policy body: {sorted(b)}"}]))
                pid = parts[2] if len(parts) == 3 else str(uuid.uuid4())
                kept = [x for x in app["policies"] if x["id"] != pid]
                if len(parts) == 3 and len(kept) == len(app["policies"]):
                    return self.reply(404, envelope(errors=[{"code": 12130, "message": "policy not found"}]))
                pol = {"id": pid, "name": b["name"], "decision": b["decision"],
                       "precedence": b.get("precedence", 1), "include": b.get("include", []),
                       "exclude": b.get("exclude", []), "require": b.get("require", [])}
                app["policies"] = kept + [pol]
                STATE["access_writes"].append({"method": method, "kind": "policy",
                                               "domain": app.get("domain")})
                return self.reply(200, envelope(policy_view(pol)))
        # PUT replaces the application's settings whole, a field left out taking Cloudflare's
        # default, and, as the play reads back rather than assumes, keeps the policies
        # attached to it.
        if p.startswith(apps + "/") and len(parts) == 1 and method == "PUT":
            app = STATE["apps"].get(parts[0])
            if not app:
                return self.reply(404, envelope(errors=[{"code": 12130, "message": "application not found"}]))
            b = self.body()
            if not b.get("domain"):
                return self.reply(400, envelope(errors=[{"code": 12000, "message": f"bad application body: {sorted(b)}"}]))
            ignored = STATE["ignore_app_field"]
            kept = app.get(ignored)
            for field in APP_SETTINGS:
                app[field] = b.get(field, copy.deepcopy(APP_DEFAULTS.get(field)))
            if ignored:
                app[ignored] = kept
            STATE["access_writes"].append({"method": "PUT", "kind": "app", "domain": app["domain"]})
            return self.reply(200, envelope(app_view(app)))
        if p == apps and method == "POST":
            b = self.body()
            linked = [x.get("id") for x in b.get("policies", [])]
            if not b.get("domain") or any(pid not in STATE["policies"] for pid in linked):
                return self.reply(400, envelope(errors=[{"code": 12000, "message": f"bad application body: {sorted(b)}"}]))
            aid = str(uuid.uuid4())
            STATE["apps"][aid] = {"id": aid, "destinations": b.get("destinations", []),
                                  "policies": [dict(STATE["policies"][pid], precedence=i + 1)
                                               for i, pid in enumerate(linked)]}
            STATE["apps"][aid].update({f: b.get(f, copy.deepcopy(APP_DEFAULTS.get(f))) for f in APP_SETTINGS})
            STATE["access_writes"].append({"method": "POST", "kind": "app", "domain": b["domain"]})
            return self.reply(201, envelope(app_view(STATE["apps"][aid])))
        if p.startswith(apps + "/") and method in ("GET", "DELETE"):
            aid = p.rsplit("/", 1)[1]
            if aid not in STATE["apps"]:
                return self.reply(404, envelope(errors=[{"code": 12130, "message": "application not found"}]))
            if method == "DELETE":
                del STATE["apps"][aid]
                return self.reply(202, envelope({"id": aid}))
            if STATE["app_read_unsuccessful"]:
                return self.reply(200, {"success": False, "errors": [{"code": 10001, "message": "sim: unsuccessful read"}],
                                        "messages": [], "result": None})
            return self.reply(200, envelope(app_view(STATE["apps"][aid])))

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
