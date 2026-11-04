#!/usr/bin/env bash
# update.sh: drop in a new kavita-epaper release without re-running the full installer.
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
SVC_NAME="kavita-epaper.service"
DEFAULT_RELEASES_DIR="/var/lib/kavita-epaper/releases"

if [ "$EUID" -ne 0 ]; then
  echo "Must be run as root (use sudo)" >&2
  exit 1
fi

# Ownership hardening. This script runs as root and executes files from
# INSTALL_DIR (venv/bin/pip, and itself on the next run). Installs before
# 0.7.15 left all of it owned by the service user, which made a compromise
# of that account a path to root. Normalize on every run.
chown -R root:root "$INSTALL_DIR"
chmod -R go-w "$INSTALL_DIR"
[ -f "$INSTALL_DIR/.env" ] && chmod 600 "$INSTALL_DIR/.env"

# Read the one setting we need from .env without sourcing it. Sourcing would
# execute the file as root, including anything written into it while it was
# still owned by the service user.
env_value() {
  [ -f "$INSTALL_DIR/.env" ] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$INSTALL_DIR/.env" | tail -1 \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}
KAVITA_EPAPER_RELEASES_DIR="${KAVITA_EPAPER_RELEASES_DIR:-$(env_value KAVITA_EPAPER_RELEASES_DIR)}"
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
  # grep over browser_download_url entries is sufficient; no jq dependency.
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

# Hand off to the update.sh shipped in the tarball when it differs from this
# one, so each release's own install logic (ownership, new steps) applies to
# its own install. Runs as a child, not exec, so this process's EXIT trap
# still cleans up TMPDIR (which holds a downloaded tarball) afterwards. The
# call and exit share one line because bash parses a whole line before
# running it, and the child may replace this file on disk.
INCOMING="$TMPDIR/extract/deploy/update.sh"
if [ -z "${KAVITA_EPAPER_UPDATE_HANDOFF:-}" ] && [ -f "$INCOMING" ] && \
   ! cmp -s "$INCOMING" "${BASH_SOURCE[0]}"; then
  echo "[+] handing off to the tarball's update.sh"
  KAVITA_EPAPER_UPDATE_HANDOFF=1 bash "$INCOMING" "$TARBALL"; exit $?
fi

[ -f "$TMPDIR/extract/VERSION" ] && echo "[+] new version: $(cat "$TMPDIR/extract/VERSION")"
[ -f "$INSTALL_DIR/VERSION" ] && echo "[+] current version: $(cat "$INSTALL_DIR/VERSION")"

if [ -f "$TMPDIR/extract/VERSION" ] && [ -f "$INSTALL_DIR/VERSION" ] && \
   [ "$(cat "$TMPDIR/extract/VERSION")" = "$(cat "$INSTALL_DIR/VERSION")" ]; then
  echo "[=] already on this version, nothing to do"
  exit 0
fi

# From 0.7.21 the app refuses to start without a real session secret. Check
# it before anything is stopped, so a weak one leaves the current version
# running. Only the length is looked at; the value is never printed. A secret
# set in a unit drop-in (systemctl show -p Environment) counts too.
SECRET_LINE=$(grep -E '^[[:space:]]*KAVITA_EPAPER_SECRET=' "$INSTALL_DIR/.env" 2>/dev/null | tail -1 || true)
SECRET_VAL=${SECRET_LINE#*=}
SECRET_VAL=${SECRET_VAL%\"}; SECRET_VAL=${SECRET_VAL#\"}
SECRET_VAL=${SECRET_VAL%\'}; SECRET_VAL=${SECRET_VAL#\'}
SECRET_ISSUE=""
if [ -z "$SECRET_LINE" ]; then
  UNIT_ENV=$(systemctl show "$SVC_NAME" -p Environment 2>/dev/null || true)
  case "$UNIT_ENV" in
    *KAVITA_EPAPER_SECRET=*) ;;
    *) SECRET_ISSUE="is not set in $INSTALL_DIR/.env" ;;
  esac
  unset UNIT_ENV
elif [ -z "$SECRET_VAL" ]; then
  SECRET_ISSUE="is not set in $INSTALL_DIR/.env"
elif [ "$SECRET_VAL" = "CHANGE_ME_TO_A_LONG_RANDOM_STRING" ]; then
  SECRET_ISSUE="is still the placeholder from env.example"
elif [ "${#SECRET_VAL}" -lt 32 ]; then
  SECRET_ISSUE="is too short (${#SECRET_VAL} characters, need at least 32)"
fi
unset SECRET_LINE SECRET_VAL
if [ -n "$SECRET_ISSUE" ]; then
  echo "[✗] KAVITA_EPAPER_SECRET $SECRET_ISSUE; this version won't start with it." >&2
  echo "    $SVC_NAME was not stopped and is still running $(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo 'the previous version')." >&2
  echo "    Generate one: python3 -c 'import secrets; print(secrets.token_urlsafe(48))'" >&2
  echo "    set KAVITA_EPAPER_SECRET=<that value> in $INSTALL_DIR/.env, then run this update again." >&2
  echo "    A new secret signs everyone out once." >&2
  exit 1
fi

# Service unit. Install the shipped unit when it differs from the installed
# one. This point is only reached after the cross-project guard above, so
# the unit belongs to this project. The new unit is verified before anything
# is stopped, and the installed one is backed up and put back if the service
# won't start. Local changes belong in a drop-in under
# /etc/systemd/system/$SVC_NAME.d/ (systemctl edit), which this never touches.
UNIT_SRC="$TMPDIR/extract/deploy/$SVC_NAME"
UNIT_DST="/etc/systemd/system/$SVC_NAME"
UNIT_CHANGED=""
UNIT_BACKUP=""
if [ -f "$UNIT_SRC" ] && ! cmp -s "$UNIT_SRC" "$UNIT_DST"; then
  echo "[+] service unit changed, verifying the new one"
  # verify exits 0 on warnings such as unknown keys, so also fail on any
  # message about this unit. Messages about unrelated units don't count.
  VERIFY_RC=0
  VERIFY_OUT=$(systemd-analyze verify "$UNIT_SRC" 2>&1) || VERIFY_RC=$?
  if [ "$VERIFY_RC" -ne 0 ] || printf '%s\n' "$VERIFY_OUT" | grep -qF -e "$UNIT_SRC" -e "$SVC_NAME"; then
    printf '%s\n' "$VERIFY_OUT" >&2
    echo "[✗] new $SVC_NAME failed systemd-analyze verify; nothing was changed" >&2
    exit 1
  fi
  UNIT_CHANGED=1
fi

# Python dependencies go in while the current version is still running. If
# pip fails, the update stops here and that version keeps serving. Adding
# packages under a running process is safe: the new code only loads them at
# the restart below.
# constraints.txt (from 0.7.22) pins the tested versions of everything
# requirements.txt pulls in; a change to either file runs pip.
same_file() {  # both missing, or both present and identical
  if [ -f "$1" ] || [ -f "$2" ]; then
    [ -f "$1" ] && [ -f "$2" ] && cmp -s "$1" "$2"
  fi
}
PIP_CONSTRAINTS=()
[ -f "$TMPDIR/extract/constraints.txt" ] && PIP_CONSTRAINTS=(-c "$TMPDIR/extract/constraints.txt")
if [ -f "$INSTALL_DIR/requirements.txt" ] && \
   same_file "$INSTALL_DIR/requirements.txt" "$TMPDIR/extract/requirements.txt" && \
   same_file "$INSTALL_DIR/constraints.txt" "$TMPDIR/extract/constraints.txt"; then
  echo "[+] requirements.txt and constraints.txt unchanged, skipping pip"
else
  echo "[+] requirements.txt or constraints.txt changed, updating venv before stopping $SVC_NAME"
  if ! "$INSTALL_DIR/venv/bin/pip" install --disable-pip-version-check --quiet --upgrade \
       -r "$TMPDIR/extract/requirements.txt" ${PIP_CONSTRAINTS[@]+"${PIP_CONSTRAINTS[@]}"}; then
    echo "[✗] pip install failed; $SVC_NAME was not stopped and is still running $(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo 'the previous version')" >&2
    echo "    nothing else was changed (pip may have added packages to the venv)" >&2
    exit 1
  fi
fi

echo "[+] stopping $SVC_NAME"
systemctl stop "$SVC_NAME" || true

echo "[+] syncing app/ → $INSTALL_DIR/app/"
rsync -a --delete "$TMPDIR/extract/app/" "$INSTALL_DIR/app/"
cp "$TMPDIR/extract/requirements.txt" "$INSTALL_DIR/requirements.txt"
if [ -f "$TMPDIR/extract/constraints.txt" ]; then
  cp "$TMPDIR/extract/constraints.txt" "$INSTALL_DIR/constraints.txt"
  chown root:root "$INSTALL_DIR/constraints.txt"
else
  rm -f "$INSTALL_DIR/constraints.txt"
fi

[ -f "$TMPDIR/extract/VERSION" ] && cp "$TMPDIR/extract/VERSION" "$INSTALL_DIR/VERSION"

if [ -f "$TMPDIR/extract/deploy/update.sh" ]; then
  install -m 755 "$TMPDIR/extract/deploy/update.sh" "$INSTALL_DIR/update.sh"
fi

chown -R root:root "$INSTALL_DIR/app" "$INSTALL_DIR/requirements.txt" "$INSTALL_DIR/venv"
[ -f "$INSTALL_DIR/VERSION" ] && chown root:root "$INSTALL_DIR/VERSION"
chmod -R go-w "$INSTALL_DIR/app"

if [ -n "$UNIT_CHANGED" ]; then
  if [ -f "$UNIT_DST" ]; then
    mkdir -p /var/backups
    UNIT_BACKUP="/var/backups/$SVC_NAME.$(date +%Y%m%d-%H%M%S)"
    cp -p "$UNIT_DST" "$UNIT_BACKUP"
    echo "[+] backed up the installed unit to $UNIT_BACKUP"
  fi
  install -m 644 "$UNIT_SRC" "$UNIT_DST"
  systemctl daemon-reload
  echo "[+] installed the new $SVC_NAME"
fi

echo "[+] starting $SVC_NAME"
systemctl reset-failed "$SVC_NAME" 2>/dev/null || true
# Don't let set -e exit here: a failed start must reach the unit rollback.
systemctl start "$SVC_NAME" || true

sleep 2
if systemctl is-active --quiet "$SVC_NAME"; then
  echo "[✓] kavita-epaper updated and running"
  systemctl status "$SVC_NAME" --no-pager | head -3
else
  echo "[✗] service failed to start; check: journalctl -u $SVC_NAME -n 30" >&2
  if [ -n "$UNIT_CHANGED" ]; then
    if [ -n "$UNIT_BACKUP" ]; then
      echo "[!] restoring the previous unit from $UNIT_BACKUP" >&2
      install -m 644 "$UNIT_BACKUP" "$UNIT_DST"
      systemctl daemon-reload
      systemctl reset-failed "$SVC_NAME" 2>/dev/null || true
      systemctl start "$SVC_NAME" 2>/dev/null || true
      sleep 2
      if systemctl is-active --quiet "$SVC_NAME"; then
        echo "[!] running on the previous unit with the new code; the update is incomplete" >&2
      else
        echo "[✗] still not running on the previous unit" >&2
      fi
    else
      echo "[!] there was no previous unit; removing the new one" >&2
      rm -f "$UNIT_DST"
      systemctl daemon-reload
    fi
  fi
  exit 1
fi
