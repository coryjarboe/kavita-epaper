# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with
upgrade notes called out where they require manual steps.

## [0.7.21] - clearer sign-in errors, required session secret

### Changed
- Sign-in errors say what went wrong and where to fix it:
  - Kavita unreachable: "Couldn't reach Kavita at <url>: <reason>", where
    the reason is connection refused, host name not found, TLS
    certificate not trusted, no answer, or too slow, plus a pointer to
    `KAVITA_BASE_URL` in `.env`. The URL is shown without any user info,
    query or fragment.
  - Something other than Kavita at that address (an HTML page, a 404,
    a reply without a token): "That doesn't look like Kavita at <url>",
    instead of an Internal Server Error or a bare "login failed".
  - Kavita refuses the sign-in (400 or 401): Kavita's own message is
    shown ("Kavita said: ..."), unless it looks like a token or contains
    the password, in which case "Wrong username or password." is shown.
  - Kavita answers with an error (for example 500): its status code.
- The Kavita URL, the reason and the `.env` path are shown only to
  clients with private or loopback addresses (10/8, 172.16/12,
  192.168/16, 127/8, ::1, fc00::/7, fe80::/10), as resolved through
  trusted proxies. Everyone else sees "Can't reach the Kavita server.
  Check the server logs." The log always has the full URL (without
  user info or query).
- The login page builds these messages from a short error code in the
  link, so a crafted link can no longer put arbitrary text there.
- Connecting to Kavita gives up after 5 seconds (was 10, and 15 for
  sign-in), so a wrong or unreachable address fails quickly.
- The log line for a failed sign-in names the Kavita URL, the reason and
  the error type (for example `timeout (ConnectTimeout <- TimeoutError)`).

### Security
- kavita-epaper refuses to start if `KAVITA_EPAPER_SECRET` is missing,
  is the `env.example` placeholder, or is shorter than 32 characters,
  and says how to generate one. It used to fall back to a random secret
  (signing everyone out at every restart) and silently accepted the
  placeholder. The service exits with status 78, and the unit's new
  `RestartPreventExitStatus=78` stops systemd from retrying.
  `KAVITA_EPAPER_SECRET_PREVIOUS` is not checked, since during a
  rotation it is the old secret.
- `update.sh` checks the secret before stopping the service. If it would
  be refused, the update stops with the current version still running
  and explains how to fix it. Only the length is checked; the value is
  never printed. A secret set in a unit drop-in also counts.

### Notes
- Installs made with `install.sh` already have a 64-character secret and
  need nothing. If you wrote `.env` by hand with a short secret, set a
  new one first (this signs everyone out once): `update.sh` tells you.
- `tests/test_login_errors.py` covers each sign-in error, who sees the
  Kavita URL (including through a trusted proxy and a faked
  `X-Forwarded-For`), and the secret check; the `update.sh` harness has
  secret scenarios. Kavita's refusal format was checked against a real
  Kavita with one sign-in for a nonexistent user.

## [0.7.20] - shorter browser cover cache, quieter update.sh

### Changed
- Browsers now keep a cover for at most an hour (`Cache-Control:
  private, max-age=3600`, previously a day), and never past the time
  the server's own cache entry has left under `KAVITA_EPAPER_COVER_TTL`.
  A cover Kavita stops serving to a user, or replaces, no longer lingers
  on that device for up to a day.
- The blank placeholder served for a cover Kavita refuses is sent with
  `Cache-Control: no-store`, so the real cover shows as soon as Kavita
  serves it again.
- `update.sh` runs pip with `--disable-pip-version-check`, so updates no
  longer print pip's "new release available" notice.

## [0.7.19] - encrypted session cookie, per-user cover cache, trusted proxy

### Security
- The session cookie is now encrypted, not just signed. It holds the
  user's Kavita JWT, refresh token and API key, which anyone with a copy
  of the cookie could previously read by base64-decoding it. It now uses
  Fernet (AES-128-CBC with HMAC-SHA256) from the `cryptography` package,
  with the key derived from `KAVITA_EPAPER_SECRET` by HKDF-SHA256. The
  optional `KAVITA_EPAPER_SECRET_PREVIOUS` lets you rotate the secret
  without signing everyone out. `itsdangerous` is no longer used.
- Covers are cached per user. A cached cover used to be served to any
  signed-in user without asking Kavita, so a cache hit could show a cover
  Kavita would refuse that user. Each user's entries now come only from
  their own Kavita requests, and file names use an HMAC of the username.
  Entries expire after `KAVITA_EPAPER_COVER_TTL` seconds (default 86400,
  `0` turns the disk cache off). When Kavita refuses an expired cover, the
  entry is deleted and a blank placeholder is served. Cache writes are
  atomic.
- The service unit takes uvicorn's `--forwarded-allow-ips` from
  `KAVITA_EPAPER_FORWARDED_ALLOW_IPS`. The default stays `*`, so home
  installs work unchanged; set it to your reverse proxy's address (for
  example `192.0.2.10`) so other clients can't fake their IP or the
  request scheme with `X-Forwarded-*` headers.
- New README "Security" section on hardening beyond a trusted home LAN:
  trusted proxy IPs, HTTPS and `KAVITA_EPAPER_COOKIE_SECURE`, not
  exposing the app port, the secret and its rotation, file ownership,
  and updating with `update.sh`.

### Changed
- `update.sh` installs changed Python dependencies before stopping the
  service. If `pip` fails, it exits non-zero with the previous version
  still running. Previously it stopped the service first, so a failed
  install left it down.
- Developer tests now live in `tests/` (a fake Kavita, app and proxy
  tests on scratch ports, and an `update.sh` harness); see
  `tests/README.md`. They are not part of the release tarball.

### Notes
- Everyone must sign in again after this update: cookies from earlier
  versions can't be decrypted. They are treated as signed out (a redirect
  to the login page that also deletes the old cookie, never an error).
- The cover cache rebuilds. The first start removes the old shared cover
  files, and covers are fetched again from Kavita as they are viewed.
- This release adds `cryptography` to `requirements.txt`, so `update.sh`
  needs to reach PyPI. Run the tarball's `update.sh` or the installed one;
  both install the dependency before stopping the service.

## [0.7.18] - optional reader keepalive

### Added
- `KAVITA_EPAPER_KEEPALIVE_SECONDS` (default `0`, off). When set, an open
  reader page requests `/ping` this often while it is visible, pauses
  while hidden, and pings once on becoming visible again. It is meant for
  e-readers whose Wi-Fi sleeps between page loads and gets dropped by the
  access point as idle. Values are clamped to 10..300; `25` is a good
  start. Each ping wakes the radio, so it costs some battery.
- `GET /ping` returns `204 No Content`. It takes no session, never reads
  or sets the cookie and never calls Kavita. Its requests are left out of
  the access log.

### Notes
- Nothing changes until you set the variable in
  `/opt/kavita-epaper/.env` and restart the service.

## [0.7.17] - fix reader left-edge clipping

### Fixed
- The reader cut off the first letters of each line further into a page.
  It stepped between screens by the column width rounded to a whole
  pixel, while the browser lays columns out at the fractional width, so
  each page turn landed up to 0.5px off and the error added up (about
  6px by screen 14). The step now uses the fractional width and each
  scroll position is rounded once from the screen number, so the error
  stays under 0.5px.

### Docs
- The README's Install (Options A and C) and Migration blocks now remove
  the `mktemp -d` directory after use.

## [0.7.16] - keep Kavita apiKeys out of logs and the browser

### Security
- httpx logged every Kavita request URL at INFO, and the cover and
  book-resource endpoints take the apiKey as a query parameter, so live
  keys went to the journal. The httpx logger is now at WARNING.
- Kavita's book page HTML embeds the user's apiKey in every resource URL,
  and the reader passed it through to the browser, where it sat in the
  DOM and in uvicorn's access log on every image load. `/read-resource`
  adds the key server-side, so the reader now strips it from the page.
- Covers and book resources were sent with `Cache-Control: public`, which
  lets a shared cache (for example a caching reverse proxy) serve them
  without a login. They are now `private`.
- The service unit sets `InaccessiblePaths=-/opt/kavita`, so the service
  user can't read a local Kavita install's database (which holds every
  user's auth keys). kavita-epaper only talks to Kavita over HTTP. The
  leading `-` skips the path when Kavita lives elsewhere.

### Changed
- `update.sh` now installs the release's service unit when it differs
  from the installed one. It runs `systemd-analyze verify` on the new unit
  before stopping anything (and refuses any warning about it), saves the
  old unit to `/var/backups/kavita-epaper.service.<timestamp>`, and puts
  it back and exits non-zero if the service doesn't come up. Previously
  only `install.sh` installed the unit, so unit changes never reached
  existing installs.

### Notes
- Local changes made directly to
  `/etc/systemd/system/kavita-epaper.service` are overwritten when a
  release changes the unit. Move them to a drop-in
  (`sudo systemctl edit kavita-epaper`, which writes
  `kavita-epaper.service.d/override.conf`); see README, "Service unit".
- Upgrading from 0.7.15 installed before the `update.sh` handoff existed:
  run `deploy/update.sh` from the extracted tarball, as in README,
  "Migration", so this release's unit step runs.
- Keys already written to the journal stay there. Regenerate the Kavita
  auth keys of every user who used kavita-epaper before this release.
  The session cookie keeps the key from sign-in, so after regenerating,
  sign out of kavita-epaper and back in to pick up the new key.

## [0.7.15] - root-owned install dir

### Security
- `install.sh` left `/opt/kavita-epaper` (including `.env`, `update.sh`
  and `venv/`) owned by the `kavita-epaper` service user. `update.sh` runs
  as root, sources `.env` and runs `venv/bin/pip`, so anyone with code
  execution as the service user could get root the next time an admin
  ran an update. The install dir is now `root:root` and not group/world
  writable, and `.env` is `root:root 600`. The service still reads its
  config, because systemd loads `EnvironmentFile=` as root before
  dropping privileges.
- `update.sh` no longer sources `.env`. It reads
  `KAVITA_EPAPER_RELEASES_DIR` with a plain text match, so nothing in
  `.env` is ever executed.
- `update.sh` re-applies the ownership on every run, so existing installs
  are corrected by their next update.

### Changed
- `update.sh` hands off to the `update.sh` inside the tarball when the two
  differ, so a release's own install steps always apply to its install.
  Previously the outgoing release's script ran the whole update.

### Notes
- The `update.sh` already installed on a pre-0.7.15 host predates the
  handoff, sources `.env`, and chowns `app/` back to the service user. For
  this upgrade run `deploy/update.sh` from the extracted tarball instead;
  see README, "Migration".

## [0.7.14] - fix EPUB image rendering

### Fixed
- Images embedded in EPUBs (illustrations, diagrams, chapter art) showed
  as broken-image icons in the reader. Kavita's BookService emits
  resource URLs as `//{host}{pathbase}/api/book/{id}/book-resources?file=...`
  (protocol-relative, includes the host). The previous URL-rewriting
  regex only matched `/api/Book/{id}/book-resources` as a path,
  leaving the `//host` prefix intact. Result: the browser made the
  request against the Kavita host directly with no valid apiKey and
  got a 401/404, rendering as a broken image. The regex now strips
  the full host-prefixed URL so resources load from kavita-epaper's
  own `/read-resource/{id}` endpoint.

### Notes
- Affects every EPUB with embedded images. Verified against eight
  representative URL patterns including subpath-deployed Kavita
  instances and CSS `background: url(...)` references.
- Pure app code change. `update.sh` is sufficient to apply.

## [0.7.13] - EPUB-only scope made explicit

### Added
- Reader button (▶) on series detail is now only shown for EPUB items.
  For comics, PDFs, raw images, and any other Kavita-supported format,
  only the download button (↓) is shown. Library browse still works for
  all formats. Decided not to build a manga/comic reader inside
  kavita-epaper: Kavita already has a polished one, duplicating it for
  a Boox-class device that handles manga poorly isn't worth the code.

### Changed
- README rewritten for voice and clarity. EPUB-only scope is now
  documented up front and in "What this isn't" rather than implied.

## [0.7.12] - fix silent failure in `update.sh --github`

### Fixed
- `update.sh --github` could exit silently with no error message if the
  release lookup didn't find a matching asset. Root cause: the pipeline
  inside the `SOURCE=$(...)` assignment returned non-zero (grep finds
  no match), which under `set -euo pipefail` killed the script before
  the "no asset found" check could fire. Added `|| true` so the empty
  string falls into the proper check.

### Notes
- This was the bug behind reports of `update.sh --github coryjarboe/...`
  returning to the prompt immediately after "querying ..." with no
  output.
- Pure shell fix. Safe to apply via `update.sh` itself once you've
  worked around the bug to update.

## [0.7.11] - remove unused KAVITA_PUBLIC_URL

### Removed
- `KAVITA_PUBLIC_URL` env var. It was defined and the `reader_url` helper
  in `main.py` constructed "Open in Kavita" links from it, but no
  template actually rendered those links. Dead config. Removed
  alongside the `reader_url` helper and the `_reader_kind_for_format`
  function that only the helper called.
- Corresponding entry from `env.example` and the README config table.

### Changed
- Install-section note updated: only `KAVITA_BASE_URL` is documented as
  user-configurable now.

### Notes
- Pure code reduction. `update.sh` is sufficient to apply.
- If you'd set `KAVITA_PUBLIC_URL=...` in your `.env`, it's now ignored.
  Safe to remove from `.env` to keep things clean.
- If you eventually want "Open in Kavita" links in series view, that's a
  feature to re-add deliberately, with the variable re-introduced for a
  real purpose.

## [0.7.10] - fix incorrect device attribution

### Fixed
- Multiple places throughout the README, CHANGELOG, and inline code
  comments mistakenly referred to the test device as an "Onyx Boox";
  the actual primary test device is the OBOOK6, an unrelated
  Android-based e-reader brand. Corrected throughout. The original
  project name (`kavita-boox`) was a misnomer for the same reason;
  this is what motivated the v0.7.0 rename. The CHANGELOG entry for
  v0.7.0 now explains this.

### Changed
- `LICENSE` copyright holder updated to "Cory Jarboe".

No code-behavior changes.

## [0.7.9] - document tested devices

### Changed
- README gains a "Tested on" section listing devices the project has
  been verified on: OBOOK6, Samsung Galaxy Tab S10 FE, iPad (6th
  gen), and desktop browsers.

No code changes.

## [0.7.8] - generalized defaults for public release

### Changed
- Default `KAVITA_EPAPER_RELEASES_DIR` moved from the media share
  (author's homelab path) to `/var/lib/kavita-epaper/releases` (FHS
  standard for service-owned mutable data). `install.sh` now creates
  this directory automatically.
- Example URLs in the README, env template, and reverse-proxy docs use
  RFC 2606 reserved domains (`example.com`) instead of author-specific
  hostnames.
- README install/upgrade instructions no longer assume a specific LXC
  layout; works on any Debian-family host with systemd.

### Upgrade notes (0.7.7 → 0.7.8)

If you'd been using the old default (the media share) without
setting `KAVITA_EPAPER_RELEASES_DIR` in `.env`, the no-args `update.sh`
will now look at `/var/lib/kavita-epaper/releases` instead. To keep the
old behavior, set `KAVITA_EPAPER_RELEASES_DIR` to the media share in
`/opt/kavita-epaper/.env`.

To pick up the new install.sh dir-creation behavior, re-run the
installer once:

```bash
mkdir -p /tmp/kavita-epaper && tar -xzf kavita-epaper-v0.7.8.tar.gz -C /tmp/kavita-epaper
cd /tmp/kavita-epaper && sudo ./deploy/install.sh
```

(Idempotent, preserves `.env` and the cover cache.)

## [0.7.7] - `update.sh --github` mode

### Added
- `update.sh --github <owner>/<repo>` resolves the latest published
  release on GitHub via the public API and downloads the attached
  `kavita-epaper-v*.tar.gz` asset. No external dependencies (uses
  grep-based JSON parsing). Optional `GITHUB_TOKEN` env var for private
  repos and higher rate limits.

No code changes outside `update.sh`. Safe to apply via `update.sh`
itself.

## [0.7.6] - direct-access README rewrite

### Changed
- The "Direct access without a reverse proxy" warning rewritten for
  accuracy. The prior text overstated the risk relative to Kavita's own
  threat model. kavita-epaper's auth flow is identical to Kavita's
  native flow: credentials hit Kavita over whatever transport is
  configured. If plain-HTTP Kavita on a trusted LAN is fine, plain-HTTP
  kavita-epaper on the same LAN is also fine.

No code changes.

## [0.7.5] - direct-IP access works out of the box

### Changed
- `KAVITA_EPAPER_COOKIE_SECURE` is now tri-state. New default is `auto`,
  which sets the cookie's `Secure` flag dynamically based on the request
  scheme (HTTPS → Secure; HTTP → not Secure). Pin to `true` or `false` to
  override.

### Fixed
- Direct access via `http://<host-ip>:8095` previously logged the user in
  but the session never persisted, because the `Secure` cookie was
  silently dropped by browsers over plain HTTP. With the `auto` default
  this just works, with no env tweak needed for first-try usage.

### Notes
- If you'd hardcoded `KAVITA_EPAPER_COOKIE_SECURE=true` in `.env`, leave
  it; behavior is unchanged. If you want the new auto behavior, set it to
  `auto` (or remove the line and let it default).
- Pure `app/` change: `update.sh` is sufficient. No installer re-run
  needed.

## [0.7.4] - polish for public release

### Added
- `LICENSE` (MIT).
- README intro paragraph explaining what this project is and why it exists.
- README screenshot section (placeholders; replace with real captures).
- `CHANGELOG.md` (this file); migration and upgrade notes moved here from
  the README.

### Changed
- README pruned of stale per-version upgrade sections that were noise for
  new users.

No code changes. Safe to apply via `update.sh`; no service file changes,
no migration required.

## [0.7.2] - env-driven host/port + cross-project update guard

### Added
- `KAVITA_EPAPER_HOST` and `KAVITA_EPAPER_PORT` env vars, settable in
  `.env`. Defaults: `0.0.0.0` and `8095`.
- `update.sh` now refuses to apply a tarball whose project name doesn't
  match the install directory (e.g. `kavita-epaper-*.tar.gz` applied to
  `/opt/kavita-boox/`).

### Changed
- **Default bind address changed from `127.0.0.1` to `0.0.0.0`.** The
  service is now reachable from other hosts by default, which is useful when
  your reverse proxy lives on a different machine. Set
  `KAVITA_EPAPER_HOST=127.0.0.1` in `.env` to restore loopback-only.

### Upgrade notes (0.7.1 → 0.7.2)

This release changes the systemd unit file. `update.sh` only swaps app
code; it does not touch `/etc/systemd/system/kavita-epaper.service`. To
pick up the new unit, re-run the installer after applying the update:

```bash
mkdir -p /tmp/kavita-epaper && tar -xzf kavita-epaper-v0.7.2.tar.gz -C /tmp/kavita-epaper
cd /tmp/kavita-epaper && sudo ./deploy/install.sh
```

`install.sh` is idempotent and preserves `.env` and the cover cache. If
you previously worked around the loopback default with `systemctl edit`,
you can remove that override after re-installing:

```bash
sudo systemctl revert kavita-epaper.service
sudo systemctl restart kavita-epaper
```

## [0.7.0] - renamed `kavita-boox` → `kavita-epaper`

### Changed
- Project renamed throughout: install path, system user, systemd unit,
  env var prefix, cookie name, session salt, localStorage keys, log
  prefix.

### Upgrade notes (from `kavita-boox`)

Cross-project updates are not supported. If you have an existing
`kavita-boox` install, remove it before installing `kavita-epaper`:

```bash
sudo systemctl disable --now kavita-boox
sudo rm -rf /opt/kavita-boox /var/cache/kavita-boox /etc/systemd/system/kavita-boox.service
sudo userdel kavita-boox
sudo systemctl daemon-reload
```

Then install `kavita-epaper` per the README. Expect a one-time fresh
login (cookie name + session salt changed) and reader settings reset
(dark mode, font size, margins; `localStorage` keys are now `ke-*`
instead of `kb-*`).

If you'd customized `.env`, copy values from `KAVITA_BOOX_*` to the new
`KAVITA_EPAPER_*` variables. Leave `KAVITA_EPAPER_SECRET` at its
auto-generated value: re-using the old secret would not help since the
session salt changed.

## [0.6.0] - dark mode

### Added
- Per-device dark mode toggle in the reader settings panel. Light by
  default; flipped via a single CSS variable swap. Applies globally
  across library, series, and reader views.
- Inline early-apply script in `base.html` to prevent light → dark
  flash on cold loads.

## [0.5.1] - fix progress clobbering

### Fixed
- Opening a book no longer overwrites Kavita's saved progress with page
  zero. Previously, tapping the ▶ button on a series page loaded
  `/read/{id}` with no `page=` parameter, which defaulted to page 1 and
  then unconditionally POSTed `pageNum=0` to Kavita's progress endpoint,
  destroying any prior reading position. The reader now fetches saved
  progress from `/api/Reader/get-progress` first and resumes from
  there, falling back to page 1 only if no progress exists.

## [0.5.0] - pagination rewrite

### Changed
- EPUB reader pagination switched from `transform: translateX()` to
  native `element.scrollLeft`. This matches Kavita's own web reader
  approach: the browser's scroll engine and layout engine see the same
  numbers, eliminating subpixel rounding errors that caused text from
  adjacent columns to bleed in at page edges. CSS multi-column
  properties moved from JS to stylesheet; `.reader-content` now uses
  flex layout for reliable height fill on older Chromium (the kind
  shipping in low-cost Android e-readers).

## Earlier history

The project began as `kavita-boox`, a download-only Kavita frontend
intended for sideloading EPUBs to Android-based e-readers like the
OBOOK6 via apps like NeoReader. The built-in EPUB reader was added in
v0.4.x and substantially rewritten in v0.5.0. The misleading
`kavita-boox` name (the actual test device was an OBOOK6, not an Onyx
Boox) was corrected in v0.7.0 with the rename to `kavita-epaper`.
