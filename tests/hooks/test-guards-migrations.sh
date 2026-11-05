#!/usr/bin/env bash
# tests/hooks/test-guards-migrations.sh — guard-migrations.sh 테스트 (§3.9 + 서브에이전트 거부 + 티어 + 로그 + 파서 폴백)
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
t_setup
HOOK="$T_HOOKS/guard-migrations.sh"
AGENT='{"agent_id":"agent-1","agent_type":"implementer"}'   # D6: 서브에이전트 표지는 agent_id (agent_type 만으로는 메인 세션일 수 있음 → test-guards-migrations-2.sh)

run() {  # <json> [VAR=VAL ...]
  local in=$1; shift
  if [ $# -gt 0 ]; then
    T_OUT=$(printf '%s' "$in" | env "$@" "$BASH" "$HOOK" 2>"$T_TMP/stderr.txt"); T_RC=$?
    T_ERR=$(cat "$T_TMP/stderr.txt" 2>/dev/null)
  else t_run_hook "$HOOK" "$in"; fi
}
tb()  { run "$(t_bash_json "$3" "${4:-}" "${5:-}" "${6:-}")"; assert_decision "$1" "$2"; }   # <name> <expect> <cmd> [cwd] [mode] [extra]
tp()  { run "$(t_path_json "$3" "$4" "${5:-}" "${6:-}" "${7:-}")"; assert_decision "$1" "$2"; }  # <name> <expect> <tool> <path> [cwd] [mode] [extra]
twr() {  # <name> <expect> <path> <content> [mode] [extra] — bash 3.2 는 "$( … \" … )" 중첩을 잘못 파싱하므로 변수로 먼저 만든다
  local fp ct j; fp=$(t_json_str "$3"); ct=$(t_json_str "$4")
  j=$(t_pre_json Write "{\"file_path\":$fp,\"content\":$ct}" "" "${5:-}" "${6:-}"); run "$j"; assert_decision "$1" "$2"
}
trs() { assert_contains "$1" "$(t_reason "$T_OUT")" "$2"; }
t_ms() {
  if command -v python3 >/dev/null 2>&1; then python3 -I -S -c 'import time; print(int(time.time()*1000))'
  elif command -v perl >/dev/null 2>&1; then perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'
  else echo 0; fi
}

# fixtures (existing migration files)
mkdir -p "$T_PROJ/app/migrations" "$T_PROJ/alembic/versions" "$T_PROJ/prisma/migrations/2024_x" "$T_PROJ/src" "$T_PROJ/docs/migrations"
printf 'from django.db import migrations\n' >"$T_PROJ/app/migrations/0002_x.py"
: >"$T_PROJ/app/migrations/__init__.py"
printf 'def upgrade(): pass\n' >"$T_PROJ/alembic/versions/abc_init.py"
printf 'CREATE TABLE t (id int);\n' >"$T_PROJ/prisma/migrations/2024_x/migration.sql"
printf '# guide\n' >"$T_PROJ/docs/migrations/README.md"

t_section "file tools (main agent)"
tp "edit existing django migration" ask Edit "app/migrations/0002_x.py"
trs "edit-existing rule id" "[migrations:edit-existing]"
tp "edit existing (absolute path)" ask Edit "$T_PROJ/app/migrations/0002_x.py"
twr "write new migration AddField" none "app/migrations/0003_y.py" "operations = [migrations.AddField(model_name='a', name='b')]"
twr "write new migration RemoveField" ask "app/migrations/0003_y.py" "operations = [migrations.RemoveField(model_name='a', name='b')]"
trs "destructive-schema rule id" "[migrations:destructive-schema]"
twr "write new sql migration DROP COLUMN" ask "prisma/migrations/2025_z/migration.sql" "ALTER TABLE t DROP COLUMN c;"
twr "write new alembic op.drop_" ask "alembic/versions/def_next.py" "def upgrade(): op.drop_table('t')"
twr "write new alembic add_column" none "alembic/versions/def_next.py" "def upgrade(): op.add_column('t', sa.Column('c', sa.Integer()))"
twr "write existing migration (overwrite)" ask "app/migrations/0002_x.py" "x = 1"
tp "edit migrations __init__" none Edit "app/migrations/__init__.py"
tp "edit models.py" none Edit "src/models.py"
tp "edit docs/migrations README" none Edit "docs/migrations/README.md"
tp "edit alembic env.py" none Edit "alembic/env.py"
tp "edit existing alembic version" ask Edit "alembic/versions/abc_init.py"
tp "edit existing prisma migration" ask Edit "prisma/migrations/2024_x/migration.sql"
tp "multiedit existing migration" ask MultiEdit "app/migrations/0002_x.py"
ME_INPUT='{"file_path":"app/migrations/0009_new.py","edits":[{"old_string":"a","new_string":"migrations.DeleteModel(\"X\")"}]}'
j=$(t_pre_json MultiEdit "$ME_INPUT"); run "$j"
assert_decision "multiedit new file DeleteModel" ask
tp "read tool ignored" none Read "app/migrations/0002_x.py"
tp "edit existing auto → still ask" ask Edit "app/migrations/0002_x.py" "" auto
assert_eq "output is valid JSON" 0 "$(t_json_valid "$T_OUT"; echo $?)"

t_section "Bash (main agent)"
tb "rm migration" ask "rm app/migrations/0002_x.py"
trs "delete rule id" "[migrations:delete]"
tb "git rm prisma migration" ask "git rm prisma/migrations/2024_x/migration.sql"
tb "mv migration" ask "mv app/migrations/0002_x.py app/migrations/0002_z.py"
tb "sed -i migration" ask "sed -i 's/a/b/' app/migrations/0002_x.py"
tb "redirect into migration" ask "echo x > app/migrations/0004_w.py"
tb "rm unrelated file" none "rm src/models.py"
tb "git rm docs" none "git rm docs/migrations/README.md"
tb "makemigrations (main)" none "uv run python manage.py makemigrations app"
tb "migrate (main) → ask-low" ask "uv run python manage.py migrate"
trs "apply rule id" "[migrations:apply]"
tb "migrate auto → none" none "uv run python manage.py migrate" "" auto
tb "migrate bypass → none" none "python manage.py migrate" "" bypassPermissions
tb "migrate --check" none "uv run python manage.py migrate --check"
tb "migrate --plan" none "python manage.py migrate --plan"
tb "migrate zero (owned by destructive)" none "python manage.py migrate app zero"
tb "alembic upgrade head" ask "alembic upgrade head"
tb "alembic downgrade (owned by destructive)" none "alembic downgrade -1"
tb "alembic revision" none "alembic revision --autogenerate -m x"
tb "prisma migrate dev" ask "prisma migrate dev"
tb "prisma migrate dev --create-only" none "npx prisma migrate dev --create-only"
tb "prisma migrate deploy" ask "npx prisma migrate deploy"
tb "prisma migrate reset (owned by destructive)" none "npx prisma migrate reset"
tb "rails db:migrate" ask "bin/rails db:migrate"
tb "knex migrate:latest" ask "npx knex migrate:latest"
tb "knex migrate:make" none "npx knex migrate:make add_users"
tb "goose up" ask "goose up"
tb "sqlx migrate run" ask "sqlx migrate run"
tb "unrelated command" none "uv run pytest tests/"
tb "mention in commit message" none 'git commit -m "add migrations for users"'
tb "bash -c migrate" ask 'bash -c "python manage.py migrate"'

t_section "subagent (agent_type present) → deny"
tp "subagent edit existing migration" deny Edit "app/migrations/0002_x.py" "" default "$AGENT"
trs "subagent rule id" "[migrations:subagent]"
twr "subagent write new migration" deny "app/migrations/0003_y.py" "x" default "$AGENT"
tb "subagent makemigrations" deny "uv run python manage.py makemigrations app" "" default "$AGENT"
tb "subagent migrate" deny "uv run python manage.py migrate" "" default "$AGENT"
tb "subagent rm migration" deny "rm app/migrations/0002_x.py" "" default "$AGENT"
tb "subagent alembic revision" deny "alembic revision -m x" "" default "$AGENT"
tb "subagent migrate --check → none" none "python manage.py migrate --check" "" default "$AGENT"
tb "subagent unrelated bash → none" none "uv run pytest" "" default "$AGENT"
tp "subagent edit non-migration → none" none Edit "src/models.py" "" default "$AGENT"
tp "subagent deny even in bypass" deny Edit "app/migrations/0002_x.py" "" bypassPermissions "$AGENT"

t_section "env / parser / log"
run "$(t_path_json Edit "app/migrations/0002_x.py")" CLAUDE_GUARD_MIGRATIONS=off; assert_decision "off switch (file)" none
run "$(t_bash_json "python manage.py migrate")" CLAUDE_GUARD_MIGRATIONS=off; assert_decision "off switch (bash)" none
run "$(t_path_json Edit "app/migrations/0002_x.py")" HOOK_FORCE_PARSER=none; assert_decision "no parser → none" none
assert_rc "no parser rc" 0
run "$(t_path_json Edit "app/migrations/0002_x.py")" HOOK_FORCE_PARSER=python3; assert_decision "python3 parser ask" ask
assert_eq "python3 output valid JSON" 0 "$(t_json_valid "$T_OUT"; echo $?)"
j=$(t_pre_json Write '{"file_path":"app/migrations/0003_y.py","content":"RemoveField"}'); run "$j" HOOK_FORCE_PARSER=python3; assert_decision "python3 content check" ask
run "not json"; assert_decision "invalid input → none" none
run "$(t_pre_json Edit '{"file_path":"app/migrations/0002_x.py"}' "" default "$AGENT")" CLAUDE_HOOKS_LOG="$T_TMP/hooks.log"
assert_contains "log line written" "$(cat "$T_TMP/hooks.log" 2>/dev/null)" "guard-migrations	deny	migrations:subagent"
run "$(t_bash_json "python manage.py migrate" "" auto)" CLAUDE_HOOKS_LOG="$T_TMP/hooks.log"
assert_contains "silenced apply logged" "$(cat "$T_TMP/hooks.log" 2>/dev/null)" "guard-migrations	allow	migrations:apply"
t_run_hook run-hook "$(t_path_json Edit "app/migrations/0002_x.py")" guard-migrations; assert_decision "via launcher" ask

t_section "benchmark (20 non-triggering calls)"
i=0; t0=$(t_ms)
while [ $i -lt 20 ]; do run "$(t_path_json Edit "src/views.py")"; i=$((i + 1)); done
t1=$(t_ms); total=$((t1 - t0))
printf '  bench guard-migrations: 20 runs = %d ms (avg %d ms, incl. test JSON build)\n' "$total" "$((total / 20))"
[ "$total" -lt 5000 ] && t_pass "bench under 250 ms avg" || t_fail "bench too slow" "$total ms for 20 runs"
t_report
