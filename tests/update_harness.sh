#!/bin/bash
# update.sh harness: runs copies of deploy/update.sh (this checkout's, and the
# one from $OLD_REF, default v0.7.18) with every system path redirected under
# a scratch directory, and systemctl and pip replaced by stubs. The live
# install, /etc/systemd/system and /var/backups are never touched; the only
# real system command it runs is systemd-analyze verify (read-only).
# Usage: tests/update_harness.sh [work-dir]. See tests/README.md.
set -u
R=$(cd "$(dirname "$0")/.." && pwd)
OLD_REF=${OLD_REF:-v0.7.20}
H=${1:-$(mktemp -d -t kavita-epaper-harness-XXXXXX)}
rm -rf "$H"; mkdir -p "$H/bin" "$H/rel"
echo "== work dir $H, old ref $OLD_REF"
export H PATH="$H/bin:$PATH"
redirect() { sed -e "s#/opt/kavita-epaper#$H/opt/kavita-epaper#g" -e "s#/etc/systemd/system/#$H/etc/#g" -e "s#/var/backups#$H/backups#g" "$1"; }
redirect "$R/deploy/update.sh" > "$H/new.sh"
git -C "$R" show "$OLD_REF:deploy/update.sh" > "$H/old-raw.sh" || exit 1
redirect "$H/old-raw.sh" > "$H/old.sh"
for f in new.sh old.sh; do
  n=$(grep -vE '^\s*#' "$H/$f" | grep -cE '(^|[^/a-z0-9])/(opt|etc|var/backups)/')
  echo "live paths left in $f: $n"
  [ "$n" = 0 ] || { echo "FAIL  $f still references live paths; aborting"; exit 1; }
done

cat > "$H/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$H/calls"
case "$1" in
  show) [ -n "${SHOW_ENV:-}" ] && echo "Environment=$SHOW_ENV" || echo "Environment="; exit 0;;
  is-active) n=$(cat "$H/n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$H/n"
             v=$(echo "$ACTIVE_SEQ" | cut -d, -f$n); [ "${v:-1}" = 1 ];;
  *) exit 0;;
esac
EOF
chmod +x "$H/bin/systemctl"

# Release trees: this checkout's tracked files with the redirected update.sh,
# packed with the same file list as the release, plus a typo'd unit variant.
mk_tarball() {  # $1 name, $2 unit sed expression (optional)
  local T="$H/tree-$1"; rm -rf "$T"; mkdir -p "$T"
  # tracked files plus new, not-yet-committed ones (not ignored files)
  (cd "$R" && git ls-files -z --cached --others --exclude-standard | xargs -0 -I{} cp --parents {} "$T/")
  cp "$H/new.sh" "$T/deploy/update.sh"
  [ -n "${2:-}" ] && sed -i "$2" "$T/deploy/kavita-epaper.service"
  (cd "$T" && tar -czf "$H/rel/$1.tar.gz" --owner=0 --group=0 ./.gitignore ./CHANGELOG.md ./LICENSE ./MIGRATION.md ./README.md ./VERSION ./requirements.txt ./constraints.txt ./deploy ./app)
}
mk_tarball good
mk_tarball typo 's/^ExecStart=/ExecStartt=/'
git -C "$R" show "$OLD_REF:deploy/kavita-epaper.service" > "$H/unit-old"
cp "$H/tree-good/deploy/kavita-epaper.service" "$H/unit-new"
# The unit-sync scenarios need the installed unit to differ from the release's.
# If it didn't change since OLD_REF, mark the installed copy (a comment line),
# like the requirements.txt copy in setup().
if cmp -s "$H/unit-old" "$H/unit-new"; then
  echo "# harness: installed copy" >> "$H/unit-old"
  echo "note: unit unchanged since $OLD_REF; the installed copy gets a marker comment so it differs"
fi

setup() {  # $1 installed unit: old|new|none ; $2 installed update.sh: old|new ; $3 reqs: changed|same
  rm -rf "$H/opt" "$H/etc" "$H/backups" "$H/calls" "$H/n"
  mkdir -p "$H/opt/kavita-epaper/venv/bin" "$H/etc"
  git -C "$R" archive "$OLD_REF" app | tar -x -C "$H/opt/kavita-epaper"
  if [ "$3" = same ] || [ "$3" = consold ]; then
    cp "$R/requirements.txt" "$H/opt/kavita-epaper/requirements.txt"
    [ -f "$R/constraints.txt" ] && cp "$R/constraints.txt" "$H/opt/kavita-epaper/constraints.txt"
    [ "$3" = consold ] && echo "# harness: older constraints" >> "$H/opt/kavita-epaper/constraints.txt"
  else  # always differs from the release, even if requirements did not change since OLD_REF
    { git -C "$R" show "$OLD_REF:requirements.txt"; echo "# harness: installed copy"; } > "$H/opt/kavita-epaper/requirements.txt"
  fi
  git -C "$R" show "$OLD_REF:VERSION" > "$H/opt/kavita-epaper/VERSION"
  if [ "${SECRET_LINE-default}" = default ]; then
    echo "KAVITA_EPAPER_SECRET=$(printf 's%.0s' $(seq 48))" > "$H/opt/kavita-epaper/.env"
  else
    printf '%s\n' "KAVITA_BASE_URL=http://127.0.0.1:5000" ${SECRET_LINE:+"$SECRET_LINE"} > "$H/opt/kavita-epaper/.env"
  fi
  printf '#!/bin/bash\necho "pip $*" >> "$H/calls"\nexit ${PIP_RC:-0}\n' > "$H/opt/kavita-epaper/venv/bin/pip"
  chmod +x "$H/opt/kavita-epaper/venv/bin/pip"
  case $1 in old) cp "$H/unit-old" "$H/etc/kavita-epaper.service";; new) cp "$H/unit-new" "$H/etc/kavita-epaper.service";; esac
  cp "$H/$2.sh" "$H/opt/kavita-epaper/update.sh"
}

state() {
  local I="$H/opt/kavita-epaper" u v app reqs order
  if [ -e "$H/etc/kavita-epaper.service" ]; then
    if cmp -s "$H/etc/kavita-epaper.service" "$H/unit-new"; then u=new; elif cmp -s "$H/etc/kavita-epaper.service" "$H/unit-old"; then u=old; else u=OTHER; fi
  else u=ABSENT; fi
  cmp -s "$I/VERSION" "$R/VERSION" && v=new || v=old
  cmp -s "$I/app/main.py" "$R/app/main.py" && app=new || app=old
  cmp -s "$I/requirements.txt" "$R/requirements.txt" && reqs=new || reqs=old
  order=$(grep -E '^(pip install|systemctl stop)' "$H/calls" 2>/dev/null | sed -E 's/^pip.*/pip/; s/^systemctl stop.*/stop/' | tr '\n' '>' | sed 's/>$//')
  echo "version=$v app=$app reqs=$reqs unit=$u backups=$(ls "$H/backups" 2>/dev/null | wc -l) order=[${order:-none}]"
}

PASS=0; FAIL=0
# $1 label  $2 installed unit  $3 installed update.sh  $4 tarball  $5 ACTIVE_SEQ
# $6 PIP_RC  $7 reqs changed|same  $8 handoff|skip  $9 expected rc
# $10 expected state (exact)  $11 regex the output must match
run() {
  setup "$2" "$3" "$7"
  local hand=""; [ "$8" = skip ] && hand=1
  ACTIVE_SEQ=$5 PIP_RC=$6 KAVITA_EPAPER_UPDATE_HANDOFF=$hand bash "$H/opt/kavita-epaper/update.sh" "$H/rel/$4.tar.gz" > "$H/out" 2>&1; local rc=$?
  local st; st=$(state)
  if [ "$rc" = "$9" ] && [ "$st" = "${10}" ] && grep -qE "${11}" "$H/out"; then
    echo "PASS  $1"; PASS=$((PASS+1))
  else
    echo "FAIL  $1"; FAIL=$((FAIL+1))
    echo "      want rc=$9 ${10} /${11}/"
  fi
  echo "      rc=$rc $st"
  grep -E '^\[|^    ' "$H/out" | sed "s#$H#<H>#g; s/^/      /"
}

run "A unit changed, starts" old new good 1 0 changed skip \
  0 "version=new app=new reqs=new unit=new backups=1 order=[pip>stop]" 'updated and running'
run "B unit unchanged" new new good 1 0 changed skip \
  0 "version=new app=new reqs=new unit=new backups=0 order=[pip>stop]" 'updated and running'
run "C typo in new unit" old new typo 1 0 changed skip \
  1 "version=old app=old reqs=old unit=old backups=0 order=[none]" 'failed systemd-analyze verify'
run "D unit changed, start fails, rollback recovers" old new good 0,1 0 changed skip \
  1 "version=new app=new reqs=new unit=old backups=1 order=[pip>stop]" 'update is incomplete'
run "E unit changed, rollback also fails" old new good 0,0 0 changed skip \
  1 "version=new app=new reqs=new unit=old backups=1 order=[pip>stop]" 'still not running on the previous unit'
run "F no prior unit, start fails" none new good 0,0 0 changed skip \
  1 "version=new app=new reqs=new unit=ABSENT backups=0 order=[pip>stop]" 'no previous unit'
run "P1 requirements changed, pip ok" new new good 1 0 changed skip \
  0 "version=new app=new reqs=new unit=new backups=0 order=[pip>stop]" 'updating venv before stopping'
run "P2 requirements changed, pip FAILS" old new good 1 1 changed skip \
  1 "version=old app=old reqs=old unit=old backups=0 order=[pip]" 'was not stopped and is still running'
run "P3 requirements unchanged" new new good 1 0 same skip \
  0 "version=new app=new reqs=new unit=new backups=0 order=[stop]" 'unchanged, skipping pip'
run "C1 only constraints.txt changed" new new good 1 0 consold skip \
  0 "version=new app=new reqs=new unit=new backups=0 order=[pip>stop]" 'or constraints.txt changed, updating venv before stopping'
if grep -q "^pip install .* -c .*/extract/constraints.txt" "$H/calls" && cmp -s "$H/opt/kavita-epaper/constraints.txt" "$R/constraints.txt"; then
  echo "PASS  C1 pip got -c constraints.txt; installed constraints.txt replaced"; PASS=$((PASS+1))
else
  echo "FAIL  C1 pip call or installed constraints.txt"; FAIL=$((FAIL+1)); grep '^pip' "$H/calls" | sed 's/^/      /'
fi
run "H1 handoff from $OLD_REF update.sh" old old good 1 0 changed handoff \
  0 "version=new app=new reqs=new unit=new backups=1 order=[pip>stop]" 'handing off'
run "H2 handoff, pip FAILS" old old good 1 1 changed handoff \
  1 "version=old app=old reqs=old unit=old backups=0 order=[pip]" 'was not stopped and is still running'
# Session secret pre-check (0.7.21): a weak or missing secret stops the
# update before anything is stopped. SECRET_LINE replaces the .env secret
# line ("" = no line); SHOW_ENV is what `systemctl show -p Environment` prints.
SECRET_LINE="KAVITA_EPAPER_SECRET=too-short-secret" run "S1 secret too short" old new good 1 0 changed skip \
  1 "version=old app=old reqs=old unit=old backups=0 order=[none]" 'is too short \(16 characters, need at least 32\)'
SECRET_LINE="KAVITA_EPAPER_SECRET=CHANGE_ME_TO_A_LONG_RANDOM_STRING" run "S2 secret is the placeholder" old new good 1 0 changed skip \
  1 "version=old app=old reqs=old unit=old backups=0 order=[none]" 'still the placeholder'
SECRET_LINE="KAVITA_EPAPER_SECRET=\"$(printf 'q%.0s' $(seq 40))\"" run "S3 quoted 40-char secret is fine" old new good 1 0 changed skip \
  0 "version=new app=new reqs=new unit=new backups=1 order=[pip>stop]" 'updated and running'
SECRET_LINE="" run "S4 no secret anywhere" old new good 1 0 changed skip \
  1 "version=old app=old reqs=old unit=old backups=0 order=[none]" 'is not set in .*/\.env'
SECRET_LINE="" SHOW_ENV="KAVITA_EPAPER_SECRET=fromdropin" run "S5 secret only in a unit drop-in" old new good 1 0 changed skip \
  0 "version=new app=new reqs=new unit=new backups=1 order=[pip>stop]" 'updated and running'
SECRET_LINE="KAVITA_EPAPER_SECRET=short" run "S6 handoff from $OLD_REF, weak secret" old old good 1 0 changed handoff \
  1 "version=old app=old reqs=old unit=old backups=0 order=[none]" 'was not stopped and is still running'
if grep -q 'short' "$H/out" && ! grep -qE 'KAVITA_EPAPER_SECRET=short|too-short-secret' "$H/out"; then
  echo "PASS  secret value never printed"; PASS=$((PASS+1))
else
  echo "FAIL  secret value printed or message missing"; FAIL=$((FAIL+1))
fi

if cmp -s "$H/opt/kavita-epaper/update.sh" "$H/old.sh"; then
  echo "PASS  after H2 the installed update.sh is still $OLD_REF's"; PASS=$((PASS+1))
else
  echo "FAIL  after H2 the installed update.sh changed"; FAIL=$((FAIL+1))
fi
echo "== $PASS PASS, $FAIL FAIL of $((PASS+FAIL))"
[ "$FAIL" = 0 ]
