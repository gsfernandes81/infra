#!/usr/bin/env python3
"""The token broker against a stand-in GitHub, offline: python3 dev/hub/test_github_tokens.py

The stand-in verifies every JWT's RS256 signature with openssl against the App key's public
half, so a pass means the broker signed correctly — and it is calibrated: a JWT from a
different key is refused (test_wrong_key). Needs python3 and openssl, nothing else. Not in the
hub image: dev/hub/.dockerignore leaves it out.
"""

import base64
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
BROKER = os.path.join(HERE, "github-tokens")


def unb64(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


class Fake(BaseHTTPRequestHandler):
    pub = None
    posts = []

    def log_message(self, *args):
        pass

    def authorised(self):
        head, body, sig = self.headers["Authorization"].split()[1].split(".")
        with tempfile.NamedTemporaryFile() as f:
            f.write(unb64(sig))
            f.flush()
            ok = subprocess.run(["openssl", "dgst", "-sha256", "-verify", self.pub,
                                 "-signature", f.name], input=f"{head}.{body}".encode(),
                                capture_output=True).returncode == 0
        claims = json.loads(unb64(body))
        return ok and claims["iss"] == "123" and claims["exp"] - claims["iat"] <= 600

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self.authorised():
            return self.reply(401, {"message": "A JSON web token could not be decoded"})
        if "/nothere/" in self.path:
            return self.reply(404, {"message": "Not Found"})
        self.reply(200, {"id": 42})

    def do_POST(self):
        if not self.authorised():
            return self.reply(401, {"message": "A JSON web token could not be decoded"})
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        Fake.posts.append(body)
        name = body["repositories"][0]
        if name == "widened":
            return self.reply(201, {"token": "ghs_SECRET_widened", "expires_at": "x"})
        if name == "refused":
            return self.reply(422, {"message": "permissions exceed the app's"})
        self.reply(201, {"token": f"ghs_SECRET_{name}", "expires_at": "2026-10-27T05:00:00Z",
                         "permissions": body["permissions"],
                         "repositories": [{"full_name": f"owner/{name}"}]})


class Broker(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        d = cls.tmp.name
        cls.key = os.path.join(d, "app.pem")
        cls.other = os.path.join(d, "other.pem")
        Fake.pub = os.path.join(d, "app.pub")
        for k in (cls.key, cls.other):
            subprocess.run(["openssl", "genrsa", "-out", k, "2048"], check=True, capture_output=True)
        subprocess.run(["openssl", "rsa", "-in", cls.key, "-pubout", "-out", Fake.pub],
                       check=True, capture_output=True)
        cls.srv = HTTPServer(("127.0.0.1", 0), Fake)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.tmp.cleanup()

    def run_broker(self, repos, key=None, app_id="123", verb="once"):
        tokens = tempfile.mkdtemp(dir=self.tmp.name)
        env = {"PATH": os.environ["PATH"], "HUB_GITHUB_APP_ID": app_id,
               "HUB_GITHUB_KEY": key or self.key, "HUB_GITHUB_TOKENS": tokens,
               "HUB_GITHUB_API": f"http://127.0.0.1:{self.srv.server_port}",
               "HUB_GITHUB_PERMISSIONS": "contents=write,pull_requests=write"}
        env.update({f"HUB_REPO_{k}": v for k, v in repos.items()})
        out = subprocess.run([sys.executable, BROKER, verb], env=env, capture_output=True, text=True)
        return out, tokens

    def test_one_token_per_container_scoped_to_its_repo(self):
        Fake.posts.clear()
        out, tokens = self.run_broker({"INFRA_DEV": "owner/infra", "OR3_DEV": "owner/or3"})
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        for name, repo in (("infra-dev", "infra"), ("or3-dev", "or3")):
            path = os.path.join(tokens, name, "token")
            self.assertEqual(open(path).read(), f"ghs_SECRET_{repo}")
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            self.assertEqual(json.load(open(os.path.join(tokens, name, "meta.json")))["repo"],
                             f"owner/{repo}")
        self.assertEqual(sorted(p["repositories"] for p in Fake.posts), [["infra"], ["or3"]])
        self.assertNotIn("SECRET", out.stdout + out.stderr)

    def test_widened_refused_and_missing_are_not_written(self):
        out, tokens = self.run_broker({"A": "owner/widened", "B": "owner/refused",
                                       "C": "nothere/x", "D": "owner/ok"})
        self.assertEqual(out.returncode, 1)
        for name in "abc":
            self.assertFalse(os.path.exists(os.path.join(tokens, name, "token")), name)
            self.assertTrue(os.path.isdir(os.path.join(tokens, name)), name)
        self.assertTrue(os.path.exists(os.path.join(tokens, "d", "token")))
        self.assertIn("scoped to every repo", out.stdout)
        self.assertIn("HTTP 422 permissions exceed", out.stdout)
        self.assertNotIn("SECRET", out.stdout + out.stderr)

    def test_wrong_key_is_refused_by_the_stand_in(self):
        out, tokens = self.run_broker({"INFRA_DEV": "owner/infra"}, key=self.other)
        self.assertEqual(out.returncode, 1)
        self.assertFalse(os.path.exists(os.path.join(tokens, "infra-dev", "token")))
        self.assertIn("HTTP 401", out.stdout)

    def test_off_makes_the_directories_and_mints_nothing(self):
        out, tokens = self.run_broker({"X_DEV": "owner/x"}, app_id="")
        self.assertEqual(out.returncode, 0)
        self.assertEqual(os.listdir(os.path.join(tokens, "x-dev")), [])
        self.assertIn("off:", out.stdout)

    def test_hosts_are_the_containers_sorted(self):
        out, _ = self.run_broker({"OR3_DEV": "owner/or3", "INFRA_DEV": "owner/infra"}, verb="hosts")
        self.assertEqual(out.stdout.strip(), "infra-dev or3-dev")

    def test_dirs_removes_a_container_no_longer_named(self):
        tokens = tempfile.mkdtemp(dir=self.tmp.name)
        for name in ("gone-dev", "kept-dev"):
            os.makedirs(os.path.join(tokens, name))
            open(os.path.join(tokens, name, "token"), "w").write("ghs_SECRET_old")
        open(os.path.join(tokens, ".ready"), "w").close()
        env = {"PATH": os.environ["PATH"], "HUB_GITHUB_TOKENS": tokens, "HUB_REPO_KEPT_DEV": "owner/kept"}
        out = subprocess.run([sys.executable, BROKER, "dirs"], env=env, capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(sorted(os.listdir(tokens)), [".ready", "kept-dev"])
        self.assertTrue(os.path.exists(os.path.join(tokens, "kept-dev", "token")))
        self.assertNotIn("SECRET", out.stdout + out.stderr)

    def test_a_malformed_repo_stops_it(self):
        out, _ = self.run_broker({"Y": "a b/c"}, verb="dirs")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("is not owner/repo", out.stderr)


if __name__ == "__main__":
    unittest.main()
