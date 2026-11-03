# kavita-epaper

A lightweight web UI for [Kavita](https://www.kavitareader.com/), tuned for e-ink readers and tablets. Reads EPUB only.

Kavita's built-in web reader works fine on desktops but is heavy on low-powered devices. Animated transitions, dark chrome surfaces, settings panels designed for mouse and keyboard. On e-ink readers like the OBOOK6 you get laggy navigation and bright UI elements that ghost across page turns. On tablets it works but is overkill if you just want to read.

kavita-epaper is a small FastAPI proxy that sits in front of your existing Kavita server. It uses Kavita's API for library, metadata, progress, and EPUB content. Only the front-end is replaced. Your Kavita install is still the source of truth, nothing is duplicated.

**EPUB only.** The built-in reader does not handle comics (CBZ, CBR, etc.) or PDFs. See [What this isn't](#what-this-isnt) below.

**A note on origins.** I'm not a programmer. Claude (Anthropic's AI) did the actual coding. I drove design decisions, on-device testing on a real OBOOK6, and the calls about what to ship. If you spot something questionable in the implementation, open an issue or PR. Honest criticism welcome.

## Tested on

Devices I've actually tested:

- **OBOOK6** (6" e-ink, ~375×500 CSS px portrait, Android-based). Primary target.
- **Samsung Galaxy Tab S10 FE.** Used as a PWA. Dark mode helps for night reading.
- **iPad (6th gen).** Used as a PWA via Safari.
- **Desktop browsers** (Chrome, Firefox, Safari). For admin and incidental reading. UI is tuned for small screens but doesn't break at desktop sizes.

If you try it on something else, open an issue with the device name and any quirks.

## Screenshots

<!-- TODO: capture screenshots and replace these placeholders.
     Recommended set:
       1. Library grid (light mode) on a phone or tablet
       2. Reader view with text (light mode)
       3. Settings panel open in the reader
       4. Reader view (dark mode)
       5. (Optional) Photo of the UI rendered on an actual e-reader (OBOOK6 or similar)
     Host them under docs/screenshots/ in the repo and reference like below. -->

| Library | Reader | Settings | Dark mode |
|---------|--------|----------|-----------|
| ![Library](docs/screenshots/library.png) | ![Reader](docs/screenshots/reader.png) | ![Settings](docs/screenshots/settings.png) | ![Dark mode](docs/screenshots/reader-dark.png) |

## Features

- **Single sign-in.** Kavita username and password are sent once. The JWT, refresh token and API key are held in an encrypted HTTP-only cookie. Browser scripts never touch them.
- **Library-first UI.** No dashboard, no homescreen. Open the PWA and you're in your books. Snap-scroll library tabs, cover grid, big tap targets.
- **Built-in EPUB reader.** Proxies Kavita's `book-page` API and wraps it in an e-ink-friendly shell. CSS multi-column pagination via native `scrollLeft`. Same approach as Kavita's web reader so no edge bleed.
- **Progress syncs with Kavita.** Tap a book, resume where you left off. Tracked per-user via Kavita's `/api/Reader/get-progress` and `/api/Reader/progress` endpoints. Open the same book in Kavita's web UI on another device and your position is there too.
- **Dark mode.** Per-device toggle in reader settings (⚙). Light by default. Single CSS variable swap so the whole UI flips consistently.
- **EPUB downloads.** ↓ button on any chapter streams the EPUB through the proxy. Useful for sideloading to NeoReader, Calibre, KOReader, etc.
- **Grayscale covers.** Pre-rendered with Pillow before serving. Cuts file size and renders cleanly on e-ink.

## Requirements

- A reachable Kavita instance (1.0+, needs `book-page` and `get-progress` endpoints).
- Debian or Ubuntu LXC/VM with `python3`, `python3-venv`, `systemd`, `rsync`.
- A reverse proxy with TLS (NPM, Caddy, Traefik, etc.) if you're exposing it past a trusted LAN.
- Optional: PWA-capable browser (Chrome, Edge, Safari) for install-to-homescreen.

> Upgrading from a previous release? See [`CHANGELOG.md`](./CHANGELOG.md) for version-specific notes.

## Install

Pick whichever fits how you got the code.

### Option A: latest release from GitHub (recommended)

```bash
# Resolve the latest release tarball URL via the GitHub API, download, extract, install
LATEST=$(curl -fsSL https://api.github.com/repos/coryjarboe/kavita-epaper/releases/latest \
  | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*kavita-epaper-v[0-9][^"]*\.tar\.gz"' \
  | head -1 | grep -oE 'https://[^"]+')
D=$(mktemp -d)
curl -fsSL "$LATEST" | tar -xzf - -C "$D"
cd "$D"
sudo bash ./deploy/install.sh
cd - >/dev/null && rm -rf "$D"
```

Pulls the latest tagged release. What most people want.

### Option B: clone the repo (gets latest `main`, may be ahead of releases)

Needs `git`.

```bash
git clone https://github.com/coryjarboe/kavita-epaper.git
cd kavita-epaper
sudo bash ./deploy/install.sh
```

Use this for the absolute latest, or if you plan to modify the code locally.

### Option C: from a tarball you already have

Run this from the directory that holds the tarball, or give the tarball's absolute path.

```bash
D=$(mktemp -d)
tar -xzf kavita-epaper-vX.Y.Z.tar.gz -C "$D"
cd "$D"
sudo bash ./deploy/install.sh
cd - >/dev/null && rm -rf "$D"
```

For offline installs, air-gapped environments, or pinning a specific version.

This creates:

- `/opt/kavita-epaper/` (code and venv)
- `/opt/kavita-epaper/.env` (config, auto-generated session secret, edit to point at your Kavita)
- `/var/cache/kavita-epaper/covers/` (grayscale cover cache)
- `/var/lib/kavita-epaper/releases/` (drop release tarballs here for no-args `update.sh`)
- `kavita-epaper` system user
- `kavita-epaper.service`

The defaults assume Kavita is on the same host. If Kavita is on a different machine, edit `KAVITA_BASE_URL` in `/opt/kavita-epaper/.env` to point at it (e.g. `http://10.0.0.50:5000`). Then:

```bash
sudo systemctl restart kavita-epaper
```

Check it's running:

```bash
systemctl status kavita-epaper
journalctl -u kavita-epaper -f
```

## Reverse proxy

Default bind is `0.0.0.0:8095` so the reverse proxy can live on a different host. Point a proxy host at `http://<kavita-epaper-host-ip>:8095`.

### NPM example

| Field                 | Value                              |
|-----------------------|------------------------------------|
| Domain                | `read.example.com` (or whatever)   |
| Scheme                | `http`                             |
| Forward host          | `<kavita-epaper host IP>`          |
| Forward port          | `8095`                             |
| Block common exploits | on                                 |
| Websockets            | off (not used)                     |
| SSL                   | whatever cert your proxy uses      |
| Force SSL             | on                                 |

Caddy and Traefik work the same way. Single HTTP upstream, no special headers needed past `X-Forwarded-Proto` (uvicorn runs with `--proxy-headers`). To accept those headers only from your proxy, see [Security](#security).

### If your reverse proxy is on the same host

Set `KAVITA_EPAPER_HOST=127.0.0.1` and `KAVITA_EPAPER_FORWARDED_ALLOW_IPS=127.0.0.1` in `/opt/kavita-epaper/.env` and restart. Limits exposure to localhost so the proxy is the only way in.

### Direct access without a reverse proxy

For a quick try, it works directly on its bound IP and port. Open `http://<host-ip>:8095` in a browser. The session cookie is issued without the `Secure` flag when accessed over plain HTTP (`KAVITA_EPAPER_COOKIE_SECURE=auto` does this by default), so login persists.

> **Security note.** kavita-epaper uses Kavita's own auth model. Your credentials are posted to Kavita on first sign-in over whatever transport you've configured. If you're comfortable accessing Kavita over plain HTTP on a trusted LAN, kavita-epaper sits at the same level. For anything internet-facing, put TLS in front of both, and see [Security](#security).

## Security

The defaults suit a trusted home LAN. For anything beyond that:

- **Trust only your proxy's forwarded headers** (`KAVITA_EPAPER_FORWARDED_ALLOW_IPS`).
  - The default `*` lets any client send `X-Forwarded-For` and `X-Forwarded-Proto`, so anyone who can reach the port can fake their logged IP and make plain HTTP look like HTTPS.
  - Set it in `.env` to your proxy's IP, e.g. `192.0.2.10`, or `127.0.0.1` for a proxy on the same host.
  - Several proxies: a comma-separated list, no spaces (`192.0.2.10,192.0.2.11`). CIDR ranges like `192.0.2.0/28` work too. IP addresses only, not hostnames.
  - Requests through a trusted proxy are logged with the real client IP (port `0`), and `KAVITA_EPAPER_COOKIE_SECURE=auto` sees the proxy's HTTPS. Anyone else is logged as they connect and their forwarded headers are ignored.
  - If the list misses your proxy, the logs show the proxy's IP and `auto` treats requests as plain HTTP, so the cookie loses its `Secure` flag.
- **Use HTTPS.** Put a TLS reverse proxy in front (see [Reverse proxy](#reverse-proxy)). Keep `KAVITA_EPAPER_COOKIE_SECURE` at `auto`, or `true` if you only ever use HTTPS (with `true`, sign-in won't stick over plain HTTP).
- **Don't expose the app port.**
  - Proxy on the same host: set `KAVITA_EPAPER_HOST=127.0.0.1`.
  - Proxy elsewhere: firewall port `8095` (`KAVITA_EPAPER_PORT`) to the proxy only, e.g. `sudo ufw allow from 192.0.2.10 to any port 8095 proto tcp` and no other rule for that port.
- **Use a long random secret.**
  - `install.sh` generates `KAVITA_EPAPER_SECRET`. To make one: `python3 -c 'import secrets; print(secrets.token_urlsafe(48))'`.
  - It encrypts session cookies and keys the cover cache. Changing it signs everyone out, and covers are fetched again.
  - To rotate without signing everyone out: move the current value to `KAVITA_EPAPER_SECRET_PREVIOUS`, set a new `KAVITA_EPAPER_SECRET`, restart. Old cookies are re-issued under the new secret the next time they open a page.
  - After `KAVITA_EPAPER_SESSION_TTL` (30 days by default), remove `KAVITA_EPAPER_SECRET_PREVIOUS` and restart. Anyone who hasn't opened a page since the rotation is signed out then.
- **Keep files root-owned.** `/opt/kavita-epaper/.env` stays `root:root` mode `600` (systemd reads it before switching to the service user), and `/opt/kavita-epaper` stays owned by root. `install.sh` and `update.sh` set both.
- **Update with `update.sh`.** It verifies the new unit, installs dependencies before stopping the service, resets ownership and the `.env` mode, and checks the service comes back up (see [Update](#update)).

## Update

Four ways:

```bash
# 1. Explicit tarball path
sudo /opt/kavita-epaper/update.sh /path/to/kavita-epaper-vX.Y.Z.tar.gz

# 2. URL (auto-downloads)
sudo /opt/kavita-epaper/update.sh https://my.server/kavita-epaper-vX.Y.Z.tar.gz

# 3. Auto-pick newest from a local release directory
sudo /opt/kavita-epaper/update.sh

# 4. Latest release from a GitHub repo
sudo /opt/kavita-epaper/update.sh --github coryjarboe/kavita-epaper
```

Mode 3 picks the highest-versioned `kavita-epaper-*.tar.gz` in `$KAVITA_EPAPER_RELEASES_DIR`. Defaults to `/var/lib/kavita-epaper/releases`. Adjust in `.env` if you drop tarballs somewhere else.

Mode 4 hits GitHub's `/releases/latest` API for the given `owner/repo`, finds the `kavita-epaper-v*.tar.gz` asset, and downloads it. Anonymous API access is rate-limited to 60 requests per hour per IP. For private repos or higher limits, export `GITHUB_TOKEN` and use `sudo -E`:

```bash
export GITHUB_TOKEN=ghp_...
sudo -E /opt/kavita-epaper/update.sh --github your-org/kavita-epaper
```

All four modes preserve `.env` and the cover cache, skip `pip install` when `requirements.txt` is unchanged (and otherwise run it before stopping the service, so a failed install leaves the old version running), install the release's service unit when it changed (see [Service unit](#service-unit)), and verify the service comes back up before exiting non-zero.

## Migration

One-time fixes for installs that predate the current `install.sh`. `update.sh` only replaces code; it never rewrites `.env` or creates directories, so older hosts keep whatever their original installer left behind.

### Upgrading from before 0.7.15

Older installers left `/opt/kavita-epaper` owned by the `kavita-epaper` service user, and the `update.sh` they installed executes `.env` as root. For this one upgrade, run the `update.sh` that ships in the new release, not the installed one. Run these from the directory that holds the tarball, or give the tarball's absolute path in both places:

```bash
D=$(mktemp -d)
tar -xzf kavita-epaper-vX.Y.Z.tar.gz -C "$D"
sudo bash "$D/deploy/update.sh" kavita-epaper-vX.Y.Z.tar.gz
rm -rf "$D"
```

It makes the install dir root-owned before reading anything in it, never executes `.env`, and replaces `/opt/kavita-epaper/update.sh` with itself. Don't use the installed `update.sh` for this upgrade: it finishes by handing `app/`, `requirements.txt` and `VERSION` back to the service user. After this, update as usual; from 0.7.15 on, `update.sh` hands off to the copy shipped in each new release by itself.

The service keeps working with a root-only `.env`, because systemd reads it as root before starting the service. If you suspect the service account was compromised, review `.env` for anything you didn't put there before upgrading.

### `.env` from before 0.7.11

Your `.env` was copied from an older template and won't pick up new settings on its own. Compare it with the current template:

```bash
diff /opt/kavita-epaper/.env deploy/env.example
```

(run from an extracted release or a clone). Things to look for:

- `KAVITA_PUBLIC_URL` is ignored since 0.7.11. Delete the line.
- `KAVITA_EPAPER_HOST` and `KAVITA_EPAPER_PORT` aren't listed. The defaults (`0.0.0.0`, `8095`) come from the service file, so you only need them to change the bind address or port.
- `KAVITA_EPAPER_COOKIE_SECURE` also accepts `auto` (the default), which sets the `Secure` flag only on HTTPS requests. Keep `true` if you only ever use HTTPS.
- Old comments may give the wrong default for `KAVITA_EPAPER_RELEASES_DIR`. The real default is `/var/lib/kavita-epaper/releases`.

Keep your existing `KAVITA_EPAPER_SECRET`. Changing it signs everyone out.

Restart after editing:

```bash
sudo systemctl restart kavita-epaper
```

### Missing releases directory

If `sudo /opt/kavita-epaper/update.sh` (no arguments) fails with `Releases dir does not exist`, your install predates the step that creates it. Either create it:

```bash
sudo mkdir -p /var/lib/kavita-epaper/releases
```

or point at the directory where you already keep tarballs by adding this to `.env`:

```
KAVITA_EPAPER_RELEASES_DIR=/path/to/your/tarballs
```

Passing a tarball path, URL or `--github` always works regardless.

### Moving from the old `kavita-boox` name

`update.sh` refuses to apply a `kavita-epaper` tarball to a `kavita-boox` install, because the paths, service name and user all changed. Do a fresh install instead, then remove the old one:

```bash
# both default to port 8095, so stop the old service first
sudo systemctl disable --now kavita-boox
sudo bash ./deploy/install.sh        # from an extracted kavita-epaper release
# copy KAVITA_BASE_URL and any other settings from /opt/kavita-boox/.env;
# variables were renamed from KAVITA_BOOX_* to KAVITA_EPAPER_*
sudo systemctl restart kavita-epaper
# once it works:
sudo rm -rf /opt/kavita-boox /var/cache/kavita-boox /etc/systemd/system/kavita-boox.service
sudo userdel kavita-boox
sudo systemctl daemon-reload
```

Users sign in again after the move, because the new install generates a new session secret.

## Config

`/opt/kavita-epaper/.env`. The ones you'll actually touch:

| Variable                     | Default                         | Notes                                                |
|------------------------------|---------------------------------|------------------------------------------------------|
| `KAVITA_BASE_URL`            | `http://127.0.0.1:5000`         | Kavita API address (server-to-server). Change if Kavita isn't local. |
| `KAVITA_EPAPER_HOST`         | `0.0.0.0`                       | Interface to bind. `127.0.0.1` is loopback only.     |
| `KAVITA_EPAPER_PORT`         | `8095`                          | TCP port to listen on.                               |
| `KAVITA_EPAPER_SECRET`       | auto-generated                  | Encrypts session cookies. Changing it signs everyone out; see below. |
| `KAVITA_EPAPER_SECRET_PREVIOUS` | unset                        | Old secret during a rotation; its cookies are still accepted. |
| `KAVITA_EPAPER_COOKIE_SECURE`| `auto`                          | `auto` follows request scheme. Or pin `true`/`false`.|
| `KAVITA_EPAPER_SESSION_TTL`  | `2592000` (30d)                 | Session lifetime in seconds.                         |
| `KAVITA_EPAPER_GRAYSCALE`    | `true`                          | Pre-render covers to grayscale. Disable for color.   |
| `KAVITA_EPAPER_COVER_TTL`    | `86400` (1 day)                 | Seconds a cached cover is served before refetching. `0` = no disk cache. Cached per user. |
| `KAVITA_EPAPER_FORWARDED_ALLOW_IPS` | `*`                      | Who may set `X-Forwarded-*` headers. Your proxy's IP, e.g. `192.0.2.10`; see [Security](#security). |
| `KAVITA_EPAPER_KEEPALIVE_SECONDS` | `0` (off)                  | Reader pings `/ping` this often while visible, for e-readers whose Wi-Fi drops between page loads. Try `25`. |
| `KAVITA_EPAPER_RELEASES_DIR` | `/var/lib/kavita-epaper/releases` | Where `update.sh` looks when called with no args.  |

Restart after changes:

```bash
sudo systemctl restart kavita-epaper
```

To rotate `KAVITA_EPAPER_SECRET` without signing everyone out, see [Security](#security).

### Service unit

`install.sh` and `update.sh` overwrite `/etc/systemd/system/kavita-epaper.service` whenever a release ships a changed one. `update.sh` checks the new unit with `systemd-analyze verify` first, saves the old one to `/var/backups/kavita-epaper.service.<timestamp>`, and puts it back if the service won't start. Edits made directly to the unit file are lost at that point, so put local changes in a drop-in, which updates never touch:

```bash
sudo systemctl edit kavita-epaper
```

This writes `/etc/systemd/system/kavita-epaper.service.d/override.conf`, for example:

```ini
[Service]
MemoryMax=256M
```

Settings the app reads (`KAVITA_*`) still belong in `.env`.

## Uninstall

```bash
sudo systemctl disable --now kavita-epaper
sudo rm -rf /opt/kavita-epaper /var/cache/kavita-epaper /var/lib/kavita-epaper /etc/systemd/system/kavita-epaper.service /etc/systemd/system/kavita-epaper.service.d
sudo userdel kavita-epaper
sudo systemctl daemon-reload
```

## What this isn't

- **Not a Kavita replacement.** A thin proxy and UI in front of Kavita. Kavita does the actual work (library scan, metadata, progress storage, EPUB parsing).
- **EPUB only.** The built-in reader handles EPUB. No support for comics (CBZ, CBR, CB7, CBT, ZIP, RAR, 7Z), PDF, or raw image folders. Library browse still works for those formats and the download button still streams the file, but the reader button is hidden for non-EPUB items. Read those in Kavita's own web reader, or download and open them in a dedicated app.
- **Not multi-user-aware in any special way.** Each browser session authenticates against Kavita and gets its own cookie. No user management here, it's all Kavita's user system.
- **No background sync, no offline reading.** Online only. The service worker is intentionally a network pass-through (no caching) so library changes show up immediately.

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
├── .env                  # config (root:root, chmod 600)
└── update.sh             # dropped in by install.sh
```

Listens on `0.0.0.0:8095` by default. Set `KAVITA_EPAPER_HOST=127.0.0.1` in `.env` for loopback-only when the reverse proxy is on the same host. Always front it with a TLS-terminating reverse proxy in production.

## License

MIT. See [`LICENSE`](./LICENSE).
