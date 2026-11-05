#!/usr/bin/env bash
# guard-migrations.sh — PreToolUse(Edit|Write|MultiEdit|Bash|Monitor): 적용된 마이그레이션 보호 + 서브에이전트 금지(subagent-policy §1·§4)
# 결정은 stdout JSON + exit 0 만. 끄기: CLAUDE_GUARD_MIGRATIONS=off
# 규칙 id: migrations:subagent(deny) edit-existing(ask) destructive-schema(ask) delete(ask) apply(ask-low; auto/bypass 에서는 조용히 통과)
# 파괴적 DB 작업(downgrade/rollback/reset/zero/clean/fresh/wipe/TRUNCATE/DROP)의 확인은 guard-destructive 가 담당한다(중복 금지).
# 다만 서브에이전트가 그런 명령을 실행하는 것은 이 훅이 거부한다(G5).
# 서브에이전트 판정은 .agent_id(H_AGENT_ID) 만 쓴다 — .agent_type 은 --agent 로 띄운 메인 세션에도 들어 있다(D6, hooks.md).
GM_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
. "$GM_DIR/lib/common.sh"
hook_off CLAUDE_GUARD_MIGRATIONS && exit 0
hook_read_input
hook_require_pretooluse
case $H_TOOL in Edit|Write|MultiEdit|Bash|Monitor) ;; *) exit 0 ;; esac   # D5: Monitor 는 Bash 와 동일
GM_SUB=0; [ -n "$H_AGENT_ID" ] && GM_SUB=1

GM_SEV=0; GM_RULE=""; GM_REASON=""
GM_SUBAGENT_REASON="차단 [migrations:subagent]: 서브에이전트는 마이그레이션 생성·적용·수정·롤백 금지(subagent-policy §1·§4) — 메인에 보고할 것"
GM_DESTRUCTIVE_RE='removefield|deletemodel|alterfield|renamefield|drop_table|drop_column|droptable|dropcolumn|op\.drop_|drop table|drop column|alter table .* drop|\.drop\(|dropindex|removecolumn|changecolumn|renamecolumn|remove_column|change_column|rename_column|dropforeign|truncate'

gm_hit() { [ "$1" -gt "$GM_SEV" ] || return 0; GM_SEV=$1; GM_RULE=$2; GM_REASON=$3; }
gm_finish() {
  case $GM_SEV in
    3) hook_emit_pre deny "$GM_REASON" "$GM_RULE" ;;
    2) hook_emit_pre ask "$GM_REASON" "$GM_RULE" ;;
    1) case $H_MODE in
         auto|bypassPermissions) hook_emit_pre allow "silenced($H_MODE): $GM_REASON" "$GM_RULE" ;;
         *) hook_emit_pre ask "$GM_REASON" "$GM_RULE" ;;
       esac ;;
  esac
  exit 0
}

# gm_is_migration <path> → 0 이면 마이그레이션 파일(제외 파일은 1). fork 없음.
gm_is_migration() {
  local p=$1 b
  case $p in *migrat*|*alembic*|*drizzle*|*flyway*|*liquibase*|*goose*|*dbmate*|*db/migrate*) ;; *) return 1 ;; esac
  case /$p in
    */migrations/*|*/migration/*|*/alembic/versions/*|*/db/migrate/*|*/prisma/migrations/*|*/supabase/migrations/*|*/drizzle/*|*/knex/migrations/*|*/sequelize/migrations/*|*/typeorm/migrations/*|*/flyway/*|*/liquibase/*|*/sql/migrations/*|*/db/migrations/*|*/atlas/migrations/*|*/goose/*|*/dbmate/*) ;;
    *) return 1 ;;
  esac
  b=${p##*/}
  case $b in ''|__init__.py|README*|*.md|env.py|script.py.mako|alembic.ini|migration_lock.toml|*.lock) return 1 ;; esac
  return 0
}
# gm_is_migration_dir <path> → 0 이면 마이그레이션 디렉터리 자체(rm -rf app/migrations 등; G11)
gm_is_migration_dir() {
  local p=${1%/}
  case /$p in
    */migrations|*/migration|*/db/migrate|*/alembic/versions|*/prisma/migrations|*/supabase/migrations|*/drizzle|*/db/migrations|*/sql/migrations|*/knex/migrations|*/sequelize/migrations|*/typeorm/migrations|*/atlas/migrations) return 0 ;;
  esac
  return 1
}

# ---- Edit / Write / MultiEdit ----
gm_file_tools() {
  [ -n "$H_PATH" ] || exit 0
  gm_is_migration "$H_PATH" || exit 0
  [ "$GM_SUB" -eq 1 ] && { gm_hit 3 migrations:subagent "$GM_SUBAGENT_REASON: $H_PATH"; gm_finish; }
  hook_abspath_var "$H_PATH" "$H_CWD"
  if [ -e "$HOOK_ABS" ]; then
    gm_hit 2 migrations:edit-existing "확인 필요 [migrations:edit-existing]: 이미 존재하는 마이그레이션 수정 — 적용된 마이그레이션이면 수정 대신 새 마이그레이션을 만들 것: $H_PATH"
    gm_finish
  fi
  hook_fields 'GM_CONTENT=.tool_input.content|.tool_input.new_string|.tool_input.edits' || gm_finish
  shopt -s nocasematch
  if [[ $GM_CONTENT =~ $GM_DESTRUCTIVE_RE ]]; then
    shopt -u nocasematch
    gm_hit 2 migrations:destructive-schema "확인 필요 [migrations:destructive-schema]: 파괴적 스키마 변경 — 2단계(추가→백필→전환→삭제)와 백업 여부 확인: $H_PATH"
  fi
  shopt -u nocasematch
  gm_finish
}

# ---- Bash ----
GM_HEAD=""; GM_FILE=""
gm_head() { set -f; set -- $1; GM_HEAD=${1:-}; set +f; }
gm_file_tokens() {  # <raw> [dirs=1] → 0 이면 마이그레이션 파일(dirs=1 이면 디렉터리도) 토큰이 있음(GM_FILE 에 첫 토큰; 리디렉션 대상 포함)
  local t dirs=${2:-0}
  GM_FILE=""
  while IFS= read -r t; do
    case $t in '<'*|'>'*) t=${t#>}; t=${t#>}; t=${t#<} ;; esac
    [ -n "$t" ] || continue
    gm_is_migration "$t" && { GM_FILE=$t; return 0; }
    [ "$dirs" -eq 1 ] && gm_is_migration_dir "$t" && { GM_FILE=$t; return 0; }
  done < <(sp_tokens "$1")
  return 1
}
gm_runner_target() {  # <masked> → 0 이면 npm run/yarn/pnpm/bun/make/just 의 대상이 migrate 류(status/check/make 류 제외; G12)
  local re='(^|[:_-])migrate($|[:_-])' t
  set -f; set -- $1; set +f
  case ${1:-} in
    npm) case ${2:-} in run|run-script) t=${3:-} ;; *) return 1 ;; esac ;;
    yarn|pnpm|bun) if [ "${2:-}" = run ]; then t=${3:-}; else t=${2:-}; fi ;;
    make|just) t=${2:-} ;;
    *) return 1 ;;
  esac
  [ -n "$t" ] || return 1
  case $t in *status*|*check*|*:make*|*:create*|*:generate*|*:diff*|*:new*|-*) return 1 ;; esac
  [[ $t =~ $re ]]
}
gm_segment() {  # <masked> <raw>
  local m=$1 r=$2 create=0 apply=0 delete=0 edit=0 destructive=0 ex
  hook_excerpt "$m" 120; ex=$HOOK_EX
  gm_head "$m"
  case $GM_HEAD in
    rm|grm|rimraf|mv) gm_file_tokens "$r" 1 && delete=1 ;;
    git) case $m in 'git rm '*|'git mv '*) gm_file_tokens "$r" 1 && delete=1 ;; esac ;;
    sed) case " $m " in *' -i'*) gm_file_tokens "$r" && edit=1 ;; esac ;;
    tee|cp|truncate) gm_file_tokens "$r" && edit=1 ;;
  esac
  case $m in *'>'*) [ "$edit" -eq 1 ] || [ "$delete" -eq 1 ] || { gm_file_tokens "$r" && edit=1; } ;; esac
  case $m in
    *'manage.py makemigrations'*|*'django-admin makemigrations'*) case " $m " in *' --check'*|*' --dry-run'*) ;; *) create=1 ;; esac ;;   # B8: 검사만 하는 호출은 생성이 아님
    *'alembic revision'*|*'prisma migrate dev'*--create-only*|*'rails g migration'*|*'rails generate migration'*|*'knex migrate:make'*|*'drizzle-kit generate'*|*'sqlx migrate add'*|*'goose create'*|*'dbmate new'*|*'atlas migrate diff'*|*'artisan make:migration'*|*'flask db migrate'*|*'sequelize'*'migration:generate'*|*'sequelize'*'migration:create'*|*'typeorm'*'migration:generate'*|*'typeorm'*'migration:create'*|*'supabase migration new'*) create=1 ;;
  esac
  if [ "$create" -eq 0 ]; then
    case $m in
      *'manage.py migrate'*|*'django-admin migrate'*) case " $m " in *' --check'*|*' --plan'*|*' --list'*|*' -l '*|*' zero '*|*' zero') ;; *) apply=1 ;; esac ;;
      *'alembic upgrade'*|*'flask db upgrade'*|*'prisma migrate dev'*|*'prisma migrate deploy'*|*'prisma db push'*|*'rails db:migrate'*|*'rake db:migrate'*|*'knex migrate:latest'*|*'knex migrate:up'*|*'drizzle-kit push'*|*'drizzle-kit migrate'*|*'flyway migrate'*|*'goose up'*|*'dbmate up'*|*'dbmate migrate'*|*'sqlx migrate run'*|*'atlas migrate apply'*|*'artisan migrate'*|*'sequelize'*'db:migrate'*|*'typeorm'*'migration:run'*|*'mikro-orm migration:up'*|*'supabase db push'*|*'supabase migration up'*|*'liquibase update'*) apply=1 ;;
    esac
    case $m in *':status'*|*'migrate:fresh'*|*'migrate:reset'*|*'migrate:rollback'*|*'migrate:refresh'*|*'db:migrate:undo'*|*'db:migrate:reset'*|*'db:migrate:down'*) apply=0 ;; esac   # G16: status 는 읽기 전용
    case $GM_HEAD in npm|yarn|pnpm|bun|make|just) gm_runner_target "$m" && apply=1 ;; esac
    case $m in *migrat*|*alembic*|*prisma*|*'db:'*|*knex*|*drizzle*|*flyway*|*goose*|*dbmate*|*sqlx*|*atlas*|*rails*|*rake*|*sequelize*|*typeorm*|*supabase*|*liquibase*|*artisan*|*mikro-orm*|*'flask db'*)
      case $m in *downgrade*|*rollback*|*' reset'*|*--force-reset*|*'db:drop'*|*'db:reset'*|*' clean'*|*'migrate:fresh'*|*'db:wipe'*|*'migrate:undo'*|*'migration:revert'*|*'goose down'*|*'dbmate drop'*|*'dbmate down'*|*'database drop'*|*'migrate revert'*|*'schema clean'*|*'drizzle-kit drop'*|*'knex migrate:down'*|*'db reset'*|*'schema:drop'*|*' dropall'*|*' zero'*) apply=0; destructive=1 ;; esac ;;
    esac
  fi
  if [ "$create" -eq 1 ] || [ "$apply" -eq 1 ] || [ "$delete" -eq 1 ] || [ "$edit" -eq 1 ] || [ "$destructive" -eq 1 ]; then
    [ "$GM_SUB" -eq 1 ] && { gm_hit 3 migrations:subagent "$GM_SUBAGENT_REASON: $ex"; return 0; }
  fi
  [ "$delete" -eq 1 ] && gm_hit 2 migrations:delete "확인 필요 [migrations:delete]: 마이그레이션 파일·디렉터리 삭제·이동 — 적용된 마이그레이션이면 되돌릴 수 없음: $GM_FILE"
  [ "$edit" -eq 1 ] && gm_hit 2 migrations:edit-existing "확인 필요 [migrations:edit-existing]: 셸로 마이그레이션 파일 수정 — 적용된 마이그레이션이면 새 마이그레이션을 만들 것: $GM_FILE"
  [ "$apply" -eq 1 ] && gm_hit 1 migrations:apply "확인 필요 [migrations:apply]: 마이그레이션 적용 — 대상 DB(로컬/운영) 확인: $ex"
  return 0
}
gm_bash() {
  local low k m r
  [ -n "$H_CMD" ] || exit 0
  low=$(hook_lower "$H_CMD")
  case $low in *migrat*|*alembic*|*prisma*|*'db:'*|*knex*|*drizzle*|*flyway*|*goose*|*dbmate*|*sqlx*|*atlas*|*rails*|*sequelize*|*typeorm*|*versions*|*'db push'*|*artisan*|*liquibase*|*supabase*|*mikro-orm*|*'flask db'*|*django-admin*|*'db reset'*|*'db wipe'*) ;; *) exit 0 ;; esac
  . "$GM_DIR/lib/shellparse.sh"
  while IFS=$'\t' read -r k m r; do
    case $k in
      cmd*) gm_segment "$m" "$r" ;;
      sub) while IFS=$'\t' read -r k m r; do case $k in cmd*|sub) gm_segment "$m" "$r" ;; esac; done < <(sp_segments "$r") ;;
    esac
  done < <(sp_segments "$H_CMD")
  gm_finish
}

case $H_TOOL in Bash|Monitor) gm_bash ;; *) gm_file_tools ;; esac
exit 0
