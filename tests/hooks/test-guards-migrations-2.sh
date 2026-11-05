#!/usr/bin/env bash
# tests/hooks/test-guards-migrations-2.sh — guard-migrations.sh 회귀 테스트(D6 agent_id, B8, G5/G12 서브에이전트 거부, G11 디렉터리, G12 적용 목록, G16, D5)
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
t_setup
HOOK="$T_HOOKS/guard-migrations.sh"
AGENT_ID='{"agent_id":"agent-1"}'
AGENT_TYPE='{"agent_type":"implementer"}'
BOTH='{"agent_id":"agent-1","agent_type":"implementer"}'
run() {  # <json> [VAR=VAL ...]
  local in=$1; shift
  if [ $# -gt 0 ]; then
    T_OUT=$(printf '%s' "$in" | env "$@" "$BASH" "$HOOK" 2>"$T_TMP/stderr.txt"); T_RC=$?
    T_ERR=$(cat "$T_TMP/stderr.txt" 2>/dev/null)
  else t_run_hook "$HOOK" "$in"; fi
}
tb()  { run "$(t_bash_json "$3" "${4:-}" "${5:-}" "${6:-}")"; assert_decision "$1" "$2"; }   # <name> <expect> <cmd> [cwd] [mode] [extra]
tp()  { run "$(t_path_json "$3" "$4" "${5:-}" "${6:-}" "${7:-}")"; assert_decision "$1" "$2"; }  # <name> <expect> <tool> <path> [cwd] [mode] [extra]
trs() { assert_contains "$1" "$(t_reason "$T_OUT")" "$2"; }

mkdir -p "$T_PROJ/app/migrations" "$T_PROJ/prisma/migrations/2024_x" "$T_PROJ/db/migrate" "$T_PROJ/src"
printf 'from django.db import migrations\n' >"$T_PROJ/app/migrations/0002_x.py"
: >"$T_PROJ/app/migrations/__init__.py"
printf 'CREATE TABLE t (id int);\n' >"$T_PROJ/prisma/migrations/2024_x/migration.sql"
printf 'class X < ActiveRecord::Migration[7.0]; end\n' >"$T_PROJ/db/migrate/001_x.rb"

t_section "D6: agent_id marks a subagent, agent_type alone does not"
tb "agent_type only: makemigrations → none (main session with --agent)" none 'uv run python manage.py makemigrations app' "" default "$AGENT_TYPE"
tb "agent_id: makemigrations → deny" deny 'uv run python manage.py makemigrations app' "" default "$AGENT_ID"
trs "subagent rule id" "[migrations:subagent]"
tb "agent_id + agent_type → deny" deny 'uv run python manage.py makemigrations app' "" default "$BOTH"
tp "agent_type only: edit existing → ask (main)" ask Edit "app/migrations/0002_x.py" "" default "$AGENT_TYPE"
tp "agent_id: edit existing → deny" deny Edit "app/migrations/0002_x.py" "" default "$AGENT_ID"
tp "agent_id: edit existing in bypass → deny" deny Edit "app/migrations/0002_x.py" "" bypassPermissions "$AGENT_ID"
tb "agent_type only: migrate → ask-low (main)" ask 'python manage.py migrate' "" default "$AGENT_TYPE"
tb "agent_id: migrate → deny" deny 'python manage.py migrate' "" default "$AGENT_ID"
tb "agent_id: unrelated → none" none 'uv run pytest' "" default "$AGENT_ID"

t_section "B8: makemigrations --check / --dry-run is not creation"
tb "subagent makemigrations --check --dry-run → none" none 'uv run python manage.py makemigrations --check --dry-run' "" default "$AGENT_ID"
tb "subagent makemigrations --check → none" none 'python manage.py makemigrations --check' "" default "$AGENT_ID"
tb "subagent makemigrations --dry-run → none" none 'python manage.py makemigrations --dry-run' "" default "$AGENT_ID"
tb "subagent makemigrations app → deny" deny 'python manage.py makemigrations app' "" default "$AGENT_ID"
tb "subagent django-admin makemigrations → deny" deny 'django-admin makemigrations app' "" default "$AGENT_ID"
tb "main makemigrations --check → none" none 'python manage.py makemigrations --check'

t_section "G5 / G12: destructive migration ops — subagent deny, main none (guard-destructive owns the ask)"
for c in 'npx prisma migrate reset --force' 'uv run alembic downgrade -1' 'php artisan migrate:fresh' 'flyway clean' 'rails db:rollback STEP=1' 'npx knex migrate:rollback' 'supabase db reset' 'python manage.py migrate app zero' 'npx sequelize-cli db:migrate:undo' 'npx typeorm migration:revert'; do
  tb "subagent: $c → deny" deny "$c" "" default "$AGENT_ID"
  tb "main: $c → none" none "$c"
done

t_section "G11: deleting a migrations directory"
tb 'rm -rf app/migrations' ask 'rm -rf app/migrations'
trs "G11 delete rule id" "[migrations:delete]"
tb 'git rm -r app/migrations/' ask 'git rm -r app/migrations/'
tb 'rm -rf prisma/migrations' ask 'rm -rf prisma/migrations'
tb 'rm -rf db/migrate' ask 'rm -rf db/migrate'
tb 'mv app/migrations app/old_migrations' ask 'mv app/migrations app/old_migrations'
tb 'rm -rf app/migrations auto → still ask' ask 'rm -rf app/migrations' "" auto
tb 'subagent rm -rf app/migrations → deny' deny 'rm -rf app/migrations' "" default "$AGENT_ID"
tb 'ls db/migrate → none' none 'ls db/migrate'
tb 'rm -rf app/migrations_backup → none' none 'rm -rf app/migrations_backup'

t_section "G12: apply list and runner targets (ask-low; subagent deny; silent in auto)"
for c in 'php artisan migrate' 'npx sequelize-cli db:migrate' 'npx typeorm migration:run -d src/data-source.ts' 'npx mikro-orm migration:up' 'supabase db push' 'supabase migration up' 'liquibase update' 'flask db upgrade' 'django-admin migrate' 'npm run migrate' 'yarn db:migrate' 'pnpm migrate:up' 'make migrate' 'just db-migrate'; do
  tb "apply: $c" ask "$c"; trs "apply rule id: $c" "[migrations:apply]"
  tb "subagent apply: $c → deny" deny "$c" "" default "$AGENT_ID"
  tb "apply in auto: $c → none" none "$c" "" auto
done
for c in 'bin/rails db:migrate:status' 'php artisan migrate:status' 'npm run migrate:status' 'npm run build' 'make test' 'yarn migrate:make add_users' 'npm run db:migrate:check' 'php artisan make:migration create_users'; do
  tb "silent: $c" none "$c"
done

t_section "G16 / D5 Monitor"
tb 'rails db:migrate:status → none' none 'bin/rails db:migrate:status'
tb 'rails db:migrate → ask' ask 'bin/rails db:migrate'
run "$(t_pre_json Monitor '{"command":"python manage.py migrate"}')"; assert_decision "Monitor migrate → ask" ask
run "$(t_pre_json Monitor '{"ws":"wss://example/stream"}')"; assert_decision "Monitor ws → none" none
run "$(t_pre_json Monitor '{"command":"python manage.py migrate"}' "" default "$AGENT_ID")"; assert_decision "Monitor subagent migrate → deny" deny
run "$(t_pre_json Monitor '{"command":"rm app/migrations/0002_x.py"}')"; assert_decision "Monitor rm migration → ask" ask
t_report
