#!/usr/bin/env bash
# update.sh: install a kavita-epaper release (all or nothing), or switch back.
#
# Usage:
#   sudo /opt/kavita-epaper/update.sh                                  # newest from the releases dir
#   sudo /opt/kavita-epaper/update.sh /path/to/kavita-epaper-vX.Y.Z.tar.gz
#   sudo /opt/kavita-epaper/update.sh https://my.server/kavita-epaper-vX.Y.Z.tar.gz
#   sudo /opt/kavita-epaper/update.sh --github <owner>/<repo>         # latest release from GitHub
#   sudo /opt/kavita-epaper/update.sh --status                         # what's installed, what --rollback does
#   sudo /opt/kavita-epaper/update.sh --rollback [--yes]               # switch to the kept previous version
#
# A release older than the installed version is refused unless
# --allow-downgrade is given (in any position); --rollback is the usual way
# back and needs no flag.
#
# Layout (from 0.7.23): app/, VERSION, requirements.txt, constraints.txt are
# the current version; venv is a symlink to venvs/<id>, one venv per set of
# dependencies, built in place and never renamed; previous/ is the one kept
# previous version (its app, metadata, unit and a venv link), used by
# --rollback without a tarball or network. An update builds or reuses the
# venv while the current version keeps running, then swaps in the stop
# window, and keeps the result only if the service is active and the login
# page answers. Otherwise everything is put back as it was. Each move of the
# swap is written to a journal first, so an interrupted swap is undone on
# the next run.
#
# This script and configure are always the newest installed versions: an
# older tarball or --rollback brings back an older app, never an older
# update.sh or configure.
#
# Set KAVITA_EPAPER_RELEASES_DIR in /opt/kavita-epaper/.env to control where
# tarballs are looked for. Defaults to /var/lib/kavita-epaper/releases.
# For --github mode: anonymous API access is rate-limited to 60 requests/hour
# per IP; set GITHUB_TOKEN (and use sudo -E) for more.

set -euo pipefail

# The version of this script. A tarball's update.sh only takes over (handoff)
# and only gets installed when its version is newer than this one.
UPDATE_SH_VERSION="0.7.24"

INSTALL_DIR="/opt/kavita-epaper"
SVC_NAME="kavita-epaper.service"
DEFAULT_RELEASES_DIR="/var/lib/kavita-epaper/releases"
UNIT_DST="/etc/systemd/system/$SVC_NAME"
BACKUP_DIR="/var/backups"
HEALTH_WAIT=20
# What a version consists of: these move between the install dir and previous/.
APP_ITEMS=(app VERSION requirements.txt constraints.txt)
JOURNAL="$INSTALL_DIR/.update-journal"

if [ "$EUID" -ne 0 ]; then
  echo "Must be run as root (use sudo; in a root shell without sudo, run it directly)" >&2
  exit 1
fi

# Ownership hardening. This script runs as root and executes files from
# INSTALL_DIR (venv/bin/pip, and itself on the next run). Installs before
# 0.7.15 left all of it owned by the service user, which made a compromise
# of that account a path to root. Normalize on every run.
chown -R root:root "$INSTALL_DIR"
chmod -R go-w "$INSTALL_DIR"
[ -f "$INSTALL_DIR/.env" ] && chmod 600 "$INSTALL_DIR/.env"

# Read a setting from .env without sourcing it. Sourcing would execute the
# file as root, including anything written into it while it was still owned
# by the service user.
env_value() {
  [ -f "$INSTALL_DIR/.env" ] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$INSTALL_DIR/.env" | tail -1 \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

version_of() { cat "$1/VERSION" 2>/dev/null || echo "unknown"; }
newer_than() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }
script_version() {  # UPDATE_SH_VERSION of an update.sh file, or empty
  [ -f "$1" ] || return 0
  sed -n 's/^UPDATE_SH_VERSION="\([0-9.]*\)"$/\1/p' "$1" | head -1 || true
}

# ---------------------------------------------------------------- journal
# Every change made in the stop window is recorded before it is made, as one
# line: "mv SRC DST", "link LINK OLDTARGET" ("-" when LINK didn't exist),
# "made PATH" or "unit BACKUP" ("-" when there was no unit). undo_journal
# reverses them newest first.
jrec() { printf '%s\n' "$*" >> "$JOURNAL"; sync -f "$JOURNAL" 2>/dev/null || true; }
jmv() { jrec "mv $1 $2"; mv -T "$1" "$2"; }
jmade() { jrec "made $1"; }
set_link() {  # atomic: a new symlink renamed over the old one
  ln -sfn "$2" "$1.tmp.$$"
  mv -T "$1.tmp.$$" "$1"
}
jlink() {  # LINK TARGET
  local old="-"
  [ -L "$1" ] && old=$(readlink "$1")
  jrec "link $1 $old"
  set_link "$1" "$2"
}
undo_journal() {
  [ -f "$JOURNAL" ] || return 0
  local kind a b
  while read -r kind a b; do
    case "$kind" in
      mv) if [ -e "$b" ] || [ -L "$b" ]; then mv -T "$b" "$a"; fi ;;
      link) if [ "$b" = "-" ]; then rm -f "$a"; else set_link "$a" "$b"; fi ;;
      made) rm -rf -- "$a" ;;
      unit)
        if [ "$a" = "-" ]; then rm -f "$UNIT_DST"; else install -m 644 "$a" "$UNIT_DST"; fi
        systemctl daemon-reload ;;
    esac
  done < <(tac "$JOURNAL")
  rm -f "$JOURNAL"
}

# ---------------------------------------------------------------- health
# Healthy = active and the login page answers 200 on the configured address.
# Kavita being down is not unhealthy; /healthz is only reported.
check_url() {
  local host port
  host=$(env_value KAVITA_EPAPER_HOST); host=${host:-0.0.0.0}
  port=$(env_value KAVITA_EPAPER_PORT); port=${port:-8095}
  case "$host" in
    0.0.0.0) host=127.0.0.1 ;;
    ::|"[::]") host="[::1]" ;;
    *:*) host="[$host]" ;;
  esac
  printf 'http://%s:%s' "$host" "$port"
}
wait_healthy() {
  local url
  url="$(check_url)/login"
  for _ in $(seq 1 $((HEALTH_WAIT * 2))); do
    if systemctl is-active --quiet "$SVC_NAME" && \
       python3 -c 'import sys, urllib.request; urllib.request.urlopen(sys.argv[1], timeout=2)' "$url" >/dev/null 2>&1; then
      return 0
    fi
    systemctl is-failed --quiet "$SVC_NAME" && return 1
    sleep 0.5
  done
  return 1
}
start_service() {
  systemctl reset-failed "$SVC_NAME" 2>/dev/null || true
  systemctl start "$SVC_NAME" || true
}
kavita_note() {  # $1: "update" or "switch". Warn (never fail) when the app can't reach Kavita
  local out
  out=$(python3 - "$(check_url)/healthz" <<'PY' 2>/dev/null || true
import sys, urllib.request, urllib.error
try:
    urllib.request.urlopen(sys.argv[1], timeout=15)
except urllib.error.HTTPError as e:
    print(e.read().decode(errors="replace").strip() or f"HTTP {e.code}")
except Exception as e:
    print(f"no answer from /healthz ({type(e).__name__})")
PY
)
  if [ -n "$out" ]; then
    echo "[!] kavita-epaper is running, but Kavita isn't answering ($out)."
    echo "    The ${1:-update} itself is fine. Check that Kavita is up, and the address kavita-epaper uses:"
    echo "    sudo $INSTALL_DIR/configure show   (change it with: configure kavita-url <address>)"
  fi
}

# ---------------------------------------------------------------- venvs
deps_id() {  # DIR holding requirements.txt (and constraints.txt): 12-char id
  { cat "$1/requirements.txt"; echo "--"; cat "$1/constraints.txt" 2>/dev/null || true; echo "--"
    python3 -c 'import sys; print(sys.version)'; } | sha256sum | cut -c1-12
}
venv_target() {  # "venvs/<id>" for the current venv link, "legacy" for a real dir, "" if none
  if [ -L "$INSTALL_DIR/venv" ]; then readlink "$INSTALL_DIR/venv"
  elif [ -d "$INSTALL_DIR/venv" ]; then echo legacy
  fi
  return 0
}
build_venv() {  # ID SRC_DIR: python3 -m venv + pip -r/-c + pip check + pin check
  local dir="$INSTALL_DIR/venvs/$1" cons=()
  [ -f "$2/constraints.txt" ] && cons=(-c "$2/constraints.txt")
  rm -rf "$dir"
  mkdir -p "$INSTALL_DIR/venvs"
  python3 -m venv "$dir" &&
  "$dir/bin/pip" install --disable-pip-version-check --quiet -r "$2/requirements.txt" ${cons[@]+"${cons[@]}"} &&
  "$dir/bin/pip" check --disable-pip-version-check >/dev/null &&
  "$dir/bin/python" - "$2" <<'PY' &&
import re, sys, importlib.metadata as md
bad = 0
for f in ("requirements.txt", "constraints.txt"):
    try:
        lines = open(f"{sys.argv[1]}/{f}").read().splitlines()
    except FileNotFoundError:
        continue
    for line in lines:
        m = re.match(r"^([A-Za-z0-9_.-]+)(\[[^\]]*\])?==(\S+)", line.strip())
        if not m:
            continue
        try:
            have = md.version(m.group(1))
        except md.PackageNotFoundError:
            have = "missing"
        if have != m.group(3):
            bad += 1
            print(f"    {m.group(1)}: want {m.group(3)}, have {have}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
  touch "$dir/.complete" && return 0
  rm -rf "$dir"
  return 1
}
cleanup_venvs() {  # remove venvs/ entries neither venv nor previous/venv uses
  local keep1 keep2 d
  keep1=$(readlink "$INSTALL_DIR/venv" 2>/dev/null || true)
  keep2=$(readlink "$INSTALL_DIR/previous/venv" 2>/dev/null || true); keep2=${keep2#../}
  [ -d "$INSTALL_DIR/venvs" ] || return 0
  for d in "$INSTALL_DIR"/venvs/*; do
    [ -e "$d" ] || continue
    case "venvs/$(basename "$d")" in "$keep1"|"$keep2") ;; *) rm -rf -- "$d" ;; esac
  done
  rmdir "$INSTALL_DIR/venvs" 2>/dev/null || true
}
prune_unit_backups() {
  ls -1 "$BACKUP_DIR/$SVC_NAME".* 2>/dev/null | sort | head -n -5 | while read -r old; do
    rm -f -- "$old"
  done || true
}

# ---------------------------------------------------------------- unit
verify_unit() {  # FILE: systemd-analyze verify, failing on any message about it
  local rc=0 out
  out=$(systemd-analyze verify "$1" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] || printf '%s\n' "$out" | grep -qF -e "$1" -e "$SVC_NAME"; then
    printf '%s\n' "$out" >&2
    return 1
  fi
}
install_unit() {  # FILE: back up the installed unit, journal it, install FILE
  local backup="-"
  if [ -f "$UNIT_DST" ]; then
    mkdir -p "$BACKUP_DIR"
    backup="$BACKUP_DIR/$SVC_NAME.$(date +%Y%m%d-%H%M%S)"
    [ -e "$backup" ] && backup="$backup-$$"
    cp -p "$UNIT_DST" "$backup"
    echo "[+] backed up the installed unit to $backup"
  fi
  jrec "unit $backup"
  install -m 644 "$1" "$UNIT_DST"
  systemctl daemon-reload
  echo "[+] installed the new $SVC_NAME"
}

# ---------------------------------------------------------------- recovery
# A journal left behind means a swap was interrupted (power loss, kill).
# Undo it, start the service on what was there before, and stop.
recover_if_interrupted() {
  [ -f "$JOURNAL" ] || return 0
  echo "[!] found an interrupted update or rollback ($JOURNAL); putting the install back as it was" >&2
  systemctl stop "$SVC_NAME" 2>/dev/null || true
  undo_journal
  rm -rf "$INSTALL_DIR/next"
  cleanup_venvs
  start_service
  if wait_healthy; then
    echo "[✓] recovered; running $(version_of "$INSTALL_DIR") again. Run your command again." >&2
  else
    echo "[✗] recovered the files, but $SVC_NAME doesn't come up; check: journalctl -u $SVC_NAME -n 30" >&2
  fi
  exit 1
}

# ---------------------------------------------------------------- status
show_status() {
  local cur prev cur_v prev_v
  cur_v=$(version_of "$INSTALL_DIR")
  cur=$(venv_target)
  echo "current:   $cur_v   (venv: ${cur:-none})"
  if [ -f "$INSTALL_DIR/previous/VERSION" ]; then
    prev_v=$(version_of "$INSTALL_DIR/previous")
    prev=$(readlink "$INSTALL_DIR/previous/venv" 2>/dev/null || echo none)
    echo "previous:  $prev_v   (venv: ${prev#../})"
    echo "--rollback would switch from $cur_v to $prev_v (and a second --rollback back to $cur_v)."
  else
    echo "previous:  none; --rollback has nothing to switch to"
  fi
  [ -f "$INSTALL_DIR/failed/VERSION" ] && echo "failed:    $(version_of "$INSTALL_DIR/failed") (kept from a failed update, for its log; removed by the next update)"
  echo "update.sh: $UPDATE_SH_VERSION"
  if [ -d "$INSTALL_DIR/venvs" ]; then
    echo "venvs:"
    du -sh "$INSTALL_DIR"/venvs/* 2>/dev/null | sed "s#$INSTALL_DIR/##; s/^/  /" || true
  fi
  [ -f "$JOURNAL" ] && echo "[!] an interrupted update or rollback was found; the next update.sh run undoes it"
  if systemctl is-active --quiet "$SVC_NAME"; then echo "service:   active"; else echo "service:   not active"; fi
}

# ---------------------------------------------------------------- rollback
do_rollback() {
  local yes="$1" cur_v prev_v cur prev
  recover_if_interrupted
  if [ ! -f "$INSTALL_DIR/previous/VERSION" ] || [ ! -d "$INSTALL_DIR/previous/app" ] || \
     [ ! -L "$INSTALL_DIR/previous/venv" ] || [ ! -f "$INSTALL_DIR/previous/venv/.complete" ]; then
    echo "[✗] no kept previous version to switch to (see: update.sh --status). Nothing was changed." >&2
    exit 1
  fi
  if [ ! -L "$INSTALL_DIR/venv" ]; then
    echo "[✗] $INSTALL_DIR/venv isn't a symlink; run an update first. Nothing was changed." >&2
    exit 1
  fi
  cur_v=$(version_of "$INSTALL_DIR"); prev_v=$(version_of "$INSTALL_DIR/previous")
  echo "This switches kavita-epaper from $cur_v (current) back to $prev_v (kept previous version)."
  echo "Running --rollback again afterwards switches forward to $cur_v."
  if [ -z "$yes" ]; then
    if [ -t 0 ]; then
      printf 'Switch from %s to %s? [y/N]: ' "$cur_v" "$prev_v"
      local answer=""; read -r answer || true
      case "$answer" in y|Y|yes|YES) ;; *) echo "Nothing was changed."; exit 1 ;; esac
    else
      echo "[✗] not a terminal; rerun with --yes to switch from $cur_v to $prev_v. Nothing was changed." >&2
      exit 1
    fi
  fi
  local prev_unit="$INSTALL_DIR/previous/$SVC_NAME" swap_unit=""
  if [ -f "$prev_unit" ] && ! cmp -s "$prev_unit" "$UNIT_DST"; then
    if ! verify_unit "$prev_unit"; then
      echo "[✗] the previous version's unit fails systemd-analyze verify; nothing was changed" >&2
      exit 1
    fi
    swap_unit=1
  fi
  cur=$(readlink "$INSTALL_DIR/venv"); prev=$(readlink "$INSTALL_DIR/previous/venv"); prev=${prev#../}

  echo "[+] stopping $SVC_NAME"
  systemctl stop "$SVC_NAME" || true
  rm -f "$JOURNAL"
  mkdir "$INSTALL_DIR/next"; jmade "$INSTALL_DIR/next"
  local item
  for item in "${APP_ITEMS[@]}"; do
    [ -e "$INSTALL_DIR/$item" ] && jmv "$INSTALL_DIR/$item" "$INSTALL_DIR/next/$item"
  done
  for item in "${APP_ITEMS[@]}"; do
    [ -e "$INSTALL_DIR/previous/$item" ] && jmv "$INSTALL_DIR/previous/$item" "$INSTALL_DIR/$item"
  done
  for item in "${APP_ITEMS[@]}"; do
    [ -e "$INSTALL_DIR/next/$item" ] && jmv "$INSTALL_DIR/next/$item" "$INSTALL_DIR/previous/$item"
  done
  jlink "$INSTALL_DIR/venv" "$prev"
  jlink "$INSTALL_DIR/previous/venv" "../$cur"
  if [ -n "$swap_unit" ]; then
    cp -p "$UNIT_DST" "$INSTALL_DIR/next/$SVC_NAME.current"
    install_unit "$prev_unit"
  fi
  echo "[+] starting $SVC_NAME on $prev_v"
  start_service
  if wait_healthy; then
    [ -n "$swap_unit" ] && install -m 644 "$INSTALL_DIR/next/$SVC_NAME.current" "$prev_unit"
    # reference copies of the tools stay the newest ones
    rm -f "$JOURNAL"; rm -rf "$INSTALL_DIR/next"
    prune_unit_backups
    echo "[✓] switched to $prev_v; $cur_v is kept as the previous version (update.sh --rollback switches back)"
    kavita_note switch
    return 0
  fi
  echo "[✗] $prev_v didn't come up; switching back to $cur_v" >&2
  systemctl stop "$SVC_NAME" || true
  undo_journal
  start_service
  if wait_healthy; then
    echo "[✗] rollback failed; still running $cur_v, nothing changed. Check: journalctl -u $SVC_NAME -n 30" >&2
  else
    echo "[✗] rollback failed and $cur_v doesn't come up either. Files are back as before the rollback." >&2
    echo "    Check: journalctl -u $SVC_NAME -n 30 --no-pager" >&2
  fi
  exit 1
}

# ---------------------------------------------------------------- arguments
ALLOW_DOWNGRADE=""
ARGS=()
for a in "$@"; do
  if [ "$a" = --allow-downgrade ]; then ALLOW_DOWNGRADE=1; else ARGS+=("$a"); fi
done
set -- ${ARGS[@]+"${ARGS[@]}"}
case "${1:-}" in
  --status) show_status; exit 0 ;;
  --rollback)
    case "${2:-}" in --yes|-y) do_rollback 1 ;; "") do_rollback "" ;; *) echo "Usage: $0 --rollback [--yes]" >&2; exit 2 ;; esac
    exit 0 ;;
esac

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
  # `|| true`: under pipefail a grep with no match would end the script
  # before the empty-SOURCE check below.
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
    echo "Usage: $0 [--allow-downgrade] [<tarball-path-or-url>]" >&2
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
X="$TMPDIR/extract"
mkdir -p "$X"
tar -xzf "$TARBALL" -C "$X"

if [ ! -d "$X/app" ] || [ ! -f "$X/requirements.txt" ]; then
  echo "Tarball does not look like a kavita-epaper release (missing app/ or requirements.txt)" >&2
  exit 1
fi

# Cross-project guard: a tarball for a differently-named project (e.g. from
# before the kavita-boox rename) must not be applied to this install.
EXPECTED_PROJECT=$(basename "$INSTALL_DIR")
TARBALL_SVC=$(ls "$X/deploy/"*.service 2>/dev/null | head -1 || true)
if [ -n "$TARBALL_SVC" ]; then
  TARBALL_PROJECT=$(basename "${TARBALL_SVC%.service}")
  if [ "$TARBALL_PROJECT" != "$EXPECTED_PROJECT" ]; then
    echo "[✗] tarball ships '${TARBALL_PROJECT}.service' but install lives at ${INSTALL_DIR}" >&2
    echo "    cross-project updates aren't supported." >&2
    echo "    Use the new tarball's deploy/install.sh for a fresh install of '${TARBALL_PROJECT}'," >&2
    echo "    then remove the old install. See MIGRATION.md." >&2
    exit 1
  fi
fi

# Hand off to the tarball's update.sh only when it is newer than this one,
# so each release's own logic applies, but an older release never replaces
# this script. Runs as a child, not exec, so this process's EXIT trap still
# cleans up TMPDIR afterwards. The call and exit share one line because bash
# parses a whole line before running it, and the child may replace this
# file on disk.
INCOMING="$X/deploy/update.sh"
INCOMING_VERSION=$(script_version "$INCOMING")
if [ -z "${KAVITA_EPAPER_UPDATE_HANDOFF:-}" ] && [ -n "$INCOMING_VERSION" ] && \
   newer_than "$INCOMING_VERSION" "$UPDATE_SH_VERSION" && ! cmp -s "$INCOMING" "${BASH_SOURCE[0]}"; then
  echo "[+] handing off to the tarball's update.sh"
  KAVITA_EPAPER_UPDATE_HANDOFF=1 bash "$INCOMING" "$TARBALL" ${ALLOW_DOWNGRADE:+--allow-downgrade}; exit $?
fi

recover_if_interrupted

# Install the tarball's update.sh and configure only if they are at least as
# new as the installed ones (pre-0.7.23 tools have no version and count as
# older). An older release's tools are never installed.
INSTALLED_TOOLS_VERSION=$(script_version "$INSTALL_DIR/update.sh")
NEWER_TOOLS=""
if [ -n "$INCOMING_VERSION" ] && { [ -z "$INSTALLED_TOOLS_VERSION" ] || \
     ! newer_than "$INSTALLED_TOOLS_VERSION" "$INCOMING_VERSION"; }; then
  NEWER_TOOLS=1
fi

NEW_V=$(version_of "$X"); CUR_V=$(version_of "$INSTALL_DIR")
echo "[+] new version: $NEW_V"
echo "[+] current version: $CUR_V"
if [ "$NEW_V" = "$CUR_V" ]; then
  echo "[=] already on this version, nothing to do"
  exit 0
fi
if newer_than "$CUR_V" "$NEW_V"; then
  if [ -z "$ALLOW_DOWNGRADE" ]; then
    echo "[✗] the release you gave is $NEW_V, older than the installed $CUR_V; nothing was changed." >&2
    if [ -f "$INSTALL_DIR/previous/VERSION" ]; then
      echo "    To switch back to the kept previous version ($(version_of "$INSTALL_DIR/previous")): sudo $INSTALL_DIR/update.sh --rollback" >&2
    fi
    echo "    To install $NEW_V anyway, add --allow-downgrade to this command." >&2
    exit 1
  fi
  echo "[+] $NEW_V is older than $CUR_V (--allow-downgrade); installing its app, keeping update.sh and configure ${INSTALLED_TOOLS_VERSION:-$UPDATE_SH_VERSION}"
fi

# The app refuses to start without a real session secret (from 0.7.21).
# Check it before anything is stopped. Only the length is looked at; the
# value is never printed. A secret set in a unit drop-in counts too.
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
  echo "    $SVC_NAME was not stopped and is still running $CUR_V." >&2
  echo "    Generate a new one: sudo $INSTALL_DIR/configure new-secret" >&2
  echo "    (or set KAVITA_EPAPER_SECRET=<python3 -c 'import secrets; print(secrets.token_urlsafe(48))'>" >&2
  echo "    in $INSTALL_DIR/.env), then run this update again. A new secret signs everyone out once." >&2
  exit 1
fi

# Service unit: verified before anything is stopped. Local changes belong in
# a drop-in (systemctl edit), which this never touches.
UNIT_SRC="$X/deploy/$SVC_NAME"
UNIT_CHANGED=""
if [ -f "$UNIT_SRC" ] && ! cmp -s "$UNIT_SRC" "$UNIT_DST"; then
  echo "[+] service unit changed, verifying the new one"
  if ! verify_unit "$UNIT_SRC"; then
    echo "[✗] new $SVC_NAME failed systemd-analyze verify; nothing was changed" >&2
    exit 1
  fi
  UNIT_CHANGED=1
fi

# Venv: reuse one built for exactly these dependencies, or build a new one
# beside it while the current version keeps running. The live venv is never
# modified; a failed build changes nothing.
CUR_TARGET=$(venv_target)
same_file() {  # both missing, or both present and identical
  if [ -f "$1" ] || [ -f "$2" ]; then
    [ -f "$1" ] && [ -f "$2" ] && cmp -s "$1" "$2"
  fi
}
NEW_ID=$(deps_id "$X")
NEW_TARGET="venvs/$NEW_ID"
BUILT=""
if [ -f "$INSTALL_DIR/$NEW_TARGET/.complete" ]; then
  echo "[+] reusing the venv built for these dependencies ($NEW_TARGET)"
elif [ -n "$CUR_TARGET" ] && same_file "$INSTALL_DIR/requirements.txt" "$X/requirements.txt" && \
     same_file "$INSTALL_DIR/constraints.txt" "$X/constraints.txt"; then
  NEW_TARGET="$CUR_TARGET"
  echo "[+] requirements.txt and constraints.txt unchanged, keeping the current venv"
else
  echo "[+] dependencies changed, building $NEW_TARGET while $CUR_V keeps running"
  if ! build_venv "$NEW_ID" "$X"; then
    echo "[✗] building the new venv failed (pip, pip check or the version check);" >&2
    echo "    $SVC_NAME was not stopped and is still running $CUR_V. Nothing was changed." >&2
    exit 1
  fi
  BUILT=1
  echo "[+] built $NEW_TARGET"
fi

# Stage the new version next to the install, on the same filesystem, so the
# swap below is a handful of renames.
rm -rf "$INSTALL_DIR/next"
mkdir -p "$INSTALL_DIR/next"
cp -a "$X/app" "$INSTALL_DIR/next/app"
find "$INSTALL_DIR/next/app" -name __pycache__ -prune -exec rm -rf {} +
for f in VERSION requirements.txt constraints.txt; do
  [ -f "$X/$f" ] && install -m 644 "$X/$f" "$INSTALL_DIR/next/$f"
done
chown -R root:root "$INSTALL_DIR/next"; chmod -R go-w "$INSTALL_DIR/next"

echo "[+] stopping $SVC_NAME"
systemctl stop "$SVC_NAME" || true
rm -rf "$INSTALL_DIR/failed"
rm -f "$JOURNAL"

# ---- swap (journalled)
LEGACY_TARGET=""
if [ "$CUR_TARGET" = legacy ]; then
  LEGACY_TARGET="venvs/legacy-$(date +%Y%m%d-%H%M%S)"
  echo "[+] moving the existing venv to $LEGACY_TARGET (one-time layout change)"
  mkdir -p "$INSTALL_DIR/venvs"
  jmv "$INSTALL_DIR/venv" "$INSTALL_DIR/$LEGACY_TARGET"
  touch "$INSTALL_DIR/$LEGACY_TARGET/.complete"; jmade "$INSTALL_DIR/$LEGACY_TARGET/.complete"
  CUR_TARGET="$LEGACY_TARGET"
  [ "$NEW_TARGET" = legacy ] && NEW_TARGET="$LEGACY_TARGET"
fi
if [ -e "$INSTALL_DIR/previous" ]; then
  rm -rf "$INSTALL_DIR/previous.old"
  jmv "$INSTALL_DIR/previous" "$INSTALL_DIR/previous.old"
fi
mkdir "$INSTALL_DIR/previous"; jmade "$INSTALL_DIR/previous"
for item in "${APP_ITEMS[@]}"; do
  [ -e "$INSTALL_DIR/$item" ] && jmv "$INSTALL_DIR/$item" "$INSTALL_DIR/previous/$item"
done
[ -n "$CUR_TARGET" ] && ln -s "../$CUR_TARGET" "$INSTALL_DIR/previous/venv"
[ -f "$UNIT_DST" ] && cp -p "$UNIT_DST" "$INSTALL_DIR/previous/$SVC_NAME"
# reference copies only; the installed tools are never swapped back
for tool in update.sh configure; do
  [ -f "$INSTALL_DIR/$tool" ] && cp -p "$INSTALL_DIR/$tool" "$INSTALL_DIR/previous/$tool"
done
for item in "${APP_ITEMS[@]}"; do
  [ -e "$INSTALL_DIR/next/$item" ] && jmv "$INSTALL_DIR/next/$item" "$INSTALL_DIR/$item"
done
jlink "$INSTALL_DIR/venv" "$NEW_TARGET"
# update.sh and configure: only ever replaced by newer ones
if [ -n "$NEWER_TOOLS" ]; then
  for tool in update.sh configure; do
    if [ -f "$X/deploy/$tool" ]; then
      [ -f "$INSTALL_DIR/$tool" ] && jmv "$INSTALL_DIR/$tool" "$INSTALL_DIR/next/$tool.old"
      install -m 755 "$X/deploy/$tool" "$INSTALL_DIR/$tool"; jmade "$INSTALL_DIR/$tool"
    fi
  done
fi
[ -n "$UNIT_CHANGED" ] && install_unit "$UNIT_SRC"
[ -n "${KAVITA_EPAPER_TEST_DIE_AFTER_SWAP:-}" ] && { echo "[test] dying mid-update" >&2; kill -9 $$; }

echo "[+] starting $SVC_NAME"
start_service
if wait_healthy; then
  rm -rf "$INSTALL_DIR/previous.old" "$INSTALL_DIR/next"
  rm -f "$JOURNAL"
  cleanup_venvs
  prune_unit_backups
  echo "[✓] kavita-epaper updated to $NEW_V and running"
  echo "    previous version $CUR_V is kept (update.sh --rollback switches back)"
  systemctl status "$SVC_NAME" --no-pager | head -3 || true
  kavita_note update
  exit 0
fi

echo "[✗] $NEW_V didn't come up (not active, or $(check_url)/login didn't answer within ${HEALTH_WAIT} s)" >&2
echo "    Its log: journalctl -u $SVC_NAME -n 30 --no-pager" >&2
echo "[!] putting $CUR_V back: app, venv, unit, update.sh and configure" >&2
systemctl stop "$SVC_NAME" || true
undo_journal
mkdir -p "$INSTALL_DIR/failed"
for item in "${APP_ITEMS[@]}"; do
  [ -e "$INSTALL_DIR/next/$item" ] && mv -T "$INSTALL_DIR/next/$item" "$INSTALL_DIR/failed/$item"
done
rm -rf "$INSTALL_DIR/next"
cleanup_venvs
start_service
if wait_healthy; then
  echo "[✗] update to $NEW_V failed; rolled back, running $CUR_V again." >&2
  echo "    $NEW_V's code is kept in $INSTALL_DIR/failed/ until the next update." >&2
else
  echo "[✗] update to $NEW_V failed, and $CUR_V doesn't come up after putting it back either." >&2
  echo "    All files are as they were before this update. Check: journalctl -u $SVC_NAME -n 30 --no-pager" >&2
fi
exit 1
