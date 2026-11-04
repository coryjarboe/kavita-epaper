"""
kavita-epaper: minimal e-ink-friendly web UI for Kavita.

Sits alongside the official Kavita UI. Talks to Kavita's REST API.
Designed to be served behind a reverse proxy (e.g. nginx proxy manager).

All Kavita auth state (JWT + refresh token + apiKey) is kept in an
encrypted, authenticated cookie (Fernet). The browser only ever sees an
opaque session cookie. EPUB downloads are streamed through this app.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import hashlib
import hmac
import io
import ipaddress
import json
import logging
import os
import re
import secrets
import sys
import tempfile
import time
from typing import Any
from urllib.parse import quote

import httpx
from fastapi import Cookie, Depends, FastAPI, Form, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from . import kavita_check

# ----- config ---------------------------------------------------------------

KAVITA_BASE_URL = os.environ.get("KAVITA_BASE_URL", "http://127.0.0.1:5000").rstrip("/")
SECRET_KEY = os.environ.get("KAVITA_EPAPER_SECRET", "")
# Optional previous secret, for rotation: cookies encrypted under it are still
# accepted and re-issued under KAVITA_EPAPER_SECRET. Remove it after
# SESSION_TTL to finish the rotation.
SECRET_PREVIOUS = os.environ.get("KAVITA_EPAPER_SECRET_PREVIOUS", "")
COOKIE_NAME = os.environ.get("KAVITA_EPAPER_COOKIE", "kesess")
# Cookie 'Secure' attribute control. Tri-state:
#   "auto"  (default): set Secure when the incoming request is HTTPS, omit
#                       it when HTTP. Lets the same install serve both a
#                       reverse-proxied HTTPS hostname AND direct plain-HTTP
#                       access by IP without the cookie silently failing.
#   "true"            : always set Secure. Pin this when you only ever access
#                       via HTTPS and want browsers to refuse the cookie over
#                       HTTP even by accident.
#   "false"           : never set Secure. Only useful for testing.
# The 'Secure' flag tells browsers to refuse to send the cookie over plain
# HTTP. With hardcoded secure=True, direct-IP HTTP access silently fails
# because the browser drops the cookie on receipt.
COOKIE_SECURE = os.environ.get("KAVITA_EPAPER_COOKIE_SECURE", "auto").lower()
if COOKIE_SECURE not in ("auto", "true", "false"):
    COOKIE_SECURE = "auto"
# session lifetime in seconds; default 30 days. Kavita JWT itself is refreshed
# transparently on every request.
SESSION_TTL = int(os.environ.get("KAVITA_EPAPER_SESSION_TTL", str(60 * 60 * 24 * 30)))
# cover cache directory (optional grayscale-pre-rendered covers).
COVER_CACHE_DIR = os.environ.get("KAVITA_EPAPER_COVER_CACHE", "/var/cache/kavita-epaper/covers")
# Cover cache lifetime in seconds; 0 turns the disk cache off. Entries are
# per user, and an expired entry is only replaced after Kavita serves the
# cover to that user again.
_cover_ttl_raw = os.environ.get("KAVITA_EPAPER_COVER_TTL", "86400").strip() or "86400"
try:
    COVER_TTL = max(0, int(_cover_ttl_raw))
except ValueError:
    COVER_TTL = 86400
    logging.warning("KAVITA_EPAPER_COVER_TTL=%r is not a number; using 86400.", _cover_ttl_raw)
GRAYSCALE_COVERS = os.environ.get("KAVITA_EPAPER_GRAYSCALE", "true").lower() == "true"
# Reader keepalive interval in seconds; 0 (default) turns it off. While a
# reader page is visible it requests /ping this often, for e-readers whose
# Wi-Fi sleeps between page loads and gets dropped by the access point as
# idle. Clamped to 10..300.
_keepalive_raw = os.environ.get("KAVITA_EPAPER_KEEPALIVE_SECONDS", "0").strip() or "0"
try:
    KEEPALIVE_SECONDS = int(_keepalive_raw)
except ValueError:
    KEEPALIVE_SECONDS = 0
    logging.warning("KAVITA_EPAPER_KEEPALIVE_SECONDS=%r is not a number; keepalive is off.", _keepalive_raw)
if KEEPALIVE_SECONDS > 0:
    KEEPALIVE_SECONDS = max(10, min(KEEPALIVE_SECONDS, 300))
else:
    KEEPALIVE_SECONDS = 0

# Where users fix settings, for messages: .env and the configure command sit
# next to app/.
ENV_FILE_HINT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")
CONFIGURE_HINT = os.path.join(os.path.dirname(ENV_FILE_HINT), "configure")

# The session secret must be real: it encrypts every user's Kavita tokens.
# Refuse to start rather than run with none, the env.example placeholder, or
# a short one. Exit status 78 (EX_CONFIG) tells systemd not to restart-loop
# (RestartPreventExitStatus=78 in the unit). KAVITA_EPAPER_SECRET_PREVIOUS is
# not checked: during a rotation it is the old, possibly short, secret.
SECRET_MIN_LENGTH = 32
_SECRET_PLACEHOLDER = "CHANGE_ME_TO_A_LONG_RANDOM_STRING"
_EXIT_CONFIG = 78


def _secret_problem(secret: str) -> str | None:
    if not secret:
        return "is not set"
    if secret == _SECRET_PLACEHOLDER:
        return "is still the placeholder from env.example"
    if len(secret) < SECRET_MIN_LENGTH:
        return f"is too short ({len(secret)} characters, need at least {SECRET_MIN_LENGTH})"
    return None


_secret_issue = _secret_problem(SECRET_KEY)
if _secret_issue:
    sys.stderr.write(
        f"kavita-epaper: refusing to start: KAVITA_EPAPER_SECRET {_secret_issue}.\n"
        f"  Set a new one with:  sudo {CONFIGURE_HINT} new-secret\n"
        "  (or generate one with python3 -c 'import secrets; print(secrets.token_urlsafe(48))',\n"
        f"  set KAVITA_EPAPER_SECRET=<that value> in {ENV_FILE_HINT} and run: systemctl restart kavita-epaper)\n"
        "  A new secret signs everyone out once.\n"
    )
    sys.stderr.flush()
    sys.exit(_EXIT_CONFIG)

# Try to make grayscale cover pre-rendering available, but don't require Pillow.
try:
    from PIL import Image  # type: ignore

    HAS_PIL = True
except Exception:  # noqa: BLE001
    HAS_PIL = False
    if GRAYSCALE_COVERS:
        logging.warning("Pillow not installed; serving original color covers.")

os.makedirs(COVER_CACHE_DIR, exist_ok=True)

# ----- app + templating ------------------------------------------------------

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
templates = Jinja2Templates(directory=os.path.join(BASE_DIR, "templates"))

app = FastAPI(title="kavita-epaper", docs_url=None, redoc_url=None, openapi_url=None)
app.mount(
    "/static",
    StaticFiles(directory=os.path.join(BASE_DIR, "static")),
    name="static",
)

# TLS to Kavita: KAVITA_CA_BUNDLE adds CA certificates to the system ones;
# KAVITA_TLS_VERIFY=false turns checks off (warned at startup). A setting that
# can't work stops the app, like a bad secret.
try:
    KAVITA_TLS_VERIFY, _tls_warning = kavita_check.tls_verify_from_env()
except kavita_check.TLSConfigError as _e:
    sys.stderr.write(
        f"kavita-epaper: refusing to start: {_e}.\n"
        f"  Fix it with:  sudo {CONFIGURE_HINT} ca-bundle <file.pem|none>  (or kavita-tls-verify on)\n"
        f"  or in {ENV_FILE_HINT}, then: systemctl restart kavita-epaper\n"
    )
    sys.stderr.flush()
    sys.exit(_EXIT_CONFIG)

# Single shared httpx client. Long read timeout for downloads; a short
# connect timeout so an unreachable Kavita fails within a few seconds.
KAVITA_CONNECT_TIMEOUT = kavita_check.CONNECT_TIMEOUT
_http = httpx.AsyncClient(
    base_url=KAVITA_BASE_URL,
    timeout=httpx.Timeout(connect=KAVITA_CONNECT_TIMEOUT, read=120.0, write=60.0, pool=10.0),
    verify=KAVITA_TLS_VERIFY,
)

# Read the installed version (used for cache-busting static asset URLs).
try:
    _version_path = os.path.join(BASE_DIR, "..", "VERSION")
    with open(_version_path) as _f:
        APP_VERSION = _f.read().strip() or "dev"
except Exception:  # noqa: BLE001
    APP_VERSION = "dev"

templates.env.globals["APP_VERSION"] = APP_VERSION
templates.env.globals["KEEPALIVE_SECONDS"] = KEEPALIVE_SECONDS


def _cookie_fernet(secret: str) -> Fernet:
    """Fernet key for the session cookie, derived from the app secret."""
    key = HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=None,
        info=b"kavita-epaper session cookie v1",
    ).derive(secret.encode())
    return Fernet(base64.urlsafe_b64encode(key))


_fernet = _cookie_fernet(SECRET_KEY)
_fernet_previous = (
    _cookie_fernet(SECRET_PREVIOUS) if SECRET_PREVIOUS and SECRET_PREVIOUS != SECRET_KEY else None
)

logger = logging.getLogger("kavita-epaper")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
# httpx logs every request URL at INFO, and Kavita's image and resource
# endpoints take the apiKey as a query parameter, so INFO would write live
# keys to the journal. Warnings and errors still come through.
logging.getLogger("httpx").setLevel(logging.WARNING)


class _DropPingAccessLog(logging.Filter):
    """Keep the reader keepalive's /ping and health probes' /healthz out of
    uvicorn's access log, which would otherwise get a line every few seconds."""

    QUIET = ("/ping", "/healthz")

    def filter(self, record: logging.LogRecord) -> bool:
        args = record.args
        if isinstance(args, tuple) and len(args) >= 3:
            return str(args[2]).split("?", 1)[0] not in self.QUIET
        return True


logging.getLogger("uvicorn.access").addFilter(_DropPingAccessLog())


# ----- session helpers -------------------------------------------------------


def _encode_session(data: dict) -> str:
    token = _fernet.encrypt(json.dumps(data, separators=(",", ":")).encode())
    # Drop base64 padding: "=" would make the cookie value a quoted string.
    return token.decode().rstrip("=")


def _decode_session(raw: str | None) -> tuple[dict | None, bool]:
    """Return (data, reissue). data is None for a missing, foreign (e.g. the
    signed-only format before 0.7.19), tampered or expired cookie, which the
    caller treats as signed out. reissue is True when only the previous
    secret could decrypt it, so the caller re-encrypts it under the current
    one."""
    if not raw:
        return None, False
    try:
        token = (raw + "=" * (-len(raw) % 4)).encode("ascii")
    except UnicodeEncodeError:
        return None, False
    for fernet, reissue in ((_fernet, False), (_fernet_previous, True)):
        if fernet is None:
            continue
        try:
            data = json.loads(fernet.decrypt(token, ttl=SESSION_TTL))
        except Exception:  # noqa: BLE001
            continue
        return (data, reissue) if isinstance(data, dict) else (None, False)
    return None, False


def _set_session_cookie(response: Response, data: dict, request: Request | None = None) -> None:
    # Resolve the Secure flag per-request. Uvicorn is launched with
    # --proxy-headers and trusts X-Forwarded-Proto from the addresses in
    # KAVITA_EPAPER_FORWARDED_ALLOW_IPS, so request.url.scheme reflects the
    # proxy's scheme for those and the actual transport for everyone else.
    if COOKIE_SECURE == "auto":
        secure = bool(request and request.url.scheme == "https")
    else:
        secure = COOKIE_SECURE == "true"
    response.set_cookie(
        COOKIE_NAME,
        _encode_session(data),
        max_age=SESSION_TTL,
        httponly=True,
        secure=secure,
        samesite="lax",
        path="/",
    )


def _clear_session_cookie(response: Response) -> None:
    response.delete_cookie(COOKIE_NAME, path="/")


# ----- Kavita client ---------------------------------------------------------


class Session:
    """Per-request handle to the Kavita session in the cookie."""

    def __init__(self, raw_cookie: str | None):
        data, reissue = _decode_session(raw_cookie)
        self.data = data or {}
        # A cookie only the previous secret could open is written back under
        # the current one by the next _flush_session.
        self.dirty = reissue

    @property
    def token(self) -> str | None:
        return self.data.get("token")

    @property
    def refresh_token(self) -> str | None:
        return self.data.get("refresh_token")

    @property
    def api_key(self) -> str | None:
        return self.data.get("api_key")

    @property
    def username(self) -> str | None:
        return self.data.get("username")

    @property
    def is_authed(self) -> bool:
        return bool(self.token)

    def update_from_user_dto(self, user: dict) -> None:
        self.data["token"] = user.get("token")
        self.data["refresh_token"] = user.get("refreshToken")
        self.data["api_key"] = user.get("apiKey")
        self.data["username"] = user.get("username")
        self.data["user_id"] = user.get("id")
        self.dirty = True

    def update_tokens(self, token: str, refresh_token: str) -> None:
        self.data["token"] = token
        self.data["refresh_token"] = refresh_token
        self.dirty = True

    def clear(self) -> None:
        self.data = {}
        self.dirty = True


async def _kavita_request(
    method: str,
    path: str,
    *,
    session: Session,
    json: Any | None = None,
    params: dict | None = None,
    stream: bool = False,
) -> httpx.Response:
    """Hit Kavita with the session JWT, refreshing once on 401."""
    headers = {"Accept": "application/json"}
    if session.token:
        headers["Authorization"] = f"Bearer {session.token}"

    if stream:
        # caller will manage the response lifecycle
        req = _http.build_request(method, path, json=json, params=params, headers=headers)
        return await _http.send(req, stream=True)

    resp = await _http.request(method, path, json=json, params=params, headers=headers)

    if resp.status_code == 401 and session.refresh_token:
        # Try a one-shot refresh.
        if await _refresh(session):
            headers["Authorization"] = f"Bearer {session.token}"
            resp = await _http.request(method, path, json=json, params=params, headers=headers)

    return resp


async def _refresh(session: Session) -> bool:
    if not session.token or not session.refresh_token:
        return False
    try:
        r = await _http.post(
            "/api/Account/refresh-token",
            json={"token": session.token, "refreshToken": session.refresh_token},
            timeout=10.0,
        )
        if r.status_code == 200:
            body = r.json()
            session.update_tokens(body["token"], body["refreshToken"])
            return True
    except Exception as e:  # noqa: BLE001
        logger.warning("token refresh failed: %s", e)
    return False


def get_session(request: Request) -> Session:
    raw = request.cookies.get(COOKIE_NAME)
    return Session(raw)


def _flush_session(response: Response, session: Session, request: Request | None = None) -> None:
    if session.dirty:
        if session.data:
            _set_session_cookie(response, session.data, request)
        else:
            _clear_session_cookie(response)


def require_auth(session: Session = Depends(get_session)) -> Session:
    if not session.is_authed:
        # Use a custom exception so we can render a redirect cleanly.
        raise HTTPException(status_code=302, headers={"Location": "/login"})
    return session


# ----- routes ----------------------------------------------------------------


@app.exception_handler(HTTPException)
async def http_exc(request: Request, exc: HTTPException):
    if exc.status_code == 302 and exc.headers and "Location" in exc.headers:
        response = RedirectResponse(exc.headers["Location"], status_code=302)
        # Signed out with a cookie present: it is stale (old format, expired,
        # other secret), so drop it instead of sending it on every request.
        if exc.headers["Location"] == "/login" and COOKIE_NAME in request.cookies:
            _clear_session_cookie(response)
        return response
    return templates.TemplateResponse(
        "error.html",
        {"request": request, "status": exc.status_code, "detail": str(exc.detail)},
        status_code=exc.status_code,
    )


@app.get("/", response_class=HTMLResponse)
async def root(request: Request, session: Session = Depends(get_session)):
    if not session.is_authed:
        return RedirectResponse("/login", status_code=302)
    return RedirectResponse("/library", status_code=302)


# ----- sign-in errors ---------------------------------------------------------
# The sign-in POST redirects to /login with an error code (and at most a
# reason code, a status number or Kavita's own message); the login page
# builds the text. The Kavita URL in the text comes from the config, never
# from the query string, and never includes user info or a query.

_JWTISH = re.compile(r"eyJ[\w-]{8,}|[A-Za-z0-9+/_=-]{40,}")
# Clients that may see the internal Kavita URL and .env path in sign-in
# errors. The client address is the one uvicorn resolved, so behind a proxy
# it is the forwarded address only when the proxy is trusted
# (KAVITA_EPAPER_FORWARDED_ALLOW_IPS).
_LOCAL_NETS = tuple(ipaddress.ip_network(n) for n in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8",
    "::1/128", "fc00::/7", "fe80::/10"))


def _client_is_local(request: Request) -> bool:
    host = request.client.host if request.client else ""
    try:
        ip = ipaddress.ip_address(host.split("%", 1)[0])
    except ValueError:
        return False
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return any(ip in net for net in _LOCAL_NETS)


def _kavita_url_for_display() -> str:
    return kavita_check.display_url(KAVITA_BASE_URL)


_net_reason = kavita_check.net_reason
_exc_names = kavita_check.exc_names


def _kavita_message(r: httpx.Response, password: str) -> str | None:
    """Kavita's own reason for refusing a sign-in, if it gave a short, safe
    one: a JSON string, {"message": ...}, ASP.NET problem details, or plain
    text. Dropped if it looks like a token or contains the password."""
    text = None
    try:
        body = r.json()
    except ValueError:
        body = None
        if r.headers.get("content-type", "").startswith("text/plain"):
            text = r.text
    if isinstance(body, str):
        text = body
    elif isinstance(body, dict):
        errors = body.get("errors")
        if isinstance(errors, dict):
            for v in errors.values():
                if isinstance(v, list) and v and isinstance(v[0], str):
                    text = v[0]
                    break
        if not text:
            for key in ("message", "detail", "title"):
                if isinstance(body.get(key), str):
                    text = body[key]
                    break
    if not text:
        return None
    text = " ".join(text.split())[:200]
    if not text or _JWTISH.search(text) or (password and password in text):
        return None
    return text


def _login_error_text(error: str | None, reason: str | None, status: str | None,
                      msg: str | None, local: bool) -> tuple[str | None, str | None]:
    """(message, hint) for the login page. Only local clients (see
    _client_is_local) see the Kavita URL, the reason and the .env path."""
    if not error:
        return None, None
    url = _kavita_url_for_display()
    hint = f"Check the Kavita address: sudo {CONFIGURE_HINT} kavita-url <address>"
    code = status if status and status.isdigit() and len(status) == 3 else None
    if not local and error in ("unreachable", "not_kavita"):
        return "Can't reach the Kavita server. Check the server logs.", None
    if not local and error == "kavita_error":
        return f"The Kavita server returned an error (HTTP {code or '?'}). Try again later.", None
    if error == "unreachable":
        why = kavita_check.reason_text(reason if reason in kavita_check.NET_REASONS else "failed")
        if reason == "slow":
            hint = "Kavita may be busy, for example scanning a library. Try again in a moment."
        elif reason == "tls":
            hint = (f"If Kavita uses a private CA: sudo {CONFIGURE_HINT} ca-bundle <file.pem> "
                    "(see the README's Kavita over HTTPS section).")
        return f"Couldn't reach Kavita at {url}: {why}.", hint
    if error == "not_kavita":
        detail = f" (HTTP {code} for the sign-in request)" if code else " (the reply wasn't a Kavita sign-in response)"
        return f"That doesn't look like Kavita at {url}{detail}.", hint
    if error == "kavita_error":
        return f"Kavita at {url} returned an error (HTTP {code or '?'}). Try again, or check Kavita's logs.", None
    if error == "rejected":
        if msg:
            return f"Kavita said: {' '.join(msg.split())[:200]}", None
        if code == "401":
            return "Wrong username or password.", None
        return f"Kavita refused the sign-in (HTTP {code or '?'}).", None
    return "Sign-in failed.", None


def _login_redirect(**params: str) -> RedirectResponse:
    query = "&".join(f"{k}={quote(v, safe='')}" for k, v in params.items() if v)
    return RedirectResponse(f"/login?{query}", status_code=302)


@app.get("/login", response_class=HTMLResponse)
async def login_form(
    request: Request,
    error: str | None = None,
    reason: str | None = None,
    status: str | None = None,
    msg: str | None = None,
):
    message, hint = _login_error_text(error, reason, status, msg, _client_is_local(request))
    return templates.TemplateResponse(
        "login.html", {"request": request, "error": message, "error_hint": hint}
    )


@app.post("/login")
async def login_submit(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
):
    url = _kavita_url_for_display()
    try:
        r = await _http.post(
            "/api/Account/login",
            json={"username": username, "password": password, "apiKey": ""},
            timeout=httpx.Timeout(15.0, connect=KAVITA_CONNECT_TIMEOUT),
        )
    except httpx.HTTPError as e:
        reason = _net_reason(e)
        logger.warning("login: could not reach Kavita at %s: %s (%s)", url, reason, _exc_names(e))
        return _login_redirect(error="unreachable", reason=reason)

    if r.status_code in (400, 401):
        return _login_redirect(error="rejected", status=str(r.status_code),
                               msg=_kavita_message(r, password) or "")
    if r.status_code in (404, 405):
        logger.warning("login: %s answered HTTP %d for /api/Account/login; is KAVITA_BASE_URL right?",
                       url, r.status_code)
        return _login_redirect(error="not_kavita", status=str(r.status_code))
    if r.status_code != 200:
        logger.warning("login: Kavita at %s answered HTTP %d", url, r.status_code)
        return _login_redirect(error="kavita_error", status=str(r.status_code))

    try:
        user = r.json()
    except ValueError:
        user = None
    if not isinstance(user, dict) or not isinstance(user.get("token"), str):
        logger.warning("login: reply from %s isn't a Kavita sign-in response (content-type %s)",
                       url, r.headers.get("content-type", "none"))
        return _login_redirect(error="not_kavita")

    session = Session(None)
    session.update_from_user_dto(user)
    response = RedirectResponse("/library", status_code=302)
    _flush_session(response, session, request)
    return response


@app.post("/logout")
async def logout(request: Request):
    response = RedirectResponse("/login", status_code=302)
    _clear_session_cookie(response)
    return response


@app.get("/library", response_class=HTMLResponse)
async def library_root(
    request: Request,
    session: Session = Depends(require_auth),
):
    """Default landing: show all user-accessible libraries with a series grid
    of the first one (alphabetically). Library tabs snap-scroll at the top."""
    libs = await _get_user_libraries(session)
    if not libs:
        resp = templates.TemplateResponse(
            "library.html",
            {
                "request": request,
                "libraries": [],
                "current_lib": None,
                "series": [],
                "username": session.username,
                "page": 1,
                "has_next": False,
            },
        )
        _flush_session(resp, session, request)
        return resp
    return RedirectResponse(f"/library/{libs[0]['id']}", status_code=302)


@app.get("/library/{library_id}", response_class=HTMLResponse)
async def library_view(
    request: Request,
    library_id: int,
    page: int = Query(1, ge=1),
    session: Session = Depends(require_auth),
):
    libs = await _get_user_libraries(session)
    current = next((l for l in libs if l["id"] == library_id), None)
    if current is None:
        raise HTTPException(404, "library not found or no access")

    page_size = 4
    series, has_next = await _get_series_for_library(
        session, library_id, page=page, page_size=page_size
    )

    resp = templates.TemplateResponse(
        "library.html",
        {
            "request": request,
            "libraries": libs,
            "current_lib": current,
            "series": series,
            "username": session.username,
            "page": page,
            "has_next": has_next,
        },
    )
    _flush_session(resp, session, request)
    return resp


@app.get("/series/{series_id}", response_class=HTMLResponse)
async def series_view(
    request: Request,
    series_id: int,
    chapter_page: int = Query(1, ge=1, alias="cp"),
    back_lib_page: int = Query(1, ge=1, alias="bp"),
    session: Session = Depends(require_auth),
):
    # Fetch series basic info + detail (volumes/chapters) in two calls.
    r_series = await _kavita_request(
        "GET", f"/api/Series/{series_id}", session=session
    )
    if r_series.status_code != 200:
        raise HTTPException(r_series.status_code, "series not found")
    series = r_series.json()

    r_detail = await _kavita_request(
        "GET", "/api/Series/series-detail", session=session, params={"seriesId": series_id}
    )
    detail = r_detail.json() if r_detail.status_code == 200 else {}

    # Flatten download targets in reading order.
    all_items = _flatten_download_items(detail)

    # Paginate the chapter list; Obook6 viewport fits ~6 rows comfortably.
    ch_page_size = 6
    ch_start = (chapter_page - 1) * ch_page_size
    items = all_items[ch_start : ch_start + ch_page_size]
    ch_has_next = (ch_start + ch_page_size) < len(all_items)

    # Series format from Kavita's MangaFormat enum:
    #   0=Image, 1=Archive, 2=Unknown, 3=Epub, 4=Pdf
    # The built-in reader only handles EPUB. For everything else, hide the
    # read button; users can still download the file or open in Kavita.
    is_epub = series.get("format") == 3

    resp = templates.TemplateResponse(
        "series.html",
        {
            "request": request,
            "series": series,
            "detail": detail,
            "items": items,
            "is_epub": is_epub,
            "username": session.username,
            "chapter_page": chapter_page,
            "ch_has_next": ch_has_next,
            "ch_total": len(all_items),
            "back_lib_page": back_lib_page,
        },
    )
    _flush_session(resp, session, request)
    return resp


@app.post("/series/{series_id}/mark-read/{chapter_id}")
async def mark_chapter_read(
    request: Request,
    series_id: int,
    chapter_id: int,
    session: Session = Depends(require_auth),
):
    await _kavita_request(
        "POST",
        "/api/Reader/mark-chapter-read",
        session=session,
        json={"seriesId": series_id, "chapterId": chapter_id, "generateReadingSession": False},
    )
    resp = RedirectResponse(f"/series/{series_id}", status_code=302)
    _flush_session(resp, session, request)
    return resp


# ----- built-in reader ------------------------------------------------------


@app.get("/read/{chapter_id}", response_class=HTMLResponse)
async def read_view(
    request: Request,
    chapter_id: int,
    # `page` is intentionally Optional. When the user opens the reader from the
    # series page (no `?page=` in URL), we resume from saved progress. When the
    # prev/next buttons navigate, they always include `?page=` explicitly, so
    # that path skips the resume lookup. Previously defaulted to 1, which then
    # got POSTed back to Kavita's /Reader/progress, overwriting saved progress
    # with pageNum=0 on every reader open.
    page: int | None = Query(None, ge=1),
    back_lib_page: int = Query(1, ge=1, alias="bp"),
    session: Session = Depends(require_auth),
):
    """Built-in EPUB reader. Fetches Kavita's pre-rendered page HTML and wraps
    it in our e-ink chrome: no cross-origin navigation, stays in PWA scope."""
    r_info = await _kavita_request(
        "GET", f"/api/Book/{chapter_id}/book-info", session=session
    )
    if r_info.status_code != 200:
        raise HTTPException(r_info.status_code, "book info unavailable")
    info = r_info.json()

    total_pages = max(int(info.get("pages", 1) or 1), 1)

    # Resume from saved progress when no explicit page was given.
    # GetProgress returns {pageNum:0,...} when there's no prior progress, so the
    # fallback is identical to the old default-1 behaviour.
    if page is None:
        try:
            r_prog = await _kavita_request(
                "GET",
                "/api/Reader/get-progress",
                session=session,
                params={"chapterId": chapter_id},
            )
            if r_prog.status_code == 200:
                saved = r_prog.json() or {}
                page = int(saved.get("pageNum") or 0) + 1
            else:
                page = 1
        except Exception as e:  # noqa: BLE001
            logger.warning("progress lookup failed: %s", e)
            page = 1

    page = max(1, min(page, total_pages))
    # Kavita's book-page is 0-indexed
    api_page = page - 1

    r_page = await _kavita_request(
        "GET",
        f"/api/Book/{chapter_id}/book-page",
        session=session,
        params={"page": api_page},
    )
    if r_page.status_code != 200:
        raise HTTPException(r_page.status_code, "page unavailable")
    page_html = _decode_book_page(r_page)
    page_html = _rewrite_book_resources(page_html, chapter_id)

    # Best-effort progress save: don't fail the read if Kavita rejects it
    try:
        await _kavita_request(
            "POST",
            "/api/Reader/progress",
            session=session,
            json={
                "libraryId": info.get("libraryId"),
                "seriesId": info.get("seriesId"),
                "volumeId": info.get("volumeId"),
                "chapterId": chapter_id,
                "pageNum": api_page,
                "bookScrollId": None,
            },
        )
    except Exception as e:  # noqa: BLE001
        logger.warning("progress save failed: %s", e)

    resp = templates.TemplateResponse(
        "read.html",
        {
            "request": request,
            "info": info,
            "page_html": page_html,
            "page": page,
            "total_pages": total_pages,
            "chapter_id": chapter_id,
            "series_id": info.get("seriesId"),
            "back_lib_page": back_lib_page,
        },
    )
    _flush_session(resp, session, request)
    return resp


@app.get("/read-resource/{chapter_id}")
async def read_resource(
    request: Request,
    chapter_id: int,
    file: str = Query(...),
    session: Session = Depends(require_auth),
):
    """Proxy a resource (image, font, CSS) embedded in the EPUB. Keeps the
    apiKey server-side and serves on our origin so book HTML stays same-origin.

    Image resources go through the same grayscale conversion as covers (gated
    on KAVITA_EPAPER_GRAYSCALE). CSS and font resources pass through unchanged
    since they're not image data."""
    r = await _kavita_request(
        "GET",
        f"/api/Book/{chapter_id}/book-resources",
        session=session,
        params={"file": file, "apiKey": session.api_key or ""},
    )
    if r.status_code != 200:
        raise HTTPException(r.status_code, "resource not found")

    ctype = r.headers.get("content-type", "application/octet-stream")
    data, ctype = _to_grayscale(r.content, ctype)

    return Response(
        content=data,
        media_type=ctype,
        headers={"Cache-Control": "private, max-age=86400"},
    )


@app.get("/cover/series/{series_id}")
async def cover_series(
    request: Request,
    series_id: int,
    session: Session = Depends(require_auth),
):
    return await _serve_cover(
        cache_key=f"series-{series_id}",
        path="/api/Image/series-cover",
        params={"seriesId": series_id, "apiKey": session.api_key or ""},
        session=session,
    )


@app.get("/cover/library/{library_id}")
async def cover_library(
    request: Request,
    library_id: int,
    session: Session = Depends(require_auth),
):
    return await _serve_cover(
        cache_key=f"library-{library_id}",
        path="/api/Image/library-cover",
        params={"libraryId": library_id, "apiKey": session.api_key or ""},
        session=session,
    )


@app.get("/download/chapter/{chapter_id}")
async def download_chapter(
    request: Request,
    chapter_id: int,
    session: Session = Depends(require_auth),
):
    """Stream a chapter file through to the client.

    Kavita's /api/Download/chapter returns the file as-is when there's a single
    file in the chapter (typical for EPUB), or a zip when there are multiple.
    We just pass the bytes and headers straight through.
    """
    return await _proxy_download(
        path="/api/Download/chapter",
        params={"chapterId": chapter_id, "correlationId": secrets.token_hex(8)},
        session=session,
    )


@app.get("/download/volume/{volume_id}")
async def download_volume(
    request: Request,
    volume_id: int,
    session: Session = Depends(require_auth),
):
    return await _proxy_download(
        path="/api/Download/volume",
        params={"volumeId": volume_id, "correlationId": secrets.token_hex(8)},
        session=session,
    )


# /healthz: 200 "ok" when this app is up and Kavita answers like Kavita,
# otherwise 503 with a short reason code. No sign-in, so it never shows the
# Kavita URL. Results are reused for a few seconds so frequent probes don't
# turn into a stream of requests to Kavita.
HEALTH_CACHE_SECONDS = 10.0
_health_cache: tuple[float, bool, str] | None = None
_health_lock = asyncio.Lock()


@app.get("/healthz", include_in_schema=False)
async def healthz():
    global _health_cache
    async with _health_lock:
        now = time.monotonic()
        if _health_cache is None or now - _health_cache[0] >= HEALTH_CACHE_SECONDS:
            ok, reason, detail = await kavita_check.check(_http)
            if not ok and (_health_cache is None or _health_cache[1]):
                logger.warning("healthz: Kavita at %s: %s (%s)", _kavita_url_for_display(), reason, detail)
            _health_cache = (now, ok, reason)
        _, ok, reason = _health_cache
    headers = {"Cache-Control": "no-store"}
    if ok:
        return Response("ok\n", media_type="text/plain", headers=headers)
    return Response(f"kavita: {reason}\n", media_type="text/plain", status_code=503, headers=headers)


@app.get("/ping", include_in_schema=False)
async def ping():
    """Reader keepalive target. Takes no session: it never reads, refreshes
    or sets the cookie and never calls Kavita, so it has no auth side effects.
    Not logged at INFO (see _DropPingAccessLog)."""
    return Response(status_code=204, headers={"Cache-Control": "no-store"})


@app.get("/sw.js")
async def service_worker():
    """Serve the service worker at root scope (required: SW scope is bounded
    by URL path). Serving from /static/sw.js would restrict its control to
    /static/* only.
    """
    path = os.path.join(BASE_DIR, "static", "sw.js")
    with open(path, "rb") as f:
        content = f.read()
    return Response(
        content=content,
        media_type="application/javascript",
        headers={
            "Cache-Control": "no-cache",
            "Service-Worker-Allowed": "/",
        },
    )


@app.get("/manifest.json")
async def manifest():
    """Serve the PWA manifest at root for convention."""
    path = os.path.join(BASE_DIR, "static", "manifest.json")
    with open(path, "rb") as f:
        content = f.read()
    return Response(
        content=content,
        media_type="application/manifest+json",
        headers={"Cache-Control": "public, max-age=3600"},
    )


# ----- helpers ---------------------------------------------------------------


async def _get_user_libraries(session: Session) -> list[dict]:
    """Libraries the current user has access to."""
    r = await _kavita_request("GET", "/api/Library/user-libraries", session=session)
    if r.status_code != 200:
        # Admin fallback.
        r = await _kavita_request("GET", "/api/Library/libraries", session=session)
    if r.status_code != 200:
        raise HTTPException(r.status_code, "could not fetch libraries")
    libs = r.json() or []
    libs.sort(key=lambda l: (l.get("name") or "").lower())
    return libs


async def _get_series_for_library(
    session: Session, library_id: int, *, page: int, page_size: int
) -> tuple[list[dict], bool]:
    """Fetch a page of series for a library via /api/Series/v2.

    Kavita historically (v0.8.x→0.9.x) sometimes ignores the PageSize query
    param on this endpoint. We defensively slice the returned list to the
    requested page window; works whether or not the server honored it.
    """
    # SeriesFilterField: 19 == Libraries, FilterComparison: 0 == Equal,
    # FilterCombination: 1 == And, SeriesSortField: 1 == SortName.
    # We deliberately omit `limitTo` (some Kavita builds treat 0 as
    # "unlimited" and let it override pagination).
    body = {
        "statements": [
            {"comparison": 0, "field": 19, "value": str(library_id)},
        ],
        "combination": 1,
        "sortOptions": {"sortField": 1, "isAscending": True},
    }
    r = await _kavita_request(
        "POST",
        "/api/Series/v2",
        session=session,
        json=body,
        params={"PageNumber": page, "PageSize": page_size},
    )
    if r.status_code != 200:
        raise HTTPException(r.status_code, "could not fetch series")
    raw = r.json() or []

    # Decide whether Kavita honored PageSize.
    # If we asked for page N at size S and got back more than S items, Kavita
    # gave us the full list, so we slice ourselves. Otherwise trust the server.
    if len(raw) > page_size:
        start = (page - 1) * page_size
        series = raw[start : start + page_size]
        has_next = (start + page_size) < len(raw)
    else:
        series = raw
        # Trust the Pagination header if present.
        pagination = r.headers.get("Pagination")
        has_next = False
        if pagination:
            try:
                import json as _json

                pg = _json.loads(pagination)
                has_next = int(pg.get("currentPage", page)) < int(
                    pg.get("totalPages", page)
                )
            except Exception:  # noqa: BLE001
                has_next = len(series) >= page_size
        else:
            has_next = len(series) >= page_size
    return series, has_next


def _flatten_download_items(detail: dict) -> list[dict]:
    """Build a flat list of download targets in reading order.

    Each item: {kind: 'chapter'|'volume', id, label, pages, pages_read}.
    """
    out: list[dict] = []
    storyline = detail.get("storylineChapters") or []
    if storyline:
        for ch in storyline:
            out.append(
                {
                    "kind": "chapter",
                    "id": ch.get("id"),
                    "label": _chapter_label(ch),
                    "pages": ch.get("pages", 0),
                    "pages_read": ch.get("pagesRead", 0),
                    "volume_id": ch.get("volumeId"),
                }
            )
        return out
    # Fallback: volumes then specials.
    for v in detail.get("volumes") or []:
        chapters = v.get("chapters") or []
        if len(chapters) == 1:
            ch = chapters[0]
            out.append(
                {
                    "kind": "chapter",
                    "id": ch.get("id"),
                    "label": v.get("name") or f"Volume {v.get('minNumber')}",
                    "pages": ch.get("pages", 0),
                    "pages_read": ch.get("pagesRead", 0),
                    "volume_id": v.get("id"),
                }
            )
        else:
            for ch in chapters:
                out.append(
                    {
                        "kind": "chapter",
                        "id": ch.get("id"),
                        "label": _chapter_label(ch),
                        "pages": ch.get("pages", 0),
                        "pages_read": ch.get("pagesRead", 0),
                        "volume_id": v.get("id"),
                    }
                )
    for ch in detail.get("specials") or []:
        out.append(
            {
                "kind": "chapter",
                "id": ch.get("id"),
                "label": ch.get("title") or ch.get("range") or "Special",
                "pages": ch.get("pages", 0),
                "pages_read": ch.get("pagesRead", 0),
                "volume_id": ch.get("volumeId"),
            }
        )
    return out


def _chapter_label(ch: dict) -> str:
    title = ch.get("title")
    if title and title.strip():
        return title.strip()
    rng = ch.get("range")
    if rng:
        return f"Chapter {rng}"
    n = ch.get("number")
    if n:
        return f"Chapter {n}"
    return "Chapter"


def _decode_book_page(resp) -> str:
    """Pull the actual HTML out of Kavita's /book-page response.

    The endpoint advertises both application/json and text/plain responses.
    With our default Accept header, Kavita returns JSON: a *string* like
    "<div>...</div>" with backslash-escaped chars (\\n, \\u00A0, etc).
    Decoding via .json() unescapes them. Falls back to raw text if the
    server happens to send text/plain or the parse fails.
    """
    ct = (resp.headers.get("content-type") or "").lower()
    if "json" in ct:
        try:
            body = resp.json()
        except Exception:  # noqa: BLE001
            return resp.text
        # Most likely a bare string. Be defensive for possible {html:...} wrappers.
        if isinstance(body, str):
            return body
        if isinstance(body, dict):
            for key in ("html", "content", "page", "body"):
                v = body.get(key)
                if isinstance(v, str):
                    return v
        return resp.text
    return resp.text


def _rewrite_book_resources(html: str, chapter_id: int) -> str:
    """Rewrite Kavita book-resources URLs in the page HTML to point at our own
    proxy, so resources load from kavita-epaper's origin (keeping the page
    same-origin and the apiKey server-side).

    Kavita's BookController constructs URLs as:
        //{Host}{PathBase}/api/book/{chapterId}/book-resources?file=...
    (see Kavita API/Controllers/BookController.cs GetBookPage and
    API/Services/BookService.cs line ~1108).

    So we have to strip the protocol-relative host prefix too, not just the
    /api/book/... path portion. Otherwise the rewritten URL still points at
    the Kavita host directly, which 404s (no valid apiKey) and shows as a
    broken-image icon in the reader.

    Matches any chapter id (Kavita sometimes references resources from other
    chapters in the same book). Case-insensitive. Preserves the query string
    so file= stays intact for the resource fetch; any apiKey in it is then
    removed by _strip_api_key, since /read-resource adds its own.
    """
    # Capture group 1: the chapter id. Drop everything from `//...` through
    # `/api/book/{id}/book-resources` and replace with `/read-resource/{id}`.
    # The (?:...) host segment is non-capturing.
    pattern = re.compile(
        r"(?://[^/\s\"']+)?(?:/[^/\s\"']*)*?/api/book/(\d+)/book-resources",
        re.IGNORECASE,
    )
    return _strip_api_key(pattern.sub(r"/read-resource/\1", html))


# An apiKey query parameter, with the separator in front of it (?, & or the
# HTML-escaped &amp;) and the one after it, if any.
_API_KEY_PARAM = re.compile(
    r"([?&]|&amp;)apikey=[^&\"'\s<>)]*((?:&amp;|&)?)", re.IGNORECASE
)


def _strip_api_key(html: str) -> str:
    """Remove apiKey query parameters from URLs in book page HTML.

    Kavita embeds the user's apiKey in every book-resources URL. /read-resource
    adds the key server-side, so the browser's copy is never used; leaving it
    in would put a live key in the DOM and in the access log on every image
    load. "?apiKey=K&file=x" becomes "?file=x", "?file=x&apiKey=K" becomes
    "?file=x", and other parameters keep their separators."""

    def repl(m: re.Match) -> str:
        lead, trail = m.group(1), m.group(2)
        return "?" if lead == "?" else trail

    return _API_KEY_PARAM.sub(repl, html)


def _to_grayscale(data: bytes, content_type: str) -> tuple[bytes, str]:
    """Convert image bytes to grayscale JPEG. Returns (new_data, new_content_type).

    No-ops (returns the input unchanged) when:
      - Pillow isn't installed (HAS_PIL is False),
      - GRAYSCALE_COVERS is disabled,
      - content_type isn't an image type,
      - content_type is SVG (Pillow can't process XML; browsers will render
        SVG using CSS color rules and the e-ink display will dither it),
      - the conversion raises any exception (broken image, unsupported codec).

    Centralizes the grayscale logic so /cover/* and /read-resource/* behave
    identically and don't drift apart over time.
    """
    if not GRAYSCALE_COVERS or not HAS_PIL:
        return data, content_type
    if not content_type.startswith("image/"):
        return data, content_type
    if "svg" in content_type.lower():
        return data, content_type
    try:
        img = Image.open(io.BytesIO(data))
        img = img.convert("L")  # 8-bit grayscale
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=78, optimize=True)
        return buf.getvalue(), "image/jpeg"
    except Exception as e:  # noqa: BLE001
        logger.warning("grayscale convert failed: %s", e)
        return data, content_type


_COVER_LEGACY = re.compile(r"^(series|library)-\d+\.bin(\.ct)?$")
_COVER_USER = re.compile(r"^u[0-9a-f]{16}-(series|library)-\d+\.bin(\.ct)?$")
_COVER_TMP_PREFIX = ".tmp-"
# Longest a browser may keep a cover before asking again. Kept short so a
# cover Kavita stops serving to a user (or replaces) doesn't linger on the
# device; a cached copy is also never kept past its server-side COVER_TTL.
_COVER_BROWSER_MAX_AGE = 3600


def _cover_cache_control(remaining: float | None) -> dict:
    """Cache-Control for a cover. remaining is how long the server-side entry
    stays valid, or None when the disk cache is off."""
    max_age = _COVER_BROWSER_MAX_AGE
    if remaining is not None:
        max_age = max(0, min(max_age, int(remaining)))
    return {"Cache-Control": f"private, max-age={max_age}"}


_PLACEHOLDER_GIF = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;"


def _cover_user_tag(session: Session) -> str | None:
    """Opaque per-user prefix for cover cache files. Keyed with the app
    secret so file names don't reveal usernames."""
    name = (session.username or "").strip().lower()
    if not name:
        return None
    digest = hmac.new(SECRET_KEY.encode(), b"cover-cache\0" + name.encode(), hashlib.sha256)
    return digest.hexdigest()[:16]


def _read_cover(path: str) -> tuple[bytes, str, float] | None:
    """(data, content type, age in seconds), or None if not cached."""
    try:
        with open(path, "rb") as f:
            data = f.read()
            age = time.time() - os.fstat(f.fileno()).st_mtime
        with open(path + ".ct", "r") as f:
            ctype = f.read().strip() or "image/jpeg"
    except OSError:
        return None
    return data, ctype, age


def _write_cover(path: str, data: bytes, ctype: str) -> None:
    """Write both files via temp file + rename, so a reader never sees a
    partial cover. The .ct goes first; the .bin's mtime is the entry's age."""
    try:
        for target, content in ((path + ".ct", ctype.encode()), (path, data)):
            fd, tmp = tempfile.mkstemp(dir=COVER_CACHE_DIR, prefix=_COVER_TMP_PREFIX)
            try:
                with os.fdopen(fd, "wb") as f:
                    f.write(content)
                os.chmod(tmp, 0o644)
                os.replace(tmp, target)
            except BaseException:
                with contextlib.suppress(OSError):
                    os.unlink(tmp)
                raise
    except Exception as e:  # noqa: BLE001
        logger.warning("cover cache write failed: %s", e)


def _remove_cover(path: str) -> None:
    for target in (path, path + ".ct"):
        with contextlib.suppress(OSError):
            os.unlink(target)


def _prune_cover_cache() -> int:
    """Delete cover files nobody can be served: the shared files from before
    0.7.19, per-user files past COVER_TTL (all of them when the cache is off)
    and temp files older than an hour. Only regular files whose names match
    exactly; never follows symlinks."""
    now = time.time()
    removed = 0
    try:
        entries = list(os.scandir(COVER_CACHE_DIR))
    except OSError as e:
        logger.warning("cover cache prune skipped: %s", e)
        return 0
    for entry in entries:
        try:
            if not entry.is_file(follow_symlinks=False):
                continue
            name = entry.name
            if _COVER_LEGACY.match(name):
                pass
            elif _COVER_USER.match(name):
                age = now - entry.stat(follow_symlinks=False).st_mtime
                if COVER_TTL and 0 <= age <= COVER_TTL:
                    continue
            elif name.startswith(_COVER_TMP_PREFIX):
                if now - entry.stat(follow_symlinks=False).st_mtime <= 3600:
                    continue
            else:
                continue
            os.unlink(entry.path)
            removed += 1
        except OSError:
            continue
    if removed:
        logger.info("cover cache: removed %d stale file(s)", removed)
    return removed


async def _serve_cover(
    *,
    cache_key: str,
    path: str,
    params: dict,
    session: Session,
) -> Response:
    """Fetch a cover image from Kavita, optionally convert to grayscale, and
    cache it on disk per user. A cache hit is only ever served to the user
    whose own Kavita request filled it, and only within COVER_TTL."""
    tag = _cover_user_tag(session) if COVER_TTL > 0 else None
    cached = os.path.join(COVER_CACHE_DIR, f"u{tag}-{cache_key}.bin") if tag else None
    expired = False
    if cached:
        hit = _read_cover(cached)
        if hit is not None:
            data, ctype, age = hit
            if 0 <= age <= COVER_TTL:
                return Response(
                    content=data,
                    media_type=ctype,
                    headers=_cover_cache_control(COVER_TTL - age),
                )
            expired = True

    r = await _kavita_request("GET", path, session=session, params=params)
    if r.status_code != 200:
        if expired:
            # Kavita no longer serves this cover to this user: forget it.
            _remove_cover(cached)
        # 1x1 transparent gif so the page still lays out. Not cached, so the
        # real cover shows as soon as Kavita serves it again.
        return Response(
            content=_PLACEHOLDER_GIF,
            media_type="image/gif",
            status_code=200,
            headers={"Cache-Control": "no-store"},
        )

    ctype = r.headers.get("content-type", "image/jpeg")
    data, ctype = _to_grayscale(r.content, ctype)
    if cached:
        _write_cover(cached, data, ctype)

    return Response(
        content=data,
        media_type=ctype,
        headers=_cover_cache_control(COVER_TTL if cached else None),
    )


async def _proxy_download(*, path: str, params: dict, session: Session) -> Response:
    """Stream a download through to the client, preserving filename/content-type."""
    if not session.is_authed:
        raise HTTPException(401, "not authed")
    upstream = await _kavita_request(
        "GET", path, session=session, params=params, stream=True
    )
    if upstream.status_code != 200:
        await upstream.aclose()
        raise HTTPException(upstream.status_code, "download failed")

    # Pull through useful response headers.
    passthrough = {}
    for h in ("content-type", "content-length", "content-disposition", "etag"):
        v = upstream.headers.get(h)
        if v:
            passthrough[h] = v
    # Force a download on older Android-based e-reader browsers (e.g. the
    # OBOOK6 stock browser) that won't infer it from the response body alone
    # when content-disposition is missing.
    if "content-disposition" not in passthrough:
        passthrough["content-disposition"] = 'attachment; filename="book"'

    async def body_iter():
        try:
            async for chunk in upstream.aiter_bytes():
                yield chunk
        finally:
            await upstream.aclose()

    return StreamingResponse(
        body_iter(),
        status_code=200,
        headers=passthrough,
        media_type=passthrough.get("content-type"),
    )


# ----- shutdown --------------------------------------------------------------


@app.on_event("startup")
async def _startup():
    if _tls_warning:
        logger.warning(_tls_warning)
    _prune_cover_cache()


@app.on_event("shutdown")
async def _shutdown():
    await _http.aclose()
