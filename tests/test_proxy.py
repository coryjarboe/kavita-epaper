"""Exact-address check: the real app behind uvicorn's ProxyHeadersMiddleware
with trusted_hosts="192.0.2.10", driven in-process with the TCP peer set to
192.0.2.10 (the reverse proxy) or to another LAN client. Needs
kavita_stub.py on 127.0.0.1:18096, which this script starts. See
tests/README.md."""
import asyncio
import os
import subprocess
import sys
import tempfile
import time

T = os.path.dirname(os.path.abspath(__file__))
S = os.environ.get("KE_TEST_WORK") or tempfile.mkdtemp(prefix="kavita-epaper-proxy-")
os.environ.update({"KAVITA_BASE_URL": "http://127.0.0.1:18096", "KAVITA_EPAPER_SECRET": "x" * 48,
                   "KAVITA_EPAPER_COVER_CACHE": os.path.join(S, "covers-proxy")})
os.makedirs(os.environ["KAVITA_EPAPER_COVER_CACHE"], exist_ok=True)
sys.dont_write_bytecode = True  # keep app/__pycache__ out of the checkout
sys.path.insert(0, os.path.dirname(T))
import httpx  # noqa: E402
from uvicorn.middleware.proxy_headers import ProxyHeadersMiddleware  # noqa: E402

import app.main as m  # noqa: E402

RES = []


def check(name, ok, detail=""):
    RES.append(bool(ok))
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""))


async def main():
    seen = {}

    async def probe(scope, receive, send):
        seen.update(scheme=scope["scheme"], client=scope["client"])
        await send({"type": "http.response.start", "status": 204, "headers": []})
        await send({"type": "http.response.body", "body": b""})

    hdr = {"X-Forwarded-For": "198.51.100.24", "X-Forwarded-Proto": "https"}
    for peer, trusted in (("192.0.2.10", True), ("192.0.2.50", False)):
        t = httpx.ASGITransport(app=ProxyHeadersMiddleware(probe, trusted_hosts="192.0.2.10"), client=(peer, 5555))
        async with httpx.AsyncClient(transport=t, base_url="http://kavita-epaper") as c:
            await c.get("/x", headers=hdr)
        want = ("https", ("198.51.100.24", 0)) if trusted else ("http", (peer, 5555))
        check(f"peer {peer}: scheme={seen['scheme']} client={seen['client']}",
              (seen["scheme"], tuple(seen["client"])) == want)

        t = httpx.ASGITransport(app=ProxyHeadersMiddleware(m.app, trusted_hosts="192.0.2.10"), client=(peer, 5555))
        async with httpx.AsyncClient(transport=t, base_url="http://kavita-epaper") as c:
            r = await c.post("/login", data={"username": "alice", "password": "pw"}, headers=hdr)
        sc = r.headers.get("set-cookie", "")
        if trusted:
            check("via 192.0.2.10 with X-Forwarded-Proto https: COOKIE_SECURE=auto sets Secure",
                  r.status_code == 302 and "Secure" in sc)
        else:
            check("direct client 192.0.2.50 spoofing X-Forwarded-Proto https: no Secure",
                  r.status_code == 302 and sc and "Secure" not in sc)

    # Forms the README documents: comma-separated list and CIDR; hostnames
    # are not resolved, so they trust nobody.
    for allow, peer, trusted in (("192.0.2.11,192.0.2.10", "192.0.2.10", True),
                                 ("192.0.2.11,192.0.2.10", "192.0.2.50", False),
                                 ("192.0.2.0/28", "192.0.2.10", True),
                                 ("192.0.2.0/28", "192.0.2.50", False),
                                 ("proxy.example", "192.0.2.10", False)):
        t = httpx.ASGITransport(app=ProxyHeadersMiddleware(probe, trusted_hosts=allow), client=(peer, 5555))
        async with httpx.AsyncClient(transport=t, base_url="http://kavita-epaper") as c:
            await c.get("/x", headers=hdr)
        want = ("https", ("198.51.100.24", 0)) if trusted else ("http", (peer, 5555))
        check(f"allow {allow!r}, peer {peer}: {'trusted' if trusted else 'not trusted'}",
              (seen["scheme"], tuple(seen["client"])) == want)


stub = subprocess.Popen([sys.executable, "-I", os.path.join(T, "kavita_stub.py"), "18096"])
for _ in range(50):
    try:
        httpx.get("http://127.0.0.1:18096/_hits", timeout=0.5)
        break
    except httpx.HTTPError:
        time.sleep(0.1)
try:
    asyncio.run(main())
finally:
    stub.terminate()
print(f"== {sum(RES)} PASS, {len(RES) - sum(RES)} FAIL of {len(RES)}")
sys.exit(0 if all(RES) else 1)
