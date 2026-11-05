#!/bin/bash
# update.sh and configure harness (0.7.23).
#
# Runs copies of deploy/update.sh, deploy/configure and v0.7.22's update.sh
# with every system path redirected under a scratch directory. systemctl is a
# stub that really starts the installed app (on 127.0.0.1:18295), so the
# health check (active + /login 200), rollbacks and configure's restore are
# real. pip runs offline from a local wheelhouse (PIP_NO_INDEX), which also
# proves --rollback needs no network. Kavita is kavita_stub.py on 18396.
# The live install, units, cover cache and backups are never touched.
# Usage: tests/update_harness.sh [work-dir]. Needs network once to fill the
# wheelhouse (pip download), plus git, rsync, script and systemd-analyze.
set -u
R=$(cd "$(dirname "$0")/.." && pwd)
H=${1:-$(mktemp -d -t kavita-epaper-update-XXXXXX)}
rm -rf "$H"; mkdir -p "$H"; H=$(cd "$H" && pwd)
APP_PORT=18295 KAVITA=http://127.0.0.1:18396 DEAD=http://127.0.0.1:18399 OLD_REF=v0.7.22
echo "== work dir $H"
for p in $APP_PORT 18396 18399; do
  if ss -ltn | grep -qE ":$p\b"; then echo "port $p is in use; aborting"; exit 1; fi
done
I="$H/opt/kavita-epaper"

redirect() {
  sed -e "s#/opt/kavita-epaper#$H/opt/kavita-epaper#g" -e "s#/etc/systemd/system/#$H/etc/#g" \
      -e "s#/var/backups#$H/backups#g" -e "s#/var/lib/kavita-epaper#$H/lib#g" \
      -e "s#/var/cache/kavita-epaper#$H/cache#g" -e 's/^HEALTH_WAIT=20$/HEALTH_WAIT=8/' "$1"
}
live_paths() {  # count live paths outside comments
  grep -vE '^\s*#' "$1" | grep -cE '(^|[^/a-zA-Z0-9_.-])/(opt|etc/systemd|var/backups|var/lib|var/cache)/'
}

# ---------------------------------------------------------------- wheelhouse, tool venv
mkdir -p "$H/wheels" "$H/no-wheels"
echo "[harness] filling the wheelhouse"
python3 -m venv "$H/dl" && "$H/dl/bin/pip" download --disable-pip-version-check --quiet \
  -r "$R/requirements.txt" -c "$R/constraints.txt" -d "$H/wheels" || { echo "pip download failed"; exit 1; }
export PIP_NO_INDEX=1 PIP_FIND_LINKS="$H/wheels" PIP_DISABLE_PIP_VERSION_CHECK=1
python3 -m venv "$H/tools" && "$H/tools/bin/pip" install --quiet -r "$R/requirements.txt" -c "$R/constraints.txt" \
  || { echo "tool venv failed"; exit 1; }

# ---------------------------------------------------------------- release trees
TAR_LIST=$(grep -oE '\./\.gitignore .* \./app' "$R/.github/workflows/release.yml")
mk_tarball() {  # NAME [VERSION] [mod-function]
  local name="$1" ver="${2:-}" mod="${3:-}" T="$H/tree-$1"
  rm -rf "$T"; mkdir -p "$T"
  (cd "$R" && git ls-files -z --cached --others --exclude-standard | xargs -0 -I{} cp --parents {} "$T/")
  redirect "$R/deploy/update.sh" > "$T/deploy/update.sh"
  redirect "$R/deploy/configure" > "$T/deploy/configure"
  chmod 755 "$T/deploy/update.sh" "$T/deploy/configure"
  if [ -n "$ver" ]; then
    echo "$ver" > "$T/VERSION"
    sed -i "s/^UPDATE_SH_VERSION=\"[0-9.]*\"$/UPDATE_SH_VERSION=\"$ver\"/" "$T/deploy/update.sh"
  fi
  [ -n "$mod" ] && (cd "$T" && $mod)
  (cd "$T" && tar -czf "$H/rel/$name.tar.gz" --owner=0 --group=0 $TAR_LIST)
}
mkdir -p "$H/rel"
deps_b() { echo "# harness: dependency set b" >> constraints.txt; }
deps_c() { echo "# harness: dependency set c" >> constraints.txt; }
note_24() { echo "# harness: 0.7.24" >> app/main.py; }
broken_import() { sed -i '0,/^import asyncio$/s//raise RuntimeError("harness: broken build")\nimport asyncio/' app/main.py; }
broken_login() { python3 - <<'PY'
s = open("app/main.py").read()
s = s.replace('    message, hint = _login_error_text(', '    raise RuntimeError("harness: broken login")\n    message, hint = _login_error_text(', 1)
open("app/main.py", "w").write(s)
PY
}
unit_change() { echo "# harness: unit change" >> deploy/kavita-epaper.service; }
unit_typo() { sed -i 's/^ExecStart=/ExecStartt=/' deploy/kavita-epaper.service; }
broken_import_unit() { broken_import; unit_change; }
# The checkout's code plays 0.7.23 here, test builds play 0.7.24 and 0.7.25:
# versions are only labels, the scenarios compare them. V0 checks the real
# VERSION and UPDATE_SH_VERSION agree.
mk_tarball v23 0.7.23
mk_tarball v23deps 0.7.23 deps_b
newtools_oldapp() { echo 0.7.20 > VERSION; }
mk_tarball newtools 0.7.24 newtools_oldapp
mk_tarball v24 0.7.24 note_24
reqs_change() { echo "# harness: requirements change" >> requirements.txt; }
mk_tarball v24reqs 0.7.24 reqs_change
mk_tarball v24b 0.7.24 deps_b
mk_tarball v25c 0.7.25 deps_c
mk_tarball broken 0.7.24 broken_import
mk_tarball brokenlogin 0.7.24 broken_login
mk_tarball unitchange 0.7.24 unit_change
mk_tarball unittypo 0.7.24 unit_typo
mk_tarball brokenunit 0.7.24 broken_import_unit
# the real v0.7.22 release, with its own (older, layout-unaware) update.sh
T22="$H/tree-old22"; mkdir -p "$T22"
git -C "$R" -c tar.umask=0022 archive "$OLD_REF" | tar -x -C "$T22"
redirect "$T22/deploy/update.sh" > "$H/old-update.sh"; cp "$H/old-update.sh" "$T22/deploy/update.sh"
(cd "$T22" && tar -czf "$H/rel/old22.tar.gz" --owner=0 --group=0 $(git -C "$R" show "$OLD_REF:.github/workflows/release.yml" | grep -oE '\./\.gitignore .* \./app'))
for f in "$H/tree-v23/deploy/update.sh" "$H/tree-v23/deploy/configure" "$H/old-update.sh"; do
  n=$(live_paths "$f"); echo "live paths left in ${f#$H/}: $n"
  [ "$n" = 0 ] || { echo "FAIL  live paths left; aborting"; exit 1; }
done

# ---------------------------------------------------------------- stubs
mkdir -p "$H/bin"
export H APP_PORT PATH="$H/bin:$PATH"
cat > "$H/bin/run-app" <<'EOF'
#!/bin/bash
cd "$H/opt/kavita-epaper" || exit 1
# a unit drop-in's Environment= (SHOW_ENV); .env is read after it and wins, as in systemd
[ -n "${SHOW_ENV:-}" ] && export "$SHOW_ENV"
while IFS= read -r line; do
  case "$line" in ''|\#*) continue ;; *=*) v=${line#*=}; v=${v%\"}; v=${v#\"}; export "${line%%=*}=$v" ;; esac
done < .env
export KAVITA_EPAPER_COVER_CACHE="$H/cache/covers" PYTHONDONTWRITEBYTECODE=1
venv/bin/uvicorn app.main:app --host 127.0.0.1 --port "${KAVITA_EPAPER_PORT:-8095}" \
  --proxy-headers --forwarded-allow-ips '*' >> "$H/app.log" 2>&1
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
start_app() {
  stop_app; rm -f "$H/app.exit"
  if [ -e "$H/fail-next-start" ]; then rm -f "$H/fail-next-start"; echo 1 > "$H/app.exit"; return; fi
  setsid "$H/bin/run-app" < /dev/null > /dev/null 2>&1 & echo $! > "$H/app.pid"
}
case "$1" in
  restart|start) start_app ;;
  stop) stop_app ;;
  is-active) alive && [ ! -f "$H/app.exit" ] ;;
  is-failed) [ -f "$H/app.exit" ] && [ "$(cat "$H/app.exit")" != 0 ] ;;
  show) case "$*" in *Environment*) echo "Environment=${SHOW_ENV:-}" ;; *) cat "$H/app.exit" 2>/dev/null || echo 0 ;; esac ;;
  status) alive && echo "● kavita-epaper.service (harness)" ;;
  *) exit 0 ;;
esac
EOF
cat > "$H/bin/runuser" <<'EOF'
#!/bin/bash
shift 3; exec "$@"
EOF
chmod +x "$H/bin/"*

start_stub() {
  "$H/tools/bin/python" -I "$R/tests/kavita_stub.py" 18396 & STUB=$!
  for _ in $(seq 50); do "$H/tools/bin/python" -c "import urllib.request; urllib.request.urlopen('$KAVITA/api/health')" 2>/dev/null && break; sleep 0.1; done
}
start_stub
trap 'kill $STUB 2>/dev/null; "$H/bin/systemctl" stop >/dev/null 2>&1' EXIT

# ---------------------------------------------------------------- base states
SECRET=$(printf 's%.0s' $(seq 48))
write_env() {
  printf 'KAVITA_BASE_URL=%s\nKAVITA_EPAPER_SECRET=%s\nKAVITA_EPAPER_PORT=%s\n#KAVITA_EPAPER_COVER_TTL=86400\n' \
    "$KAVITA" "$SECRET" "$APP_PORT" > "$I/.env"; chmod 600 "$I/.env"
}
login_ok() { "$H/tools/bin/python" -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$APP_PORT/login', timeout=3)" 2>/dev/null; }
wait_up() { for _ in $(seq 60); do login_ok && return 0; sleep 0.25; done; return 1; }
echo "[harness] building the 0.7.22 base (old layout: real venv dir)"
"$H/bin/systemctl" stop
rm -rf "$H/opt" "$H/etc" "$H/backups" "$H/cache"; mkdir -p "$I" "$H/etc" "$H/backups" "$H/cache/covers"
for f in app VERSION requirements.txt constraints.txt; do cp -a "$T22/$f" "$I/"; done
cp "$H/old-update.sh" "$I/update.sh"; chmod 755 "$I/update.sh"
cp "$T22/deploy/kavita-epaper.service" "$H/etc/kavita-epaper.service"
write_env
python3 -m venv "$I/venv" && "$I/venv/bin/pip" install --quiet -r "$I/requirements.txt" -c "$I/constraints.txt" \
  || { echo "base venv failed"; exit 1; }
mkdir -p "$H/tpl"
cp -a "$H/opt" "$H/tpl/opt-22"; cp -a "$H/etc" "$H/tpl/etc-22"; cp -a "$H/backups" "$H/tpl/backups-22"
restore() {  # 22 | 23
  "$H/bin/systemctl" stop >/dev/null
  rm -rf "$H/opt" "$H/etc" "$H/backups" "$H/cache" "$H/calls" "$H/app.log" "$H/app.exit" "$H/fail-next-start"
  cp -a "$H/tpl/opt-$1" "$H/opt"; cp -a "$H/tpl/etc-$1" "$H/etc"; cp -a "$H/tpl/backups-$1" "$H/backups"
  mkdir -p "$H/cache/covers"
  "$H/bin/systemctl" start; wait_up || echo "[harness] base $1 didn't start"
  : > "$H/calls"
}

# ---------------------------------------------------------------- helpers
PASS=0; FAIL=0; BAD=""
expect() { local d="$1"; shift; if "$@"; then :; else BAD="${BAD}${BAD:+; }$d"; fi; }
has() { grep -qE -- "$1" "$H/out"; }
lacks() { ! grep -qE -- "$1" "$H/out"; }
run_sh() { local sh="$1"; shift; bash "$sh" "$@" > "$H/out" 2>&1; RC=$?; }
upd() { run_sh "$I/update.sh" "$@"; }
cfg() { python3 "$I/configure" "$@" > "$H/out" 2>&1; RC=$?; }
v() { cat "$I/${1:-}VERSION" 2>/dev/null; }
link() { readlink "$I/$1" 2>/dev/null || echo "-"; }
nvenvs() { ls -1 "$I/venvs" 2>/dev/null | wc -l; }
tools_v() { sed -n 's/^UPDATE_SH_VERSION="\([0-9.]*\)"$/\1/p' "$I/update.sh"; }
tools_are() {  # installed update.sh and configure equal that tree's
  cmp -s "$I/update.sh" "$H/tree-$1/deploy/update.sh" && cmp -s "$I/configure" "$H/tree-$1/deploy/configure"
}
venv_sum() { (cd "$1/" && find . -type f ! -name '*.pyc' ! -name .complete -print0 | sort -z | xargs -0 cksum | cksum); }
snap() {  # everything that defines the install, minus failed/ and caches
  (cd "$H" && find opt etc backups \( -name __pycache__ -o -path opt/kavita-epaper/failed \) -prune -o -print | sort |
   while IFS= read -r f; do
     if [ -L "$f" ]; then echo "L $f -> $(readlink "$f")"
     elif [ -f "$f" ]; then echo "F $f $(cksum < "$f")"
     else echo "D $f"; fi
   done)
}
pid() { cat "$H/app.pid" 2>/dev/null; }
same_but_unit_backups() {  # BEFORE AFTER: identical, apart from added /var/backups unit copies
  local d; d=$(diff <(printf '%s\n' "$1") <(printf '%s\n' "$2") | grep -E '^[<>]' || true)
  [ -z "$d" ] && return 0
  ! printf '%s\n' "$d" | grep -vqE '^> F backups/kavita-epaper\.service\.'
}
finish() {
  if [ -z "$BAD" ]; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1: $BAD"; FAIL=$((FAIL+1)); fi
  echo "      rc=$RC version=$(v) venv=$(link venv) previous=$(v previous/) prev-venv=$(link previous/venv) venvs=$(nvenvs) tools=$(tools_v) failed=$(v failed/)"
  grep -E '^\[|^    |^This |^Running |^Switch|^current|^previous|^--rollback' "$H/out" | sed "s#$H#<H>#g; s/^/      /"
  BAD=""
}

RC=-; : > "$H/out"
expect "update.sh version = VERSION" [ "$(sed -n 's/^UPDATE_SH_VERSION="\([0-9.]*\)"$/\1/p' "$R/deploy/update.sh")" = "$(cat "$R/VERSION")" ]
finish "V0 UPDATE_SH_VERSION matches VERSION"

# ---------------------------------------------------------------- migration
restore 22
SITE_BEFORE=$(venv_sum "$I/venv")
upd "$H/rel/v23.tar.gz"
expect "rc 0" [ "$RC" = 0 ]
expect "handed off" has "handing off to the tarball's update.sh"
expect "migration message" has 'moving the existing venv to venvs/legacy-'
expect "no venv build" has 'unchanged, keeping the current venv'
expect "now 0.7.23" [ "$(v)" = 0.7.23 ]
expect "venv is a symlink to legacy" bash -c "[[ \$(readlink '$I/venv') == venvs/legacy-* ]]"
expect "previous is 0.7.22" [ "$(v previous/)" = 0.7.22 ]
expect "previous/venv -> same legacy" [ "$(link previous/venv)" = "../$(link venv)" ]
expect "one venv" [ "$(nvenvs)" = 1 ]
expect "legacy venv files unchanged" [ "$(venv_sum "$I/venv")" = "$SITE_BEFORE" ]
expect "tools are 0.7.23's" tools_are v23
expect "previous keeps 0.7.22's update.sh for reference" cmp -s "$I/previous/update.sh" "$H/old-update.sh"
expect "app answers" login_ok
expect "no journal" test ! -e "$I/.update-journal"
finish "M1 migrate 0.7.22 to 0.7.23 (handoff from the installed 0.7.22 update.sh, deps unchanged)"
"$H/bin/systemctl" stop >/dev/null
cp -a "$H/opt" "$H/tpl/opt-23"; cp -a "$H/etc" "$H/tpl/etc-23"; cp -a "$H/backups" "$H/tpl/backups-23"

restore 22
SITE_BEFORE=$(venv_sum "$I/venv")
upd "$H/rel/v23deps.tar.gz"
expect "rc 0" [ "$RC" = 0 ]
expect "built while running" has 'dependencies changed, building venvs/[0-9a-f]{12} while 0.7.22 keeps running'
expect "build before stop" bash -c "grep -E 'built venvs/|stopping' '$H/out' | head -1 | grep -q built"
expect "venv -> new id" bash -c "[[ \$(readlink '$I/venv') =~ ^venvs/[0-9a-f]{12}$ ]]"
expect "previous/venv -> legacy" bash -c "[[ \$(readlink '$I/previous/venv') == ../venvs/legacy-* ]]"
expect "two venvs" [ "$(nvenvs)" = 2 ]
expect "legacy venv untouched by the build" [ "$(venv_sum "$I/previous/venv")" = "$SITE_BEFORE" ]
expect "new venv marked complete" test -f "$I/venv/.complete"
expect "app answers" login_ok
finish "M2 migrate with changed dependencies: new venv built beside the running one"

restore 22
BEFORE=$(snap)
upd "$H/rel/broken.tar.gz"
expect "rc 1" [ "$RC" = 1 ]
expect "rolled back message" has 'update to 0.7.24 failed; rolled back, running 0.7.22 again'
expect "install exactly as before (failed/ aside; only a unit backup added)" same_but_unit_backups "$BEFORE" "$(snap)"
expect "venv is a real dir again" bash -c "[ -d '$I/venv' ] && [ ! -L '$I/venv' ]"
expect "update.sh is 0.7.22's again" cmp -s "$I/update.sh" "$H/old-update.sh"
expect "no venvs dir" test ! -e "$I/venvs"
expect "failed/ has 0.7.24" [ "$(v failed/)" = 0.7.24 ]
expect "app answers on 0.7.22" login_ok
finish "M3 migration, new version won't start: everything back, plain venv/ included"

# ---------------------------------------------------------------- updates
restore 23
V_BEFORE=$(link venv)
upd "$H/rel/v24.tar.gz"
expect "rc 0" [ "$RC" = 0 ]
expect "now 0.7.24" [ "$(v)" = 0.7.24 ]
expect "same venv, no build" bash -c "[ '$(link venv)' = '$V_BEFORE' ] && grep -q 'keeping the current venv' '$H/out'"
expect "previous 0.7.23" [ "$(v previous/)" = 0.7.23 ]
expect "0.7.22 dropped (one previous)" test ! -e "$I/previous.old"
expect "tools now 0.7.24's (newer)" tools_are v24
expect "unit untouched, no backup" bash -c "! grep -q 'service unit changed' '$H/out' && [ \$(ls '$H/backups' | grep -c kavita-epaper.service) = \$(ls '$H/tpl/backups-23' | grep -c kavita-epaper.service) ]"
expect "app answers" login_ok
finish "U1 update 0.7.23 to 0.7.24, deps and unit unchanged (old B, P3)"

restore 23
OLD_TARGET=$(link venv)
upd "$H/rel/v24reqs.tar.gz"
expect "rc 0" [ "$RC" = 0 ]
expect "built a new venv" has 'dependencies changed, building venvs/[0-9a-f]{12} while 0.7.23 keeps running'
expect "new venv, old one kept for previous" bash -c "[ '$(link venv)' != '$OLD_TARGET' ] && [ '$(link previous/venv)' = '../$OLD_TARGET' ]"
expect "installed requirements.txt is the new one" cmp -s "$I/requirements.txt" "$H/tree-v24reqs/requirements.txt"
expect "app answers" login_ok
finish "P1 requirements.txt changed: new venv built, swap (old P1)"

restore 23
upd "$H/rel/v24b.tar.gz"; RC1=$RC; VB=$(link venv)
upd "$H/rel/v25c.tar.gz"
expect "both rc 0" [ "$RC1$RC" = 00 ]
expect "now 0.7.25" [ "$(v)" = 0.7.25 ]
expect "previous 0.7.24 with its venv" bash -c "[ '$(v previous/)' = 0.7.24 ] && [ '$(link previous/venv)' = '../$VB' ]"
expect "exactly two venvs, legacy gone" bash -c "[ \$(ls -1 '$I/venvs' | wc -l) = 2 ] && ! ls '$I/venvs' | grep -q legacy"
finish "U2 two dependency changes: the oldest venv is removed, one previous kept"

restore 23
BEFORE=$(snap)
upd "$H/rel/old22.tar.gz"
expect "rc 1" [ "$RC" = 1 ]
expect "names both versions" has 'the release you gave is 0.7.22, older than the installed 0.7.23; nothing was changed'
expect "points at --rollback" has 'switch back to the kept previous version \(0.7.22\): sudo .*update.sh --rollback'
expect "points at --allow-downgrade" has 'add --allow-downgrade to this command'
expect "nothing stopped" bash -c "! grep -q '^systemctl stop' '$H/calls'"
expect "nothing changed" [ "$BEFORE" = "$(snap)" ]
finish "U3 older (0.7.22) tarball without --allow-downgrade: refused, nothing changed"

restore 23
upd "$H/rel/old22.tar.gz" --allow-downgrade
expect "rc 0" [ "$RC" = 0 ]
expect "no handoff to the older script" lacks 'handing off'
expect "older-version message" has '0.7.22 is older than 0.7.23 \(--allow-downgrade\); installing its app, keeping update.sh and configure 0.7.23'
expect "app is 0.7.22" bash -c "[ '$(v)' = 0.7.22 ] && diff -rq '$I/app' '$T22/app' >/dev/null"
expect "tools still 0.7.23's" tools_are v23
expect "previous 0.7.23" [ "$(v previous/)" = 0.7.23 ]
expect "app answers" login_ok
finish "U3b --allow-downgrade (after the path): app goes back, update.sh/configure stay 0.7.23"

restore 23
upd --allow-downgrade "$H/rel/old22.tar.gz"
expect "rc 0, flag first works" bash -c "[ '$RC' = 0 ] && [ '$(v)' = 0.7.22 ]"
finish "U3c --allow-downgrade before the path"

restore 23
BEFORE=$(snap)
upd "$H/rel/newtools.tar.gz"
expect "rc 1" [ "$RC" = 1 ]
expect "handed off to the newer update.sh" has 'handing off'
expect "the newer copy refuses the older app" has 'the release you gave is 0.7.20, older than the installed 0.7.23'
expect "nothing changed" [ "$BEFORE" = "$(snap)" ]
upd "$H/rel/newtools.tar.gz" --allow-downgrade
expect "with the flag: handed off and installed" bash -c "[ '$RC' = 0 ] && grep -q 'handing off' '$H/out' && [ '$(v)' = 0.7.20 ]"
expect "the newer tools are installed" tools_are newtools
finish "U3d --allow-downgrade is passed through a handoff (newer update.sh, older app)"

restore 23
mkdir -p "$H/lib/releases"; cp "$H/rel/old22.tar.gz" "$H/lib/releases/kavita-epaper-v0.7.22.tar.gz"
BEFORE=$(snap)
upd
expect "rc 1" [ "$RC" = 1 ]
expect "picked from the releases dir" has 'auto-selected: .*kavita-epaper-v0.7.22.tar.gz'
expect "refused" has 'older than the installed 0.7.23; nothing was changed'
expect "nothing changed" [ "$BEFORE" = "$(snap)" ]
rm -rf "$H/lib/releases"
finish "U3e releases-dir mode with only an older tarball: refused"

# ---------------------------------------------------------------- failures
restore 23
BEFORE=$(snap); PID_BEFORE=$(pid)
PIP_FIND_LINKS="$H/no-wheels" upd "$H/rel/v24b.tar.gz"
expect "rc 1" [ "$RC" = 1 ]
expect "message" has 'was not stopped and is still running 0.7.23'
expect "service never stopped" bash -c "[ '$(pid)' = '$PID_BEFORE' ] && ! grep -q '^systemctl stop' '$H/calls'"
expect "install unchanged" [ "$BEFORE" = "$(snap)" ]
finish "F1 venv build fails (wheel missing): nothing stopped or changed"

for variant in broken brokenlogin; do
  restore 23
  BEFORE=$(snap)
  upd "$H/rel/$variant.tar.gz"
  expect "rc 1" [ "$RC" = 1 ]
  expect "didn't come up" has "0.7.24 didn't come up"
  expect "rolled back" has 'rolled back, running 0.7.23 again'
  expect "install exactly as before" [ "$BEFORE" = "$(snap)" ]
  expect "failed/ kept" [ "$(v failed/)" = 0.7.24 ]
  expect "app answers on 0.7.23" login_ok
  if [ "$variant" = broken ]; then finish "F2 new version fails at import: full rollback"
  else finish "F3 new version active but /login fails: full rollback"; fi
done

restore 23
BEFORE=$(snap)
upd "$H/rel/brokenunit.tar.gz"
expect "rc 1" [ "$RC" = 1 ]
expect "unit was installed, then put back" has 'installed the new kavita-epaper.service'
expect "install exactly as before (unit backup aside)" [ "$(echo "$BEFORE" | grep -v ' backups/')" = "$(snap | grep -v ' backups/')" ]
finish "F2b new version with a changed unit fails: unit restored too"

restore 23
printf '\nraise RuntimeError("harness: current broken on disk")\n' >> "$I/app/main.py"
BEFORE=$(snap)
upd "$H/rel/broken.tar.gz"
expect "rc 1" [ "$RC" = 1 ]
expect "loud message" has "and 0.7.23 doesn't come up after putting it back either"
expect "files as before" [ "$BEFORE" = "$(snap)" ]
finish "F4 new version fails and the restored one fails too: loud, nothing deleted"

restore 23
printf '\nraise RuntimeError("harness: current broken on disk")\n' >> "$I/app/main.py"
BEFORE=$(snap)
upd "$H/rel/brokenunit.tar.gz"
expect "rc 1" [ "$RC" = 1 ]
expect "new unit was installed" has 'installed the new kavita-epaper.service'
expect "loud message" has "and 0.7.23 doesn't come up after putting it back either"
expect "files and unit as before (unit backup aside)" [ "$(echo "$BEFORE" | grep -v ' backups/')" = "$(snap | grep -v ' backups/')" ]
finish "E unit changed, new version fails, restored one fails too: unit restored, loud (old E)"

restore 23
rm -f "$H/etc/kavita-epaper.service"
upd "$H/rel/brokenunit.tar.gz"
expect "rc 1" [ "$RC" = 1 ]
expect "no backup made (no prior unit)" lacks 'backed up the installed unit'
expect "new unit removed again" test ! -e "$H/etc/kavita-epaper.service"
expect "rolled back" has 'rolled back, running 0.7.23 again'
finish "F no prior unit, new version fails: the new unit is removed again (old F)"

restore 23
BEFORE=$(snap)
KAVITA_EPAPER_TEST_DIE_AFTER_SWAP=1 upd "$H/rel/v24.tar.gz"; RC1=$RC
J=$( [ -f "$I/.update-journal" ] && echo yes || echo no )
upd --status; STATUS_OUT=$(cat "$H/out")
upd "$H/rel/v24.tar.gz"; RC2=$RC; cp "$H/out" "$H/out.recover"
AFTER=$(snap)
upd "$H/rel/v24.tar.gz"; RC3=$RC
cp "$H/out.recover" "$H/out"
expect "killed mid-swap" [ "$RC1" = 137 ]
expect "journal left behind" [ "$J" = yes ]
expect "status warns" bash -c "grep -q 'interrupted update or rollback was found' <<< \"\$1\"" _ "$STATUS_OUT"
expect "next run recovers" has 'found an interrupted update or rollback'
expect "recovered message" has 'recovered; running 0.7.23 again'
expect "rc 1 after recovery" [ "$RC2" = 1 ]
expect "install as before the interrupted run" [ "$BEFORE" = "$AFTER" ]
expect "then the update works" bash -c "[ '$RC3' = 0 ] && [ '$(v)' = 0.7.24 ]"
finish "F5 killed mid-swap: next run undoes it, then the update succeeds"

restore 23
kill $STUB; wait $STUB 2>/dev/null
upd "$H/rel/v24.tar.gz"
expect "rc 0" [ "$RC" = 0 ]
expect "updated" [ "$(v)" = 0.7.24 ]
expect "Kavita warning only" has "kavita-epaper is running, but Kavita isn't answering \(kavita: refused\)"
expect "update wording, configure pointer" bash -c "grep -q 'The update itself is fine' '$H/out' && grep -q 'configure show' '$H/out'"
upd --rollback --yes
expect "rollback with Kavita down: switch wording" bash -c "[ '$RC' = 0 ] && grep -q 'The switch itself is fine' '$H/out'"
finish "K1 Kavita down during an update and a rollback: only a warning, worded for each"
start_stub

# ---------------------------------------------------------------- unit, secret, handoff
restore 23
for d in 01 02 03 04 05 06; do echo old > "$H/backups/kavita-epaper.service.200001${d}-000000"; done
OLD_UNIT=$(cksum < "$H/etc/kavita-epaper.service")
upd "$H/rel/unitchange.tar.gz"
expect "rc 0" [ "$RC" = 0 ]
expect "unit installed" cmp -s "$H/etc/kavita-epaper.service" "$H/tree-unitchange/deploy/kavita-epaper.service"
expect "previous keeps the old unit" [ "$(cksum < "$I/previous/kavita-epaper.service")" = "$OLD_UNIT" ]
expect "unit backups pruned to 5" [ "$(ls "$H/backups" | grep -c kavita-epaper.service)" = 5 ]
expect "oldest pruned" test ! -e "$H/backups/kavita-epaper.service.20000101-000000"
finish "A1 unit changed: installed, previous/ keeps the old one, backups pruned to 5"

restore 23
BEFORE=$(snap)
upd "$H/rel/unittypo.tar.gz"
expect "rc 1" [ "$RC" = 1 ]
expect "verify message" has 'failed systemd-analyze verify; nothing was changed'
expect "nothing stopped" bash -c "! grep -q '^systemctl stop' '$H/calls'"
expect "install unchanged" [ "$BEFORE" = "$(snap)" ]
finish "A2 unit fails verify: nothing changed"

restore 23
sed -i 's/^KAVITA_EPAPER_SECRET=.*/KAVITA_EPAPER_SECRET=too-short/' "$I/.env"
BEFORE=$(snap)
upd "$H/rel/v24.tar.gz"
expect "rc 1" [ "$RC" = 1 ]
expect "secret message" has 'KAVITA_EPAPER_SECRET is too short \(9 characters'
expect "points at configure" has 'configure new-secret'
expect "nothing stopped" bash -c "! grep -q '^systemctl stop' '$H/calls'"
expect "nothing changed" [ "$BEFORE" = "$(snap)" ]
finish "S1 weak secret: refused before anything is stopped"

secret_case() {  # LABEL BASE TARBALL WANT_RC REGEX [SECRET_LINE|-none] [SHOW_ENV]
  restore "$2"
  if [ "${6:-}" = -none ]; then sed -i '/^KAVITA_EPAPER_SECRET=/d' "$I/.env"
  elif [ -n "${6:-}" ]; then sed -i "s|^KAVITA_EPAPER_SECRET=.*|$6|" "$I/.env"; fi
  local before; before=$(snap)
  SHOW_ENV="${7:-}" upd "$H/rel/$3.tar.gz"
  expect "rc $4" [ "$RC" = "$4" ]
  expect "message" has "$5"
  if [ "$4" = 1 ]; then
    expect "nothing stopped" bash -c "! grep -q '^systemctl stop' '$H/calls'"
    expect "nothing changed" [ "$before" = "$(snap)" ]
  else
    expect "app answers" login_ok
  fi
  finish "$1"
}
secret_case "S2 secret is the env.example placeholder: refused" 23 v24 1 'is still the placeholder from env.example' \
  "KAVITA_EPAPER_SECRET=CHANGE_ME_TO_A_LONG_RANDOM_STRING"
secret_case "S3 quoted 40-character secret: accepted" 23 v24 0 'updated to 0.7.24 and running' \
  "KAVITA_EPAPER_SECRET=\"$(printf 'q%.0s' $(seq 40))\""
secret_case "S4 no secret anywhere: refused" 23 v24 1 'is not set in .*/\.env' -none
secret_case "S5 secret only in a unit drop-in: accepted" 23 v24 0 'updated to 0.7.24 and running' -none \
  "KAVITA_EPAPER_SECRET=from-a-drop-in-0123456789abcdef0123"
secret_case "S6 handoff from 0.7.22 with a weak secret: refused, still 0.7.22" 22 v23 1 'is too short \(5 characters' \
  "KAVITA_EPAPER_SECRET=short"
expect "S6 handed off first" has 'handing off'
expect "secret value never printed" lacks 'KAVITA_EPAPER_SECRET=short|=short'
expect "installed update.sh still 0.7.22's" cmp -s "$I/update.sh" "$H/old-update.sh"
RC=-; finish "S7 after S6: secret never printed, installed update.sh still 0.7.22's"

restore 22
PIP_FIND_LINKS="$H/no-wheels" upd "$H/rel/v23deps.tar.gz"
expect "rc 1" [ "$RC" = 1 ]
expect "handed off" has 'handing off'
expect "still 0.7.22, plain venv" bash -c "[ '$(v)' = 0.7.22 ] && [ -d '$I/venv' ] && [ ! -L '$I/venv' ]"
expect "installed update.sh still 0.7.22's" cmp -s "$I/update.sh" "$H/old-update.sh"
finish "H2 handoff from 0.7.22, venv build fails: nothing changed"

# ---------------------------------------------------------------- --status and --rollback
restore 23
upd --status
expect "status shows the direction" has '^--rollback would switch from 0.7.23 to 0.7.22'
expect "status shows update.sh version" has '^update.sh: 0.7.23'
finish "ST --status before a rollback"

restore 23
upd --rollback < /dev/null
expect "rc 1 without --yes when not a terminal" [ "$RC" = 1 ]
expect "says how" has 'rerun with --yes to switch from 0.7.23 to 0.7.22'
printf 'n\n' | script -qefc "bash $I/update.sh --rollback" /dev/null > "$H/out" 2>&1; RC=$?; sed -i 's/\r$//' "$H/out"
expect "prompt states the direction" has 'Switch from 0.7.23 to 0.7.22\? \[y/N\]'
expect "answer n changes nothing" [ "$(v)" = 0.7.23 ]
finish "R0 --rollback asks first and says which way"

restore 23
BEFORE=$(snap)
PIP_FIND_LINKS="$H/no-wheels" upd --rollback --yes
expect "rc 0" [ "$RC" = 0 ]
expect "now 0.7.22" [ "$(v)" = 0.7.22 ]
expect "previous is 0.7.23" [ "$(v previous/)" = 0.7.23 ]
expect "switched message" has 'switched to 0.7.22; 0.7.23 is kept as the previous version'
expect "tools still 0.7.23's" tools_are v23
expect "app is 0.7.22's" diff -rq "$I/app" "$T22/app"
expect "app answers" login_ok
finish "R1 --rollback to 0.7.22 (no tarball, no network): update.sh/configure stay 0.7.23"
PIP_FIND_LINKS="$H/no-wheels" upd --rollback --yes
expect "rc 0" [ "$RC" = 0 ]
expect "back on 0.7.23" [ "$(v)" = 0.7.23 ]
expect "previous 0.7.22 again" [ "$(v previous/)" = 0.7.22 ]
expect "tools still 0.7.23's" tools_are v23
expect "same install as before both rollbacks" [ "$(echo "$BEFORE" | grep -v ' backups/')" = "$(snap | grep -v ' backups/')" ]
finish "R2 --rollback again toggles forward: update.sh/configure still 0.7.23"

restore 23
rm -rf "$I/previous"
upd --rollback --yes
expect "rc 1" [ "$RC" = 1 ]
expect "message" has 'no kept previous version to switch to'
finish "R3 --rollback with nothing kept: refused, nothing changed"

restore 23
printf '\nraise RuntimeError("harness: previous broken")\n' >> "$I/previous/app/main.py"
BEFORE=$(snap)
upd --rollback --yes
expect "rc 1" [ "$RC" = 1 ]
expect "message" has "0.7.22 didn't come up; switching back to 0.7.23"
expect "still 0.7.23" has 'rollback failed; still running 0.7.23, nothing changed'
expect "install exactly as before (only a unit backup added)" same_but_unit_backups "$BEFORE" "$(snap)"
expect "app answers" login_ok
finish "R4 --rollback to a version that won't start: switched back, nothing changed"

# ---------------------------------------------------------------- configure
restore 23
cfg show
expect "rc 0" [ "$RC" = 0 ]
expect "secret masked" has 'session secret +set, 48 characters'
expect "secret never printed" lacks "$SECRET"
expect "Kavita reachable" has '^Kavita: +reachable'
expect "listen address format" has 'listen address +0\.0\.0\.0:18295 \(default host\)$'
finish "CF1 configure show"

restore 23
SUM=$(sha256sum < "$I/.env")
cfg kavita-url "$DEAD"
expect "rc 2" [ "$RC" = 2 ]
expect "refused" has 'not saved. Fix the address, or add --force'
expect ".env unchanged, no backup" bash -c "[ '$(sha256sum < "$I/.env")' = '$SUM' ] && ! ls '$H/backups' | grep -q env"
cfg kavita-url "$DEAD" --force
expect "--force saves" bash -c "[ '$RC' = 0 ] && grep -q '^KAVITA_BASE_URL=$DEAD$' '$I/.env'"
expect "Kavita warning, kept" has "can't reach Kavita right now \(kavita: refused\); the change is kept"
expect "backup 600" bash -c "[ \$(stat -c %a \$(ls -1 '$H/backups'/kavita-epaper.env.* | tail -1)) = 600 ]"
cfg kavita-url "127.0.0.1:18396/"
expect "good URL normalized and saved" bash -c "[ '$RC' = 0 ] && grep -q '^KAVITA_BASE_URL=$KAVITA$' '$I/.env'"
expect "no warning now" lacks "can't reach Kavita"
finish "CF2 kavita-url: unreachable refused, --force saves with a warning, good URL saved"

restore 23
cfg trusted-proxies proxy.example; RC1=$RC
cfg trusted-proxies "192.0.2.10,192.0.2.0/28"
expect "hostname refused" [ "$RC1" = 2 ]
expect "list saved" bash -c "[ '$RC' = 0 ] && grep -q '^KAVITA_EPAPER_FORWARDED_ALLOW_IPS=192.0.2.10,192.0.2.0/28$' '$I/.env'"
cfg cookie-secure sometimes; RC1=$RC
cfg cookie-secure true
expect "bad choice refused" [ "$RC1" = 2 ]
expect "true saved with a warning" bash -c "[ '$RC' = 0 ] && grep -q 'only sticks over HTTPS' '$H/out'"
cfg cover-ttl soon; RC1=$RC
cfg cover-ttl 3600
expect "bad ttl refused" [ "$RC1" = 2 ]
expect "ttl replaces the commented template line" bash -c "[ '$RC' = 0 ] && grep -q '^KAVITA_EPAPER_COVER_TTL=3600$' '$I/.env' && ! grep -q '^#KAVITA_EPAPER_COVER_TTL' '$I/.env'"
cfg frobnicate 1
expect "unknown command refused" [ "$RC" = 2 ]
finish "CF3 trusted-proxies, cookie-secure, cover-ttl, unknown command"

restore 23
mkdir -p "$H/etc-kavita"
"$H/tools/bin/python" - "$H/etc-kavita/ca.pem" <<'PY'
import datetime, sys
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
k = ec.generate_private_key(ec.SECP256R1()); n = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "harness CA")])
now = datetime.datetime.now(datetime.timezone.utc)
c = (x509.CertificateBuilder().subject_name(n).issuer_name(n).public_key(k.public_key()).serial_number(1)
     .not_valid_before(now).not_valid_after(now + datetime.timedelta(days=1))
     .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True).sign(k, hashes.SHA256()))
open(sys.argv[1], "wb").write(c.public_bytes(serialization.Encoding.PEM))
PY
cfg ca-bundle "$H/etc-kavita/missing.pem"; RC1=$RC
cfg ca-bundle /root/kavita-epaper-no-such-ca.pem; RC2=$RC; OUT2=$(cat "$H/out")
echo junk > "$H/etc-kavita/junk.pem"; cfg ca-bundle "$H/etc-kavita/junk.pem"; RC3=$RC
cfg ca-bundle "$H/etc-kavita/ca.pem"
expect "missing refused" [ "$RC1" = 2 ]
expect "/root refused" bash -c "[ '$RC2' = 2 ] && grep -q \"can't see /root or /home\" <<< \"\$1\"" _ "$OUT2"
expect "non-PEM refused" [ "$RC3" = 2 ]
expect "PEM saved, app starts with it" bash -c "[ '$RC' = 0 ] && grep -q '^KAVITA_CA_BUNDLE=$H/etc-kavita/ca.pem$' '$I/.env'"
cfg ca-bundle none
expect "none removes it" bash -c "[ '$RC' = 0 ] && ! grep -q '^KAVITA_CA_BUNDLE=' '$I/.env'"
cfg kavita-tls-verify off
expect "off saved with a warning" bash -c "[ '$RC' = 0 ] && grep -q '^KAVITA_TLS_VERIFY=false$' '$I/.env' && grep -q 'passwords included' '$H/out'"
cfg kavita-tls-verify on
expect "on saved" bash -c "[ '$RC' = 0 ] && grep -q '^KAVITA_TLS_VERIFY=true$' '$I/.env'"
finish "CF4 ca-bundle (missing, /root, non-PEM refused; PEM and none) and kavita-tls-verify"

restore 23
COOKIE=$("$H/tools/bin/python" -c "
import httpx
r = httpx.post('http://127.0.0.1:$APP_PORT/login', data={'username': 'alice', 'password': 'pw'})
print(r.cookies.get('kesess') or '')")
lib() { "$H/tools/bin/python" -c "import httpx,sys; print(httpx.get('http://127.0.0.1:$APP_PORT/library', cookies={'kesess': sys.argv[1]}).status_code)" "$COOKIE"; }
L0=$(lib)
cfg new-secret --keep-sessions
NEW=$(sed -n 's/^KAVITA_EPAPER_SECRET=//p' "$I/.env"); PREV=$(sed -n 's/^KAVITA_EPAPER_SECRET_PREVIOUS=//p' "$I/.env")
expect "signed in before" [ "$L0" = 200 ]
expect "rc 0" [ "$RC" = 0 ]
expect "new 64-char secret" bash -c "[ \${#1} = 64 ] && [ \"\$1\" != '$SECRET' ]" _ "$NEW"
expect "old kept as PREVIOUS" [ "$PREV" = "$SECRET" ]
expect "reminder uses the default TTL" has 'After 30 days \(KAVITA_EPAPER_SESSION_TTL\), run: configure forget-previous-secret'

expect "old cookie still works" [ "$(lib)" = 200 ]
expect "no secret printed" bash -c "! grep -qF -e '$SECRET' -e \"\$1\" '$H/out'" _ "$NEW"
cfg forget-previous-secret
expect "PREVIOUS removed" bash -c "[ '$RC' = 0 ] && ! grep -q '^KAVITA_EPAPER_SECRET_PREVIOUS=' '$I/.env'"
expect "old cookie now signed out" [ "$(lib)" = 302 ]
finish "CF5 new-secret --keep-sessions keeps people signed in; forget-previous-secret ends it"

restore 23
SUM=$(sha256sum < "$I/.env")
touch "$H/fail-next-start"
cfg cover-ttl 100
expect "rc 1" [ "$RC" = 1 ]
expect "put back" has 'Putting the previous .env back'
expect "running with the previous settings" has 'change undone; running with the previous settings'
expect ".env as before" [ "$(sha256sum < "$I/.env")" = "$SUM" ]
expect "app answers" login_ok
finish "CF6 restart fails after a change: .env put back, service up"

restore 23
for t in 101 102 103 104 105 106 107; do cfg cover-ttl $t; done
expect "5 .env backups kept" [ "$(ls "$H/backups" | grep -c '^kavita-epaper.env\.')" = 5 ]
printf '4\n7200\n' | script -qefc "python3 $I/configure" /dev/null > "$H/out" 2>&1; RC=$?
expect "menu sets cover TTL" bash -c "[ '$RC' = 0 ] && grep -q '^KAVITA_EPAPER_COVER_TTL=7200$' '$I/.env'"
finish "CF7 .env backups pruned to 5; the terminal menu works"

restore 23
echo "KAVITA_EPAPER_SESSION_TTL=604800" >> "$I/.env"
cfg new-secret --keep-sessions
expect "7-day TTL in the reminder" bash -c "[ '$RC' = 0 ] && grep -q 'After 7 days (KAVITA_EPAPER_SESSION_TTL)' '$H/out'"
sed -i 's/^KAVITA_EPAPER_SESSION_TTL=.*/KAVITA_EPAPER_SESSION_TTL=90000/' "$I/.env"
cfg new-secret --keep-sessions
expect "non-day TTL in seconds" bash -c "[ '$RC' = 0 ] && grep -q 'After 90000 seconds' '$H/out'"
finish "CF8 rotation reminder follows KAVITA_EPAPER_SESSION_TTL"

"$H/bin/systemctl" stop >/dev/null 2>&1
echo "== $PASS PASS, $FAIL FAIL of $((PASS+FAIL))"
[ "$FAIL" = 0 ]
