#!/usr/bin/env bash
# lib/guard-rules.sh — guard-destructive.sh 의 규칙 테이블(system/db/infra/deploy/publish/privilege/data-loss)
# guard-destructive.sh 가 source 한다. 세그먼트 컨텍스트(전역): S_KIND S_M(masked) S_R(raw) S_HEAD, 토큰 GD_T[j0..e), 세그먼트 번호 i
# gd_shit <sev> <rule> <why> : 1 ask-low, 2 ask-high, 3 deny (세그먼트 단위, 가장 심각한 것만 남음)

SW1=""; SW2=""; SW3=""; SW4=""; SWN=0; GD_TA=""
gd_subwords() {  # <" -flag -flag "> 값을 갖는 플래그를 건너뛰고 첫 4개 하위 명령어를 SW1..SW4 에 넣는다
  local vals=$1 j=$((j0 + 1)) t n=0 dd=0
  SW1=""; SW2=""; SW3=""; SW4=""
  while [ "$j" -lt "$e" ]; do
    t=${GD_T[$j]}; j=$((j + 1))
    if [ "$dd" -eq 0 ]; then
      case $t in
        --) dd=1; continue ;;
        -*=) j=$((j + 1)); continue ;;
        -*) case $vals in *" $t "*) j=$((j + 1)) ;; esac; continue ;;
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
    *'manage.py dbshell'*|*'manage.py flush'*|*'manage.py sqlflush'*|*'manage.py reset_db'*) gd_shit 2 db "DB 초기화/셸" ;;
    *'manage.py migrate'*|*'django-admin migrate'*) case " $S_M " in *' zero '*) gd_shit 2 db "마이그레이션 전체 되돌리기(zero)" ;; esac ;;
    *'prisma migrate reset'*|*'prisma db push'*--force-reset*|*'prisma db execute'*) gd_shit 2 db "Prisma DB 초기화/직접 실행" ;;
    *'alembic downgrade'*|*'flask db downgrade'*) case " $S_M " in *' --sql '*) ;; *) gd_shit 2 db "alembic downgrade" ;; esac ;;   # --sql: SQL 출력만(오프라인)
    *'db:drop'*|*'db:reset'*|*'db:schema:load'*|*'db:purge'*|*'db:rollback'*|*'db:migrate:reset'*|*'db:migrate:undo'*|*'db:migrate:down'*|*'db:wipe'*) gd_shit 2 db "DB 삭제/초기화/마이그레이션 롤백($S_HEAD)" ;;
    *'knex migrate:rollback'*|*'knex migrate:down'*|*'typeorm schema:drop'*|*'migration:revert'*|*'mikro-orm migration:down'*|*'mikro-orm schema:drop'*) gd_shit 2 db "마이그레이션 롤백/스키마 삭제" ;;
    *flyway*' clean'*|*'goose down'*|*'goose '*' down'*|*'goose reset'*|*'goose '*' reset'*|*'dbmate drop'*|*'dbmate '*' drop'*|*'dbmate rollback'*|*'dbmate '*' rollback'*|*'dbmate down'*|*'dbmate '*' down'*|*'sqlx database drop'*|*'sqlx migrate revert'*|*'atlas schema clean'*|*'drizzle-kit drop'*|*'supabase db reset'*|*liquibase*' rollback'*|*liquibase*' dropall'*|*liquibase*' drop-all'*) gd_shit 2 db "마이그레이션 롤백/스키마 삭제($S_HEAD)" ;;
    *'artisan migrate:fresh'*|*'artisan migrate:reset'*|*'artisan migrate:rollback'*|*'artisan migrate:refresh'*) gd_shit 2 db "Laravel DB 초기화/롤백" ;;
  esac
}

gd_ro() {  # <word> <" a b c "> — word 가 목록에 있으면 0
  [ -n "$1" ] && case $2 in *" $1 "*) return 0 ;; esac; return 1
}
gd_infra() {
  local w
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
      gd_ro "$SW1" ' list ls status get history show template lint search version env help ' && return 0
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
      case "$SW1 $SW2" in 's3 ls'|'s3 presign'|'sts get-caller-identity'|'configure list'|'configure get'|'help '|'configure list-profiles') return 0 ;; esac
      case $SW2 in describe-*|get-*|list-*|ls|head-*|lookup-*|search-*|query|scan|help|wait|batch-get-*|validate-*|check-*|test-*|estimate-*|preview-*|simulate-*) return 0 ;; esac
      gd_shit 2 infra-write "인프라/클라우드 쓰기 작업(aws $SW1 $SW2)" ;;
    gcloud) gd_subwords ' --project --account --configuration --format --filter --impersonate-service-account --billing-project --zone --region --verbosity --limit --sort-by --flags-file '
      for w in "$SW1" "$SW2" "$SW3" "$SW4"; do case $w in list|describe|get|print-*|info|version|topic|help|get-*|get-iam-policy) return 0 ;; esac; done
      case "$SW1 $SW2" in 'config list'|'auth list'|'config get-value'|'auth print-access-token'|'auth print-identity-token') return 0 ;; esac
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
gd_gh() {
  local j m
  gd_subwords ' -R --repo -H --hostname -t --template -q --jq -F --field -f --raw-field -X --method --input -H --header -b --body -B --base -c --cwd '
  case "$SW1 $SW2" in
    'release create'|'release upload') gd_shit 2 publish "GitHub 릴리스 생성/업로드" ;;
    'release delete'|'release edit'|'release delete-asset'|'repo delete'|'repo edit'|'repo rename'|'repo archive'|'repo unarchive'|'repo sync'|'pr merge'|'secret set'|'secret delete'|'secret remove'|'variable set'|'variable delete'|'workflow run'|'workflow enable'|'workflow disable'|'auth logout') gd_shit 2 infra-write "GitHub 쓰기 작업(gh $SW1 $SW2)" ;;
    'api '*) j=$((j0 + 1))
      while [ "$j" -lt "$e" ]; do
        case ${GD_T[$j]} in
          -X|--method) m=${GD_T[$((j + 1))]:-} ;; --method=|-X=) m=${GD_T[$((j + 1))]:-} ;;
          -f|-F|--field|--raw-field|--input|--field=|--raw-field=|--input=) m=POST ;;
        esac
        j=$((j + 1))
      done
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
gd_deploy_runner() {
  local tgt="" base="" re='^(deploy|release|publish|prod|production|rollback|destroy|promote|ship)([:_-]|$)' sre='(deploy|release|publish|rollback|destroy|prod)'
  case $S_HEAD in
    make) gd_subwords ' -C -f -j -I -o -W -e --directory --file --jobs --include-dir '; tgt=$SW1 ;;
    just|task|rake|invoke|inv) gd_subwords ' -f -d --justfile --working-directory --taskfile -r --rakefile -c --collection '; tgt=$SW1 ;;
    npm) gd_subwords ' --prefix -C --workspace -w '; case $SW1 in run|run-script) tgt=$SW2 ;; esac ;;
    pnpm|yarn|bun) gd_subwords ' -C --dir --filter -F --cwd '; case $SW1 in run) tgt=$SW2 ;; *) tgt=$SW1 ;; esac ;;
  esac
  [ -n "$tgt" ] && [[ $tgt =~ $re ]] && gd_shit 2 deploy-runner "배포/릴리스 작업 실행($S_HEAD $tgt)"
  case $S_HEAD in
    */*) base=${S_HEAD##*/}; [[ $base =~ $sre ]] && gd_shit 2 deploy-runner "배포 스크립트 실행($S_HEAD)" ;;
    bash|sh|zsh|python|python3|node) gd_subwords ' -c -e -m '; base=${SW1##*/}
      case $SW1 in */*|*.sh|*.py|*.js) [[ $base =~ $sre ]] && gd_shit 2 deploy-runner "배포 스크립트 실행($SW1)" ;; esac ;;
    deploy|release|publish|rollback|destroy) gd_shit 2 deploy-runner "배포/릴리스 작업 실행($S_HEAD)" ;;
  esac
  return 0
}
gd_publish() {
  case $S_M in
    'npm publish'*|'yarn publish'*|'yarn npm publish'*|'pnpm publish'*|'twine upload'*|'uv publish'*|'poetry publish'*|'gem push'*|'cargo publish'*|'flit publish'*|'hatch publish'*)
      gd_shit 2 publish "패키지 공개 배포" ;;
  esac
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
    brew) gd_subwords ' --cask --formula '; case $SW1 in install|uninstall|upgrade|reinstall|link|unlink|services|remove|rm|tap|untap) gd_shit 2 privilege "전역 패키지 변경(brew $SW1)" ;; esac ;;
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
