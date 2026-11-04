"""Reaching Kavita: TLS settings, failure reasons, and a health check.

Shared by the app (sign-in errors, /healthz) and install.sh, which runs it
before any .env exists:

    venv/bin/python -m app.kavita_check http://127.0.0.1:5000

It prints one line ("ok: ..." or "<reason>: ...") and exits 0 when the
address answers like Kavita, 1 when it doesn't, 2 on a bad TLS setting.
KAVITA_CA_BUNDLE and KAVITA_TLS_VERIFY are read from the environment, as the
app reads them. This module must not import app.main.
"""

from __future__ import annotations

import asyncio
import os
import socket
import ssl
import sys

import httpx

CONNECT_TIMEOUT = 5.0
CHECK_TIMEOUT = httpx.Timeout(10.0, connect=CONNECT_TIMEOUT)

# Human text for each failure reason. "timeout" takes the connect timeout.
NET_REASONS = {
    "refused": "connection refused (nothing is listening at that address and port)",
    "dns": "host name not found",
    "tls": "its TLS certificate isn't trusted",
    "timeout": "no answer within {connect:g} seconds (wrong address, host down, or a firewall)",
    "slow": "it accepted the connection but didn't answer in time",
    "failed": "network error",
}
NOT_KAVITA = "it answers, but not like Kavita (or a Kavita too old to have /api/health)"


class TLSConfigError(Exception):
    """KAVITA_CA_BUNDLE or KAVITA_TLS_VERIFY can't be used."""


def tls_verify_from_env(env=os.environ) -> tuple[ssl.SSLContext | bool, str | None]:
    """(verify, warning) for httpx from KAVITA_CA_BUNDLE / KAVITA_TLS_VERIFY.

    KAVITA_CA_BUNDLE: a PEM file of extra CA certificates, trusted in
    addition to the system ones. KAVITA_TLS_VERIFY=false turns certificate
    checks off (not recommended); a CA bundle is then ignored."""
    raw = (env.get("KAVITA_TLS_VERIFY") or "true").strip().lower()
    if raw not in ("true", "false"):
        raise TLSConfigError(f"KAVITA_TLS_VERIFY must be true or false, not {raw!r}")
    bundle = (env.get("KAVITA_CA_BUNDLE") or "").strip()
    if raw == "false":
        warning = ("KAVITA_TLS_VERIFY=false: Kavita's TLS certificate is not checked, so anything "
                   "between this app and Kavita can read and change the traffic, including passwords.")
        if bundle:
            warning += " KAVITA_CA_BUNDLE is ignored."
        return False, warning
    if not bundle:
        return True, None
    if not os.path.isfile(bundle):
        raise TLSConfigError(f"KAVITA_CA_BUNDLE={bundle} is not a file")
    if not os.access(bundle, os.R_OK):
        raise TLSConfigError(f"KAVITA_CA_BUNDLE={bundle} is not readable by this user")
    ctx = ssl.create_default_context()
    try:
        ctx.load_verify_locations(cafile=bundle)
    except (ssl.SSLError, OSError, ValueError) as e:
        raise TLSConfigError(f"KAVITA_CA_BUNDLE={bundle} has no usable PEM certificates ({e})") from None
    return ctx, None


def display_url(base_url: str) -> str:
    """A Kavita base URL without user info, query or fragment."""
    try:
        u = httpx.URL(base_url)
    except Exception:  # noqa: BLE001
        return "(invalid KAVITA_BASE_URL)"
    if not u.host:
        return "(invalid KAVITA_BASE_URL)"
    host = f"[{u.host}]" if ":" in u.host else u.host
    port = f":{u.port}" if u.port else ""
    return f"{u.scheme}://{host}{port}{u.path.rstrip('/')}"


def net_reason(exc: BaseException) -> str:
    """Classify a failed request to Kavita by the exceptions in its chain."""
    seen = set()
    e: BaseException | None = exc
    while e is not None and id(e) not in seen:
        seen.add(id(e))
        if isinstance(e, (httpx.ConnectTimeout, httpx.PoolTimeout)):
            return "timeout"
        if isinstance(e, (httpx.ReadTimeout, httpx.WriteTimeout)):
            return "slow"
        if isinstance(e, ConnectionRefusedError):
            return "refused"
        if isinstance(e, socket.gaierror):
            return "dns"
        if isinstance(e, ssl.SSLError):
            return "tls"
        e = e.__cause__ or e.__context__
    return "failed"


def exc_names(exc: BaseException) -> str:
    """'ConnectTimeout <- TimeoutError', for logs."""
    names, seen = [], set()
    e: BaseException | None = exc
    while e is not None and id(e) not in seen and len(names) < 4:
        seen.add(id(e))
        names.append(type(e).__name__)
        e = e.__cause__ or e.__context__
    return " <- ".join(names)


def reason_text(reason: str) -> str:
    if reason == "not_kavita":
        return NOT_KAVITA
    return NET_REASONS.get(reason, NET_REASONS["failed"]).format(connect=CONNECT_TIMEOUT)


async def check(client: httpx.AsyncClient) -> tuple[bool, str, str]:
    """(ok, reason, detail) for the Kavita at client.base_url.

    Kavita answers GET /api/health with "Ok" and GET /api/admin/exists with
    true or false, both without signing in. reason is "ok", "not_kavita" or a
    NET_REASONS key; detail is for logs (error types or the HTTP status)."""
    try:
        r = await client.get("/api/health", timeout=CHECK_TIMEOUT)
        if r.status_code != 200 or r.text.strip() != "Ok":
            return False, "not_kavita", f"/api/health answered HTTP {r.status_code}"
        r = await client.get("/api/admin/exists", timeout=CHECK_TIMEOUT)
        try:
            body = r.json()
        except ValueError:
            body = None
        if r.status_code != 200 or not isinstance(body, bool):
            return False, "not_kavita", f"/api/admin/exists answered HTTP {r.status_code}"
    except httpx.HTTPError as e:
        return False, net_reason(e), exc_names(e)
    return True, "ok", "/api/health Ok"


async def _cli(url: str) -> int:
    try:
        verify, warning = tls_verify_from_env()
    except TLSConfigError as e:
        print(f"tls-config: {e}")
        return 2
    if warning:
        print(f"warning: {warning}", file=sys.stderr)
    async with httpx.AsyncClient(base_url=url, verify=verify) as client:
        ok, reason, detail = await check(client)
    shown = display_url(url)
    if ok:
        print(f"ok: Kavita answers at {shown}")
        return 0
    print(f"{reason}: {shown}: {reason_text(reason)} [{detail}]")
    return 1


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: python -m app.kavita_check KAVITA_URL", file=sys.stderr)
        sys.exit(2)
    sys.exit(asyncio.run(_cli(sys.argv[1])))
