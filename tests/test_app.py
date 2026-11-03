"""Scratch-port tests: cookie encryption, per-user cover cache, forwarded-IP
trust. Runs the real app (uvicorn, from this checkout) on 127.0.0.1:18095
against kavita_stub.py on 18096. See tests/README.md."""
import base64
import hashlib
import hmac
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

import httpx
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

T = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.dirname(T)  # repo root, holds app/
# Logs, cover cache and the symlink target go here, never into the repo.
S = os.environ.get("KE_TEST_WORK") or tempfile.mkdtemp(prefix="kavita-epaper-test-")
os.makedirs(S, exist_ok=True)
COVERS = os.path.join(S, "covers")
PY = sys.executable
APP, STUB = 18095, 18096
print(f"== work dir {S}")
BASE = f"http://127.0.0.1:{APP}"
S1, S2, S3 = "secret-one-" + "a" * 40, "secret-two-" + "b" * 40, "secret-three-" + "c" * 40
RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append(bool(ok))
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)


def fernet(secret):
    k = HKDF(algorithm=hashes.SHA256(), length=32, salt=None,
             info=b"kavita-epaper session cookie v1").derive(secret.encode())
    return Fernet(base64.urlsafe_b64encode(k))


def pad(v):
    return v + "=" * (-len(v) % 4)


def decrypt(secret, value):
    try:
        return json.loads(fernet(secret).decrypt(pad(value).encode()))
    except Exception:
        return None


def mint(secret, data, at=None):
    tok = fernet(secret).encrypt_at_time(json.dumps(data).encode(), int(at or time.time()))
    return tok.decode().rstrip("=")


def tag(secret, user):
    return hmac.new(secret.encode(), b"cover-cache\0" + user.encode(), hashlib.sha256).hexdigest()[:16]


class Proc:
    def __init__(self, args, env, log):
        self.log = log
        self.p = subprocess.Popen(args, env=env, stdout=open(log, "w"), stderr=subprocess.STDOUT)

    def stop(self):
        self.p.terminate()
        self.p.wait(10)

    def text(self):
        return open(self.log).read()


def start_stub(**env):
    e = dict(os.environ, **{k: str(v) for k, v in env.items()})
    p = Proc([PY, "-I", os.path.join(T, "kavita_stub.py"), str(STUB)], e, os.path.join(S, "stub.log"))
    for _ in range(50):
        try:
            httpx.get(f"http://127.0.0.1:{STUB}/_hits", timeout=0.5)
            return p
        except httpx.HTTPError:
            time.sleep(0.1)
    raise SystemExit("stub did not start")


def start_app(name, forwarded, **extra):
    env = {"PATH": os.environ["PATH"], "PYTHONDONTWRITEBYTECODE": "1",
           "KAVITA_BASE_URL": f"http://127.0.0.1:{STUB}", "KAVITA_EPAPER_COVER_CACHE": COVERS,
           "KAVITA_EPAPER_SECRET": S1}
    env.update({k: str(v) for k, v in extra.items()})
    p = Proc([PY, "-m", "uvicorn", "app.main:app", "--app-dir", SRC, "--host", "127.0.0.1",
              "--port", str(APP), "--proxy-headers", "--forwarded-allow-ips", forwarded],
             env, os.path.join(S, f"app-{name}.log"))
    for _ in range(100):
        try:
            if httpx.get(f"{BASE}/login", timeout=0.5).status_code == 200:
                return p
        except httpx.HTTPError:
            time.sleep(0.1)
    print(p.text())
    raise SystemExit(f"app {name} did not start")


def stub(path, **q):
    return httpx.post(f"http://127.0.0.1:{STUB}{path}", params=q)


def hits():
    return httpx.get(f"http://127.0.0.1:{STUB}/_hits").json()


def login(user, headers=None):
    r = httpx.post(f"{BASE}/login", data={"username": user, "password": "pw"}, headers=headers or {})
    sc = r.headers.get("set-cookie", "")
    m = re.match(r"kesess=([^;]*)", sc)
    return r, sc, (m.group(1) if m else None)


def get(path, cookie=None, headers=None):
    h = dict(headers or {})
    if cookie is not None:
        h["Cookie"] = f"kesess={cookie}"
    return httpx.get(f"{BASE}{path}", headers=h)


def deletes_cookie(r):
    sc = r.headers.get("set-cookie", "")
    return sc.startswith("kesess=") and ("Max-Age=0" in sc or "expires=Thu, 01 Jan 1970" in sc)


def is_placeholder(r):
    return r.status_code == 200 and r.headers.get("content-type") == "image/gif" and len(r.content) < 64


def files():
    return sorted(os.listdir(COVERS))


def old_cookie(secret, data):
    """Signed-only cookie as issued up to 0.7.18 (itsdangerous, test-only dependency)."""
    from itsdangerous import TimestampSigner, URLSafeSerializer
    payload = URLSafeSerializer(secret, salt="kavita-epaper-session").dumps(data)
    return TimestampSigner(secret).sign(payload.encode()).decode()


# ---------------------------------------------------------------- setup
shutil.rmtree(COVERS, ignore_errors=True)
os.makedirs(COVERS)
os.makedirs(os.path.join(S, "outside"), exist_ok=True)
now = time.time()
seed = {
    "series-55.bin": 0, "series-55.bin.ct": 0, "library-3.bin": 0, "library-3.bin.ct": 0,
    "u0123456789abcdef-series-1.bin": 0, "u0123456789abcdef-series-1.bin.ct": 0,
    "ufedcba9876543210-series-2.bin": 2 * 86400, "ufedcba9876543210-series-2.bin.ct": 2 * 86400,
    ".tmp-old": 2 * 3600, ".tmp-new": 0, "notes.txt": 9 * 86400, "series-55.bin.bak": 9 * 86400,
    "series-x.bin": 9 * 86400,
}
for name, age in seed.items():
    p = os.path.join(COVERS, name)
    open(p, "wb").write(b"x")
    os.utime(p, (now - age, now - age))
target = os.path.join(S, "outside", "target.bin")
open(target, "wb").write(b"keep")
os.symlink(target, os.path.join(COVERS, "series-77.bin"))
os.mkdir(os.path.join(COVERS, "series-78.bin"))

stubp = start_stub(JWT_PAD=0, REFRESH_LEN=384)

# ---------------------------------------------------------------- instance 1
print("== instance 1: SECRET=S1, FORWARDED_ALLOW_IPS=192.0.2.10, COVER_TTL default")
app = start_app("1", "192.0.2.10")
removed = sorted(set(seed) - set(files()))
check("startup prune removed exactly legacy + expired per-user + old tmp",
      removed == sorted(["series-55.bin", "series-55.bin.ct", "library-3.bin", "library-3.bin.ct",
                         "ufedcba9876543210-series-2.bin", "ufedcba9876543210-series-2.bin.ct", ".tmp-old"]),
      ", ".join(removed))
check("prune kept fresh per-user, fresh tmp, unrelated names, symlink, dir",
      all(n in files() for n in ["u0123456789abcdef-series-1.bin", "u0123456789abcdef-series-1.bin.ct",
                                 ".tmp-new", "notes.txt", "series-55.bin.bak", "series-x.bin",
                                 "series-77.bin", "series-78.bin"]) and open(target, "rb").read() == b"keep")
check("prune logged its count", "cover cache: removed 7 stale file(s)" in app.text())

r, sc, ca = login("alice")
check("login alice -> 302 /library with cookie", r.status_code == 302 and r.headers["location"] == "/library" and ca)
check(f"realistic Set-Cookie under 3800 bytes", len(sc) < 3800, f"Set-Cookie {len(sc)} bytes, value {len(ca)}")
check("cookie flags: HttpOnly, SameSite=lax, no Secure on plain http",
      "HttpOnly" in sc and "SameSite=lax" in sc and "Secure" not in sc)
check("cookie value unquoted, no '=' padding", '"' not in ca and "=" not in ca)
raw = base64.urlsafe_b64decode(pad(ca))
check("cookie contents not readable (no username/JWT/'token' after base64 decode)",
      b"alice" not in raw and b"eyJ" not in raw and b"token" not in raw)
da = decrypt(S1, ca)
check("cookie decrypts with HKDF(S1) and holds the session",
      da and da.get("username") == "alice" and da.get("token", "").count(".") == 2 and da.get("refresh_token") and da.get("api_key"))
jwt_len, rt_len = len(da["token"]), len(da["refresh_token"])
print(f"      sizes: JWT {jwt_len}, refresh token {rt_len}, apiKey {len(da['api_key'])}")
check("/library with cookie -> 200", get("/library", ca).status_code == 200)

for label, value in [
    ("0.7.18-format signed cookie", old_cookie(S1, da)),
    ("tampered cookie", ca[:60] + ("A" if ca[60] != "A" else "B") + ca[61:]),
    ("cookie under another secret", mint(S3, da)),
    ("expired cookie (31 days old)", mint(S1, da, at=time.time() - 31 * 86400)),
    ("junk cookie", "!!!not-a-cookie"),
]:
    r1 = get("/library", value)
    r2 = get("/cover/series/1", value)
    check(f"{label}: /library and /cover -> 302 /login, cookie deleted",
          r1.status_code == 302 and r1.headers.get("location") == "/login" and deletes_cookie(r1)
          and r2.status_code == 302 and deletes_cookie(r2))
check("stale cookie: /login page still renders 200", get("/login", old_cookie(S1, da)).status_code == 200)
check("no cookie: /library -> 302 without Set-Cookie",
      (lambda r: r.status_code == 302 and "set-cookie" not in r.headers)(get("/library")))

# per-user cover cache
stub("/_reset")
ta, tb = tag(S1, "alice"), tag(S1, "bob")
r_a1, r_a2 = get("/cover/series/1", ca), get("/cover/series/1", ca)
check("alice series 1: JPEG, second request served from cache",
      r_a1.headers.get("content-type") == "image/jpeg" and r_a2.content == r_a1.content
      and hits().get("alice:series:1") == 1)
check("cache file named with HMAC tag, no username in name",
      f"u{ta}-series-1.bin" in files() and f"u{ta}-series-1.bin.ct" in files()
      and not any("alice" in n or "bob" in n for n in files()))
r, sc, cb = login("bob")
r_b1 = get("/cover/series/1", cb)
check("bob series 1 is fetched from Kavita for bob, not served from alice's entry",
      r_b1.headers.get("content-type") == "image/jpeg" and hits().get("bob:series:1") == 1
      and f"u{tb}-series-1.bin" in files() and ta != tb)
stub("/_deny", user="bob", kind="series", id="2")
r_b2, r_a3 = get("/cover/series/2", cb), get("/cover/series/2", ca)
check("bob denied series 2 -> placeholder, nothing cached for bob", is_placeholder(r_b2)
      and f"u{tb}-series-2.bin" not in files())
check("alice allowed series 2 -> JPEG", r_a3.headers.get("content-type") == "image/jpeg")
r_l = get("/cover/library/5", ca)
check("alice library cover 5 -> JPEG, cached per user",
      r_l.headers.get("content-type") == "image/jpeg" and f"u{ta}-library-5.bin" in files())
p1 = os.path.join(COVERS, f"u{ta}-series-1.bin")
os.utime(p1, (time.time() - 2 * 86400,) * 2)
get("/cover/series/1", ca)
check("expired entry refetched from Kavita and refreshed",
      hits().get("alice:series:1") == 2 and time.time() - os.stat(p1).st_mtime < 60)
stub("/_deny", user="alice", kind="series", id="1")
r = get("/cover/series/1", ca)
check("within TTL a fresh entry is still served (bounded by TTL)",
      r.headers.get("content-type") == "image/jpeg" and hits().get("alice:series:1") == 2)
os.utime(p1, (time.time() - 2 * 86400,) * 2)
r = get("/cover/series/1", ca)
check("expired + Kavita now refuses -> placeholder, entry deleted",
      is_placeholder(r) and hits().get("alice:series:1") == 3
      and f"u{ta}-series-1.bin" not in files() and f"u{ta}-series-1.bin.ct" not in files())
check("no temp files left; cache files are 0644",
      not any(n.startswith(".tmp-") and n != ".tmp-new" for n in files())
      and all(oct(os.stat(os.path.join(COVERS, n)).st_mode & 0o777) == "0o644"
              for n in files() if n.startswith(f"u{ta}") or n.startswith(f"u{tb}")))

# forwarded-IP trust: 127.0.0.1 is not 192.0.2.10, so its headers are ignored
spoof = {"X-Forwarded-For": "6.6.6.6", "X-Forwarded-Proto": "https"}
get("/login", headers=spoof)
r, sc, _ = login("alice", headers=spoof)
time.sleep(0.3)
lines = [l for l in app.text().splitlines() if '"GET /login' in l or '"POST /login' in l]
check("untrusted client: X-Forwarded-For ignored in access log",
      lines and not any("6.6.6.6" in l for l in lines) and re.search(r"127\.0\.0\.1:[1-9]\d*", lines[-1]),
      lines[-1].split("INFO:")[-1].strip() if lines else "")
check("untrusted client: X-Forwarded-Proto https ignored (no Secure)", "Secure" not in sc)

# token refresh re-encrypts
stub("/_expire", user="alice")
r = get("/library", ca)
sc = r.headers.get("set-cookie", "")
ca2 = (re.match(r"kesess=([^;]*)", sc) or [None, None])[1]
d2 = decrypt(S1, ca2) if ca2 else None
check("expired Kavita token: refreshed, new encrypted cookie issued",
      r.status_code == 200 and d2 and d2["token"] != da["token"])
ca = ca2 or ca
log1 = app.text()
app.stop()
check("instance 1 log: no tracebacks, no 500s", "Traceback" not in log1 and '" 500' not in log1)

# ---------------------------------------------------------------- instance 2
print("== instance 2: rotation, SECRET=S2, SECRET_PREVIOUS=S1")
app = start_app("2", "192.0.2.10", KAVITA_EPAPER_SECRET=S2, KAVITA_EPAPER_SECRET_PREVIOUS=S1)
r = get("/library", ca)
sc = r.headers.get("set-cookie", "")
cn = (re.match(r"kesess=([^;]*)", sc) or [None, None])[1]
check("S1 cookie accepted and re-issued", r.status_code == 200 and cn and cn != ca)
check("re-issued cookie is under S2 only", cn and decrypt(S2, cn) and decrypt(S1, cn) is None)
r = get("/library", cn)
check("re-issued cookie works without another re-issue", r.status_code == 200 and "set-cookie" not in r.headers)
r = get("/library", mint(S3, da))
check("cookie under an unrelated secret -> 302 /login, deleted", r.status_code == 302 and deletes_cookie(r))
log2 = app.text()
app.stop()
check("instance 2 log: no tracebacks, no 500s", "Traceback" not in log2 and '" 500' not in log2)

# ---------------------------------------------------------------- instance 3
print("== instance 3: trusted proxy (127.0.0.1 stands in for 192.0.2.10)")
app = start_app("3", "127.0.0.1")
r, sc, _ = login("alice", headers={"X-Forwarded-For": "198.51.100.24", "X-Forwarded-Proto": "https"})
time.sleep(0.3)
check("trusted proxy + X-Forwarded-Proto https -> cookie has Secure", "Secure" in sc)
check("trusted proxy: access log shows the device IP from X-Forwarded-For",
      '198.51.100.24:0 - "POST /login' in app.text())
r, sc, _ = login("alice")
check("trusted proxy, plain http request -> no Secure", "Secure" not in sc)
log3 = app.text()
app.stop()
check("instance 3 log: no tracebacks, no 500s", "Traceback" not in log3 and '" 500' not in log3)

# ---------------------------------------------------------------- instance 4
print("== instance 4: COVER_TTL=0")
before = [n for n in files() if n.startswith("u")]
app = start_app("4", "192.0.2.10", KAVITA_EPAPER_COVER_TTL=0)
check("TTL=0: startup removes every per-user cover file",
      before and not any(n.startswith("u") for n in files()), f"{len(before)} removed")
stub("/_reset")
r, sc, c4 = login("alice")
get("/cover/series/3", c4)
get("/cover/series/3", c4)
check("TTL=0: every request goes to Kavita, nothing written",
      hits().get("alice:series:3") == 2 and not any(n.startswith("u") for n in files()))
log4 = app.text()
app.stop()
check("instance 4 log: no tracebacks, no 500s", "Traceback" not in log4 and '" 500' not in log4)

# ---------------------------------------------------------------- instance 5
print("== instance 5: oversized tokens (stress)")
stubp.stop()
stubp = start_stub(JWT_PAD=1100, REFRESH_LEN=512)
app = start_app("5", "192.0.2.10")
r, sc, c5 = login("alice")
d5 = decrypt(S1, c5)
check("stress: Set-Cookie still under 3800 bytes", len(sc) < 3800,
      f"JWT {len(d5['token'])}, refresh {len(d5['refresh_token'])} -> Set-Cookie {len(sc)} bytes")
app.stop()
stubp.stop()

print(f"== {sum(RESULTS)} PASS, {len(RESULTS) - sum(RESULTS)} FAIL of {len(RESULTS)}")
sys.exit(0 if all(RESULTS) else 1)
