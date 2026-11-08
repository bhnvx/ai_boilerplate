#!/usr/bin/env bash
# tests/hooks/test-guards-migrations-5.sh — guard-migrations.sh 회귀 테스트(3차 수정 S1–S5)
# S1 돌지 않은 절대 cd 뒤의 상대 cd(미끼 디렉터리) · S2 명령 안의 HOME 변경·치환된 명령 단어 · S3 미리 보기(*-sql·--sql)를 DB 클라이언트로 넘김
# S4 남은 틈(docker compose cp·bash --norc -c·git --work-tree·git restore 줄인 옵션·64개 한도의 유효 cwd) · S5 Edit/Write 경로는 저장소 루트 기준
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
t_setup
HOOK="$T_HOOKS/guard-migrations.sh"
AGENT_ID='{"agent_id":"agent-1","agent_type":"implementer"}'
run() { t_run_hook "$HOOK" "$1"; }
tb()  { run "$(t_bash_json "$3" "${4:-}" "${5:-}" "${6:-}")"; assert_decision "$1" "$2"; }   # <name> <expect> <cmd> [cwd] [mode] [extra]
tbs() { tb "$1" "$2" "$3" "${4:-}" default "$AGENT_ID"; }                                       # 서브에이전트
trs() { assert_contains "$1" "$(t_reason "$T_OUT")" "$2"; }
tm()  {  # <name> <expect> <cmd> [extra] — Monitor (bash 3.2 의 "$( … \" … )" 중첩 문제를 피하려고 변수로 먼저 만든다)
  local j mi; j=$(t_json_str "$3"); mi="{\"command\":$j}"
  run "$(t_pre_json Monitor "$mi" "" default "${4:-}")"; assert_decision "$1" "$2"
}
tf()  {  # <name> <expect> <tool> <path> [cwd] [mode] [extra] [content] — Edit/Write/MultiEdit
  local fp ct ti; fp=$(t_json_str "$4"); ct=$(t_json_str "${8:-x = 1}")
  ti="{\"file_path\":$fp,\"content\":$ct,\"old_string\":\"a\",\"new_string\":$ct}"
  run "$(t_pre_json "$3" "$ti" "${5:-}" "${6:-}" "${7:-}")"; assert_decision "$1" "$2"
}
blk() {  # <rule> <cmd> [cwd] — 메인 ask(규칙 id, auto 에서도 ask = ask-high), 서브에이전트 deny
  tb "block: $2" ask "$2" "${3:-}"; trs "block rule id: $2" "[migrations:$1]"
  tb "block stays ask in auto: $2" ask "$2" "${3:-}" auto
  tbs "subagent block: $2" deny "$2" "${3:-}"
}
crt() { tb "create (main none): $1" none "$1" "${2:-}"; tbs "create (subagent deny): $1" deny "$1" "${2:-}"; }   # 새 마이그레이션 생성
pas() { tb "pass: $1" none "$1" "${2:-}"; tbs "subagent pass: $1" none "$1" "${2:-}"; }
apl() {  # <cmd> — ask-low(auto 에서 조용히 통과), 서브에이전트 deny
  tb "apply: $1" ask "$1"; trs "apply rule id: $1" "[migrations:apply]"
  tb "apply silenced in auto: $1" none "$1" "" auto
  tbs "subagent apply: $1" deny "$1"
}
rbk() { tb "rollback main (guard-destructive owns the ask): $1" none "$1"; tbs "rollback subagent: $1" deny "$1"; }
t_ms() {  # 벽시계 ms(test-guards-destructive-2.sh 와 같다)
  if command -v python3 >/dev/null 2>&1; then python3 -I -S -c 'import time; print(int(time.time()*1000))'
  elif command -v perl >/dev/null 2>&1; then perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'
  else echo 0; fi
}
t_under() { [ "$2" -lt "$3" ] && t_pass "$1 (${2}ms < ${3}ms)" || t_fail "$1" "${2}ms ≥ ${3}ms"; }

mkdir -p "$T_PROJ/migrations" "$T_PROJ/app/migrations" "$T_PROJ/app/src" "$T_PROJ/src"
printf 'from django.db import migrations\n' >"$T_PROJ/migrations/0001_initial.py"
printf 'from django.db import migrations\n' >"$T_PROJ/app/migrations/0001_initial.py"
printf '# app only\n' >"$T_PROJ/app/migrations/0005_app_only.py"
printf 'x = 1\n' >"$T_PROJ/template.py"
DECOY="$T_TMP/decoy"   # 같은 이름의 하위 디렉터리(app·src)를 가진 미끼 — 마이그레이션 파일은 없다
mkdir -p "$DECOY/app" "$DECOY/src" "$T_TMP/d1/d2"
APP="$T_PROJ/app"
rep() { local c='' i=1; while [ "$i" -le "$2" ]; do c="$c$1$i); "; i=$((i + 1)); done; printf '%s' "$c$3"; }   # (cd /nx1); … (cd /nxN); <끝>

t_section "S1: 돌지 않았을 수 있는 절대 cd 뒤의 상대 cd 는 세션 cwd·닿은 모든 디렉터리 기준으로도 푼다"
for c in "false && cd '$DECOY'; cd app; echo x > migrations/0005_app_only.py" "cd '$DECOY' & cd app; echo x > migrations/0005_app_only.py" \
  "cd '$DECOY' | true; cd app && echo x > migrations/0005_app_only.py" "if false; then cd '$DECOY'; fi; cd app; echo x > migrations/0005_app_only.py" \
  "false && cd '$DECOY'; cd app && sed -i '' s/a/b/ migrations/0005_app_only.py" "false && cd '$DECOY'; cd ./app/ && cp template.py migrations/0005_app_only.py" \
  "sh -c \"false && cd '$DECOY'; cd app; echo x > migrations/0005_app_only.py\""; do
  blk edit-existing "$c"
done
blk edit-existing "false && cd '$DECOY/src'; cd ../app; echo x > migrations/0005_app_only.py" "$T_PROJ/src"   # 세션 cwd 가 src: ../app 은 프로젝트의 app
blk delete "false && cd '$DECOY'; cd app && git rm migrations/0005_app_only.py"
blk edit-existing "false && cd '$T_TMP/d1/d2'; cd ..; echo x > 'proj dir/migrations/0001_initial.py'"   # 세션 cwd 의 부모(T_TMP)도 후보
tm "Monitor decoy cd then relative cd → ask" ask "false && cd '$DECOY'; cd app; echo x > migrations/0005_app_only.py"
tm "Monitor decoy cd then relative cd (subagent) → deny" deny "false && cd '$DECOY'; cd app; echo x > migrations/0005_app_only.py" "$AGENT_ID"
blk edit-existing "$(rep '(cd /nx' 64 "false && cd '$DECOY'; cd app; echo x > migrations/0009_new.py")"   # 64개 한도를 넘으면 상대 경로는 있는 파일로
crt "false && cd '$DECOY'; cd app; echo x > migrations/0009_new.py"
crt "cd '$DECOY' & cd app; cat > migrations/0009_new.py <<'EOF'"$'\nx = 1\nEOF'
crt "cd app && cd src; echo x > migrations/0009_new.py"
pas "false && cd '$DECOY'; cd app; cat migrations/0005_app_only.py > /tmp/x.py"
pas "cd '$DECOY' && cd src && echo x > out.txt; ls migrations"
pas "false && cd '$DECOY'; cd app; ls migrations > /tmp/list.txt"
MANY="$T_TMP/many"; i=0; while [ "$i" -lt 64 ]; do mkdir -p "$MANY/d$i/sub"; i=$((i + 1)); done   # 비용 상한: 있는 디렉터리 64개
big() {  # <앞 cd 개수> <반복 단위> <반복 수> <끝> — (cd '<있는 디렉터리>') … 뒤에 같은 단위를 반복
  local c='' i=0
  while [ "$i" -lt "$1" ]; do c="$c(cd '$MANY/d$i'); "; i=$((i + 1)); done
  i=0; while [ "$i" -lt "$3" ]; do c="$c${2//@/$i}; "; i=$((i + 1)); done
  printf '%s' "$c$4"
}
C=$(big 40 'cd x@' 1500 'echo x > migrations/0009_new.py'); tb 'cost cap: 40 dirs + 1500 distinct relative cds → ask (candidates overflow)' ask "$C"; assert_rc 'cost cap cds' 0
tbs 'cost cap: 40 dirs + 1500 distinct relative cds (subagent) → deny' deny "$C"
C=$(big 60 'echo x > migrations/n@.sql' 600 'echo x > migrations/0009_new.py'); tb 'cost cap: 60 dirs + 600 relative migration writes → ask (treated as existing)' ask "$C"; assert_rc 'cost cap writes' 0
trs 'cost cap writes rule id' '[migrations:edit-existing]'
C=$(big 60 'echo x > n@.txt' 5 'echo x > migrations/0009_new.py'); tb 'under the cost cap: 60 dirs + 5 writes, new migration → none' none "$C"
GA="$T_TMP/tools/goose/app"   # 후보 디렉터리는 존재 판정에만 쓴다 — 저장소 밖 조상(…/goose)의 이름으로 마이그레이션이 되지 않는다
mkdir -p "$GA/web" && (cd "$GA" && t_git init -q .) || exit 1
for c in 'cd web && cd .. && echo x > notes.txt; ls migrations' 'cd web; cd ..; echo x >> status.log; cat migrations/0001_initial.py' \
  'false && cd /tmp; cd ..; echo x > notes.txt; ls migrations'; do
  pas "$c" "$GA"
done

t_section "S2: 명령 안에서 HOME 을 바꾸면 맨 cd·~ 경로는 모르는 위치, 명령 단어가 \$ 로 시작하면 모르는 cwd 변경"
for c in "HOME='$APP' cd; echo x > migrations/0005_app_only.py" "export HOME='$APP'; echo x > ~/migrations/0005_app_only.py" \
  '$(echo cd) app; echo x > migrations/0005_app_only.py' 'c=cd; $c app; echo x > migrations/0005_app_only.py' \
  '`echo cd` app; echo x > migrations/0005_app_only.py' 'c=cd; "$c" app && echo x > migrations/0005_app_only.py' \
  '${CD:-cd} app; echo x > migrations/0005_app_only.py' "HOME='$APP'; cd ~ && echo x > migrations/0005_app_only.py" \
  "HOME='$T_PROJ' cd ~/app && echo x > migrations/0005_app_only.py" "env HOME='$APP' sh -c 'cd; echo x > migrations/0005_app_only.py'" \
  "export HOME='$APP'; sed -i '' s/a/b/ ~/migrations/0005_app_only.py" "echo x > ~/migrations/0005_app_only.py; export HOME='$APP'"; do
  blk edit-existing "$c"
done
tm "Monitor HOME= cd → ask" ask "HOME='$APP' cd; echo x > migrations/0005_app_only.py"
tm "Monitor \$c cd (subagent) → deny" deny 'c=cd; $c app; echo x > migrations/0005_app_only.py' "$AGENT_ID"
blk edit-existing 'c=cdx; ${c/x/} app; echo x > migrations/0005_app_only.py'   # ${…} 안의 / 는 펼친 단어에 남지 않는다
blk edit-existing 'a=cdx; b=x; ${a/${b}/} app; echo x > migrations/0005_app_only.py'
for c in 'cd; echo x > migrations/0009_new.py' 'cd ~ && echo x > migrations/0009_new.py' 'echo x > ~/migrations/0009_new.py' \
  "JAVA_HOME=/opt/jdk cd; echo x > migrations/0009_new.py" "export PYTHONHOME=/opt/py; echo x > ~/migrations/0009_new.py" \
  '$VIRTUAL_ENV/bin/python manage.py check && echo x > migrations/0009_new.py' '"$(npm bin)/knex" migrate:list; echo x > migrations/0009_new.py' \
  '"${VIRTUAL_ENV}/bin/python" -m pytest -q; echo x > migrations/0009_new.py'; do
  crt "$c"   # 경로로 실행하는 외부 명령($…/…)은 셸 cwd 를 바꾸지 못한다
done
for c in "export HOME='$APP'; cat ~/migrations/0005_app_only.py" '$(echo cd) app; cat migrations/0005_app_only.py > /tmp/x.py' \
  'c=cd; $c app; ls migrations' "HOME='$APP' cd; ls migrations"; do
  pas "$c"
done

t_section "S3: 미리 보기(liquibase *-sql·alembic/flask --sql)는 뒤 단어도 보고, DB 클라이언트로 넘기면 적용·롤백"
for c in 'liquibase --changelog-file changes-sql update' 'liquibase --changelog-file changes-sql --url jdbc:x update-count 2' \
  'liquibase update-sql | psql "$DATABASE_URL"' 'alembic upgrade head --sql | psql "$DB"' 'flask db upgrade --sql | psql "$DB"' \
  'liquibase --changelog-file=x.xml updateSQL | mysql -u app app' 'alembic upgrade head --sql | tee upgrade.sql | psql "$DB"' \
  'liquibase update-sql 2>/dev/null | sqlite3 app.db' 'liquibase update-sql | docker compose exec -T db psql -U app' \
  'liquibase update-sql | kubectl exec -i pg-0 -- psql -U app' 'alembic upgrade head --sql |& mariadb app' \
  'python -m alembic upgrade head --sql | sqlcmd -S db' 'liquibase update-count-sql 2 | clickhouse-client' \
  'liquibase update-sql | grep -v "^--" | psql "$DB"' 'alembic upgrade head --sql | PGPASSWORD=x psql -h db app' \
  "sh -c 'alembic upgrade head --sql | psql \"\$DB\"'" 'liquibase update-sql --url "jdbc:a|b" | psql' 'liquibase  update-sql   |   psql' \
  $'liquibase --changelog-file=x.xml \\\n  update-sql | psql "$DB"' $'alembic upgrade head --sql \\\n  | psql "$DB"'; do
  apl "$c"
done
for c in 'alembic downgrade -1 --sql | psql "$DB"' 'liquibase rollback-sql v1 | psql "$DB"' 'liquibase future-rollback-sql | mysql app' \
  'flask db downgrade --sql | psql "$DB"'; do
  rbk "$c"
done
for c in 'liquibase update-sql > out.sql' 'alembic upgrade head --sql > x.sql' 'liquibase update-sql | less' \
  'alembic upgrade head --sql | tee upgrade.sql' 'liquibase update-sql | grep -c CREATE' 'liquibase --changelog-file changes-sql status' \
  "alembic upgrade head --sql > x.sql; psql -c 'select 1'" "liquibase update-sql || psql -c 'select 1'" \
  "echo 'select 1' | psql; liquibase update-sql" 'liquibase rollback-sql v1 > rollback.sql' \
  'liquibase rollback-sql v1 --output-file rollback.sql' 'liquibase update-sql --output-file update-v2.sql'; do
  pas "$c"
done
rp() { local c='' i=0; while [ "$i" -lt "$2" ]; do c="$c$1; "; i=$((i + 1)); done; printf '%s' "$c$3"; }
C=$(rp 'liquibase update-sql | tee a.sql' 70 'echo ok'); tb '70 preview|tee segments → none (bounded pipe checks)' none "$C"; assert_rc '70 preview|tee' 0
tbs '70 preview|tee segments (subagent) → none' none "$C"
C=$(rp 'liquibase update-sql | tee a.sql' 70 'psql -f a.sql'); tb 'past 64 pipe checks a later DB client counts (conservative) → ask' ask "$C"

t_section "S4: docker compose cp·셸 -c 묶음·git --work-tree·git restore 줄인 옵션·64개 한도에서도 유효 cwd"
for c in 'docker compose cp fix.py web:/app/migrations/0001_initial.py' 'docker compose -f dc.yml cp fix.py web:/app/migrations/0001_initial.py' \
  'docker compose --project-directory ./ops cp fix.py web:/app/migrations/' 'docker compose cp --index 2 fix.py web:/app/migrations/0001_initial.py' \
  "docker-compose exec web bash --norc -c 'echo x > /app/migrations/0009_new.py'" "nerdctl exec web bash --norc -c 'echo x > /app/migrations/0009_new.py'" \
  "docker run --rm img bash --norc -c 'echo x > /app/migrations/0009_new.py'" "docker container exec web bash --rcfile /etc/x -c 'echo x > /app/migrations/0009_new.py'" \
  "podman exec web bash --norc -c 'echo x > /app/migrations/0009_new.py'" "docker run --rm img sh -xc 'echo x > /app/migrations/0009_new.py'" \
  'git --work-tree=app checkout HEAD~1 -- migrations/0005_app_only.py' 'git --work-tree app checkout HEAD~1 -- migrations/0005_app_only.py' \
  'git --work-tree=app restore migrations/0005_app_only.py' "git -C '$T_PROJ' --work-tree=app checkout -- migrations/0005_app_only.py" \
  'git restore --staged --wor migrations/0001_initial.py' 'git restore --sta --w migrations/0001_initial.py' \
  'git restore --so=HEAD~1 migrations/0001_initial.py' 'git restore --sou HEAD~1 --staged --worktree migrations/0001_initial.py'; do
  blk edit-existing "$c"
done
blk delete "$(rep '(cd /nx' 64 'cd migrations && rm 0001_initial.py')"
blk edit-existing "$(rep '(cd /nx' 64 'cd migrations && echo x > 0001_initial.py')"
blk delete "$(rep '(cd /nx' 63 'cd migrations && rm 0001_initial.py')"   # 한도 아래(대조군)
crt 'git --work-tree=app checkout HEAD~1 -- migrations/0009_new.py'
for c in 'docker compose cp web:/app/migrations/0001_initial.py /tmp/x.py' 'docker compose cp fix.py web:/app/src/x.py' \
  "docker-compose exec web bash --norc -c 'cat /app/migrations/0001_initial.py'" 'nerdctl exec web bash --norc migrate-check.sh' \
  'git --work-tree=app status' 'git --work-tree=app diff migrations/ > /tmp/x.patch' 'git restore --sta migrations/0001_initial.py' \
  'git restore --stag --so HEAD~1 migrations/0001_initial.py' "$(rep '(cd /nx' 64 'cd src && rm old.py; ls migrations')"; do
  pas "$c"
done

t_section "S5: Edit/Write 는 세션 cwd 아래 파일을 저장소 루트 기준 경로로 판정(도구 이름 디렉터리에 클론한 저장소)"
for name in goose flyway liquibase dbmate drizzle migrations; do
  R="$T_TMP/tools/$name/app"
  mkdir -p "$R/src" "$R/migrations" "$T_TMP/tools/$name/other" && (cd "$R" && t_git init -q .) || exit 1
  printf 'x = 1\n' >"$R/src/app.py"; printf 'x = 1\n' >"$R/migrations/0001_initial.py"; printf 'x\n' >"$T_TMP/tools/$name/other/x.ts"
  for t in Edit Write MultiEdit; do
    tf "$t $name/app/src/app.py (cwd = repo root) → none" none $t "$R/src/app.py" "$R"
    tf "$t $name/app/src/app.py (subagent) → none" none $t "$R/src/app.py" "$R" default "$AGENT_ID"
  done
  tf "Edit relative src/app.py under $name/app → none" none Edit 'src/app.py' "$R"
  tf "Write new src/new.py under $name/app → none" none Write "$R/src/new.py" "$R"
  tf "Write new src/new.py under $name/app (subagent) → none" none Write "$R/src/new.py" "$R" default "$AGENT_ID"
  tf "Edit $name/app/migrations/0001_initial.py (existing) → ask" ask Edit "$R/migrations/0001_initial.py" "$R"
  trs "Edit $name existing migration rule id" "[migrations:edit-existing]"
  tf "Edit $name/app/migrations/0001_initial.py (subagent) → deny" deny Edit "$R/migrations/0001_initial.py" "$R" default "$AGENT_ID"
  tf "Write new $name/app/migrations/0009_new.py → none (creation)" none Write "$R/migrations/0009_new.py" "$R"
  tf "Write new $name/app/migrations/0009_new.py (subagent) → deny" deny Write "$R/migrations/0009_new.py" "$R" default "$AGENT_ID"
  tf "Write destructive new migration under $name/app → ask" ask Write "$R/migrations/0009_drop.py" "$R" default "" 'op.drop_table("users")'
  trs "Write destructive new migration under $name rule id" "[migrations:destructive-schema]"
  tf "Edit $name/other/x.ts (outside the session cwd keeps the absolute path) → ask" ask Edit "$T_TMP/tools/$name/other/x.ts" "$R"
  tf "Edit $name/other/x.ts outside the cwd (subagent) → deny" deny Edit "$T_TMP/tools/$name/other/x.ts" "$R" default "$AGENT_ID"
done
for t in Edit Write MultiEdit; do
  tf "$t <cwd>/migrations/0001_initial.py → ask (unchanged)" ask $t "$T_PROJ/migrations/0001_initial.py"
  trs "$t <cwd>/migrations/0001_initial.py rule id" "[migrations:edit-existing]"
  tf "$t <cwd>/migrations/0001_initial.py (subagent) → deny" deny $t "$T_PROJ/migrations/0001_initial.py" "" default "$AGENT_ID"
  tf "$t 0001_initial.py with cwd inside migrations → ask" ask $t '0001_initial.py' "$T_PROJ/migrations"
  tf "$t absolute path with cwd inside migrations → ask" ask $t "$T_PROJ/migrations/0001_initial.py" "$T_PROJ/migrations"
  tf "$t 0001_initial.py with cwd inside migrations (subagent) → deny" deny $t '0001_initial.py' "$T_PROJ/migrations" default "$AGENT_ID"
  tf "$t <cwd>/app/migrations/0005_app_only.py with cwd app → ask" ask $t "$APP/migrations/0005_app_only.py" "$APP"
  tf "$t migrations/__pycache__/../0001_initial.py → ask" ask $t 'migrations/__pycache__/../0001_initial.py'
  tf "$t src/../migrations/0001_initial.py → ask" ask $t 'src/../migrations/0001_initial.py'
  tf "$t <cwd>/src/app.py → none" none $t "$T_PROJ/src/app.py"
done
NR="$T_TMP/norepo/drizzle/app"   # 저장소가 아니면 예전처럼 절대 경로로 판정한다
mkdir -p "$NR/src" && printf 'x = 1\n' >"$NR/src/app.py"
tf "Edit under a tool-named dir without a git repo → ask (absolute path, unchanged)" ask Edit "$NR/src/app.py" "$NR"
tf "Edit under a tool-named dir without a git repo (subagent) → deny" deny Edit "$NR/src/app.py" "$NR" default "$AGENT_ID"
pas 'echo x > src/app.py' "$T_TMP/tools/drizzle/app"
t_section "리뷰 3차: 미리 보기가 있는 명령의 원문 비교는 선형 시간(큰 heredoc 이 10초 제한을 넘겨 판정 없이 통과하지 않게)"
{ printf "cat > migrations/0009_add.py <<'EOF'\n"; i=0
  while [ "$i" -lt 70 ]; do printf "    op.create_table(\n        't%s',\n        sa.Column('id', sa.Integer()),\n    )\n" "$i"; i=$((i + 1)); done
  printf 'EOF\nalembic upgrade head --sql | psql "$DB"'; } >"$T_TMP/cmd.txt"
t0=$(t_ms); run "$(t_bash_json_file "$T_TMP/cmd.txt")"; t1=$(t_ms)
assert_decision "heredoc new migration + preview | psql → ask (apply)" ask; assert_rc "heredoc + preview" 0
t_under "heredoc ($(wc -l <"$T_TMP/cmd.txt" | tr -d ' ') lines) + preview" $((t1 - t0)) 3000
run "$(t_bash_json_file "$T_TMP/cmd.txt" "" default "$AGENT_ID")"; assert_decision "heredoc + preview (subagent) → deny" deny
{ printf 'liquibase update-sql --x "'; i=0; while [ "$i" -lt 3000 ]; do printf ' \t'; i=$((i + 1)); done; printf '" > out.sql'; } >"$T_TMP/cmd.txt"
t0=$(t_ms); run "$(t_bash_json_file "$T_TMP/cmd.txt")"; t1=$(t_ms)
assert_decision "preview with 6KB of spaces and tabs → none" none; t_under "preview + 6KB whitespace" $((t1 - t0)) 3000
{ printf 'echo "'; i=0; while [ "$i" -lt 3000 ]; do printf '>|'; i=$((i + 1)); done; printf '"; echo x >| migrations/0001_initial.py'; } >"$T_TMP/cmd.txt"
t0=$(t_ms); run "$(t_bash_json_file "$T_TMP/cmd.txt")"; t1=$(t_ms)   # >| 를 > 로 바꾸는 곳도 선형(r2b 부터 2차 비용)
assert_decision "3000 >| in a string, then >| onto an existing migration → ask" ask; t_under "3000 >| rewrite" $((t1 - t0)) 3000
for h in 'liquibase update-sql' 'liquibase status'; do   # 도구 단어 뒤 단어가 수천 개(미리 보기 뒤에도 끝까지 본다)
  { printf '%s' "$h"; i=0; while [ "$i" -lt 6000 ]; do printf ' a'; i=$((i + 1)); done; printf ' > /dev/null; echo x > migrations/0001_initial.py'; } >"$T_TMP/cmd.txt"
  t0=$(t_ms); run "$(t_bash_json_file "$T_TMP/cmd.txt")"; t1=$(t_ms)
  assert_decision "$h + 6000 words, then an existing migration write → ask" ask; t_under "$h + 6000 words" $((t1 - t0)) 3000
done

t_section "리뷰 3차: 미리 보기 세그먼트의 \$(…)·백틱·붙여 쓴 리디렉션·따옴표 친 명령 이름, 더 많은 DB 클라이언트"
for c in 'liquibase --url="$(cat .dburl)" update-sql | psql "$DB"' 'alembic -x url=`cat .url` upgrade head --sql | psql "$DB"' \
  'liquibase --password=$(cat .pw) update-sql | psql "$DB"' 'alembic upgrade head --sql</dev/null | psql "$DB"' \
  '"liquibase" update-sql | psql "$DB"' 'alembic upgrade head --sql | grep -v "$(printf x)" | psql "$DB"' \
  'liquibase update-sql | sqlplus app@db' 'liquibase update-sql | mysqlsh --sql app@db' 'alembic upgrade head --sql | duckdb app.db' \
  'alembic upgrade head --sql | cockroach sql --url "$DB"' 'liquibase update-sql | ssh db "sqlplus app@db"'; do
  apl "$c"
done
rbk 'alembic -x url=$(cat .url) downgrade -1 --sql | psql "$DB"'
for c in 'liquibase --url="$(cat .dburl)" update-sql > out.sql' 'liquibase --url="$(cat .dburl)" update-sql | tee a.sql' \
  'alembic -x url=`cat .url` upgrade head --sql | less' "liquibase update-sql --url \"\$(cat u)\" || psql -c 'select 1'" \
  'liquibase update-sql | sql-formatter' 'alembic upgrade head --sql | ssh db "cat > /tmp/up.sql"'; do
  pas "$c"
done
tm "Monitor preview with \$(…) | psql → ask" ask 'liquibase --url="$(cat .dburl)" update-sql | psql "$DB"'
tm "Monitor preview with \$(…) | psql (subagent) → deny" deny 'liquibase --url="$(cat .dburl)" update-sql | psql "$DB"' "$AGENT_ID"

t_section "리뷰 3차: 저장소 루트·서브모듈 자신의 이름은 남긴다(migrations·flyway 이름의 저장소에서 Edit/Write)"
MR="$T_TMP/repos/migrations"; FR="$T_TMP/repos/flyway"; SR="$T_TMP/repos/super"
mkdir -p "$MR/sql" "$FR" "$SR/migrations" "$SR/src" && (cd "$MR" && t_git init -q .) && (cd "$FR" && t_git init -q .) && (cd "$SR" && t_git init -q .) || exit 1
printf 'x\n' >"$MR/V1__init.sql"; printf 'x\n' >"$MR/sql/V2__users.sql"; printf 'x\n' >"$FR/V1__init.sql"; printf 'x = 1\n' >"$SR/src/app.py"
printf 'gitdir: ../.git/modules/migrations\n' >"$SR/migrations/.git"; printf 'x\n' >"$SR/migrations/0001_initial.py"   # 서브모듈(.git 파일)
for t in Edit Write MultiEdit; do
  tf "$t V1__init.sql at the root of a repo named migrations → ask" ask $t "$MR/V1__init.sql" "$MR"
  trs "$t repo named migrations rule id" "[migrations:edit-existing]"
  tf "$t V1__init.sql at the root of a repo named migrations (subagent) → deny" deny $t "$MR/V1__init.sql" "$MR" default "$AGENT_ID"
  tf "$t sql/V2__users.sql with cwd = <repo migrations>/sql → ask" ask $t "$MR/sql/V2__users.sql" "$MR/sql"
  tf "$t V1__init.sql at the root of a repo named flyway → ask" ask $t "$FR/V1__init.sql" "$FR"
  tf "$t 0001_initial.py with cwd inside a submodule named migrations → ask" ask $t "$SR/migrations/0001_initial.py" "$SR/migrations"
  tf "$t 0001_initial.py inside a submodule named migrations (subagent) → deny" deny $t "$SR/migrations/0001_initial.py" "$SR/migrations" default "$AGENT_ID"
  tf "$t src/app.py in the superproject → none" none $t "$SR/src/app.py" "$SR"
done
tf "Write destructive new migration at the root of a repo named migrations → ask" ask Write "$MR/V9__drop.sql" "$MR" default "" 'DROP TABLE users;'
trs "destructive new migration in a repo named migrations rule id" "[migrations:destructive-schema]"
tf "Write new migration at the root of a repo named migrations (subagent) → deny" deny Write "$MR/V9__new.sql" "$MR" default "$AGENT_ID"

t_section "리뷰 3차: cd 가 많은 명령의 평범한 상대 쓰기는 작업 상한을 쓰지 않는다(로그 파일이 마이그레이션이 되지 않게)"
MONO="$T_TMP/mono"; mkdir -p "$MONO/logs" && (cd "$MONO" && t_git init -q .) || exit 1
i=1; while [ "$i" -le 40 ]; do mkdir -p "$MONO/services/s$i/migrations"; i=$((i + 1)); done
mono() { local c='' i=1; while [ "$i" -le "$1" ]; do c="${c}cd services/s$i && npm run migrate:status > ../../logs/$2$i.log 2>&1; cd ../..; "; i=$((i + 1)); done; printf '%s' "${c}echo done"; }
for n in 30 40; do
  C=$(mono "$n" s); pas "$C" "$MONO"
  C=$(mono "$n" migrate-s); pas "$C" "$MONO"   # 이름에 migrate 가 든 로그 파일
done
C=$(big 60 'echo x > n@.txt' 600 'echo x > migrations/0009_new.py'); tb '60 dirs + 600 plain relative writes, then a new migration → none' none "$C"; assert_rc '60 dirs + 600 plain writes' 0
tbs '60 dirs + 600 plain relative writes, then a new migration (subagent) → deny' deny "$C"

t_section "리뷰 3차: 컨테이너 안의 셸·명령을 경로로 쓴 형태(/bin/sh -c·/usr/bin/tee)"
for c in "docker run --rm img /bin/sh -c 'echo x > /app/migrations/0009_new.py'" "docker-compose exec web /bin/bash -c 'echo x > /app/migrations/0009_new.py'" \
  "nerdctl exec web /usr/bin/bash -lc 'sed -i s/a/b/ /app/migrations/0001_initial.py'" "docker run --rm -i img /usr/bin/tee /app/migrations/0001_initial.py"; do
  blk edit-existing "$c"
done
pas "docker run --rm img /bin/sh -c 'cat /app/migrations/0001_initial.py'"

t_section "리뷰 3차: = 없이 HOME 을 바꾸는 형태(for·read·printf -v)와 중괄호 펼침 명령 단어"
for c in "for HOME in '$APP'; do cd; echo x > migrations/0005_app_only.py; done" "read -r HOME <<< '$APP'; cd; echo x > migrations/0005_app_only.py" \
  "printf -v HOME %s '$APP'; cd && echo x > migrations/0005_app_only.py" "for HOME in '$APP'; do echo x > ~/migrations/0005_app_only.py; done" \
  '{cd,} app; echo x > migrations/0005_app_only.py' '{cd,} app && sed -i "" s/a/b/ migrations/0005_app_only.py'; do
  blk edit-existing "$c"
done
for c in 'echo "$HOME"; cd; echo x > migrations/0009_new.py' 'ls ${HOME}/x; cd ~ && echo x > migrations/0009_new.py' \
  'export HOMEBREW_NO_ENV_HINTS=1; cd; echo x > migrations/0009_new.py'; do
  crt "$c"
done

t_report
