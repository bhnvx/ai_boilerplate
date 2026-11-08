#!/usr/bin/env bash
# tests/hooks/test-guards-migrations-3.sh — guard-migrations.sh 회귀 테스트
# F7(리디렉션 대상만 쓰기), B407(셸로 새 마이그레이션 생성), F11(도구와 동사 사이의 옵션), F20(__pycache__·복사 원본), D13(제외 파일)
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
t_setup
HOOK="$T_HOOKS/guard-migrations.sh"
AGENT_ID='{"agent_id":"agent-1","agent_type":"implementer"}'
run() { t_run_hook "$HOOK" "$1"; }
tb()  { run "$(t_bash_json "$3" "${4:-}" "${5:-}" "${6:-}")"; assert_decision "$1" "$2"; }   # <name> <expect> <cmd> [cwd] [mode] [extra]
tbs() { tb "$1" "$2" "$3" "${4:-}" default "$AGENT_ID"; }                                       # 서브에이전트
tp()  { run "$(t_path_json "$3" "$4" "${5:-}" "${6:-}" "${7:-}")"; assert_decision "$1" "$2"; }  # <name> <expect> <tool> <path> [cwd] [mode] [extra]
trs() { assert_contains "$1" "$(t_reason "$T_OUT")" "$2"; }
dec() { run "$(t_bash_json "$1" "" default "${2:-}")"; t_decision "$T_OUT"; }                     # <cmd> [extra] → 결정

mkdir -p "$T_PROJ/migrations/__pycache__" "$T_PROJ/app/migrations/__pycache__" "$T_PROJ/alembic/versions" "$T_PROJ/db/migrations" "$T_PROJ/src"
printf 'from django.db import migrations\n' >"$T_PROJ/migrations/0001_initial.py"
printf '# root only\n' >"$T_PROJ/migrations/0002_only_root.py"
: >"$T_PROJ/migrations/__init__.py"
: >"$T_PROJ/migrations/__pycache__/0001_initial.cpython-312.pyc"
printf 'from django.db import migrations\n' >"$T_PROJ/app/migrations/0001_initial.py"
: >"$T_PROJ/app/migrations/__pycache__/0001_initial.cpython-312.pyc"
printf 'def upgrade():\n    ${upgrades if upgrades else "pass"}\n' >"$T_PROJ/alembic/versions/script.py.mako"
printf '[alembic]\nscript_location = alembic\n' >"$T_PROJ/alembic.ini"
printf 'CREATE TABLE t (id int);\n' >"$T_PROJ/db/migrations/20240101_init.sql"
printf 'x = 1\n' >"$T_PROJ/template.py"
NEW_PY=$'from django.db import migrations, models\n\n\nclass Migration(migrations.Migration):\n    dependencies = [("app", "0001_initial")]\n    operations = [migrations.AddField(model_name="user", name="email", field=models.EmailField(blank=True))]'
DROP_PY=$'from django.db import migrations\n\n\nclass Migration(migrations.Migration):\n    operations = [migrations.RemoveField(model_name="user", name="email")]'
HD_NEW="cat > migrations/0002_add_email.py <<'EOF'"$'\n'"$NEW_PY"$'\nEOF'
HD_DROP="cat > migrations/0003_remove_email.py <<'EOF'"$'\n'"$DROP_PY"$'\nEOF'

t_section "F7: 리디렉션은 대상(> 뒤 단어)만 쓴다 — 읽기만 하는 인수는 수정이 아님"
for c in 'ls migrations/*.py 2>/dev/null | wc -l' 'cat migrations/0001_initial.py 2>&1 | head -40' \
  'grep -n RunSQL migrations/0001_initial.py > /tmp/out.txt' 'grep -c AddField migrations/0001_initial.py >> notes.txt 2>&1' \
  'cat migrations/0001_initial.py 1>&2' 'diff migrations/0001_initial.py template.py >/dev/null 2>&1' \
  'grep ">" migrations/0001_initial.py' 'wc -l migrations/0001_initial.py &> /tmp/wc.txt' \
  'cat migrations/0001_initial.py >& /tmp/both.txt' 'cat < migrations/0001_initial.py > /tmp/copy.py' \
  'head -5 migrations/0001_initial.py 2>&- 3>&1' 'tee >(cat > /tmp/log.txt) < migrations/0001_initial.py' \
  'grep -n My\ Field migrations/0001_initial.py > /tmp/out.txt'; do
  tb "pass: $c" none "$c"
  tbs "subagent pass: $c" none "$c"
done
for c in 'echo x > migrations/0001_initial.py' 'cat tmpl >> migrations/0001_initial.py' "sed -i '' s/a/b/ migrations/0001_initial.py" \
  'tee migrations/0001_initial.py' 'tee -a migrations/0001_initial.py < template.py' 'cmd 2> migrations/0001_initial.py' \
  'cmd 2>> migrations/0001_initial.py' 'echo x >| migrations/0001_initial.py' 'cmd &> migrations/0001_initial.py' \
  'cmd &>> migrations/0001_initial.py' 'cmd >& migrations/0001_initial.py' 'cat <> migrations/0001_initial.py' \
  'echo x >migrations/0001_initial.py' 'echo x > "migrations/0001_initial.py"' 'ls 2>/dev/null > migrations/0001_initial.py' \
  'cat template.py | tee migrations/0001_initial.py > /dev/null' 'echo x > migrations/$NAME.py' "sed -i 's/a/b/' migrations/*.py" \
  'tee migrations/00{01,09}_initial.py < template.py' 'cp /tmp/*.py migrations/' 'cp template.py "$PWD/migrations/0009_x.py"' \
  ': > migrations/0001_initial.py' '> migrations/0001_initial.py echo hi' 'exec 3<> migrations/0001_initial.py' 'sh -c "echo x > migrations/0001_initial.py"' \
  'x=$(cat > migrations/0001_initial.py < template.py)' 'cd nonexistent; echo x > migrations/0001_initial.py' 'echo a\ b > migrations/0001_initial.py'; do
  tb "block: $c" ask "$c"; trs "block rule id: $c" "[migrations:edit-existing]"
  tbs "subagent block: $c" deny "$c"
done
tb 'edit-existing is ask-high (still ask in auto)' ask 'echo x > migrations/0001_initial.py' "" auto

t_section "B407: 아직 없는 마이그레이션 파일을 셸로 쓰는 것은 생성(메인 통과, 서브에이전트 deny)"
tb "heredoc creates a new migration → none" none "$HD_NEW"
tbs "subagent heredoc creation → deny" deny "$HD_NEW"
trs "subagent creation rule id" "[migrations:subagent]"
for c in "tee migrations/0003_new.py <<'EOF'"$'\nx = 1\nEOF' 'cp template.py migrations/0003_new.py' 'cp template.py migrations/' \
  'install -m 644 template.py migrations/0003_new.py' 'mv /tmp/0003_new.py migrations/' 'git mv template.py migrations/0003_new.py' \
  'cp -t migrations/ template.py' "echo 'x = 1' > migrations/0003_new.py" 'rsync -a /tmp/0003_new.py db/migrations/' \
  'cat My\ Notes.txt > migrations/0003_new.py' 'mv my\ file.py migrations/'; do
  tb "create: $c → none" none "$c"
  tbs "subagent create: $c → deny" deny "$c"
done
for c in 'cp template.py migrations/0001_initial.py' 'cp /tmp/0001_initial.py migrations/' 'install template.py migrations/0001_initial.py' \
  'rsync -a template.py migrations/0001_initial.py' 'mv template.py migrations/0001_initial.py' 'cp -t migrations/ /tmp/0001_initial.py' \
  'cp --target-directory=migrations /tmp/0001_initial.py' 'cp a.py /tmp/0001_initial.py migrations'; do
  tb "overwrite existing: $c → ask" ask "$c"; trs "overwrite rule id: $c" "[migrations:edit-existing]"
done
tb "heredoc creation with destructive content → ask" ask "$HD_DROP"
trs "destructive creation rule id" "[migrations:destructive-schema]"
tb "destructive creation is ask-high (auto)" ask "$HD_DROP" "" auto
tbs "subagent destructive creation → deny" deny "$HD_DROP"
tb "echo destructive SQL into a new migration → ask" ask "echo 'ALTER TABLE users DROP COLUMN email;' > db/migrations/20240201_drop.sql"
trs "echo destructive rule id" "[migrations:destructive-schema]"
tb "destructive SQL piped into tee of a new migration → ask" ask 'echo "ALTER TABLE users DROP COLUMN email;" | tee db/migrations/20240301_drop.sql'
trs "piped destructive rule id" "[migrations:destructive-schema]"
tb "generator piped into tee of a new migration → none" none 'python gen.py | tee migrations/0009_new.py'
tb "destructive heredoc to stdout is not a migration write" none "cat <<'EOF'"$'\nop.drop_table("t")\nEOF'
tb "new migration + unrelated destructive heredoc to /tmp → none" none "cat > /tmp/notes.txt <<'EOF'"$'\nDROP TABLE t\nEOF'
t_section "B407: 존재 여부는 유효 작업 디렉터리 기준(cd 추적)"
tb "cd app && overwrite existing app/migrations file → ask" ask "cd app && cat > migrations/0001_initial.py <<'EOF'"$'\nx\nEOF'
tb "cd app && file that exists only at the root → ask (R2: cd 가 실행됐는지 몰라 합집합)" ask 'cd app && echo x > migrations/0002_only_root.py'
tb "cd app && new migration → none" none "cd app && cat > migrations/0009_new.py <<'EOF'"$'\nx\nEOF'
tb "cd \$VAR (unknown) && write → ask" ask 'cd "$APP_DIR" && echo x > migrations/0009_new.py'
tb "cd - (unknown) && write → ask" ask 'cd - && echo x > migrations/0009_new.py'
tb "subshell cd does not leak → root file exists → ask" ask '(cd src) && echo x > migrations/0002_only_root.py'
tb "cd inside subshell applies inside it → ask" ask '(cd app && echo x > migrations/0001_initial.py)'
tb "cd in \$(…) does not leak → root file exists → ask" ask 'd=$(cd src && pwd); echo x > migrations/0002_only_root.py'
tb "cd in \$(…) inside sh -c does not leak → ask" ask "sh -c 'd=\$(cd src && pwd); echo x > migrations/0002_only_root.py'"
tb "sh -c cd does not leak to the outer command → ask" ask "sh -c 'cd src' && echo x > migrations/0002_only_root.py"
tb "cd inside sh -c, file that exists only at the root → ask (R2: 합집합)" ask "sh -c 'cd app && echo x > migrations/0002_only_root.py'"
tb "cwd from hook input → exists → ask" ask 'echo x > migrations/0001_initial.py' "$T_PROJ/app"
tb "absolute path to a new migration → none" none "echo x > '$T_PROJ/migrations/0009_new.py'"
tb "absolute path to an existing migration → ask" ask "echo x > '$T_PROJ/migrations/0001_initial.py'"

t_section "F11: 도구와 동사 사이에 옵션·위치 인수가 와도 적용·롤백·생성을 인식"
for c in 'goose -dir db/migrations postgres "$DATABASE_URL" up' 'goose -dir db/migrations postgres "$DATABASE_URL" up-by-one' \
  'goose -dir db/migrations postgres "$DATABASE_URL" up-to 20240101000000' 'dbmate --url "$DATABASE_URL" up' 'dbmate -d db/migrations migrate' \
  'migrate -path db/migrations -database "$DATABASE_URL" up' 'migrate -path db/migrations -database "$DATABASE_URL" goto 3' \
  'docker run --rm -v "$PWD/db/migrations:/migrations" migrate/migrate -path=/migrations -database "$DATABASE_URL" up' \
  'atlas migrate apply --url "$DATABASE_URL"' 'alembic -c alembic.ini upgrade head' 'python -m alembic -x tenant=a upgrade head' \
  'flask --app wsgi db upgrade' 'flyway -url=jdbc:postgresql://localhost/app -user=app migrate' \
  'liquibase --changelog-file=db/changelog.xml --url=jdbc:x update' 'npx knex --knexfile knexfile.js migrate:latest' \
  'php artisan --env=testing migrate'; do
  tb "apply: $c → ask" ask "$c"; trs "apply rule id: $c" "[migrations:apply]"
  tb "apply in auto: $c → none" none "$c" "" auto
  tbs "subagent apply: $c → deny" deny "$c"
done
for c in 'goose -dir db/migrations postgres "$DATABASE_URL" down' 'goose -dir db/migrations postgres "$DATABASE_URL" down-to 0' \
  'goose -dir db/migrations postgres "$DATABASE_URL" reset' 'dbmate --url "$DATABASE_URL" rollback' 'dbmate --url "$DATABASE_URL" drop' \
  'migrate -path db/migrations -database "$DATABASE_URL" down 1' 'migrate -path db/migrations -database "$DATABASE_URL" drop -f' \
  'alembic -c alembic.ini downgrade -1' 'flask --app wsgi db downgrade' 'npx knex --env production migrate:down' 'flyway -url=x clean'; do
  tb "rollback main: $c → none (guard-destructive owns the ask)" none "$c"
  tbs "rollback subagent: $c → deny" deny "$c"
done
for c in 'goose -dir db/migrations create add_users sql' 'dbmate -d db/migrations new add_users' \
  'migrate create -ext sql -dir db/migrations -seq add_users' 'alembic -c alembic.ini revision --autogenerate -m "add users"' \
  'flask --app wsgi db migrate -m "add users"' 'npx knex --knexfile knexfile.js migrate:make add_users' 'php artisan make:migration create_users'; do
  tb "create main: $c → none" none "$c"
  tbs "create subagent: $c → deny" deny "$c"
done
for c in 'goose status' 'goose -dir db/migrations postgres "$DATABASE_URL" status' 'goose -dir db/migrations postgres "$DATABASE_URL" version' \
  'dbmate status' 'dbmate --url "$DATABASE_URL" status' 'dbmate dump' 'migrate version' \
  'migrate -path db/migrations -database "$DATABASE_URL" version' 'migrate -path db/migrations -database "$DATABASE_URL" force 3' \
  'alembic -c alembic.ini current' 'alembic -c alembic.ini history' 'flask --app wsgi db current' 'flyway -url=x info' \
  'liquibase --changelog-file=x status' 'npx knex --knexfile k.js migrate:status' 'php artisan --env=testing migrate:status' \
  'ls db/migrate' 'brew install goose dbmate golang-migrate' 'go install github.com/pressly/goose/v3/cmd/goose@latest' \
  'alembic -c alembic.ini upgrade head --sql' 'alembic -c alembic.ini downgrade -1 --sql' 'flask --app wsgi db upgrade --sql > u.sql' \
  'goose -dir db/migrations create add_up_column sql > /dev/null'; do
  tb "read-only main: $c → none" none "$c"
  case $c in *create*) ;; *) tbs "read-only subagent: $c → none" none "$c" ;; esac
done
for v in up up-by-one up-to redo reset down down-to status version create fix; do   # 동사마다 기존(인접형) 분류를 유지
  for x in '' "$AGENT_ID"; do
    a=$(dec "goose $v" "$x"); b=$(dec "goose -dir db/migrations postgres \"\$DATABASE_URL\" $v" "$x")
    assert_eq "goose $v ${x:+(subagent) }keeps its classification with flags" "$a" "$b"
  done
done
for v in up migrate rollback down drop new status dump load wait; do
  for x in '' "$AGENT_ID"; do
    a=$(dec "dbmate $v" "$x"); b=$(dec "dbmate --url \"\$DATABASE_URL\" -d db/migrations $v" "$x")
    assert_eq "dbmate $v ${x:+(subagent) }keeps its classification with flags" "$a" "$b"
  done
done
for v in upgrade downgrade revision current history stamp; do
  for x in '' "$AGENT_ID"; do
    a=$(dec "alembic $v head" "$x"); b=$(dec "alembic -c alembic.ini -x tenant=a $v head" "$x")
    assert_eq "alembic $v ${x:+(subagent) }keeps its classification with flags" "$a" "$b"
  done
done

t_section "F20: __pycache__·*.pyc 는 마이그레이션이 아니고, cp·install·rsync 는 목적지만 쓴다"
for c in 'rm -rf migrations/__pycache__' 'rm -rf app/migrations/__pycache__/' 'rm migrations/__pycache__/0001_initial.cpython-312.pyc' \
  'rm -f migrations/*.pyc' 'git rm -r --cached migrations/__pycache__' 'cp migrations/0001_initial.py /tmp/0001_initial.py.bak' \
  'cp migrations/0001_initial.py app/migrations/0001_initial.py /tmp/' 'cp -r app/migrations /tmp/mig-backup' \
  'rsync -a migrations/ /tmp/mig-backup/' 'install -m 644 migrations/0001_initial.py /tmp/x.py' 'tee /tmp/x.txt < migrations/0001_initial.py'; do
  tb "F20 pass: $c" none "$c"
  tbs "F20 subagent pass: $c" none "$c"
done
for c in 'rm migrations/0001_initial.py' 'rm -rf app/migrations' 'mv migrations/0001_initial.py /tmp/' 'git mv migrations/0001_initial.py migrations/0001_init.py' \
  'mv migrations/0002_only_root.py migrations/0002_renamed.py'; do
  tb "F20 delete: $c → ask" ask "$c"; trs "F20 delete rule id: $c" "[migrations:delete]"
  tbs "F20 subagent delete: $c → deny" deny "$c"
done
tb 'mv a file into the migrations dir is not a delete' none 'mv template.py migrations/'

t_section "D13: alembic 템플릿·설정은 마이그레이션이 아님"
tp "Edit script.py.mako (main)" none Edit "alembic/versions/script.py.mako"
tp "Edit script.py.mako (subagent)" none Edit "alembic/versions/script.py.mako" "" default "$AGENT_ID"
tp "Edit alembic.ini (main)" none Edit "alembic.ini"
tp "Edit alembic.ini (subagent)" none Edit "alembic.ini" "" default "$AGENT_ID"
FP=$(t_json_str "alembic/versions/script.py.mako"); CT=$(t_json_str 'def downgrade(): op.drop_table("t")')
WI="{\"file_path\":$FP,\"content\":$CT}"   # bash 3.2 는 "$( … \" … )" 중첩을 잘못 파싱하므로 변수로 먼저 만든다
J=$(t_pre_json Write "$WI" "" default "$AGENT_ID"); assert_eq "Write test JSON is valid" 0 "$(t_json_valid "$J"; echo $?)"
run "$J"; assert_decision "Write script.py.mako with drop_table (subagent)" none
tb "sed -i script.py.mako (main)" none "sed -i 's/pass/...' alembic/versions/script.py.mako"
tbs "sed -i script.py.mako (subagent)" none "sed -i 's/pass/...' alembic/versions/script.py.mako"
tbs "edit alembic.ini by redirect (subagent)" none 'echo "[post_write_hooks]" >> alembic.ini'
t_report
