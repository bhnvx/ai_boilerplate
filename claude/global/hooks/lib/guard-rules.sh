#!/usr/bin/env bash
# lib/guard-rules.sh — guard-destructive.sh 의 규칙 테이블(system/db/infra/deploy/publish/privilege/data-loss)
# guard-destructive.sh 가 source 한다. 세그먼트 컨텍스트(전역): S_KIND S_M(masked) S_R(raw) S_HEAD, 토큰 GD_T[j0..e), 세그먼트 번호 i
# gd_shit <sev> <rule> <why> : 1 ask-low, 2 ask-high, 3 deny (세그먼트 단위, 가장 심각한 것만 남음)

SW1=""; SW2=""; SW3=""; SW4=""; SWN=0; GD_TA=""
gd_numval() {  # <단어> → 0 이면 make -j/-l 의 값으로 본다: 숫자(2·2.5)이거나 실행할 때 펼쳐지는 값($N·"$JOBS"·$(nproc)·`nproc` 의 자리표시 —
  # 셸이 숫자로 바꿔 넘긴다). 그 밖의 단어는 GNU make 처럼 값이 아니라 타깃이다(R4 task3; make -j $(nproc) deploy 를 놓치지 않게)
  case $1 in ''|*[!0-9.]*) case $1 in '$'*) return 0 ;; esac; return 1 ;; esac
  return 0
}
gd_subwords() {  # <" -flag -flag "> [<" -numflag "">] 값을 갖는 플래그를 건너뛰고 첫 4개 하위 명령어를 SW1..SW4 에 넣는다.
  # 2번째 인수(numv)의 플래그(make 의 -j/--jobs/-l/--load-average)는 다음 단어가 값(gd_numval)일 때만 먹는다(GNU make: 숫자가 아니면 그 단어는 타깃; I4/R4 task3)
  local vals=$1 numv=${2:-} j=$((j0 + 1)) t n=0 dd=0
  SW1=""; SW2=""; SW3=""; SW4=""
  while [ "$j" -lt "$e" ]; do
    t=${GD_T[$j]}; j=$((j + 1))
    if [ "$dd" -eq 0 ]; then
      case $t in
        --) dd=1; continue ;;
        -*=) j=$((j + 1)); continue ;;
        -*) case $numv in *" $t "*) gd_numval "${GD_T[$j]:-}" && j=$((j + 1)); continue ;; esac   # -j/-l 등: 다음 단어가 값이면 먹고, 아니면 그 단어가 타깃
            case $vals in *" $t "*) j=$((j + 1)) ;; esac; continue ;;
      esac
    fi
    n=$((n + 1)); case $n in 1) SW1=$t ;; 2) SW2=$t ;; 3) SW3=$t ;; 4) SW4=$t; break ;; esac
  done
  SWN=$n
}
gd_has_tok() {  # <tok> — 세그먼트 토큰(머리 제외) 중 정확히 일치하는 것이 있으면 0
  local j=$((j0 + 1)); while [ "$j" -lt "$e" ]; do [ "${GD_T[$j]}" = "$1" ] && return 0; j=$((j + 1)); done; return 1
}
gd_tok_after() {  # <tok> → GD_TA = 그 다음 토큰
  local j=$((j0 + 1)); GD_TA=""
  while [ "$j" -lt "$e" ]; do [ "${GD_T[$j]}" = "$1" ] && { GD_TA=${GD_T[$((j + 1))]:-}; return 0; }; j=$((j + 1)); done; return 1
}
gd_short_has() {  # <letter> — 짧은 플래그 그룹(-rfv 등) 안에 글자가 있으면 0
  local j=$((j0 + 1)) t; while [ "$j" -lt "$e" ]; do t=${GD_T[$j]}; j=$((j + 1)); case $t in --) return 1 ;; --*) ;; -*"$1"*) return 0 ;; esac; done; return 1
}
gd_dry_run() {  # kubectl/helm 의 --dry-run / --dry-run=client|server 가 있으면 0 (G16; --dry-run=none 은 실제 적용)
  gd_has_tok --dry-run && return 0
  if gd_tok_after --dry-run=; then case $GD_TA in client|server) return 0 ;; esac; fi
  return 1
}

gd_system() {
  local re
  case $S_HEAD in
    mkfs|mkfs.*) gd_shit 3 system "파일시스템 포맷" ;;
    shutdown|reboot|halt|poweroff) gd_shit 3 system "시스템 종료/재시작" ;;
    killall5) gd_shit 3 system "모든 프로세스 종료" ;;
    kill) [ "$e" -gt "$((j0 + 2))" ] && [ "${GD_T[$((e - 1))]}" = "-1" ] && gd_shit 3 system "모든 프로세스 종료(kill -1)" ;;
    crontab) gd_has_tok -r && gd_shit 3 system "crontab 전체 삭제" ;;
    history) gd_has_tok -c && gd_shit 3 system "셸 히스토리 삭제" ;;
    launchctl) case $S_M in 'launchctl bootout system'*) gd_shit 3 system "시스템 launchd 도메인 해제" ;; esac ;;
    diskutil) case $S_M in 'diskutil eraseDisk'*|'diskutil eraseVolume'*|'diskutil reformat'*|'diskutil apfs deleteContainer'*|'diskutil apfs deleteVolume'*) gd_shit 3 system "디스크/볼륨 삭제" ;; esac ;;
    csrutil) gd_has_tok disable && gd_shit 3 system "SIP 해제" ;;
    nvram) gd_has_tok -c && gd_shit 3 system "NVRAM 초기화" ;;
    dd) re='^/dev/(r?disk|sd|nvme|hd|mmcblk|xvd|vd)'; gd_tok_after of= && [[ $GD_TA =~ $re ]] && gd_shit 3 system "블록 디바이스에 직접 쓰기" ;;
    chmod|chown) if gd_short_has R || gd_has_tok --recursive; then gd_has_tok / && gd_shit 3 system "루트 권한/소유자 재귀 변경"; fi ;;
  esac
}

gd_sql_scan() {  # <text> — DB 클라이언트가 먹는 텍스트의 파괴적 SQL (대소문자 무시). 반환 0 = 발견
  local r1='drop[[:space:]]+(table|database|schema|index|user|role|view|sequence)' r2='truncate([[:space:]]+table)?[[:space:]]+[a-z_"`]'
  local r3='delete[[:space:]]+from[[:space:]]+[a-z_"`.]+[[:space:]]*(;|$)' r4='alter[[:space:]]+table.*drop' r5='(flushall|flushdb)([[:space:]]|$)' r6='drop_?(database|collection)|\.drop\(\)'
  shopt -s nocasematch
  if [[ $1 =~ $r1 ]] || [[ $1 =~ $r2 ]] || [[ $1 =~ $r3 ]] || [[ $1 =~ $r4 ]] || [[ $1 =~ $r5 ]] || [[ $1 =~ $r6 ]]; then
    shopt -u nocasematch; gd_shit 2 db "파괴적 DB 작업(DROP/TRUNCATE/DELETE 전체/FLUSH)"; return 0
  fi
  shopt -u nocasematch; return 1
}
gd_db() {  # DB 클라이언트 머리. 파이프로 들어오는 SQL(echo "DROP …" | psql)은 직전 세그먼트(echo/printf/cat)의 RAW 도 검사(G14)
  local pm
  case $S_HEAD in
    dropdb|dropuser) gd_shit 2 db "DB/사용자 삭제" ;;
    psql|mysql|mariadb|sqlite3|duckdb|clickhouse-client|mongosh|mongo|redis-cli|cqlsh)
      if ! gd_sql_scan "$S_R" && [ "${i:-0}" -gt 0 ]; then
        pm=${GD_M[$((i - 1))]}
        case $pm in echo|'echo '*|printf|'printf '*|cat|'cat '*) gd_sql_scan "${GD_R[$((i - 1))]}" ;; esac
      fi ;;
  esac
}
gd_db_orm() {  # ORM/마이그레이션 도구의 파괴적 작업(머리와 무관하게 MASKED 로 판단). §3.9: 롤백/clean/reset/drop 은 전부 이 훅 소유(G5)
  case $S_M in
    *'manage.py dbshell'*|*'manage.py flush'*|*'manage.py sqlflush'*|*'manage.py reset_db'*|*'django-admin flush'*) gd_shit 2 db "DB 초기화/셸" ;;
    *'manage.py migrate'*|*'django-admin migrate'*) case " $S_M " in *' zero '*) gd_shit 2 db "마이그레이션 전체 되돌리기(zero)" ;; esac ;;
    *'prisma migrate reset'*|*'prisma db push'*--force-reset*|*'prisma db execute'*) gd_shit 2 db "Prisma DB 초기화/직접 실행" ;;
    *'alembic downgrade'*|*'flask db downgrade'*) case " $S_M " in   # --sql: SQL 출력만(오프라인). 그 SQL 을 DB 클라이언트로 넘기면 실행(I5)
        *' --sql '*) gd_sql_fed && gd_shit 2 db "롤백 SQL 미리 보기를 DB 클라이언트로 실행(alembic·flask db downgrade --sql)" ;;
        *) gd_shit 2 db "alembic downgrade" ;; esac ;;
    *'db:drop'*|*'db:reset'*|*'db:schema:load'*|*'db:purge'*|*'db:rollback'*|*'db:migrate:reset'*|*'db:migrate:undo'*|*'db:migrate:down'*|*'db:wipe'*) gd_shit 2 db "DB 삭제/초기화/마이그레이션 롤백($S_HEAD)" ;;
    *knex*' migrate:rollback'*|*knex*' migrate:down'*|*typeorm*' schema:drop'*|*'migration:revert'*|*mikro-orm*' migration:down'*|*mikro-orm*' schema:drop'*) gd_shit 2 db "마이그레이션 롤백/스키마 삭제" ;;
    *flyway*' clean'*|*'goose down'*|*'goose '*' down'*|*'goose reset'*|*'goose '*' reset'*|*'dbmate drop'*|*'dbmate '*' drop'*|*'dbmate rollback'*|*'dbmate '*' rollback'*|*'dbmate down'*|*'dbmate '*' down'*|*'sqlx database drop'*|*'sqlx migrate revert'*|*'atlas schema clean'*|*'atlas '*' schema clean'*|*'drizzle-kit drop'*|*'supabase db reset'*|*'supabase '*' db reset'*) gd_shit 2 db "마이그레이션 롤백/스키마 삭제($S_HEAD)" ;;
    *artisan*' migrate:fresh'*|*artisan*' migrate:reset'*|*artisan*' migrate:rollback'*|*artisan*' migrate:refresh'*) gd_shit 2 db "Laravel DB 초기화/롤백" ;;
  esac
  case $S_M in *liquibase*) gd_liquibase ;; esac
  gd_db_opts
}
GD_SQLC=' psql mysql mariadb sqlite3 sqlcmd clickhouse-client clickhouse duckdb '   # SQL 을 받아 실행하는 DB 클라이언트(I5)
gd_sql_fed() {  # 세그먼트 i 의 출력(SQL 미리 보기)이 DB 클라이언트로 가는가(I5). 파서는 구분자를 남기지 않으므로 파이프는 세그먼트 순서로
  # 근사한다: 뒤 세그먼트가 DB 클라이언트(거름 명령 tee·cat·sed·grep·awk·tr·head·tail 과 kubectl exec·ssh 의 바깥 줄은 지나감).
  # 또는 이 세그먼트가 DB 클라이언트 줄 바로 뒤의 치환 안(psql -f <(…), psql -c "$(…)")
  local j=$((${i:-0} + 1)) h
  while [ "$j" -lt "$GD_N" ]; do
    case ${GD_K[$j]} in cmd*) ;; *) break ;; esac
    h=${GD_M[$j]%% *}; h=${h##*/}
    gd_ro "$h" "$GD_SQLC" && return 0
    case $h in tee|cat|sed|grep|awk|tr|head|tail|kubectl|ssh) j=$((j + 1)) ;; *) break ;; esac
  done
  j=${i:-0}
  if [ "$j" -ge 2 ] && [ "${GD_K[$((j - 1))]}" = push ]; then
    case ${GD_K[$((j - 2))]} in cmd*) h=${GD_M[$((j - 2))]%% *}; gd_ro "${h##*/}" "$GD_SQLC" && return 0 ;; esac
  fi
  return 1
}
gd_liquibase() {  # liquibase 의 롤백·전체 삭제 동사(I5). MASKED 단어로 r2b 와 같은 범위(liquibase 뒤 어디든 rollback… dropAll… 로 시작하는
  # 단어)를 보되, SQL 만 출력하는 미리 보기(*-sql·*SQL·*Sql — guard-migrations 와 같음)와 리디렉션 대상(> rollback.sql)은 동사가 아니다.
  # 롤백 미리 보기를 DB 클라이언트로 넘기면(| psql) 실행이므로 롤백과 같다
  local w seen=0 skip=0 rb=0 pv=0
  set -f; set -- $S_M; set +f
  for w in "$@"; do
    if [ "$seen" -eq 0 ]; then case $w in *liquibase*) seen=1 ;; esac; continue; fi
    [ "$skip" -eq 1 ] && { skip=0; continue; }
    case $w in
      *'>'|*'>&'|*'>|'|'<'|'0<'|[1-9]'<'|'<<<') skip=1 ;;
      *-sql|*SQL|*Sql) case $w in *[Rr]ollback*) pv=1 ;; esac ;;   # rollback-sql·rollbackSQL·future-rollback-sql(update-sql·execute-sql 은 롤백 아님)
      rollback*|dropAll*|dropall*|drop-all*) rb=1 ;;
    esac
  done
  if [ "$rb" -eq 1 ]; then gd_shit 2 db "마이그레이션 롤백/스키마 삭제(liquibase)"
  elif [ "$pv" -eq 1 ] && gd_sql_fed; then gd_shit 2 db "롤백 SQL 미리 보기를 DB 클라이언트로 실행(liquibase)"; fi
  return 0
}
gd_tool_sub() {  # <glob> <" -opt ... "> — 세그먼트에서 <glob> 과 맞는 첫 토큰(경로 접미 포함) 뒤의 하위 명령어 → SW1..SW4. 없으면 1
  local j=$j0 t n=0   # 값을 받는 옵션(-c x, -x k=v 는 토큰 둘)과 --opt=값 은 값까지 건너뛴다
  SW1=""; SW2=""; SW3=""; SW4=""
  while [ "$j" -lt "$e" ]; do case ${GD_T[$j]} in $1|*/$1) break ;; esac; j=$((j + 1)); done
  [ "$j" -lt "$e" ] || return 1
  j=$((j + 1))
  while [ "$j" -lt "$e" ]; do t=${GD_T[$j]}; j=$((j + 1))
    case $t in
      -*=) j=$((j + 1)); continue ;;
      -*) case $2 in *" $t "*) case ${GD_T[$j]:-} in [A-Za-z_]*=) j=$((j + 2)) ;; *) j=$((j + 1)) ;; esac ;; esac; continue ;;
    esac
    n=$((n + 1)); case $n in 1) SW1=$t ;; 2) SW2=$t ;; 3) SW3=$t ;; 4) SW4=$t; break ;; esac
  done
  return 0
}
gd_db_opts() {  # 도구와 동사 사이에 전역 옵션이 낀 롤백·리셋·삭제(r2): alembic -c x downgrade, flask --app x db downgrade,
  # prisma --schema x migrate reset, golang-migrate(migrate … down|drop, 이미지 migrate/migrate). alembic·flask 의 --sql 은 오프라인(SQL 출력만)
  case $S_M in *alembic*)
    if gd_tool_sub alembic ' -c --config -n --name -x ' && [ "$SW1" = downgrade ]; then
      if ! gd_has_tok --sql; then gd_shit 2 db "마이그레이션 롤백(alembic downgrade)"
      elif gd_sql_fed; then gd_shit 2 db "롤백 SQL 미리 보기를 DB 클라이언트로 실행(alembic downgrade --sql)"; fi
    fi ;;
  esac
  case $S_M in *flask*)
    if gd_tool_sub flask ' -A --app -e --env-file ' && [ "$SW1 $SW2" = "db downgrade" ]; then
      if ! gd_has_tok --sql; then gd_shit 2 db "마이그레이션 롤백(flask db downgrade)"
      elif gd_sql_fed; then gd_shit 2 db "롤백 SQL 미리 보기를 DB 클라이언트로 실행(flask db downgrade --sql)"; fi
    fi ;;
  esac
  case $S_M in *prisma*)
    if gd_tool_sub prisma ' --schema '; then
      case "$SW1 $SW2" in 'migrate reset'|'db execute') gd_shit 2 db "Prisma DB 초기화/직접 실행" ;; 'db push') gd_has_tok --force-reset && gd_shit 2 db "Prisma DB 초기화(--force-reset)" ;; esac
    fi ;;
  esac
  case $S_HEAD in migrate)
    gd_tool_sub migrate ' -source -path -database -prefetch -lock-timeout --source --path --database --prefetch --lock-timeout '
    case $SW1 in down|drop) gd_shit 2 db "마이그레이션 롤백/스키마 삭제(migrate $SW1)" ;; esac ;;
  esac
  case $S_M in *migrate/migrate*)
    if gd_tool_sub 'migrate/migrate*' ' -source -path -database -prefetch -lock-timeout --source --path --database --prefetch --lock-timeout '; then
      case $SW1 in down|drop) gd_shit 2 db "마이그레이션 롤백/스키마 삭제(migrate/migrate $SW1)" ;; esac
    fi ;;
  esac
  return 0
}

gd_ro() {  # <word> <" a b c "> — word 가 목록에 있으면 0
  [ -n "$1" ] && case $2 in *" $1 "*) return 0 ;; esac; return 1
}
gd_ver_help() {  # 첫 인수가 버전·도움말 플래그이고 나머지도 플래그뿐이면 0(aws --version, terraform -help). 맨 앞일 때만 본다
  local j=$((j0 + 1))
  [ "$j" -lt "$e" ] || return 1
  case ${GD_T[$j]} in --version|-version|--help|-help|-h) ;; *) return 1 ;; esac
  j=$((j + 1)); while [ "$j" -lt "$e" ]; do case ${GD_T[$j]} in -*) ;; *) return 1 ;; esac; j=$((j + 1)); done
  return 0
}
gd_infra() {
  local w
  gd_ver_help && return 0
  case $S_HEAD in
    kubectl) gd_subwords ' -n --namespace --context --kubeconfig --cluster --user -s --server --token --as --as-group --request-timeout -v --certificate-authority --client-certificate --client-key -o --output -l --selector '
      case $SW1 in
        rollout) case $SW2 in status|history) return 0 ;; esac ;;
        auth) case $SW2 in can-i|whoami) return 0 ;; esac ;;
        get|describe|logs|top|explain|api-resources|api-versions|version|cluster-info|config|diff|port-forward|wait|events|completion|help) return 0 ;;
      esac
      gd_dry_run && return 0
      gd_shit 2 infra-write "인프라/클라우드 쓰기 작업(kubectl $SW1 $SW2)" ;;
    helm) gd_subwords ' -n --namespace --kube-context --kubeconfig -f --values --set --set-string --version --repo -o --output '
      gd_ro "$SW1" ' list ls status get history show template lint search version env help diff ' && return 0   # diff: helm-diff 플러그인(미리보기)
      case "$SW1 $SW2" in 'repo list'|'repo ls'|'repo update'|'dependency list'|'dependency ls'|'dependency build'|'dependency update') return 0 ;; esac
      gd_dry_run && return 0
      gd_shit 2 infra-write "인프라/클라우드 쓰기 작업(helm $SW1)" ;;
    terraform|tofu|terragrunt) gd_subwords ' -var -var-file -target -backend-config -lock-timeout -parallelism '
      gd_ro "$SW1" ' plan fmt validate init show output providers graph version console login logout test get metadata help hclfmt render-json validate-inputs ' && return 0
      case "$SW1 $SW2" in 'state list'|'state show'|'state pull'|'workspace list'|'workspace show'|'workspace select'|'run-all plan'|'run-all validate'|'run-all init') return 0 ;; esac
      gd_shit 2 infra-write "인프라/클라우드 쓰기 작업($S_HEAD $SW1)" ;;
    pulumi) gd_subwords ' -s --stack -C --cwd --config-file --color '
      gd_ro "$SW1" ' preview whoami version about login logout help ' && return 0
      case "$SW1 $SW2" in 'stack ls'|'stack output'|'stack history'|'stack export'|'stack graph'|'stack select'|'config get'|'config ls'|'plugin ls') return 0 ;; esac
      gd_shit 2 infra-write "인프라/클라우드 쓰기 작업(pulumi $SW1)" ;;
    aws) gd_subwords ' --profile --region --endpoint-url --output -o --query --cli-connect-timeout --cli-read-timeout --color --ca-bundle --cli-binary-format --page-size --max-items --starting-token '
      case "$SW1 $SW2" in 's3 ls'|'s3 presign'|'sts get-caller-identity'|'configure list'|'configure get'|'help '|'configure list-profiles'|'logs tail') return 0 ;; esac
      case $SW2 in describe-*|get-*|list-*|ls|head-*|lookup-*|search-*|query|scan|help|wait|batch-get-*|validate-*|check-*|test-*|estimate-*|preview-*|simulate-*) return 0 ;; esac
      gd_shit 2 infra-write "인프라/클라우드 쓰기 작업(aws $SW1 $SW2)" ;;
    gcloud) gd_subwords ' --project --account --configuration --format --filter --impersonate-service-account --billing-project --zone --region --verbosity --limit --sort-by --flags-file '
      for w in "$SW1" "$SW2" "$SW3" "$SW4"; do case $w in list|describe|get|print-*|info|version|topic|help|get-*|get-iam-policy) return 0 ;; esac; done
      case "$SW1 $SW2" in 'config list'|'auth list'|'config get-value'|'auth print-access-token'|'auth print-identity-token'|'logging read') return 0 ;; esac
      gd_shit 2 infra-write "인프라/클라우드 쓰기 작업(gcloud $SW1 $SW2 $SW3)" ;;
    az) gd_subwords ' --subscription -o --output --query -g --resource-group -n --name -l --location '
      for w in "$SW1" "$SW2" "$SW3" "$SW4"; do case $w in list|show|get|version|help|list-*|show-*|get-*) return 0 ;; esac; done
      gd_shit 2 infra-write "인프라/클라우드 쓰기 작업(az $SW1 $SW2)" ;;
    docker) gd_docker ;;
    docker-compose) gd_docker_compose_v1 ;;
    gh) gd_gh ;;
    fly|flyctl) gd_subwords ' -a --app -c --config --access-token -t -r --region --org -o '
      gd_ro "$SW1" ' status logs apps version info config releases machine volumes auth help dashboard ' && case "$SW1 $SW2" in 'apps list'|'apps ls'|'config show'|'config validate'|'releases list'|'releases ls'|'machine list'|'machine ls'|'volumes list'|'volumes ls'|'auth whoami'|status*|logs*|version*|info*|dashboard*|help*) return 0 ;; esac
      gd_shit 2 infra-write "배포/인프라 쓰기 작업($S_HEAD $SW1 $SW2)" ;;
    heroku) gd_subwords ' -a --app -r --remote '
      gd_ro "$SW1" ' apps logs ps releases status info version config auth:whoami apps:info help ' && return 0
      gd_shit 2 infra-write "배포/인프라 쓰기 작업(heroku $SW1)" ;;
    vercel) gd_subwords ' --token -t --scope -S --cwd -A --local-config '
      gd_ro "$SW1" ' ls list inspect logs whoami env version help domains teams projects ' && return 0
      gd_shit 2 infra-write "배포 작업(vercel ${SW1:-deploy})" ;;
    netlify) gd_subwords ' --site -s --auth --filter --dir -d --functions -f '
      gd_ro "$SW1" ' status sites:list logs version dev functions:list env:list open help login ' && return 0
      gd_shit 2 infra-write "배포 작업(netlify $SW1)" ;;
    wrangler) gd_subwords ' --config -c --env -e --name --compatibility-date '
      gd_ro "$SW1" ' dev whoami versions tail version login help pages deployments ' && return 0
      gd_shit 2 infra-write "배포 작업(wrangler $SW1)" ;;
    serverless|sls) gd_subwords ' --stage -s --region -r --config -c --app --org '
      gd_ro "$SW1" ' info print logs version help package ' && return 0
      case "$SW1 $SW2" in 'invoke local') return 0 ;; esac
      gd_shit 2 infra-write "배포 작업($S_HEAD $SW1)" ;;
    sam) gd_subwords ' --profile --region --config-file --config-env -t --template --template-file --stack-name -s '
      gd_ro "$SW1" ' build validate local version init package list logs traces help ' && return 0
      gd_shit 2 infra-write "배포 작업(sam $SW1)" ;;
    cdk) gd_subwords ' -a --app -c --context --profile -o --output --toolkit-stack-name '
      gd_ro "$SW1" ' synth synthesize diff ls list version doctor context metadata notices init help ' && return 0
      gd_shit 2 infra-write "배포 작업(cdk $SW1)" ;;
    ansible-playbook) gd_shit 2 infra-write "ansible-playbook 실행" ;;
    fab) gd_shit 2 infra-write "fabric 작업 실행" ;;
    cap) gd_subwords ' '; case "$SW1 $SW2" in *deploy*) gd_shit 2 infra-write "capistrano 배포" ;; esac ;;
    firebase|eb|supabase|railway|amplify|kamal|cf|zappa)   # 배포 CLI: 배포 하위 명령만(나머지는 기존 규칙·통과)
      gd_subwords ' -P --project --token --profile -r --region -e --environment -s --service -d --destination -c --config-file --project-ref --workdir '
      case "$S_HEAD:$SW1" in
        firebase:deploy|firebase:*:deploy|eb:deploy|railway:up|railway:redeploy|amplify:publish|amplify:push|kamal:deploy|kamal:redeploy|kamal:rollback|kamal:setup|cf:push|zappa:deploy|zappa:update|zappa:rollback)
          gd_shit 2 infra-write "배포 작업($S_HEAD $SW1)" ;;
        supabase:functions) [ "$SW2" = deploy ] && gd_shit 2 infra-write "배포 작업(supabase functions deploy)" ;;
      esac ;;
  esac
}
gd_compose() {  # <compose 하위 명령> — docker compose 와 v1 바이너리 docker-compose 공용(G14)
  case $1 in
    down) if gd_has_tok -v || gd_has_tok --volumes || gd_has_tok --rmi; then gd_shit 2 infra-write "docker compose down -v(볼륨 삭제)"; fi ;;
    push) gd_shit 2 publish "컨테이너 이미지 푸시" ;;
    ps|logs|config|images|top|version|ls|events|up|build|pull|restart|start|stop|run|exec|create|kill|pause|unpause|port|cp|watch|attach|wait|stats|'') ;;
    *) gd_shit 2 infra-write "docker compose $1" ;;
  esac
}
gd_docker_compose_v1() {  # docker-compose(v1 shim): 첫 하위 단어가 compose 하위 명령
  gd_subwords ' -f --file -p --project-name --env-file --profile --project-directory --ansi --log-level --context -c -H --host '
  gd_compose "$SW1"
}
gd_docker() {
  gd_subwords ' --context -c -H --host -l --log-level --config -f --file -p --project-name --env-file --profile --project-directory --ansi --progress --parallel '
  case $SW1 in
    compose) gd_compose "$SW2" ;;
    system) [ "$SW2" = prune ] && gd_shit 2 infra-write "docker system prune" ;;
    volume|image|container|network) case $SW2 in rm|prune|remove) gd_shit 2 infra-write "docker $SW1 $SW2" ;; esac ;;
    rmi|rm|login|logout) gd_shit 2 infra-write "docker $SW1" ;;
    push) gd_shit 2 publish "컨테이너 이미지 푸시" ;;
    buildx) gd_has_tok --push && gd_shit 2 publish "컨테이너 이미지 푸시(buildx --push)" ;;
    ps|images|logs|inspect|version|info|stats|top|port|diff|history|search|build|pull|run|exec|create|start|stop|restart|kill|pause|unpause|wait|rename|attach|events|tag|save|load|export|cp|commit|ls|context|manifest|scout|'') ;;
    *) gd_shit 2 infra-write "docker $SW1" ;;
  esac
}
gd_gql_doc() {  # <query 값> → GD_GQL: read(query·{·fragment 로 시작하고 mutation 이 없는 인라인 문서) | write(mutation·@파일·치환·그 밖)
  local v=$1
  v=${v#"${v%%[![:space:]]*}"}                       # 앞 공백(여러 줄 문서) 제거
  case $v in
    *mutation*) GD_GQL=write ;;
    query|query[[:space:]\(\{]*|'{'*|fragment[[:space:]]*) [ "$GD_GQL" = write ] || GD_GQL=read ;;
    *) GD_GQL=write ;;                               # 토큰은 @ 를 벗기므로 query=@q.graphql 도 여기(파일 내용은 모른다)
  esac
}
gd_gh() {
  local j t m xm="" fm="" ep="" GD_GQL=""
  gd_subwords ' -R --repo -H --hostname -t --template -q --jq -F --field -f --raw-field -X --method --input -H --header -b --body -B --base -c --cwd '
  case "$SW1 $SW2" in
    'release create'|'release upload') gd_shit 2 publish "GitHub 릴리스 생성/업로드" ;;
    'release delete'|'release edit'|'release delete-asset'|'repo delete'|'repo edit'|'repo rename'|'repo archive'|'repo unarchive'|'repo sync'|'pr merge'|'secret set'|'secret delete'|'secret remove'|'variable set'|'variable delete'|'workflow run'|'workflow enable'|'workflow disable'|'auth logout') gd_shit 2 infra-write "GitHub 쓰기 작업(gh $SW1 $SW2)" ;;
    'api '*) j=$((j0 + 1)); while [ "$j" -lt "$e" ] && [ "${GD_T[$j]}" != api ]; do j=$((j + 1)); done; j=$((j + 1))
      while [ "$j" -lt "$e" ]; do t=${GD_T[$j]}; j=$((j + 1))   # F10: 명시적 -X 가 이긴다. 필드(-f/-F)·--input 은 기본값만 POST 로 바꾼다
        case $t in
          -X|--method|--method=) xm=${GD_T[$j]:-}; j=$((j + 1)) ;;
          -X?*) xm=${t#-X} ;;
          -f|-F|--field|--raw-field|--field=|--raw-field=) fm=POST; t=${GD_T[$j]:-}; j=$((j + 1))   # 값 key=value 는 key= 와 value 두 토큰
            case $t in query=) gd_gql_doc "${GD_T[$j]:-}"; j=$((j + 1)) ;; query=*) gd_gql_doc "${t#query=}" ;; *=) j=$((j + 1)) ;; esac ;;
          --input|--input=) fm=POST; j=$((j + 1)) ;;
          -H|--header|-q|--jq|-t|--template|--hostname|--cache|-p|--preview) j=$((j + 1)) ;;
          -*=) j=$((j + 1)) ;; -*) ;;
          *) [ -n "$ep" ] || ep=$t ;;
        esac
      done
      m=${xm:-$fm}
      case $m in GET|HEAD|get|head) return 0 ;; esac
      if [ "$ep" = graphql ]; then [ "$GD_GQL" = read ] || gd_shit 2 infra-write "GitHub API 쓰기 호출(gh api graphql)"; return 0; fi
      case $m in POST|PUT|PATCH|DELETE|post|put|patch|delete) gd_shit 2 infra-write "GitHub API 쓰기 호출(gh api $m)" ;; esac ;;
  esac
}

gd_remote() {
  local j t
  case $S_HEAD in
    ssh) gd_shit 2 remote "원격 호스트 접속(ssh)" ;;
    scp|sftp) gd_shit 2 remote "원격 파일 전송($S_HEAD)" ;;
    rsync) j=$((j0 + 1))
      while [ "$j" -lt "$e" ]; do t=${GD_T[$j]}; j=$((j + 1))
        case $t in --delete*) gd_shit 2 data-loss-misc "rsync --delete" ;; -*) ;; *://*) ;; *:*) case ${t%%:*} in */*) ;; *) gd_shit 2 remote "원격 호스트로 rsync" ;; esac ;; esac
      done ;;
  esac
}
GD_PK=""; GD_PF=""; GD_PI=""; GD_PW=""; GD_PN=0; GD_PH='$(…)'   # GD_PH: 파서가 명령 치환 자리에 남기는 자리표시 단어
GD_PC=""; GD_PCV=""   # gd_prog 캐시(I3): 키 "세그먼트:종류"와 결과 — pipe-to-shell 과 deploy-runner 가 같은 세그먼트를 두 번 훑지 않는다
gd_stdin_dev() { case $1 in /dev/stdin|/dev/fd/0|/proc/self/fd/0|/proc/thread-self/fd/0) return 0 ;; esac; return 1; }
gd_prog() {  # <sh|py|node|perl|ruby> — 셸·인터프리터 세그먼트 [j0,e) 가 프로그램을 어디서 읽는가(F14·F2·r2). 값을 받는 옵션은 인터프리터마다 다르다:
  # 셸 -o -O(+o +O) --rcfile --init-file, python -W -X(-c -m 은 프로그램), node -r --require --import --loader -C --conditions --env-file(-e -p 는 프로그램)
  # → GD_PK stdin | file | string | module, GD_PF = 스크립트 인수·명령 문자열·(module 이면 모듈 뒤 첫 인수)
  #   GD_PI = 표준 입력: ''(물려받음 — < /dev/stdin·<&0 포함) | file(GD_PW = < 대상) | here(GD_PW = <<< 단어) | heredoc | other
  #   GD_PN = 1: 실행하지 않음(셸 -n, node --check|-c|--test, perl·ruby -c, python -m py_compile|compileall|pytest)
  local k=$1 j=$((j0 + 1)) t v c r st=0 sf=0 vals=' '   # st: 0 옵션, 1 옵션 끝(다음 단어가 피연산자), 2 피연산자 뒤(인수), 3 python -m 모듈 뒤
  if [ "$GD_PC" = "${i:-}:$k" ]; then   # 같은 세그먼트·종류는 캐시(I3)
    GD_PK=${GD_PCV%%$'\t'*}; v=${GD_PCV#*$'\t'}; GD_PF=${v%%$'\t'*}; v=${v#*$'\t'}; GD_PI=${v%%$'\t'*}; v=${v#*$'\t'}
    GD_PW=${v%%$'\t'*}; GD_PN=${v#*$'\t'}; return 0
  fi
  GD_PK=stdin; GD_PF=""; GD_PI=""; GD_PW=""; GD_PN=0
  case $k in
    sh) vals=' --rcfile --init-file ' ;;
    py) vals=' --check-hash-based-pycs ' ;;
    node) vals=' -r --require --import --loader --experimental-loader -C --conditions --env-file ' ;;
  esac
  while [ "$j" -lt "$e" ] && [ "$st" -ne 2 ]; do t=${GD_T[$j]}; j=$((j + 1))   # 피연산자 앞(옵션)은 인덱스 순회
    case $t in                                          # 리디렉션은 어디에 있어도 본다(출력 리디렉션은 대상 단어와 함께 건너뜀)
      '<('*|'>('*) ;;                                   # 프로세스 치환은 단어
      '<<<') GD_PI=here; GD_PW=${GD_T[$j]:-}; j=$((j + 1)); continue ;;
      '<<<'*) GD_PI=here; GD_PW=${t#<<<}; continue ;;
      '<<'*) GD_PI=heredoc; continue ;;
      '<&0'|'0<&0') continue ;;                         # 표준 입력 복제 — 여전히 파이프
      '<&'*|'0<&'*) GD_PI=other; continue ;;
      '<'|'0<') v=${GD_T[$j]:-}; j=$((j + 1)); gd_stdin_dev "$v" || { GD_PI=file; GD_PW=$v; }; continue ;;
      '<'*|'0<'*) v=${t#0}; v=${v#<}; gd_stdin_dev "$v" || { GD_PI=file; GD_PW=$v; }; continue ;;
      [1-9]'<'|*'>'|*'>&'|*'>|') j=$((j + 1)); continue ;;
      [1-9]'<'*|*'>'*) continue ;;
    esac
    case $st in
      3) case $t in -*) ;; *) GD_PF=$t; st=2 ;; esac; continue ;;
      0) case $k:$t in
           *:--) st=1; continue ;;
           sh:-) st=1; continue ;;                      # 셸의 - 는 -- 와 같다(뒤에 피연산자가 없으면 표준 입력)
           *:-) st=2; continue ;;                       # 인터프리터의 - 는 표준 입력
           node:--eval|node:--print|node:--eval=|node:--print=) GD_PK=string; GD_PF=${GD_T[$j]:-}; st=2; continue ;;
           *:-*=) j=$((j + 1)); continue ;;             # --opt=값(토큰이 둘로 나뉜다)
           node:--check|node:--test) GD_PN=1; continue ;;
           *:--*) gd_ro "$t" "$vals" && j=$((j + 1)); continue ;;
           sh:+?*) case $t in *[oO]*) j=$((j + 1)) ;; esac; continue ;;
           *:-?*) r=${t#-}
             while [ -n "$r" ]; do c=${r:0:1}; r=${r#?}
               case $k:$c in
                 sh:c|node:e|node:p) GD_PK=string; GD_PF=${GD_T[$j]:-}; j=$((j + 1)); st=2; break ;;
                 py:c|perl:e|perl:E|ruby:e) GD_PK=string; if [ -n "$r" ]; then GD_PF=$r; else GD_PF=${GD_T[$j]:-}; j=$((j + 1)); fi; st=2; break ;;
                 py:m) GD_PK=module; if [ -n "$r" ]; then v=$r; else v=${GD_T[$j]:-}; j=$((j + 1)); fi
                   case $v in py_compile|compileall|pytest) GD_PN=1 ;; esac; st=3; break ;;
                 sh:o|sh:O) j=$((j + 1)) ;;
                 sh:s) sf=1 ;;
                 sh:n|node:c|perl:c|ruby:c) GD_PN=1 ;;
                 py:W|py:X|node:r|node:C|ruby:I|ruby:r|ruby:C|ruby:E) [ -n "$r" ] || { case ${GD_T[$j]:-} in [A-Za-z_]*=) j=$((j + 2)) ;; *) j=$((j + 1)) ;; esac; }; break ;;
                 perl:l|perl:0) r=${r#"${r%%[!0-9]*}"} ;;   # 붙은 8진수 값
                 perl:[IMmxidDFC]|ruby:[xFKTW0]) break ;;    # 붙여 쓰는 값(단어의 나머지)
               esac
             done
             continue ;;
         esac ;;
    esac
    if [ "$sf" -eq 0 ] && [ "$t" != - ] && ! gd_stdin_dev "$t"; then GD_PK=file; GD_PF=$t; fi   # 셸 -s 뒤는 위치 매개변수
    st=2
  done
  # 피연산자 뒤 [j,e) 에는 입력 리디렉션만 의미가 있다(I3). 원문에 < 가 없으면 볼 것이 없고, 있으면 for 로 한 번만 훑는다
  # (bash 3.2 의 배열 인덱스 접근은 앞에서부터 세므로 긴 세그먼트를 인덱스로 끝까지 돌면 제곱 비용)
  if [ "$st" -eq 2 ] && [ "$j" -lt "$e" ]; then case ${GD_R[${i:-0}]} in *'<'*) gd_prog_tail ;; esac; fi
  GD_PC="${i:-}:$k"; GD_PCV="$GD_PK"$'\t'"$GD_PF"$'\t'"$GD_PI"$'\t'"$GD_PW"$'\t'"$GD_PN"
  return 0
}
gd_prog_tail() {  # gd_prog 의 피연산자 뒤 토큰 [j,e) 에서 입력 리디렉션만 본다(위 순회의 리디렉션 분기와 같은 규칙; 끝의 값 단어는 다음 토큰)
  local t v pend=""
  for t in "${GD_T[@]:$j:$((e - j))}"; do
    if [ -n "$pend" ]; then   # 바로 앞 연산자의 값 단어
      case $pend in here) GD_PW=$t ;; in) gd_stdin_dev "$t" || { GD_PI=file; GD_PW=$t; } ;; esac
      pend=""; continue
    fi
    case $t in *'<'*|*'>'*) ;; *) continue ;; esac   # 리디렉션 단어만(아래 패턴은 모두 < 나 > 를 담는다)
    case $t in
      '<('*|'>('*) ;;
      '<<<') GD_PI=here; pend=here ;;
      '<<<'*) GD_PI=here; GD_PW=${t#<<<} ;;
      '<<'*) GD_PI=heredoc ;;
      '<&0'|'0<&0') ;;
      '<&'*|'0<&'*) GD_PI=other ;;
      '<'|'0<') pend=in ;;
      '<'*|'0<'*) v=${t#0}; v=${v#<}; gd_stdin_dev "$v" || { GD_PI=file; GD_PW=$v; } ;;
      [1-9]'<'|*'>'|*'>&'|*'>|') pend=skip ;;
    esac
  done
  case $pend in
    here) GD_PW=${GD_T[$e]:-} ;;
    in) v=${GD_T[$e]:-}; gd_stdin_dev "$v" || { GD_PI=file; GD_PW=$v; } ;;
  esac
}
gd_prog_stdin() { [ "$GD_PK" = stdin ] && [ -z "$GD_PI" ] && [ "$GD_PN" -eq 0 ]; }   # gd_prog 결과: 물려받은 표준 입력(파이프)을 프로그램으로 읽는가
gd_prog_sub() {  # gd_prog 결과로, 인터프리터가 치환의 출력을 프로그램으로 실행하는가(python3 <(curl …), -c "$(curl …)", < <(…), <<< "$(…)")
  case $GD_PK in
    file) case $GD_PF in '<('*) return 0 ;; esac ;;
    string) [ "$GD_PF" = "$GD_PH" ] && return 0 ;;
    stdin) case $GD_PI in file) case $GD_PW in '<('*) return 0 ;; esac ;; here) [ "$GD_PW" = "$GD_PH" ] && return 0 ;; esac ;;
  esac
  return 1
}
gd_deploy_name() {  # <이름> <script|target> — 배포 이름인가(r2): 단어 앞뒤가 경계(. _ -, 타깃은 : 도)이거나 이름의 처음·끝. prod·production 은
  # 맨 앞만. 스크립트는 테스트 파일(test_* *.test *.spec, 그리고 앞부분이 한 단어인 *_test *_spec), 타깃은 첫 구성 요소가 test·lint·check 등이면 아니다
  local w='(deploy|release|publish|rollback|destroy|promote|ship)' b='[._-]' re1 re2
  if [ "$2" = target ]; then
    case ${1%%[._:-]*} in test|tests|lint|check|typecheck|fmt|format|spec|e2e) return 1 ;; esac
    b='[._:-]'
  else
    case $1 in test_*|*.test|*.spec) return 1 ;; *_test|*_spec) case ${1%_*} in *[._-]*) ;; *) return 1 ;; esac ;; esac   # I2: *_test·*_spec 는 앞부분이 한 단어일 때만(deploy_and_test 는 배포)
  fi
  re1="(^|$b)$w($b|\$)"; re2="^(prod|production)($b|\$)"
  [[ $1 =~ $re1 ]] || [[ $1 =~ $re2 ]]
}
GD_TGT=""
gd_run_target() {  # <" -opt … "> — make·just·rake·task 의 첫 타깃을 원문 단어로 찾는다(I4): 옵션(값 포함)과 KEY=VALUE 대입(값이 비어도)을
  # 건너뛴다. 토큰은 KEY=VALUE 를 둘로 나누므로(값이 비면 하나) 첫 토큰이 대입일 때만 부른다(awk 1회, 명령 치환 + heredoc)
  local w n=0 skip=0 dd=0 ws numv=${2:-} mn=0
  GD_TGT=""; gd_afork || return 0; ws=$(sp_words "$S_R")   # R5: 분석 fork 상한(guard-destructive.sh)
  while IFS= read -r w; do
    n=$((n + 1)); [ "$n" -eq 1 ] && continue          # 머리(make)
    if [ "$mn" -eq 1 ]; then mn=0; gd_numval "$w" && continue; fi   # 앞이 -j/-l 류: 이 단어가 값(gd_numval)이면 먹고, 아니면 타깃 후보로(R4 task3)
    [ "$skip" -eq 1 ] && { skip=0; continue; }
    if [ "$dd" -eq 0 ]; then
      case $w in --) dd=1; continue ;; -*=*) continue ;;
        -*) case " $numv " in *" $w "*) mn=1; continue ;; esac; case $1 in *" $w "*) skip=1 ;; esac; continue ;; esac
    fi
    case $w in [A-Za-z_]*=*) case ${w%%=*} in *[!A-Za-z0-9_]*) ;; *) continue ;; esac ;; esac
    GD_TGT=$w; return 0
  done <<GDEOF
$ws
GDEOF
  return 0
}
gd_deploy_runner() {   # 배포 타깃(make·npm run …)과 배포 스크립트(이름에서 확장자를 뗀 것; 셸·python·node 는 gd_prog 로 찾은 스크립트 인수)
  local tgt="" base="" k="" vals="" numv=""
  case $S_HEAD in
    make) vals=' -C -f -I -o -W --directory --file --include-dir '; numv=' -j --jobs -l --load-average ' ;;   # I4/4c: -e(불리언)는 값 목록에서 뺀다. R4 task3: -j/--jobs/-l/--load-average 는 다음 단어가 숫자이거나 $ 로 시작하는 펼침($(nproc)·$N)일 때만 값으로 먹는다(make -j deploy 의 deploy 는 타깃)
    just|task|rake|invoke|inv) vals=' -f -d --justfile --working-directory --taskfile -r --rakefile -c --collection ' ;;
  esac
  case $S_HEAD in
    make|just|task|rake|invoke|inv) gd_subwords "$vals" "$numv"; tgt=$SW1
      case $tgt in [A-Za-z_]*=) case ${tgt%=} in *[!A-Za-z0-9_]*) ;; *) gd_run_target "$vals" "$numv"; tgt=$GD_TGT ;; esac ;; esac ;;   # I4: make ENV=production deploy
    npm) gd_subwords ' --prefix -C --workspace -w '; case $SW1 in run|run-script) tgt=$SW2 ;; esac ;;
    pnpm|yarn|bun) gd_subwords ' -C --dir --filter -F --cwd '; case $SW1 in run) tgt=$SW2 ;; *) tgt=$SW1 ;; esac ;;
  esac
  [ -n "$tgt" ] && gd_deploy_name "$tgt" target && gd_shit 2 deploy-runner "배포/릴리스 작업 실행($S_HEAD $tgt)"
  case $S_HEAD in
    */*) base=${S_HEAD##*/}
      case $base in   # I4: 경로가 붙은 인터프리터(.venv/bin/python, /opt/…/python3.12)는 이름으로 아래 인터프리터 규칙
        bash|sh|zsh|dash|ksh) k=sh ;; python|python[0-9]*) k=py ;; node) k=node ;;
        *) gd_deploy_name "${base%.*}" script && gd_shit 2 deploy-runner "배포 스크립트 실행($S_HEAD)"; return 0 ;;
      esac ;;
    bash|sh|zsh|dash|ksh) k=sh ;;
    python|python[0-9]*) k=py ;;
    node) k=node ;;
    deploy|release|publish|rollback|destroy) gd_shit 2 deploy-runner "배포/릴리스 작업 실행($S_HEAD)"; return 0 ;;
    *) return 0 ;;
  esac
  gd_prog "$k"
  [ "$GD_PN" -eq 1 ] && return 0                         # 실행하지 않는 문법 검사·테스트 러너
  case $GD_PK in
    file) tgt=$GD_PF ;;
    module) case $GD_PF in */*|*.sh|*.py|*.js) tgt=$GD_PF ;; *) tgt="" ;; esac ;;   # python -m pdb <스크립트>
    stdin) tgt=""; [ "$GD_PI" = file ] && case $GD_PW in '<('*) ;; *) tgt=$GD_PW ;; esac ;;   # bash < deploy.sh
    *) tgt="" ;;
  esac
  [ -n "$tgt" ] || return 0
  base=${tgt##*/}; gd_deploy_name "${base%.*}" script && gd_shit 2 deploy-runner "배포 스크립트 실행($tgt)"
  return 0
}
gd_publish() {  # npm·pnpm·bun·yarn 은 전역 옵션 뒤의 하위 명령으로 판단한다(F11: npm -w x publish, pnpm -r publish, yarn workspace x npm publish)
  case $S_HEAD in
    npm) gd_subwords ' --prefix -C -w --workspace --registry --userconfig --cache --tag --access --otp --loglevel ' ;;
    pnpm|bun) gd_subwords ' -C --dir --filter -F --cwd --registry --tag --access --otp ' ;;
    yarn) gd_subwords ' --cwd --include --exclude --from '
      if [ "$SW1" = workspace ] || [ "$SW1 $SW2" = "workspaces foreach" ]; then SW1=$SW3; SW2=$SW4; fi   # yarn workspace <이름> <명령…>
      [ "$SW1" = npm ] && SW1=$SW2 ;;                                                                   # yarn npm publish(berry)
    *) case $S_M in 'twine upload'*|'uv publish'*|'poetry publish'*|'gem push'*|'cargo publish'*|'flit publish'*|'hatch publish'*) gd_shit 2 publish "패키지 공개 배포" ;; esac
      return 0 ;;
  esac
  [ "$SW1" = publish ] && gd_shit 2 publish "패키지 공개 배포"
  return 0
}
gd_privilege() {
  local re1='^[ugoa]*\+[rwxXst]*s' re2='^[2-7][0-7][0-7][0-7]$' j t
  case $S_KIND in *sudo*) gd_shit 2 privilege "sudo/doas 권한 상승" ;; esac
  case $S_HEAD in
    su|sudo|doas) gd_shit 2 privilege "권한 상승($S_HEAD)" ;;
    chmod) if gd_short_has R || gd_has_tok --recursive; then gd_shit 2 privilege "재귀 권한 변경"; fi
      j=$((j0 + 1)); while [ "$j" -lt "$e" ]; do t=${GD_T[$j]}; j=$((j + 1))
        case $t in
          777) gd_shit 2 privilege "위험한 권한 모드($t)" ;;
          *+*s*) [[ $t =~ $re1 ]] && gd_shit 2 privilege "setuid/setgid 부여($t)" ;;
          [2-7][0-7][0-7][0-7]) [[ $t =~ $re2 ]] && gd_shit 2 privilege "setuid/setgid 모드($t)" ;;
        esac; done ;;
    chown|chgrp) if gd_short_has R || gd_has_tok --recursive; then gd_shit 2 privilege "재귀 소유자 변경"; fi ;;
    launchctl) case " $S_M " in *' load '*|*' unload '*|*' bootstrap '*|*' bootout '*) gd_shit 2 privilege "launchd 서비스 등록/해제" ;; esac ;;
    systemctl) case " $S_M " in *' start '*|*' stop '*|*' restart '*|*' enable '*|*' disable '*|*' mask '*|*' daemon-reload'*) gd_shit 2 privilege "시스템 서비스 변경" ;; esac ;;
    defaults) gd_has_tok write && gd_shit 2 privilege "시스템 기본값 변경(defaults write)" ;;
    csrutil|spctl|nvram|pmset|networksetup|dscl|visudo|at) gd_shit 2 privilege "시스템 설정 변경($S_HEAD)" ;;
    scutil) gd_has_tok --set && gd_shit 2 privilege "시스템 설정 변경(scutil --set)" ;;
    brew) gd_subwords ' --cask --formula '
      case "$SW1 $SW2" in 'services '|'services list'|'services info') return 0 ;; esac   # brew services [list|info] 는 읽기 전용
      case $SW1 in install|uninstall|upgrade|reinstall|link|unlink|services|remove|rm|tap|untap) gd_shit 2 privilege "전역 패키지 변경(brew $SW1)" ;; esac ;;
    npm) case " $S_M " in *' i '*|*' install '*|*' add '*) if gd_has_tok -g || gd_has_tok --global; then gd_shit 2 privilege "전역 패키지 설치(npm -g)"; fi ;; esac ;;
    pnpm) case " $S_M " in *' add '*|*' install '*|*' i '*) if gd_has_tok -g || gd_has_tok --global; then gd_shit 2 privilege "전역 패키지 설치(pnpm -g)"; fi ;; esac ;;
    yarn) case $S_M in 'yarn global add'*) gd_shit 2 privilege "전역 패키지 설치(yarn global)" ;; esac ;;
    pip|pip3|python|python3) gd_has_tok --break-system-packages && gd_shit 2 privilege "시스템 파이썬 패키지 변경" ;;
    pipx) case " $S_M " in *' install '*) gd_shit 2 privilege "전역 패키지 설치(pipx)" ;; esac ;;
    crontab) if gd_has_tok -e; then gd_shit 2 privilege "crontab 편집"; else
        j=$((j0 + 1)); while [ "$j" -lt "$e" ]; do case ${GD_T[$j]} in -*) ;; *) gd_shit 2 privilege "crontab 교체" ;; esac; j=$((j + 1)); done; fi ;;
  esac
}
gd_dataloss() {
  local j t
  case $S_HEAD in
    find|gfind) gd_has_tok -delete && gd_shit 2 data-loss-misc "find -delete"
      if gd_tok_after -exec || gd_tok_after -execdir; then case $GD_TA in rm|unlink|shred) gd_shit 2 data-loss-misc "find -exec rm" ;; esac; fi ;;
    shred) gd_shit 2 data-loss-misc "shred(복구 불가 삭제)" ;;
    truncate) if gd_has_tok -s0 || gd_has_tok --size=0 || { gd_tok_after -s && [ "$GD_TA" = 0 ]; } || { gd_tok_after --size= && [ "$GD_TA" = 0 ]; }; then
        j=$((j0 + 1)); while [ "$j" -lt "$e" ]; do t=${GD_T[$j]}; j=$((j + 1))
          case $t in -*|0) ;; /tmp/*|/private/tmp/*|/var/folders/*|'$TMPDIR'*) ;; *) gd_shit 2 data-loss-misc "파일 내용 비우기(truncate -s 0 $t)" ;; esac; done; fi ;;
  esac
}
