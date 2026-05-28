#!/usr/bin/env bash
# update.sh — drop in a new kavita-epaper release without re-running the full installer.
#
# Usage:
#   sudo /opt/kavita-epaper/update.sh                                  # auto-pick newest from releases dir
#   sudo /opt/kavita-epaper/update.sh /path/to/kavita-epaper-vX.Y.Z.tar.gz
#   sudo /opt/kavita-epaper/update.sh https://my.server/kavita-epaper-vX.Y.Z.tar.gz
#   sudo /opt/kavita-epaper/update.sh --github <owner>/<repo>         # latest release from GitHub
#
# Set KAVITA_EPAPER_RELEASES_DIR in /opt/kavita-epaper/.env to control where
# tarballs are looked for. Defaults to /var/lib/kavita-epaper/releases.
#
# For --github mode: anonymous API access is rate-limited to 60 requests/hour
# per IP. For private repos or higher limits, set GITHUB_TOKEN in the
# environment (export it before invoking sudo with `sudo -E`).

set -euo pipefail

INSTALL_DIR="/opt/kavita-epaper"
SERVICE_USER="kavita-epaper"
SVC_NAME="kavita-epaper.service"
DEFAULT_RELEASES_DIR="/var/lib/kavita-epaper/releases"

if [ "$EUID" -ne 0 ]; then
  echo "Must be run as root (use sudo)" >&2
  exit 1
fi

if [ -f "$INSTALL_DIR/.env" ]; then
  set -a; . "$INSTALL_DIR/.env"; set +a
fi
RELEASES_DIR="${KAVITA_EPAPER_RELEASES_DIR:-$DEFAULT_RELEASES_DIR}"

SOURCE="${1:-}"

# --github <owner>/<repo>: resolve to the asset URL of the latest published
# release. Falls through into the normal URL-download path below.
if [ "$SOURCE" = "--github" ]; then
  REPO="${2:-}"
  if [ -z "$REPO" ] || [[ "$REPO" != */* ]] || [[ "$REPO" == */*/* ]]; then
    echo "Usage: $0 --github <owner>/<repo>" >&2
    exit 2
  fi
  API_URL="https://api.github.com/repos/${REPO}/releases/latest"
  echo "[+] querying $API_URL"

  # GitHub requires a User-Agent. GITHUB_TOKEN is optional (private repos /
  # higher rate limits). curl_args is built up to avoid passing an empty
  # Authorization header when the token isn't set.
  CURL_ARGS=(-fsSL -H "Accept: application/vnd.github+json" -H "User-Agent: kavita-epaper-update")
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  if ! RESP=$(curl "${CURL_ARGS[@]}" "$API_URL"); then
    echo "[✗] failed to fetch latest release from GitHub" >&2
    echo "    possible causes: repo doesn't exist, no published releases yet," >&2
    echo "    rate-limited (60/hr anonymous), or network issue" >&2
    exit 1
  fi

  # Extract the kavita-epaper-*.tar.gz asset URL from the JSON response.
  # GitHub returns pretty-printed JSON with one field per line, so a simple
  # grep over browser_download_url entries is sufficient — no jq dependency.
  # `|| true` is critical: under set -euo pipefail, a grep with no matches
  # makes the pipeline return non-zero, which would otherwise kill the script
  # silently before we reach the empty-SOURCE check below.
  SOURCE=$(printf '%s' "$RESP" \
    | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*kavita-epaper-v[0-9][^"]*\.tar\.gz"' \
    | head -1 \
    | grep -oE 'https://[^"]+' || true)

  if [ -z "$SOURCE" ]; then
    echo "[✗] latest release has no kavita-epaper-v*.tar.gz asset attached" >&2
    echo "    check https://github.com/${REPO}/releases" >&2
    exit 1
  fi
  echo "[+] resolved to $SOURCE"
fi

if [ -z "$SOURCE" ]; then
  if [ ! -d "$RELEASES_DIR" ]; then
    echo "Releases dir does not exist: $RELEASES_DIR" >&2
    echo "Either create it, set KAVITA_EPAPER_RELEASES_DIR in .env, or pass a path/URL." >&2
    exit 1
  fi
  SOURCE=$(ls "$RELEASES_DIR"/kavita-epaper-v*.tar.gz 2>/dev/null | sort -V | tail -1 || true)
  if [ -z "$SOURCE" ]; then
    echo "No kavita-epaper-v*.tar.gz found in $RELEASES_DIR" >&2
    echo "Usage: $0 [<tarball-path-or-url>]" >&2
    exit 1
  fi
  echo "[+] auto-selected: $SOURCE"
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

if [[ "$SOURCE" == http://* ]] || [[ "$SOURCE" == https://* ]]; then
  echo "[+] downloading $SOURCE"
  TARBALL="$TMPDIR/release.tar.gz"
  curl -fsSL "$SOURCE" -o "$TARBALL"
else
  if [ ! -f "$SOURCE" ]; then
    echo "Not found: $SOURCE" >&2
    exit 1
  fi
  TARBALL="$SOURCE"
fi

echo "[+] extracting"
mkdir -p "$TMPDIR/extract"
tar -xzf "$TARBALL" -C "$TMPDIR/extract"

if [ ! -d "$TMPDIR/extract/app" ] || [ ! -f "$TMPDIR/extract/requirements.txt" ]; then
  echo "Tarball does not look like a kavita-epaper release (missing app/ or requirements.txt)" >&2
  exit 1
fi

# Cross-project guard: catch the case where a tarball for a differently-named
# project is applied to this install (e.g. kavita-epaper tarball applied to a
# /opt/kavita-boox install during a rename). Uses the shipped service file as
# the source of truth for the tarball's project identity.
EXPECTED_PROJECT=$(basename "$INSTALL_DIR")
TARBALL_SVC=$(ls "$TMPDIR/extract/deploy/"*.service 2>/dev/null | head -1)
if [ -n "$TARBALL_SVC" ]; then
  TARBALL_PROJECT=$(basename "${TARBALL_SVC%.service}")
  if [ "$TARBALL_PROJECT" != "$EXPECTED_PROJECT" ]; then
    echo "[✗] tarball ships '${TARBALL_PROJECT}.service' but install lives at ${INSTALL_DIR}" >&2
    echo "    cross-project updates aren't supported." >&2
    echo "    Use the new tarball's deploy/install.sh for a fresh install of '${TARBALL_PROJECT}'," >&2
    echo "    then remove the old install. See README.md (Migration section)." >&2
    exit 1
  fi
fi

[ -f "$TMPDIR/extract/VERSION" ] && echo "[+] new version: $(cat "$TMPDIR/extract/VERSION")"
[ -f "$INSTALL_DIR/VERSION" ] && echo "[+] current version: $(cat "$INSTALL_DIR/VERSION")"

if [ -f "$TMPDIR/extract/VERSION" ] && [ -f "$INSTALL_DIR/VERSION" ] && \
   [ "$(cat "$TMPDIR/extract/VERSION")" = "$(cat "$INSTALL_DIR/VERSION")" ]; then
  echo "[=] already on this version — nothing to do"
  exit 0
fi

echo "[+] stopping $SVC_NAME"
systemctl stop "$SVC_NAME" || true

echo "[+] syncing app/ → $INSTALL_DIR/app/"
rsync -a --delete "$TMPDIR/extract/app/" "$INSTALL_DIR/app/"

if [ -f "$INSTALL_DIR/requirements.txt" ] && \
   diff -q "$INSTALL_DIR/requirements.txt" "$TMPDIR/extract/requirements.txt" >/dev/null 2>&1; then
  echo "[+] requirements.txt unchanged — skipping pip"
else
  echo "[+] requirements.txt changed — updating venv"
  cp "$TMPDIR/extract/requirements.txt" "$INSTALL_DIR/requirements.txt"
  "$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade -r "$INSTALL_DIR/requirements.txt"
fi

[ -f "$TMPDIR/extract/VERSION" ] && cp "$TMPDIR/extract/VERSION" "$INSTALL_DIR/VERSION"

if [ -f "$TMPDIR/extract/deploy/update.sh" ]; then
  install -m 755 "$TMPDIR/extract/deploy/update.sh" "$INSTALL_DIR/update.sh"
fi

chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/app" "$INSTALL_DIR/requirements.txt"
[ -f "$INSTALL_DIR/VERSION" ] && chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/VERSION"

echo "[+] starting $SVC_NAME"
systemctl reset-failed "$SVC_NAME" 2>/dev/null || true
systemctl start "$SVC_NAME"

sleep 2
if systemctl is-active --quiet "$SVC_NAME"; then
  echo "[✓] kavita-epaper updated and running"
  systemctl status "$SVC_NAME" --no-pager | head -3
else
  echo "[✗] service failed to start — check: journalctl -u $SVC_NAME -n 30" >&2
  exit 1
fi
