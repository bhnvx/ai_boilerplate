#!/usr/bin/env bash
# guard-destructive.sh — PreToolUse(Bash|Monitor): 파괴적 명령 차단/확인. 결정은 stdout JSON + exit 0 만.
# 끄기: CLAUDE_GUARD_DESTRUCTIVE=off
# 설정: CLAUDE_GUARD_PROTECTED_BRANCHES(쉼표/공백 목록, 글롭 가능; 미설정이면 "main master"; none(대소문자 무관)·빈 값=브랜치 규칙 전부 끔
#         — lib/common.sh hook_is_protected_branch 가 단일 구현; D11), CLAUDE_GUARD_ASK_ON_PUSH(protected|1|0),
#       CLAUDE_GUARD_ALLOW_PATTERNS(ERE 대안을 | 로 연결; ^(…)$ 로 감싸 세그먼트의 MASKED 형태(따옴표 안 문자열은 "Q"·'Q')에 대조;
#         맞으면 그 세그먼트의 ASK 를 없앤다(결정 없음 → 일반 권한 규칙). DENY·명령 전체 규칙(pipe-to-shell 등)은 불변, 이 훅에만 적용)
# 규칙 id: destructive:rm-root rm-git rm-system rm-recursive rm-glob rm-xargs system git-force-protected git-no-verify git-hooks-bypass
#          git-push-protected git-push git-force git-protected-write git-history git-amend git-reset-hard git-checkout-force git-restore
#          git-clean git-stash-drop git-branch-delete git-tag-delete git-remote git-worktree db infra-write remote deploy-runner publish
#          privilege pipe-to-shell data-loss-misc
GD_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
. "$GD_DIR/lib/common.sh"
hook_off CLAUDE_GUARD_DESTRUCTIVE && exit 0
hook_read_input
hook_require_pretooluse
case $H_TOOL in Bash|Monitor) ;; *) exit 0 ;; esac    # D5: Monitor 는 Bash 와 같은 권한 규칙으로 명령을 실행한다(ws 감시는 command 가 비어 통과)
[ -n "$H_CMD" ] || exit 0
GD_LOW=$(hook_lower "$H_CMD")
GD_PRE=$(printf '%s' "$GD_LOW" | LC_ALL=C tr -d "\"'\\\\")   # G7: "rm"·r''m·r\m 도 프리필터를 통과하도록 따옴표·역슬래시 제거(tr 1회 — bash 3.2 의 ${x//…} 는 긴 문자열에서 2차 비용)
case $GD_PRE in
  *'rm '*|*rmdir*|*'git '*|*kubectl*|*'helm '*|*terraform*|*terragrunt*|*tofu*|*pulumi*|*'aws '*|*gcloud*|*'az '*|*docker*|*'ssh '*|*'scp '*|*sftp*|*rsync*|*sudo*|*doas*|*chmod*|*chown*|*mkfs*|*'dd '*|*shutdown*|*reboot*|*halt*|*poweroff*|*kill*|*crontab*|*launchctl*|*systemctl*|*'defaults write'*|*diskutil*|*csrutil*|*spctl*|*nvram*|*pmset*|*networksetup*|*'brew '*|*'npm '*|*'pnpm '*|*'yarn '*|*'bun '*|*'pip '*|*pipx*|*twine*|*'poetry publish'*|*'uv publish'*|*'cargo publish'*|*'gem push'*|*'gh '*|*vercel*|*netlify*|*'fly '*|*flyctl*|*heroku*|*serverless*|*'sls '*|*'sam '*|*'cdk '*|*wrangler*|*ansible*|*'fab '*|*'cap '*|*'make '*|*'just '*|*'task '*|*rake*|*invoke*|*'drop '*|*truncate*|*'delete '*|*'alter '*|*manage.py*|*prisma*|*alembic*|*rails*|*knex*|*redis-cli*|*mongo*|*psql*|*mysql*|*sqlite3*|*dropdb*|*dropuser*|*curl*|*wget*|*eval*|*'sh -c'*|*history*|*'find '*|*shred*|*'> /dev'*|*/dev/*|*':(){'*|*.git*|*deploy*|*release*|*publish*|*rollback*|*destroy*|*prod*|*'su '*|*'su'|*scutil*|*dscl*|*visudo*|*'at '*|*flush*|*flyway*|*goose*|*dbmate*|*sqlx*|*'atlas '*|*artisan*|*supabase*|*sequelize*|*typeorm*|*drizzle*|*liquibase*|*mikro-orm*|*'db:'*|*'migrate:'*|*'migration:'*|*'grm '*|*rimraf*|*gnubin*|*'gfind '*|*downgrade*|*'db reset'*|*'db wipe'*|*'schema clean'*|*railway*|*amplify*|*kamal*|*'cf '*|*zappa*|*urllib*|*requests*|*promote*|*ship*|*'migrate '*|*migrate/migrate*) ;;
  *) exit 0 ;;
esac
. "$GD_DIR/lib/shellparse.sh"
. "$GD_DIR/lib/guard-rules.sh"

hook_protected_branches; GD_PROT=$HOOK_PROT              # D11: 빈 값이면 브랜치 규칙 끔
GD_ASK_PUSH=${CLAUDE_GUARD_ASK_ON_PUSH:-protected}
GD_ALLOW_RE=${CLAUDE_GUARD_ALLOW_PATTERNS:-}; [ -n "$GD_ALLOW_RE" ] && GD_ALLOW_RE="^($GD_ALLOW_RE)\$"
GD_EFF=${H_CWD:-$PWD}; GD_EFF_UNKNOWN=0; GD_PREV=""; GD_DIRSTACK=""; GD_BRANCH_ASSUMED=""; GD_BR=""; GD_BR_DIR=""; GD_BR_CACHE=""; GD_BR_DONE=0; GD_HOOKS_BYPASS=0
GD_SP=0; GD_S_EFF=(); GD_S_UNK=(); GD_S_BR=(); GD_S_DS=(); GD_S_PREV=(); GD_S_KB=()   # 서브셸·명령 치환 안의 cd 가 밖으로 새지 않도록 하는 상태 스택(G10)
GD_SB=(); GD_SE=()   # 세그먼트 i 앞에서 저장(GD_SB[i] 번)·뒤에서 복원(GD_SE[i] 번): 명령 문자열(bash -c '…' 등) 펼침의 처음·끝(I6)
GD_XB=(); GD_XE=()   # R6: 펼친 문자열(eval 포함)마다 처음·끝 세그먼트에서 센다 — gd_pipe_shell 이 펼침 뒤에 그 문자열을 가진 명령의 상태(last)를 되돌린다
GD_FX=(); GD_FXO=(); GD_FXN=(); GD_FXR=0   # find -exec 셸 문자열 펼침: GD_FX[i]=find 세그먼트:몇 번째 문자열(가장 안쪽 find), GD_FXO[i]=가장 바깥 find(겹칠 때만; R6), GD_FXN[find]=문자열 수(I8)
GD_FWI=""; GD_FSS=""; GD_FNS=0; GD_FJS=1; GD_FJC=1; GD_FXC=0; GD_FBAD=0; GD_FA=(); GD_FA10=(); GD_FAN=(); GD_FP=()   # find 세그먼트 표(한 번만 만든다; I8·성능): 시작 디렉터리·깊이 플래그·순번별 인수(전체·처음 10개·개수)
GD_FDK=""; GD_FD=""; GD_FDN=0; GD_FDB=0   # $@·$* 가 넘기는 서로 다른 인수 패턴(그룹마다 한 번만 만든다; 대상마다 인수 전체를 다시 읽지 않게)
GD_FWORDCAP=4000; GD_FWORKCAP=200; GD_FWORK=0   # find 단어·명령 전체 판단 작업량 상한(넘으면 원래 규칙(rec 면 deny) + find -exec rm 과 같은 ask-high; I8 지연·fail-open 방지). 실제 find 는 시작 디렉터리가 1~5개뿐이라 이 상한은 합성 스트레스 입력에만 걸린다(상한은 gd_rm_target 호출 수 = 판단 비용을 유계로 묶는다)
GD_SEV=0; GD_RULE=""; GD_WHY=""; GD_EX=""     # 전체 결정(deny 3 > ask-high 2 > ask-low 1 > 0)
GD_OVERFLOW=0; GD_FORKS=0; GD_FORKCAP=200      # R5: 330 → 200(gawk 는 awk 1회가 약 10 ms — 330개 + 분석 fork 가 유휴에도 5~6초). R4 task2: 파서 overflow 레코드 + sub 재파싱(awk fork) 상한. 셸 문자열이 아주 많으면 fork 비용이 10초 제한을 넘기므로 상한 뒤 문자열은 다시 파싱하지 않고 한 세그먼트로 판정하고 too-complex 를 바닥으로 둔다(코퍼스는 sub 가 많아야 1~2개)
# R5 작업 상한(넘으면 받은 부분만 판정하고 too-complex 바닥): GD_SEGCAP 세그먼트 수(최상위 + 다시 파싱한 셸 문자열 전체 — 문자열마다 파서 상한을
# 새로 받지 않게 남은 몫만 넘긴다), GD_TOKCAP 토큰 수(bash 3.2 배열 접근은 위치에 비례해 세그먼트·토큰이 많으면 판정이 제곱으로 느려진다),
# GD_AFORKCAP 세그먼트 분석용 fork(git 하위 명령·단어 나누기·브랜치 조회·대입의 소문자 변환 — 하나가 수 ms), GD_RMCAP rm 대상 수.
# 코퍼스 최대는 레코드 15개·대상 몇 개라 정상 명령은 닿지 않는다. 그래도 느리면 hook_time_up(lib/common.sh)이 멈춘다
# GD_RPMAX 다시 파싱하는 문자열 글자 수 합(단어가 수만 개인 문자열은 파싱·토큰화가 단어 수의 제곱 — 남은 문자열은 한 세그먼트로), GD_BUNDLEMAX git commit 짧은 옵션 묶음 길이
GD_SEGCAP=2000; GD_TOKCAP=8000; GD_AFORKS=0; GD_AFORKCAP=100; GD_RMCAP=1000; GD_RPB=0; GD_RPMAX=98304; GD_BUNDLEMAX=256
GD_SUBMAX=4096   # R6 통합: 다시 파싱하지 않고 한 세그먼트로 두는 문자열은 앞 4096자만(머리로 판정 — 셸이 읽는 1 MB heredoc 본문을 통째로 토큰화하면
                 # 공용 파서의 단어 나누기가 BWK awk 에서 길이의 제곱이라 30초를 넘겨 판정 없이 통과했고, 토큰 상한을 다 써서 뒤 명령도 보지 못했다)
GD_DMAX=3   # R6(G-A): 셸 문자열을 다시 파싱하는 가장 깊은 깊이(최상위 0 — guard-migrations 와 같은 번호). 깊이 3 문자열 안의 문자열은 한 세그먼트(gd_sub)
S_SEV=0; S_RULE=""; S_WHY=""; S_KIND=""; S_M=""; S_R=""; S_HEAD=""
GD_N=0; GD_K=(); GD_M=(); GD_R=(); GD_HD=(); GD_T=(); GD_TS=(); GD_TE=(); GD_HEAD=""
GD_CP=""; GD_DOTS=0; GD_ISDOT=0

gd_shit() { [ "$1" -gt "$S_SEV" ] || return 0; S_SEV=$1; S_RULE=$2; S_WHY=$3; }
gd_merge() {  # 세그먼트 결정 → 전체 결정(허용 패턴은 ASK 만 없앤다). 발췌는 UTF-8 경계에서 자른다(C8)
  [ "$S_SEV" -gt 0 ] || return 0
  if [ "$S_SEV" -lt 3 ] && [ -n "$GD_ALLOW_RE" ] && [[ $S_M =~ $GD_ALLOW_RE ]]; then hook_debug "allow-pattern: $S_M"; S_SEV=0; return 0; fi
  if [ "$S_SEV" -gt "$GD_SEV" ]; then GD_SEV=$S_SEV; GD_RULE=$S_RULE; GD_WHY=$S_WHY; hook_excerpt "$S_M" 120; GD_EX=$HOOK_EX; fi
}
gd_head() { set -f; set -- $1; GD_HEAD=${1:-}; set +f; }
gd_add_seg() { GD_K[$GD_N]=$1; GD_M[$GD_N]=$2; GD_R[$GD_N]=$3; GD_HD[$GD_N]=$4; GD_N=$((GD_N + 1)); }
gd_afork() { [ "$GD_AFORKS" -lt "$GD_AFORKCAP" ] || { GD_OVERFLOW=1; return 1; }; GD_AFORKS=$((GD_AFORKS + 1)); }   # R5: 분석용 fork 를 한 번 더 써도 되면 0(센다). 넘으면 그 분석을 건너뛰고 too-complex 바닥
gd_wb() {  # R5: 다시 파싱할 셸 문자열에 줄 파서 상한(SP_WBMAX) — 세그먼트 상한의 남은 몫(테스트가 SP_WBMAX 로 더 낮췄으면 그것)
  GD_WB=$((GD_SEGCAP - GD_N)); [ "$GD_WB" -gt 0 ] || GD_WB=1
  case ${SP_WBMAX:-} in ''|*[!0-9]*) ;; *) [ "$SP_WBMAX" -lt "$GD_WB" ] && GD_WB=$SP_WBMAX ;; esac
}
gd_iso() { [ "$1" -le "$2" ] || return 0; GD_SB[$1]=$((${GD_SB[$1]:-0} + 1)); GD_SE[$2]=$((${GD_SE[$2]:-0} + 1)); }   # <처음> <끝> — 그 범위의 cd 를 밖에 남기지 않는다(I6)
gd_fxmark() {  # <처음> <끝> <find 세그먼트> <순번> — find -exec 셸 문자열을 펼친 세그먼트 표시(I8). 문자열 수는 펼친 세그먼트가 없어도 센다.
  # R6: find -exec 문자열 안에 또 find -exec 문자열이 있으면(안쪽이 먼저 끝나 먼저 표시된다) GD_FX 는 가장 안쪽 find(실제로 위치 매개변수를 넘기는 쪽),
  # GD_FXO 는 가장 바깥 find(예전 표시 — 바깥 표시가 덮어썼다)다. gd_rm_target 은 둘 다 풀릴 때만 위치 매개변수를 푼다(어느 쪽보다 약하지 않게)
  local x=$1; GD_FXN[$3]=$4
  while [ "$x" -le "$2" ]; do if [ -n "${GD_FX[$x]:-}" ]; then GD_FXO[$x]="$3:$4"; else GD_FX[$x]="$3:$4"; fi; x=$((x + 1)); done
}
gd_sub() {  # <raw> <masked> <바깥 명령 머리> <깊이> <find 세그먼트> <순번> — 셸 문자열(sub 줄: bash -c '…'·sh -c·su -c·ssh '…'·eval 과 실행기 문자열)을
  # 다시 파싱해 세그먼트로 넣는다. R6(G-A): 문자열 안의 문자열도 깊이 GD_DMAX 까지 같은 규칙으로 펼친다(guard-migrations gm_sub 와 같은 번호 — 최상위 0,
  # 최상위의 문자열 1, 그 안의 문자열 2, 3). 깊이 GD_DMAX 문자열을 파싱할 때는 SP_SUBFLAT=1 이라 그 안의 문자열(한 세그먼트로 남는다)의 개행·탭이
  # 공백이다([[:space:]] 정규식 — gd_sql_scan·gd_pipe_text — 이 줄을 넘어 맞는다). 깊이마다 그대로 지키는 것: eval 이 아닌 문자열은 새 셸이라 안의
  # cd 가 밖에 남지 않고(gd_iso; eval 은 같은 셸), find -exec 셸 문자열은 위치 매개변수를 풀 수 있게 표시하고(gd_fxmark; I8), 문자열 안의 heredoc 은
  # 그 줄의 머리(ihd)로 본다. 상한(GD_FORKCAP 문자열 수·GD_RPMAX 글자 수 합·GD_SEGCAP 세그먼트·작업 시간)은 모든 깊이가 함께 쓴다 — 넘은 문자열은
  # 다시 파싱하지 않고 한 세그먼트(RAW 의 개행은 파서가 낸 0x1E 그대로 — tr 을 더 부르지 않는다)로 판정하고 too-complex 가 바닥이다(앞의 판정은 그대로).
  # 문자열마다 < <(…) 를 쓰면 bash 3.2 가 약 250번째에서 죽어(rc 133) 판정 없이 통과한다 — 명령 치환 + heredoc(R11).
  # 반환 1 = 4096자를 넘는 머리라 보지 않았다(find -exec 순번을 세지 않는다 — 예전과 같다)
  local f so k m r sh="" ifx="" ifo=0 ihd=""
  if [ "$4" -gt "$GD_DMAX" ] || [ "$GD_FORKS" -ge "$GD_FORKCAP" ] || [ $((GD_RPB + ${#1})) -gt "$GD_RPMAX" ] || hook_time_up; then
    [ "$4" -gt "$GD_DMAX" ] || GD_OVERFLOW=1   # 가장 깊은 문자열 안의 문자열은 원래 한 세그먼트(상한이 아니다)
    if hook_longhead "$2"; then GD_OVERFLOW=1; return 1; fi
    if [ "${#1}" -gt "$GD_SUBMAX" ]; then GD_OVERFLOW=1; gd_add_seg sub "${2:0:$GD_SUBMAX}" "${1:0:$GD_SUBMAX}" ""   # 긴 문자열은 앞부분만(GD_SUBMAX) — 나머지는 too-complex 바닥
    else gd_add_seg sub "$2" "$1" ""; fi
    [ "$3" = eval ] || gd_iso $((GD_N - 1)) $((GD_N - 1))
    [ -n "$5" ] && gd_fxmark $((GD_N - 1)) $((GD_N - 1)) "$5" "$6"
    return 0
  fi
  GD_FORKS=$((GD_FORKS + 1)); GD_RPB=$((GD_RPB + ${#1})); f=$GD_N; gd_wb   # R5: 세그먼트 상한의 남은 몫만
  if [ "$4" -ge "$GD_DMAX" ]; then so=$(SP_SUBFLAT=1 SP_WBMAX=$GD_WB sp_segments "$1"); else so=$(SP_WBMAX=$GD_WB sp_segments "$1"); fi
  while IFS=$'\t' read -r k m r; do
    [ "$GD_N" -lt "$GD_SEGCAP" ] || { GD_OVERFLOW=1; break; }
    case $k in
      cmd*) if hook_longhead "$m"; then GD_OVERFLOW=1; sh=""; ifx=""; ihd=""; continue; fi
        gd_add_seg "$k" "$m" "$r" ""; sh=${m%% *}; case $sh in find|gfind) ifx=$((GD_N - 1)); ifo=0 ;; *) ifx="" ;; esac
        case $r in *'<<'*) gd_head "$m"; ihd=$GD_HEAD ;; esac ;;
      heredoc) gd_add_seg heredoc "$m" "$r" "$ihd" ;;   # R4: 문자열 안의 heredoc(개행이 살아 있어 본문이 생긴다)도 최상위처럼 SQL·셸 본문으로 검사(sh -c 'psql <<EOF …')
      sub) gd_sub "$r" "$m" "$sh" $(($4 + 1)) "$ifx" $((ifo + 1)) && ifo=$((ifo + 1)) ;;
      push|pop) gd_add_seg "$k" "$m" "$r" "" ;;
      overflow) GD_OVERFLOW=1 ;;   # R4 task2: 문자열 재파싱도 상한을 넘으면 다 분석하지 못함
    esac
  done <<GDSEOF
$so
GDSEOF
  [ "$3" = eval ] || gd_iso "$f" $((GD_N - 1))   # eval 은 같은 셸(cd 가 남는다)
  [ -n "$5" ] && gd_fxmark "$f" $((GD_N - 1)) "$5" "$6"
  if [ "$f" -lt "$GD_N" ]; then GD_XB[$f]=$((${GD_XB[$f]:-0} + 1)); GD_XE[$((GD_N - 1))]=$((${GD_XE[$((GD_N - 1))]:-0} + 1)); fi
  return 0
}
gd_collect() {   # 파서 줄 → 세그먼트. sub(셸 문자열)는 gd_sub 가 깊이 GD_DMAX 까지 펼친다(R6). find -exec 셸 문자열은 위치 매개변수를 풀 수 있게 표시한다(I8)
  local k m r hd="" a lh="" fx="" fo=0
  while IFS=$'\t' read -r k m r; do
    if [ "$GD_N" -ge "$GD_SEGCAP" ] || hook_time_up; then GD_OVERFLOW=1; break; fi   # R5: 세그먼트 상한·작업 시간 — 더 읽지 않는다
    case $k in
      cmd*) if hook_longhead "$m"; then GD_OVERFLOW=1; lh=""; fx=""; hd=""; continue; fi   # R5: 4096자를 넘는 명령 이름은 보지 않는다(lib/common.sh)
        gd_add_seg "$k" "$m" "$r" ""; lh=${m%% *}; case $r in *'<<'*) gd_head "$m"; hd=$GD_HEAD ;; esac
        case $lh in find|gfind) fx=$((GD_N - 1)); fo=0 ;; *) fx="" ;; esac ;;
      sub) gd_sub "$r" "$m" "$lh" 1 "$fx" $((fo + 1)) && fo=$((fo + 1)) ;;   # 최상위의 문자열은 깊이 1
      heredoc) gd_add_seg heredoc "$m" "$r" "$hd" ;;
      push|pop) gd_add_seg "$k" "$m" "$r" "" ;;
      assign) if gd_afork; then a=$(hook_lower "$r"); case $a in *husky=0*|*skip_hooks=*|*lefthook=0*|*skip_simple_git_hooks=*|*pre_commit_allow_no_config=*) GD_HOOKS_BYPASS=1 ;; esac; fi ;;   # R5: tr fork 도 분석 fork 상한에 센다
      overflow) GD_OVERFLOW=1; break ;;   # R4 task2: 파서 작업 상한 초과 — 더 읽지 않고 멈춘다(fork·세그먼트 비용 유계)
    esac
  done < <(sp_segments "$1")
}
gd_tokenize() {  # 세그먼트마다 한 줄씩 awk 1회로 토큰화(따옴표 상태가 세그먼트를 넘지 않음; C1). heredoc 본문·push/pop 은 토큰화하지 않음(C2)
  local i=0 s=0 n=0 buf="" toks t r rr=() trunc=0
  while [ "$i" -lt "$GD_N" ]; do
    case ${GD_K[$i]} in
      heredoc|push|pop) r="" ;;
      *) r=${GD_R[$i]}; case $r in *\\) r=${r%?} ;; esac ;;   # 끝의 역슬래시 제거(${r%\\} 는 bash 3.2 에서 길이의 제곱 비용)
    esac
    rr[$i]=$r; i=$((i + 1))
  done
  printf -v buf '%s\n' ${rr[@]+"${rr[@]}"}   # 세그먼트 원문을 한 번에 줄로 잇는다 — buf="$buf$r" 반복은 bash 에서 세그먼트 수의 제곱 비용(대상 수천 개면 10초; I/R4 task2)
  toks=$(sp_tokens_lines "${buf%$'\n'}" "" "$GD_TOKCAP")   # R5: 토큰 상한까지만 토큰화 — 넘으면 상한에 닿은 세그먼트까지만 나오고 끝에 __SP_TRUNC__
  case $toks in *$'\n'__SP_TRUNC__) trunc=1; GD_OVERFLOW=1 ;; esac
  set -f; IFS=$'\n'; GD_T=($toks); unset IFS; set +f
  GD_TS[0]=0
  if [ "${#GD_T[@]}" -gt 2000 ]; then                    # 긴 입력(I3): 경계 줄 번호를 grep 한 번으로(토큰마다 도는 bash 순회보다 빠름). 줄 = 토큰(빈 줄 없음)
    while IFS=: read -r n t; do [ -n "$n" ] || continue; GD_TE[$s]=$((n - 1)); s=$((s + 1)); GD_TS[$s]=$n; done <<GDEOF
$(printf '%s\n' "$toks" | grep -n -x -F __SP_SEG__)
GDEOF
    n=${#GD_T[@]}
  else
    for t in ${GD_T[@]+"${GD_T[@]}"}; do               # 순차 순회(bash 3.2 배열의 인덱스 접근은 O(n); G6)
      if [ "$t" = __SP_SEG__ ]; then GD_TE[$s]=$n; s=$((s + 1)); GD_TS[$s]=$((n + 1)); fi
      n=$((n + 1))
    done
  fi
  [ "$trunc" -eq 0 ] || GD_N=$s   # R5: 토큰 상한 — 상한에 닿은 세그먼트(그 앞 토큰까지)에서 끝내고 뒤 세그먼트는 보지 않는다(too-complex 바닥)
  while [ "$s" -lt "$GD_N" ]; do GD_TE[$s]=$n; s=$((s + 1)); GD_TS[$s]=$n; done
}

# gd_canon <path> → GD_CP(절대 경로, . 과 .. 을 텍스트로 해소), GD_DOTS(.. 만으로 된 상대 경로), GD_ISDOT(현재 디렉터리 자체)
gd_canon() {
  local p=$1 out="" c
  GD_DOTS=0; GD_ISDOT=0
  while :; do
    case $p in */'*') p=${p%/\*} ;; */.) p=${p%/.} ;; ?*/) p=${p%/} ;; *) break ;; esac
    [ -n "$p" ] || { p=/; break; }
  done
  case $p in '*'|.) GD_ISDOT=1; p=. ;; esac
  case $p in
    '~') p=$HOME ;; '~/'*) p=$HOME${p#\~} ;; '$HOME') p=$HOME ;; '$HOME/'*) p=$HOME${p#\$HOME} ;;
    '${HOME}') p=$HOME ;; '${HOME}/'*) p=$HOME${p#\$\{HOME\}} ;;
  esac
  case $p in
    /*) ;;
    *) c=${p//\//}; c=${c//./}; [ -z "$c" ] && [ "$GD_ISDOT" -eq 0 ] && GD_DOTS=1; p=$GD_EFF/$p ;;
  esac
  set -f; IFS=/; set -- $p; unset IFS; set +f
  for c in "$@"; do case $c in ''|.) ;; ..) out=${out%/*} ;; *) out=$out/$c ;; esac; done
  GD_CP=${out:-/}
}
gd_cd() {  # cd/pushd/popd 추적(G10): 이후 세그먼트의 유효 디렉터리. pushd/popd 는 스택, cd - 는 직전 디렉터리, 모르면 UNKNOWN
  local j=$((j0 + 1)) t="" prev=$GD_EFF pu=$GD_EFF_UNKNOWN
  if [ "$S_HEAD" = popd ]; then
    if [ -n "$GD_DIRSTACK" ]; then
      t=${GD_DIRSTACK%%$'\n'*}; GD_DIRSTACK=${GD_DIRSTACK#"$t"}; GD_DIRSTACK=${GD_DIRSTACK#$'\n'}
      GD_EFF_UNKNOWN=${t%%:*}; GD_EFF=${t#*:}
    else GD_EFF_UNKNOWN=1; fi
    GD_PREV=$prev; GD_BR_DONE=0; return 0
  fi
  while [ "$j" -lt "$e" ]; do case ${GD_T[$j]} in -) t=-; break ;; -*) ;; *) t=${GD_T[$j]}; break ;; esac; j=$((j + 1)); done
  case $t in
    '') if [ "$S_HEAD" = pushd ]; then GD_EFF_UNKNOWN=1; else GD_EFF=$HOME; GD_EFF_UNKNOWN=0; fi ;;
    '~') GD_EFF=$HOME; GD_EFF_UNKNOWN=0 ;;
    -) if [ -n "$GD_PREV" ]; then GD_EFF=$GD_PREV; GD_EFF_UNKNOWN=0; else GD_EFF_UNKNOWN=1; fi ;;
    '$'*) GD_EFF_UNKNOWN=1 ;;
    *) gd_canon "$t"; GD_EFF=$GD_CP; if [ -d "$GD_EFF" ]; then GD_EFF_UNKNOWN=0; else GD_EFF_UNKNOWN=1; fi ;;
  esac
  [ "$S_HEAD" = pushd ] && GD_DIRSTACK="$pu:$prev"$'\n'"$GD_DIRSTACK"
  GD_PREV=$prev; GD_BR_DONE=0
}
gd_push() {  # [1] — 서브셸·명령 치환 시작: 디렉터리 상태 저장. 1 이면(명령 문자열 펼침, I6) 브랜치 가정은 되돌리지 않는다
  # (git checkout 은 셸이 아니라 저장소 상태를 바꾸므로 bash -c 'git checkout main' 뒤에도 남는다)
  GD_SP=$((GD_SP + 1)); GD_S_EFF[$GD_SP]=$GD_EFF; GD_S_UNK[$GD_SP]=$GD_EFF_UNKNOWN; GD_S_BR[$GD_SP]=$GD_BRANCH_ASSUMED; GD_S_DS[$GD_SP]=$GD_DIRSTACK; GD_S_PREV[$GD_SP]=$GD_PREV
  GD_S_KB[$GD_SP]=${1:-0}
}
gd_pop() {  # 서브셸 끝: 안에서 한 cd 는 밖에 영향이 없다
  [ "$GD_SP" -gt 0 ] || return 0
  GD_EFF=${GD_S_EFF[$GD_SP]}; GD_EFF_UNKNOWN=${GD_S_UNK[$GD_SP]}; GD_DIRSTACK=${GD_S_DS[$GD_SP]}; GD_PREV=${GD_S_PREV[$GD_SP]}
  [ "${GD_S_KB[$GD_SP]:-0}" = 1 ] || GD_BRANCH_ASSUMED=${GD_S_BR[$GD_SP]}
  GD_SP=$((GD_SP - 1)); GD_BR_DONE=0
}
gd_is_toplevel() { [ -e "$GD_EFF/.git" ]; }   # 유효 디렉터리가 저장소 최상위(워크트리 포함)인가 — fork 없음
GD_TV_N=""; GD_TV_O=""; GD_TV_W=""; GD_TV_R=""
gd_tmpvar() {  # <target> — $TMPDIR·$TMP·$TEMP 로 시작하면 0. GD_TV_N 이름, GD_TV_O 연산자(중괄호 없음 '' · } · :- - := = :? ? :+ + %% % ## # // / ,, , ^^ ^ :),
  # GD_TV_W 연산자 뒤 단어, GD_TV_R 변수 뒤 나머지(짝 맞는 } 뒤 — 중첩 ${…} 를 센다; I7)
  local s=$1 d=1 c w=""
  GD_TV_O=""; GD_TV_W=""; GD_TV_R=""
  case $s in
    '$TMPDIR'*) GD_TV_N=TMPDIR; GD_TV_R=${s#\$TMPDIR}; return 0 ;;
    '$TEMP'*) GD_TV_N=TEMP; GD_TV_R=${s#\$TEMP}; return 0 ;;
    '$TMP'*) GD_TV_N=TMP; GD_TV_R=${s#\$TMP}; return 0 ;;
    '${TMPDIR'[}:?=+%#/,^-]*) GD_TV_N=TMPDIR; s=${s#??TMPDIR} ;;   # 이름 바로 뒤가 } 또는 연산자
    '${TEMP'[}:?=+%#/,^-]*) GD_TV_N=TEMP; s=${s#??TEMP} ;;
    '${TMP'[}:?=+%#/,^-]*) GD_TV_N=TMP; s=${s#??TMP} ;;
    *) return 1 ;;
  esac
  case $s in
    '}'*) GD_TV_O='}'; GD_TV_R=${s#?}; return 0 ;;
    :[-=?+]*|'%%'*|'##'*|'//'*|',,'*|'^^'*) GD_TV_O=${s:0:2}; s=${s:2} ;;
    *) GD_TV_O=${s:0:1}; s=${s:1} ;;
  esac
  [ "${#s}" -le 4096 ] || { GD_TV_W='$'; return 0; }   # 아주 긴 단어는 풀지 않는다(글자 그대로 기본값 아님 · 나머지 없음 = 임시 루트로 본다)
  while [ -n "$s" ]; do
    c=${s:0:1}; s=${s:1}
    case $c in
      '}') d=$((d - 1)); [ "$d" -eq 0 ] && break ;;
      '$') case $s in '{'*) d=$((d + 1)); w=$w'${'; s=${s:1}; continue ;; esac ;;
    esac
    w=$w$c
  done
  GD_TV_W=$w; GD_TV_R=$s
  return 0
}
gd_tmp_lit() {  # <단어> — 글자 그대로의 임시 경로(/tmp·/var/tmp·/private/tmp·/private/var/tmp 와 그 아래; 변수·치환·글롭·따옴표·.. 없음)인가(I7)
  case $1 in *'$'*|*'`'*|*..*|*[\*\?\[]*|*[[:space:]]*|*\'*|*\"*) return 1 ;; esac
  case ${1%/} in /tmp|/tmp/*|/var/tmp|/var/tmp/*|/private/tmp|/private/tmp/*|/private/var/tmp|/private/var/tmp/*) return 0 ;; esac
  return 1
}
gd_tmp_root() {  # (gd_tmpvar 결과) — 변수(연산자는 무엇이든) 뒤에 하위 경로가 없으면(빈 값·/·/*·/.·*) 0: 임시 루트 자체(r2·obs-3)
  local r=$GD_TV_R
  while :; do case $r in */\*) r=${r%/\*} ;; */.) r=${r%/.} ;; */) r=${r%/} ;; *) break ;; esac; done
  case $r in ''|'*') return 0 ;; esac
  return 1
}
gd_tmp_inside() {  # (gd_tmpvar 결과) — 값이 그 임시 디렉터리인 형태라 하위 경로를 조용히 통과해도 되는가.
  # $TMPDIR: 그대로(뒤가 이름 글자면 다른 변수 $TMPDIR_X)·${…}·${…:?}·${…?}·${…%/}·${…%%/}, 기본값·대입(:- - := =)은 기본값이 글자 그대로의
  # 임시 경로일 때만(I7). $TMP·$TEMP: $V/…·${V}·${V:?}·${V?}·${V%/} 만(r2b). 그 밖(:+ + # / , ^ : %…)은 값이 바뀐다
  case $GD_TV_N:$GD_TV_O in
    TMPDIR:) case $GD_TV_R in [A-Za-z0-9_]*) return 1 ;; esac; return 0 ;;
    TMP:|TEMP:) case $GD_TV_R in /*) return 0 ;; esac; return 1 ;;
    *:'}'|*:':?'|*:'?') return 0 ;;
    *:%) [ "$GD_TV_W" = / ] && return 0 ;;
    TMPDIR:%%) [ "$GD_TV_W" = / ] && return 0 ;;
    TMPDIR:':-'|TMPDIR:-|TMPDIR:':='|TMPDIR:=) gd_tmp_lit "$GD_TV_W" && return 0 ;;
  esac
  return 1
}
gd_rm_target() {  # <target> (rec/force 는 gd_rm 지역변수). 메시지는 원래 표기 p, 판단은 c(임시 루트 변수는 /tmp 로 바꿔 본다)
  local p=$1 c=$1 base cwd=${H_CWD:-$PWD}
  case $p in '$'[0-9@*]*|'${'[0-9@*]'}'*) [ -n "${GD_FX[${i:-0}]:-}" ] && [ "$GD_FXR" -eq 0 ] && gd_find_pos "$p" && { [ -z "${GD_FXO[${i:-0}]:-}" ] || gd_find_pos_o "$p"; } && return 0 ;; esac   # I8(R6: 겹친 find 는 바깥 쪽도)
  case $p in
    */..|*/../*) ;;                                                     # F13: .. 로 임시 경로를 벗어날 수 있으면 변수 지름길을 쓰지 않는다
    *) if gd_tmpvar "$p"; then
         if gd_tmp_root; then c=/tmp                                    # r2: 하위 경로 없는 임시 루트 변수는 rm -rf /tmp/* 와 같은 판단
         elif gd_tmp_inside; then return 0; fi                          # 임시 경로 안은 통과(값을 바꾸는 연산자·글자 그대로가 아닌 기본값은 일반 규칙)
       fi ;;
  esac
  case $c in
    '${'*':?'*|'${'*':-'*) ;;
    '$'*|'<('*) [ "$rec" -eq 1 ] && gd_shit 3 rm-root "미확장 변수·명령 치환 대상(값이 비면 루트/홈 삭제): $p"; return 0 ;;   # G1
  esac
  case ${c%/} in .git|*/.git) gd_shit 3 rm-git ".git 디렉터리 삭제: $p"; return 0 ;; esac
  gd_canon "$c"
  [ "$GD_DOTS" -eq 1 ] && { gd_shit 3 rm-root "상위 디렉터리 전체 삭제: $p"; return 0; }
  case $GD_CP in
    /|"$HOME") gd_shit 3 rm-root "루트/홈 디렉터리 삭제: $p"; return 0 ;;
    "$HOME"/*) case ${GD_CP#"$HOME"/} in */*) ;; *) gd_shit 3 rm-root "홈 바로 아래 디렉터리 삭제: $p"; return 0 ;; esac ;;   # C7: 패턴을 인용
  esac
  case $GD_CP in */.git|*/.git/*) gd_shit 3 rm-git ".git 디렉터리(또는 그 내부) 삭제: $p"; return 0 ;; esac   # G2: 정규화 후(.git/* .git/objects ../x/.git)
  case "$cwd/" in "$GD_CP"/?*) gd_shit 3 rm-root "현재 작업 디렉터리의 상위 디렉터리 삭제: $p"; return 0 ;; esac   # G2: 텍스트 비교(fork 없음) — 임시 경로여도 적용
  if [ "$GD_CP" = "$cwd" ] && [ -e "$GD_CP/.git" ]; then gd_shit 3 rm-root "저장소 최상위(현재 작업 디렉터리) 삭제: $p"; return 0; fi   # G2
  case $GD_CP in
    /usr|/etc|/var|/bin|/sbin|/lib|/lib64|/boot|/dev|/opt|/proc|/sys|/System|/Library|/Applications|/Users|/home|/private|/private/etc|/private/var|/root|/srv|/mnt|/media|/Volumes|/tmp|/var/tmp|/var/folders|/cores|/Network) gd_shit 3 rm-root "시스템 경로 삭제: $p"; return 0 ;;
    /System/*|/Library/*|/usr/*|/etc/*|/bin/*|/sbin/*|/boot/*|/dev/*|/proc/*|/sys/*|/private/etc/*) if [ "$rec" -eq 1 ]; then gd_shit 3 rm-root "시스템 경로 삭제: $p"; else gd_shit 2 rm-system "시스템 파일 삭제: $p"; fi; return 0 ;;
    /Users/*|/home/*) case ${GD_CP#/*/*/} in "$GD_CP") gd_shit 3 rm-root "사용자 홈 디렉터리 삭제: $p"; return 0 ;; esac ;;
  esac
  if [ "$GD_ISDOT" -eq 1 ]; then
    if [ "$GD_EFF_UNKNOWN" -eq 1 ] || [ "$GD_CP" = "$HOME" ] || gd_is_toplevel; then gd_shit 3 rm-root "현재 디렉터리 전체 삭제(저장소 최상위/홈/위치 불명): $p"
    else gd_shit 1 rm-recursive "현재 디렉터리 전체 삭제: $p"; fi
    return 0
  fi
  case $GD_CP in /tmp/?*|/private/tmp/?*|/var/folders/?*|/private/var/folders/?*|/var/tmp/?*|/private/var/tmp/?*)   # F13: 정규화한 경로가 임시 디렉터리 안(cd /tmp 포함)이면 조용히 통과.
    case "$GD_CP/" in "$cwd"/*) ;; *) return 0 ;; esac ;;   # 단, 작업 디렉터리(임시 경로에 둔 프로젝트) 안은 일반 규칙
  esac
  base=${GD_CP##*/}
  if [ "$rec" -eq 1 ]; then
    case $base in .*[\*\?\[]*) [ -e "${GD_CP%/*}/.git" ] && { gd_shit 3 rm-git ".git 과 일치할 수 있는 글롭 삭제(저장소 최상위): $p"; return 0; } ;; esac   # G2: .* .git* .g*
    case $base in
      node_modules|.venv|venv|.tox|dist|build|out|.next|.nuxt|.turbo|.cache|coverage|htmlcov|__pycache__|.pytest_cache|.mypy_cache|.ruff_cache|.parcel-cache|tmp|.tmp|site-packages|*.egg-info) return 0 ;;
    esac
    case $GD_CP in */target/debug|*/target/release|*/.gradle/caches) return 0 ;; esac
    gd_shit 1 rm-recursive "디렉터리 재귀 삭제: $p"
  else
    case $p in *'*'*|*'?'*) gd_shit 1 rm-glob "글롭 삭제: $p" ;; esac
  fi
}
gd_find_build() {  # <fx> — find 세그먼트의 원문 단어를 한 번만, 앞에서 뒤로 한 번 훑어 표를 만든다(I8·성능). bash 3.2 배열의 인덱스 접근은
  # 오름차순이어도 O(i)라(G6) 단어를 배열에 넣고 인덱스로 다시 읽으면 2차 비용이다 — 상태 기계로 읽고 -exec 그룹 단어만 모아 gd_find_group 에 넘긴다.
  # 시작 디렉터리(GD_FSS·GD_FNS)·깊이 플래그(GD_FJS 깊이 0 판단·GD_FJC 하위 판단)·순번별 인수(GD_FA·GD_FA10·GD_FAN)·{}+ 플래그(GD_FP)·
  # 문자열 수(GD_FXC)를 한 번에 만든다. 단어가 상한을 넘으면 GD_FBAD=1(그 세그먼트의 모든 대상은 원래 규칙으로 되돌린다)
  local fx=$1 ws w n=0 x=0 ph=0 pend="" g=0 gw gn=0 gp=""
  GD_FSS=""; GD_FNS=0; GD_FJS=1; GD_FJC=1; GD_FXC=0; GD_FBAD=0; GD_FA=(); GD_FA10=(); GD_FAN=(); GD_FP=(); GD_FWI=$fx; GD_FDK=""
  gd_afork || { GD_FBAD=1; return 0; }   # R5: 분석 fork 상한(넘으면 find 단어 상한을 넘은 것과 같게)
  ws=$(sp_words "${GD_R[$fx]}")
  while IFS= read -r w; do
    n=$((n + 1)); [ "$n" -le "$GD_FWORDCAP" ] || { GD_FBAD=1; return 0; }
    [ "$n" -eq 1 ] && continue                                   # find 자체
    if [ "$g" -eq 1 ]; then                                      # -exec 그룹 안: ; 또는 {} 바로 뒤의 + 까지 모은다
      if [ "$w" = ';' ] || { [ "$w" = + ] && [ "$gp" = '{}' ]; }; then gd_find_group "$w"; g=0
      else gw[$gn]=$w; gn=$((gn + 1)); gp=$w; fi
      continue
    fi
    case $pend in
      f) GD_FSS=$GD_FSS$w$'\n'; GD_FNS=$((GD_FNS + 1)); pend=""; continue ;;   # BSD -f <경로>
      D) pend=""; continue ;;
      maxdepth|mindepth)   # 값은 수일 때만 먹는다(여러 번 쓰면 마지막 값; 00 은 0)
        case $w in
          ''|*[!0-9]*) pend="" ;;
          *[1-9]*) [ "$pend" = maxdepth ] && GD_FJC=1 || GD_FJS=0; pend=""; continue ;;   # -maxdepth N≥1 → 하위도, -mindepth N≥1 → 깊이 0 은 넘기지 않음
          *) [ "$pend" = maxdepth ] && GD_FJC=0 || GD_FJS=1; pend=""; continue ;;        # -maxdepth 0 → 시작 디렉터리만, -mindepth 0 → 깊이 0 도
        esac ;;
    esac
    if [ "$ph" -eq 0 ]; then                                     # 시작 디렉터리 앞의 find 옵션
      case $w in -H|-L|-P|-E|-X|-s|-x|-d|-O*) continue ;; -D) pend=D; continue ;; -f) pend=f; continue ;; --) ph=1; continue ;; *) ph=1 ;; esac
    fi
    if [ "$ph" -eq 1 ]; then                                     # 시작 디렉터리: 첫 식 단어까지
      case $w in -*|'('|'!'|')'|,) ph=2 ;; *) GD_FSS=$GD_FSS$w$'\n'; GD_FNS=$((GD_FNS + 1)); continue ;; esac
    fi
    case $w in
      -maxdepth) pend=maxdepth ;; -mindepth) pend=mindepth ;;
      -exec|-execdir|-ok|-okdir) g=1; gw=(); gn=0; gp="" ;;
    esac
  done <<GDEOF
$ws
GDEOF
  [ "$g" -eq 1 ] && gd_find_group ""                            # 끝나지 않은 그룹(find 는 실행되지 않지만 파서의 셈과 맞춘다)
  [ -n "$GD_FSS" ] || { GD_FSS=.$'\n'; GD_FNS=1; }
  GD_FXC=$x
}
gd_find_group() {  # <종결어> — gd_find_build 가 모은 -exec 그룹 단어(지역변수 gw[0..gn))에서 셸 문자열의 인수를 뽑아 순번 x 에 넣는다.
  # 파서(xsubs)와 같은 규칙: 첫 단어가 셸, 마지막 단어 앞까지에서 글자만으로 된 c 포함 플래그(-c -ec …)의 첫 위치, 그 다음 단어(빈 문자열 아님)가
  # 셸 문자열, 그 뒤가 인수($0 $1 …). 인수는 줄 단위(빈 인수도 한 줄 — 위치가 밀리지 않게 개수로 읽는다)·처음 10개($0…$9)·개수.
  # for 순회 한 번과 printf -v 한 번(배열 조각 "${gw[@]:k}")만 쓴다 — 문자열에 한 단어씩 덧붙이면 bash 에서 길이의 제곱 비용이고,
  # bash 3.2 의 "${gw[*]:k}" 는 빈 원소를 \177 로 바꾸므로 쓰지 않는다
  local w c=0 k=-1 na al a10 t
  [ "$gn" -gt 0 ] || return 0
  case ${gw[0]##*/} in sh|bash|zsh|dash|ksh|mksh) ;; *) return 0 ;; esac
  for w in "${gw[@]}"; do
    if [ "$c" -ge 1 ] && [ "$c" -lt $((gn - 1)) ]; then case $w in -*[!A-Za-z]*) ;; -*c*) k=$c; break ;; esac; fi
    c=$((c + 1))
  done
  [ "$k" -ge 1 ] || return 0
  # 파서의 shstr 와 같게 -c 뒤 옵션을 건너뛴다(POSIX sh -c [옵션] 문자열): -c 묶음과 옵션의 o·O 글자마다 이름 1개, -x·+e 같은 옵션, 끝 표시 -- · -.
  # 건너뛰지 않으면 sh -c -- 'rm -rf "$1"' 의 위치 매개변수가 한 칸 밀려 ask-high 가 ask-low 가 됐다(R4 통합 검증)
  [ "${#gw[$k]}" -le "$GD_BUNDLEMAX" ] || { GD_FBAD=1; return 0; }   # R5: ${w//[!oO]/} 는 길이의 제곱(2만 자에 40초 넘게) — 아주 긴 옵션 묶음은 find 단어 상한과 같게(원래 규칙)
  t=${gw[$k]//[!oO]/}; k=$((k + ${#t}))
  while [ $((k + 1)) -lt "$gn" ]; do
    w=${gw[$((k + 1))]}
    case $w in
      --|-) k=$((k + 1)); break ;;
      [-+]*) case ${w#?} in ''|*[!A-Za-z]*) break ;; esac; [ "${#w}" -le "$GD_BUNDLEMAX" ] || { GD_FBAD=1; return 0; }; t=${w//[!oO]/}; k=$((k + 1 + ${#t})) ;;
      *) break ;;
    esac
  done
  [ $((k + 1)) -lt "$gn" ] || return 0
  [ -n "${gw[$((k + 1))]}" ] || return 0   # 셸 문자열(빈 문자열이면 파서도 세지 않는다)
  na=$((gn - k - 2)); al=""; a10=""
  if [ "$na" -gt 0 ]; then printf -v al '%s\n' "${gw[@]:$((k + 2))}"; printf -v a10 '%s\n' "${gw[@]:$((k + 2)):10}"; fi
  x=$((x + 1)); GD_FA[$x]=$al; GD_FA10[$x]=$a10; GD_FAN[$x]=$na
  [ "$1" = + ] && GD_FP[$x]=1 || GD_FP[$x]=0   # {} + 는 찾은 경로 여러 개로 펼쳐져 뒤 위치 매개변수를 채운다
}
gd_find_pos() {  # <대상> — find -exec 셸 문자열(GD_FX[i]) 안의 위치 매개변수($0…$9 ${N} $@ $*)를 find 가 넘기는 인수로 바꿔 판단한다(I8).
  # {} 는 find 가 찾은 경로다. find 는 -mindepth N(N>=1)이 없으면 시작 디렉터리 자체(깊이 0)도, -maxdepth 0 이 아니면 그 아래(<시작>/x)도 넘긴다.
  # 그래서 {} 는 <시작>(rm 이 거부하는 마지막 구성 요소 . .. 은 건너뜀. -r 없는 rm 이면 시작 디렉터리 그 자체도 건너뜀)과 <시작>/x 둘 다로
  # 판단하고, find -exec rm 과 같은 ask-high 를 더한다.
  # 그 밖의 인수는 글자 그대로. 표는 세그먼트마다 한 번만 만들고, 같은 패턴은 한 번만 판단하며, 문자열 수가 파서와 다르거나 인수가 없으면
  # 1(원래 규칙: 미확장 변수 → rec 면 deny). 작업량 상한을 넘으면 find -exec rm 과 같은 ask-high 를 남기고 1. 대상 하나의 비용은 인수 개수와
  # 무관하다($N 은 처음 10개에서, $@·$* 는 그룹마다 한 번 만든 목록에서 읽는다) — 대상 x 인수 의 2차 비용이 훅 시간 제한(fail-open)을 넘지 않게
  local tg=$1 fx=${GD_FX[$i]%%:*} fo=${GD_FX[$i]#*:} v sfx a w t o u k=0 plus ops="" nops=0 nb=0 work found=0
  [ "$GD_FWORK" -lt "$GD_FWORKCAP" ] || { gd_find_over "$tg"; return 1; }   # 상한을 이미 다 썼으면 표도 인수도 읽지 않고 바로(대상마다 O(1))
  [ "$GD_FWI" = "$fx" ] || gd_find_build "$fx"
  [ "$GD_FBAD" -eq 0 ] || { gd_find_over "$tg"; return 1; }
  [ "$GD_FXC" = "${GD_FXN[$fx]:-}" ] || return 1   # 파서와 셸 문자열 수가 다르면 되돌린다(파서 변경 대비)
  case $1 in
    '${'*) v=${1:2:1}; sfx=${1:4} ;;
    *) v=${1:1:1}; sfx=${1:2} ;;
  esac
  plus=${GD_FP[$fo]:-0}
  case $v in
    [0-9]) if [ "$v" -lt "${GD_FAN[$fo]:-0}" ]; then   # 빈 인수('')도 자리를 차지한다(건너뛰면 뒤 인수가 당겨져 다른 대상을 판단한다)
             while IFS= read -r a; do [ "$k" -eq "$v" ] && break; k=$((k + 1)); done <<GDEOF
${GD_FA10[$fo]:-}
GDEOF
             ops=$a$'\n'; nops=1
           elif [ "$plus" -eq 1 ]; then ops='{}'$'\n'; nops=1
           else return 1; fi
           case $ops in *'{}'*) nb=1 ;; esac ;;
    *) [ "$GD_FDK" = "$fx:$fo" ] || gd_find_dist "$fo" "$fx:$fo"
       [ "$GD_FDN" -gt 0 ] || return 1
       [ "$GD_FDN" -le "$GD_FWORKCAP" ] || { gd_find_over "$tg"; return 1; }
       ops=$GD_FD; nops=$GD_FDN; nb=$GD_FDB ;;
  esac
  work=$(( nb * GD_FNS * 2 + (nops - nb) ))   # 판단 횟수(= {} 패턴 x 시작 디렉터리 x 2(하위·깊이0) + 글자 그대로 인수)
  [ $((GD_FWORK + work)) -le "$GD_FWORKCAP" ] || { gd_find_over "$tg"; return 1; }   # 명령 전체 누적 상한(dirs x groups 같은 팬아웃)
  GD_FWORK=$((GD_FWORK + work))
  GD_FXR=1; k=0
  while [ "$k" -lt "$nops" ] && IFS= read -r a; do k=$((k + 1))   # 개수만큼 읽는다(빈 인수도 판단: rm -rf ""/* = rm -rf /*)
    case $a in
      *'{}'*) found=1
        while IFS= read -r w; do [ -n "$w" ] || continue
          [ "$GD_FJC" -eq 1 ] && gd_rm_target "${a%%'{}'*}$w/x${a#*'{}'}$sfx"   # <시작>/x(찾은 하위 경로)
          if [ "$GD_FJS" -eq 1 ]; then                                          # <시작> 자체(깊이 0) — 마지막 구성 요소가 . .. 이면 rm 이 거부하므로 건너뜀
            t="${a%%'{}'*}$w${a#*'{}'}$sfx"; o=$t; while :; do case $o in */) o=${o%/} ;; *) break ;; esac; done
            u=$w; while :; do case $u in */) u=${u%/} ;; *) break ;; esac; done
            # -r 없는 rm 은 디렉터리를 지우지 못하므로 시작 디렉터리 그 자체(앞뒤에 붙은 것 없음)는 판단하지 않는다(find /tmp -name '*.sock' -exec sh -c 'rm -f "$1"' … 가 deny 가 되지 않게)
            case ${o##*/} in .|..) ;; *) { [ "${rec:-0}" -eq 1 ] || [ "$o" != "$u" ]; } && gd_rm_target "$t" ;; esac
          fi
        done <<GDEOF2
$GD_FSS
GDEOF2
        ;;
      *) gd_rm_target "$a$sfx" ;;
    esac
  done <<GDEOF3
$ops
GDEOF3
  GD_FXR=0
  [ "$found" -eq 1 ] && gd_shit 2 data-loss-misc "find -exec 셸 문자열로 찾은 파일 삭제(find -exec rm 과 같음): $tg"
  return 0
}
gd_find_pos_o() {  # <대상> — 겹친 find -exec 문자열(GD_FXO[i]): 가장 바깥 find 의 인수로도 판단한다(R6). 풀리지 않으면 1(원래 규칙)
  local sv=${GD_FX[$i]} rc
  GD_FX[$i]=${GD_FXO[$i]}; gd_find_pos "$1"; rc=$?; GD_FX[$i]=$sv
  return $rc
}
gd_find_dist() {  # <순번> <키> — $@·$* 가 넘기는 인수($0 다음부터, {} + 이면 {} 를 더함)의 서로 다른 패턴(GD_FD 줄 단위·GD_FDN 개수·GD_FDB {} 포함 수).
  # 그룹마다 한 번만 만든다(GD_FDK 캐시). 빈 인수도 한 패턴. 상한을 넘으면 거기서 멈춘다(GD_FDN > 상한 → 호출한 쪽이 되돌림)
  local a c=0 n=${GD_FAN[$1]:-0} d="" dn=0 db=0 nl=$'\n'
  GD_FDK=$2
  while [ "$c" -lt "$n" ] && IFS= read -r a; do
    c=$((c + 1)); [ "$c" -eq 1 ] && continue   # $0
    case $nl$d in *"$nl$a$nl"*) continue ;; esac
    d=$d$a$nl; dn=$((dn + 1)); case $a in *'{}'*) db=$((db + 1)) ;; esac
    [ "$dn" -le "$GD_FWORKCAP" ] || break
  done <<GDEOF
${GD_FA[$1]:-}
GDEOF
  if [ "${GD_FP[$1]:-0}" -eq 1 ] && [ "$dn" -le "$GD_FWORKCAP" ]; then
    case $nl$d in *"$nl{}$nl"*) ;; *) d=$d'{}'$nl; dn=$((dn + 1)); db=$((db + 1)) ;; esac
  fi
  GD_FD=$d; GD_FDN=$dn; GD_FDB=$db
}
gd_find_over() {  # <대상> — 상한을 넘어 위치 매개변수를 풀지 않을 때: 적어도 find -exec rm 과 같은 ask-high(rec 면 원래 규칙이 deny 를 더한다)
  gd_shit 2 data-loss-misc "find -exec 셸 문자열(판단 상한 초과 — find -exec rm 과 같게 봄): $1"
}
gd_rm() {  # [<rec-preset>] — rimraf 는 항상 재귀·강제(G20)
  local j=$((j0 + 1)) t rec=${1:-0} force=0 dd=0 ntgt=0 pj pe ph
  [ "$rec" -eq 1 ] && force=1
  while [ "$j" -lt "$e" ]; do
    t=${GD_T[$j]}; j=$((j + 1))
    if [ "$dd" -eq 0 ]; then
      case $t in
        --) dd=1; continue ;; --recursive) rec=1; continue ;; --force) force=1; continue ;; --*) continue ;;
        -?*) case $t in *r*|*R*) rec=1 ;; esac; case $t in *f*) force=1 ;; esac; continue ;;
      esac
    fi
    ntgt=$((ntgt + 1))
    if [ "$ntgt" -gt "$GD_RMCAP" ] || hook_time_up; then GD_OVERFLOW=1; break; fi   # R5: rm 대상 상한·작업 시간(대상마다 경로를 정규화해 수만 개면 10초를 넘긴다)
    gd_rm_target "$t"
  done
  case $S_KIND in
    *xargs*) if [ "$i" -gt 0 ]; then
        pj=${GD_TS[$((i - 1))]}; pe=${GD_TE[$((i - 1))]}; ph=${GD_T[$pj]:-}
        case $ph in echo|printf) pj=$((pj + 1)); while [ "$pj" -lt "$pe" ]; do gd_rm_target "${GD_T[$pj]}"; pj=$((pj + 1)); done ;; esac
      fi
      gd_shit 1 rm-xargs "xargs 로 전달되는 삭제 대상 불명" ;;
    *) if [ "$rec" -eq 1 ] && [ "$ntgt" -eq 0 ]; then gd_shit 3 rm-root "삭제 대상 불명(명령 치환·미확장 변수·빈 인수): $S_M"; fi ;;   # G1 안전망
  esac
}
# ---- git ----
gd_branch() {  # <dir> → GD_BR (가정된 브랜치 > 캐시 > git symbolic-ref 1회)
  if [ -n "$GD_BRANCH_ASSUMED" ]; then GD_BR=$GD_BRANCH_ASSUMED; return 0; fi
  if [ "$GD_BR_DONE" -eq 1 ] && [ "$GD_BR_DIR" = "$1" ]; then GD_BR=$GD_BR_CACHE; return 0; fi
  gd_afork || { GD_BR=""; return 0; }   # R5: git fork 도 분석 fork 상한에 센다(넘으면 브랜치를 모름 — too-complex 바닥)
  GD_BR=$(git -C "$1" --no-optional-locks symbolic-ref --short -q HEAD 2>/dev/null)
  GD_BR_DIR=$1; GD_BR_CACHE=$GD_BR; GD_BR_DONE=1
}
gd_protected() { hook_is_protected_branch "$1"; }   # D11: lib/common.sh 의 단일 구현
gd_git_push() {  # W[] = push 인수
  local w force=0 lease=0 mirror=0 all=0 tags=0 del=0 dry=0 remote="" nref=0 prot=0 nonprot=0 skip=0 dst src
  for w in ${W[@]+"${W[@]}"}; do
    [ "$skip" -eq 1 ] && { skip=0; continue; }
    case $w in
      --force|-f) force=1 ;; --force-with-lease*|--force-if-includes) lease=1 ;;
      --mirror) mirror=1 ;; --all|--branches) all=1 ;; --tags) tags=1 ;; --delete|-d) del=1 ;; --dry-run|-n) dry=1 ;;
      --no-veri|--no-verif|--no-verify) gd_shit 3 git-no-verify "훅 검증 생략(--no-verify)" ;;   # git 은 고유한 접두 약어도 받는다
      -o|--push-option|--repo|--receive-pack|--exec) skip=1 ;;
      --*) ;; -*) case $w in *f*) force=1 ;; esac; case $w in *n*) dry=1 ;; esac ;;
      *) if [ -z "$remote" ]; then remote=$w; else
           nref=$((nref + 1)); dst=$w
           case $dst in +*) force=1; dst=${dst#+} ;; esac
           case $dst in *:*) src=${dst%%:*}; dst=${dst#*:}; [ -z "$src" ] && del=1 ;; esac
           dst=${dst#refs/heads/}
           case $dst in *'*'*) [ -n "$GD_PROT" ] && prot=1; continue ;; esac   # G21: 와일드카드 refspec 은 보호 브랜치를 포함한다
           case $dst in refs/*) continue ;; HEAD|@|'$'*) gd_branch "$dir"; dst=$GD_BR ;; esac   # G1: $(git branch --show-current)·$BRANCH 는 현재 브랜치로 본다
           if gd_protected "$dst"; then prot=1; else nonprot=1; fi
         fi ;;
    esac
  done
  [ "$dry" -eq 1 ] && return 0
  if [ "$mirror" -eq 1 ]; then force=1; [ -n "$GD_PROT" ] && prot=1; fi
  [ "$all" -eq 1 ] && [ -n "$GD_PROT" ] && prot=1
  if [ "$nref" -eq 0 ] && [ "$all" -eq 0 ] && [ "$mirror" -eq 0 ] && [ "$tags" -eq 0 ]; then gd_branch "$dir"; if gd_protected "$GD_BR"; then prot=1; else nonprot=1; fi; fi   # F8: refspec 없는 --tags 는 태그만 푸시
  [ "$GD_HOOKS_BYPASS" -eq 1 ] && gd_shit 2 git-hooks-bypass "git 훅 우회 환경 변수와 함께 push"
  if [ "$prot" -eq 1 ] && [ "$force" -eq 1 ]; then gd_shit 3 git-force-protected "보호 브랜치 강제 푸시"; return 0; fi
  if [ "$prot" -eq 1 ] && [ "$del" -eq 1 ]; then gd_shit 3 git-force-protected "보호 브랜치 원격 삭제"; return 0; fi
  if [ "$force" -eq 1 ] || [ "$lease" -eq 1 ]; then gd_shit 2 git-force "강제 푸시(--force/--force-with-lease)"; return 0; fi
  if [ "$prot" -eq 1 ]; then [ "$GD_ASK_PUSH" = 0 ] || gd_shit 2 git-push-protected "보호 브랜치로 푸시"; return 0; fi
  [ "$GD_ASK_PUSH" = 1 ] && gd_shit 2 git-push "원격 푸시(CLAUDE_GUARD_ASK_ON_PUSH=1)"
  return 0
}
gd_commit_short() {  # <짧은 플래그 묶음(앞의 - 제외)> — git commit 을 getopt 처럼 왼쪽부터 읽는다(F1): n = --no-verify.
  local s=$1 c lim=0    # m F C c t 는 값을 받는다(단어의 나머지, 없으면 다음 단어 → skip). u S 는 붙은 값만 받는다(-uno, -Sn)
  # R5: 글자마다 남은 문자열을 다시 만들어 길이의 제곱(2만 자에 16초) — 앞 GD_BUNDLEMAX 글자까지만 읽는다. 그 안에서 값 글자로 끝나지 않으면 too-complex 바닥
  if [ "${#s}" -gt "$GD_BUNDLEMAX" ]; then s=${s:0:$GD_BUNDLEMAX}; lim=1; fi
  while [ -n "$s" ]; do
    c=${s:0:1}; s=${s:1}
    case $c in
      n) gd_shit 3 git-no-verify "훅 검증 생략(-n)" ;;
      m|F|C|c|t) [ -n "$s" ] || [ "$lim" -eq 1 ] || skip=1; return 0 ;;
      u|S) return 0 ;;
    esac
  done
  [ "$lim" -eq 0 ] || GD_OVERFLOW=1
}
gd_is_commit() {  # <dir> <name> — git 이 이 이름을 커밋(브랜치·태그·sha)으로 푸는가(git checkout 의 전환 우선; F9)
  gd_afork || return 1   # R5: 분석 fork 상한(넘으면 파일 복원으로 본다 + too-complex 바닥)
  git -C "$1" --no-optional-locks rev-parse -q --verify "$2^{commit}" >/dev/null 2>&1
}
gd_git() {
  local gl gdir sub rest dir w skip=0 amend=0 staged=0 wt=0 dot=0 npath=0 del=0 undo=0 tgt="" nb="" val="" W=()
  gd_afork || return 0   # R5: git 세그먼트마다 awk 를 1~2번 부른다 — 분석 fork 상한(넘으면 이 세그먼트는 보지 않고 too-complex 바닥)
  gl=$(sp_git_subcmd "$S_R") || return 0
  gdir=${gl%%$'\t'*}; rest=${gl#*$'\t'}; sub=${rest%%$'\t'*}; rest=${rest#*$'\t'}   # (IFS 탭 read 는 빈 필드를 합쳐 버린다)
  [ -n "$sub" ] || return 0
  dir=$GD_EFF; if [ -n "$gdir" ]; then hook_abspath_var "$gdir" "$GD_EFF"; dir=$HOOK_ABS; fi
  if [ -n "$rest" ]; then gd_afork || return 0; set -f; IFS=$'\n'; W=($(sp_words "$rest")); unset IFS; set +f; fi
  case $GD_LOW in *core.hookspath=*) case $sub in commit|push|merge|rebase) gd_shit 2 git-hooks-bypass "git 훅 경로 우회(-c core.hooksPath=)" ;; esac ;; esac
  case $sub in
    push) gd_git_push ;;
    commit)
      for w in ${W[@]+"${W[@]}"}; do
        [ "$skip" -eq 1 ] && { skip=0; continue; }
        case $w in
          --) break ;;                                   # 이후는 경로
          --no-veri|--no-verif|--no-verify) gd_shit 3 git-no-verify "훅 검증 생략(--no-verify)" ;; --amend) amend=1 ;;
          --message|--file|--author|--date|--template|--fixup|--squash|--reuse-message|--reedit-message|--trailer|--cleanup|--pathspec-from-file) skip=1 ;;   # 값을 다음 단어로 받는 긴 옵션(--gpg-sign 의 값은 = 로만)
          --*) ;; -?*) gd_commit_short "${w#-}" ;;
        esac
      done
      [ "$GD_HOOKS_BYPASS" -eq 1 ] && gd_shit 2 git-hooks-bypass "git 훅 우회 환경 변수(HUSKY=0 등)와 함께 commit"
      gd_branch "$dir"
      gd_protected "$GD_BR" && gd_shit 2 git-protected-write "보호 브랜치($GD_BR)에서 직접 커밋 — 브랜치를 먼저 만들지 확인"
      if [ "$amend" -eq 1 ]; then
        if gd_afork && [ "$(git -C "$dir" --no-optional-locks rev-list --count '@{u}..HEAD' 2>/dev/null)" = 0 ]; then gd_shit 2 git-history "이미 푸시된 커밋 amend(히스토리 재작성)"
        else gd_shit 1 git-amend "커밋 amend"; fi
      fi ;;
    merge|cherry-pick|rebase|revert|am)
      for w in ${W[@]+"${W[@]}"}; do case $w in --no-veri|--no-verif|--no-verify) [ "$sub" = merge ] || [ "$sub" = rebase ] && gd_shit 3 git-no-verify "훅 검증 생략(--no-verify)" ;; --abort|--quit|--continue|--skip) undo=1 ;; esac; done
      [ "$undo" -eq 1 ] && return 0   # G16: 진행 중 작업의 중단·계속은 보호 브랜치에 새 변경을 쓰지 않는다
      [ "$GD_HOOKS_BYPASS" -eq 1 ] && gd_shit 2 git-hooks-bypass "git 훅 우회 환경 변수와 함께 $sub"
      gd_branch "$dir"; gd_protected "$GD_BR" && gd_shit 2 git-protected-write "보호 브랜치($GD_BR)에서 직접 $sub — 브랜치를 먼저 만들지 확인" ;;
    reset)
      for w in ${W[@]+"${W[@]}"}; do case $w in --hard|--merge|--keep) tgt=$w ;; esac; done
      if [ -n "$tgt" ]; then gd_branch "$dir"; if gd_protected "$GD_BR"; then gd_shit 2 git-reset-hard "보호 브랜치($GD_BR)에서 reset $tgt"; else gd_shit 1 git-reset-hard "작업 내용 폐기(reset $tgt)"; fi; fi ;;
    checkout|switch)
      for w in ${W[@]+"${W[@]}"}; do
        [ "$skip" -eq 1 ] && { skip=0; nb=$w; continue; }
        case $w in
          --) dot=1 ;; -b|-c|-B|-C|--orphan) skip=1; case $w in -B|-C) gd_shit 1 git-checkout-force "브랜치 강제 재생성($w)" ;; esac ;;
          -f|--force|--discard-changes) gd_shit 1 git-checkout-force "변경 사항 폐기($sub $w)" ;;
          -*) ;; .|'*'|./) gd_shit 2 data-loss-misc "작업 트리 변경 전체 폐기($sub $w)" ;;
          *) if [ "$dot" -eq 1 ]; then gd_shit 1 git-restore "파일 변경 폐기($sub -- $w)"; else npath=$((npath + 1)); [ -z "$tgt" ] && tgt=$w; fi ;;
        esac
      done
      # G8·F9: git 과 같은 우선순위 — checkout 인수가 하나면 커밋으로 풀릴 때 전환(같은 이름의 경로가 있어도), 아니고 경로·글롭이면
      # 파일 복원(checkout -- <경로> 와 같은 ask-low). 인수가 둘 이상이면 <rev> <경로…> 복원. 브랜치 가정은 전환일 때만
      if [ -n "$nb" ]; then GD_BRANCH_ASSUMED=$nb
      elif [ -n "$tgt" ] && [ "$dot" -eq 0 ]; then
        if [ "$sub" = switch ]; then GD_BRANCH_ASSUMED=$tgt
        elif [ "$npath" -ge 2 ]; then gd_shit 1 git-restore "파일 변경 폐기($sub $tgt …)"
        else
          case $tgt in *[\*\?\[]*) val=1 ;; /*) [ -e "$tgt" ] && val=1 ;; *) [ -e "$dir/$tgt" ] && val=1 ;; esac   # 글롭 문자는 브랜치 이름에 못 쓴다
          if [ -n "$val" ] && ! gd_is_commit "$dir" "$tgt"; then gd_shit 1 git-restore "파일 변경 폐기($sub $tgt)"; else GD_BRANCH_ASSUMED=$tgt; fi
        fi
      fi ;;
    restore)
      for w in ${W[@]+"${W[@]}"}; do
        case $w in --staged|-S) staged=1 ;; --worktree|-W) wt=1 ;; -s|--source) skip=1 ;; --) ;; -*) ;;
          .|'*'|./|:/) dot=1 ;; *) [ "$skip" -eq 1 ] && skip=0 || npath=$((npath + 1)) ;; esac
      done
      if [ "$staged" -eq 1 ] && [ "$wt" -eq 0 ]; then :; elif [ "$dot" -eq 1 ]; then gd_shit 2 data-loss-misc "작업 트리 변경 전체 폐기(restore)"; elif [ "$npath" -gt 0 ]; then gd_shit 1 git-restore "파일 변경 폐기(restore)"; fi ;;
    clean)
      for w in ${W[@]+"${W[@]}"}; do
        case $w in
          --dry-run) dot=2 ;; --force) staged=1 ;; --*) ;;
          -*) case $w in *n*) dot=2 ;; esac; case $w in *x*|*X*) wt=1 ;; esac; case $w in *f*) staged=1 ;; esac ;;
        esac
      done
      if [ "$dot" -ne 2 ]; then
        if [ "$wt" -eq 1 ] && [ "$staged" -eq 1 ]; then gd_shit 2 data-loss-misc "추적되지 않은 파일·무시 파일 삭제(clean -x)"
        elif [ "$staged" -eq 1 ]; then gd_shit 1 git-clean "추적되지 않은 파일 삭제(clean -f)"; fi
      fi ;;
    stash) case ${W[0]:-} in drop|clear) gd_shit 1 git-stash-drop "stash 삭제" ;; esac ;;
    branch)
      for w in ${W[@]+"${W[@]}"}; do
        case $w in
          --delete) del=1 ;; --force) staged=1 ;; --*) ;;
          -*) case $w in *D*) del=1; staged=1 ;; esac; case $w in *d*) del=1 ;; esac; case $w in *f*) staged=1 ;; esac ;;   # G13: -df/-fd 결합 플래그
          *) gd_protected "$w" && tgt=$w ;;
        esac
      done
      if [ "$del" -eq 1 ] && [ "$staged" -eq 1 ]; then if [ -n "$tgt" ]; then gd_shit 3 git-force-protected "보호 브랜치($tgt) 강제 삭제"; else gd_shit 1 git-branch-delete "브랜치 강제 삭제(-D)"; fi; fi ;;
    update-ref) case " ${W[*]-} " in *' -d '*) for w in ${W[@]+"${W[@]}"}; do
          case $w in -d) continue ;; HEAD|@) gd_branch "$dir"; val=$GD_BR ;; *) val=${w#refs/heads/} ;; esac   # G21: HEAD/@ 는 현재 브랜치
          [ -n "$val" ] && gd_protected "$val" && gd_shit 3 git-force-protected "보호 브랜치 참조 삭제($w)"
        done ;; esac ;;
    config)   # G21: 영구적 훅 우회(core.hooksPath 변경). 표준 위치(.husky/.githooks/.git/hooks)는 예외
      for w in ${W[@]+"${W[@]}"}; do
        if [ "$skip" -eq 1 ]; then val=$w; break; fi
        case $w in [Cc][Oo][Rr][Ee].[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]) skip=1 ;; [Cc][Oo][Rr][Ee].[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]=*) val=${w#*=}; break ;; esac
      done
      case $val in ''|.husky|.husky/*|.githooks|.githooks/*|.git/hooks|.hooks|.lefthook*) ;; *) gd_shit 2 git-hooks-bypass "git 훅 경로 변경(config core.hooksPath $val)" ;; esac ;;
    filter-branch|filter-repo) gd_shit 3 git-force-protected "히스토리 전체 재작성($sub)" ;;
    reflog) case ${W[0]:-} in expire|delete) gd_shit 2 git-history "reflog $W 삭제(복구 불가)" ;; esac ;;
    gc) case " ${W[*]-} " in *' --prune'*) gd_shit 2 git-history "gc --prune(복구 불가)" ;; esac ;;
    tag) case " ${W[*]-} " in *' -d '*|*' --delete '*) gd_shit 1 git-tag-delete "태그 삭제" ;; esac ;;
    remote) case ${W[0]:-} in remove|rm|set-url|prune) gd_shit 1 git-remote "원격 설정 변경(remote ${W[0]})" ;; esac ;;
    worktree) case ${W[0]:-} in prune) gd_shit 1 git-worktree "worktree prune" ;; remove) case " ${W[*]-} " in *' --force '*|*' -f '*) gd_shit 1 git-worktree "worktree 강제 제거" ;; esac ;; esac ;;
  esac
  return 0
}
gd_whole() {  # 명령 전체(소문자)에 대한 규칙
  local r6='>&?[|!]?[[:space:]]*["'"'"']?/dev/(r?disk|sd|nvme|hd)'   # > >> 2> &> >& 와 덮어쓰기 >| >! >&| >&! &>|(zsh), 따옴표 친 장치 경로(I1)
  S_SEV=0; S_RULE=""; S_WHY=""; hook_excerpt "$H_CMD" 120; S_M=$HOOK_EX
  case $GD_LOW in *':(){'*) gd_shit 3 system "포크 폭탄" ;; esac
  [[ $GD_LOW =~ $r6 ]] && gd_shit 3 system "블록 디바이스로 리디렉션"
  if [ "$S_SEV" -gt "$GD_SEV" ]; then GD_SEV=$S_SEV; GD_RULE=$S_RULE; GD_WHY=$S_WHY; GD_EX=$S_M; fi
}
gd_pipe_text() {  # <text> — 실행되는 텍스트(셸이 읽는 heredoc 본문·인수로 넘긴 명령 문자열)의 원격 스크립트 실행 형태(G9). 0 = 발견
  local r1='(curl|wget)[^|]*(\|[^|]*)*\|[[:space:]]*(sudo[[:space:]]+)?(env[[:space:]]+)?((ba|z|da|k|fi)?sh([[:space:]]|$)|(python[0-9.]*|perl|ruby|node)([[:space:]]+-)?[[:space:]]*($|[;&|)]))'
  local r2='(bash|sh|zsh|dash|ksh)[[:space:]]+(-c[[:space:]]+)?["'"'"']?\$\((curl|wget)' r3='eval[[:space:]].*\$\((curl|wget)'
  local r4='python[0-9.]*[[:space:]]+-c[[:space:]].*(urllib|requests).*(exec|eval)' r5='(source|\.|bash|sh|zsh|dash|ksh)[[:space:]]+(-s[[:space:]]+)?<\((curl|wget)' rc=1
  case $1 in *[Cc][Uu][Rr][Ll]*|*[Ww][Gg][Ee][Tt]*|*urllib*|*requests*) ;; *) return 1 ;; esac
  shopt -s nocasematch
  if [[ $1 =~ $r1 ]] || [[ $1 =~ $r2 ]] || [[ $1 =~ $r3 ]] || [[ $1 =~ $r4 ]] || [[ $1 =~ $r5 ]]; then rc=0; fi
  shopt -u nocasematch; return $rc
}
gd_reads_stdin() {  # <sh|py|node|perl|ruby> — 세그먼트 [j0,e) 가 프로그램을 물려받은 표준 입력(파이프)에서 읽는가(gd_prog).
  # 스크립트 인수·-c/-e 문자열·자체 입력(< 파일, <<, <<<)이 있으면 아니다. 스크립트 인수가 -·/dev/stdin·/dev/fd/0·/proc/self/fd/0 이거나
  # 입력이 < /dev/stdin·<&0 이면 여전히 표준 입력이다(r2). 셸 -n(실행 안 함)은 제외
  gd_prog "$1"; gd_prog_stdin
}
gd_cat_stdin() {  # 세그먼트 [j0,e) 의 cat 이 물려받은 표준 입력만 읽는가(파일 인수 없음, - 또는 표준 입력 장치만 — bash -c "$(cat)")
  local j=$((j0 + 1)) t
  while [ "$j" -lt "$e" ]; do t=${GD_T[$j]}; j=$((j + 1))
    case $t in
      -|'<&0'|'0<&0') ;;
      '<'|'0<') gd_stdin_dev "${GD_T[$j]:-}" || return 1; j=$((j + 1)) ;;
      '<'*|'0<'*) t=${t#0}; gd_stdin_dev "${t#<}" || return 1 ;;
      *'>'|*'>&') j=$((j + 1)) ;;
      *'>'*|-*) ;;
      *) gd_stdin_dev "$t" || return 1 ;;
    esac
  done
  return 0
}
gd_echo_fetch() {  # <i> — 세그먼트 i 가 curl/wget 명령 텍스트를 내보내는 echo/printf 인가(echo "curl … | sh" | bash)
  case ${GD_K[$1]} in cmd*) ;; *) return 1 ;; esac
  case ${GD_M[$1]} in echo|'echo '*|printf|'printf '*) ;; *) return 1 ;; esac
  case ${GD_R[$1]} in *[Cc][Uu][Rr][Ll]*|*[Ww][Gg][Ee][Tt]*) return 0 ;; esac
  return 1
}
gd_pipe_shell() {  # pipe-to-shell(G9·F14·r2) — 실행되는 것만 본다: 앞선 curl/wget 의 출력을 표준 입력으로 읽는 셸·인터프리터(/dev/stdin 등
  # 표준 입력 장치를 스크립트로 받는 형태, source /dev/stdin 포함), 실행되는 치환(셸·eval·source 의 치환, 치환을 프로그램으로 받는 인터프리터:
  # python3 <(…)·-c "$(…)") 안의 curl/wget 이나 표준 입력을 읽는 cat·< /dev/stdin, 셸이 읽는 heredoc 본문, 인수로 넘긴 명령 문자열.
  # 파일로 쓰거나 메시지로만 쓰는 heredoc 본문과 git·gh·echo·printf 의 인수는 보지 않는다. 파서는 구분자(| ; &&)를 남기지 않으므로
  # 파이프는 세그먼트 순서로 근사한다
  local i=0 d=0 k h pk j0 e ex fetch=0 hx=0 hit=0 own=(0) last=(0) xs=() xd=() xn=0 c   # own[깊이]: 이 치환을 실행자가 실행하는가, last[깊이]: 그 깊이의 마지막 명령이 실행자인가
  # R6: 파서는 명령의 $(…) 묶음을 그 명령의 sub 줄 뒤에 내므로 펼친 문자열의 세그먼트가 명령과 그 치환 사이에 온다 — 펼침(GD_XB·GD_XE) 앞의 last 를
  # 저장했다가 펼침이 끝나면 되돌린다(sh -c "echo; $(curl …)"·eval "echo; $(curl …)" 의 치환은 문자열을 실행하는 셸이 쓴다)
  while [ "$i" -lt "$GD_N" ] && [ "$hit" -eq 0 ]; do
    hook_time_up && { GD_OVERFLOW=1; break; }   # R5: 작업 시간 상한
    c=${GD_XB[$i]:-0}; while [ "$c" -gt 0 ]; do xs[$xn]=${last[$d]:-0}; xd[$xn]=$d; xn=$((xn + 1)); c=$((c - 1)); done
    k=${GD_K[$i]}
    case $k in
      push) d=$((d + 1)); last[$d]=0   # 명령 치환·서브셸: 그 출력을 앞 명령(실행자)이 실행하면 own
        if [ "${GD_M[$i]}" = '<<' ]; then own[$d]=${own[$((d - 1))]}   # R6: 셸이 읽는 heredoc 본문 묶음(파서 P-C) — 본문 명령의 출력은 실행되지 않는다(bash <<EOF 안의 curl -o)
        else own[$d]=$((${last[$((d - 1))]} | ${own[$((d - 1))]})); fi ;;
      pop) [ "$d" -gt 0 ] && d=$((d - 1)) ;;
      heredoc) if [ "$hx" -eq 1 ] || [ "${own[$d]}" -eq 1 ]; then gd_pipe_text "${GD_R[$i]}" && hit=1; fi ;;
      sub) gd_pipe_text "${GD_R[$i]}" && hit=1 ;;    # 2단계 이상 중첩된 명령 문자열
      *) gd_head "${GD_M[$i]}"; h=${GD_HEAD##*/}; j0=${GD_TS[$i]}; e=${GD_TE[$i]}; ex=0   # 경로를 뗀 이름(~/bin/bash)
        case ${GD_R[$i]} in *'<<'*) case $h in '<'*) ;; *) hx=0 ;; esac ;; esac   # heredoc 본문은 그 줄의 << 명령이나 뒤 명령(cat <<EOF | bash)이
                                                      # 셸일 때만 실행된다(ssh host <<EOF 의 내부 문자열 '<<EOF' 같은 머리 없는 세그먼트는 제외)
        if [ "$fetch" -eq 1 ] && [ "${own[$d]}" -eq 1 ]; then   # 실행되는 치환 안에서 앞선 curl 의 출력(표준 입력)을 읽는다: "$(cat)", <(cat), "$(< /dev/stdin)"
          case $h:$GD_HEAD in
            cat:*) gd_cat_stdin && hit=1 ;;
            *:'<&0') hit=1 ;;
            *:'<'*) pk=${GD_HEAD#<}; [ -n "$pk" ] || pk=${GD_T[$((j0 + 1))]:-}; gd_stdin_dev "$pk" && hit=1 ;;
          esac
        fi
        case $h in
          curl|wget) [ "${own[$d]}" -eq 1 ] && hit=1; fetch=1 ;;
          sh|bash|zsh|dash|ksh|fish) hx=1; ex=1; if { [ "$fetch" -eq 1 ] || { [ "$i" -gt 0 ] && gd_echo_fetch $((i - 1)); }; } && gd_reads_stdin sh; then hit=1; fi ;;
          python*|perl|ruby|node) hx=1; case $h in python*) pk=py ;; *) pk=$h ;; esac   # 인터프리터는 치환을 프로그램으로 받을 때만 실행자(python3 <(curl …))
            gd_prog "$pk"
            if [ "$fetch" -eq 1 ] && gd_prog_stdin; then hit=1; fi
            gd_prog_sub && ex=1 ;;
          ssh) hx=1 ;;
          source|.) ex=1; [ "$fetch" -eq 1 ] && gd_stdin_dev "${GD_T[$((j0 + 1))]:-}" && hit=1 ;;   # curl … | source /dev/stdin
          eval) ex=1 ;;
        esac
        case $h in git|gh|echo|printf) ;; *) gd_pipe_text "${GD_R[$i]}" && hit=1 ;; esac   # 인수 속 명령 문자열(docker run … sh -c "…")
        case $h in '$('*|'<('*|'>('*|'…') ;; *) last[$d]=$ex ;; esac ;;   # 자리표시 단어($(…))만 남은 세그먼트는 건너뛴다
    esac
    c=${GD_XE[$i]:-0}; while [ "$c" -gt 0 ] && [ "$xn" -gt 0 ]; do xn=$((xn - 1)); last[${xd[$xn]}]=${xs[$xn]}; c=$((c - 1)); done
    i=$((i + 1))
  done
  [ "$hit" -eq 1 ] && [ "$GD_SEV" -lt 2 ] || return 0
  GD_SEV=2; GD_RULE=pipe-to-shell; GD_WHY="원격 스크립트를 받아 바로 실행"; hook_excerpt "$H_CMD" 120; GD_EX=$HOOK_EX
}
gd_eval() {  # <segment-index> — 명령 문자열 펼침의 처음이면 작업 디렉터리 상태를 저장하고 끝이면 되돌린다(GD_SB·GD_SE; I6)
  local gd_k=${GD_SB[$1]:-0}
  while [ "$gd_k" -gt 0 ]; do gd_push 1; gd_k=$((gd_k - 1)); done
  gd_eval_seg "$1"
  gd_k=${GD_SE[$1]:-0}
  while [ "$gd_k" -gt 0 ]; do gd_pop; gd_k=$((gd_k - 1)); done
}
gd_eval_seg() {  # <segment-index>
  local i=$1 j0 e
  S_KIND=${GD_K[$i]}; S_M=${GD_M[$i]}; S_R=${GD_R[$i]}; j0=${GD_TS[$i]}; e=${GD_TE[$i]}
  S_SEV=0; S_RULE=""; S_WHY=""
  case $S_KIND in push) gd_push; return 0 ;; pop) gd_pop; return 0 ;; esac
  if [ "$S_KIND" = heredoc ]; then
    case ${GD_HD[$i]} in psql|mysql|mariadb|sqlite3|duckdb|clickhouse-client|mongosh|mongo|redis-cli|cqlsh) gd_sql_scan "$S_R" ;; esac
    gd_merge; return 0
  fi
  gd_head "$S_M"; S_HEAD=$GD_HEAD
  case $S_HEAD in cd|pushd|popd) gd_cd; return 0 ;; esac
  case $S_HEAD in
    rm|grm) gd_rm ;;                       # G20: coreutils grm (gnubin 경로는 파서가 벗긴다)
    rimraf) gd_rm 1 ;;                     # G20: rimraf 는 항상 재귀·강제
    git) gd_git ;;
    mkfs*|dd|shutdown|reboot|halt|poweroff|kill|killall5|crontab|history|launchctl|diskutil|csrutil|nvram|chmod|chown|chgrp) gd_system; gd_privilege ;;
    psql|mysql|mariadb|sqlite3|duckdb|clickhouse-client|mongosh|mongo|redis-cli|cqlsh|dropdb|dropuser) gd_db ;;
    kubectl|helm|terraform|tofu|terragrunt|pulumi|aws|gcloud|az|flyctl|fly|heroku|vercel|netlify|wrangler|serverless|sls|sam|cdk|ansible-playbook|docker|docker-compose|gh|fab|cap|firebase|eb|supabase|railway|amplify|kamal|cf|zappa) gd_infra ;;
    ssh|scp|sftp|rsync) gd_remote ;;
    make|just|task|rake|invoke|inv|npm|pnpm|yarn|bun|twine|uv|poetry|gem|cargo|flit|hatch|pip|pip3|pipx|brew) gd_db_orm; gd_publish; gd_deploy_runner; gd_privilege ;;   # db·publish 가 먼저(같은 티어면 더 구체적인 규칙 id: rake db:rollback, pnpm publish)
    find|gfind|shred|truncate) gd_dataloss ;;
    su|sudo|doas|systemctl|defaults|spctl|pmset|networksetup|scutil|dscl|visudo|at) gd_privilege ;;
    *) gd_deploy_runner ;;
  esac
  case $S_KIND in *sudo*) gd_privilege ;; esac
  gd_db_orm
  gd_merge
}
gd_too_complex() {  # R4 task2: 파서 작업 상한 초과 — 명령을 다 분석하지 못함. 메인은 ask-high, 서브에이전트(agent_id)는 deny. 이미 더 센 결정이 있으면 그대로
  local sev=2; [ -n "$H_AGENT_ID" ] && sev=3
  [ "$sev" -gt "$GD_SEV" ] || return 0
  GD_SEV=$sev; GD_RULE=too-complex; GD_WHY="명령이 너무 커서 전부 분석하지 못함 — 직접 확인할 것"; hook_excerpt "$H_CMD" 120; GD_EX=$HOOK_EX
}
gd_finish() {
  case $GD_SEV in
    3) hook_emit_pre deny "차단 [destructive:$GD_RULE]: $GD_WHY — $GD_EX" "destructive:$GD_RULE" ;;
    2) hook_emit_pre ask "확인 필요 [destructive:$GD_RULE]: $GD_WHY — $GD_EX" "destructive:$GD_RULE" ;;
    1) case $H_MODE in
         auto|bypassPermissions) hook_emit_pre allow "silenced($H_MODE): [destructive:$GD_RULE] $GD_WHY — $GD_EX" "destructive:$GD_RULE" ;;
         *) hook_emit_pre ask "확인 필요 [destructive:$GD_RULE]: $GD_WHY — $GD_EX" "destructive:$GD_RULE" ;;
       esac ;;
  esac
  exit 0
}

gd_collect "$H_CMD"
gd_whole
if [ "$GD_N" -gt 0 ]; then
  gd_tokenize
  gd_pipe_shell
  i=0; while [ "$i" -lt "$GD_N" ]; do hook_time_up && { GD_OVERFLOW=1; break; }; gd_eval "$i"; i=$((i + 1)); done   # R5: 작업 시간 상한
fi
[ "$GD_OVERFLOW" -eq 1 ] && gd_too_complex   # R4 task2: 상한 초과 — 받은 세그먼트는 모두 판정하고(상한 앞의 deny 유지) 못 본 부분 때문에 too-complex 를 바닥으로
gd_finish
