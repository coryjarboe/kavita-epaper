"""Sign-in error messages and the startup secret check (0.7.21).

Part 1 starts the app in subprocesses with bad secrets and checks it refuses
with exit status 78 and a clear message. Part 2 runs the app in-process and
signs in against kavita_stub.py (127.0.0.1:18096), the stub in "html" mode
(18097, a non-Kavita web server), a local self-signed TLS server (18443), a
closed port (18099), an unresolvable host and an unroutable address. See
tests/README.md."""
import asyncio
import datetime
import html
import http.server
import logging
import os
import re
import ssl
import subprocess
import sys
import tempfile
import threading
import time

T = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(T)
S = os.environ.get("KE_TEST_WORK") or tempfile.mkdtemp(prefix="kavita-epaper-login-")
os.makedirs(S, exist_ok=True)
GOOD_SECRET = "s" * 48
RES = []


def check(name, ok, detail=""):
    RES.append(bool(ok))
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)


# ---------------------------------------------------------------- part 1
print("== startup secret check")
base_env = {"PATH": os.environ["PATH"], "PYTHONDONTWRITEBYTECODE": "1",
            "KAVITA_BASE_URL": "http://127.0.0.1:18096",
            "KAVITA_EPAPER_COVER_CACHE": os.path.join(S, "covers")}
short = "abcdefghij" * 3 + "x"  # 31 characters
for label, secret, want_rc, want in (
        ("unset", None, 78, "KAVITA_EPAPER_SECRET is not set"),
        ("empty", "", 78, "KAVITA_EPAPER_SECRET is not set"),
        ("env.example placeholder", "CHANGE_ME_TO_A_LONG_RANDOM_STRING", 78, "is still the placeholder from env.example"),
        ("31 characters", short, 78, "is too short (31 characters, need at least 32)"),
        ("32 characters", "k" * 32, 0, None)):
    env = dict(base_env)
    if secret is not None:
        env["KAVITA_EPAPER_SECRET"] = secret
    p = subprocess.run([sys.executable, "-c", "import app.main"], cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=60)
    out = p.stdout + p.stderr
    if want_rc:
        check(f"secret {label}: exit 78 with a clear message, value not echoed",
              p.returncode == want_rc and want in out and "token_urlsafe(48)" in out
              and os.path.join(ROOT, ".env") in out and (not secret or secret not in out.replace(want, "")),
              f"rc={p.returncode}")
    else:
        check(f"secret {label}: starts", p.returncode == 0, f"rc={p.returncode} {out.strip()[-120:]}")

env = dict(base_env)
p = subprocess.run([sys.executable, "-m", "uvicorn", "app.main:app", "--app-dir", ROOT,
                    "--host", "127.0.0.1", "--port", "18195"], env=env,
                   capture_output=True, text=True, timeout=60)
check("uvicorn with no secret exits 78 (systemd won't restart-loop)",
      p.returncode == 78 and "refusing to start" in p.stderr, f"rc={p.returncode}")

# ---------------------------------------------------------------- part 2
os.environ.update({"KAVITA_BASE_URL": "http://127.0.0.1:18096", "KAVITA_EPAPER_SECRET": GOOD_SECRET,
                   "KAVITA_EPAPER_COVER_CACHE": os.path.join(S, "covers-inproc")})
os.makedirs(os.environ["KAVITA_EPAPER_COVER_CACHE"], exist_ok=True)
sys.dont_write_bytecode = True
sys.path.insert(0, ROOT)
import httpx  # noqa: E402
from cryptography import x509  # noqa: E402
from cryptography.hazmat.primitives import hashes, serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402
from cryptography.x509.oid import NameOID  # noqa: E402

import app.main as m  # noqa: E402

logs = []


class Capture(logging.Handler):
    def emit(self, record):
        logs.append(record.getMessage())


logging.getLogger("kavita-epaper").addHandler(Capture())

# self-signed TLS server
key = ec.generate_private_key(ec.SECP256R1())
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
now = datetime.datetime.now(datetime.timezone.utc)
cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
        .serial_number(1).not_valid_before(now).not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost")]), False)
        .sign(key, hashes.SHA256()))
open(os.path.join(S, "c.pem"), "wb").write(cert.public_bytes(serialization.Encoding.PEM))
open(os.path.join(S, "k.pem"), "wb").write(key.private_bytes(
    serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
tls = http.server.HTTPServer(("127.0.0.1", 18443), http.server.BaseHTTPRequestHandler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(os.path.join(S, "c.pem"), os.path.join(S, "k.pem"))
tls.socket = ctx.wrap_socket(tls.socket, server_side=True)
threading.Thread(target=tls.serve_forever, daemon=True).start()

stubs = [subprocess.Popen([sys.executable, "-I", os.path.join(T, "kavita_stub.py"), "18096"]),
         subprocess.Popen([sys.executable, "-I", os.path.join(T, "kavita_stub.py"), "18097", "html"])]
for port in (18096, 18097):
    for _ in range(50):
        try:
            httpx.get(f"http://127.0.0.1:{port}/_hits", timeout=0.5)
            break
        except httpx.HTTPError:
            time.sleep(0.1)

HINT = f"Check KAVITA_BASE_URL in {os.path.join(ROOT, '.env')}, then restart kavita-epaper."
client_timeout = m._http.timeout


def use_kavita(url, transport=None):
    m.KAVITA_BASE_URL = url
    m._http = httpx.AsyncClient(base_url=url, timeout=client_timeout, transport=transport)


async def sign_in(user, pw):
    t = httpx.ASGITransport(app=m.app, client=("127.0.0.1", 5555))
    async with httpx.AsyncClient(transport=t, base_url="http://kavita-epaper") as c:
        start = time.time()
        r = await c.post("/login", data={"username": user, "password": pw})
        took = time.time() - start
        loc = r.headers.get("location", "")
        page = ""
        if loc.startswith("/login"):
            page = (await c.get(loc)).text
        return r, took, loc, page


def alert(page):
    mm = re.search(r'role="alert">(.*?)</div>', page, re.S)
    return html.unescape(re.sub(r"\s*<[^>]+>\s*", " ", mm.group(1))).strip() if mm else ""


async def main():
    print("== Kavita unreachable or not Kavita")
    use_kavita("http://127.0.0.1:18099")
    r, took, loc, page = await sign_in("alice", "pw")
    a = alert(page)
    check("refused: names the URL, the reason and where to change it",
          r.status_code == 302 and "Couldn't reach Kavita at http://127.0.0.1:18099: connection refused" in a
          and HINT in a, a)
    check("refused: log has the reason and the error type",
          any("could not reach Kavita at http://127.0.0.1:18099: refused (ConnectError" in l for l in logs), logs[-1])

    use_kavita("http://kavita.invalid:5000")
    r, took, loc, page = await sign_in("alice", "pw")
    check("unknown host name: 'host name not found'", "kavita.invalid:5000: host name not found" in alert(page),
          alert(page))

    use_kavita("https://localhost:18443")
    r, took, loc, page = await sign_in("alice", "pw")
    check("self-signed TLS: 'TLS certificate isn't trusted'",
          "Couldn't reach Kavita at https://localhost:18443: its TLS certificate isn't trusted" in alert(page),
          alert(page))

    use_kavita("http://192.0.2.1:5000")
    r, took, loc, page = await sign_in("alice", "pw")
    a = alert(page)
    if "no answer within" in a:
        check("unroutable host: fails within the 5 s connect timeout, not 15 s",
              took < 7 and "no answer within 5 seconds" in a
              and any("timeout (ConnectTimeout" in l for l in logs), f"{took:.1f}s; {a}")
    else:
        print(f"SKIP  unroutable host: this network doesn't drop 192.0.2.1 silently [{took:.1f}s; {a}]")

    def slow(request):
        raise httpx.ReadTimeout("timed out", request=request)
    use_kavita("http://127.0.0.1:18096", transport=httpx.MockTransport(slow))
    r, took, loc, page = await sign_in("alice", "pw")
    check("Kavita too slow to answer: 'didn't answer in time', logged as ReadTimeout",
          "accepted the connection but didn't answer in time" in alert(page) and "Kavita may be busy" in alert(page)
          and "KAVITA_BASE_URL" not in alert(page) and any("slow (ReadTimeout" in l for l in logs), alert(page))

    use_kavita("http://127.0.0.1:18097")
    r, took, loc, page = await sign_in("alice", "pw")
    check("HTML 200 from a non-Kavita server: no 500, 'doesn't look like Kavita'",
          r.status_code == 302 and "That doesn't look like Kavita at http://127.0.0.1:18097 "
          "(the reply wasn't a Kavita sign-in response)." in alert(page) and HINT in alert(page), alert(page))
    check("HTML 200: logged with the content type",
          any("isn't a Kavita sign-in response (content-type text/html)" in l for l in logs))

    use_kavita("http://127.0.0.1:18096/api")
    r, took, loc, page = await sign_in("alice", "pw")
    check("stray /api suffix: 'doesn't look like Kavita (HTTP 404 ...)'",
          "That doesn't look like Kavita at http://127.0.0.1:18096/api (HTTP 404 for the sign-in request)."
          in alert(page), alert(page))

    use_kavita("http://127.0.0.1:18096")
    r, took, loc, page = await sign_in("notoken", "pw")
    check("200 JSON without a token: 'doesn't look like Kavita'", "That doesn't look like Kavita" in alert(page))

    r, took, loc, page = await sign_in("boom", "pw")
    check("Kavita 500: 'returned an error (HTTP 500)', no hint about the URL",
          "Kavita at http://127.0.0.1:18096 returned an error (HTTP 500)." in alert(page)
          and "KAVITA_BASE_URL" not in alert(page), alert(page))

    print("== Kavita refuses the sign-in")
    for user, pw, want in (
            ("alice", "wrong", "Kavita said: Your credentials are not correct"),
            ("locked", "pw", "Kavita said: You've been locked out from too many authorization attempts."),
            ("jsonstr", "pw", "Kavita said: Your account is disabled. Contact the server admin."),
            ("problem", "pw", "Kavita said: The Password field is required."),
            ("nobody", "pw", "Kavita said: bad"),
            ("empty", "pw", "Wrong username or password.")):
        r, took, loc, page = await sign_in(user, pw)
        check(f"{user}: {want}", want in alert(page), alert(page))
    r, took, loc, page = await sign_in("leaky", "pw")
    check("message that looks like a token is dropped", "eyJ" not in page and "Wrong username or password." in
          alert(page), alert(page))
    r, took, loc, page = await sign_in("echo", "hunter2-correct-horse")
    check("message containing the password is dropped",
          "hunter2" not in page and "Wrong username or password." in alert(page), alert(page))

    print("== URL display and crafted links")
    use_kavita("http://admin:sekrit@127.0.0.1:18099/?apikey=abc#frag")
    r, took, loc, page = await sign_in("alice", "pw")
    check("user info, query and fragment are never shown",
          "sekrit" not in page and "admin" not in page and "apikey" not in page and
          "Couldn't reach Kavita at http://127.0.0.1:18099:" in alert(page), alert(page))
    t = httpx.ASGITransport(app=m.app)
    async with httpx.AsyncClient(transport=t, base_url="http://kavita-epaper") as c:
        a1 = alert((await c.get("/login?error=whatever&msg=Visit+evil.example")).text)
        a2 = alert((await c.get("/login?error=unreachable&reason=%3Cb%3Eevil")).text)
        a3 = alert((await c.get("/login?error=kavita_error&status=%3Cscript%3E")).text)
        a4 = (await c.get("/login?error=rejected&msg=%3Cscript%3Ealert(1)%3C/script%3E")).text
    check("unknown error code: generic text, msg ignored", a1 == "Sign-in failed.", a1)
    check("unknown reason: generic 'network error'", "network error" in a2 and "evil" not in a2, a2)
    check("non-numeric status ignored", "HTTP ?" in a3 and "script" not in a3, a3)
    raw = re.search(r'role="alert">(.*?)</div>', a4, re.S)
    check("msg is HTML-escaped, never markup", raw and "<script>" not in raw.group(1)
          and "&lt;script&gt;" in raw.group(1), raw.group(1) if raw else "no alert")

    print("== who sees the Kavita URL")
    use_kavita("http://127.0.0.1:18099")
    GENERIC = "Can't reach the Kavita server. Check the server logs."

    async def page_for(client_host, path="/login?error=unreachable&reason=refused"):
        t = httpx.ASGITransport(app=m.app, client=(client_host, 5555))
        async with httpx.AsyncClient(transport=t, base_url="http://kavita-epaper") as c:
            return alert((await c.get(path)).text)

    for host in ("10.1.2.3", "172.16.0.9", "172.31.255.1", "192.168.1.20", "127.0.0.1", "127.8.9.10",
                 "::1", "fd12:3456::1", "fe80::1", "::ffff:192.168.1.5"):
        a = await page_for(host)
        check(f"local client {host}: URL, reason and .env hint shown",
              "http://127.0.0.1:18099: connection refused" in a and HINT in a, a)
    for host in ("203.0.113.7", "8.8.8.8", "172.32.0.1", "100.64.0.1", "169.254.1.1",
                 "2001:db8::1", "::ffff:203.0.113.7", "not-an-ip"):
        a = await page_for(host)
        check(f"remote client {host}: generic message, no URL or path",
              a == GENERIC and "127.0.0.1" not in a and ".env" not in a, a)
    a = await page_for("203.0.113.7", "/login?error=not_kavita&status=404")
    check("remote client, not Kavita: same generic message", a == GENERIC, a)
    a = await page_for("203.0.113.7", "/login?error=kavita_error&status=500")
    check("remote client, Kavita 500: status only, no URL",
          a == "The Kavita server returned an error (HTTP 500). Try again later.", a)
    a = await page_for("203.0.113.7", "/login?error=rejected&status=401")
    check("remote client, wrong password: unchanged", a == "Wrong username or password.", a)

    # The real sign-in from a remote client: generic page, full URL in the log.
    before = len(logs)
    t = httpx.ASGITransport(app=m.app, client=("203.0.113.7", 5555))
    async with httpx.AsyncClient(transport=t, base_url="http://kavita-epaper") as c:
        r = await c.post("/login", data={"username": "alice", "password": "pw"})
        a = alert((await c.get(r.headers["location"])).text)
    check("remote sign-in with Kavita down: generic page, full URL still logged",
          a == GENERIC and any("could not reach Kavita at http://127.0.0.1:18099: refused" in l
                               for l in logs[before:]), a)

    # Behind uvicorn's proxy-header handling (as the unit runs it).
    from uvicorn.middleware.proxy_headers import ProxyHeadersMiddleware

    async def via(trusted, peer, xff):
        t = httpx.ASGITransport(app=ProxyHeadersMiddleware(m.app, trusted_hosts=trusted), client=(peer, 5555))
        async with httpx.AsyncClient(transport=t, base_url="http://kavita-epaper") as c:
            return alert((await c.get("/login?error=unreachable&reason=refused",
                                      headers={"X-Forwarded-For": xff})).text)
    a = await via("192.0.2.10", "192.0.2.10", "192.168.1.20")
    check("trusted proxy forwarding a LAN client: URL shown", "http://127.0.0.1:18099" in a, a)
    a = await via("192.0.2.10", "192.0.2.10", "203.0.113.9")
    check("trusted proxy forwarding an internet client: generic", a == GENERIC, a)
    a = await via("192.0.2.10", "203.0.113.9", "10.0.0.5")
    check("untrusted client faking X-Forwarded-For 10.0.0.5: ignored, generic", a == GENERIC, a)
    a = await via("*", "203.0.113.9", "10.0.0.5")
    check("with FORWARDED_ALLOW_IPS='*' the same fake works (why the README says set it)",
          "http://127.0.0.1:18099" in a, a)

    print("== success and logs")
    use_kavita("http://127.0.0.1:18096")
    r, took, loc, page = await sign_in("alice", "pw")
    check("right password: 302 /library with a session cookie",
          r.status_code == 302 and loc == "/library" and "kesess=" in r.headers.get("set-cookie", ""))
    joined = "\n".join(logs)
    check("logs hold no passwords, tokens or user info",
          not any(x in joined for x in ("hunter2", "wrong", "sekrit", "eyJ", "apikey")), f"{len(logs)} lines")


try:
    asyncio.run(main())
finally:
    for p in stubs:
        p.terminate()
    tls.shutdown()
print(f"== {sum(RES)} PASS, {len(RES) - sum(RES)} FAIL of {len(RES)}")
sys.exit(0 if all(RES) else 1)
