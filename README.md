# kavita-epaper

A lightweight, e-ink-friendly alternative web UI for [Kavita](https://www.kavitareader.com/).

Kavita's built-in web reader is great on desktops but heavy on low-powered
devices — animated transitions, dark chrome surfaces, settings panels designed
for mouse-and-keyboard. On e-ink readers like the OBOOK6 the result is
laggy navigation and bright UI elements that ghost across page turns. On
tablets it works fine but feels like overkill for "I just want to read a
book."

kavita-epaper is a thin proxy + PWA in front of your existing Kavita server.
It speaks Kavita's API for everything that matters (library, metadata,
progress, EPUB content) and replaces only the front-end with something
designed from the start for small screens, slow refresh rates, and big
tap targets. Light by default, with a dark mode toggle. Your existing
Kavita installation continues to be the source of truth — nothing is
duplicated, nothing is migrated.

**A note on origins.** I'm not a programmer. Claude (Anthropic's AI) did
the actual coding work here — I drove the design decisions, on-device
testing on a real OBOOK6, and the architectural calls about what
should and shouldn't ship. If you're a programmer and you spot something
questionable in the implementation, please open an issue or pull request.
Honest criticism is welcome and useful.

## Tested on

Hands-on testing has been done on the following devices:

- **OBOOK6** (6" e-ink, ~375×500 CSS px portrait, Android-based).
  Primary target device.
- **Samsung Galaxy Tab S10 FE.** Used as a PWA; dark mode useful for
  nighttime reading.
- **iPad (6th generation).** Used as a PWA via Safari.
- **Desktop browsers** (Chrome, Firefox, Safari). For administration
  and incidental reading; the UI is tuned for small screens but
  doesn't break at desktop sizes.

Other devices will likely work too — if you try it on something else
and it works (or doesn't), open an issue with the device name and any
quirks you hit.

## Screenshots

<!-- TODO: capture screenshots and replace these placeholders.
     Recommended set:
       1. Library grid (light mode) on a phone or tablet
       2. Reader view with text (light mode)
       3. Reader view (dark mode)
       4. Settings panel open in the reader
       5. (Optional) Photo of the UI rendered on an actual e-reader (OBOOK6 or similar)
     Host them under docs/screenshots/ in the repo and reference like below. -->

| Library | Reader | Dark mode |
|---------|--------|-----------|
| ![Library](docs/screenshots/library.png) | ![Reader](docs/screenshots/reader.png) | ![Dark mode](docs/screenshots/reader-dark.png) |

## Features

- **Sign in once.** Kavita username/password → JWT lives in a signed HTTP-only
  cookie on the server. Browser never touches the token.
- **Library-first UI.** No dashboard, no homescreen. Open the PWA, you're in
  your books. Snap-scroll library tabs, cover grid, big tap targets.
- **Built-in EPUB reader.** Proxies Kavita's `book-page` API and wraps it in
  an e-ink-friendly shell. CSS multi-column pagination driven by native
  `scrollLeft` (same approach as Kavita's web reader — no edge bleed).
- **Progress syncs with Kavita.** Tap a book → resumes where you left off,
  tracked per-user via Kavita's `/api/Reader/get-progress` and `/api/Reader/progress`
  endpoints. Open the same book in Kavita's web UI on another device, your
  position is there too.
- **Dark mode.** Per-device toggle in the reader settings (⚙). Light by
  default; flipped via a single CSS variable swap so the entire UI changes
  consistently.
- **EPUB downloads.** "↓" button on any chapter streams the EPUB through the
  proxy — useful if you want to sideload to NeoReader / Calibre / KOReader.
- **Grayscale covers.** Pre-rendered with Pillow before serving — cuts file
  size and renders cleanly on e-ink.

## Requirements

- A reachable Kavita instance (1.0+, anything with `book-page` and
  `get-progress` endpoints).
- Debian/Ubuntu LXC or VM with `python3`, `python3-venv`, `systemd`, `rsync`.
- A reverse proxy with TLS (NPM, Caddy, Traefik — whatever you already run).
- Optional: PWA-capable browser on the client side (Chrome/Edge/Safari) for
  the install-to-homescreen experience.

> Upgrading from a previous release? See [`CHANGELOG.md`](./CHANGELOG.md)
> for version-specific notes, including the rename from `kavita-boox` and
> the 0.7.1 → 0.7.2 systemd unit change.

## Install

```bash
mkdir -p /tmp/kavita-epaper
tar -xzf kavita-epaper-vX.Y.Z.tar.gz -C /tmp/kavita-epaper
cd /tmp/kavita-epaper
sudo ./deploy/install.sh
```

This creates:

- `/opt/kavita-epaper/` — code + venv
- `/opt/kavita-epaper/.env` — config (auto-generated session secret, edit to
  point at your Kavita)
- `/opt/kavita-epaper/update.sh` — for future updates (see below)
- `/var/cache/kavita-epaper/covers/` — grayscale cover cache
- `kavita-epaper` system user
- `kavita-epaper.service` — listens on `127.0.0.1:8095`

Edit `/opt/kavita-epaper/.env` to set `KAVITA_BASE_URL` and `KAVITA_PUBLIC_URL`
if Kavita isn't on `127.0.0.1:5000`, then:

```bash
sudo systemctl restart kavita-epaper
```

Check it's running:

```bash
systemctl status kavita-epaper
journalctl -u kavita-epaper -f
```

## Reverse proxy

By default the service binds to `0.0.0.0:8095` (all interfaces), so your
reverse proxy can live on a different host. Add a proxy host pointing to
`http://<kavita-epaper-host-ip>:8095`.

### NPM example

| Field                 | Value                              |
|-----------------------|------------------------------------|
| Domain                | `read.example.com` (or whatever)       |
| Scheme                | `http`                             |
| Forward host          | `<kavita-epaper host IP>`          |
| Forward port          | `8095`                             |
| Block common exploits | on                                 |
| Websockets            | off (not used)                     |
| SSL                   | whatever cert your proxy uses     |
| Force SSL             | on                                 |

Caddy/Traefik are the same shape — single HTTP upstream, no special
headers needed beyond `X-Forwarded-Proto` (uvicorn is launched with
`--proxy-headers --forwarded-allow-ips '*'`).

### If your reverse proxy is on the same host

Set `KAVITA_EPAPER_HOST=127.0.0.1` in `/opt/kavita-epaper/.env` and
restart the service — that limits exposure to localhost so the only path
to the app is via the proxy.

### Direct access without a reverse proxy

For a quick try, kavita-epaper works directly on its bound IP and port —
just open `http://<host-ip>:8095` in a browser. The session cookie is
issued without the `Secure` flag when accessed over plain HTTP (this is
what `KAVITA_EPAPER_COOKIE_SECURE=auto` does by default), so login
persists correctly.

> **Security note.** kavita-epaper inherits Kavita's own auth model: your
> credentials are posted to your Kavita server on first sign-in, over
> whatever transport you've configured. If you're already comfortable
> accessing Kavita over plain HTTP on a trusted LAN, kavita-epaper sits
> at the same security level. For anything internet-facing, put TLS in
> front of both.

## Update

Four ways to invoke `update.sh`:

```bash
# 1. Explicit tarball path
sudo /opt/kavita-epaper/update.sh /path/to/kavita-epaper-vX.Y.Z.tar.gz

# 2. URL (auto-downloads)
sudo /opt/kavita-epaper/update.sh https://my.server/kavita-epaper-vX.Y.Z.tar.gz

# 3. Auto-pick newest from a release directory
sudo /opt/kavita-epaper/update.sh

# 4. Latest release from a GitHub repo
sudo /opt/kavita-epaper/update.sh --github youruser/kavita-epaper
```

For (3), the script picks the highest-versioned `kavita-epaper-*.tar.gz`
in `$KAVITA_EPAPER_RELEASES_DIR` (defaults to `/var/lib/kavita-epaper/releases` if
unset — adjust in `.env` to wherever you actually drop release tarballs).

For (4), the script hits GitHub's `/releases/latest` API for the given
`owner/repo`, finds the attached `kavita-epaper-v*.tar.gz` asset, and
downloads it. Anonymous API access is rate-limited to 60 requests per
hour per IP. For private repos or higher limits, export `GITHUB_TOKEN`
and use `sudo -E`:

```bash
export GITHUB_TOKEN=ghp_...
sudo -E /opt/kavita-epaper/update.sh --github your-org/kavita-epaper
```

All four modes preserve `.env` and the cover cache, skip `pip install`
when `requirements.txt` is unchanged, and verify the service comes back
up before exiting non-zero.

## Config

`/opt/kavita-epaper/.env`. The ones you'll actually touch:

| Variable                     | Default                         | Notes                                                |
|------------------------------|---------------------------------|------------------------------------------------------|
| `KAVITA_BASE_URL`            | `http://127.0.0.1:5000`         | Where the Kavita API lives (server-to-server).       |
| `KAVITA_PUBLIC_URL`          | `https://kavita.example.com`        | URL the browser uses for "Open in Kavita" links.     |
| `KAVITA_EPAPER_HOST`         | `0.0.0.0`                       | Interface to bind. `127.0.0.1` = loopback only.      |
| `KAVITA_EPAPER_PORT`         | `8095`                          | TCP port to listen on.                               |
| `KAVITA_EPAPER_SECRET`       | auto-generated                  | Signs session cookies. Don't change after install.   |
| `KAVITA_EPAPER_COOKIE_SECURE`| `auto`                          | `auto` follows request scheme. Or pin `true`/`false`.|
| `KAVITA_EPAPER_SESSION_TTL`  | `2592000` (30d)                 | Session lifetime in seconds.                         |
| `KAVITA_EPAPER_GRAYSCALE`    | `true`                          | Pre-render covers to grayscale. Disable for color.   |
| `KAVITA_EPAPER_RELEASES_DIR` | `/var/lib/kavita-epaper/releases`           | Where `update.sh` looks when called with no args.    |

Restart the service after changes:

```bash
sudo systemctl restart kavita-epaper
```

## Uninstall

```bash
sudo systemctl disable --now kavita-epaper
sudo rm -rf /opt/kavita-epaper /var/cache/kavita-epaper /var/lib/kavita-epaper /etc/systemd/system/kavita-epaper.service
sudo userdel kavita-epaper
sudo systemctl daemon-reload
```

## What this isn't

- **Not a Kavita replacement.** It's a thin proxy/UI in front of Kavita —
  Kavita does all the heavy lifting (library scan, metadata, progress
  storage, EPUB parsing).
- **Not multi-user-aware in any special way.** Each browser session
  authenticates against Kavita and gets its own cookie. There's no
  user-management UI here — it's all Kavita's user system.
- **No background sync, no offline reading.** Online-only. The service
  worker is intentionally a network pass-through (no caching) so library
  changes show up immediately.

## File layout

```
/opt/kavita-epaper/
├── app/                  # FastAPI app
│   ├── main.py
│   ├── static/           # CSS, JS, icons, manifest
│   └── templates/        # Jinja2 (base, library, series, read, login)
├── venv/                 # Python virtualenv
├── requirements.txt
├── VERSION
├── .env                  # config (chmod 600)
└── update.sh             # dropped in by install.sh
```

Listens on `0.0.0.0:8095` by default. Set `KAVITA_EPAPER_HOST=127.0.0.1`
in `.env` to bind loopback-only when your reverse proxy is on the same
host. Always front it with a TLS-terminating reverse proxy in production.

## License

MIT. See [`LICENSE`](./LICENSE).
