#!/usr/bin/env bash
# guard-destructive.sh — PreToolUse(Bash|Monitor): 파괴적 명령 차단/확인. 결정은 stdout JSON + exit 0 만.
# 끄기: CLAUDE_GUARD_DESTRUCTIVE=off
# 설정: CLAUDE_GUARD_PROTECTED_BRANCHES(쉼표/공백 목록, 글롭 가능; 미설정이면 "main master"; none(대소문자 무관)·빈 값=브랜치 규칙 전부 끔
#         — lib/common.sh hook_is_protected_branch 가 단일 구현; D11), CLAUDE_GUARD_ASK_ON_PUSH(protected|1|0),
#       CLAUDE_GUARD_ALLOW_PATTERNS(ERE 대안을 | 로 연결; ^(…)$ 로 감싸 MASKED 세그먼트에 적용; ASK 만 allow 로 낮추고 DENY 는 불변)
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
  *'rm '*|*rmdir*|*'git '*|*kubectl*|*'helm '*|*terraform*|*terragrunt*|*tofu*|*pulumi*|*'aws '*|*gcloud*|*'az '*|*docker*|*'ssh '*|*'scp '*|*sftp*|*rsync*|*sudo*|*doas*|*chmod*|*chown*|*mkfs*|*'dd '*|*shutdown*|*reboot*|*halt*|*poweroff*|*kill*|*crontab*|*launchctl*|*systemctl*|*'defaults write'*|*diskutil*|*csrutil*|*spctl*|*nvram*|*pmset*|*networksetup*|*'brew '*|*'npm '*|*'pnpm '*|*'yarn '*|*'bun '*|*'pip '*|*pipx*|*twine*|*'poetry publish'*|*'uv publish'*|*'cargo publish'*|*'gem push'*|*'gh '*|*vercel*|*netlify*|*'fly '*|*flyctl*|*heroku*|*serverless*|*'sls '*|*'sam '*|*'cdk '*|*wrangler*|*ansible*|*'fab '*|*'cap '*|*'make '*|*'just '*|*'task '*|*rake*|*invoke*|*'drop '*|*truncate*|*'delete '*|*'alter '*|*manage.py*|*prisma*|*alembic*|*rails*|*knex*|*redis-cli*|*mongo*|*psql*|*mysql*|*sqlite3*|*dropdb*|*dropuser*|*curl*|*wget*|*eval*|*'sh -c'*|*history*|*'find '*|*shred*|*'> /dev'*|*/dev/*|*':(){'*|*.git*|*deploy*|*release*|*publish*|*rollback*|*destroy*|*prod*|*'su '*|*'su'|*scutil*|*dscl*|*visudo*|*'at '*|*flush*|*flyway*|*goose*|*dbmate*|*sqlx*|*'atlas '*|*artisan*|*supabase*|*sequelize*|*typeorm*|*drizzle*|*liquibase*|*mikro-orm*|*'db:'*|*'migrate:'*|*'migration:'*|*'grm '*|*rimraf*|*gnubin*|*'gfind '*|*downgrade*|*'db reset'*|*'db wipe'*|*'schema clean'*) ;;
  *) exit 0 ;;
esac
. "$GD_DIR/lib/shellparse.sh"
. "$GD_DIR/lib/guard-rules.sh"

hook_protected_branches; GD_PROT=$HOOK_PROT              # D11: 빈 값이면 브랜치 규칙 끔
GD_ASK_PUSH=${CLAUDE_GUARD_ASK_ON_PUSH:-protected}
GD_ALLOW_RE=${CLAUDE_GUARD_ALLOW_PATTERNS:-}; [ -n "$GD_ALLOW_RE" ] && GD_ALLOW_RE="^($GD_ALLOW_RE)\$"
GD_EFF=${H_CWD:-$PWD}; GD_EFF_UNKNOWN=0; GD_PREV=""; GD_DIRSTACK=""; GD_BRANCH_ASSUMED=""; GD_BR=""; GD_BR_DIR=""; GD_BR_CACHE=""; GD_BR_DONE=0; GD_HOOKS_BYPASS=0
GD_SP=0; GD_S_EFF=(); GD_S_UNK=(); GD_S_BR=(); GD_S_DS=(); GD_S_PREV=()   # 서브셸·명령 치환 안의 cd 가 밖으로 새지 않도록 하는 상태 스택(G10)
GD_SEV=0; GD_RULE=""; GD_WHY=""; GD_EX=""     # 전체 결정(deny 3 > ask-high 2 > ask-low 1 > 0)
S_SEV=0; S_RULE=""; S_WHY=""; S_KIND=""; S_M=""; S_R=""; S_HEAD=""
GD_N=0; GD_K=(); GD_M=(); GD_R=(); GD_HD=(); GD_T=(); GD_TS=(); GD_TE=(); GD_HEAD=""
GD_CP=""; GD_DOTS=0; GD_ISDOT=0

gd_shit() { [ "$1" -gt "$S_SEV" ] || return 0; S_SEV=$1; S_RULE=$2; S_WHY=$3; }
gd_merge() {  # 세그먼트 결정 → 전체 결정(허용 패턴은 ASK 만 낮춘다). 발췌는 UTF-8 경계에서 자른다(C8)
  [ "$S_SEV" -gt 0 ] || return 0
  if [ "$S_SEV" -lt 3 ] && [ -n "$GD_ALLOW_RE" ] && [[ $S_M =~ $GD_ALLOW_RE ]]; then hook_debug "allow-pattern: $S_M"; S_SEV=0; return 0; fi
  if [ "$S_SEV" -gt "$GD_SEV" ]; then GD_SEV=$S_SEV; GD_RULE=$S_RULE; GD_WHY=$S_WHY; hook_excerpt "$S_M" 120; GD_EX=$HOOK_EX; fi
}
gd_head() { set -f; set -- $1; GD_HEAD=${1:-}; set +f; }
gd_add_seg() { GD_K[$GD_N]=$1; GD_M[$GD_N]=$2; GD_R[$GD_N]=$3; GD_HD[$GD_N]=$4; GD_N=$((GD_N + 1)); }
gd_collect() {
  local k m r hd="" a
  while IFS=$'\t' read -r k m r; do
    case $k in
      cmd*) gd_add_seg "$k" "$m" "$r" ""; case $r in *'<<'*) gd_head "$m"; hd=$GD_HEAD ;; esac ;;
      sub) while IFS=$'\t' read -r k m r; do case $k in cmd*|sub|push|pop) gd_add_seg "$k" "$m" "$r" "" ;; esac; done < <(sp_segments "$r") ;;
      heredoc) gd_add_seg heredoc "$m" "$r" "$hd" ;;
      push|pop) gd_add_seg "$k" "$m" "$r" "" ;;
      assign) a=$(hook_lower "$r"); case $a in *husky=0*|*skip_hooks=*|*lefthook=0*|*skip_simple_git_hooks=*|*pre_commit_allow_no_config=*) GD_HOOKS_BYPASS=1 ;; esac ;;
    esac
  done < <(sp_segments "$1")
}
gd_tokenize() {  # 세그먼트마다 한 줄씩 awk 1회로 토큰화(따옴표 상태가 세그먼트를 넘지 않음; C1). heredoc 본문·push/pop 은 토큰화하지 않음(C2)
  local i=0 s=0 n=0 buf="" toks t r
  while [ "$i" -lt "$GD_N" ]; do
    case ${GD_K[$i]} in
      heredoc|push|pop) r="" ;;
      *) r=${GD_R[$i]}; case $r in *\\) r=${r%?} ;; esac ;;   # 끝의 역슬래시 제거(${r%\\} 는 bash 3.2 에서 길이의 제곱 비용)
    esac
    buf="$buf$r"$'\n'; i=$((i + 1))
  done
  toks=$(sp_tokens_lines "${buf%$'\n'}")
  set -f; IFS=$'\n'; GD_T=($toks); unset IFS; set +f
  GD_TS[0]=0
  for t in ${GD_T[@]+"${GD_T[@]}"}; do                 # 순차 순회(bash 3.2 배열의 인덱스 접근은 O(n); G6)
    if [ "$t" = __SP_SEG__ ]; then GD_TE[$s]=$n; s=$((s + 1)); GD_TS[$s]=$((n + 1)); fi
    n=$((n + 1))
  done
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
gd_push() {  # 서브셸·명령 치환 시작: 디렉터리 상태 저장
  GD_SP=$((GD_SP + 1)); GD_S_EFF[$GD_SP]=$GD_EFF; GD_S_UNK[$GD_SP]=$GD_EFF_UNKNOWN; GD_S_BR[$GD_SP]=$GD_BRANCH_ASSUMED; GD_S_DS[$GD_SP]=$GD_DIRSTACK; GD_S_PREV[$GD_SP]=$GD_PREV
}
gd_pop() {  # 서브셸 끝: 안에서 한 cd 는 밖에 영향이 없다
  [ "$GD_SP" -gt 0 ] || return 0
  GD_EFF=${GD_S_EFF[$GD_SP]}; GD_EFF_UNKNOWN=${GD_S_UNK[$GD_SP]}; GD_BRANCH_ASSUMED=${GD_S_BR[$GD_SP]}; GD_DIRSTACK=${GD_S_DS[$GD_SP]}; GD_PREV=${GD_S_PREV[$GD_SP]}
  GD_SP=$((GD_SP - 1)); GD_BR_DONE=0
}
gd_is_toplevel() { [ -e "$GD_EFF/.git" ]; }   # 유효 디렉터리가 저장소 최상위(워크트리 포함)인가 — fork 없음
gd_rm_target() {  # <target> (rec/force 는 gd_rm 지역변수)
  local p=$1 base tmp=0 cwd=${H_CWD:-$PWD}
  case $p in
    '$TMPDIR'*|'${TMPDIR'*|'$TMP/'*|'${TMP}'*|'$TEMP/'*) return 0 ;;
    '${'*':?'*|'${'*':-'*) ;;
    '$'*|'<('*) [ "$rec" -eq 1 ] && gd_shit 3 rm-root "미확장 변수·명령 치환 대상(값이 비면 루트/홈 삭제): $p"; return 0 ;;   # G1
  esac
  case ${p%/} in .git|*/.git) gd_shit 3 rm-git ".git 디렉터리 삭제: $p"; return 0 ;; esac
  case $p in /tmp/?*|/private/tmp/?*|/var/folders/?*|/private/var/folders/?*|/var/tmp/?*|/private/var/tmp/?*) tmp=1 ;; *) tmp=0 ;; esac
  gd_canon "$p"
  [ "$GD_DOTS" -eq 1 ] && { gd_shit 3 rm-root "상위 디렉터리 전체 삭제: $p"; return 0; }
  case $GD_CP in
    /|"$HOME") gd_shit 3 rm-root "루트/홈 디렉터리 삭제: $p"; return 0 ;;
    "$HOME"/*) case ${GD_CP#"$HOME"/} in */*) ;; *) gd_shit 3 rm-root "홈 바로 아래 디렉터리 삭제: $p"; return 0 ;; esac ;;   # C7: 패턴을 인용
  esac
  case $GD_CP in */.git|*/.git/*) gd_shit 3 rm-git ".git 디렉터리(또는 그 내부) 삭제: $p"; return 0 ;; esac   # G2: 정규화 후(.git/* .git/objects ../x/.git)
  case "$cwd/" in "$GD_CP"/?*) gd_shit 3 rm-root "현재 작업 디렉터리의 상위 디렉터리 삭제: $p"; return 0 ;; esac   # G2: 텍스트 비교(fork 없음) — 임시 경로여도 적용
  if [ "$GD_CP" = "$cwd" ] && [ -e "$GD_CP/.git" ]; then gd_shit 3 rm-root "저장소 최상위(현재 작업 디렉터리) 삭제: $p"; return 0; fi   # G2
  [ "$tmp" -eq 1 ] && return 0          # 임시 디렉터리를 절대 경로로 지정 → 조용히 통과
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
    ntgt=$((ntgt + 1)); gd_rm_target "$t"
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
  GD_BR=$(git -C "$1" --no-optional-locks symbolic-ref --short -q HEAD 2>/dev/null)
  GD_BR_DIR=$1; GD_BR_CACHE=$GD_BR; GD_BR_DONE=1
}
gd_protected() { hook_is_protected_branch "$1"; }   # D11: lib/common.sh 의 단일 구현
gd_git_push() {  # W[] = push 인수
  local w force=0 lease=0 mirror=0 all=0 del=0 dry=0 remote="" nref=0 prot=0 nonprot=0 skip=0 dst src
  for w in ${W[@]+"${W[@]}"}; do
    [ "$skip" -eq 1 ] && { skip=0; continue; }
    case $w in
      --force|-f) force=1 ;; --force-with-lease*|--force-if-includes) lease=1 ;;
      --mirror) mirror=1 ;; --all|--branches) all=1 ;; --delete|-d) del=1 ;; --dry-run|-n) dry=1 ;;
      --no-verify) gd_shit 3 git-no-verify "훅 검증 생략(--no-verify)" ;;
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
  if [ "$nref" -eq 0 ] && [ "$all" -eq 0 ] && [ "$mirror" -eq 0 ]; then gd_branch "$dir"; if gd_protected "$GD_BR"; then prot=1; else nonprot=1; fi; fi
  [ "$GD_HOOKS_BYPASS" -eq 1 ] && gd_shit 2 git-hooks-bypass "git 훅 우회 환경 변수와 함께 push"
  if [ "$prot" -eq 1 ] && [ "$force" -eq 1 ]; then gd_shit 3 git-force-protected "보호 브랜치 강제 푸시"; return 0; fi
  if [ "$prot" -eq 1 ] && [ "$del" -eq 1 ]; then gd_shit 3 git-force-protected "보호 브랜치 원격 삭제"; return 0; fi
  if [ "$force" -eq 1 ] || [ "$lease" -eq 1 ]; then gd_shit 2 git-force "강제 푸시(--force/--force-with-lease)"; return 0; fi
  if [ "$prot" -eq 1 ]; then [ "$GD_ASK_PUSH" = 0 ] || gd_shit 2 git-push-protected "보호 브랜치로 푸시"; return 0; fi
  [ "$GD_ASK_PUSH" = 1 ] && gd_shit 2 git-push "원격 푸시(CLAUDE_GUARD_ASK_ON_PUSH=1)"
  return 0
}
gd_git() {
  local gl gdir sub rest dir w skip=0 amend=0 staged=0 wt=0 dot=0 npath=0 del=0 undo=0 tgt="" nb="" val="" W=()
  gl=$(sp_git_subcmd "$S_R") || return 0
  gdir=${gl%%$'\t'*}; rest=${gl#*$'\t'}; sub=${rest%%$'\t'*}; rest=${rest#*$'\t'}   # (IFS 탭 read 는 빈 필드를 합쳐 버린다)
  [ -n "$sub" ] || return 0
  dir=$GD_EFF; if [ -n "$gdir" ]; then hook_abspath_var "$gdir" "$GD_EFF"; dir=$HOOK_ABS; fi
  if [ -n "$rest" ]; then set -f; IFS=$'\n'; W=($(sp_words "$rest")); unset IFS; set +f; fi
  case $GD_LOW in *core.hookspath=*) case $sub in commit|push|merge|rebase) gd_shit 2 git-hooks-bypass "git 훅 경로 우회(-c core.hooksPath=)" ;; esac ;; esac
  case $sub in
    push) gd_git_push ;;
    commit)
      for w in ${W[@]+"${W[@]}"}; do
        [ "$skip" -eq 1 ] && { skip=0; continue; }
        case $w in
          --no-verify) gd_shit 3 git-no-verify "훅 검증 생략(--no-verify)" ;; --amend) amend=1 ;;
          -m|-F|-C|-c|--author|--date|-t|--template|--fixup|--squash|--reuse-message|--reedit-message|--trailer|--cleanup|--gpg-sign) skip=1 ;;
          --*) ;; -*) case $w in *n*) gd_shit 3 git-no-verify "훅 검증 생략(-n)" ;; esac; case $w in *m*|*F*|*C*|*c*) skip=1 ;; esac ;;
        esac
      done
      [ "$GD_HOOKS_BYPASS" -eq 1 ] && gd_shit 2 git-hooks-bypass "git 훅 우회 환경 변수(HUSKY=0 등)와 함께 commit"
      gd_branch "$dir"
      gd_protected "$GD_BR" && gd_shit 2 git-protected-write "보호 브랜치($GD_BR)에서 직접 커밋 — 브랜치를 먼저 만들지 확인"
      if [ "$amend" -eq 1 ]; then
        if [ "$(git -C "$dir" --no-optional-locks rev-list --count '@{u}..HEAD' 2>/dev/null)" = 0 ]; then gd_shit 2 git-history "이미 푸시된 커밋 amend(히스토리 재작성)"
        else gd_shit 1 git-amend "커밋 amend"; fi
      fi ;;
    merge|cherry-pick|rebase|revert|am)
      for w in ${W[@]+"${W[@]}"}; do case $w in --no-verify) [ "$sub" = merge ] || [ "$sub" = rebase ] && gd_shit 3 git-no-verify "훅 검증 생략(--no-verify)" ;; --abort|--quit|--continue|--skip) undo=1 ;; esac; done
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
      # G8: 브랜치 가정은 switch, 또는 checkout 의 비플래그 인수가 하나뿐이고 그 이름의 경로가 없을 때만(파일 복원과 구분)
      if [ -n "$nb" ]; then GD_BRANCH_ASSUMED=$nb
      elif [ -n "$tgt" ] && [ "$dot" -eq 0 ]; then
        if [ "$sub" = switch ]; then GD_BRANCH_ASSUMED=$tgt
        elif [ "$npath" -eq 1 ]; then case $tgt in /*) [ -e "$tgt" ] || GD_BRANCH_ASSUMED=$tgt ;; *) [ -e "$dir/$tgt" ] || GD_BRANCH_ASSUMED=$tgt ;; esac; fi
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
  local r1='(curl|wget)[^|]*(\|[^|]*)*\|[[:space:]]*(sudo[[:space:]]+)?(env[[:space:]]+)?((ba|z|da|k|fi)?sh([[:space:]]|$)|(python[0-9.]*|perl|ruby|node)([[:space:]]+-)?[[:space:]]*($|[;&|)]))'
  local r2='(bash|sh|zsh|dash|ksh)[[:space:]]+(-c[[:space:]]+)?["'"'"']?\$\((curl|wget)' r3='eval[[:space:]].*\$\((curl|wget)'
  local r4='python[0-9.]*[[:space:]]+-c[[:space:]].*(urllib|requests).*(exec|eval)' r5='(source|\.|bash|sh|zsh|dash|ksh)[[:space:]]+(-s[[:space:]]+)?<\((curl|wget)'
  local r6='>[[:space:]]*/dev/(r?disk|sd|nvme|hd)'
  S_SEV=0; S_RULE=""; S_WHY=""; hook_excerpt "$H_CMD" 120; S_M=$HOOK_EX
  case $GD_LOW in *':(){'*) gd_shit 3 system "포크 폭탄" ;; esac
  [[ $GD_LOW =~ $r6 ]] && gd_shit 3 system "블록 디바이스로 리디렉션"
  if [[ $GD_LOW =~ $r1 ]] || [[ $GD_LOW =~ $r2 ]] || [[ $GD_LOW =~ $r3 ]] || [[ $GD_LOW =~ $r4 ]] || [[ $GD_LOW =~ $r5 ]]; then gd_shit 2 pipe-to-shell "원격 스크립트를 받아 바로 실행"; fi   # G9
  if [ "$S_SEV" -gt "$GD_SEV" ]; then GD_SEV=$S_SEV; GD_RULE=$S_RULE; GD_WHY=$S_WHY; GD_EX=$S_M; fi
}
gd_eval() {  # <segment-index>
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
    kubectl|helm|terraform|tofu|terragrunt|pulumi|aws|gcloud|az|flyctl|fly|heroku|vercel|netlify|wrangler|serverless|sls|sam|cdk|ansible-playbook|docker|docker-compose|gh|fab|cap) gd_infra ;;
    ssh|scp|sftp|rsync) gd_remote ;;
    make|just|task|rake|invoke|inv|npm|pnpm|yarn|bun|twine|uv|poetry|gem|cargo|flit|hatch|pip|pip3|pipx|brew) gd_deploy_runner; gd_publish; gd_privilege ;;
    find|gfind|shred|truncate) gd_dataloss ;;
    su|sudo|doas|systemctl|defaults|spctl|pmset|networksetup|scutil|dscl|visudo|at) gd_privilege ;;
    *) gd_deploy_runner ;;
  esac
  case $S_KIND in *sudo*) gd_privilege ;; esac
  gd_db_orm
  gd_merge
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
  i=0; while [ "$i" -lt "$GD_N" ]; do gd_eval "$i"; i=$((i + 1)); done
fi
gd_finish
