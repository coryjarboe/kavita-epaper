"""/healthz, Kavita over HTTPS (KAVITA_CA_BUNDLE, KAVITA_TLS_VERIFY) and the
app.kavita_check command install.sh uses (0.7.22).

Runs the real app (uvicorn, from this checkout) on 127.0.0.1:18195 against
kavita_stub.py: plain HTTP on 18096, HTML-only on 18097, and HTTPS on 18443
with a certificate from a throwaway CA. See tests/README.md."""
import datetime
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time

import httpx
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

T = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(T)
S = os.environ.get("KE_TEST_WORK") or tempfile.mkdtemp(prefix="kavita-epaper-tls-")
os.makedirs(S, exist_ok=True)
PY = sys.executable
APP = 18195
BASE = f"http://127.0.0.1:{APP}"
RES = []


def check(name, ok, detail=""):
    RES.append(bool(ok))
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)


# ---------------------------------------------------------------- certificates
def write_pem(path, obj, key=False):
    if key:
        data = obj.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                 serialization.NoEncryption())
    else:
        data = obj.public_bytes(serialization.Encoding.PEM)
    open(path, "wb").write(data)


now = datetime.datetime.now(datetime.timezone.utc)
ca_key = ec.generate_private_key(ec.SECP256R1())
ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "kavita-epaper test CA")])
ca = (x509.CertificateBuilder().subject_name(ca_name).issuer_name(ca_name).public_key(ca_key.public_key())
      .serial_number(1).not_valid_before(now).not_valid_after(now + datetime.timedelta(days=1))
      .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
      .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False, key_encipherment=False,
                                   data_encipherment=False, key_agreement=False, key_cert_sign=True,
                                   crl_sign=True, encipher_only=False, decipher_only=False), critical=True)
      .add_extension(x509.SubjectKeyIdentifier.from_public_key(ca_key.public_key()), critical=False)
      .sign(ca_key, hashes.SHA256()))
srv_key = ec.generate_private_key(ec.SECP256R1())
srv = (x509.CertificateBuilder()
       .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")]))
       .issuer_name(ca_name).public_key(srv_key.public_key()).serial_number(2)
       .not_valid_before(now).not_valid_after(now + datetime.timedelta(days=1))
       .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost")]), critical=False)
       .add_extension(x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
       .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()), critical=False)
       .sign(ca_key, hashes.SHA256()))
CA = os.path.join(S, "ca.pem")
write_pem(CA, ca)
write_pem(os.path.join(S, "srv.pem"), srv)
write_pem(os.path.join(S, "srv.key"), srv_key, key=True)
JUNK = os.path.join(S, "not-a-cert.pem")
open(JUNK, "w").write("this is not a certificate\n")


# ---------------------------------------------------------------- helpers
def start_stub(port, *extra):
    p = subprocess.Popen([PY, "-I", os.path.join(T, "kavita_stub.py"), str(port), *extra])
    scheme = "https" if "--tls" in extra else "http"
    for _ in range(50):
        try:
            httpx.get(f"{scheme}://localhost:{port}/api/health", timeout=0.5, verify=False)
            return p
        except httpx.HTTPError:
            time.sleep(0.1)
    raise SystemExit(f"stub {port} did not start")


def app_env(**extra):
    env = {"PATH": os.environ["PATH"], "PYTHONDONTWRITEBYTECODE": "1",
           "KAVITA_EPAPER_SECRET": secrets.token_urlsafe(48),
           "KAVITA_EPAPER_COVER_CACHE": os.path.join(S, "covers")}
    os.makedirs(env["KAVITA_EPAPER_COVER_CACHE"], exist_ok=True)
    env.update(extra)
    return env


class App:
    def __init__(self, name, **extra):
        self.log = os.path.join(S, f"app-{name}.log")
        self.p = subprocess.Popen([PY, "-m", "uvicorn", "app.main:app", "--app-dir", ROOT, "--host", "127.0.0.1",
                                   "--port", str(APP), "--proxy-headers", "--forwarded-allow-ips", "*"],
                                  env=app_env(**extra), stdout=open(self.log, "w"), stderr=subprocess.STDOUT)
        for _ in range(100):
            if self.p.poll() is not None:
                return
            try:
                httpx.get(f"{BASE}/login", timeout=0.5)
                return
            except httpx.HTTPError:
                time.sleep(0.1)

    def text(self):
        return open(self.log).read()

    def stop(self):
        if self.p.poll() is None:
            self.p.terminate()
            self.p.wait(10)


def sign_in():
    r = httpx.post(f"{BASE}/login", data={"username": "alice", "password": "pw"})
    page = httpx.get(BASE + r.headers["location"]).text if r.headers.get("location", "").startswith("/login") else ""
    m = re.search(r'role="alert">(.*?)</div>', page, re.S)
    import html
    return r, (html.unescape(re.sub(r"\s*<[^>]+>\s*", " ", m.group(1))).strip() if m else "")


def kc(url, **env):
    e = {"PATH": os.environ["PATH"], "PYTHONDONTWRITEBYTECODE": "1", **env}
    p = subprocess.run([PY, "-m", "app.kavita_check", url], cwd=ROOT, env=e, capture_output=True, text=True,
                       timeout=60)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


stubs = [start_stub(18096), start_stub(18097, "html"),
         start_stub(18443, "--tls", os.path.join(S, "srv.pem"), os.path.join(S, "srv.key"))]
TLS_URL = "https://localhost:18443"
try:
    # ------------------------------------------------------------ kavita_check
    print("== python -m app.kavita_check (what install.sh runs)")
    rc, out, err = kc("http://127.0.0.1:18096")
    check("Kavita answers: exit 0, 'ok: Kavita answers at ...'", rc == 0 and out == "ok: Kavita answers at http://127.0.0.1:18096", out)
    rc, out, err = kc("http://127.0.0.1:18099")
    check("nothing listening: exit 1, 'refused: ... connection refused'",
          rc == 1 and out.startswith("refused: http://127.0.0.1:18099: connection refused"), out)
    rc, out, err = kc("http://127.0.0.1:18097")
    check("HTML server: exit 1, 'not_kavita: ... not like Kavita'",
          rc == 1 and out.startswith("not_kavita: http://127.0.0.1:18097: it answers, but not like Kavita"), out)
    rc, out, err = kc("http://127.0.0.1:18096/api")
    check("stray /api: exit 1, not_kavita", rc == 1 and out.startswith("not_kavita: http://127.0.0.1:18096/api:"), out)
    rc, out, err = kc("http://user:pw@127.0.0.1:18099/?k=v")
    check("user info and query never printed", "pw@" not in out and "k=v" not in out and "user" not in out, out)
    rc, out, err = kc(TLS_URL)
    check("private-CA HTTPS without a CA bundle: exit 1, tls", rc == 1 and out.startswith("tls: "), out)
    rc, out, err = kc(TLS_URL, KAVITA_CA_BUNDLE=CA)
    check("with KAVITA_CA_BUNDLE: exit 0", rc == 0 and out.startswith("ok: "), out)
    rc, out, err = kc(TLS_URL, KAVITA_TLS_VERIFY="false")
    check("with KAVITA_TLS_VERIFY=false: exit 0 and a warning", rc == 0 and "not checked" in err, err)
    rc, out, err = kc(TLS_URL, KAVITA_CA_BUNDLE=os.path.join(S, "missing.pem"))
    check("missing CA bundle: exit 2, says it's not a file", rc == 2 and "is not a file" in out, out)
    rc, out, err = kc(TLS_URL, KAVITA_TLS_VERIFY="maybe")
    check("bad KAVITA_TLS_VERIFY: exit 2", rc == 2 and "must be true or false" in out, out)

    # ------------------------------------------------------------ app over HTTPS
    print("== app with Kavita over HTTPS")
    app = App("tls-none", KAVITA_BASE_URL=TLS_URL)
    r, a = sign_in()
    check("no CA bundle: sign-in says the certificate isn't trusted, hints at KAVITA_CA_BUNDLE",
          "its TLS certificate isn't trusted" in a and "KAVITA_CA_BUNDLE" in a, a)
    h = httpx.get(f"{BASE}/healthz")
    check("no CA bundle: /healthz 503 'kavita: tls'", h.status_code == 503 and h.text == "kavita: tls\n", h.text)
    app.stop()

    app = App("tls-ca", KAVITA_BASE_URL=TLS_URL, KAVITA_CA_BUNDLE=CA)
    r, a = sign_in()
    cookie = re.search(r"kesess=([^;]+)", r.headers.get("set-cookie", ""))
    lib = httpx.get(f"{BASE}/library", cookies={"kesess": cookie.group(1)}) if cookie else None
    check("KAVITA_CA_BUNDLE: sign-in works and the library loads over HTTPS",
          r.status_code == 302 and r.headers.get("location") == "/library" and lib is not None
          and lib.status_code == 200, a or (lib.status_code if lib is not None else "no cookie"))
    h = httpx.get(f"{BASE}/healthz")
    check("KAVITA_CA_BUNDLE: /healthz 200", h.status_code == 200 and h.text == "ok\n", h.text)
    check("KAVITA_CA_BUNDLE: no TLS warning at startup", "not checked" not in app.text())
    app.stop()

    app = App("tls-off", KAVITA_BASE_URL=TLS_URL, KAVITA_TLS_VERIFY="false")
    r, a = sign_in()
    check("KAVITA_TLS_VERIFY=false: sign-in works", r.status_code == 302 and r.headers.get("location") == "/library", a)
    check("KAVITA_TLS_VERIFY=false: warning logged at startup",
          "KAVITA_TLS_VERIFY=false: Kavita's TLS certificate is not checked" in app.text())
    app.stop()

    for label, extra, want in (
            ("missing CA bundle", {"KAVITA_CA_BUNDLE": os.path.join(S, "missing.pem")}, "is not a file"),
            ("CA bundle that isn't PEM", {"KAVITA_CA_BUNDLE": JUNK}, "has no usable PEM certificates"),
            ("bad KAVITA_TLS_VERIFY", {"KAVITA_TLS_VERIFY": "yes please"}, "must be true or false")):
        app = App("bad", KAVITA_BASE_URL=TLS_URL, **extra)
        app.p.wait(30)
        check(f"{label}: refuses to start, exit 78, says why",
              app.p.returncode == 78 and want in app.text() and "refusing to start" in app.text(),
              f"rc={app.p.returncode}")

    # ------------------------------------------------------------ /healthz
    print("== /healthz")
    app = App("health", KAVITA_BASE_URL="http://127.0.0.1:18096")
    h = httpx.get(f"{BASE}/healthz")
    check("Kavita up: 200 'ok', no-store", h.status_code == 200 and h.text == "ok\n"
          and h.headers.get("cache-control") == "no-store", h.text)
    for _ in range(5):
        httpx.get(f"{BASE}/healthz")
    httpx.get(f"{BASE}/login")
    time.sleep(0.3)
    log = app.text()
    check("/healthz not in the access log, /login is", "/healthz" not in log and '"GET /login' in log)
    stubs[0].terminate()
    stubs[0].wait(5)
    h = httpx.get(f"{BASE}/healthz")
    check("Kavita just stopped: still 200 from the 10 s cache", h.status_code == 200, h.text)
    time.sleep(10.5)
    h = httpx.get(f"{BASE}/healthz")
    check("after the cache: 503 'kavita: refused', no URL in the body",
          h.status_code == 503 and h.text == "kavita: refused\n" and "127.0.0.1" not in h.text, h.text)
    httpx.get(f"{BASE}/healthz")
    time.sleep(0.3)
    warns = [l for l in app.text().splitlines() if "healthz: Kavita at" in l]
    check("failure logged once with the URL and reason",
          len(warns) == 1 and "http://127.0.0.1:18096: refused" in warns[0], warns)
    app.stop()
    app = App("health-html", KAVITA_BASE_URL="http://127.0.0.1:18097")
    h = httpx.get(f"{BASE}/healthz")
    check("something that isn't Kavita: 503 'kavita: not_kavita'",
          h.status_code == 503 and h.text == "kavita: not_kavita\n", h.text)
    log = app.text()
    app.stop()
    check("no tracebacks in any app log", "Traceback" not in log)
finally:
    for p in stubs:
        if p.poll() is None:
            p.terminate()
print(f"== {sum(RES)} PASS, {len(RES) - sum(RES)} FAIL of {len(RES)}")
sys.exit(0 if all(RES) else 1)
