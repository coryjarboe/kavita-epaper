#!/bin/bash
# install.sh harness: runs a copy of deploy/install.sh with every system path
# redirected under a scratch directory. apt-get, dpkg, useradd, chown (for the
# service user), id, hostname and python3's version check are stubbed;
# systemctl is a stub that really starts the installed app (from the scratch
# install, on 127.0.0.1:18295) so the health wait, exit status 78 and port
# clashes are real. Kavita is kavita_stub.py on 127.0.0.1:18396; 18399 is
# closed, and the built-in default Kavita address is redirected there, so the
# real Kavita is never contacted. The live install, units, cover cache and
# backups are never touched.
# Usage: tests/install_harness.sh [work-dir]. See tests/README.md.
set -u
R=$(cd "$(dirname "$0")/.." && pwd)
H=${1:-$(mktemp -d -t kavita-epaper-install-XXXXXX)}
rm -rf "$H"; mkdir -p "$H/bin" "$H/backups"
H=$(cd "$H" && pwd)
APP_PORT=18295 KAVITA=http://127.0.0.1:18396 DEAD=http://127.0.0.1:18399
echo "== work dir $H"
for p in $APP_PORT 18396 18399; do
  if ss -ltn | grep -qE ":$p\b"; then echo "port $p is in use; aborting"; exit 1; fi
done

redirect() {
  sed -e "s#/opt/kavita-epaper#$H/opt/kavita-epaper#g" -e "s#/var/cache/kavita-epaper#$H/cache#g" \
      -e "s#/var/lib/kavita-epaper#$H/lib#g" -e "s#/etc/systemd/system/#$H/etc/#g" \
      -e "s#/var/backups#$H/backups#g" -e "s#http://127.0.0.1:5000#$DEAD#g" "$1"
}
T="$H/tree"; mkdir -p "$T"
(cd "$R" && git ls-files -z --cached --others --exclude-standard | xargs -0 -I{} cp --parents {} "$T/")
redirect "$R/deploy/install.sh" > "$T/deploy/install.sh"
redirect "$R/deploy/configure" > "$T/deploy/configure"; chmod 755 "$T/deploy/configure"
redirect "$R/deploy/env.example" | sed -e "s/^#KAVITA_EPAPER_PORT=8095$/KAVITA_EPAPER_PORT=$APP_PORT/" > "$T/deploy/env.example"
n=$(grep -vE '^\s*#' "$T/deploy/install.sh" | grep -cE '(^|[^/a-z0-9])/(opt|var/cache|var/lib|etc|var/backups)/|127\.0\.0\.1:5000')
echo "live paths left in install.sh: $n"
[ "$n" = 0 ] || { echo "FAIL  install.sh still references live paths; aborting"; exit 1; }
grep -q "^KAVITA_EPAPER_PORT=$APP_PORT$" "$T/deploy/env.example" && ! grep -q '/var/cache/kavita-epaper' "$T/deploy/env.example" \
  || { echo "FAIL  env.example not redirected; aborting"; exit 1; }

# One real venv, shared by the scenarios (the fresh-install scenario builds its own).
echo "[harness] building the shared venv"
python3 -m venv "$H/venv-shared" && "$H/venv-shared/bin/pip" install --disable-pip-version-check --quiet \
  -r "$R/requirements.txt" -c "$R/constraints.txt" || { echo "venv build failed"; exit 1; }
REAL_PY=$(command -v python3)

# ---------------------------------------------------------------- stubs
export H APP_PORT REAL_PY PATH="$H/bin:$PATH"
cat > "$H/bin/apt-get" <<'EOF'
#!/bin/bash
echo "apt-get $*" >> "$H/calls"
EOF
cat > "$H/bin/dpkg" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$H/bin/useradd" <<'EOF'
#!/bin/bash
echo "useradd $*" >> "$H/calls"; touch "$H/user-created"
EOF
cat > "$H/bin/id" <<'EOF'
#!/bin/bash
if [ "$#" = 1 ] && [ "$1" = -u ]; then echo "${FAKE_UID:-$(/usr/bin/id -u)}"; exit 0; fi
if [ "$#" = 2 ] && [ "$1" = -u ] && [ "$2" = kavita-epaper ]; then
  [ -e "$H/user-created" ] && { echo 999; exit 0; } || exit 1
fi
exec /usr/bin/id "$@"
EOF
cat > "$H/bin/chown" <<'EOF'
#!/bin/bash
for a in "$@"; do case "$a" in kavita-epaper:*) echo "chown $*" >> "$H/calls"; exit 0;; esac; done
exec /usr/bin/chown "$@"
EOF
cat > "$H/bin/hostname" <<'EOF'
#!/bin/bash
[ "${1:-}" = -I ] && { echo "192.0.2.44 2001:db8::44 fe80::1 "; exit 0; }
exec /usr/bin/hostname "$@"
EOF
cat > "$H/bin/python3" <<'EOF'
#!/bin/bash
if [ -n "${FAKE_PY_OLD:-}" ]; then
  case "$*" in
    *"version_info >= (3, 10)"*) exit 1 ;;
    *"version_info[:3]"*) echo 3.9.2; exit 0 ;;
  esac
fi
exec "$REAL_PY" "$@"
EOF
# systemctl: really runs the installed app, as the unit would (EnvironmentFile,
# WorkingDirectory), but always on 127.0.0.1 and the scratch cover cache.
cat > "$H/bin/run-app" <<'EOF'
#!/bin/bash
cd "$H/opt/kavita-epaper" || exit 1
while IFS= read -r line; do
  case "$line" in ''|\#*) continue ;; *=*) v=${line#*=}; v=${v%\"}; v=${v#\"}; export "${line%%=*}=$v" ;; esac
done < .env
export KAVITA_EPAPER_COVER_CACHE="$H/cache/covers" PYTHONDONTWRITEBYTECODE=1
venv/bin/uvicorn app.main:app --host 127.0.0.1 --port "${KAVITA_EPAPER_PORT:-8095}" \
  --proxy-headers --forwarded-allow-ips "${KAVITA_EPAPER_FORWARDED_ALLOW_IPS:-*}" >> "$H/app.log" 2>&1
echo $? > "$H/app.exit"
EOF
cat > "$H/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$H/calls"
alive() { [ -f "$H/app.pid" ] && kill -0 "$(cat "$H/app.pid")" 2>/dev/null; }
stop_app() {
  if alive; then pkill -TERM -P "$(cat "$H/app.pid")" 2>/dev/null; kill "$(cat "$H/app.pid")" 2>/dev/null
    for _ in $(seq 50); do alive || break; sleep 0.1; done; fi
  # like systemd, return only once the app itself is gone (its port is free)
  for _ in $(seq 100); do ss -ltn | grep -qE ":$APP_PORT\b" || break; sleep 0.1; done
  rm -f "$H/app.pid"
}
case "$1" in
  restart|start)
    stop_app; rm -f "$H/app.exit"
    setsid "$H/bin/run-app" < /dev/null > /dev/null 2>&1 & echo $! > "$H/app.pid" ;;
  stop) stop_app ;;
  is-active) alive && [ ! -f "$H/app.exit" ] ;;
  is-failed) [ -f "$H/app.exit" ] && [ "$(cat "$H/app.exit")" != 0 ] ;;
  show) [ -f "$H/app.exit" ] && cat "$H/app.exit" || echo 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$H/bin/"*

# ---------------------------------------------------------------- Kavita stub
"$H/venv-shared/bin/python" -I "$R/tests/kavita_stub.py" 18396 & STUB=$!
trap 'kill $STUB 2>/dev/null; [ -f "$H/app.pid" ] && "$H/bin/systemctl" stop >/dev/null 2>&1' EXIT
for _ in $(seq 50); do "$H/venv-shared/bin/python" -c "import urllib.request; urllib.request.urlopen('$KAVITA/api/health')" 2>/dev/null && break; sleep 0.1; done

# ---------------------------------------------------------------- scenario helpers
I="$H/opt/kavita-epaper"
PASS=0; FAIL=0; BAD=""
setup() {  # $1: fresh (real venv) | shared (venv symlinked to the shared one)
  "$H/bin/systemctl" stop >/dev/null 2>&1
  rm -rf "$H/opt" "$H/etc" "$H/cache" "$H/lib" "$H/calls" "$H/app.log" "$H/app.exit" "$H/user-created" "$H/out"
  rm -f "$H/backups/"*
  mkdir -p "$H/etc" "$I"
  [ "$1" = shared ] && ln -s "$H/venv-shared" "$I/venv"
  : > "$H/calls"
}
write_env() {  # $1 url, $2 secret, [$3 extra line]
  { echo "KAVITA_BASE_URL=$1"; echo "KAVITA_EPAPER_SECRET=$2"; echo "KAVITA_EPAPER_PORT=$APP_PORT"
    [ -n "${3:-}" ] && echo "$3"; } > "$I/.env"
  chmod 600 "$I/.env"
}
install_run() {  # args to install.sh; env from the caller
  bash "$T/deploy/install.sh" "$@" > "$H/out" 2>&1; RC=$?
}
install_tty() {  # $1 input lines, rest: args
  local input="$1"; shift
  printf '%b' "$input" | script -qefc "bash $T/deploy/install.sh $*" /dev/null > "$H/out" 2>&1; RC=$?
  sed -i 's/\r$//' "$H/out"
}
ok() { if [ "$1" = 0 ]; then return; fi; BAD="${BAD}${BAD:+; }$2"; }
expect() {  # $1 description, then a test command
  local d="$1"; shift
  if "$@"; then :; else BAD="${BAD}${BAD:+; }$d"; fi
}
has() { grep -qE -- "$1" "$H/out"; }
lacks() { ! grep -qE -- "$1" "$H/out"; }
envval() { grep -E "^$1=" "$I/.env" | tail -1 | cut -d= -f2-; }
login_ok() { "$H/venv-shared/bin/python" -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$APP_PORT/login', timeout=3)" 2>/dev/null; }
finish() {  # $1 label
  if [ -z "$BAD" ]; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1: $BAD"; FAIL=$((FAIL+1)); fi
  echo "      rc=$RC"; grep -E '^\[|^    |^Kavita address|^Where does|^Continue' "$H/out" | sed "s#$H#<H>#g; s/^/      /"
  BAD=""
}
mode_owner() { stat -c '%a %U:%G' "$1" 2>/dev/null; }

# ---------------------------------------------------------------- scenarios
setup fresh
install_run --kavita-url "$KAVITA"
expect "rc 0" [ "$RC" = 0 ]
expect "check mark" has '^\[✓\] kavita-epaper is installed and running\.'
expect "venv -> venvs/<id>" bash -c "[[ \$(readlink '$I/venv') =~ ^venvs/[0-9a-f]{12}$ ]]"
expect "venv marked complete" test -f "$I/venv/.complete"
expect "configure installed 755" bash -c "cmp -s '$I/configure' '$T/deploy/configure' && [ \$(stat -c %a '$I/configure') = 755 ]"
expect "no previous/ on a fresh install" test ! -e "$I/previous"
expect ".env root 600" [ "$(mode_owner "$I/.env")" = "600 root:root" ]
expect ".env URL" [ "$(envval KAVITA_BASE_URL)" = "$KAVITA" ]
expect "64-char secret" [ "$(envval KAVITA_EPAPER_SECRET | tr -d '\n' | wc -c)" = 64 ]
expect "Kavita reachable line" has "Kavita: +reachable at $KAVITA"
expect "LAN IPv4 address" has "Open: +http://192.0.2.44:$APP_PORT"
expect "LAN IPv6 address" has "http://\[2001:db8::44\]:$APP_PORT"
expect "no link-local" lacks 'fe80'
expect "sign-in line" has 'Sign in with your Kavita username and password\.'
expect "service user created" grep -q '^useradd ' "$H/calls"
expect "unit installed" test -f "$H/etc/kavita-epaper.service"
expect "app really serves /login" login_ok
expect "constraints.txt installed" cmp -s "$I/constraints.txt" "$R/constraints.txt"
finish "I1 fresh install, --kavita-url reachable"

setup shared
KAVITA_BASE_URL="127.0.0.1:18396/" install_run
expect "rc 0" [ "$RC" = 0 ]
expect "URL from env, scheme added, slash dropped" [ "$(envval KAVITA_BASE_URL)" = "$KAVITA" ]
expect "check mark" has '^\[✓\]'
finish "I2 fresh install, KAVITA_BASE_URL from the environment"

setup shared
install_tty "127.0.0.1:18399\n$KAVITA\n"
expect "rc 0" [ "$RC" = 0 ]
expect "prompt shown with default" has "Kavita address \[$DEAD\]:"
expect "first answer refused" has 'refused: http://127.0.0.1:18399: connection refused'
expect "prompt hides the error chain" lacks 'Kavita address .*ConnectError'
expect "second answer saved" [ "$(envval KAVITA_BASE_URL)" = "$KAVITA" ]
expect "reachable" has "Kavita: +reachable at $KAVITA"
finish "I3 terminal prompt: wrong address, then the right one"

setup shared
install_tty "\n\n\nn\n"
expect "rc 1" [ "$RC" = 1 ]
expect "asked to continue" has 'Continue anyway\? \[y/N\]'
expect "stopped message" has 'stopped before writing .* or starting the service'
expect "no .env" test ! -e "$I/.env"
expect "service never started" bash -c "! grep -qE '^systemctl (restart|start)' '$H/calls'"
finish "I4 terminal prompt: three failures, then no"

setup shared
install_run < /dev/null
expect "rc 0" [ "$RC" = 0 ]
expect "warning" has '^\[!\] Kavita check failed: refused'
expect "continued and running" has '^\[✓\]'
expect "summary not reachable" has "Kavita: +not reachable at $DEAD"
expect "fix hint" has 'Fix it: sudo .*/opt/kavita-epaper/configure kavita-url <address>'
expect "default written" [ "$(envval KAVITA_BASE_URL)" = "$DEAD" ]
finish "I5 not a terminal, Kavita unreachable: warn and continue"

setup shared
write_env "$KAVITA" "$(printf 'k%.0s' $(seq 48))"
SUM=$(sha256sum "$I/.env")
install_run --kavita-url http://127.0.0.1:18300
expect "rc 1" [ "$RC" = 1 ]
expect "refusal" has 'already exists, so the Kavita address you gave was not used'
expect "configure hint" has 'To change it: sudo .*/opt/kavita-epaper/configure kavita-url http://127.0.0.1:18300'
expect "overwrite hint" has 'rerun with --overwrite-env'
expect ".env unchanged" [ "$(sha256sum "$I/.env")" = "$SUM" ]
expect "nothing else ran" [ ! -s "$H/calls" ]
finish "I6 existing .env plus --kavita-url: refused, nothing changed"

setup shared
write_env "$KAVITA" "$(printf 'k%.0s' $(seq 48))" "KAVITA_EPAPER_HOST=127.0.0.1"
SUM=$(sha256sum "$I/.env")
install_run
expect "rc 0" [ "$RC" = 0 ]
expect "keeping .env" has 'keeping .*/\.env; checking its Kavita address'
expect ".env unchanged" [ "$(sha256sum "$I/.env")" = "$SUM" ]
expect "reachable" has "Kavita: +reachable at $KAVITA"
expect "loopback summary" has "Listening on 127.0.0.1:$APP_PORT only \(loopback\)"
finish "I7 rerun with an existing .env: kept, its address checked"

setup shared
OLD_SECRET=$(printf 'o%.0s' $(seq 50))
write_env "$DEAD" "$OLD_SECRET"
cp "$I/.env" "$H/old.env"
for d in 01 02 03 04 05 06; do echo old > "$H/backups/kavita-epaper.env.200001${d}-000000"; done
install_run --overwrite-env --kavita-url "$KAVITA"
NEWEST=$(ls -1 "$H/backups"/kavita-epaper.env.* | sort | tail -1)
expect "rc 0" [ "$RC" = 0 ]
expect "backup message" has 'backed up .*/\.env to .*/backups/kavita-epaper\.env\.'
expect "backup = old .env" cmp -s "$NEWEST" "$H/old.env"
expect "backup root 600" [ "$(mode_owner "$NEWEST")" = "600 root:root" ]
expect "5 backups kept" [ "$(ls -1 "$H/backups" | wc -l)" = 5 ]
expect "oldest pruned" test ! -e "$H/backups/kavita-epaper.env.20000101-000000"
expect "new URL" [ "$(envval KAVITA_BASE_URL)" = "$KAVITA" ]
expect "secret kept" [ "$(envval KAVITA_EPAPER_SECRET)" = "$OLD_SECRET" ]
expect "secret never printed" lacks "$OLD_SECRET"
finish "I8 --overwrite-env: backed up (5 kept), new URL, secret kept"

setup shared
write_env "$KAVITA" "too-short"
install_run
expect "rc 1" [ "$RC" = 1 ]
expect "no check mark" lacks '^\[✓\]'
expect "stopped at once, exit 78" has 'stopped right after starting \(exit status 78\)'
expect "exit 78 explained" has 'refused to start because of a setting'
expect "journal hint" has 'journalctl -u kavita-epaper -n 30 --no-pager'
expect "app said why" grep -q 'KAVITA_EPAPER_SECRET is too short' "$H/app.log"
finish "I9 existing .env with a short secret: app refuses (78), install says so"

setup shared
"$H/venv-shared/bin/python" -c "import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', $APP_PORT)); s.listen(); time.sleep(60)" & BLOCK=$!
sleep 0.5
install_run --kavita-url "$KAVITA"
kill $BLOCK 2>/dev/null; wait $BLOCK 2>/dev/null
expect "rc 1" [ "$RC" = 1 ]
expect "no check mark" lacks '^\[✓\]'
expect "stopped at once, exit 1" has 'stopped right after starting \(exit status 1\)'
expect "journal hint" has 'journalctl -u kavita-epaper'
expect "no setting claim" lacks 'because of a setting'
finish "I10 port already in use: no check mark, journal hint"

setup shared
FAKE_UID=1000 install_run --kavita-url "$KAVITA"
expect "rc 1" [ "$RC" = 1 ]
expect "root message" has 'must run as root'
expect "nothing ran" [ ! -s "$H/calls" ]
expect "no .env" test ! -e "$I/.env"
finish "I11 not root: refused before anything"

setup shared
FAKE_PY_OLD=1 install_run --kavita-url "$KAVITA"
expect "rc 1" [ "$RC" = 1 ]
expect "python message" has 'needs Python 3\.10 or newer; python3 here is 3\.9\.2'
expect "no user created" bash -c "! grep -q '^useradd' '$H/calls'"
expect "nothing synced" test ! -e "$I/app"
finish "I12 Python 3.9: refused before installing"

setup shared
KAVITA_TLS_VERIFY=false install_run --kavita-url "$KAVITA"
expect "rc 0" [ "$RC" = 0 ]
expect "KAVITA_TLS_VERIFY written" [ "$(envval KAVITA_TLS_VERIFY)" = false ]
expect "app warned" grep -q "KAVITA_TLS_VERIFY=false: Kavita's TLS certificate is not checked" "$H/app.log"
finish "I13 KAVITA_TLS_VERIFY from the environment goes into .env"

setup shared
KAVITA_CA_BUNDLE="$H/no-such-ca.pem" install_run --kavita-url "$KAVITA"
expect "rc 1" [ "$RC" = 1 ]
expect "check reported the setting" has 'Kavita check failed: tls-config: KAVITA_CA_BUNDLE=.* is not a file'
expect "KAVITA_CA_BUNDLE written" [ "$(envval KAVITA_CA_BUNDLE)" = "$H/no-such-ca.pem" ]
expect "exit 78 explained" has 'exit status 78\)'
finish "I14 missing KAVITA_CA_BUNDLE: install warns, app refuses (78)"

setup shared
write_env "$KAVITA" "$(printf 'k%.0s' $(seq 48))"
printf '#!/bin/bash\nUPDATE_SH_VERSION="0.7.99"\n' > "$I/update.sh"; echo newer > "$I/configure"
cp "$I/update.sh" "$H/newer-update.sh"
install_run
expect "rc 0" [ "$RC" = 0 ]
expect "keeps newer tools" has 'keeping the installed update.sh and configure \(0\.7\.99'
expect "update.sh untouched" cmp -s "$I/update.sh" "$H/newer-update.sh"
expect "configure untouched" [ "$(cat "$I/configure")" = newer ]
finish "I15 rerun over newer update.sh/configure: never downgraded"

"$H/bin/systemctl" stop >/dev/null 2>&1
echo "== $PASS PASS, $FAIL FAIL of $((PASS+FAIL))"
[ "$FAIL" = 0 ]
