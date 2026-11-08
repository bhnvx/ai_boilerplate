#!/usr/bin/env bash
# guard-migrations.sh — PreToolUse(Edit|Write|MultiEdit|Bash|Monitor): 적용된 마이그레이션 보호 + 서브에이전트 금지(subagent-policy §1·§4)
# 결정은 stdout JSON + exit 0 만. 끄기: CLAUDE_GUARD_MIGRATIONS=off
# 규칙 id: migrations:subagent(deny) edit-existing(ask) destructive-schema(ask) delete(ask) apply(ask-low; auto/bypass 에서는 조용히 통과)
# 파괴적 DB 작업(downgrade/rollback/reset/zero/clean/fresh/wipe/TRUNCATE/DROP)의 확인은 guard-destructive 가 담당한다(중복 금지).
# 다만 서브에이전트가 그런 명령을 실행하는 것은 이 훅이 거부한다(G5).
# 셸 쓰기는 실제로 쓰는 경로만 본다(F7·F20): 리디렉션 대상, tee 출력, cp/mv/install/rsync/scp 목적지, 제자리 수정
# (sed -i·perl/ruby -i·git checkout/restore·dd of=·curl -o·wget -O·truncate·patch). 이미 있는 파일이면 edit-existing,
# 없으면 생성이다(B407: 메인은 통과하되 명령 어디에든 파괴적 내용이 있으면 destructive-schema, 서브에이전트는 deny).
# 상대 경로는 세션 cwd 와 명령 안의 cd 가 닿은 모든 디렉터리에서 판정한다(cd 가 실제로 실행됐는지 알 수 없으므로 합집합).
# ssh·컨테이너 안의 쓰기와 host:path 목적지는 이미 있는 파일로 본다. 명령 안에서 HOME 을 바꾸거나 명령 단어가 $ 로 시작하면 cwd·~ 를 모른다고 본다.
# git 의 작업 트리를 모르면(상대 core.worktree·--config-env·명령 안의 GIT_WORK_TREE) git 이 쓰는 경로도 이미 있는 파일로 본다.
# 마이그레이션 이름·명령 어휘가 없는 세그먼트·셸 문자열은(이름이 든 기준 디렉터리도 없으면) 쓰기·안쪽 명령을 따지지 않는다 — 판정이 날 수 없다.
# 아주 큰 명령: awk 를 부르는 횟수(따옴표가 든 쓰는 명령의 단어 나누기·셸 문자열 다시 파싱)가 상한(GM_FKMAX)을 넘으면, 그 뒤의 그런 세그먼트는
# 이름·어휘가 있거나 이름이 든 기준 디렉터리가 있을 때 이미 있는 마이그레이션 수정·삭제로 본다(10초 제한을 넘겨 판정 없이 통과하지 않게).
# 미리 보기(liquibase *-sql·alembic/flask --sql)는 통과지만, 출력을 DB 클라이언트(psql 등)로 파이프하면 적용·롤백이다(원문 비교는 선형 시간).
# Edit/Write 는 세션 cwd 아래 파일이면 cwd 의 저장소 루트 기준 경로로 판정한다(루트 위 디렉터리 이름은 보지 않고, 루트 자신의 이름은 본다).
# 서브에이전트 판정은 .agent_id(H_AGENT_ID) 만 쓴다 — .agent_type 은 --agent 로 띄운 메인 세션에도 들어 있다(D6, hooks.md).
GM_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
. "$GM_DIR/lib/common.sh"
hook_off CLAUDE_GUARD_MIGRATIONS && exit 0
hook_read_input
hook_require_pretooluse
case $H_TOOL in Edit|Write|MultiEdit|Bash|Monitor) ;; *) exit 0 ;; esac   # D5: Monitor 는 Bash 와 동일
GM_SUB=0; [ -n "$H_AGENT_ID" ] && GM_SUB=1

GM_SEV=0; GM_RULE=""; GM_REASON=""
GM_SEVMAX=2; [ "$GM_SUB" -eq 1 ] && GM_SEVMAX=3; GM_DONE=0   # 메인은 ask(2), 서브에이전트는 deny(3)가 가장 센 결정 — 닿으면 더 볼 것이 없다
GM_FK=0; GM_FKMAX=150   # awk 를 부르는 횟수(세그먼트 단어·셸 문자열 다시 파싱)의 상한 — 넘으면 보수적으로 본다(10초 제한을 넘겨 판정 없이 통과하지 않게)
GM_REC=0; GM_RECCAP=5000   # R5: 처리한 파서 레코드 수 상한(최상위 + 다시 파싱한 셸 문자열 전체). 문자열마다 파서 상한(5000)을 새로 받으면 합이 끝이 없어 10초를 넘겼다 — 남은 몫만 넘기고 넘으면 too-complex
GM_SUBAGENT_REASON="차단 [migrations:subagent]: 서브에이전트는 마이그레이션 생성·적용·수정·롤백 금지(subagent-policy §1·§4) — 메인에 보고할 것"
GM_DESTR_REASON="확인 필요 [migrations:destructive-schema]: 파괴적 스키마 변경 — 2단계(추가→백필→전환→삭제)와 백업 여부 확인"
GM_DESTRUCTIVE_RE='removefield|deletemodel|alterfield|renamefield|drop_table|drop_column|droptable|dropcolumn|op\.drop_|drop table|drop column|alter table .* drop|\.drop\(|dropindex|removecolumn|changecolumn|renamecolumn|remove_column|change_column|rename_column|dropforeign|truncate'
# R3: ssh·docker/podman/nerdctl exec|run·docker compose exec|run·kubectl exec 가 있는 명령(소문자; 세그먼트 구분자를 넘지 않는다)
GM_REMOTE_RE=$'(^|[^a-z0-9_.-])(auto)?ssh[ \t]|(docker|podman|nerdctl)[^;&|()\n]*[ \t](exec|run)[ \t]|kubectl[^;&|()\n]*[ \t]exec[ \t]|(^|[^a-z0-9_.-])oc[ \t][^;&|()\n]*exec[ \t]'

gm_hit() { [ "$1" -gt "$GM_SEV" ] || return 0; GM_SEV=$1; GM_RULE=$2; GM_REASON=$3; [ "$1" -lt "$GM_SEVMAX" ] || GM_DONE=1; }   # 더 셀 수 없으면 gm_run 이 멈춘다(결정은 같다)
gm_fk() { GM_FK=$((GM_FK + 1)); [ "$GM_FK" -le "$GM_FKMAX" ]; }   # awk 를 한 번 더 불러도 되면 0
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
gm_destr() {  # <text> → 0 이면 파괴적 스키마 변경 패턴이 있음(대소문자 무시)
  local rc=1
  shopt -s nocasematch
  case $1 in   # 패턴마다 들어 있는 낱말로 먼저 거른다 — 정규식은 부를 때마다 다시 컴파일돼 세그먼트가 아주 많은 명령의 고정 비용이 크다
    *drop*|*remove*|*delete*|*alter*|*rename*|*change*|*truncate*) [[ $1 =~ $GM_DESTRUCTIVE_RE ]] && rc=0 ;;
  esac
  shopt -u nocasematch
  return $rc
}

# gm_is_migration <path> → 0 이면 마이그레이션 파일(제외 파일은 1). fork 없음.
gm_is_migration() {
  local p=$1 b
  case $p in *migrat*|*alembic*|*drizzle*|*flyway*|*liquibase*|*goose*|*dbmate*|*db/migrate*) ;; *) return 1 ;; esac
  case /$p/ in */../*) ;; *) case /$p in */__pycache__/*|*/__pycache__) return 1 ;; esac ;; esac   # F20: 바이트코드 캐시는 마이그레이션이 아니다(.. 로 빠져나오는 경로는 제외하지 않음)
  case /$p in
    */migrations/*|*/migration/*|*/alembic/versions/*|*/db/migrate/*|*/prisma/migrations/*|*/supabase/migrations/*|*/drizzle/*|*/knex/migrations/*|*/sequelize/migrations/*|*/typeorm/migrations/*|*/flyway/*|*/liquibase/*|*/sql/migrations/*|*/db/migrations/*|*/atlas/migrations/*|*/goose/*|*/dbmate/*) ;;
    *) return 1 ;;
  esac
  b=${p##*/}
  case $b in ''|__init__.py|README*|*.md|env.py|script.py.mako|alembic.ini|migration_lock.toml|*.lock|*.pyc|*.pyo) return 1 ;; esac
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
gm_dotdot() {  # <절대 경로> → GM_ND: . 과 .. 를 글자로 접은 경로(bash 의 cd -L·Write 도구의 경로 정규화와 같은 방식). fork 없음
  local p=$1 c o="" IFS=/
  case $p in */.|*/./*|*/..|*/../*) ;; *) GM_ND=$p; return 0 ;; esac
  set -f
  for c in $p; do
    case $c in ''|.) ;; ..) o=${o%/*} ;; *) o=$o/$c ;; esac
  done
  set +f
  GM_ND=${o:-/}
}

# ---- Edit / Write / MultiEdit ----
gm_file_mig() {  # <절대 경로> <글자로 접은 경로> → 0 이면 마이그레이션. 세션 cwd 아래 파일은 cwd 의 저장소 루트 기준 경로로 판정한다
  # (…/goose/·…/drizzle/ 처럼 도구 이름의 디렉터리에 클론한 저장소에서 모든 편집이 걸리지 않게; Bash 의 gm_rel 과 같은 방식).
  # 접은 경로와 접지 않은 경로(.. 포함) 중 하나라도 마이그레이션이면 마이그레이션이다. cwd 밖·저장소가 아니면 경로 그대로(예전과 같음)
  local c
  hook_abspath_var "${H_CWD:-$PWD}" /; gm_dotdot "$HOOK_ABS"; c=$GM_ND
  case $2 in "$c"/*) ;; *) gm_is_migration "$H_PATH"; return ;; esac
  gm_root_of "$c"
  [ -n "$GM_ROOT" ] || { gm_is_migration "$H_PATH"; return; }
  # 저장소 루트 자신의 이름은 남긴다 — migrations·flyway 같은 이름의 저장소·서브모듈(세션 cwd 가 그 안)에서도 마이그레이션을 지킨다
  gm_is_migration "${GM_ROOT##*/}/${2#"$GM_ROOT"/}" && return 0
  case $1 in "$GM_ROOT"/*) gm_is_migration "${GM_ROOT##*/}/${1#"$GM_ROOT"/}" ;; *) gm_is_migration "$1" ;; esac
}
gm_file_tools() {
  local abs nd
  [ -n "$H_PATH" ] || exit 0
  if [ "${#H_PATH}" -gt 4096 ]; then   # R5: 4096자를 넘는 경로는 경로 판정이 길이의 제곱(100 KB 에 7.5초) — 마이그레이션 낱말이 있으면 분석하지 않고 too-complex, 없으면 통과
    case $H_PATH in *migrat*|*alembic*|*versions*|*drizzle*|*flyway*|*liquibase*|*goose*|*dbmate*|*/db/migrate*) gm_too_complex; gm_finish ;; esac
    exit 0
  fi
  hook_abspath_var "$H_PATH" "$H_CWD"; abs=$HOOK_ABS; gm_dotdot "$abs"; nd=$GM_ND   # .. 이 든 경로는 실제 경로와 글자로 접은 경로 둘 다 본다
  gm_file_mig "$abs" "$nd" || exit 0
  [ "$GM_SUB" -eq 1 ] && { gm_hit 3 migrations:subagent "$GM_SUBAGENT_REASON: $H_PATH"; gm_finish; }
  if [ -e "$abs" ] || [ -e "$nd" ]; then
    gm_hit 2 migrations:edit-existing "확인 필요 [migrations:edit-existing]: 이미 존재하는 마이그레이션 수정 — 적용된 마이그레이션이면 수정 대신 새 마이그레이션을 만들 것: $H_PATH"
    gm_finish
  fi
  hook_fields 'GM_CONTENT=.tool_input.content|.tool_input.new_string|.tool_input.edits' || gm_finish
  gm_destr "$GM_CONTENT" && gm_hit 2 migrations:destructive-schema "$GM_DESTR_REASON: $H_PATH"
  gm_finish
}

# ---- Bash ----
GM_HEAD=""; GM_FILE=""; GM_NEW=0; GM_NEW_FILE=""; GM_ANY_DESTR=0; GM_ARGS=(); GM_WOK=0
GM_WT=""; GM_WTD=""; GM_WTR=""; GM_SRC=""; GM_DEL=""; GM_FB=0; GM_FBK=""; GM_GC=""; GM_P=""
GM_TOOL=""; GM_VERB=""; GM_VC=""; GM_C=""; GM_LOW=""; GM_REMOTE=""; GM_FUNC=0; GM_PEND=0; GM_CDPATH=0; GM_IX=0; GM_INNER=""
GM_CWD=""; GM_EFF=""; GM_EFF_UNKNOWN=0; GM_DIRS=""; GM_NDIRS=0; GM_SP=0; GM_S_EFF=(); GM_S_UNK=()   # 유효 작업 디렉터리(cd 추적)와 서브셸·sh -c 의 상태 스택
GM_ND=""; GM_REL=""; GM_ROOT=""; GM_RB=""; GM_RR=""; GM_SV=""; GM_SA=""; GM_SB=""; GM_LN=""; GM_LK=""; GM_LV=""; GM_LA=0
GM_RB_='}'; GM_DIRX=(); GM_ADIRS=""; GM_NADIRS=0; GM_WORK=0; GM_WORKC=0; GM_PHC=0; GM_KDIRS=""; GM_HOMESET=0; GM_ALTK=""; GM_PV=""; GM_PVX=""; GM_PVNEW=0; GM_NS=""; GM_NPIPE=0   # S1 있는 디렉터리·cd 후보 기억 · S2 HOME 변경 · S3 미리 보기 보류
GM_L=(); GM_KADIRS=""; GM_GWT=0; GM_GWU=0; GM_EP=""   # 줄 목록 배열 · 이름이 든 저장소 안 cd 후보 · GIT_WORK_TREE·모르는 작업 트리 · 컨테이너 --entrypoint
GM_WCM=$'\001'; GM_WCR=""; GM_WCA=(); GM_WCT=""; GM_WCRC=0; GM_UQ=""; GM_SSK=$'\001'; GM_SSV=""   # gm_words·sp_segments 의 마지막 입력·결과 · gm_unq 결과
# S3: 미리 보기 SQL 을 표준 입력으로 받아 실행하는 DB 클라이언트(컨테이너·ssh·셸 문자열 안의 것은 원문 단어로 찾는다)
GM_DBCLI_RE='(^|[^A-Za-z0-9_.-])(psql|mysql|mariadb|sqlite3|sqlcmd|clickhouse-client|sqlplus|mysqlsh|duckdb|usql|pgcli|mycli|litecli|snowsql|isql|osql|mssql-cli)([^A-Za-z0-9_.-]|$)'
# cp·mv·install 의 긴 옵션(R7): 이름=불리언, 이름= 는 붙인 값만, 이름: 은 값 필수(다음 단어도 됨)
GM_CP_LONG='archive attributes-only backup= copy-contents dereference force interactive link no-clobber no-dereference preserve= no-preserve: parents recursive reflink= remove-destination sparse: strip-trailing-slashes suffix: symbolic-link target-directory: no-target-directory update= verbose one-file-system context= keep-directory-symlink debug help version'
GM_MV_LONG='backup= force interactive no-clobber strip-trailing-slashes suffix: target-directory: no-target-directory update= verbose context= exchange no-copy debug help version'
GM_IN_LONG='backup= compare directory group: mode: owner: preserve-timestamps strip strip-program: suffix: target-directory: no-target-directory verbose preserve-context context= debug help version'
GM_RSYNC_VALS='-e --rsh -f --filter --exclude --include --exclude-from --include-from --files-from -T --temp-dir --backup-dir --suffix --compare-dest --copy-dest --link-dest --log-file --log-file-format --password-file --partial-dir --chmod --chown --usermap --groupmap --copy-as -B --block-size --bwlimit --max-size --min-size --max-delete --max-alloc --modify-window --timeout --contimeout --port --address --sockopts --rsync-path -M --remote-option --out-format --info --debug --iconv --checksum-choice --cc --checksum-seed --compress-choice --zc --compress-level --zl --skip-compress --outbuf --stop-after --stop-at --write-batch --only-write-batch --read-batch --protocol --early-input'

# docker·podman·nerdctl·compose 의 전역 옵션과 exec·run 옵션 중 값을 받는 것(공용 파서가 벗기지 않는 형태의 안쪽 명령 찾기; R3)
GM_CTR_VALS=' -c --context -H --host -l --log-level --config --tlscacert --tlscert --tlskey -f --file -p --project-name --profile --env-file --project-directory --ansi --progress --parallel -e --env -u --user -w --workdir --detach-keys --index --entrypoint --label --label-file --name --publish -v --volume --network --net --network-alias --mount --add-host --cap-add --cap-drop --cgroup-parent --cgroupns --cidfile --cpus --cpu-shares --cpu-period --cpu-quota --cpuset-cpus --cpuset-mems --device --dns --dns-option --dns-search --domainname --expose --gpus --group-add -h --hostname --ip --ip6 --ipc --isolation --link --log-driver --log-opt --mac-address -m --memory --memory-reservation --memory-swap --oom-score-adj --pid --pids-limit --platform --pull --restart --runtime --security-opt --shm-size --stop-signal --stop-timeout --storage-opt --sysctl --tmpfs --ulimit --userns --uts --volume-driver --volumes-from --health-cmd --health-interval --health-retries --health-timeout --health-start-period --annotation -a --attach --blkio-weight --kernel-memory '
gm_head() { set -f; set -- $1; GM_HEAD=${1:-}; set +f; }
gm_file_tokens() {  # <raw> [dirs=1] → 0 이면 마이그레이션 파일(dirs=1 이면 디렉터리도) 토큰이 있음(GM_FILE 에 첫 토큰; 리디렉션 대상 포함). 단어를 맞추지 못할 때의 옛 규칙
  local t dirs=${2:-0} out
  GM_FILE=""
  gm_fk || { gm_bigx "$1"; return; }   # awk 상한을 넘었다 — 이름·어휘가 있으면 토큰이 있는 것으로(보수적으로)
  out=$(sp_tokens "$1")   # 세그먼트마다 < <(…) 를 쓰면 bash 3.2 가 약 250번째에서 죽는다(R11) — 명령 치환 + heredoc
  while IFS= read -r t; do
    case $t in '<'*|'>'*) t=${t#>}; t=${t#>}; t=${t#<} ;; esac
    [ -n "$t" ] || continue
    gm_is_migration "$t" && { GM_FILE=$t; return 0; }
    [ "$dirs" -eq 1 ] && gm_is_migration_dir "$t" && { GM_FILE=$t; return 0; }
  done <<GMEOF
$out
GMEOF
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
gm_vclass() {  # <도구> <단어> → GM_C(apply|destructive|create|preview|빈 값)
  case $1:$2 in
    liquibase:execute*) GM_C="" ;;   # execute-sql 은 SQL 을 실행한다(미리 보기 아님) — 분류하지 않는다
    liquibase:*-sql|liquibase:*SQL|liquibase:*Sql) GM_C=preview ;;   # R10: update-sql·updateSQL·rollback-sql 등은 SQL 만 출력(postgresql 같은 단어는 아님)
    goose:up|goose:up-by-one|goose:up-to|dbmate:up|dbmate:migrate|migrate:up|migrate:goto|alembic:upgrade|flask:upgrade|flyway:migrate|knex:migrate:latest|knex:migrate:up|artisan:migrate|artisan:migrate:*|liquibase:update|liquibase:update-*|liquibase:update[A-Z]*) GM_C=apply ;;
    goose:down|goose:down-to|goose:reset|dbmate:rollback|dbmate:down|dbmate:drop|migrate:down|migrate:drop|alembic:downgrade|flask:downgrade|flyway:clean|knex:migrate:rollback|knex:migrate:down|liquibase:rollback*|liquibase:drop-all|liquibase:dropAll) GM_C=destructive ;;
    goose:create|dbmate:new|migrate:create|alembic:revision|flask:migrate|knex:migrate:make|artisan:make:migration) GM_C=create ;;
    *) GM_C="" ;;
  esac
}
gm_tool_verb() {  # <masked> → GM_TOOL·GM_VERB·GM_VC: 도구 단어 뒤에서 처음 나오는 분류 동사(F11).
  # 사이의 옵션·옵션 값·위치 인수(goose 의 드라이버·DB 문자열 등)는 건너뛴다. 읽기 전용 동사(status·version 등)는 분류하지 않는다.
  # 뒤에 나온 도구 단어가 앞의 것보다 먼저 맞춰 본다(R9: docker run --name goose flyway/flyway migrate). 스크립트 이름의 : 뒤(db:goose)도 도구.
  local w b t tools="" fdb=0 pt="" pw="" rd=0 d o ws j=0 pn=0
  GM_TOOL=""; GM_VERB=""; GM_VC=""
  set -f; ws=($1); set +f   # 위치 인수(set --)가 아니라 배열로 — 단어가 수천 개면 루프 안의 함수 호출(gm_vclass)마다 bash 3.2 가 위치 인수를 다뤄 2차 비용(10초 제한)
  [ "${ws[0]##*/}" = migrate ] && { tools=migrate; j=1; }   # golang-migrate 는 명령 머리일 때만(manage.py migrate·npm run migrate 의 migrate 와 구분)
  for w in "${ws[@]:$j}"; do
    if [ -n "$pt" ]; then   # 미리 보기 뒤: 리디렉션·그 대상과 파일·버전처럼 보이는 단어(. /)는 동사가 아니다(> rollback.sql·--output-file update-v2.sql)
      pn=$((pn + 1)); [ "$pn" -le 64 ] || break   # 옵션 값을 동사로 잘못 읽은 경우만 고치면 된다 — 뒤 64단어까지만(아주 긴 세그먼트에서 r2b 처럼 바로 끝낸다)
      [ "$rd" -eq 1 ] && { rd=0; continue; }
      d=${w%%[!0-9]*}; o=${w#"$d"}
      case $o in '>'*|'<'*|'&>'*) [ -z "${o#"${o%%[!<>&|]*}"}" ] && rd=1; continue ;; esac
      case $w in *.*|*/*) continue ;; esac
    fi
    case $w in -*|*://*) continue ;; esac   # 옵션(-url=…)·URL 은 도구 이름도 동사도 아니다
    b=${w##*/}; t=${b%%[@:]*}             # 경로·버전(@v3)·이미지 태그(:10) 제거
    case $t in
      alembic|goose|dbmate|flyway|liquibase|knex|artisan|flask) ;;
      *) t=""
         case $w in migrate/migrate|migrate/migrate[@:]*|*/migrate/migrate|*/migrate/migrate[@:]*) t=migrate ;; esac   # golang-migrate 공식 도커 이미지
         case $b in *:*) case ${b##*:} in alembic|goose|dbmate|flyway|liquibase|knex|artisan) t=${b##*:} ;; esac ;; esac ;;
    esac
    if [ -n "$t" ]; then   # 같은 도구 이름은 한 번만 두고 앞으로 옮긴다 — 도구 단어마다 목록이 자라면 뒤 단어마다 목록 전체를 돌아 2차 비용(4KB 에 8초)
      case " $tools" in *" $t "*) tools=" $tools"; tools=${tools/" $t "/ }; tools=${tools# } ;; esac
      tools="$t $tools"; [ "$t" = flask ] && fdb=0; continue
    fi
    [ -n "$tools" ] || continue
    [ "$w" = db ] && { fdb=1; continue; }   # flask 의 db 그룹
    case $w in   # gm_vclass 가 분류할 수 있는 낱말만 넘긴다(도구 뒤 단어가 수천 개인 세그먼트에서 단어마다 함수를 부르지 않게)
      up|up-*|migrate|migrate:*|goto|upgrade|update*|down|down-*|downgrade|reset|rollback*|drop*|clean|create|new|revision|make:migration|*-sql|*SQL|*Sql) ;;
      *) continue ;;
    esac
    for t in $tools; do
      [ "$t" = flask ] && [ "$fdb" -eq 0 ] && continue
      gm_vclass "$t" "$w"
      case $GM_C in
        '') ;;
        preview) [ -n "$pt" ] || { pt=$t; pw=$w; } ;;   # S3: 미리 보기는 기억만 하고 계속 본다(liquibase --changelog-file changes-sql update 의 값 changes-sql)
        *) GM_TOOL=$t; GM_VERB=$w; GM_VC=$GM_C; return 0 ;;
      esac
    done
  done
  [ -n "$pt" ] && { GM_TOOL=$pt; GM_VERB=$pw; GM_VC=preview; }   # 뒤에 적용·롤백·생성 동사가 없을 때만 미리 보기
  return 0
}

# ---- 작업 디렉터리 추적(B407·R2·R12) ----
gm_root_of() {  # <절대 디렉터리> → GM_ROOT: 위로 올라가며 처음 .git 이 있는 디렉터리(없으면 빈 값). 마지막 결과를 기억한다
  local d=$1
  [ "$1" = "$GM_RB" ] && { GM_ROOT=$GM_RR; return 0; }
  GM_ROOT=""
  while [ -n "$d" ] && [ "$d" != / ]; do
    [ -e "$d/.git" ] && { GM_ROOT=$d; break; }
    d=${d%/*}
  done
  GM_RB=$1; GM_RR=$GM_ROOT
}
gm_rel() {  # <상대 경로> <기준 디렉터리> → GM_REL: 푼 경로를 그 저장소 루트 기준으로(루트 밖·저장소가 아니면 절대 경로).
  # 루트 위의 디렉터리 이름(…/goose/ 에 클론한 저장소)은 보지 않는다
  hook_abspath_var "$1" "$2"; gm_dotdot "$HOOK_ABS"; GM_REL=$GM_ND
  gm_root_of "$2"
  [ -n "$GM_ROOT" ] || return 0
  case $GM_REL in "$GM_ROOT"/*) GM_REL=${GM_REL#"$GM_ROOT"/} ;; "$GM_ROOT") GM_REL=. ;; esac
}
gm_add_dir() {  # <절대 경로> [있음=1] [cd 후보=1] — cd 가 닿은(닿았을 수 있는) 디렉터리 목록에 더한다. 목록마다 64개를 넘으면 더하지 않고 상대 경로는 있는 파일로 본다.
  # 따라간 경로는 GM_DIRS(존재·마이그레이션 판정), gm_cd_alt 의 후보는 GM_ADIRS(존재 판정만 — 저장소 밖 조상 디렉터리 이름으로 마이그레이션이 되지 않게;
  # 한도도 따로 세어 따라간 경로가 후보에 밀려 빠지지 않는다)
  case $'\n'$GM_DIRS in *$'\n'"$1"$'\n'*) return 0 ;; esac
  if [ "${3:-0}" = 1 ]; then
    [ "$GM_NADIRS" -lt 64 ] || return 0
    case $'\n'$GM_ADIRS in *$'\n'"$1"$'\n'*) return 0 ;; esac
    GM_NADIRS=$((GM_NADIRS + 1)); GM_ADIRS=$GM_ADIRS$1$'\n'
    case $1 in *migrat*|*alembic*|*drizzle*|*flyway*|*liquibase*|*goose*|*dbmate*)   # S1: 저장소 안이고 루트 기준 경로에 이름이 있는 후보는 마이그레이션
      gm_root_of "$1"   # 판정의 기준으로도 쓴다(gm_mig; 세션 cwd 가 db/ 일 때 미끼 cd 뒤의 cd migrate). 저장소 밖 후보(…/goose 조상)는 넣지 않는다
      if [ -n "$GM_ROOT" ]; then case ${1#"$GM_ROOT"} in *migrat*|*alembic*|*drizzle*|*flyway*|*liquibase*|*goose*|*dbmate*) GM_KADIRS=$GM_KADIRS$1$'\n' ;; esac; fi ;;
    esac
  else
    [ "$GM_NDIRS" -lt 64 ] || return 0
    GM_NDIRS=$((GM_NDIRS + 1)); GM_DIRS=$GM_DIRS$1$'\n'
    case $1 in *migrat*|*alembic*|*drizzle*|*flyway*|*liquibase*|*goose*|*dbmate*) GM_KDIRS=$GM_KDIRS$1$'\n'   # 이름으로 마이그레이션이 될 수 있는 기준(gm_mig)
      # 먼저 S1 후보로 들어간 디렉터리를 따라갔으면 후보 목록에서 뺀다 — 같은 기준을 gm_mig 가 두 번 훑으면 서비스가 많은 모노레포 루프가
      # 작업 상한(gm_work)을 먼저 써 버려 로그 쓰기까지 마이그레이션 수정이 된다
      case $'\n'$GM_KADIRS in *$'\n'"$1"$'\n'*) local nl=$'\n'; GM_KADIRS=$nl$GM_KADIRS; GM_KADIRS=${GM_KADIRS/"$nl$1$nl"/$nl}; GM_KADIRS=${GM_KADIRS#"$nl"} ;; esac ;;
    esac
  fi
  [ "${2:-0}" = 1 ] && GM_DIRX[${#GM_DIRX[@]}]=$1   # 있는 디렉터리만 따로(gm_cd_alt 의 기준) — 없는 디렉터리는 셸의 cwd 가 될 수 없다
  return 0
}
gm_work() { GM_WORK=$((GM_WORK + 1)); [ "$GM_WORK" -le 2048 ]; }   # 상대 경로를 디렉터리 목록에 맞춰 보는 횟수의 상한(한 번 실행에).
gm_workc() { GM_WORKC=$((GM_WORKC + 1)); [ "$GM_WORKC" -le 2048 ]; }   # gm_cd_alt 의 상한은 따로 센다 — cd 가 많은 명령이 쓰기 판정의 상한을 먼저 써 버려 로그 파일까지 마이그레이션이 되지 않게
# cd·쓰기가 아주 많은 명령이 10초 제한을 넘겨 판정 없이 통과하지 않도록, 넘으면 보수적으로 본다(마이그레이션·이미 있는 파일·후보 목록 넘침)
gm_mig() {  # <경로> <dirs> → 0 이면 마이그레이션(dirs=1 이면 디렉터리도). 글자 그대로, 또는 상대 경로를 세션 cwd·cd 가 닿은 디렉터리에서 푼 경로로(R12)
  local rest="" d
  gm_is_migration "$1" && return 0
  [ "$2" = 1 ] && gm_is_migration_dir "$1" && return 0
  case $1 in ''|/*|'~'*|'$'*) return 1 ;; esac
  case $1 in
    *migrat*|*alembic*|*drizzle*|*flyway*|*liquibase*|*goose*|*dbmate*) rest=$GM_CWD$'\n'$GM_EFF$'\n'$GM_DIRS ;;   # 유효 cwd 도 본다 — 64개 한도로 GM_DIRS 에 못 들어간 cd 뒤(S4)
    *)   # 경로에 마이그레이션·도구 이름이 없으면 그런 이름이 든 기준 디렉터리에서만 마이그레이션이 될 수 있다 — 나머지는 보지 않는다
         # (디렉터리가 많은 명령의 평범한 상대 쓰기가 상한을 써 버려 마이그레이션으로 판정되거나 목록을 매번 훑지 않게)
      for d in "$GM_CWD" "$GM_EFF"; do case $d in *migrat*|*alembic*|*drizzle*|*flyway*|*liquibase*|*goose*|*dbmate*) rest=$rest$d$'\n' ;; esac; done
      rest=$rest$GM_KDIRS$GM_KADIRS ;;
  esac
  while [ -n "$rest" ]; do
    d=${rest%%$'\n'*}; rest=${rest#*$'\n'}
    [ -n "$d" ] || continue
    gm_work || return 0
    gm_rel "$1" "$d"
    gm_is_migration "$GM_REL" && return 0
    [ "$2" = 1 ] && gm_is_migration_dir "$GM_REL" && return 0
  done
  return 1
}
gm_exists_at() {  # <경로> <기준> → 0 이면 있음(.. 은 실제 경로와 글자로 접은 경로 둘 다 본다)
  hook_abspath_var "$1" "$2"
  { [ -e "$HOOK_ABS" ] || [ -L "$HOOK_ABS" ]; } && return 0
  gm_dotdot "$HOOK_ABS"
  [ "$GM_ND" != "$HOOK_ABS" ] && { [ -e "$GM_ND" ] || [ -L "$GM_ND" ]; }
}
gm_remote() {  # → 0 이면 ssh·컨테이너 안에서 실행되는 부분이 있는 명령(R3; 처음 필요할 때 한 번 계산)
  if [ -z "$GM_REMOTE" ]; then GM_REMOTE=0; [[ $GM_LOW =~ $GM_REMOTE_RE ]] && GM_REMOTE=1; fi
  [ "$GM_REMOTE" -eq 1 ]
}
gm_exists() {  # <경로> → 0 이면 이미 있는 파일로 본다. 상대 경로는 세션 cwd·cd 가 닿은 디렉터리 중 한 곳에라도 있으면(R2)
  local rest d
  gm_remote && return 0                                            # ssh·docker exec 등 안의 쓰기(R3)
  case $1 in *[*?[{]*|*'$'*|*'`'*|'~'[!/]*|:*) return 0 ;; esac   # 글롭·중괄호·변수·치환, ~+ ~- ~user(R5), git 매직 경로(:/x)
  case $1 in '~'|'~/'*) [ "$GM_HOMESET" -eq 1 ] && return 0 ;; esac   # S2: 명령 안에서 HOME 을 바꿨다 — ~ 가 어디인지 모른다
  case $1 in /*|'~'|'~/'*) gm_exists_at "$1" /; return ;; esac
  [ "$GM_EFF_UNKNOWN" -eq 0 ] && [ "$GM_NDIRS" -lt 64 ] && [ "$GM_NADIRS" -lt 64 ] || return 0   # 따라가지 못한 cd·eval·source 뒤의 상대 경로(디렉터리 목록이 넘쳐도)
  rest=$GM_CWD$'\n'$GM_DIRS$GM_ADIRS   # S1: 돌지 않았을 수 있는 cd 의 후보(GM_ADIRS)도
  while [ -n "$rest" ]; do
    d=${rest%%$'\n'*}; rest=${rest#*$'\n'}
    [ -n "$d" ] || continue
    gm_work || return 0
    gm_exists_at "$1" "$d" && return 0
  done
  return 1
}
gm_isdir() {  # <경로> → 0 이면 디렉터리(상대 경로는 세션 cwd·cd 가 닿은 디렉터리 중 한 곳에서)
  local rest d
  case $1 in /*|'~'|'~/'*) hook_abspath_var "$1" /; [ -d "$HOOK_ABS" ]; return ;; esac
  rest=$GM_CWD$'\n'$GM_DIRS
  while [ -n "$rest" ]; do
    d=${rest%%$'\n'*}; rest=${rest#*$'\n'}
    [ -n "$d" ] || continue
    gm_work || return 1   # 상한을 넘으면 디렉터리가 아닌 것으로 — 목적지 자체를 쓰는 경로로 판정한다
    hook_abspath_var "$1" "$d"; [ -d "$HOOK_ABS" ] && return 0
  done
  return 1
}
gm_cd_unknown() { GM_EFF_UNKNOWN=1; GM_EFF=""; }
gm_split() { local IFS=$'\n'; set -f; GM_L=($1); set +f; }   # <줄 목록> → GM_L(줄마다 한 원소, 빈 줄 제외). 단어 나누기 한 번(선형)
gm_cd_alt() {  # <상대 cd 대상> — 앞의 cd 는 실제로 돌지 않았을 수 있으므로(false && cd /x; cd app·cd /x & cd app·cd /x | true) 대상을
  # 세션 cwd 와 cd 가 닿은 모든 디렉터리 기준으로도 풀어 존재 판정의 합집합(GM_ADIRS)에 더한다(S1). 있는 디렉터리만 더한다 — 없으면 그 cd 는
  # 실패하고 cwd 는 이미 합집합에 있는 그 자리다. 후보도 64개 한도(넘치면 상대 경로는 있는 파일로). 같은 대상·같은 목록이면 결과도 같으므로 다시 풀지 않는다(반복 cd 의 비용)
  local d k
  [ "$GM_NADIRS" -lt 64 ] || return 0
  k=$1$'\t'${#GM_DIRX[@]}
  case $'\n'$GM_ALTK in *$'\n'"$k"$'\n'*) return 0 ;; esac
  for d in "$GM_CWD" "${GM_DIRX[@]}"; do   # 기준은 세션 cwd 와 있는 디렉터리(펼친 목록은 고정 — 이 cd 가 더한 것은 이 cd 의 기준이 아니다)
    [ "$GM_NADIRS" -lt 64 ] || break
    [ -n "$d" ] || continue
    gm_workc || { GM_NADIRS=64; break; }   # 상한을 넘으면 후보 목록이 넘친 것으로(상대 경로는 있는 파일로)
    hook_abspath_var "$1" "$d"; gm_dotdot "$HOOK_ABS"
    if [ -d "$GM_ND" ]; then gm_add_dir "$GM_ND" 1 1
    elif [ "$GM_ND" != "$HOOK_ABS" ] && [ -d "$HOOK_ABS" ]; then gm_add_dir "$HOOK_ABS" 1 1; fi   # 심볼릭 링크 뒤의 .. 은 실제 경로
  done
  [ "${#GM_ALTK}" -le 8192 ] || GM_ALTK=""
  GM_ALTK=$GM_ALTK$k$'\n'
}
gm_pend() { [ "$GM_PEND" -eq 1 ] || return 0; GM_PEND=0; gm_cd_unknown; }   # eval 은 안쪽 명령(sub 줄)을 본 뒤에 cwd 를 모르는 상태로
gm_cd() {  # GM_ARGS(cd·pushd·popd·chdir 와 인수) → GM_EFF(글자 기준 유효 디렉터리)·GM_EFF_UNKNOWN·GM_DIRS
  local w d="" i=1 n=${#GM_ARGS[@]} have=0 unk=0 x
  [ "$GM_HEAD" = popd ] && { gm_cd_unknown; return 0; }
  while [ "$i" -lt "$n" ]; do
    w=${GM_ARGS[$i]}; i=$((i + 1))
    case $w in
      --) [ "$i" -lt "$n" ] && { d=${GM_ARGS[$i]}; have=1; }; break ;;
      -|-[0-9]*|+[0-9]*) gm_cd_unknown; return 0 ;;                # cd - (OLDPWD), pushd ±N(스택 회전)
      -n) [ "$GM_HEAD" = pushd ] && { gm_cd_unknown; return 0; } ;;  # pushd -n 은 cwd 를 바꾸지 않고 스택만
      -*) ;;                                                         # cd -L/-P 같은 옵션
      *) d=$w; have=1; break ;;
    esac
  done
  if [ "$have" -eq 0 ]; then
    case $GM_HEAD in cd|chdir) d=$HOME ;; *) gm_cd_unknown; return 0 ;; esac   # 인수 없는 pushd 는 스택 위 둘을 맞바꾼다
    [ "$GM_HOMESET" -eq 1 ] && { gm_cd_unknown; return 0; }   # S2: HOME=… cd·export HOME=… 뒤의 맨 cd
  fi
  case $d in ''|*'$'*|*'`'*|'~'[!/]*|*[*?[]*) gm_cd_unknown; return 0 ;; esac   # cd ""·변수·치환·~+ ~- ~user·글롭
  case $d in '~'|'~/'*) [ "$GM_HOMESET" -eq 1 ] && { gm_cd_unknown; return 0; } ;; esac   # S2: 바꾼 HOME 아래(cd ~/app)
  [ "$GM_FUNC" -eq 1 ] && unk=1   # 함수 정의가 있는 명령의 cd 는 언제 실행될지(실행될지) 모른다
  case $d in /*|'~'|'~/'*|.|..|./*|../*) ;; *) [ "$GM_CDPATH" -eq 1 ] && unk=1 ;; esac   # 명령 안에서 CDPATH 를 바꿨다
  case $d in
    /*|'~'|'~/'*) hook_abspath_var "$d" / ;;
    *) gm_cd_alt "$d"   # S1: 세션 cwd·닿은 디렉터리 기준으로 푼 대상도 합집합에
       [ -n "$GM_EFF" ] || { GM_EFF_UNKNOWN=1; return 0; }
       [ "${#GM_EFF}" -le 1024 ] || { gm_cd_unknown; return 0; }   # cd src; cd src; … 로 끝없이 길어지는 경로는 따라가지 않는다(2차 비용)
       hook_abspath_var "$d" "$GM_EFF" ;;
  esac
  gm_dotdot "$HOOK_ABS"; GM_EFF=$GM_ND
  x=0; [ -d "$GM_EFF" ] && x=1
  gm_add_dir "$GM_EFF" "$x"
  if [ "$GM_EFF_UNKNOWN" -eq 1 ]; then case $d in /*|'~'|'~/'*) ;; *) return 0 ;; esac; fi   # 앞의 cd 를 못 따라갔으면 상대 cd 도 모른다
  if [ "$x" -eq 1 ]; then GM_EFF_UNKNOWN=$unk
  elif [ -d "$HOOK_ABS" ]; then GM_EFF=$HOOK_ABS; gm_add_dir "$GM_EFF" 1; GM_EFF_UNKNOWN=$unk   # 심볼릭 링크 뒤의 .. 은 실제 경로
  else GM_EFF_UNKNOWN=1; fi
}
gm_push() { GM_SP=$((GM_SP + 1)); GM_S_EFF[$GM_SP]=$GM_EFF; GM_S_UNK[$GM_SP]=$GM_EFF_UNKNOWN; }   # 서브셸 안의 cd 는 밖에 영향이 없다
gm_pop() {
  [ "$GM_SP" -gt 0 ] || return 0
  GM_EFF=${GM_S_EFF[$GM_SP]}; GM_EFF_UNKNOWN=${GM_S_UNK[$GM_SP]}; GM_SP=$((GM_SP - 1))
}

# ---- 세그먼트의 단어와 쓰는 경로 ----
gm_words() {  # <masked> <raw> → GM_ARGS(리디렉션을 뺀 단어, 따옴표 제거)와 GM_WT(리디렉션 쓰기 대상, 줄마다 하나).
  # 연산자는 MASKED 로 판별한다(따옴표 안의 > 는 리디렉션이 아님). 반환 1 = 두 단어 수가 어긋남(\\ 뒤 공백 같은 드문 이스케이프),
  # 2 = awk 상한(gm_fk)을 넘어 단어를 나누지 못했다. 마지막으로 성공한 입력·결과를 기억한다(공용 파서는 컨테이너 줄을 묶음 앞뒤로 두 번 낸다)
  local wt0=$GM_WT rc
  if [ "$1" = "$GM_WCM" ] && [ "$2" = "$GM_WCR" ]; then GM_ARGS=("${GM_WCA[@]}"); GM_WT=$GM_WT$GM_WCT; return "$GM_WCRC"; fi
  gm_words0 "$1" "$2"; rc=$?
  GM_WCM=$1; GM_WCR=$2; GM_WCA=("${GM_ARGS[@]}"); GM_WCT=${GM_WT#"$wt0"}; GM_WCRC=$rc   # 2(상한)는 상한이 줄지 않으므로 다시 불러도 같다
  return "$rc"
}
gm_words0() {
  local ms=() rs=() w out wt0=$GM_WT
  set -f; ms=(${1//\\ /_}); set +f   # 이스케이프된 공백(a\ b)은 한 단어 — MASKED 는 연산자 판별에만 쓰므로 _ 로 바꿔 나눈다
  case $2 in
    *[\'\"\\]*)   # 따옴표·역슬래시가 있을 때만 awk 로 단어를 나눈다(R11: < <(…) 대신 명령 치환 + heredoc; 끝의 빈 단어를 지키려고 . 을 붙였다 뗀다)
      case $2 in
        *[\\$'\r']*) ;;
        *) case $1 in *[!\ 0-9\&\<\>\|][\<\>]*) ;; *) gm_mreg && {   # 단어 가운데의 < >(공용 파서가 끊지 않은 꼴)·가리지 않은 따옴표는 awk 로
             # 빠른 길(fork 없음): 역슬래시·CR 이 없고 따옴표가 모두 가린 꼴('Q'·"Q")이면 따옴표 밖 글자는 MASKED 와 RAW 가 같다.
             # ① 머리가 단어를 보는 명령(gm_whead)이 아니면 판정에 쓰이는 것은 리디렉션 쓰기 대상뿐이다 — 대상에 따옴표가 없으면 MASKED 단어로 끝낸다
          rs=("${ms[@]}"); gm_wloop
          case ${GM_ARGS[0]:-} in *[\'\"]*) ;; *) gm_whead "${GM_ARGS[0]:-}" || case $GM_WT in *[\'\"]*) ;; *) return 0 ;; esac ;; esac
          GM_WT=$wt0
          # ② 따옴표 안에 공백이 없으면(공백으로 나눈 RAW 단어 수 = MASKED 단어 수) 단어마다 따옴표를 sp_words 처럼 벗긴다(sed -i '' …·cp "a" b)
          set -f; rs=($2); set +f
          if [ "${#rs[@]}" -eq "${#ms[@]}" ] && gm_unqa; then gm_wloop; return 0; fi
          rs=(); } ;; esac ;;
      esac
      gm_fk || return 2
      out=$(sp_words "$2"; printf .); out=${out%$'\n.'}
      while IFS= read -r w; do rs[${#rs[@]}]=$w; done <<GMEOF
$out
GMEOF
      ;;
    *) set -f; rs=($2); set +f ;;   # 따옴표가 없으면 공용 파서의 단어 = 공백으로 나눈 단어(fork 없음)
  esac
  [ "${#ms[@]}" -eq "${#rs[@]}" ] || return 1
  gm_wloop
  return 0
}
gm_mreg() {  # gm_words0 의 ms(동적 범위) → 0 이면 MASKED 단어의 따옴표가 모두 가린 꼴('Q'·"Q")이다. 아니면(공용 파서가 따옴표를 벗긴 머리 단어에
  # 남은 따옴표 글자·닫히지 않은 따옴표·256자를 넘는 단어) 빠른 길을 쓰지 않는다
  local w x
  for w in "${ms[@]}"; do
    case $w in *[\'\"]*) [ "${#w}" -le 256 ] || return 1; x=${w//\'Q\'/}; x=${x//\"Q\"/}; case $x in *[\'\"]*) return 1 ;; esac ;; esac
  done
  return 0
}
gm_unqa() {  # gm_words0 의 rs(동적 범위)에서 따옴표가 든 단어를 벗긴다(역슬래시 없음). 반환 1 = 512자를 넘는 단어(awk 로)
  local j=0 n=${#rs[@]}
  while [ "$j" -lt "$n" ]; do
    case ${rs[$j]} in *[\'\"]*) [ "${#rs[$j]}" -le 512 ] || return 1; gm_unq "${rs[$j]}"; rs[$j]=$GM_UQ ;; esac
    j=$((j + 1))
  done
  return 0
}
gm_unq() {  # <단어(역슬래시 없음)> → GM_UQ: 공용 파서의 unq 와 같다 — '…'·$'…'·"…" 는 안의 글자(닫히지 않으면 끝까지), 그 밖의 $ 는 그대로
  local s=$1 o="" p
  while [ -n "$s" ]; do
    case $s in
      "'"*) s=${s#?}; case $s in *"'"*) o=$o${s%%"'"*}; s=${s#*"'"} ;; *) o=$o$s; s="" ;; esac ;;
      "\$'"*) s=${s#??}; case $s in *"'"*) o=$o${s%%"'"*}; s=${s#*"'"} ;; *) o=$o$s; s="" ;; esac ;;
      '"'*) s=${s#?}; case $s in *'"'*) o=$o${s%%'"'*}; s=${s#*'"'} ;; *) o=$o$s; s="" ;; esac ;;
      '$'*) o=$o'$'; s=${s#?} ;;
      *) p=${s%%[\'\"\$]*}; o=$o$p; s=${s#"$p"} ;;
    esac
  done
  GM_UQ=$o
}
gm_whead() {  # <명령 이름> → 0 이면 GM_ARGS 의 원문 단어가 필요한 명령(gm_cmd_writes 가 보는 명령·cd 류)
  case $1 in
    tee|cp|gcp|mv|gmv|install|ginstall|rsync|scp|rm|grm|rimraf|git|sed|gsed|perl|ruby|dd|gdd|curl|wget|truncate|gtruncate|patch|gpatch) return 0 ;;
    docker|podman|nerdctl|docker-compose|podman-compose|kubectl|oc|cd|pushd|popd|chdir) return 0 ;;
    -*c*) case ${1#-} in *[![:alpha:]]*) return 1 ;; esac; return 0 ;;
  esac
  return 1
}
gm_wloop() {  # gm_words 의 ms·rs(bash 의 동적 범위) → GM_ARGS·GM_WT
  local n=${#ms[@]} i=0 w r d t op tgt
  GM_ARGS=()
  while [ "$i" -lt "$n" ]; do
    w=${ms[$i]}; r=${rs[$i]}; i=$((i + 1))
    d=${w%%[!0-9]*}; t=${w#"$d"}   # 2> 같은 fd 번호
    case $t in
      '>('*|'<('*) continue ;;   # 프로세스 치환 자리표시(안쪽 명령은 따로 검사)
      '&>>'*) op='&>>' ;; '&>'*) op='&>' ;; '>>'*) op='>>' ;; '>&'*) op='>&' ;; '>|'*) op='>|' ;; '>'*) op='>' ;;   # >| 는 공용 파서가 한 단어로 낼 때를 위해
      '<>'*) op='<>' ;; '<<<'*) op='<<<' ;; '<<-'*) op='<<-' ;; '<<'*) op='<<' ;; '<&'*) op='<&' ;; '<'*) op='<' ;;
      *) GM_ARGS[${#GM_ARGS[@]}]=$r; continue ;;
    esac
    tgt=${r:$((${#d} + ${#op}))}
    if [ -z "$tgt" ] && [ "$i" -lt "$n" ]; then   # 연산자와 대상이 떨어진 형태
      case ${ms[$i]} in '>'*|'<'*|'&>'*) continue ;; esac   # 공용 파서는 2>> 를 "2>" ">" 로 나눈다 — 다음 단어가 연산자를 잇는다
      tgt=${rs[$i]}; i=$((i + 1))
    fi
    case $op in
      '<>') GM_WT=$GM_WT$tgt$'\n' ;;   # 읽기·쓰기로 연다
      '<'*) ;;                         # 입력·heredoc·here-string 은 읽기
      '>&') case $tgt in *[!0-9-]*) GM_WT=$GM_WT$tgt$'\n' ;; esac ;;   # >&2·2>&1·1>&- 는 fd 복제·닫기(파일 없음), >&file 은 파일
      *) GM_WT=$GM_WT$tgt$'\n' ;;
    esac
  done
  return 0
}
gm_short() {  # <글자 묶음> <불리언 글자> <값 글자> <엄격=1|0> → GM_SV(값을 받는 글자)·GM_SA(그 뒤에 붙은 값)·GM_SB(앞의 불리언 글자들).
  # 반환 1 = 모르는 글자(엄격할 때만). 첫 값 글자는 패턴 한 번으로 찾는다(C 로케일) — 글자마다 ${s:1} 로 자르면 긴 묶음(-bbbb… 16KB)에서
  # 2차 비용이라 10초 제한에 닿았다. 글자 목록에는 ] - ^ ! \ 를 쓰지 않는다
  local LC_ALL=C s=$1 p
  GM_SV=""; GM_SA=""; GM_SB=$s
  if [ -n "$3" ]; then
    p=${s%%[$3]*}
    if [ "$p" != "$s" ]; then GM_SB=$p; GM_SV=${s:${#p}:1}; GM_SA=${s:$((${#p} + 1))}; fi
  fi
  if [ "$4" = 1 ]; then case $GM_SB in *[!$2]*) return 1 ;; esac; fi
  return 0
}
gm_long() {  # <--이름[=값]> <목록> → GM_LN(이름)·GM_LK(b|o|r)·GM_LV(붙은 값)·GM_LA(1=붙은 값 있음). 줄인 이름도 하나로 정해지면 받는다(GNU getopt).
  # 반환 1 = 모르는 옵션·모호한 줄임·값을 받지 않는 옵션에 붙은 값
  local o=${1#--} e k hit="" cnt=0
  GM_LA=0; GM_LV=""; GM_LN=""; GM_LK=""
  case $o in *=*) GM_LV=${o#*=}; GM_LA=1; o=${o%%=*} ;; esac
  [ -n "$o" ] || return 1
  for e in $2; do k=${e%[=:]}; [ "$k" = "$o" ] && { hit=$e; break; }; done
  if [ -z "$hit" ]; then
    for e in $2; do k=${e%[=:]}; case $k in "$o"*) hit=$e; cnt=$((cnt + 1)) ;; esac; done
    [ "$cnt" -eq 1 ] || return 1
  fi
  GM_LN=${hit%[=:]}
  case $hit in *=) GM_LK=o ;; *:) GM_LK=r ;; *) GM_LK=b ;; esac
  [ "$GM_LK" = b ] && [ "$GM_LA" -eq 1 ] && return 1
  return 0
}
gm_gp() {  # <경로> → GM_P: git -C 디렉터리 아래로 옮긴 경로(git 하위 명령만; 그 밖에는 그대로)
  GM_P=$1
  [ -n "$GM_GC" ] || return 0
  case $1 in /*|'~'*|'') ;; *) GM_P=$GM_GC/$1 ;; esac
}
gm_add_wt() { gm_gp "$1"; GM_WT=$GM_WT$GM_P$'\n'; [ "$GM_GWU" -eq 0 ] || GM_WTR=$GM_WTR$GM_P$'\n'; }     # 쓰는 로컬 경로(작업 트리를 모르는 git 이면 이미 있는 파일로도)
gm_add_wtd() { gm_gp "$1"; GM_WTD=$GM_WTD$GM_P$'\n'; [ "$GM_GWU" -eq 0 ] || GM_WTR=$GM_WTR$GM_P$'\n'; }  # 쓰는 로컬 경로(마이그레이션 디렉터리면 그 안의 파일을 덮어쓴다)
gm_add_wtr() { GM_WTR=$GM_WTR$1$'\n'; }                 # 원격·컨테이너 쪽 경로(이미 있는 파일로 본다)
gm_add_src() { gm_gp "$1"; GM_SRC=$GM_SRC$GM_P$'\n'; }  # mv·git mv 의 원본(삭제)
gm_add_del() { gm_gp "$1"; GM_DEL=$GM_DEL$GM_P$'\n'; }  # rm·git rm 의 대상(삭제)

gm_w_tee() {  # tee [옵션] 파일… — 출력 파일
  local i=1 n=${#GM_ARGS[@]} w end=0
  while [ "$i" -lt "$n" ]; do
    w=${GM_ARGS[$i]}; i=$((i + 1))
    if [ "$end" -eq 0 ]; then case $w in --) end=1; continue ;; -?*) continue ;; esac; fi
    gm_add_wt "$w"
  done
}
gm_w_del() {  # <시작 위치> — rm·git rm 의 위치 인수
  local i=$1 n=${#GM_ARGS[@]} w end=0
  while [ "$i" -lt "$n" ]; do
    w=${GM_ARGS[$i]}; i=$((i + 1))
    if [ "$end" -eq 0 ]; then case $w in --) end=1; continue ;; -?*) continue ;; esac; fi
    gm_add_del "$w"
  done
}
gm_w_copy() {  # <cp|mv|install|rsync|scp> <시작 위치> — 옵션·값을 건너뛰고 목적지(마지막 위치 인수 또는 -t DIR)를 쓴다(F20).
  # cp·mv·install: 모르는 옵션이 있거나 목적지가 없으면 GM_FB=1(옛 규칙; R7). 원격 목적지(host:path)는 GM_WTR(R3)
  local h=$1 i=$2 n=${#GM_ARGS[@]} w bools="" vals="" longs="" tdir="" dest dir=0 both=0 end=0 pos=() s j=0 rem=0 rp="" v
  case $h in
    cp) bools=abcdfHilLnNpPrRsTuvxXZ; vals=St; longs=$GM_CP_LONG ;;
    mv) bools=bfhinTuvZ; vals=St; longs=$GM_MV_LONG ;;
    install) bools=bcCdDpsTUvZ; vals=BfghlMmoSt; longs=$GM_IN_LONG ;;   # -D·-T 는 GNU 처럼 불리언(BSD 에서는 값), -S 는 값(R7)
    rsync) vals='efTBM@' ;;
    scp) vals=cFiJloPSDX ;;
  esac
  while [ "$i" -lt "$n" ]; do
    w=${GM_ARGS[$i]}; i=$((i + 1))
    if [ "$end" -eq 0 ]; then
      case $w in
        --) end=1; continue ;;
        --?*)
          case $h in
            rsync) case " $GM_RSYNC_VALS " in *" ${w%%=*} "*) case $w in *=*) ;; *) i=$((i + 1)) ;; esac ;; esac; continue ;;
            scp) continue ;;
          esac
          gm_long "$w" "$longs" || { GM_FB=1; GM_FBK=$h; return 0; }
          v=$GM_LV
          if [ "$GM_LK" = r ] && [ "$GM_LA" -eq 0 ]; then v=${GM_ARGS[$i]:-}; i=$((i + 1)); fi
          case $GM_LN in
            target-directory) tdir=$v ;;
            directory) [ "$h" = install ] && return 0 ;;   # install -d 는 디렉터리만 만든다
          esac
          continue ;;
        -?*)
          case $h in
            rsync|scp) gm_short "${w#-}" "" "$vals" 0 ;;
            *) gm_short "${w#-}" "$bools" "$vals" 1 || { GM_FB=1; GM_FBK=$h; return 0; } ;;
          esac
          [ "$h" = install ] && case $GM_SB in *d*) return 0 ;; esac
          if [ -n "$GM_SV" ]; then
            if [ -n "$GM_SA" ]; then v=$GM_SA; else v=${GM_ARGS[$i]:-}; i=$((i + 1)); fi
            [ "$GM_SV" = t ] && case $h in cp|mv|install) tdir=$v ;; esac   # -t·-vt·-ft DIR(rsync 의 -t 는 --times)
          fi
          continue ;;
      esac
    fi
    pos[${#pos[@]}]=$w
  done
  n=${#pos[@]}
  if [ -n "$tdir" ]; then dest=$tdir; dir=1
  else
    if [ "$n" -lt 2 ]; then case $h in cp|mv|install) GM_FB=1; GM_FBK=$h ;; esac; return 0; fi   # 목적지가 없다 — 옵션 값을 잘못 읽었을 수 있다
    n=$((n - 1)); dest=${pos[$n]}
  fi
  case $h in
    rsync|scp)
      case $dest in
        rsync://*|scp://*) rem=1; rp=${dest#*://}; case $rp in */*) rp=/${rp#*/} ;; *) rp="" ;; esac ;;
        *:*) case ${dest%%:*} in */*) ;; *) rem=1; rp=${dest#*:}; rp=${rp#:} ;; esac ;;   # host:path·host::module/path
      esac ;;
  esac
  if [ "$dir" -eq 0 ]; then
    case $dest in */) dir=1 ;; esac
    if [ "$rem" -eq 1 ]; then
      { [ -z "$rp" ] || gm_is_migration_dir "$rp"; } && dir=1
    else
      gm_gp "$dest"; gm_is_migration_dir "$GM_P" && dir=1
      [ "$dir" -eq 0 ] && gm_isdir "$GM_P" && dir=1
    fi
    [ "$dir" -eq 0 ] && [ "$n" -ge 2 ] && { dir=1; both=1; }   # 원본이 여럿이면 디렉터리여야 한다 — 옵션을 잘못 읽었을 때를 위해 목적지 자체도 본다
  fi
  if [ "$rem" -eq 0 ]; then gm_gp "$dest"; dest=$GM_P; fi
  if [ "$dir" -eq 0 ] || [ "$both" -eq 1 ]; then
    if [ "$rem" -eq 1 ]; then gm_add_wtr "$rp"; else GM_WT=$GM_WT$dest$'\n'; fi
  fi
  while [ "$j" -lt "$n" ]; do
    s=${pos[$j]}; j=$((j + 1))
    [ "$h" = mv ] && gm_add_src "$s"
    [ "$dir" -eq 1 ] || continue
    case $s in */) continue ;; esac   # 끝이 / 인 원본은 내용 복사 — 쓰는 파일을 알 수 없다
    s=${s##*/}; s=${s##*:}            # 원본의 파일 이름(host:path 원본 포함)
    [ -n "$s" ] || continue
    if [ "$rem" -eq 1 ]; then gm_add_wtr "${rp:+${rp%/}/}$s"; else GM_WT=$GM_WT${dest%/}/$s$'\n'; fi
  done
}
gm_w_checkout() {  # git checkout [<커밋>] [--] <경로>… — 작업 트리 파일을 덮어쓴다(R4). -- 가 없으면 위치 인수 모두를 경로 후보로
  local i=$1 n=${#GM_ARGS[@]} w end=0 pos=() j=0
  while [ "$i" -lt "$n" ]; do
    w=${GM_ARGS[$i]}; i=$((i + 1))
    if [ "$end" -eq 0 ]; then
      case $w in
        --) end=1; j=${#pos[@]}; continue ;;   # -- 앞의 위치 인수는 커밋
        -b|-B|--orphan) i=$((i + 1)); continue ;;
        -?*) continue ;;
      esac
    fi
    pos[${#pos[@]}]=$w
  done
  while [ "$j" -lt "${#pos[@]}" ]; do gm_add_wtd "${pos[$j]}"; j=$((j + 1)); done
}
gm_w_restore() {  # git restore [-s <커밋>] [-S] [-W] <경로>… — --staged 만이면 인덱스만 바뀐다(R4)
  local i=$1 n=${#GM_ARGS[@]} w end=0 st=0 wt=0 pos=() j=0 o
  while [ "$i" -lt "$n" ]; do
    w=${GM_ARGS[$i]}; i=$((i + 1))
    if [ "$end" -eq 0 ]; then
      case $w in
        --) end=1; continue ;;
        -s) i=$((i + 1)); continue ;;
        --?*) o=${w#--}; o=${o%%=*}   # S4: git 은 하나로 정해지는 줄임도 받는다(--wor·--sta·--so). --s 는 --source·--staged 사이에서 모호해 git 이 거부한다
              case worktree in "$o"*) wt=1 ;; esac
              case $o in
                ?) ;;
                *) case staged in "$o"*) st=1 ;; esac
                   case source in "$o"*) case $w in *=*) ;; *) i=$((i + 1)) ;; esac ;; esac ;;
              esac
              continue ;;
        -?*) gm_short "${w#-}" "" s 0
             case $GM_SB in *S*) st=1 ;; esac
             case $GM_SB in *W*) wt=1 ;; esac
             [ "$GM_SV" = s ] && [ -z "$GM_SA" ] && i=$((i + 1))
             continue ;;
      esac
    fi
    pos[${#pos[@]}]=$w
  done
  [ "$st" -eq 1 ] && [ "$wt" -eq 0 ] && return 0
  while [ "$j" -lt "${#pos[@]}" ]; do gm_add_wtd "${pos[$j]}"; j=$((j + 1)); done
}
gm_w_git() {  # git [전역 옵션] <mv|rm|checkout|restore> … — -C 디렉터리는 상대 경로 앞에 붙인다
  local i=1 n=${#GM_ARGS[@]} w c="" wt="" cw="" wu=$GM_GWT g0 v
  while [ "$i" -lt "$n" ]; do
    w=${GM_ARGS[$i]}; i=$((i + 1))
    case $w in
      -C) w=${GM_ARGS[$i]:-}; i=$((i + 1)) ;;
      -C?*) w=${w#-C} ;;
      --work-tree) wt=${GM_ARGS[$i]:-}; i=$((i + 1)); continue ;;
      --work-tree=*) wt=${w#*=}; continue ;;
      -c|--config-env) v=${GM_ARGS[$i]:-}; i=$((i + 1))   # -c core.worktree=/DIR 는 --work-tree 와 같다. 상대 값(.git 기준)·--config-env 는 위치를 모른다
        case $v in [Cc][Oo][Rr][Ee].[Ww][Oo][Rr][Kk][Tt][Rr][Ee][Ee]=*) v=${v#*=}; case $w:$v in -c:/*) cw=$v ;; *) wu=1 ;; esac ;; esac
        continue ;;
      --config-env=*) case ${w#*=} in [Cc][Oo][Rr][Ee].[Ww][Oo][Rr][Kk][Tt][Rr][Ee][Ee]=*) wu=1 ;; esac; continue ;;
      --git-dir|--namespace|--exec-path|--attr-source|--super-prefix) i=$((i + 1)); continue ;;
      -*) continue ;;
      *) c=$w; break ;;
    esac
    case $w in /*|'~'*) GM_GC=$w ;; *) GM_GC=${GM_GC:+$GM_GC/}$w ;; esac
  done
  GM_GWU=$wu; gm_w_gitsub "$c" "$i"; GM_GWU=0   # 작업 트리를 모르면 쓰는 경로는 이미 있는 파일로도 본다(GM_WTR)
  # S4: --work-tree·core.worktree 는 마지막 -C 디렉터리 기준이고, cwd 가 작업 트리 밖이면 경로는 작업 트리 루트 기준이다 — cwd 기준(위)과 둘 다 본다
  g0=$GM_GC
  for v in "$wt" "$cw"; do
    [ -n "$v" ] || continue
    case $v in /*|'~'*) GM_GC=$v ;; *) GM_GC=${g0:+$g0/}$v ;; esac
    gm_w_gitsub "$c" "$i"
  done
}
gm_w_gitsub() {  # <하위 명령> <시작 위치>
  case $1 in
    mv) gm_w_copy mv "$2" ;;
    rm) gm_w_del "$2" ;;
    checkout) gm_w_checkout "$2" ;;
    restore) gm_w_restore "$2" ;;
  esac
}
gm_w_sed() {  # sed|gsed -i·-I·--in-place: 스크립트를 뺀 위치 인수가 제자리에서 바뀐다(R4)
  local i=1 n=${#GM_ARGS[@]} w inpl=0 scr=0 end=0 pos=() j=0 o
  while [ "$i" -lt "$n" ]; do
    w=${GM_ARGS[$i]}; i=$((i + 1))
    if [ "$end" -eq 0 ]; then
      case $w in
        --) end=1; continue ;;
        --?*) o=${w#--}; o=${o%%=*}   # GNU 는 하나로 정해지는 줄임도 받는다(--in·--e=·--fi)
              [ -n "$o" ] || continue
              case in-place in "$o"*) inpl=1; continue ;; esac
              case expression in "$o"*) scr=1; case $w in *=*) ;; *) i=$((i + 1)) ;; esac; continue ;; esac
              case file in "$o"*) scr=1; case $w in *=*) ;; *) i=$((i + 1)) ;; esac; continue ;; esac
              case line-length in "$o"*) case $w in *=*) ;; *) i=$((i + 1)) ;; esac ;; esac
              continue ;;
        -?*) gm_short "${w#-}" "" iIefl 0
             case $GM_SV in
               i|I) inpl=1   # -i[접미사]. BSD 의 -i '' ·-i .bak 은 다음 단어가 접미사
                    [ -z "$GM_SA" ] && [ "$i" -lt "$n" ] && case ${GM_ARGS[$i]} in ''|.*) i=$((i + 1)) ;; esac ;;
               e|f) scr=1; [ -z "$GM_SA" ] && i=$((i + 1)) ;;
               l) [ -z "$GM_SA" ] && i=$((i + 1)) ;;
             esac
             continue ;;
      esac
    fi
    pos[${#pos[@]}]=$w
  done
  [ "$inpl" -eq 1 ] || return 0
  [ "$scr" -eq 1 ] || j=1   # -e·-f 가 없으면 첫 위치 인수는 스크립트
  while [ "$j" -lt "${#pos[@]}" ]; do gm_add_wt "${pos[$j]}"; j=$((j + 1)); done
}
gm_w_inplace() {  # perl·ruby -i: 프로그램(-e 코드 또는 첫 위치 인수)을 뺀 위치 인수가 제자리에서 바뀐다(R4)
  local h=${GM_ARGS[0]} i=1 n=${#GM_ARGS[@]} w inpl=0 code=0 end=0 pos=() j=0 vals nxt s c sv sa
  case $h in
    perl) vals=eEIiCdDFmMVx; nxt=eEI ;;   # 값 글자: 뒤에 붙은 글자가 값이다(nxt 는 비어 있으면 다음 단어가 값). -0·-l 은 아래에서 숫자만
    *) vals=eEICriFKxWT; nxt=eEICr ;;
  esac
  while [ "$i" -lt "$n" ]; do
    w=${GM_ARGS[$i]}; i=$((i + 1))
    if [ "$end" -eq 0 ]; then
      case $w in
        --) end=1; continue ;;
        --*) continue ;;
        -?*) s=${w#-}; sv=""; sa=""
             if [ "${#s}" -gt 64 ]; then   # 아주 긴 묶음은 글자마다 돌지 않고 보수적으로 본다(i 가 있으면 제자리 수정, e·E 가 있으면 위치 인수는 모두 파일)
               case $s in *i*) inpl=1 ;; esac; case $s in *[eE]*) code=1 ;; esac
               continue
             fi
             while [ -n "$s" ]; do   # -0[8진수]·perl -l[8진수] 는 숫자만 값이고 묶음의 나머지는 스위치다(-0pi·-lpi·-pli·-00pi)
               c=${s:0:1}; s=${s:1}
               case $c in
                 0) while case $s in [0-7]*) true ;; *) false ;; esac; do s=${s:1}; done; continue ;;
                 l) if [ "$h" = perl ]; then while case $s in [0-7]*) true ;; *) false ;; esac; do s=${s:1}; done; fi; continue ;;
               esac
               case $vals in *"$c"*) sv=$c; sa=$s; break ;; esac
             done
             case $sv in i) inpl=1 ;; e) code=1 ;; E) [ "$h" = perl ] && code=1 ;; esac
             [ -n "$sv" ] && [ -z "$sa" ] && case $nxt in *"$sv"*) i=$((i + 1)) ;; esac
             continue ;;
      esac
    fi
    pos[${#pos[@]}]=$w
  done
  [ "$inpl" -eq 1 ] || return 0
  [ "$code" -eq 1 ] || j=1   # -e 가 없으면 첫 위치 인수는 프로그램 파일
  while [ "$j" -lt "${#pos[@]}" ]; do gm_add_wt "${pos[$j]}"; j=$((j + 1)); done
}
gm_w_dd() {  # dd of=<경로>
  local i=1 n=${#GM_ARGS[@]} w
  while [ "$i" -lt "$n" ]; do w=${GM_ARGS[$i]}; i=$((i + 1)); case $w in of=*) gm_add_wt "${w#of=}" ;; esac; done
}
gm_w_curl() {  # curl -o/--output <경로>(--output-dir 기준; -sSo 같은 묶음 포함)
  local i=1 n=${#GM_ARGS[@]} w v od="" outs="" t
  while [ "$i" -lt "$n" ]; do
    w=${GM_ARGS[$i]}; i=$((i + 1)); v=""
    case $w in
      --output) v=${GM_ARGS[$i]:-}; i=$((i + 1)) ;;
      --output=*) v=${w#*=} ;;
      --output-dir) od=${GM_ARGS[$i]:-}; i=$((i + 1)); continue ;;
      --output-dir=*) od=${w#*=}; continue ;;
      --*|-) continue ;;
      -?*) gm_short "${w#-}" "" AbcCdDeEFHKmoPQrtTuUwxXyYz 0
           [ -n "$GM_SV" ] || continue
           if [ -n "$GM_SA" ]; then v=$GM_SA; else v=${GM_ARGS[$i]:-}; i=$((i + 1)); fi
           [ "$GM_SV" = o ] || continue ;;
      *) continue ;;
    esac
    case $v in ''|-) continue ;; esac
    outs=$outs$v$'\n'
  done
  while [ -n "$outs" ]; do
    t=${outs%%$'\n'*}; outs=${outs#*$'\n'}
    case $t in /*|'~'*) ;; *) [ -n "$od" ] && t=${od%/}/$t ;; esac
    gm_add_wt "$t"
  done
}
gm_w_wget() {  # wget -O/--output-document <경로>(-qO 같은 묶음 포함; - 는 표준 출력)
  local i=1 n=${#GM_ARGS[@]} w v
  while [ "$i" -lt "$n" ]; do
    w=${GM_ARGS[$i]}; i=$((i + 1)); v=""
    case $w in
      --output-document) v=${GM_ARGS[$i]:-}; i=$((i + 1)) ;;
      --output-document=*) v=${w#*=} ;;
      --*|-) continue ;;
      -?*) gm_short "${w#-}" "" aABDeiIloOPQRtTUwX 0
           [ -n "$GM_SV" ] || continue
           if [ -n "$GM_SA" ]; then v=$GM_SA; else v=${GM_ARGS[$i]:-}; i=$((i + 1)); fi
           [ "$GM_SV" = O ] || continue ;;
      *) continue ;;
    esac
    case $v in ''|-) continue ;; esac
    gm_add_wt "$v"
  done
}
gm_w_truncate() {  # truncate [-c] [-o] (-s 크기 | -r 참조 파일) 파일…
  local i=1 n=${#GM_ARGS[@]} w end=0
  while [ "$i" -lt "$n" ]; do
    w=${GM_ARGS[$i]}; i=$((i + 1))
    if [ "$end" -eq 0 ]; then
      case $w in
        --) end=1; continue ;;
        --size|--reference) i=$((i + 1)); continue ;;
        --*) continue ;;
        -?*) gm_short "${w#-}" "" sr 0; [ -n "$GM_SV" ] && [ -z "$GM_SA" ] && i=$((i + 1)); continue ;;
      esac
    fi
    gm_add_wt "$w"
  done
}
gm_w_patch() {  # patch [옵션] [원본 [패치 파일]] — 원본과 -o 출력 파일을 쓴다(-d 디렉터리 기준). --dry-run·BSD -C 는 쓰지 않는다
  local i=1 n=${#GM_ARGS[@]} w end=0 pos=() d="" o="" v
  while [ "$i" -lt "$n" ]; do
    w=${GM_ARGS[$i]}; i=$((i + 1))
    if [ "$end" -eq 0 ]; then
      case $w in
        --) end=1; continue ;;
        --dry-run|--check) return 0 ;;
        --output=*) o=${w#*=}; continue ;;
        --output) o=${GM_ARGS[$i]:-}; i=$((i + 1)); continue ;;
        --directory=*) d=${w#*=}; continue ;;
        --directory) d=${GM_ARGS[$i]:-}; i=$((i + 1)); continue ;;
        --input|--strip|--fuzz|--reject-file|--prefix|--basename-prefix|--version-control|--suffix|--ifdef|--get|--quoting-style|--read-only) i=$((i + 1)); continue ;;
        --*) continue ;;
        -?*) gm_short "${w#-}" "" pioDdFrBVzYgx 0
             case $GM_SB in *C*) return 0 ;; esac
             [ -n "$GM_SV" ] || continue
             if [ -n "$GM_SA" ]; then v=$GM_SA; else v=${GM_ARGS[$i]:-}; i=$((i + 1)); fi
             case $GM_SV in o) o=$v ;; d) d=$v ;; esac
             continue ;;
      esac
    fi
    pos[${#pos[@]}]=$w
  done
  if [ -n "${pos[0]:-}" ]; then v=${pos[0]}; case $v in /*|'~'*) ;; *) [ -n "$d" ] && v=${d%/}/$v ;; esac; gm_add_wt "$v"; fi
  if [ -n "$o" ] && [ "$o" != - ]; then case $o in /*|'~'*) ;; *) [ -n "$d" ] && o=${d%/}/$o ;; esac; gm_add_wt "$o"; fi
}
gm_w_ccp() {  # docker|podman|nerdctl [container] cp, kubectl|oc cp — 컨테이너 쪽 목적지(이름:경로)는 이미 있는 파일로(R3)
  local h=${GM_ARGS[0]} i=1 n=${#GM_ARGS[@]} w vals sub="" pos=() dest s j=0 dir=0 rp
  case $h in
    kubectl|oc) vals=' -n --namespace --context --kubeconfig --cluster --user -s --server --token --as --as-group --request-timeout -v --certificate-authority --client-certificate --client-key -c --container --retries ' ;;
    *) vals=' --context -c -H --host -l --log-level --config -f --file -p --project-name --profile --env-file --project-directory --ansi --progress --parallel --index ' ;;   # docker 전역·compose 전역·compose cp 의 값 옵션
  esac
  while [ "$i" -lt "$n" ]; do
    w=${GM_ARGS[$i]}; i=$((i + 1))
    case $w in -?*) case $vals in *" $w "*) i=$((i + 1)) ;; esac; continue ;; esac
    if [ -z "$sub" ]; then
      case $w in container|compose) continue ;; esac   # docker container cp·docker compose cp(S4)
      [ "$w" = cp ] || return 0
      sub=cp; continue
    fi
    pos[${#pos[@]}]=$w
  done
  n=${#pos[@]}; [ "$n" -ge 2 ] || return 0
  n=$((n - 1)); dest=${pos[$n]}
  case $dest in
    *:*) rp=${dest#*:}
         case $rp in */) dir=1 ;; esac
         gm_is_migration_dir "$rp" && dir=1
         [ "$dir" -eq 1 ] || { gm_add_wtr "$rp"; return 0; } ;;
    *) case $dest in */) dir=1 ;; esac
       gm_is_migration_dir "$dest" && dir=1
       [ "$dir" -eq 0 ] && gm_isdir "$dest" && dir=1
       [ "$dir" -eq 1 ] || { gm_add_wt "$dest"; return 0; } ;;
  esac
  while [ "$j" -lt "$n" ]; do
    s=${pos[$j]}; j=$((j + 1)); s=${s##*/}; s=${s##*:}
    case $s in ''|-) continue ;; esac
    case $dest in *:*) gm_add_wtr "${rp%/}/$s" ;; *) gm_add_wt "${dest%/}/$s" ;; esac
  done
}
gm_ctr_inner() {  # docker|podman|nerdctl [container|compose] exec|run, docker-compose|podman-compose exec|run → GM_IX: 안쪽 명령 첫 단어의 위치(없으면 0)
  local h=${GM_ARGS[0]:-} i=1 n=${#GM_ARGS[@]} w sub="" comp=0
  GM_IX=0; GM_EP=""
  case $h in docker-compose|podman-compose) comp=1 ;; docker|podman|nerdctl) ;; *) return 0 ;; esac
  while [ "$i" -lt "$n" ]; do
    w=${GM_ARGS[$i]}; i=$((i + 1))
    case $w in
      --entrypoint=*) GM_EP=${w#*=}; continue ;;   # --entrypoint X 는 안쪽 명령의 머리다(이미지 뒤의 단어는 X 의 인수)
      --entrypoint) GM_EP=${GM_ARGS[$i]:-}; i=$((i + 1)); continue ;;
      --*=*) continue ;;
      -*) case $GM_CTR_VALS in *" $w "*) i=$((i + 1)) ;; esac; continue ;;
    esac
    if [ -z "$sub" ]; then
      case $w in compose) [ "$comp" -eq 0 ] && { comp=1; continue; } ;; container) continue ;; esac
      sub=$w; case $sub in exec|run) ;; *) return 0 ;; esac
      continue
    fi
    [ "$i" -lt "$n" ] && GM_IX=$i   # w 는 컨테이너·서비스·이미지 이름
    return 0
  done
}
gm_w_ctr() {  # 컨테이너 명령: cp 목적지(gm_w_ccp)와, 공용 파서가 벗기지 않는 exec·run 의 안쪽 명령(podman exec·docker-compose exec·docker run 등)
  local j=1 n w
  gm_w_ccp
  gm_ctr_inner
  [ "$GM_IX" -gt 0 ] || return 0
  GM_ARGS=("${GM_ARGS[@]:$GM_IX}")
  [ -n "$GM_EP" ] && GM_ARGS=("$GM_EP" "${GM_ARGS[@]}")   # --entrypoint sh img -c '…'
  GM_ARGS[0]=${GM_ARGS[0]##*/}   # 컨테이너 안의 /bin/sh·/usr/bin/tee 처럼 경로로 쓴 명령도 이름으로 본다
  case ${GM_ARGS[0]:-} in
    sh|bash|zsh|dash|ash|ksh|mksh) ;;
    env|nice|nohup|timeout|stdbuf|setsid|ionice|chrt|taskset|busybox|sudo|doas|exec|command|time|tini|dumb-init|gosu|su-exec)
      n=${#GM_ARGS[@]}   # env sh -c '…' 처럼 래퍼 뒤의 셸: 처음 나오는 셸 단어부터 본다(공용 파서의 shc 와 같은 방식). 셸이 없으면 그대로
      while [ "$j" -lt "$n" ]; do case ${GM_ARGS[$j]##*/} in sh|bash|zsh|dash|ash|ksh|mksh) break ;; esac; j=$((j + 1)); done
      [ "$j" -lt "$n" ] || { gm_cmd_writes; return 0; }
      j=$((j + 1)) ;;
    *) gm_cmd_writes; return 0 ;;
  esac
  n=${#GM_ARGS[@]}   # sh -c '…' 의 문자열은 이 세그먼트가 끝난 뒤 sub 줄처럼 다시 파싱한다(gm_run)
  while [ "$j" -lt "$n" ]; do   # S4: 공용 파서처럼 글자만으로 된 -…c… 묶음을 찾는다(--norc·--rcfile 값은 건너뛴다)
    w=${GM_ARGS[$j]}; j=$((j + 1))
    case $w in --*|-) continue ;; -*c*) ;; *) continue ;; esac
    case ${w#-} in *[![:alpha:]]*) continue ;; esac
    [ "$j" -lt "$n" ] && GM_INNER=${GM_ARGS[$j]}; return 0
  done
}
gm_cmd_writes() {  # GM_ARGS → 명령이 쓰는 경로(GM_WT·GM_WTD·GM_WTR)와 지우는 경로(GM_SRC·GM_DEL). 나머지 명령은 인수를 읽기만 한다고 본다(F7)
  GM_GC=""
  case ${GM_ARGS[0]:-} in
    tee) gm_w_tee ;;
    cp|gcp) gm_w_copy cp 1 ;;
    mv|gmv) gm_w_copy mv 1 ;;
    install|ginstall) gm_w_copy install 1 ;;
    rsync) gm_w_copy rsync 1 ;;
    scp) gm_w_copy scp 1 ;;
    rm|grm|rimraf) gm_w_del 1 ;;
    git) gm_w_git ;;
    sed|gsed) gm_w_sed ;;
    perl|ruby) gm_w_inplace ;;
    dd|gdd) gm_w_dd ;;
    curl) gm_w_curl ;;
    wget) gm_w_wget ;;
    truncate|gtruncate) gm_w_truncate ;;
    patch|gpatch) gm_w_patch ;;
    docker|podman|nerdctl|docker-compose|podman-compose) gm_w_ctr ;;
    kubectl|oc) gm_w_ccp ;;   # kubectl exec 는 공용 파서가 안쪽 명령을 따로 낸다
    -*c*) case ${GM_ARGS[0]#-} in *[![:alpha:]]*) ;; *) GM_INNER=${GM_ARGS[1]:-} ;; esac ;;   # 명령 이름이 -c 묶음이면 다음 단어가 셸 문자열
  esac
}
gm_classify() {  # <쓰는 경로> — 마이그레이션이면 이미 있으면 수정(edit), 없으면 생성(new). gm_segment 의 지역변수를 바꾼다
  case $1 in ''|-) return 0 ;; esac   # /dev/null 은 아래 gm_mig 에서 걸러진다(/dev/../… 로 빠져나오는 경로를 건너뛰지 않도록 /dev/* 예외는 두지 않는다)
  gm_mig "$1" 0 || return 0
  if gm_exists "$1"; then edit=1; GM_FILE=$1; else new=1; GM_NEW_FILE=$1; fi
}
gm_writes() {  # <masked> <raw> <cd 세그먼트=1> — 쓰는 경로는 수정(edit)·생성(new)으로, 지우는 경로는 삭제(delete)로 분류(F7·F20·B407·R4)
  local t rest rc
  GM_WT=""; GM_WTD=""; GM_WTR=""; GM_SRC=""; GM_DEL=""; GM_FB=0; GM_FBK=""; GM_WOK=0
  gm_words "$1" "$2"; rc=$?
  if [ "$rc" -eq 2 ]; then   # awk 상한을 넘었다 — 이 세그먼트를 이미 있는 마이그레이션 수정·삭제로 본다(cd 세그먼트는 리디렉션이 있을 때만)
    [ "$3" -eq 1 ] && case $1 in *'>'*) ;; *) return 0 ;; esac
    case $GM_HEAD in   # 컨테이너 줄은 cp 이거나 줄에 이름·어휘가 있을 때만 — 안쪽 셸 문자열은 공용 파서의 sub 줄로도 보고, 컨테이너 안의 상대 경로는 호스트의 기준 디렉터리와 상관없다
      docker|podman|nerdctl|docker-compose|podman-compose|kubectl|oc) gm_needv "$2" || case " $1 " in *' cp '*) ;; *) return 0 ;; esac ;;
    esac
    gm_bigx "$2" || return 0
    case $GM_HEAD in
      rm|grm|rimraf|mv|gmv) delete=1 ;;
      git) case $1 in 'git rm '*|'git mv '*) delete=1 ;; *) edit=1 ;; esac ;;
      *) edit=1 ;;
    esac
    return 0
  fi
  if [ "$rc" -ne 0 ]; then   # 단어를 맞추지 못하면 예전처럼 보수적으로: 마이그레이션 토큰이 하나라도 있으면 수정·삭제
    case $GM_HEAD in
      rm|grm|rimraf|mv|gmv) gm_file_tokens "$2" 1 && delete=1 ;;
      git) case $1 in 'git rm '*|'git mv '*) gm_file_tokens "$2" 1 && delete=1 ;; *) gm_file_tokens "$2" && edit=1 ;; esac ;;
      *) gm_file_tokens "$2" && edit=1 ;;
    esac
    return 0
  fi
  GM_WOK=1
  [ "$3" -eq 1 ] || gm_cmd_writes   # cd 세그먼트는 리디렉션만 본다
  if [ "$GM_FB" -eq 1 ]; then       # R7: cp·mv·install 의 모르는 옵션 → 옛 규칙(마이그레이션 토큰이 있으면 수정, mv 는 삭제)
    if [ "$GM_FBK" = mv ]; then gm_file_tokens "$2" 1 && delete=1; else gm_file_tokens "$2" && edit=1; fi
  fi
  gm_split "$GM_WT"   # 줄 목록은 배열로 한 번에 나눈다(${rest#*$'\n'} 를 되풀이하면 UTF-8 로케일에서 줄 수에 비례해 2차 비용 — 대상 수천 개면 10초)
  for t in "${GM_L[@]}"; do gm_classify "$t"; done
  gm_split "$GM_WTD"   # git checkout·restore: 마이그레이션 디렉터리를 주면 그 안의 파일을 덮어쓴다
  for t in "${GM_L[@]}"; do
    if gm_mig "$t" 0; then gm_classify "$t"; elif gm_mig "$t" 1; then edit=1; GM_FILE=$t; fi
  done
  gm_split "$GM_WTR"   # R3: 원격·컨테이너 쪽 경로는 이미 있는 파일로 본다
  for t in "${GM_L[@]}"; do gm_is_migration "$t" && { edit=1; GM_FILE=$t; }; done
  gm_split "$GM_SRC$GM_DEL"
  for t in "${GM_L[@]}"; do gm_mig "$t" 1 && { delete=1; GM_FILE=$t; }; done
  return 0
}
gm_segment() {  # <masked> <raw> <kind>
  local m=$1 r=$2 kind=${3:-cmd} create=0 apply=0 delete=0 edit=0 destructive=0 new=0 w=0 ex iscd=0 after=0 pv=""
  gm_head "$m"
  case $GM_HEAD in
    cd|pushd|popd|chdir) w=1; case $kind in *xargs*|*sudo*) ;; *) iscd=1 ;; esac ;;   # xargs·sudo 의 cd 는 셸 cwd 를 바꾸지 못한다(리디렉션은 바깥 셸이 연다)
    eval) GM_PEND=1 ;;   # R2: eval 은 현재 셸에서 돈다 — 안쪽 명령(sub 줄)을 본 뒤 cwd 를 모르는 상태로
    source|.|z|zi|zoxide|__zoxide_z|__zoxide_zi|j|jc|jo|autojump|fasd_cd) after=1 ;;   # 따라갈 수 없는 cwd 변경
    function) GM_FUNC=1 ;;
    '$'*)   # S2: $c app·$(echo cd) app·${CD:-cd} app — 명령 단어가 치환이면 cwd 를 바꿀 수 있다. 마지막 } 뒤에 / 가 있으면
      # ($VIRTUAL_ENV/bin/python·${X}/bin/python·$(…)/knex) 펼친 단어에 / 가 남아 경로로 실행하는 외부 명령이다 — 셸 cwd 를 바꾸지 못한다
      case ${GM_HEAD##*"$GM_RB_"} in */*) ;; *) case $kind in *xargs*|*sudo*) ;; *) after=1 ;; esac ;; esac ;;
    '{'*,*'}'*|'{'*..*'}'*) case $kind in *xargs*|*sudo*) ;; *) after=1 ;; esac ;;   # {cd,} app — 중괄호 펼침으로 만든 명령 단어도 cwd 를 바꿀 수 있다
    rm|grm|rimraf|git|tee|cp|gcp|mv|gmv|install|ginstall|rsync|scp|sed|gsed|perl|ruby|dd|gdd|curl|wget|truncate|gtruncate|patch|gpatch|docker|podman|nerdctl|docker-compose|podman-compose|kubectl|oc) w=1 ;;
    -*c*) case ${GM_HEAD#-} in *[![:alpha:]]*) ;; *) w=1 ;; esac ;;   # 셸이 떨어져 나간 -c '…'(docker compose run --entrypoint sh svc -c '…' 를 공용 파서가 벗긴 꼴)
  esac
  case $m in *'>'*) w=1 ;; esac
  [ "$w" -eq 1 ] && [ "$iscd" -eq 0 ] && ! gm_need "$r" && w=0   # 이름·어휘가 없고 이름이 든 기준 디렉터리도 없으면 쓰기는 마이그레이션일 수 없다(awk 를 부르지 않는다)
  if [ "$w" -eq 1 ] && [ "$GM_FK" -ge "$GM_FKMAX" ]; then   # awk 상한에 닿은 뒤의 컨테이너 줄: cp·이름·어휘가 없으면 볼 것이 없다(gm_writes 의 상한 갈래와 같다)
    case $GM_HEAD in docker|podman|nerdctl|docker-compose|podman-compose|kubectl|oc) gm_needv "$r" || case " $m " in *' cp '*) ;; *) w=0 ;; esac ;; esac
  fi
  [ "$w" -eq 1 ] && gm_writes "$m" "$r" "$iscd"   # cd 세그먼트의 리디렉션은 cd 전에 옛 cwd 에서 열린다(R6)
  if [ "$iscd" -eq 0 ]; then
    case $m in   # alembic·flask db·goose·dbmate·golang-migrate·flyway·liquibase·knex·artisan 은 동사로, 나머지는 아래 인접 패턴으로 판정
      *alembic*|*goose*|*dbmate*|*migrate*|*flyway*|*liquibase*|*knex*|*artisan*|*flask*) gm_tool_verb "$m" ;;
      *) GM_TOOL=""; GM_VERB=""; GM_VC="" ;;   # 도구 이름이 없으면 단어를 나누지 않는다(세그먼트가 아주 많은 명령의 고정 비용)
    esac
    [ "$GM_VC" = create ] && create=1
    case $m in
      *'manage.py makemigrations'*|*'django-admin makemigrations'*) case " $m " in *' --check'*|*' --dry-run'*) ;; *) create=1 ;; esac ;;   # B8: 검사만 하는 호출은 생성이 아님
      *'prisma migrate dev'*--create-only*|*'rails g migration'*|*'rails generate migration'*|*'drizzle-kit generate'*|*'sqlx migrate add'*|*'atlas migrate diff'*|*'sequelize'*'migration:generate'*|*'sequelize'*'migration:create'*|*'typeorm'*'migration:generate'*|*'typeorm'*'migration:create'*|*'supabase migration new'*) create=1 ;;
    esac
    if [ "$create" -eq 0 ]; then
      case $m in
        *'manage.py migrate'*|*'django-admin migrate'*) case " $m " in *' --check'*|*' --plan'*|*' --list'*|*' -l '*|*' zero '*|*' zero') ;; *) apply=1 ;; esac ;;
        *'prisma migrate dev'*|*'prisma migrate deploy'*|*'prisma db push'*|*'rails db:migrate'*|*'rake db:migrate'*|*'drizzle-kit push'*|*'drizzle-kit migrate'*|*'sqlx migrate run'*|*'atlas migrate apply'*|*'sequelize'*'db:migrate'*|*'typeorm'*'migration:run'*|*'mikro-orm migration:up'*|*'supabase db push'*|*'supabase migration up'*) apply=1 ;;
      esac
      [ "$GM_VC" = apply ] && apply=1
      case $m in *':status'*|*'migrate:fresh'*|*'migrate:reset'*|*'migrate:rollback'*|*'migrate:refresh'*|*'db:migrate:undo'*|*'db:migrate:reset'*|*'db:migrate:down'*) apply=0 ;; esac   # G16: status 는 읽기 전용
      case $GM_HEAD in npm|yarn|pnpm|bun|make|just) gm_runner_target "$m" && apply=1 ;; esac
      case $m in *migrat*|*alembic*|*prisma*|*'db:'*|*knex*|*drizzle*|*flyway*|*goose*|*dbmate*|*sqlx*|*atlas*|*rails*|*rake*|*sequelize*|*typeorm*|*supabase*|*liquibase*|*artisan*|*mikro-orm*|*'flask db'*)
        case $m in *downgrade*|*rollback*|*' reset'*|*--force-reset*|*'db:drop'*|*'db:reset'*|*' clean'*|*'migrate:fresh'*|*'db:wipe'*|*'migrate:undo'*|*'migration:revert'*|*'database drop'*|*'migrate revert'*|*'schema clean'*|*'drizzle-kit drop'*|*'db reset'*|*'schema:drop'*|*' dropall'*|*' zero'*) apply=0; destructive=1 ;; esac ;;
      esac
      [ "$GM_VC" = destructive ] && { apply=0; destructive=1; }
      # alembic·Flask-Migrate 오프라인 모드(--sql)는 DB에 접속하지 않고 SQL 만 출력한다 → 적용·롤백이 아니다
      # S3: 다만 출력을 DB 클라이언트로 파이프하면 원래 명령의 결정이다 — 다음 파이프 단계를 본 뒤 정한다(GM_PV; gm_run)
      case $GM_TOOL:$GM_VERB in alembic:upgrade|alembic:downgrade|flask:upgrade|flask:downgrade)
        case " $m " in *' --sql '*)
          if [ "$destructive" -eq 1 ]; then pv=destructive; elif [ "$apply" -eq 1 ]; then pv=apply; fi
          apply=0; destructive=0 ;;
        esac ;;
      esac
      if [ "$GM_VC" = preview ]; then   # R10: liquibase 의 *-sql·*SQL 미리 보기. 넘기면 -sql 을 뗀 명령(rollback·drop 류는 롤백, 나머지는 적용)
        case $GM_VERB in *[Rr]ollback*|*[Dd]rop*) pv=destructive ;; *) pv=apply ;; esac
        apply=0; destructive=0
      fi
      [ -n "$pv" ] && { hook_excerpt "$m" 120; GM_PV=$pv; GM_PVX=$HOOK_EX; GM_PVNEW=1; }
    fi
  fi
  if [ "$create" -eq 1 ] || [ "$apply" -eq 1 ] || [ "$delete" -eq 1 ] || [ "$edit" -eq 1 ] || [ "$destructive" -eq 1 ] || [ "$new" -eq 1 ]; then
    hook_excerpt "$m" 120; ex=$HOOK_EX   # 발췌는 판정이 났을 때만 만든다
    [ "$GM_SUB" -eq 1 ] && { gm_hit 3 migrations:subagent "$GM_SUBAGENT_REASON: $ex"; return 0; }
  fi
  [ "$new" -eq 1 ] && GM_NEW=1   # 새 마이그레이션 파일 — 명령 어디에든 파괴적 내용이 있으면 끝에서 destructive-schema(R8)
  [ "$delete" -eq 1 ] && gm_hit 2 migrations:delete "확인 필요 [migrations:delete]: 마이그레이션 파일·디렉터리 삭제·이동 — 적용된 마이그레이션이면 되돌릴 수 없음: $GM_FILE"
  [ "$edit" -eq 1 ] && gm_hit 2 migrations:edit-existing "확인 필요 [migrations:edit-existing]: 셸로 마이그레이션 파일 수정 — 적용된 마이그레이션이면 새 마이그레이션을 만들 것: $GM_FILE"
  [ "$apply" -eq 1 ] && gm_hit 1 migrations:apply "확인 필요 [migrations:apply]: 마이그레이션 적용 — 대상 DB(로컬/운영) 확인: $ex"
  if [ "$iscd" -eq 1 ]; then if [ "$GM_WOK" -eq 1 ]; then gm_cd; else gm_cd_unknown; fi; fi
  [ "$after" -eq 1 ] && gm_cd_unknown
  return 0
}
gm_need() {  # <글자> → 0 이면 자세히 볼 세그먼트·셸 문자열: 마이그레이션 경로 이름이나 마이그레이션 명령 어휘(gm_is_migration·gm_tool_verb·
  # gm_segment 의 패턴이 쓰는 글자)가 있거나, 이름이 든 기준 디렉터리(세션 cwd·유효 cwd·cd 가 닿은 디렉터리·S1 후보)가 있어 상대 경로 쓰기가
  # 마이그레이션이 될 수 있다. 아니면 쓰기·안쪽 명령을 따져도 판정이 날 수 없으므로 건너뛴다(세그먼트마다 awk 를 부르는 비용 — 64KB 에 10초).
  # 따옴표·역슬래시를 뺀 글자로 본다(mig"rations"/x·mi\grations/x 도 셸에서는 migrations/x 다)
  gm_needv "$1" && return 0
  [ -n "$GM_KDIRS$GM_KADIRS" ] && return 0
  case $GM_CWD$'\n'$GM_EFF in *migrat*|*alembic*|*drizzle*|*flyway*|*liquibase*|*goose*|*dbmate*) return 0 ;; esac
  return 1
}
gm_needv() {  # <글자> → 0 이면 따옴표·역슬래시를 뺀 글자에 마이그레이션 경로 이름·명령 어휘가 있다(gm_need 의 앞부분)
  gm_sq "$1"
  case $GM_NS in *migrat*|*alembic*|*drizzle*|*flyway*|*liquibase*|*goose*|*dbmate*|*prisma*|*db:*|*knex*|*sqlx*|*atlas*|*rails*|*rake*|*sequelize*|*typeorm*|*supabase*|*artisan*|*mikro-orm*|*flask*|*django*) return 0 ;; esac
  return 1
}
gm_sub() {  # <raw> <masked> <깊이> — sub 줄·컨테이너 안쪽 셸 문자열을 다시 파싱한다(깊이 3까지). 안쪽 명령은 바깥 파이프 단계의 프로그램이므로
  # 바깥의 미리 보기 보류(GM_PV)를 지우거나 바꾸지 않는다(… | sh -c 'grep -v x' | psql·ssh host liquibase update-sql | psql).
  # 깊이 3 에서는 그 줄 하나만 본다(예전과 같다 — 보류도 그대로 넘긴다). awk 상한을 넘은 뒤에는 gm_subx
  local pv=$GM_PV px=$GM_PVX
  [ "$GM_DONE" -eq 0 ] || return 0   # 가장 센 결정이 났다
  [ "$3" -lt 3 ] || { gm_segment "$2" "$1" cmd; return 0; }
  [ "$1" = "$GM_SSK" ] || gm_fk || { gm_subx "$1" "$2"; return 0; }   # 지난 파싱 결과를 다시 쓰면 awk 를 부르지 않는다
  GM_PV=""
  gm_run "$1" $(($3 + 1))
  GM_PV=$pv; GM_PVX=$px; GM_PVNEW=0
}
gm_subx() {  # <raw> <masked> — awk 상한(gm_fk)을 넘은 뒤의 셸 문자열: 다시 파싱하지 않는다. 어휘도 쓰기도 없으면 판정을 낼 수 없어 넘기고,
  # 아니면 한 세그먼트로 본다(깊이 3 과 같다). 명령이 여럿·래퍼·셸이 든 문자열은 한 세그먼트로 보면 뒤 명령을 놓치므로 이름·어휘가 있거나
  # 이름이 든 기준 디렉터리가 있으면 이미 있는 마이그레이션 수정으로 본다(서브에이전트는 deny)
  local pv=$GM_PV px=$GM_PVX w
  gm_needv "$1" || gm_canwrite "$1" || return 0
  GM_PV=""; gm_segment "$2" "$1" cmd; GM_PV=$pv; GM_PVX=$px; GM_PVNEW=0
  case $1 in
    *[\;\&\|\(\)\`]*|*$'\n'*|*$'\036'*|*$'\037'*) ;;   # 0x1E·0x1F: 공용 파서가 sub 의 개행·탭을 바꾼 바이트(R4·R6) — 여러 줄 문자열도 여러 명령
    *) gm_head "$1"; w=${GM_HEAD##*/}
       case $w in
         sudo|doas|env|nohup|nice|timeout|stdbuf|command|builtin|exec|xargs|time|noglob|npx|bunx|uvx|eval|ssh|su|find|watch|flock) ;;
         sh|bash|zsh|dash|ash|ksh|mksh|setsid|ionice|chrt|taskset|unbuffer|chronic|caffeinate|runuser|chroot|unshare|script|mise) ;;
         *) return 0 ;;   # 래퍼가 없는 명령 하나는 gm_segment 로 충분하다
       esac ;;
  esac
  gm_bigx "$1" || return 0
  [ "$GM_SUB" -eq 1 ] && { gm_hit 3 migrations:subagent "$GM_SUBAGENT_REASON: $GM_FILE"; return 0; }
  gm_hit 2 migrations:edit-existing "확인 필요 [migrations:edit-existing]: 셸로 마이그레이션 파일 수정일 수 있음 — 적용된 마이그레이션이면 새 마이그레이션을 만들 것: $GM_FILE"
}
gm_bigx() {  # <글자> → 0 이면 awk 상한을 넘어 자세히 보지 못한 세그먼트·문자열을 마이그레이션 쓰기로 본다(이름·어휘가 있거나 이름이 든 기준
  # 디렉터리가 있을 때만 — gm_need). GM_FILE 에 발췌
  gm_need "$1" || return 1
  hook_excerpt "$1" 100; GM_FILE="(명령이 너무 커서 자세히 보지 못한 부분) $HOOK_EX"
  return 0
}
gm_canwrite() {  # <글자> → 0 이면 파일을 쓰거나 셸 문자열을 실행할 수 있는 낱말이 있다(대강·넉넉하게 — 리디렉션 > 이나 쓰는 명령·셸·래퍼 이름)
  local w IFS=$' \t\n\036\037'   # 0x1E·0x1F: sub 문자열의 개행·탭(R4·R6) — 다음 줄 첫 낱말도 따로 본다
  case $1 in *'>'*) return 0 ;; esac
  set -f
  for w in $1; do
    case ${w##*/} in
      rm|grm|rimraf|tee|cp|gcp|mv|gmv|install|ginstall|rsync|scp|sed|gsed|perl|ruby|dd|gdd|curl|wget|truncate|gtruncate|patch|gpatch|git) set +f; return 0 ;;
      docker|podman|nerdctl|docker-compose|podman-compose|kubectl|oc|sh|bash|zsh|dash|ash|ksh|mksh|eval|ssh|su|sudo|doas|xargs|find|env|exec|source|.|-*c*) set +f; return 0 ;;
    esac
  done
  set +f
  return 1
}
gm_sq() {  # <글자> → GM_NS: 공백류·따옴표·역슬래시를 모두 뺀 글자(공용 파서가 다시 이은 세그먼트와 원문을 견준다 — 단어 사이 공백·줄 잇기·
  # 붙여 쓴 리디렉션(--sql</dev/null)·머리 단어의 따옴표가 달라도 같다). 단어 나누기로 한 번에 지운다: ${s//…} 를 되풀이하면 bash 3.2 에서
  # 2차 이상 비용이라 몇 KB 의 heredoc 만으로 10초 제한을 넘겨 판정 없이 통과했다
  local IFS=$' \t\n\r'
  set -f; set -- $1; IFS=; GM_NS="$*"
  IFS=$'\'"\\'; set -- $GM_NS; IFS=; GM_NS="$*"; set +f
}
gm_phc() {  # <raw 세그먼트> → GM_PHC: 명령 치환 자리표시 $(…) 의 수 = 공용 파서가 그 줄 뒤에 내는 push … pop 블록 수(4096자를 넘으면 16)
  local x=$1 n=0 ph=$'(\342\200\246)'
  case $x in *"$ph"*) ;; *) GM_PHC=0; return 0 ;; esac
  [ "${#x}" -le 4096 ] || { GM_PHC=16; return 0; }
  while [ "$n" -lt 16 ]; do case $x in *"$ph"*) x=${x#*"$ph"}; n=$((n + 1)) ;; *) break ;; esac; done
  GM_PHC=$n
}
gm_piped() {  # <raw 세그먼트> → 0 이면 세그먼트의 출력이 파이프(| 또는 |&)로 다음 명령에 간다(S3). 공백·따옴표를 뺀 명령 글자에서 찾는다(gm_sq).
  # gm_run 의 지역변수 gm_rc(명령)·gm_nc(접은 명령, 처음 물을 때 만든다)·gm_nb 를 쓴다(bash 의 동적 범위; 큰 문자열을 복사·비교하지 않게).
  # 비용 상한: 한 번 실행에 64번을 넘게 묻거나 명령이 64KB 를 넘으면 찾지 않고 파이프로 본다(보수적으로 — 다음 단계가 DB 클라이언트일 때만 걸린다)
  local g p ph=$'(\342\200\246)'
  [ -n "$1" ] || return 1
  GM_NPIPE=$((GM_NPIPE + 1)); [ "$GM_NPIPE" -le 64 ] || return 0
  if [ "$gm_nb" -eq 0 ]; then
    if [ "${#gm_rc}" -gt 65536 ]; then gm_nb=2; else gm_sq "$gm_rc"; gm_nc=$GM_NS; gm_nb=1; fi
  fi
  [ "$gm_nb" -eq 1 ] || return 0
  gm_sq "$1"; g=$GM_NS
  case $g in *"$ph"*)   # 명령 치환 자리표시: 원문에는 그 안의 명령이 있다 — 마지막 자리표시 뒤 글자를 닫는 ) 나 ` 바로 뒤에서 찾는다(보수적)
    [ "${#g}" -le 4096 ] || return 0
    p=${g##*"$ph"}
    case $gm_nc in *")$p|"[!\|]*|*")$p|"|*"\`$p|"[!\|]*|*"\`$p|") return 0 ;; esac
    return 1 ;;
  esac
  case $gm_nc in *"$g"[\|\)\;\}]*) ;; *) return 1 ;; esac   # 뒤에 | ) ; } 가 없으면 바로 끝낸다(아래 패턴 열 개를 매번 훑지 않게)
  case $gm_nc in   # 한 명령짜리 묶음의 출력도 파이프로 간다: ( 미리 보기 ) | psql · { 미리 보기; } | psql · $(미리 보기) | psql
    *"$g|"[!\|]*|*"$g|"|*"$g)|"[!\|]*|*"$g)|"|*"$g;)|"[!\|]*|*"$g;)|"|*"$g;}|"[!\|]*|*"$g;}|"|*"$g}|"[!\|]*|*"$g}|") return 0 ;;
  esac
  return 1
}
gm_dbclient() {  # <masked> <raw> → 0 이면 SQL 을 표준 입력으로 받아 실행하는 DB 클라이언트 단계(컨테이너·ssh·셸 문자열 안 포함)
  local h
  gm_head "$1"; h=${GM_HEAD##*/}
  case $h in
    psql|mysql|mariadb|sqlite3|sqlcmd|clickhouse-client|sqlplus|sql|mysqlsh|duckdb|usql|pgcli|mycli|litecli|snowsql|isql|osql|db2|mssql-cli) return 0 ;;
    clickhouse) case " $1 " in *' client '*) return 0 ;; esac ;;
    cockroach) case " $1 " in *' sql '*) return 0 ;; esac ;;
    docker|podman|nerdctl|docker-compose|podman-compose|kubectl|oc|ssh|sh|bash|zsh|dash|ksh|mksh) [[ $2 =~ $GM_DBCLI_RE ]] && return 0 ;;
  esac
  return 1
}
gm_pv_stage() {  # <masked> <raw> — 미리 보기(GM_PV) 다음 파이프 단계. DB 클라이언트면 원래 명령의 결정(적용 ask-low, 롤백은
  # 메인 통과·guard-destructive 몫, 서브에이전트 deny). 다시 파이프로 넘기면(tee·grep 등) 다음 단계를 본다
  if gm_dbclient "$1" "$2"; then gm_pv_db; return 0; fi
  gm_piped "$2" || GM_PV=""
}
gm_pv_db() {  # 미리 보기(GM_PV)의 SQL 을 DB 클라이언트가 실행한다 — 적용은 ask-low, 롤백은 메인 통과(guard-destructive 몫), 서브에이전트는 deny
  if [ "$GM_SUB" -eq 1 ]; then gm_hit 3 migrations:subagent "$GM_SUBAGENT_REASON: $GM_PVX"
  elif [ "$GM_PV" = apply ]; then gm_hit 1 migrations:apply "확인 필요 [migrations:apply]: 마이그레이션 적용(미리 보기 SQL 을 DB 클라이언트로 실행) — 대상 DB(로컬/운영) 확인: $GM_PVX"
  fi
  GM_PV=""
}
gm_too_complex() {  # R4 task2: 파서 작업 상한 초과 — 명령을 다 분석하지 못함. 메인은 ask-high, 서브에이전트는 deny. gm_hit 이 더 센 결정만 남긴다. 어휘 없는 프리필터는 이미 gm_bash 에서 걸렀다
  if [ "$GM_SUB" -eq 1 ]; then gm_hit 3 migrations:too-complex "차단 [migrations:too-complex]: 명령이 너무 커서 전부 분석하지 못함 — 마이그레이션 작업이 섞여 있으면 메인에 보고할 것"
  else gm_hit 2 migrations:too-complex "확인 필요 [migrations:too-complex]: 명령이 너무 커서 전부 분석하지 못함 — 마이그레이션 적용·수정 여부를 직접 확인할 것"; fi
}
gm_run() {  # <명령> <깊이> — sp_segments 결과를 줄마다 처리한다. sub(sh -c·eval·ssh·su -c 의 안쪽 명령)는 범위를 두고 다시 파싱(깊이 3까지)
  local LC_ALL=C out k m r pk="" pf=0 pend inner wb gm_rc=$1 gm_nc="" gm_nb=0 pvh=0 pvd=0 dbh=0 dbd=0 ph=$'(\342\200\246)'   # gm_rc·gm_nc·gm_nb: gm_piped 가 읽는다(S3)
  # LC_ALL=C: 세그먼트·단어의 패턴 비교를 바이트로 한다(UTF-8 로케일에서는 비교마다 글자를 변환해 세그먼트가 많은 명령이 25–50% 느리다).
  # 판정은 ASCII 글자만 보고, 결정 JSON 은 이 함수 밖(gm_finish)에서 만든다
  # pvh·pvd: 건너뛸 $(…) 블록 수·깊이. dbh·dbd: DB 클라이언트 줄의 $(…)·<(…) 블록 수·깊이(psql -c "$(alembic upgrade head --sql)" — 안의 미리 보기는 적용)
  if [ "$1" = "$GM_SSK" ]; then out=$GM_SSV   # 같은 문자열을 바로 다시 파싱할 때(컨테이너 줄의 안쪽 셸 문자열·공용 파서의 sub 줄)는 지난 결과를 쓴다
  else   # R11: < <(…) 대신 명령 치환 + heredoc. R5: 줄 파서 상한은 레코드 상한의 남은 몫(테스트가 SP_WBMAX 로 더 낮췄으면 그것)
    wb=$((GM_RECCAP - GM_REC)); [ "$wb" -gt 0 ] || wb=1
    case ${SP_WBMAX:-} in ''|*[!0-9]*) ;; *) [ "$SP_WBMAX" -lt "$wb" ] && wb=$SP_WBMAX ;; esac
    out=$(SP_WBMAX=$wb sp_segments "$1"); GM_SSK=$1; GM_SSV=$out
  fi
  while IFS=$'\t' read -r k m r; do
    [ "$GM_DONE" -eq 0 ] || break   # 가장 센 결정이 났다 — 나머지는 결정을 바꿀 수 없다(큰 명령의 비용)
    GM_REC=$((GM_REC + 1))
    if [ "$GM_REC" -gt "$GM_RECCAP" ] || hook_time_up; then gm_too_complex; break; fi   # R5: 레코드 상한·작업 시간(lib/common.sh) — 나머지는 보지 않는다
    [ "$k" = overflow ] && { gm_too_complex; break; }   # R4 task2: 파서 작업 상한 초과 — 명령을 다 분석하지 못함
    case $k in cmd*|sub) if hook_longhead "$m"; then gm_too_complex; continue; fi ;; esac   # R5: 4096자를 넘는 명령 이름은 보지 않는다(lib/common.sh)
    case $k in
      push) gm_pend; gm_push; { [ "$pvd" -gt 0 ] || [ "$pvh" -gt 0 ]; } && pvd=$((pvd + 1))   # 미리 보기 단계의 $(…) 안은 다음 파이프 단계가 아니다
            { [ "$dbd" -gt 0 ] || [ "$dbh" -gt 0 ]; } && dbd=$((dbd + 1))
            if [ "$pk" = cmd1 ]; then pf=1; else pf=0; fi; pk=push; continue ;;
      pop) [ "$pf" -eq 1 ] && [ "$pk" = push ] && GM_FUNC=1   # 한 단어 명령 뒤의 빈 ( ) = 함수 정의 name()
           gm_pend; gm_pop
           if [ "$pvd" -gt 0 ]; then pvd=$((pvd - 1)); [ "$pvd" -eq 0 ] && pvh=$((pvh - 1)); fi
           if [ "$dbd" -gt 0 ]; then dbd=$((dbd - 1)); [ "$dbd" -eq 0 ] && dbh=$((dbh - 1)); fi
           pf=0; pk=pop; continue ;;
      sub) ;;
      *) gm_pend ;;
    esac
    pf=0
    if [ "$GM_ANY_DESTR" -eq 0 ] && [ -n "$r" ]; then   # R8: heredoc 본문·세그먼트 글자 어디에든 있는 파괴적 내용(명령 이름 truncate 는 빼고)
      case $k in cmd*) case $r in *' '*) gm_destr "${r#* }" && GM_ANY_DESTR=1 ;; esac ;; *) gm_destr "$r" && GM_ANY_DESTR=1 ;; esac
    fi
    case $k in
      cmd*) case $m in *CDPATH=*|*CDPATH+=*|*cdpath=*|*cdpath+=*) GM_CDPATH=1 ;; esac   # export CDPATH=…·zsh cdpath=(…) 뒤의 상대 cd 는 다른 곳으로 갈 수 있다
            [ -n "$GM_PV" ] && [ "$pvd" -eq 0 ] && gm_pv_stage "$m" "$r"   # S3: 미리 보기 뒤의 파이프 단계
            gm_segment "$m" "$r" "$k"
            if [ "$GM_PVNEW" -eq 1 ]; then GM_PVNEW=0   # 미리 보기의 출력이 파이프로 가지 않으면 보류를 버린다
              if [ "$dbd" -gt 0 ]; then gm_pv_db; else gm_piped "$r" || GM_PV=""; fi   # DB 클라이언트 인수의 $(…)·<(…) 안이면 바로 그 결정
            fi
            if [ -n "$GM_PV" ] && [ "$pvd" -eq 0 ]; then gm_phc "$r"; pvh=$GM_PHC; fi   # 이 단계의 $(…) 블록(뒤에 이어 나온다)은 건너뛴다
            if [ "$dbd" -eq 0 ]; then dbh=0; case $r in *"$ph"*) gm_dbclient "$m" "$r" && { gm_phc "$r"; dbh=$GM_PHC; } ;; esac; fi   # 이 DB 클라이언트 줄 뒤의 블록 수
            if [ -n "$GM_INNER" ]; then   # podman exec … sh -c '…' 처럼 공용 파서가 sub 줄을 내지 않는 컨테이너 안쪽 셸 문자열
              inner=$GM_INNER; GM_INNER=""; gm_push
              gm_need "$inner" && gm_sub "$inner" "$inner" "$2"
              gm_pop
            fi
            pk=cmd; case $m in *' '*|*'$('*|'') ;; *) pk=cmd1 ;; esac ;;
      sub) pend=$GM_PEND; GM_PEND=0; gm_push   # eval 의 보류(GM_PEND)는 안쪽 명령을 다 본 뒤 바깥에 적용한다
           gm_need "$r" && gm_sub "$r" "$m" "$2"   # 중첩 sh -c 의 cd 도 밖으로 새지 않는다. 어휘·이름이 없는 문자열은 다시 파싱하지 않는다
           gm_pop; GM_PEND=$pend; gm_pend; pk=sub ;;
      assign) case $m in *CDPATH=*|*CDPATH+=*|*cdpath=*|*cdpath+=*) GM_CDPATH=1 ;; esac; pk=assign ;;
      *) pk=$k ;;
    esac
  done <<GMEOF
$out
GMEOF
  gm_pend
}
gm_voc() {  # <소문자 명령> → 0 이면 마이그레이션 관련 어휘가 있다(없으면 세션 cwd 가 마이그레이션 경로일 때만 본다)
  case $1 in *migrat*|*alembic*|*prisma*|*'db:'*|*knex*|*drizzle*|*flyway*|*goose*|*dbmate*|*sqlx*|*atlas*|*rails*|*sequelize*|*typeorm*|*versions*|*'db push'*|*artisan*|*liquibase*|*supabase*|*mikro-orm*|*'flask db'*|*flask*' db '*|*django-admin*|*'db reset'*|*'db wipe'*) return 0 ;; esac
  return 1
}
gm_dq() { local IFS=$'\'"\\'; set -f; set -- $1; IFS=; GM_NS="$*"; set +f; }   # <글자> → GM_NS: 따옴표·역슬래시만 뺀 글자(공백은 그대로)
gm_cwd_mig() {  # → 0 이면 세션 cwd(저장소 루트 기준)가 마이그레이션 경로 안이다(R12: 명령에 경로가 드러나지 않는 상대 경로 쓰기)
  gm_rel . "$GM_CWD"
  case /$GM_REL/ in *migrat*|*alembic*|*drizzle*|*flyway*|*liquibase*|*goose*|*dbmate*|*/db/migrate/*) return 0 ;; esac
  return 1
}
gm_bash() {
  local cmd=$H_CMD
  [ -n "$H_CMD" ] || exit 0
  hook_abspath_var "${H_CWD:-$PWD}" /; gm_dotdot "$HOOK_ABS"; GM_CWD=$GM_ND; GM_EFF=$GM_CWD
  GM_LOW=$(hook_lower "$H_CMD")
  gm_voc "$GM_LOW" || {
    # 따옴표·역슬래시로 나뉜 낱말(mig"rations"/…·alem"bic" …)도 셸에서는 이어진다 — 64KB 이하면 그것들을 뺀 글자로 한 번 더 본다
    case $GM_LOW in *[\'\"\\]*) [ "${#GM_LOW}" -le 65536 ] && { gm_dq "$GM_LOW"; gm_voc "$GM_NS"; } ;; *) false ;; esac
  } || gm_cwd_mig || exit 0
  . "$GM_DIR/lib/shellparse.sh"
  case $H_CMD in *HOME*)   # S2: 명령 어디서든 HOME 을 바꾸면(HOME=… cd·export HOME=…·for HOME in·read HOME·printf -v HOME) 맨 cd·~ 는 모르는 위치
    # 낱말 HOME 이면 본다($HOME·${HOME}·JAVA_HOME·HOMEBREW_… 는 아님)
    case " $H_CMD " in *[![:alnum:]_\$\{]HOME[![:alnum:]_]*) GM_HOMESET=1 ;; esac ;;
  esac
  case $H_CMD in *GIT_WORK_TREE*) GM_GWT=1 ;; esac   # 명령 안의 GIT_WORK_TREE(값은 따라가지 않는다 — git 이 쓰는 경로는 이미 있는 파일로도 본다)
  # >|(noclobber 를 무시하는 쓰기)는 공용 파서가 파이프로 끊으므로 > 로 바꿔 읽는다. zsh 의 같은 쓰기 >!·>>!·&>!·>&!·>&| 도(Bash 도구가 zsh 로 돌 수
  # 있다 — bash 에서는 ! 라는 파일에 쓰지만 보수적으로 zsh 쪽으로 읽는다). awk 한 번으로(선형) — ${cmd//…} 는 >| 수에 비례해
  # 2차 비용이라 수천 개면 10초 제한을 넘겨 판정 없이 통과했다. awk 가 실패하면 원래 명령 그대로
  # zsh 의 >>&·>>&|·>>&!(표준 출력·오류를 덧붙여 쓰기 = &>>)도 &>> 로 읽는다 — 공용 파서는 >>& 뒤의 대상을 명령 인수로 본다
  case $cmd in *'>|'*|*'>!'*|*'>&|'*|*'>&!'*|*'>>&'*) GM_NS=$(printf '%s\n' "$cmd" | LC_ALL=C awk '{ gsub(/>>&[|!]?/, "\\&>> "); gsub(/>&[|!]/, ">\\& "); gsub(/>[|!]/, "> "); print }') && cmd=$GM_NS ;; esac
  gm_run "$cmd" 0
  [ "$GM_NEW" -eq 1 ] && [ "$GM_ANY_DESTR" -eq 1 ] && gm_hit 2 migrations:destructive-schema "$GM_DESTR_REASON: $GM_NEW_FILE"
  gm_finish
}

case $H_TOOL in Bash|Monitor) gm_bash ;; *) gm_file_tools ;; esac
exit 0
