#!/usr/bin/env bash
# install.sh: first-time deploy of kavita-epaper.
#
#   sudo bash ./deploy/install.sh [--kavita-url URL] [--overwrite-env]
#
# (Already root, for example in a Proxmox container? Leave out "sudo".)
#
# The Kavita address comes from --kavita-url, else $KAVITA_BASE_URL, else a
# prompt when run in a terminal, else http://127.0.0.1:5000. It is checked
# before anything is written; when not in a terminal an unreachable Kavita
# only gives a warning. An existing .env is kept unless --overwrite-env is
# given; the old one is then backed up to /var/backups and its secret kept.
# KAVITA_CA_BUNDLE and KAVITA_TLS_VERIFY from the environment go into a new
# .env too.
#
# Idempotent: safe to re-run from a freshly-extracted tarball to repair an
# install. For routine updates after the initial install, use update.sh
# (drops in a new tarball without touching .env or the cover cache).
#
# Needs a Debian-family host (Debian, Ubuntu, derivatives) with systemd and
# Python 3.10 or newer.

set -euo pipefail

INSTALL_DIR="/opt/kavita-epaper"
CACHE_DIR="/var/cache/kavita-epaper/covers"
RELEASES_DIR="/var/lib/kavita-epaper/releases"
BACKUP_DIR="/var/backups"
SERVICE_USER="kavita-epaper"
SVC_NAME="kavita-epaper.service"
SVC_FILE="/etc/systemd/system/kavita-epaper.service"
ENV_FILE="${INSTALL_DIR}/.env"
DEFAULT_KAVITA_URL="http://127.0.0.1:5000"
HEALTH_WAIT=20

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$( cd "${SCRIPT_DIR}/.." && pwd )"

usage() {
  echo "usage: install.sh [--kavita-url URL] [--overwrite-env]"
  echo "  --kavita-url URL   Kavita's address, e.g. http://192.0.2.20:5000 (or set KAVITA_BASE_URL)"
  echo "  --overwrite-env    replace an existing ${ENV_FILE} (backed up first; its secret is kept)"
}

KAVITA_URL_ARG=""
OVERWRITE_ENV=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kavita-url)
      [ $# -ge 2 ] || { echo "[✗] --kavita-url needs a value" >&2; usage >&2; exit 2; }
      KAVITA_URL_ARG="$2"; shift 2 ;;
    --kavita-url=*) KAVITA_URL_ARG="${1#*=}"; shift ;;
    --overwrite-env) OVERWRITE_ENV=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[✗] unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
KAVITA_URL_GIVEN="${KAVITA_URL_ARG:-${KAVITA_BASE_URL:-}}"

if [ "$(id -u)" -ne 0 ]; then
  echo "[✗] install.sh must run as root: sudo bash ./deploy/install.sh" >&2
  echo "    (in a root shell without sudo, run it without the sudo)" >&2
  exit 1
fi

# An existing .env is the source of truth; refuse to silently ignore a
# Kavita address given on the command line.
if [ -f "${ENV_FILE}" ] && [ -z "${OVERWRITE_ENV}" ] && [ -n "${KAVITA_URL_GIVEN}" ]; then
  echo "[✗] ${ENV_FILE} already exists, so the Kavita address you gave was not used." >&2
  echo "    To change it, edit KAVITA_BASE_URL in ${ENV_FILE}, then run: systemctl restart kavita-epaper" >&2
  echo "    Or rerun with --overwrite-env to write a new .env (the current one is backed up to" >&2
  echo "    ${BACKUP_DIR}, and its secret is kept so nobody is signed out). Nothing was changed." >&2
  exit 1
fi

# Value of KEY in an env file (last assignment wins), without quotes.
env_get() {
  local line
  line=$(grep -E "^[[:space:]]*$1=" "$2" 2>/dev/null | tail -1 || true)
  line=${line#*=}
  line=${line%\"}; line=${line#\"}; line=${line%\'}; line=${line#\'}
  printf '%s' "$line"
}

# Set KEY=VALUE in an env file: replaces the first "KEY=" or "#KEY=" line,
# otherwise appends. awk reads the value from the environment, so it is
# never parsed as a pattern or shell code.
env_set() {
  K="$1" V="$2" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"]; done = 0 }
    !done && (index($0, k "=") == 1 || index($0, "#" k "=") == 1) { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }' "$3" > "$3.tmp"
  mv "$3.tmp" "$3"
}

secret_ok() {
  [ "${#1}" -ge 32 ] && [ "$1" != "CHANGE_ME_TO_A_LONG_RANDOM_STRING" ]
}

normalize_url() {
  local u="$1"
  case "$u" in http://*|https://*) ;; *) u="http://$u" ;; esac
  printf '%s' "${u%/}"
}

echo "[+] installing kavita-epaper from ${REPO_DIR}"

# 1) ensure python3-venv + rsync are present
NEEDED_PKGS=""
for pkg in python3-venv python3-pip rsync; do
  dpkg -s "$pkg" >/dev/null 2>&1 || NEEDED_PKGS="$NEEDED_PKGS $pkg"
done
if [ -n "$NEEDED_PKGS" ]; then
  echo "[+] apt installing:$NEEDED_PKGS"
  apt-get update -qq
  apt-get install -y -qq $NEEDED_PKGS
fi

if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
  PYVER=$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || echo "missing")
  echo "[✗] kavita-epaper needs Python 3.10 or newer; python3 here is ${PYVER}." >&2
  echo "    Debian 12 and Ubuntu 22.04 or newer have it. Stopped before installing kavita-epaper." >&2
  exit 1
fi

# 2) service user
if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  echo "[+] creating system user ${SERVICE_USER}"
  useradd --system --no-create-home --shell /usr/sbin/nologin "${SERVICE_USER}"
fi

# 3) install dir + sync code
mkdir -p "${INSTALL_DIR}"
SYNC_FILES=("${REPO_DIR}/app" "${REPO_DIR}/requirements.txt")
[ -f "${REPO_DIR}/constraints.txt" ] && SYNC_FILES+=("${REPO_DIR}/constraints.txt")
# Sync the app/ tree and requirements only; keep .env if it exists
rsync -a --delete \
  --exclude='.git' --exclude='__pycache__' --exclude='.env' --exclude='venv' \
  --exclude='openapi.json' --exclude='deploy/' \
  "${SYNC_FILES[@]}" \
  "${INSTALL_DIR}/"

# Also drop the updater + version stamp into the install dir for future use
install -m 755 "${SCRIPT_DIR}/update.sh" "${INSTALL_DIR}/update.sh"
if [ -f "${REPO_DIR}/VERSION" ]; then
  cp "${REPO_DIR}/VERSION" "${INSTALL_DIR}/VERSION"
fi

# 4) venv + deps, with the tested versions of everything pulled in
if [ ! -d "${INSTALL_DIR}/venv" ]; then
  echo "[+] creating venv"
  python3 -m venv "${INSTALL_DIR}/venv"
fi
CONSTRAINTS=()
[ -f "${INSTALL_DIR}/constraints.txt" ] && CONSTRAINTS=(-c "${INSTALL_DIR}/constraints.txt")
echo "[+] installing Python packages"
"${INSTALL_DIR}/venv/bin/pip" install --disable-pip-version-check --quiet --upgrade pip
"${INSTALL_DIR}/venv/bin/pip" install --disable-pip-version-check --quiet \
  -r "${INSTALL_DIR}/requirements.txt" ${CONSTRAINTS[@]+"${CONSTRAINTS[@]}"}

# 5) cache + releases dirs
mkdir -p "${CACHE_DIR}"
chown -R "${SERVICE_USER}:${SERVICE_USER}" "${CACHE_DIR}"
# Releases dir is owned by root (only root runs update.sh anyway); the service
# user doesn't need to write to it.
mkdir -p "${RELEASES_DIR}"

# 6) Kavita address: test it with the app's own check before writing it.
CHECK_CA="" CHECK_TLS=""
kavita_test() {  # $1 url; sets CHECK_OUT; returns 0 when Kavita answers
  local rc=0
  CHECK_OUT=$(cd "${INSTALL_DIR}" && env PYTHONDONTWRITEBYTECODE=1 \
      KAVITA_CA_BUNDLE="${CHECK_CA}" KAVITA_TLS_VERIFY="${CHECK_TLS}" \
      "${INSTALL_DIR}/venv/bin/python" -m app.kavita_check "$1" 2>&1) || rc=$?
  return $rc
}

KAVITA_OK=""
if [ -f "${ENV_FILE}" ] && [ -z "${OVERWRITE_ENV}" ]; then
  ENV_ACTION=keep
  KAVITA_URL=$(env_get KAVITA_BASE_URL "${ENV_FILE}")
  KAVITA_URL=${KAVITA_URL:-$DEFAULT_KAVITA_URL}
  CHECK_CA=$(env_get KAVITA_CA_BUNDLE "${ENV_FILE}")
  CHECK_TLS=$(env_get KAVITA_TLS_VERIFY "${ENV_FILE}")
  echo "[+] keeping ${ENV_FILE}; checking its Kavita address ${KAVITA_URL}"
  kavita_test "${KAVITA_URL}" && KAVITA_OK=1
else
  ENV_ACTION=write
  CHECK_CA="${KAVITA_CA_BUNDLE:-}"
  CHECK_TLS="${KAVITA_TLS_VERIFY:-}"
  DEFAULT_URL="${DEFAULT_KAVITA_URL}"
  if [ -f "${ENV_FILE}" ]; then
    OLD_URL=$(env_get KAVITA_BASE_URL "${ENV_FILE}")
    DEFAULT_URL="${OLD_URL:-$DEFAULT_KAVITA_URL}"
  fi
  if [ -n "${KAVITA_URL_GIVEN}" ]; then
    KAVITA_URL=$(normalize_url "${KAVITA_URL_GIVEN}")
    echo "[+] checking Kavita at ${KAVITA_URL}"
    kavita_test "${KAVITA_URL}" && KAVITA_OK=1
  elif [ -t 0 ] && [ -t 1 ]; then
    echo
    echo "Where does Kavita run? Enter its address as this machine reaches it,"
    echo "for example http://192.0.2.20:5000. Press Enter for the default."
    KAVITA_URL="${DEFAULT_URL}"
    for attempt in 1 2 3; do
      printf 'Kavita address [%s]: ' "${KAVITA_URL}"
      ANSWER=""
      read -r ANSWER || true
      [ -n "${ANSWER}" ] && KAVITA_URL=$(normalize_url "${ANSWER}")
      if kavita_test "${KAVITA_URL}"; then
        KAVITA_OK=1
        break
      fi
      echo "    ${CHECK_OUT% \[*}"
    done
    if [ -z "${KAVITA_OK}" ]; then
      printf 'Kavita is not reachable at %s. Continue anyway? [y/N]: ' "${KAVITA_URL}"
      ANSWER=""
      read -r ANSWER || true
      case "${ANSWER}" in
        y|Y|yes|YES) ;;
        *) echo "[✗] stopped before writing ${ENV_FILE} or starting the service." >&2
           echo "    Rerun install.sh once you know Kavita's address." >&2
           exit 1 ;;
      esac
    fi
  else
    KAVITA_URL="${DEFAULT_URL}"
    echo "[+] no Kavita address given; checking ${KAVITA_URL}"
    kavita_test "${KAVITA_URL}" && KAVITA_OK=1
  fi
fi
if [ -n "${KAVITA_OK}" ]; then
  echo "[+] ${CHECK_OUT}"
else
  echo "[!] Kavita check failed: ${CHECK_OUT}" >&2
  echo "    Continuing; the app starts anyway and signs in once Kavita answers there." >&2
fi

# 7) env file: written only when missing or with --overwrite-env
if [ "${ENV_ACTION}" = write ]; then
  SECRET=""
  if [ -f "${ENV_FILE}" ]; then
    mkdir -p "${BACKUP_DIR}"
    BACKUP="${BACKUP_DIR}/kavita-epaper.env.$(date +%Y%m%d-%H%M%S)"
    [ -e "${BACKUP}" ] && BACKUP="${BACKUP}-$$"
    install -m 600 -o root -g root "${ENV_FILE}" "${BACKUP}"
    echo "[+] backed up ${ENV_FILE} to ${BACKUP}"
    # keep the newest 5 backups
    ls -1 "${BACKUP_DIR}"/kavita-epaper.env.* 2>/dev/null | sort | head -n -5 | while read -r OLD; do
      rm -f -- "${OLD}"
    done || true
    OLD_SECRET=$(env_get KAVITA_EPAPER_SECRET "${ENV_FILE}")
    if secret_ok "${OLD_SECRET}"; then
      SECRET="${OLD_SECRET}"
      echo "[+] keeping the existing session secret, so nobody is signed out"
    fi
    unset OLD_SECRET
  fi
  [ -n "${SECRET}" ] || SECRET="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
  echo "[+] writing ${ENV_FILE}"
  NEW_ENV=$(mktemp "${INSTALL_DIR}/.env.new.XXXXXX")
  chmod 600 "${NEW_ENV}"
  cp "${SCRIPT_DIR}/env.example" "${NEW_ENV}"
  env_set KAVITA_EPAPER_SECRET "${SECRET}" "${NEW_ENV}"
  env_set KAVITA_BASE_URL "${KAVITA_URL}" "${NEW_ENV}"
  [ -n "${CHECK_CA}" ] && env_set KAVITA_CA_BUNDLE "${CHECK_CA}" "${NEW_ENV}"
  [ -n "${CHECK_TLS}" ] && env_set KAVITA_TLS_VERIFY "${CHECK_TLS}" "${NEW_ENV}"
  unset SECRET
  chmod 600 "${NEW_ENV}"
  mv -f "${NEW_ENV}" "${ENV_FILE}"
fi

# 8) ownership: everything under the install dir belongs to root.
# update.sh runs as root and executes files from here (venv/bin/pip, the
# script itself), so anything the service user can write here is a path
# to root. The service only needs to read code and the venv; it never
# opens .env itself (systemd reads EnvironmentFile= as root before
# dropping to User=), so .env is root-only.
chown -R root:root "${INSTALL_DIR}"
chmod -R go-w "${INSTALL_DIR}"
chmod 600 "${ENV_FILE}"

# 9) systemd unit
echo "[+] installing systemd unit"
cp "${SCRIPT_DIR}/kavita-epaper.service" "${SVC_FILE}"
systemctl daemon-reload
systemctl enable "${SVC_NAME}" >/dev/null
systemctl restart "${SVC_NAME}"

# 10) wait until it serves the login page
HOST=$(env_get KAVITA_EPAPER_HOST "${ENV_FILE}"); HOST=${HOST:-0.0.0.0}
PORT=$(env_get KAVITA_EPAPER_PORT "${ENV_FILE}"); PORT=${PORT:-8095}
case "${HOST}" in
  0.0.0.0) CHECK_HOST=127.0.0.1 ;;
  ::|"[::]") CHECK_HOST="[::1]" ;;
  *:*) CHECK_HOST="[${HOST}]" ;;
  *) CHECK_HOST="${HOST}" ;;
esac
LOGIN_URL="http://${CHECK_HOST}:${PORT}/login"
echo "[+] waiting for ${LOGIN_URL}"
UP="" FAILED=""
for _ in $(seq 1 $((HEALTH_WAIT * 2))); do
  if systemctl is-active --quiet "${SVC_NAME}" && \
     "${INSTALL_DIR}/venv/bin/python" -c 'import sys, urllib.request; urllib.request.urlopen(sys.argv[1], timeout=2)' \
       "${LOGIN_URL}" >/dev/null 2>&1; then
    UP=1
    break
  fi
  if systemctl is-failed --quiet "${SVC_NAME}"; then FAILED=1; break; fi
  sleep 0.5
done
if [ -z "${UP}" ]; then
  STATUS=$(systemctl show -p ExecMainStatus --value "${SVC_NAME}" 2>/dev/null || true)
  if [ -n "${FAILED}" ]; then
    echo "[✗] kavita-epaper stopped right after starting (exit status ${STATUS:-unknown})." >&2
  else
    echo "[✗] kavita-epaper didn't answer at ${LOGIN_URL} within ${HEALTH_WAIT} s." >&2
  fi
  if [ "${STATUS}" = 78 ]; then
    echo "    It refused to start because of a setting; the log says which." >&2
  fi
  echo "    Check: journalctl -u kavita-epaper -n 30 --no-pager" >&2
  exit 1
fi

# 11) summary
echo
echo "[✓] kavita-epaper is installed and running."
case "${HOST}" in
  0.0.0.0|::|"[::]")
    LABEL="Open:     "
    for ip in $(hostname -I 2>/dev/null || true); do
      case "$ip" in
        fe80:*) continue ;;
        *:*) echo "    ${LABEL} http://[${ip}]:${PORT}" ;;
        *) echo "    ${LABEL} http://${ip}:${PORT}" ;;
      esac
      LABEL="          "
    done
    if [ "${LABEL}" = "Open:     " ]; then
      echo "    Open:      http://<this machine's IP>:${PORT}"
    fi ;;
  127.*|localhost|::1)
    echo "    Listening on ${HOST}:${PORT} only (loopback); open it through your reverse proxy." ;;
  *)
    echo "    Open:      http://${HOST}:${PORT}" ;;
esac
echo "    Sign in with your Kavita username and password."
if [ -n "${KAVITA_OK}" ]; then
  echo "    Kavita:    reachable at ${KAVITA_URL}"
else
  echo "    Kavita:    not reachable at ${KAVITA_URL}"
  echo "               Fix KAVITA_BASE_URL in ${ENV_FILE}, then: systemctl restart kavita-epaper"
fi
echo "    Settings:  ${ENV_FILE}"
echo "    Logs:      journalctl -u kavita-epaper -f"
echo
echo "For HTTPS, put a reverse proxy in front (NPM, Caddy, Traefik): see the"
echo "README's Reverse proxy and Security sections."
