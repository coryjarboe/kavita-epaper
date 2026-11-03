"""Minimal fake Kavita for the kavita-epaper tests. Usage: kavita_stub.py PORT

Users alice and bob (password "pw"). Tokens are JWT-shaped with Kavita-like
claims; sizes are set via JWT_PAD / REFRESH_LEN env vars. Control endpoints
(/_deny, /_allow, /_expire, /_hits, /_reset) let the test flip permissions,
expire a user's access token and count cover fetches.
"""
import base64
import io
import json
import os
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from PIL import Image

PORT = int(sys.argv[1])
JWT_PAD = int(os.environ.get("JWT_PAD", "0"))
REFRESH_LEN = int(os.environ.get("REFRESH_LEN", "384"))
USERS = {"alice": 1, "bob": 2}
ROLES = ["Admin", "Pleb", "Download", "Change Password", "Bookmark",
         "Change Restriction", "Login", "Promote", "Read Only"]

lock = threading.Lock()
tokens = {}          # access token -> username
expired = set()      # access tokens that now get 401
refresh = {}         # refresh token -> username
deny = set()         # (username, kind, id)
hits = {}            # "user:kind:id" -> count


def b64(b):
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def make_jwt(user):
    now = int(time.time())
    claims = {"nameid": user, "role": ROLES, "nbf": now, "exp": now + 3600,
              "iat": now, "jti": secrets.token_hex(16)}
    if JWT_PAD:
        claims["pad"] = "x" * JWT_PAD
    return ".".join([b64(json.dumps({"alg": "HS512", "typ": "JWT"}).encode()),
                     b64(json.dumps(claims).encode()), b64(secrets.token_bytes(64))])


def issue(user):
    t = make_jwt(user)
    r = base64.b64encode(secrets.token_bytes(REFRESH_LEN)).decode()[:REFRESH_LEN]
    with lock:
        tokens[t] = user
        refresh[r] = user
    return t, r


def png(shade):
    buf = io.BytesIO()
    Image.new("RGB", (60, 90), (shade, 80, 200 - shade)).save(buf, "PNG")
    return buf.getvalue()


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body=b"", ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def user(self):
        auth = self.headers.get("Authorization", "")
        t = auth[7:] if auth.startswith("Bearer ") else ""
        with lock:
            if t in expired:
                return None
            return tokens.get(t)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_POST(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path == "/api/Account/login":
            b = self.body()
            if b.get("username") in USERS and b.get("password") == "pw":
                t, r = issue(b["username"])
                return self.send(200, {"username": b["username"], "token": t,
                                       "refreshToken": r, "apiKey": secrets.token_hex(18),
                                       "id": USERS[b["username"]], "email": None})
            return self.send(401, {"message": "bad"})
        if u.path == "/api/Account/refresh-token":
            b = self.body()
            with lock:
                user = refresh.pop(b.get("refreshToken"), None)
            if not user:
                return self.send(401, {})
            t, r = issue(user)
            return self.send(200, {"token": t, "refreshToken": r})
        if u.path in ("/_deny", "/_allow"):
            key = (q["user"], q["kind"], q["id"])
            with lock:
                (deny.add if u.path == "/_deny" else deny.discard)(key)
            return self.send(200, {})
        if u.path == "/_expire":
            with lock:
                for t, user in tokens.items():
                    if user == q["user"]:
                        expired.add(t)
            return self.send(200, {})
        if u.path == "/_reset":
            with lock:
                hits.clear()
                deny.clear()
            return self.send(200, {})
        return self.send(404, {})

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path == "/_hits":
            with lock:
                return self.send(200, dict(hits))
        user = self.user()
        if user is None:
            return self.send(401, {})
        if u.path == "/api/Library/user-libraries":
            return self.send(200, [])
        for kind, path, param in (("series", "/api/Image/series-cover", "seriesId"),
                                  ("library", "/api/Image/library-cover", "libraryId")):
            if u.path == path:
                cid = q.get(param, "")
                with lock:
                    k = f"{user}:{kind}:{cid}"
                    hits[k] = hits.get(k, 0) + 1
                    denied = (user, kind, cid) in deny
                if denied:
                    return self.send(403, {})
                return self.send(200, png(int(cid) * 20 % 200), "image/png")
        return self.send(404, {})


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
