# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with
upgrade notes called out where they require manual steps.

## [0.7.14] — fix EPUB image rendering

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

## [0.7.13] — EPUB-only scope made explicit

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
  Em-dashes removed throughout.

## [0.7.12] — fix silent failure in `update.sh --github`

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

## [0.7.11] — remove unused KAVITA_PUBLIC_URL

### Removed
- `KAVITA_PUBLIC_URL` env var — was defined and the `reader_url` helper
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

## [0.7.10] — fix incorrect device attribution

### Fixed
- Multiple places throughout the README, CHANGELOG, and inline code
  comments mistakenly referred to the test device as an "Onyx Boox" —
  the actual primary test device is the OBOOK6, an unrelated
  Android-based e-reader brand. Corrected throughout. The original
  project name (`kavita-boox`) was a misnomer for the same reason;
  this is what motivated the v0.7.0 rename. The CHANGELOG entry for
  v0.7.0 now explains this.

### Changed
- `LICENSE` copyright holder updated to "Cory Jarboe".

No code-behavior changes.

## [0.7.9] — document tested devices

### Changed
- README gains a "Tested on" section listing devices the project has
  been verified on: OBOOK6, Samsung Galaxy Tab S10 FE, iPad (6th
  gen), and desktop browsers.

No code changes.

## [0.7.8] — generalized defaults for public release

### Changed
- Default `KAVITA_EPAPER_RELEASES_DIR` moved from `/mnt/jellyfin/media`
  (author's homelab path) to `/var/lib/kavita-epaper/releases` (FHS
  standard for service-owned mutable data). `install.sh` now creates
  this directory automatically.
- Example URLs in the README, env template, and reverse-proxy docs use
  RFC 2606 reserved domains (`example.com`) instead of author-specific
  hostnames.
- README install/upgrade instructions no longer assume a specific LXC
  layout; works on any Debian-family host with systemd.

### Upgrade notes (0.7.7 → 0.7.8)

If you'd been using the old default (`/mnt/jellyfin/media`) without
setting `KAVITA_EPAPER_RELEASES_DIR` in `.env`, the no-args `update.sh`
will now look at `/var/lib/kavita-epaper/releases` instead. To keep the
old behavior, set `KAVITA_EPAPER_RELEASES_DIR=/mnt/jellyfin/media` in
`/opt/kavita-epaper/.env`.

To pick up the new install.sh dir-creation behavior, re-run the
installer once:

```bash
mkdir -p /tmp/kavita-epaper && tar -xzf kavita-epaper-v0.7.8.tar.gz -C /tmp/kavita-epaper
cd /tmp/kavita-epaper && sudo ./deploy/install.sh
```

(Idempotent, preserves `.env` and the cover cache.)

## [0.7.7] — `update.sh --github` mode

### Added
- `update.sh --github <owner>/<repo>` resolves the latest published
  release on GitHub via the public API and downloads the attached
  `kavita-epaper-v*.tar.gz` asset. No external dependencies (uses
  grep-based JSON parsing). Optional `GITHUB_TOKEN` env var for private
  repos and higher rate limits.

No code changes outside `update.sh`. Safe to apply via `update.sh`
itself.

## [0.7.6] — direct-access README rewrite

### Changed
- The "Direct access without a reverse proxy" warning rewritten for
  accuracy. The prior text overstated the risk relative to Kavita's own
  threat model. kavita-epaper's auth flow is identical to Kavita's
  native flow: credentials hit Kavita over whatever transport is
  configured. If plain-HTTP Kavita on a trusted LAN is fine, plain-HTTP
  kavita-epaper on the same LAN is also fine.

No code changes.

## [0.7.5] — direct-IP access works out of the box

### Changed
- `KAVITA_EPAPER_COOKIE_SECURE` is now tri-state. New default is `auto`,
  which sets the cookie's `Secure` flag dynamically based on the request
  scheme (HTTPS → Secure; HTTP → not Secure). Pin to `true` or `false` to
  override.

### Fixed
- Direct access via `http://<host-ip>:8095` previously logged the user in
  but the session never persisted, because the `Secure` cookie was
  silently dropped by browsers over plain HTTP. With the `auto` default
  this just works — no env tweak needed for first-try usage.

### Notes
- If you'd hardcoded `KAVITA_EPAPER_COOKIE_SECURE=true` in `.env`, leave
  it; behavior is unchanged. If you want the new auto behavior, set it to
  `auto` (or remove the line and let it default).
- Pure `app/` change — `update.sh` is sufficient. No installer re-run
  needed.

## [0.7.4] — polish for public release

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

## [0.7.2] — env-driven host/port + cross-project update guard

### Added
- `KAVITA_EPAPER_HOST` and `KAVITA_EPAPER_PORT` env vars, settable in
  `.env`. Defaults: `0.0.0.0` and `8095`.
- `update.sh` now refuses to apply a tarball whose project name doesn't
  match the install directory (e.g. `kavita-epaper-*.tar.gz` applied to
  `/opt/kavita-boox/`).

### Changed
- **Default bind address changed from `127.0.0.1` to `0.0.0.0`.** The
  service is now reachable from other hosts by default — useful when
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

## [0.7.0] — renamed `kavita-boox` → `kavita-epaper`

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
(dark mode, font size, margins — `localStorage` keys are now `ke-*`
instead of `kb-*`).

If you'd customized `.env`, copy values from `KAVITA_BOOX_*` to the new
`KAVITA_EPAPER_*` variables. Leave `KAVITA_EPAPER_SECRET` at its
auto-generated value — re-using the old secret would not help since the
session salt changed.

## [0.6.0] — dark mode

### Added
- Per-device dark mode toggle in the reader settings panel. Light by
  default; flipped via a single CSS variable swap. Applies globally
  across library, series, and reader views.
- Inline early-apply script in `base.html` to prevent light → dark
  flash on cold loads.

## [0.5.1] — fix progress clobbering

### Fixed
- Opening a book no longer overwrites Kavita's saved progress with page
  zero. Previously, tapping the ▶ button on a series page loaded
  `/read/{id}` with no `page=` parameter, which defaulted to page 1 and
  then unconditionally POSTed `pageNum=0` to Kavita's progress endpoint
  — destroying any prior reading position. The reader now fetches saved
  progress from `/api/Reader/get-progress` first and resumes from
  there, falling back to page 1 only if no progress exists.

## [0.5.0] — pagination rewrite

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
