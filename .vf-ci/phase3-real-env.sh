#!/usr/bin/env bash
set -Eeuo pipefail

CURRENT_SRC="${1:?current source directory required}"
BASELINE_SRC="${2:?baseline source directory required}"
ROOT="${3:-/tmp/vf-forge-phase3}"
PHP_BIN="${PHP_BIN:-php}"
PASSWORD='Phase3-Test-Password-2026!'
RESULTS="$ROOT/results.log"
mkdir -p "$ROOT"
: > "$RESULTS"

pass(){ echo "PASS | $*" | tee -a "$RESULTS"; }
fail(){ echo "FAIL | $*" | tee -a "$RESULTS" >&2; exit 1; }
json_get(){ python3 -c 'import json,sys; d=json.load(sys.stdin); p=sys.argv[1].split(".");
for k in p:
    if k=="": continue
    d=d[int(k)] if isinstance(d,list) else d[k]
print("true" if d is True else "false" if d is False else "" if d is None else d)' "$1"; }
json_ok(){ python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("ok") is True else 1)'; }

server_pid=''
stop_server(){ if [[ -n "${server_pid:-}" ]] && kill -0 "$server_pid" 2>/dev/null; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi; server_pid=''; }
trap stop_server EXIT
start_server(){ local web="$1" port="$2"; stop_server; "$PHP_BIN" -d upload_max_filesize=128M -d post_max_size=160M -d memory_limit=512M -S "127.0.0.1:$port" -t "$web" >"$ROOT/php-$port.log" 2>&1 & server_pid=$!; for _ in $(seq 1 80); do curl -fsS "http://127.0.0.1:$port/setup.php" >/dev/null 2>&1 && return 0; curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1 && return 0; sleep .15; done; cat "$ROOT/php-$port.log" >&2; fail "PHP server failed on $port"; }
csrf_from_html(){ python3 -c 'import re,sys; s=sys.stdin.read(); m=re.search(r"name=\"setup_csrf\" value=\"([^\"]+)\"",s); print(m.group(1) if m else "")'; }

install_site(){ local web="$1" data="$2" port="$3" jar="$4"; rm -rf "$data" "$jar"; mkdir -p "$(dirname "$data")"; local base="http://127.0.0.1:$port" html token code; html=$(curl -fsS -c "$jar" "$base/setup.php"); token=$(printf '%s' "$html" | csrf_from_html); [[ ${#token} -ge 32 ]] || fail "setup csrf missing on $port"; code=$(curl -sS -o "$ROOT/setup-$port.out" -D "$ROOT/setup-$port.headers" -b "$jar" -c "$jar" -H "Origin: $base" --data-urlencode "setup_csrf=$token" --data-urlencode 'site_title=VF Forge Phase3' --data-urlencode "data_root=$data" --data-urlencode "password=$PASSWORD" --data-urlencode "password_confirm=$PASSWORD" -w '%{http_code}' "$base/setup.php"); [[ "$code" == 302 ]] || { cat "$ROOT/setup-$port.out" >&2; fail "setup expected 302 got $code"; }; [[ -f "$web/app/.runtime.php" ]] || fail "runtime missing after setup"; pass "clean install HTTP $port"; }
login_site(){ local port="$1" jar="$2"; local base="http://127.0.0.1:$port" out; out=$(curl -fsS -b "$jar" -c "$jar" -H "Origin: $base" -H 'Content-Type: application/json' --data "{\"password\":\"$PASSWORD\"}" "$base/api.php?action=login"); printf '%s' "$out" | json_ok || fail "login failed"; printf '%s' "$out" | json_get csrf; }
api_json(){ local port="$1" jar="$2" csrf="$3" action="$4" body="${5:-{}}"; local base="http://127.0.0.1:$port"; curl -fsS -b "$jar" -c "$jar" -H "Origin: $base" -H "X-CSRF-Token: $csrf" -H 'Content-Type: application/json' --data "$body" "$base/api.php?action=$action"; }
project_create(){ local port="$1" jar="$2" csrf="$3" name="$4" ver="$5" out; out=$(api_json "$port" "$jar" "$csrf" project_save "{\"name\":\"$name\",\"current_version\":\"$ver\",\"description\":\"phase3 real data\"}"); printf '%s' "$out" | json_ok || fail "project create failed"; printf '%s' "$out" | json_get project.id; }
upload_file(){ local port="$1" jar="$2" csrf="$3" pid="$4" file="$5"; local base="http://127.0.0.1:$port"; curl -fsS -b "$jar" -c "$jar" -H "Origin: $base" -H "X-CSRF-Token: $csrf" -F "project_id=$pid" -F 'status=active' -F "files=@$file" "$base/api.php?action=upload"; }
full_backup(){ local port="$1" jar="$2" csrf="$3" out id status; out=$(api_json "$port" "$jar" "$csrf" backup_full_start '{}'); printf '%s' "$out" | json_ok || fail "backup start failed"; id=$(printf '%s' "$out"|json_get backup.id); status=$(printf '%s' "$out"|json_get backup.status); for _ in $(seq 1 120); do [[ "$status" == completed ]] && { printf '%s' "$out"; return 0; }; out=$(api_json "$port" "$jar" "$csrf" backup_full_step "{\"id\":$id}"); status=$(printf '%s' "$out"|json_get backup.status); done; fail "backup did not complete"; }
find_db(){ local data="$1"; find "$data/database" -maxdepth 1 -type f -name '*.sqlite' | head -1; }

require_env(){
  "$PHP_BIN" -r 'foreach(["pdo_sqlite","fileinfo","zip"] as $e){if(!extension_loaded($e)){fwrite(STDERR,"missing:$e\n");exit(2);}} echo "php=".PHP_VERSION." sqlite=".SQLite3::version()["versionString"]."\n";' || fail "required PHP extensions missing"
  command -v sqlite3 >/dev/null || fail "sqlite3 CLI missing"
  command -v tar >/dev/null || fail "tar missing"
  pass "real PHP/PDO_SQLITE/sqlite3/ZipArchive environment"
}

clean_chain(){
  local web="$ROOT/clean-web" data="$ROOT/clean-data" port=18181 jar="$ROOT/clean.cookies"; rm -rf "$web" "$data"; mkdir -p "$web"; cp -a "$CURRENT_SRC"/. "$web"/; rm -rf "$web/.git" "$web/tests"; start_server "$web" "$port"; install_site "$web" "$data" "$port" "$jar"; local csrf pid sample up1 up2 backup backup_name backup_file db rid confirm out;
  csrf=$(login_site "$port" "$jar"); [[ -n "$csrf" ]] || fail "csrf missing after login"; pass "admin login + CSRF"
  pid=$(project_create "$port" "$jar" "$csrf" 'Phase3 Clean Project' 'V1.23.0'); [[ "$pid" =~ ^[0-9]+$ ]] || fail "project id invalid"; pass "project create/save/read path"
  sample="$ROOT/sample.txt"; printf 'vf-forge-phase3-%s\n' "$(date +%s)" > "$sample"; up1=$(upload_file "$port" "$jar" "$csrf" "$pid" "$sample"); printf '%s' "$up1"|json_ok || fail "upload failed"; [[ $(printf '%s' "$up1"|json_get duplicate_count) == 0 ]] || fail "first upload marked duplicate"; up2=$(upload_file "$port" "$jar" "$csrf" "$pid" "$sample"); [[ $(printf '%s' "$up2"|json_get duplicate_count) -ge 1 ]] || fail "duplicate upload not detected"; pass "private upload + SHA dedupe"
  backup=$(full_backup "$port" "$jar" "$csrf"); backup_name=$(printf '%s' "$backup"|json_get backup.filename); backup_file="$data/backups/$backup_name"; [[ -s "$backup_file" ]] || fail "full backup file missing"; pass "full backup completed + archive present"
  project_create "$port" "$jar" "$csrf" 'Post Backup Mutation' 'V9.9.9' >/dev/null; db=$(find_db "$data"); [[ -n "$db" ]] || fail "db not found"; [[ $(sqlite3 "$db" "select count(*) from projects where name='Post Backup Mutation';") == 1 ]] || fail "mutation missing before restore"
  out=$(curl -fsS -b "$jar" -c "$jar" -H "Origin: http://127.0.0.1:$port" -H "X-CSRF-Token: $csrf" -F "restore_file=@$backup_file" "http://127.0.0.1:$port/api.php?action=restore_preflight"); printf '%s' "$out"|json_ok || fail "restore preflight failed"; rid=$(printf '%s' "$out"|json_get restore.id); confirm=$(printf '%s' "$out"|json_get restore.conflict.protection.confirmation); [[ -n "$confirm" ]] || fail "restore confirmation missing"; out=$(api_json "$port" "$jar" "$csrf" restore_execute "{\"id\":$rid,\"confirmation\":\"$confirm\"}"); printf '%s' "$out"|json_ok || fail "restore execute failed"; db=$(find_db "$data"); [[ $(sqlite3 "$db" "pragma integrity_check;") == ok ]] || fail "restore db integrity"; [[ -z $(sqlite3 "$db" 'pragma foreign_key_check;') ]] || fail "restore fk errors"; [[ $(sqlite3 "$db" "select count(*) from projects where name='Post Backup Mutation';") == 0 ]] || fail "restore did not revert post-backup mutation"; [[ $(sqlite3 "$db" "select count(*) from projects where name='Phase3 Clean Project';") == 1 ]] || fail "restore lost backed project"; pass "full restore staging/switch/data rollback"
  "$PHP_BIN" "$web/cli/verify.php" > "$ROOT/clean-verify.json"; python3 - "$ROOT/clean-verify.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); assert x['ok'] is True, x
PY
  pass "post-restore CLI verify"
  stop_server
}

fault_matrix(){
  local web="$ROOT/fault-web" data="$ROOT/fault-data" port=18182 jar="$ROOT/fault.cookies"; rm -rf "$web" "$data"; mkdir -p "$web"; cp -a "$CURRENT_SRC"/. "$web"/; rm -rf "$web/.git" "$web/tests"; start_server "$web" "$port"; install_site "$web" "$data" "$port" "$jar"; local csrf pid db sample code out bid;
  csrf=$(login_site "$port" "$jar"); pid=$(project_create "$port" "$jar" "$csrf" 'Fault Project' 'V1.23.0'); db=$(find_db "$data"); sample="$ROOT/fault.txt"; echo 'fault-file' > "$sample"
  python3 - "$db" <<'PY' &
import sqlite3,sys,time
c=sqlite3.connect(sys.argv[1],timeout=1); c.execute('BEGIN EXCLUSIVE'); time.sleep(7); c.rollback()
PY
  lockpid=$!; sleep .4; code=$(curl -sS -o "$ROOT/locked.json" -w '%{http_code}' -b "$jar" -c "$jar" -H "Origin: http://127.0.0.1:$port" -H "X-CSRF-Token: $csrf" -H 'Content-Type: application/json' --data '{"name":"Must Not Commit While Locked"}' "http://127.0.0.1:$port/api.php?action=project_save"); wait "$lockpid" || true; [[ "$code" == 503 ]] || { cat "$ROOT/locked.json"; fail "sqlite locked expected 503 got $code"; }; grep -q 'SQLITE_BUSY' "$ROOT/locked.json" || fail "sqlite busy code missing"; [[ $(sqlite3 "$db" "select count(*) from projects where name='Must Not Commit While Locked';") == 0 ]] || fail "locked write committed"; pass "SQLite busy/locked explicit failure + no commit"
  chmod 0500 "$data/files"; code=$(curl -sS -o "$ROOT/writefail.json" -w '%{http_code}' -b "$jar" -c "$jar" -H "Origin: http://127.0.0.1:$port" -H "X-CSRF-Token: $csrf" -F "project_id=$pid" -F 'status=active' -F "files=@$sample" "http://127.0.0.1:$port/api.php?action=upload"); chmod 0750 "$data/files"; [[ "$code" == 422 ]] || { cat "$ROOT/writefail.json"; fail "write permission expected 422 got $code"; }; pass "private file write permission failure safely rejected"
  out=$(api_json "$port" "$jar" "$csrf" backup_full_start '{}'); bid=$(printf '%s' "$out"|json_get backup.id); out=$(api_json "$port" "$jar" "$csrf" backup_full_stop "{\"id\":$bid}"); [[ $(printf '%s' "$out"|json_get backup.status) == stopped ]] || fail "backup stop failed"; [[ ! -e "$data/locks/maintenance.json" ]] || fail "backup stop left maintenance lock"; ! find "$data/backups" -maxdepth 1 -name '*.part' -print -quit | grep -q . || fail "backup stop left part"; pass "backup interruption/stop cleanup"
  printf 'not-a-valid-backup' > "$ROOT/corrupt.tar.gz"; code=$(curl -sS -o "$ROOT/corrupt.json" -w '%{http_code}' -b "$jar" -c "$jar" -H "Origin: http://127.0.0.1:$port" -H "X-CSRF-Token: $csrf" -F "restore_file=@$ROOT/corrupt.tar.gz" "http://127.0.0.1:$port/api.php?action=restore_preflight"); [[ "$code" =~ ^(400|422|500)$ ]] || fail "corrupt restore unexpectedly accepted: $code"; [[ ! -e "$data/locks/maintenance.json" ]] || fail "corrupt restore left maintenance lock"; pass "corrupt restore rejected without lock residue"
  if "$PHP_BIN" -n "$web/cli/check-requirements.php" >"$ROOT/deps-missing.out" 2>&1; then fail "dependency-missing check unexpectedly passed"; fi; pass "dependency missing is detected"
  stop_server
}

dirty_atomic(){
  local web="$ROOT/dirty-web" data="$ROOT/dirty-data" port=18183 jar="$ROOT/dirty.cookies" atomicdir="$ROOT/atomic"; rm -rf "$web" "$data" "$atomicdir"; mkdir -p "$web" "$atomicdir"; cp -a "$BASELINE_SRC"/. "$web"/; rm -rf "$web/.git"; start_server "$web" "$port"; install_site "$web" "$data" "$port" "$jar"; local csrf pid sample up before db zip repair ready exec token cont version code;
  csrf=$(login_site "$port" "$jar"); pid=$(project_create "$port" "$jar" "$csrf" 'Dirty V121 Project' 'V1.21.1'); sample="$ROOT/dirty.txt"; echo 'dirty-persistent-data' > "$sample"; up=$(upload_file "$port" "$jar" "$csrf" "$pid" "$sample"); printf '%s' "$up"|json_ok || fail "baseline upload failed"; db=$(find_db "$data"); before=$(sqlite3 "$db" "select count(*) from projects where name='Dirty V121 Project';"); [[ "$before" == 1 ]] || fail "baseline business data missing"; echo '<?php echo "old repair";' > "$web/repair-v1.20.0.php"; mkdir -p "$data/temp/old-cache"; echo stale > "$data/temp/old-cache/legacy.cache"
  "$PHP_BIN" "$CURRENT_SRC/cli/build-atomic.php" --out="$atomicdir" --from=1.21.1,1.22.0 > "$ROOT/atomic-build.out"; zip=$(tail -1 "$ROOT/atomic-build.out"); [[ -s "$zip" ]] || fail "atomic zip missing"; unzip -q "$zip" -d "$web"; repair=$(find "$web" -maxdepth 1 -type f -name 'repair-v1.23.0.php' | head -1); [[ -n "$repair" ]] || fail "repair script missing";
  ready=$(curl -fsS -b "$jar" -c "$jar" "http://127.0.0.1:$port/$(basename "$repair")"); grep -q '准备升级' <<<"$ready" || fail "atomic not ready on v1.21.1"; exec=$(curl -fsS -b "$jar" -c "$jar" -H "Origin: http://127.0.0.1:$port" --data-urlencode "csrf=$csrf" --data-urlencode 'atomic_action=execute' "http://127.0.0.1:$port/$(basename "$repair")"); token=$(grep -oE 'atomic_continue=[a-f0-9]{32}' <<<"$exec" | head -1 | cut -d= -f2); [[ ${#token} == 32 ]] || fail "atomic continuation token missing"; cont=$(curl -fsS -b "$jar" -c "$jar" -H "Origin: http://127.0.0.1:$port" --data-urlencode "csrf=$csrf" --data-urlencode 'atomic_action=continue' "http://127.0.0.1:$port/$(basename "$repair")?atomic_continue=$token"); grep -q '升级成功' <<<"$cont" || { echo "$cont" > "$ROOT/atomic-fail.html"; fail "atomic v1.21.1 -> v1.23.0 failed"; }
  db=$(find_db "$data"); [[ $(sqlite3 "$db" "select count(*) from projects where name='Dirty V121 Project';") == 1 ]] || fail "atomic lost project data"; [[ $(sqlite3 "$db" 'pragma integrity_check;') == ok ]] || fail "atomic db integrity"; [[ -z $(sqlite3 "$db" 'pragma foreign_key_check;') ]] || fail "atomic fk"; [[ ! -e "$web/repair-v1.20.0.php" ]] || fail "old repair residue not cleaned"; [[ ! -e "$repair" ]] || fail "current repair not self cleaned"; [[ -f "$data/temp/old-cache/legacy.cache" ]] || fail "atomic mutated unrelated private residue"; pass "dirty V1.21.1 -> V1.23.0 Atomic + data preservation + repair cleanup"
  unzip -q "$zip" -d "$web"; repair="$web/repair-v1.23.0.php"; ready=$(curl -fsS -b "$jar" -c "$jar" "http://127.0.0.1:$port/$(basename "$repair")"); grep -q '当前版本不可升级\|当前已经是目标版本' <<<"$ready" || fail "repeat atomic not safely blocked/no-op"; [[ $(sqlite3 "$db" "select count(*) from projects where name='Dirty V121 Project';") == 1 ]] || fail "repeat atomic changed data"; pass "Atomic repeat execution safely blocked/no-op"
  stop_server
}

atomic_migration_failure(){
  local web="$ROOT/atomic-fail-web" data="$ROOT/atomic-fail-data" port=18184 jar="$ROOT/atomic-fail.cookies" fail_src="$ROOT/current-fail-src" atomicdir="$ROOT/atomic-fail-dist"; rm -rf "$web" "$data" "$fail_src" "$atomicdir"; mkdir -p "$web" "$fail_src" "$atomicdir"; cp -a "$BASELINE_SRC"/. "$web"/; cp -a "$CURRENT_SRC"/. "$fail_src"/; rm -rf "$web/.git" "$fail_src/.git" "$fail_src/tests"; start_server "$web" "$port"; install_site "$web" "$data" "$port" "$jar"; local csrf pid db before zip repair exec token cont;
  csrf=$(login_site "$port" "$jar"); pid=$(project_create "$port" "$jar" "$csrf" 'Atomic Rollback Sentinel' 'V1.21.1'); db=$(find_db "$data"); before=$(sha256sum "$db" | awk '{print $1}');
  python3 - "$fail_src/app/MigrationRunner.php" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read()
needle='public function run(): array'
pos=s.find(needle)
if pos<0: raise SystemExit('run method missing')
brace=s.find('{',pos)
s=s[:brace+1]+"\n        throw new RuntimeException('PHASE3_INJECTED_MIGRATION_FAILURE');"+s[brace+1:]
open(p,'w').write(s)
PY
  "$PHP_BIN" "$fail_src/cli/build-atomic.php" --out="$atomicdir" --from=1.21.1,1.22.0 > "$ROOT/atomic-fail-build.out"; zip=$(tail -1 "$ROOT/atomic-fail-build.out"); unzip -q "$zip" -d "$web"; repair="$web/repair-v1.23.0.php";
  exec=$(curl -fsS -b "$jar" -c "$jar" -H "Origin: http://127.0.0.1:$port" --data-urlencode "csrf=$csrf" --data-urlencode 'atomic_action=execute' "http://127.0.0.1:$port/$(basename "$repair")"); token=$(grep -oE 'atomic_continue=[a-f0-9]{32}' <<<"$exec" | head -1 | cut -d= -f2); [[ ${#token} == 32 ]] || fail "atomic failure continuation missing"; cont=$(curl -fsS -b "$jar" -c "$jar" -H "Origin: http://127.0.0.1:$port" --data-urlencode "csrf=$csrf" --data-urlencode 'atomic_action=continue' "http://127.0.0.1:$port/$(basename "$repair")?atomic_continue=$token"); grep -q '升级失败' <<<"$cont" || fail "injected migration failure did not fail"; grep -q '回滚.*PASS\|已回滚' <<<"$cont" || fail "atomic rollback not reported PASS"; db=$(find_db "$data"); [[ $(sqlite3 "$db" "select count(*) from projects where name='Atomic Rollback Sentinel';") == 1 ]] || fail "rollback lost sentinel data"; grep -Eq "define\('VFAB_VERSION', *'1\.21\.1'\)" "$web/app/bootstrap.php" || fail "source not rolled back to v1.21.1"; [[ ! -e "$data/locks/maintenance.json" ]] || fail "successful atomic rollback left lock"; pass "Atomic source-switched Migration failure -> source/DB/config rollback"
  stop_server
}

require_env
clean_chain
fault_matrix
dirty_atomic
atomic_migration_failure
pass "PHASE3_REAL_ENV_CORE_COMPLETE"
cat "$RESULTS"
