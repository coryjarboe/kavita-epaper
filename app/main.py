"""
kavita-epaper: minimal e-ink-friendly web UI for Kavita.

Sits alongside the official Kavita UI. Talks to Kavita's REST API.
Designed to be served behind a reverse proxy (e.g. nginx proxy manager).

All Kavita auth state (JWT + refresh token + apiKey) lives server-side
in a signed cookie session. The browser only ever sees an opaque session
cookie. EPUB downloads are streamed through this app.
"""

from __future__ import annotations

import io
import logging
import os
import secrets
import time
from typing import Any
from urllib.parse import quote

import httpx
from fastapi import Cookie, Depends, FastAPI, Form, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from itsdangerous import BadSignature, TimestampSigner
from itsdangerous import URLSafeSerializer

# ----- config ---------------------------------------------------------------

KAVITA_BASE_URL = os.environ.get("KAVITA_BASE_URL", "http://127.0.0.1:5000").rstrip("/")
SECRET_KEY = os.environ.get("KAVITA_EPAPER_SECRET", "")
COOKIE_NAME = os.environ.get("KAVITA_EPAPER_COOKIE", "kesess")
# Cookie 'Secure' attribute control. Tri-state:
#   "auto"  (default) — set Secure when the incoming request is HTTPS, omit
#                       it when HTTP. Lets the same install serve both a
#                       reverse-proxied HTTPS hostname AND direct plain-HTTP
#                       access by IP without the cookie silently failing.
#   "true"            — always set Secure. Pin this when you only ever access
#                       via HTTPS and want browsers to refuse the cookie over
#                       HTTP even by accident.
#   "false"           — never set Secure. Only useful for testing.
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
GRAYSCALE_COVERS = os.environ.get("KAVITA_EPAPER_GRAYSCALE", "true").lower() == "true"

if not SECRET_KEY:
    # Generate an ephemeral secret if not configured. This will invalidate
    # sessions on every restart, which is acceptable in dev but should be
    # configured in production.
    SECRET_KEY = secrets.token_urlsafe(48)
    logging.warning(
        "KAVITA_EPAPER_SECRET not set; using an ephemeral secret. "
        "Sessions will be invalidated on every restart."
    )

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

# Single shared httpx client. Long timeout for downloads.
_http = httpx.AsyncClient(
    base_url=KAVITA_BASE_URL,
    timeout=httpx.Timeout(connect=10.0, read=120.0, write=60.0, pool=10.0),
)

# Read the installed version (used for cache-busting static asset URLs).
try:
    _version_path = os.path.join(BASE_DIR, "..", "VERSION")
    with open(_version_path) as _f:
        APP_VERSION = _f.read().strip() or "dev"
except Exception:  # noqa: BLE001
    APP_VERSION = "dev"

templates.env.globals["APP_VERSION"] = APP_VERSION

_serializer = URLSafeSerializer(SECRET_KEY, salt="kavita-epaper-session")
_signer = TimestampSigner(SECRET_KEY)

logger = logging.getLogger("kavita-epaper")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")


# ----- session helpers -------------------------------------------------------


def _encode_session(data: dict) -> str:
    payload = _serializer.dumps(data)
    return _signer.sign(payload.encode()).decode()


def _decode_session(raw: str | None) -> dict | None:
    if not raw:
        return None
    try:
        payload = _signer.unsign(raw, max_age=SESSION_TTL).decode()
        return _serializer.loads(payload)
    except (BadSignature, Exception):
        return None


def _set_session_cookie(response: Response, data: dict, request: Request | None = None) -> None:
    # Resolve the Secure flag per-request. Uvicorn is launched with
    # --proxy-headers --forwarded-allow-ips '*', so request.url.scheme
    # already reflects X-Forwarded-Proto when a reverse proxy is in front;
    # for direct connections it reflects the actual transport.
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
        self.data = _decode_session(raw_cookie) or {}
        self.dirty = False

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
        return RedirectResponse(exc.headers["Location"], status_code=302)
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


@app.get("/login", response_class=HTMLResponse)
async def login_form(request: Request, error: str | None = None):
    return templates.TemplateResponse(
        "login.html", {"request": request, "error": error}
    )


@app.post("/login")
async def login_submit(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
):
    try:
        r = await _http.post(
            "/api/Account/login",
            json={"username": username, "password": password, "apiKey": ""},
            timeout=15.0,
        )
    except httpx.HTTPError as e:
        logger.warning("login network error: %s", e)
        return RedirectResponse(
            f"/login?error={quote('could not reach kavita')}", status_code=302
        )

    if r.status_code != 200:
        # Kavita returns 401 for bad creds.
        msg = "wrong username or password" if r.status_code == 401 else "login failed"
        return RedirectResponse(f"/login?error={quote(msg)}", status_code=302)

    user = r.json()
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

    # Paginate the chapter list — Obook6 viewport fits ~6 rows comfortably.
    ch_page_size = 6
    ch_start = (chapter_page - 1) * ch_page_size
    items = all_items[ch_start : ch_start + ch_page_size]
    ch_has_next = (ch_start + ch_page_size) < len(all_items)

    resp = templates.TemplateResponse(
        "series.html",
        {
            "request": request,
            "series": series,
            "detail": detail,
            "items": items,
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
    it in our e-ink chrome — no cross-origin navigation, stays in PWA scope."""
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

    # Best-effort progress save — don't fail the read if Kavita rejects it
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
    apiKey server-side and serves on our origin so book HTML stays same-origin."""
    r = await _kavita_request(
        "GET",
        f"/api/Book/{chapter_id}/book-resources",
        session=session,
        params={"file": file, "apiKey": session.api_key or ""},
    )
    if r.status_code != 200:
        raise HTTPException(r.status_code, "resource not found")
    return Response(
        content=r.content,
        media_type=r.headers.get("content-type", "application/octet-stream"),
        headers={"Cache-Control": "public, max-age=86400"},
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


@app.get("/sw.js")
async def service_worker():
    """Serve the service worker at root scope (required — SW scope is bounded
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
    requested page window — works whether or not the server honored it.
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
    # gave us the full list — we slice ourselves. Otherwise trust the server.
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
    With our default Accept header, Kavita returns JSON — a *string* like
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

    Matches any /api/Book/<id>/book-resources URL (not just the current
    chapter's — Kavita sometimes references resources from other chapters in
    the same book). Captures the chapter id and preserves it in the rewrite.
    Case-insensitive. Leaves the query string (?file=X&apiKey=Y) intact.
    """
    import re

    pattern = re.compile(
        r"/api/Book/(\d+)/book-resources", re.IGNORECASE
    )
    return pattern.sub(r"/read-resource/\1", html)


async def _serve_cover(
    *,
    cache_key: str,
    path: str,
    params: dict,
    session: Session,
) -> Response:
    """Fetch a cover image from Kavita, optionally convert to grayscale, and
    cache it on disk."""
    cached = os.path.join(COVER_CACHE_DIR, f"{cache_key}.bin")
    cached_meta = cached + ".ct"
    if os.path.exists(cached) and os.path.exists(cached_meta):
        try:
            with open(cached, "rb") as f:
                data = f.read()
            with open(cached_meta, "r") as f:
                ctype = f.read().strip() or "image/jpeg"
            return Response(
                content=data,
                media_type=ctype,
                headers={"Cache-Control": "public, max-age=86400"},
            )
        except Exception:  # noqa: BLE001
            pass

    r = await _kavita_request("GET", path, session=session, params=params)
    if r.status_code != 200:
        # 1x1 transparent gif so the page still lays out.
        return Response(
            content=b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;",
            media_type="image/gif",
            status_code=200,
        )

    ctype = r.headers.get("content-type", "image/jpeg")
    data = r.content

    if GRAYSCALE_COVERS and HAS_PIL and ctype.startswith("image/"):
        try:
            img = Image.open(io.BytesIO(data))
            img = img.convert("L")  # 8-bit grayscale
            buf = io.BytesIO()
            img.save(buf, format="JPEG", quality=78, optimize=True)
            data = buf.getvalue()
            ctype = "image/jpeg"
        except Exception as e:  # noqa: BLE001
            logger.warning("grayscale convert failed for %s: %s", cache_key, e)

    try:
        with open(cached, "wb") as f:
            f.write(data)
        with open(cached_meta, "w") as f:
            f.write(ctype)
    except Exception as e:  # noqa: BLE001
        logger.warning("cover cache write failed: %s", e)

    return Response(
        content=data,
        media_type=ctype,
        headers={"Cache-Control": "public, max-age=86400"},
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


@app.on_event("shutdown")
async def _shutdown():
    await _http.aclose()
