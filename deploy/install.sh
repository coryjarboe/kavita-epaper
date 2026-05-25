#!/usr/bin/env bash
# install.sh — first-time deploy of kavita-epaper.
#
# Idempotent: safe to re-run from a freshly-extracted tarball to repair an
# install. For routine updates after the initial install, use update.sh
# (drops in a new tarball without touching .env or the cover cache).
#
# Assumes a Debian-family host (Debian, Ubuntu, derivatives) with python3
# and systemd.

set -euo pipefail

INSTALL_DIR="/opt/kavita-epaper"
CACHE_DIR="/var/cache/kavita-epaper/covers"
RELEASES_DIR="/var/lib/kavita-epaper/releases"
SERVICE_USER="kavita-epaper"
SVC_FILE="/etc/systemd/system/kavita-epaper.service"
ENV_FILE="${INSTALL_DIR}/.env"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$( cd "${SCRIPT_DIR}/.." && pwd )"

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

# 2) service user
if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  echo "[+] creating system user ${SERVICE_USER}"
  useradd --system --no-create-home --shell /usr/sbin/nologin "${SERVICE_USER}"
fi

# 3) install dir + sync code
mkdir -p "${INSTALL_DIR}"
# Sync the app/ tree and requirements only — keep .env if it exists
rsync -a --delete \
  --exclude='.git' --exclude='__pycache__' --exclude='.env' --exclude='venv' \
  --exclude='openapi.json' --exclude='deploy/' \
  "${REPO_DIR}/app" "${REPO_DIR}/requirements.txt" \
  "${INSTALL_DIR}/"

# Also drop the updater + version stamp into the install dir for future use
install -m 755 "${SCRIPT_DIR}/update.sh" "${INSTALL_DIR}/update.sh"
if [ -f "${REPO_DIR}/VERSION" ]; then
  cp "${REPO_DIR}/VERSION" "${INSTALL_DIR}/VERSION"
fi

# 4) venv + deps
if [ ! -d "${INSTALL_DIR}/venv" ]; then
  echo "[+] creating venv"
  python3 -m venv "${INSTALL_DIR}/venv"
fi
"${INSTALL_DIR}/venv/bin/pip" install --quiet --upgrade pip
"${INSTALL_DIR}/venv/bin/pip" install --quiet -r "${INSTALL_DIR}/requirements.txt"

# 5) cache + releases dirs
mkdir -p "${CACHE_DIR}"
chown -R "${SERVICE_USER}:${SERVICE_USER}" "${CACHE_DIR}"
# Releases dir is owned by root (only root runs update.sh anyway); the service
# user doesn't need to write to it.
mkdir -p "${RELEASES_DIR}"

# 6) env file (only if missing — never overwrite existing config)
if [ ! -f "${ENV_FILE}" ]; then
  echo "[+] creating ${ENV_FILE} from template"
  cp "${SCRIPT_DIR}/env.example" "${ENV_FILE}"
  # generate a real secret
  SECRET="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
  sed -i "s|CHANGE_ME_TO_A_LONG_RANDOM_STRING|${SECRET}|" "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
fi
chown "${SERVICE_USER}:${SERVICE_USER}" "${ENV_FILE}"

# 7) systemd unit
echo "[+] installing systemd unit"
cp "${SCRIPT_DIR}/kavita-epaper.service" "${SVC_FILE}"
systemctl daemon-reload
systemctl enable kavita-epaper.service >/dev/null
systemctl restart kavita-epaper.service

# 8) ownership of install dir
chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}"

echo
echo "[✓] kavita-epaper installed."
echo "    listening on:   http://0.0.0.0:8095 (all interfaces)"
echo "    env file:       ${ENV_FILE}"
echo "    service:        systemctl status kavita-epaper"
echo "    logs:           journalctl -u kavita-epaper -f"
echo
echo "Next: add a reverse proxy host (NPM/Caddy/Traefik/etc) pointing to"
echo "      http://<this-host-ip>:8095. If your reverse proxy runs on this"
echo "      same host, you can bind loopback-only by setting"
echo "      KAVITA_EPAPER_HOST=127.0.0.1 in ${ENV_FILE}"
echo "      and running: systemctl restart kavita-epaper"
