#!/usr/bin/env bash
# guard-secrets.sh — PreToolUse(Read|Edit|Write|MultiEdit|NotebookEdit|Grep|Bash|Monitor): 비밀 파일 접근 차단/확인
# 결정은 stdout JSON + exit 0 만. 끄기: CLAUDE_GUARD_SECRETS=off
# 설정: CLAUDE_GUARD_SECRET_EXTRA(콜론 구분 글롭 → hard), CLAUDE_GUARD_SECRET_ALLOW(콜론 구분 글롭 → 통과; 먼저 검사)
# 규칙 id: secrets:hard-path soft-path print exfil write source copy remove git-add hard-mention soft env-dump env-secret printer
GS_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
. "$GS_DIR/lib/common.sh"
hook_off CLAUDE_GUARD_SECRETS && exit 0
hook_read_input
hook_require_pretooluse
case $H_TOOL in Read|Edit|Write|MultiEdit|NotebookEdit|Grep|Bash|Monitor) ;; *) exit 0 ;; esac   # D5: Monitor 는 Bash 와 동일

GS_SEV=0; GS_RULE=""; GS_REASON=""          # 심각도: 0 none, 1 ask-low, 2 ask-high, 3 deny
GS_OVERFLOW=0; GS_FORKS=0; GS_FORKCAP=200    # R5: 330 → 200(gawk 는 awk 1회가 약 10 ms — 330개 + 분석 fork 가 유휴에도 5~6초). R4 task2: 파서 overflow 레코드 + sub 재파싱(awk fork) 상한 — 상한 뒤 문자열은 한 세그먼트로 판정하고 too-complex 를 바닥으로(gs_shx)
# R5 작업 상한(넘으면 받은 부분만 판정하고 too-complex 바닥): GS_SEGCAP 세그먼트 수(최상위 + 다시 파싱한 셸 문자열·셸 heredoc 본문 전체 — 문자열마다
# 파서 상한을 새로 받지 않게 남은 몫만 넘긴다), GS_TOKCAP 토큰 수(bash 3.2 배열 접근은 위치에 비례하고 토큰마다 경로 분류를 해 많으면 10초를 넘긴다),
# GS_WORDMAX 단어 길이(${t##*/} 같은 패턴 제거가 bash 3.2 에서 길이의 제곱 — 200 KB 단어 하나에 수십 초. PATH_MAX 보다 긴 단어는 경로로 열 수 없으므로
# 분류하지 않고 바닥만 둔다), GS_AFORKCAP 세그먼트 분석용 fork(echo 의 변수 참조 sp_varrefs — 프로세스 치환이라 bash 3.2 는 약 255번째에 죽는다 — 와
# 코드 heredoc 소문자 변환). 코퍼스 최대는 레코드 15개·단어 70자라 정상 명령은 닿지 않는다. 그래도 느리면 hook_time_up(lib/common.sh)이 멈춘다
# GS_RPMAX 다시 파싱하는 문자열 글자 수 합(문자열 하나의 단어가 수만 개면 파싱·토큰화가 단어 수의 제곱 — 남은 문자열은 한 세그먼트로).
# GS_BUNDLEMAX 짧은 옵션 묶음 길이(gs_bundle 이 글자마다 문자열을 다시 만들어 2000자에 6초)
GS_SEGCAP=2000; GS_TOKCAP=4000; GS_WORDMAX=4096; GS_AFORKS=0; GS_AFORKCAP=100; GS_RPB=0; GS_RPMAX=98304; GS_BUNDLEMAX=256
GS_SUBMAX=4096   # R6 통합: 다시 파싱하지 않고 한 세그먼트로 두는 문자열은 앞 4096자만(머리로 판정 — 1 MB 문자열·셸 heredoc 본문을 통째로 토큰화하면
                 # 공용 파서의 단어 나누기가 BWK awk 에서 길이의 제곱이라 10초 제한을 넘겼고, 토큰 상한을 다 써서 뒤 명령도 보지 못했다)
GS_FXW=0; GS_FXMAX=256   # R6(G-B): find·fd -exec 프로그램을 따로 판정하는 토큰 수 상한(명령마다; gs_fexec)
GS_DMAX=3   # R6(G-A): 셸 문자열을 다시 파싱하는 가장 깊은 깊이(최상위 0 — guard-migrations 와 같은 번호). 깊이 3 문자열 안의 문자열은 한 세그먼트(gs_shx)
GS_GLOBN=0; GS_GLOBMAX=256   # R7(PERF-1): 글롭 {a,b} 대안을 분류하는 수 상한(명령마다 — {a,b} 16개는 대안이 2^16 개라 30초). 넘으면 더 펼치지 않고 too-complex 바닥
GS_C=none                                   # gs_class 결과
GS_PATS=(); GS_EXTRA=(); GS_ALLOW=()
GS_PRINTERS='cat less more head tail bat grep rg egrep fgrep awk sed cut sort uniq strings xxd hexdump od base64 scp rsync curl wget nc tar zip gzip bzip2 xz 7z python node ruby perl php jq yq openssl diff nl tac rev pr fold column comm join paste'
GS_LOADERS='dotenv dotenvx dotenv-cli godotenv env-cmd'   # env 파일을 자식 프로세스에 넘기는 로더(§3.3 규칙 1)

gs_hit() {  # <sev> <rule> <reason> — 더 심각한 결정만 남긴다
  [ "$1" -gt "$GS_SEV" ] || return 0
  GS_SEV=$1; GS_RULE=$2; GS_REASON=$3
}

gs_split_colon() {  # <array-name> <colon-list>
  local __n=$1 __s=$2 __p
  set -f
  IFS=: ; for __p in $__s; do [ -n "$__p" ] && eval "$__n[\${#$__n[@]}]=\$__p"; done
  unset IFS; set +f
}

gs_load_patterns() {
  local f="$GS_DIR/lib/secret-patterns.txt" line
  if [ -r "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}; set -f; set -- $line; set +f
      [ -n "${1:-}" ] && GS_PATS[${#GS_PATS[@]}]=$1
    done <"$f"
  fi
  [ -n "${CLAUDE_GUARD_SECRET_EXTRA:-}" ] && gs_split_colon GS_EXTRA "$CLAUDE_GUARD_SECRET_EXTRA"
  [ -n "${CLAUDE_GUARD_SECRET_ALLOW:-}" ] && gs_split_colon GS_ALLOW "$CLAUDE_GUARD_SECRET_ALLOW"
  return 0
}

# gs_class <token> <lowercased-token> → GS_C=none|hard|soft (fork 없음; 경로 정규화는 hook_abspath_var)
gs_class() {
  local t=$1 l=$2 b lb p abs ext f16=0
  GS_C=none
  [ -n "$t" ] || return 0
  while case $t in ?*/) ;; *) false ;; esac; do t=${t%/}; l=${l%/}; done
  b=${t##*/}; lb=${l##*/}
  for p in ${GS_ALLOW[@]+"${GS_ALLOW[@]}"}; do case $b in $p) return 0 ;; esac; case $t in $p) return 0 ;; esac; done
  for p in ${GS_EXTRA[@]+"${GS_EXTRA[@]}"}; do case $lb in $p) GS_C=hard; return 0 ;; esac; case $l in $p) GS_C=hard; return 0 ;; esac; done
  case $lb in
    *.example|*.sample|*.template|*.dist|*.md|*.pub|*.lock|*.py|*.pyi|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.vue|*.svelte|*.html|*.htm|*.css|*.scss|*.go|*.rs|*.java|*.kt|*.kts|*.rb|*.php|*.sql|*.sh|*.bash|*.zsh|*.swift|*.c|*.h|*.cpp|*.cc|*.cs|*.dart|*.ex|*.exs|*.lua|*.pl|*.r|*.scala|*.tf|*.proto|*.graphql|*.ipynb|*.csv|*.svg|*.png|*.jpg|*.jpeg|*.gif|*.pdf|*.xlsx|*.docx) return 0 ;;
    *.local) ;;                                                 # .env.example.local 류는 실제 값일 수 있다(settings.json 의 .env.*.local)
    *.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|*.kdbx|*.priv|*.priv.*|*.ovpn|*.ppk|*.env|*.token) ;;   # 끝 확장자가 키·인증서·env·토큰이면 중간이 example 이어도 실제 비밀(api.example.com.key)
    *.example.*|*.sample.*|*.template.*|*.dist.*) f16=1 ;;      # F16: 예제·템플릿이 중간 확장자(secrets.example.yml) — 자격 증명 디렉터리 검사만 한다
  esac
  case /$l/ in */tests/fixtures/*|*/test/fixtures/*|*/__fixtures__/*|*/testdata/*) return 0 ;; esac
  [ "$f16" -eq 1 ] || for p in ${GS_PATS[@]+"${GS_PATS[@]}"}; do case $lb in $p) GS_C=hard; return 0 ;; esac; done
  case $t in
    */*|'~'|'$HOME'|'${HOME}')
      hook_abspath_var "$t" "$H_CWD"; abs=$HOOK_ABS
      case $abs in   # 자격 증명 디렉터리·파일(전체 경로 규칙; G19 포함)
        */.ssh|*/.ssh/*|*/.aws|*/.aws/*|*/.config/gcloud|*/.config/gcloud/*|*/.kube|*/.kube/*|*/.gnupg|*/.gnupg/*|*/.docker/config.json|*/.claude/.credentials.json) GS_C=hard; return 0 ;;
        */.config/gh/hosts.yml|*/.vault-token|*/.cargo/credentials|*/.cargo/credentials.*|*/.terraform.d/credentials*|*/.huggingface/token|*/.cache/huggingface/token|*/.azure|*/.azure/*) GS_C=hard; return 0 ;;
        "$HOME/.npmrc"|"$HOME/.pypirc"|"$HOME/.netrc") GS_C=hard; return 0 ;;
      esac
      case /$abs/ in */tests/fixtures/*|*/test/fixtures/*|*/__fixtures__/*|*/testdata/*) return 0 ;; esac ;;
  esac
  [ "$f16" -eq 0 ] || return 0
  case $lb in
    .npmrc|.pypirc|.yarnrc.yml|pip.conf)
      hook_abspath_var "$t" "$H_CWD"; abs=$HOOK_ABS
      case $abs in "$HOME/.npmrc"|"$HOME/.pypirc") GS_C=hard; return 0 ;; esac
      if [ -f "$abs" ] && LC_ALL=C grep -Eq '(_authToken|_auth|_password|password|npmAuthToken)[[:space:]]*[:=][[:space:]]*[^$[:space:]"'"'"']' "$abs" 2>/dev/null; then GS_C=hard; fi
      return 0 ;;
  esac
  case $lb in
    *secret*|*password*|*passwd*|*apikey*|*api_key*|*api-key*|vault*|*.tfvars|*.tfstate|*.tfstate.*|*.jwt|*.p8|*.asc)
      case ${lb#.} in *.*) ext=.${lb##*.} ;; *) ext="" ;; esac
      case $ext in ''|.json|.yaml|.yml|.toml|.ini|.cfg|.conf|.properties|.xml|.txt|.env|.tfvars|.tfstate|.jwt|.p8|.asc|.csv) GS_C=soft ;; esac
      case $lb in *.tfstate.*) GS_C=soft ;; esac ;;
  esac
  return 0
}

# gs_glob_class <glob> <lowercased-glob> → GS_C (Grep 의 glob 인수·Bash 글롭 토큰용; basename 기준)
gs_glob_class() {
  local g=${1##*/} lg=${2##*/} lp p pre body suf a sev=0 c
  GS_C=none
  [ -n "$lg" ] || return 0
  case $lg in *'{'*','*'}'*)   # G18: {a,b} 전개 — 대안마다 분류해 가장 심각한 것을 남긴다
    pre=${lg%%\{*}; body=${lg#*\{}; suf=${body#*\}}; body=${body%%\}*}
    while :; do
      GS_GLOBN=$((GS_GLOBN + 1))   # R7(PERF-1): 대안 수 상한·작업 시간 — 넘으면 남은 대안을 펼치지 않는다(찾은 것 중 가장 심각한 것 + too-complex 바닥)
      if [ "$GS_GLOBN" -gt "$GS_GLOBMAX" ] || hook_time_up; then GS_OVERFLOW=1; break; fi
      case $body in *,*) a=${body%%,*}; body=${body#*,} ;; *) a=$body; body="" ;; esac
      gs_glob_class "$pre$a$suf" "$pre$a$suf"
      case $GS_C in hard) sev=3; break ;; soft) [ "$sev" -lt 2 ] && sev=2 ;; esac   # hard 면 남은 대안은 보지 않는다
      [ -n "$body" ] || break
    done
    case $sev in 3) GS_C=hard ;; 2) GS_C=soft ;; *) GS_C=none ;; esac
    return 0 ;;
  esac
  case $lg in *'['?*']'*)      # G4: 문자 클래스 .[e]nv → 첫 글자로 치환해 분류
    c=$lg
    while case $c in *'['?*']'*) ;; *) false ;; esac; do pre=${c%%\[*}; body=${c#*\[}; suf=${body#*\]}; body=${body%%\]*}; body=${body#!}; c=$pre${body:0:1}$suf; done
    gs_glob_class "$c" "$c"; return 0 ;;
  esac
  lp=${lg%%[\*\?]*}
  if [ "$lp" = "$lg" ]; then gs_class "$g" "$lg"; return 0; fi
  for p in ${GS_PATS[@]+"${GS_PATS[@]}"} ${GS_EXTRA[@]+"${GS_EXTRA[@]}"}; do
    [ "$lg" = "$p" ] && { GS_C=hard; return 0; }
    case $lg in $p) GS_C=hard; return 0 ;; esac
    if [ ${#lp} -ge 2 ]; then case $p in *[\*\?\[]*) ;; "$lp"*) GS_C=hard; return 0 ;; esac; fi
  done
  case $lg in *secret*|*password*|*passwd*|*apikey*|*api_key*|*api-key*|vault*|*.tfvars|*.tfstate*|*.jwt|*.p8|*.asc) GS_C=soft ;; esac
  return 0
}
gs_class_any() {  # <token> <lowercased> → GS_C: 경로 규칙(gs_class) 먼저, 글롭 문자가 있으면 basename 글롭 규칙도(G4)
  gs_class "$1" "$2"
  if [ "$GS_C" = none ]; then case $1 in *[\*\?\[\{]*) gs_glob_class "$1" "$2" ;; esac; fi
  if [ "$GS_C" = soft ]; then case $1 in *://*|'{'*|'['*|*'"'*':'*) GS_C=none ;; esac; fi   # F17: URL·JSON 본문은 경로가 아니다(soft 만)
  return 0
}
gs_pat_in() {  # <lowercased-text> → 0 이면 secret-patterns.txt 글롭과 맞는 부분 문자열이 있다(F4: Bash 사전 필터가 패턴 파일을 따른다)
  local p
  for p in ${GS_PATS[@]+"${GS_PATS[@]}"}; do case $1 in *$p*) return 0 ;; esac; done
  return 1
}
gs_bundle() {  # <-short-flags> <value-letters> → GS_BB(값 옵션 앞의 글자들) GS_BV(첫 값 옵션 글자) GS_BA(그 뒤에 붙은 값)
  local s=${1#-} c o="" k=0
  GS_BB=""; GS_BV=""; GS_BA=""
  # R5: 글자마다 남은 문자열을 다시 만들어 길이의 세제곱 비용(2000자에 6초) — 앞 GS_BUNDLEMAX 글자까지만 읽는다. 그 안에 값 옵션 글자가 없으면 too-complex 바닥
  if [ "${#s}" -gt "$GS_BUNDLEMAX" ]; then o=$s; s=${s:0:$GS_BUNDLEMAX}; fi
  while [ -n "$s" ]; do
    c=${s%"${s#?}"}; s=${s#?}; k=$((k + 1))
    case $2 in *"$c"*) GS_BV=$c; if [ -n "$o" ]; then GS_BA=${o:$k}; else GS_BA=$s; fi; return 0 ;; esac   # 붙은 값은 자르지 않은 원문에서
    GS_BB=$GS_BB$c
  done
  [ -z "$o" ] || GS_OVERFLOW=1
  return 0
}

# gs_scan_text <text> <lowercased-text> → 0 이면 hard 토큰 포함(코드 문자열·heredoc 본문 검사; fork 없음)
# 경로 모양(/ . ~)인 단어만 분류한다(EXTRA 패턴이 있으면 모든 단어) — 순차 순회(C5).
gs_scan_text() {
  local __b __w __all=0
  [ "${#GS_EXTRA[@]}" -eq 0 ] || __all=1
  set -f; IFS=$' \t\'"(),;=<>|&{}[]'
  __b=($2)
  unset IFS; set +f
  for __w in ${__b[@]+"${__b[@]}"}; do
    if [ "$__all" -eq 0 ]; then case $__w in */*|*.*|*'~'*|credentials|_netrc) ;; *) continue ;; esac; fi
    gs_class "$__w" "$__w"
    [ "$GS_C" = hard ] && return 0
  done
  return 1
}

gs_afork() { [ "$GS_AFORKS" -lt "$GS_AFORKCAP" ] || { GS_OVERFLOW=1; return 1; }; GS_AFORKS=$((GS_AFORKS + 1)); }   # R5: 분석용 fork 를 한 번 더 써도 되면 0(센다). 넘으면 그 분석을 건너뛰고 too-complex 바닥
gs_wb() {  # R5: 다시 파싱할 문자열에 줄 파서 상한(SP_WBMAX) — 세그먼트 상한의 남은 몫(테스트가 SP_WBMAX 로 더 낮췄으면 그것)
  GS_WB=$((GS_SEGCAP - GS_N)); [ "$GS_WB" -gt 0 ] || GS_WB=1
  case ${SP_WBMAX:-} in ''|*[!0-9]*) ;; *) [ "$SP_WBMAX" -lt "$GS_WB" ] && GS_WB=$SP_WBMAX ;; esac
}
gs_too_complex() {  # R4 task2: 파서 작업 상한 초과 — 명령을 다 분석하지 못함. 메인은 ask-high, 서브에이전트(agent_id)는 deny. 이미 더 센 결정이 있으면 그대로
  local sev=2 pre="확인 필요"; [ -n "$H_AGENT_ID" ] && { sev=3; pre="차단"; }
  hook_excerpt "$H_CMD" 120
  gs_hit "$sev" secrets:too-complex "$pre [secrets:too-complex]: 명령이 너무 커서 전부 분석하지 못함 — 비밀 접근 여부를 직접 확인할 것: $HOOK_EX"
}
gs_finish() {
  case $GS_SEV in
    3) hook_emit_pre deny "$GS_REASON" "$GS_RULE" ;;
    2) hook_emit_pre ask "$GS_REASON" "$GS_RULE" ;;
    1) case $H_MODE in
         auto|bypassPermissions) hook_emit_pre allow "silenced($H_MODE): $GS_REASON" "$GS_RULE" ;;
         *) hook_emit_pre ask "$GS_REASON" "$GS_RULE" ;;
       esac ;;
  esac
  exit 0
}

# ---- 파일 도구(Read/Edit/Write/MultiEdit/NotebookEdit/Grep) ----
gs_file_tools() {
  local lp
  if [ "${#H_PATH}" -gt "$GS_WORDMAX" ] || [ "${#H_GLOB}" -gt "$GS_WORDMAX" ]; then   # R5: 4096자를 넘는 경로·glob 은 분류(${t##*/}·glob 비교)가 길이의 제곱(100 KB 에 15초 — 10초 제한을 넘겨
    # 판정 없이 통과: .e<* 10만 개>nv 같은 glob 은 .env 와 맞는다). 분석하지 않고 too-complex(메인 ask-high, 서브에이전트 deny)
    if [ -n "$H_AGENT_ID" ]; then gs_hit 3 secrets:too-complex "차단 [secrets:too-complex]: 경로·glob 이 너무 길어 분석하지 못함 — 비밀 파일 접근 여부를 직접 확인할 것"
    else gs_hit 2 secrets:too-complex "확인 필요 [secrets:too-complex]: 경로·glob 이 너무 길어 분석하지 못함 — 비밀 파일 접근 여부를 직접 확인할 것"; fi
    gs_finish
  fi
  if [ -n "$H_PATH" ]; then
    lp=$(hook_lower "$H_PATH")
    gs_class "$H_PATH" "$lp"
    case $GS_C in
      hard) gs_hit 3 secrets:hard-path "비밀 파일 접근 차단 [secrets:hard-path]: $H_PATH. 필요한 값은 사용자가 직접 전달해야 한다(~/.claude/rules/security.md)." ;;
      soft) gs_hit 2 secrets:soft-path "비밀 값이 들어 있을 수 있는 파일 [secrets:soft-path]: $H_PATH. 열어도 되는지 확인." ;;
    esac
  fi
  if [ "$H_TOOL" = Grep ] && [ -n "$H_GLOB" ]; then
    lp=$(hook_lower "$H_GLOB")
    gs_glob_class "$H_GLOB" "$lp"
    case $GS_C in
      hard) gs_hit 3 secrets:hard-path "비밀 파일 접근 차단 [secrets:hard-path]: glob=$H_GLOB. 필요한 값은 사용자가 직접 전달해야 한다(~/.claude/rules/security.md)." ;;
      soft) gs_hit 2 secrets:soft-path "비밀 값이 들어 있을 수 있는 파일 [secrets:soft-path]: glob=$H_GLOB. 열어도 되는지 확인." ;;
    esac
    if [ "$GS_OVERFLOW" -eq 1 ]; then   # R7(PERF-1): {…} 대안이 상한을 넘어 다 보지 못함 — too-complex(메인 ask-high, 서브에이전트 deny)
      if [ -n "$H_AGENT_ID" ]; then gs_hit 3 secrets:too-complex "차단 [secrets:too-complex]: glob 의 {…} 대안이 너무 많아 분석하지 못함 — 비밀 파일 접근 여부를 직접 확인할 것"
      else gs_hit 2 secrets:too-complex "확인 필요 [secrets:too-complex]: glob 의 {…} 대안이 너무 많아 분석하지 못함 — 비밀 파일 접근 여부를 직접 확인할 것"; fi
    fi
  fi
  gs_finish
}
# ---- Bash ----
GS_N=0; GS_K=(); GS_M=(); GS_R=(); GS_E=()  # 작업 세그먼트(kind masked raw envfile); sub·셸 heredoc 은 깊이 GS_DMAX 까지 분해(R6)
GS_SID=(); GS_CUR=0; GS_NSID=0              # 세그먼트가 나온 펼침(0 = 최상위, sub·셸 heredoc 마다 새 번호): 이웃 규칙은 같은 번호끼리만
GS_T=(); GS_L=(); GS_TS=(); GS_TE=()       # 토큰, 소문자 토큰, 세그먼트별 [시작,끝)
GS_HEAD=""; GS_ENVF=""
gs_add_seg() { GS_K[$GS_N]=$1; GS_M[$GS_N]=$2; GS_R[$GS_N]=$3; GS_E[$GS_N]=$GS_ENVF; GS_SID[$GS_N]=$GS_CUR; GS_ENVF=""; GS_N=$((GS_N + 1)); }
gs_head() { set -f; set -- $1; GS_HEAD=${1:-}; set +f; }
gs_expand() {  # <shell-text> <깊이> — 내부 명령 문자열(셸 문자열·파서 P-C 묶음의 셸 heredoc 본문)을 세그먼트로 추가.
  # R6(G-A): 문자열 안의 문자열(sub 줄)도 gs_shx 로 깊이 GS_DMAX 까지 펼친다(guard-migrations gm_sub 와 같은 번호 — 최상위 0, 최상위의 문자열 1, 2, 3).
  # 깊이 GS_DMAX 문자열을 파싱할 때는 SP_SUBFLAT=1 이라 그 안의 문자열(한 세그먼트로 남는다)의 개행·탭이 공백이다(언급 검사가 줄을 넘어 맞는다).
  # 펼침마다 새 GS_CUR 번호(이웃 규칙은 같은 번호끼리만)이고 끝나면 바깥 번호로 돌아간다.
  # sub 마다 < <(…) 를 쓰면 bash 3.2 가 약 250번째에서 죽어(rc 133) 판정 없이 통과한다 — 명령 치환 + heredoc(guard-migrations R11 과 같게)
  # 문자열 안의 heredoc(R4: 개행이 살아 있어 본문이 생긴다)도 최상위처럼 본다(코드 본문은 gs_hdoc, 셸이 읽는 본문은 파서의 P-C 묶음이 sub 줄로 온다)
  local k m r o hd="" cur=$GS_CUR
  GS_NSID=$((GS_NSID + 1)); GS_CUR=$GS_NSID; gs_wb
  if [ "$2" -ge "$GS_DMAX" ]; then o=$(SP_SUBFLAT=1 SP_WBMAX=$GS_WB sp_segments "$1"); else o=$(SP_WBMAX=$GS_WB sp_segments "$1"); fi   # R5: 세그먼트 상한의 남은 몫만
  while IFS=$'\t' read -r k m r; do
    [ "$GS_N" -lt "$GS_SEGCAP" ] || { GS_OVERFLOW=1; break; }
    case $k in
      cmd*) if hook_longhead "$m"; then GS_OVERFLOW=1; hd=""; continue; fi   # R5: 4096자를 넘는 명령 이름은 보지 않는다(lib/common.sh)
            gs_add_seg "$k" "$m" "$r"; case $r in *'<<'*) gs_head "$m"; hd=$GS_HEAD ;; esac ;;
      sub) gs_shx "$r" "$m" $(($2 + 1)) ;;
      heredoc) gs_hdoc "$r" "$hd" ;;
      envfile) GS_ENVF=$r ;;
      overflow) GS_OVERFLOW=1 ;;
    esac
  done <<GSEOF
$o
GSEOF
  GS_CUR=$cur
}
gs_hdoc() {  # <본문> <heredoc 머리> — 코드 heredoc 본문(python/node/ruby/perl/php)은 code 세그먼트(C5).
  # 셸이 스크립트로 읽는 본문(bash <<EOF · cat <<EOF | bash · sudo/docker exec -i/ssh …)은 파서가 heredoc 줄 뒤에 내는 P-C 묶음(sub 줄; 소유권은
  # heredoc 마다, 줄 유지)을 gs_shx 가 그 줄의 문자열처럼 한 번 펼친다(R6 — 예전의 '머리·줄의 마지막 세그먼트가 셸' 어림과 평탄 본문 펼침은 없앴다)
  case $2 in python*|node|ruby|perl|php) gs_add_seg code "$2 <heredoc>" "$1" ;; esac
}
gs_shx() {  # <raw> <masked> <깊이> — 셸 문자열(sub 줄: sh -c·eval·ssh 와 파서 P-C 의 셸 heredoc 본문)을 펼친다(gs_expand).
  # 깊이 GS_DMAX 를 넘는 문자열(가장 깊은 문자열 안의 문자열)은 원래 한 세그먼트다(상한이 아니다). R4 task2·R5: 재파싱 상한(awk fork 수 GS_FORKCAP·
  # 세그먼트 GS_SEGCAP·글자 수 합 GS_RPMAX·작업 시간 — 모든 깊이가 함께 쓴다)을 넘으면 다시 파싱하지 않고 한 세그먼트로 판정한다(앞뒤 세그먼트 판정은
  # 그대로 — 상한 앞의 deny 를 잃지 않게. RAW 의 개행은 파서가 낸 0x1E 그대로 — tr 을 더 부르지 않는다). 다 분석하지 못했으므로 too-complex 가 바닥이다(gs_bash).
  # 한 세그먼트로 둔 문자열도 새 GS_CUR 번호를 받는다(바깥 세그먼트와 이웃이 아니다)
  local cur=$GS_CUR
  if [ "$3" -le "$GS_DMAX" ]; then
    if [ "$GS_FORKS" -lt "$GS_FORKCAP" ] && [ "$GS_N" -lt "$GS_SEGCAP" ] && [ $((GS_RPB + ${#1})) -le "$GS_RPMAX" ] && ! hook_time_up; then
      GS_FORKS=$((GS_FORKS + 1)); GS_RPB=$((GS_RPB + ${#1})); gs_expand "$1" "$3"; return 0
    fi
    GS_OVERFLOW=1
  fi
  GS_NSID=$((GS_NSID + 1)); GS_CUR=$GS_NSID
  if [ "${#1}" -gt "$GS_SUBMAX" ]; then GS_OVERFLOW=1; gs_add_seg sub "${2:0:$GS_SUBMAX}" "${1:0:$GS_SUBMAX}"   # 긴 문자열은 앞부분만(GS_SUBMAX) — 나머지는 too-complex 바닥
  else gs_add_seg sub "$2" "$1"; fi
  GS_CUR=$cur
}
gs_collect() {
  local k m r hd=""
  while IFS=$'\t' read -r k m r; do
    if [ "$GS_N" -ge "$GS_SEGCAP" ] || hook_time_up; then GS_OVERFLOW=1; break; fi   # R5: 세그먼트 상한·작업 시간 — 더 읽지 않는다
    case $k in
      envfile) GS_ENVF=$r ;;   # G3: 파서가 벗긴 러너(uv run --env-file …)의 env 파일 → 다음 cmd 세그먼트에 붙인다
      cmd*) if hook_longhead "$m"; then GS_OVERFLOW=1; hd=""; continue; fi   # R5: 4096자를 넘는 명령 이름은 보지 않는다(lib/common.sh)
            gs_add_seg "$k" "$m" "$r"; case $r in *'<<'*) gs_head "$m"; hd=$GS_HEAD ;; esac ;;
      sub) gs_shx "$r" "$m" 1 ;;   # 최상위의 문자열(셸 heredoc 본문 포함)은 깊이 1
      heredoc) gs_hdoc "$r" "$hd" ;;
      overflow) GS_OVERFLOW=1; break ;;   # R4 task2: 파서 작업 상한 초과
    esac
  done < <(sp_segments "$1")
}
gs_tokenize() {  # 세그먼트마다 한 줄씩 awk 1회 + tr 1회로 토큰화(따옴표 상태가 세그먼트를 넘지 않음; C1). 코드 본문은 토큰화하지 않음(C5)
  local i=0 s=0 n=0 buf="" toks lows t r rr=() lt="" trunc=0
  while [ "$i" -lt "$GS_N" ]; do
    r=${GS_R[$i]}; case $r in *\\) r=${r%?} ;; esac          # 끝의 역슬래시 제거(${r%\\} 는 bash 3.2 에서 길이의 제곱 비용)
    [ "${GS_K[$i]}" = code ] && r=""
    if [ -n "${GS_E[$i]}" ]; then case $r in *' '*) r="${r%% *} --env-file \"${GS_E[$i]}\" ${r#* }" ;; *) r="$r --env-file \"${GS_E[$i]}\"" ;; esac; fi
    rr[$i]=$r; i=$((i + 1))
  done
  printf -v buf '%s\n' ${rr[@]+"${rr[@]}"}   # 세그먼트 원문을 한 번에 줄로 잇는다(buf="$buf$r" 반복은 세그먼트 수의 제곱 비용; I/R4 task2)
  toks=$(sp_tokens_lines "${buf%$'\n'}" keep-empty "$GS_TOKCAP"); lows=$(hook_lower "$toks")   # 빈 인수는 __SP_EMPTY__(grep '' .env; F15). R5: 토큰 상한까지만(넘으면 끝에 __SP_TRUNC__)
  case $toks in *$'\n'__SP_TRUNC__) trunc=1; GS_OVERFLOW=1 ;; esac
  set -f; IFS=$'\n'; GS_T=($toks); GS_L=($lows); unset IFS; set +f
  GS_TS[0]=0
  for t in ${GS_T[@]+"${GS_T[@]}"}; do
    if [ "$t" = __SP_SEG__ ]; then GS_TE[$s]=$n; s=$((s + 1)); GS_TS[$s]=$((n + 1))
    elif [ "${#t}" -gt "$GS_WORDMAX" ]; then lt="$lt $n"; fi   # R5: 아주 긴 단어(아래에서 바꾼다)
    n=$((n + 1))
  done
  [ "$trunc" -eq 0 ] || GS_N=$s   # R5: 토큰 상한 — 상한에 닿은 세그먼트(그 앞 토큰까지)에서 끝내고 뒤 세그먼트는 보지 않는다(too-complex 바닥)
  while [ "$s" -lt "$GS_N" ]; do GS_TE[$s]=$n; s=$((s + 1)); GS_TS[$s]=$n; done
  for t in $lt; do GS_T[$t]=__SP_LONG__; GS_L[$t]=__sp_long__; GS_OVERFLOW=1; done   # R5: 단어 길이 상한 — 분류하지 않고(길이의 제곱 비용) too-complex 바닥
}

gs_redir() {  # <redir_in|redir_out> <target> — GS_C 는 이미 계산됨(gs_eval 지역변수 pr/ex/fam/grh 사용)
  case $GS_C in
    hard) if [ "$1" = redir_in ]; then
            if [ "$fam" = grep ]; then grh=$2; grm="비밀 파일 내용 출력"   # F15: -q/-l/-L/-c 여부는 세그먼트 끝에서 판정
            elif [ "$pr" -eq 1 ]; then gs_hit 3 secrets:print "차단 [secrets:print]: $ex — 비밀 파일 내용 출력"
            else gs_hit 2 secrets:source "확인 필요 [secrets:source]: $ex — 비밀 파일을 입력으로 사용"; fi
          else gs_hit 2 secrets:write "확인 필요 [secrets:write]: $ex — 비밀 파일에 쓰기"; fi ;;
    soft) [ "$1" = redir_in ] && [ "$pr" -eq 1 ] && gs_hit 2 secrets:soft "확인 필요 [secrets:soft]: $ex — 비밀 값이 들어 있을 수 있는 파일($2)" ;;
  esac
  return 0
}
gs_hard() {  # <token> — hard 토큰의 head 별 규칙(gs_eval 지역변수 i m head pos pr ex 사용)
  local t=$1 q=0
  case $m in *"$t"*) ;; *) q=1 ;; esac
  case $head in
    python*|node|ruby|perl|php)
      if [ "$pos" -eq 1 ]; then gs_hit 3 secrets:print "차단 [secrets:print]: $ex — 비밀 파일 내용 출력"
      else gs_hit 2 secrets:hard-mention "확인 필요 [secrets:hard-mention]: $ex — 비밀 파일 경로 사용($t)"; fi ;;
    curl|wget|scp|rsync|nc) gs_hit 3 secrets:exfil "차단 [secrets:exfil]: $ex — 비밀 파일 외부 전송" ;;
    cat) if [ "${px:-0}" -eq 0 ] && [ "$i" -gt 0 ] && [ "${GS_SID[$((i - 1))]}" = "${GS_SID[$i]}" ] && case ${GS_M[$((i - 1))]} in export|'export '*|set|'set -a'*|'set -o allexport'*|eval|'eval '*|env|'env '*) ;; *) false ;; esac; then
           gs_hit 2 secrets:source "확인 필요 [secrets:source]: $ex — 비밀 파일을 셸 환경에 로드"
         elif [ "${px:-0}" -eq 0 ] && [ "$((i + 1))" -lt "$GS_N" ] && [ "${GS_SID[$((i + 1))]}" = "${GS_SID[$i]}" ] && case ${GS_M[$((i + 1))]} in 'export $(…)'*|'export "$(…)'*|'env $(…)'*|'eval $(…)'*|'eval "$(…)'*|'set -a'*|'source <('*|'. <('*) ;; *) false ;; esac; then
           gs_hit 2 secrets:source "확인 필요 [secrets:source]: $ex — 비밀 파일을 셸 환경에 로드"
         else gs_hit 3 secrets:print "차단 [secrets:print]: $ex — 비밀 파일 내용 출력"; fi ;;
    cp|mv|install) gs_hit 2 secrets:copy "확인 필요 [secrets:copy]: $ex — 비밀 파일 복사·이동" ;;
    rm|shred) gs_hit 2 secrets:remove "확인 필요 [secrets:remove]: $ex — 비밀 파일 삭제" ;;
    ls|test|'['|stat|file|touch|chmod|chown|chgrp|wc|du|realpath|dirname|basename|find|mkdir|rmdir|echo|printf) ;;
    source|.) gs_hit 2 secrets:source "확인 필요 [secrets:source]: $ex — 비밀 파일을 셸 환경에 로드" ;;
    git) gs_git_hard "$t" ;;
    grep|rg|egrep|fgrep) grh=$t; grm="비밀 파일 내용 출력" ;;   # F15: 출력 모드(-q -l -L -c)는 세그먼트를 다 읽고 판정
    *) if [ "$pr" -eq 1 ]; then gs_hit 3 secrets:print "차단 [secrets:print]: $ex — 비밀 파일 내용 출력"
       else gs_hit 2 secrets:hard-mention "확인 필요 [secrets:hard-mention]: $ex — 비밀 파일 경로 사용($t)"; fi ;;
  esac
}
gs_git_scan() {  # git: 하위 명령 gsc 와 출력 성격 옵션(gpr 패치, gnc 내용 없음, gpi grep 패턴 자리)을 미리 읽는다(gs_eval 지역변수; F5·4)
  local x=$((j0 + 1)) y sk=0 nx=0 pseen=0
  while [ "$x" -lt "$e" ]; do   # 전역 옵션(-C <dir> -c <k=v> --git-dir=… --no-pager 등)
    y=${GS_T[$x]}; x=$((x + 1))
    if [ "$sk" -eq 1 ]; then sk=0; continue; fi
    case $y in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env|--attr-source|--super-prefix|--*=) sk=1 ;;
      -*) ;;
      *) gsc=$y; break ;;
    esac
  done
  while [ "$x" -lt "$e" ]; do
    y=${GS_T[$x]}; x=$((x + 1))
    case $nx in 1) nx=0; continue ;; 2) nx=0; gpi="$gpi$((x - 1)) "; continue ;; 3) nx=0; gpf="$gpf$((x - 1)) "; continue ;; esac   # 앞 옵션의 값(2 = grep -e 패턴, 3 = -f 패턴 파일)
    [ "$y" = -- ] && break
    case $gsc in
      log|whatchanged) case $y in -p|-u|-U*|--unified|--unified=|--patch|--patch-with-stat|--patch-with-raw|-L*|--word-diff|--word-diff=|--color-words|--color-words=|-c|--cc|--remerge-diff) gpr=1 ;; esac ;;
      status) case $y in --verbose|-v*|-[!-]*v*) gpr=1 ;; esac ;;   # status -v 는 스테이징된 diff 를 출력한다
      show|diff) case $y in
                   -p|-u|-U*|--unified|--unified=|--patch|--patch-with-stat|--patch-with-raw) gpr=1 ;;
                   --stat|--stat=|--numstat|--shortstat|--name-only|--name-status|--summary|--dirstat|--dirstat=|--raw|--no-patch|-s|--quiet) gnc=1 ;;
                 esac ;;
      cat-file) case $y in -t|-s|-e) gnc=1 ;; esac ;;
      rm) [ "$y" = --cached ] && gnc=1 ;;
      grep) case $y in
              -e|--regexp|--regexp=) nx=2; pseen=1 ;;
              -f|--file|--file=) nx=3; pseen=1 ;;
              -A|-B|-C|-m|--max-count|--max-depth|--threads|--after-context|--before-context|--context|--*=) nx=1 ;;
              -l|-L|-c|-q|--name-only|--files-with-matches|--files-without-match|--count|--quiet) gnc=1 ;;
              --*) ;;
              -?*) gs_bundle "$y" efABCm; case $GS_BB in *[lLcq]*) gnc=1 ;; esac
                   case $GS_BV in '') ;; e) pseen=1; [ -z "$GS_BA" ] && nx=2 ;; f) pseen=1; [ -z "$GS_BA" ] && nx=3 ;; *) [ -z "$GS_BA" ] && nx=1 ;; esac ;;
              *) [ "$pseen" -eq 1 ] || { gpi="$gpi$((x - 1)) "; pseen=1; } ;;   # 첫 위치 인수 = 패턴
            esac ;;
    esac
  done
  return 0
}
gs_git_hard() {  # <token> — git 하위 명령별(F5·4): 내용 출력 → print, 메타데이터만 → 없음, 그 밖 → hard-mention(gs_hard 의 q 사용)
  local p="차단 [secrets:print]: $ex — git 이 비밀 파일 내용을 출력"
  case $gsc in
    add) gs_hit 2 secrets:git-add "확인 필요 [secrets:git-add]: $ex — 비밀 파일 스테이징(커밋 유출 위험)"; return 0 ;;
    check-ignore|ls-files) return 0 ;;                                               # 경로만 출력
    status) [ "$gpr" -eq 1 ] && gs_hit 3 secrets:print "$p"; return 0 ;;             # -v 가 아니면 상태만
    rm) [ "$gnc" -eq 1 ] && return 0 ;;                                              # git rm --cached: 추적 해제(안전한 쪽)
    log|whatchanged) [ "$gpr" -eq 1 ] && gs_hit 3 secrets:print "$p"; return 0 ;;   # 패치 없는 log 는 커밋 목록만
    show) if [ "$gpr" -eq 1 ] || [ "$gnc" -eq 0 ]; then gs_hit 3 secrets:print "$p"; return 0; fi
          case $1 in *:*) gs_hit 3 secrets:print "$p"; return 0 ;; esac ;;          # <rev>:<path> 는 --stat 이어도 내용
    diff) if [ "$gpr" -eq 1 ] || [ "$gnc" -eq 0 ]; then gs_hit 3 secrets:print "$p"; return 0; fi ;;
    blame|annotate) gs_hit 3 secrets:print "$p"; return 0 ;;
    cat-file) if [ "$gnc" -eq 0 ]; then gs_hit 3 secrets:print "$p"; return 0; fi ;;
    grep) case $gpi in *" $((j - 1)) "*) return 0 ;; esac                          # 패턴 자리의 .env 는 파일이 아니다
          case $gpf in *" $((j - 1)) "*) gs_hit 2 secrets:hard-mention "확인 필요 [secrets:hard-mention]: $ex — 비밀 파일을 검색 패턴 파일로 사용($1)"; return 0 ;; esac   # C
          if [ "$gnc" -eq 0 ]; then gs_hit 3 secrets:print "$p"; return 0; fi ;;
  esac
  [ "$q" -eq 1 ] || gs_hit 2 secrets:hard-mention "확인 필요 [secrets:hard-mention]: $ex — 비밀 파일 경로 사용($1)"
  return 0
}
gs_git_msg() {  # <flag> — git commit/tag/notes/stash 의 -m/--message 값은 경로가 아니다(-F/--file 은 그대로 분류; 5)
  case $1 in
    -m|--message|--message=) prev=skip ;;
    --*) ;;
    -*m) gs_bundle "$1" mFCctSu; [ "$GS_BV" = m ] && [ -z "$GS_BA" ] && prev=skip ;;   # -am "msg"(-Sm 은 -S<keyid>)
  esac
  return 0
}
gs_gh_msg() {  # <flag> — gh/glab pr·mr·issue·release 의 제목·본문 인라인 값은 경로가 아니다(--body-file·-F 는 그대로 분류; 5)
  case ${GS_T[$((j0 + 1))]:-} in pr|mr|issue|release) ;; *) return 0 ;; esac
  case $head:$1 in
    gh:-t|gh:--title|gh:--title=|gh:-b|gh:--body|gh:--body=|gh:-n|gh:--notes|gh:--notes=) prev=skip ;;
    glab:-t|glab:--title|glab:--title=|glab:-d|glab:--description|glab:--description=|glab:-m|glab:--message|glab:--message=|glab:-N|glab:--notes|glab:--notes=) prev=skip ;;
  esac
  return 0
}
gs_patf() {  # <file> <lowercased> — grep·rg·git grep 의 -f/--file 패턴 파일(C): 내용을 직접 내지는 않지만 일치 줄·-o 로 새므로 ask-high
  gs_class_any "$1" "$2"
  [ "$GS_C" = hard ] && gs_hit 2 secrets:hard-mention "확인 필요 [secrets:hard-mention]: $ex — 비밀 파일을 검색 패턴 파일로 사용($1)"
  return 0
}
gs_scrf() {  # <file> <lowercased> — sed·awk·jq·yq 의 -f/--file/--from-file 스크립트 파일(4): 스크립트 오류가 문제 줄을 그대로 내므로 ask-high
  gs_class_any "$1" "$2"   # soft 는 위치 인수일 때와 같게(출력기면 ask-high; --file=값 이 예전처럼 soft 로 남는다)
  case $GS_C in
    hard) gs_hit 2 secrets:hard-mention "확인 필요 [secrets:hard-mention]: $ex — 비밀 파일을 스크립트 파일로 사용($1)" ;;
    soft) [ "$pr" -eq 1 ] && gs_hit 2 secrets:soft "확인 필요 [secrets:soft]: $ex — 비밀 값이 들어 있을 수 있는 파일($1)" ;;
  esac
  return 0
}
gs_find() {  # find(6): 이름 조건(-name·-iname·-path·-ipath·-wholename·-iwholename; 없으면 시작 경로)이 비밀이고 -exec·-execdir·-ok·-okdir 가
  # 출력기(cat head tail less more base64 xxd od strings nl …·grep 류)·복사(cp mv install)·전송(scp rsync curl -T)이면 그 프로그램이 비밀 경로에 받는 단계(gs_eval 지역변수)
  local x=$((j0 + 1)) y ly v lv neg=0 pre=1 s ls hit="" act=0 g=0 gp="" gpn="" gn=0 up=0 head nc
  local sts=() lsts=() nms=() lnms=() pts=() lpts=()
  while [ "$x" -lt "$e" ]; do
    y=${GS_T[$x]}; ly=${GS_L[$x]}; x=$((x + 1))
    if [ "$g" -eq 1 ]; then   # -exec 묶음 안: ; 또는 {} + 까지
      case $y in
        ';') g=0 ;;
        +) [ "${GS_T[$((x - 2))]:-}" = '{}' ] && g=0 ;;
        -T|--upload-file|--upload-file=) up=1 ;;
        -*) [ "$gp" = grep ] && { head=$gpn; nc=0; gs_grep_nc "$y"; [ "$nc" -eq 1 ] && gn=1; } ;;   # -l -q -c(rg 의 -L 은 --follow)
      esac
      [ "$g" -eq 1 ] && continue
      case $gp in
        print) [ "$act" -lt 3 ] && act=3 ;;
        grep) if [ "$gn" -eq 1 ]; then [ "$act" -lt 2 ] && act=2; else [ "$act" -lt 3 ] && act=3; fi ;;
        copy) [ "$act" -lt 1 ] && act=1 ;;
        curl) [ "$up" -eq 1 ] && act=4 ;;
        exfil) act=4 ;;
      esac
      continue
    fi
    if [ "$pre" -eq 1 ]; then   # find [-H -L -P -D x -Olevel] 시작경로… 식
      case $y in
        -H|-L|-P|-E|-X|-d|-s|-x|-O*) continue ;;
        -D|-f) x=$((x + 1)); continue ;;
        -*|'('|'!'|')'|,) pre=0 ;;
        *) sts[${#sts[@]}]=$y; lsts[${#lsts[@]}]=$ly; continue ;;
      esac
    fi
    case $y in
      '!'|-not) neg=1; continue ;;
      -name|-iname) v=${GS_T[$x]:-}; lv=${GS_L[$x]:-}; x=$((x + 1)); [ "$neg" -eq 0 ] && { nms[${#nms[@]}]=$v; lnms[${#lnms[@]}]=$lv; } ;;
      -path|-ipath|-wholename|-iwholename) v=${GS_T[$x]:-}; lv=${GS_L[$x]:-}; x=$((x + 1)); [ "$neg" -eq 0 ] && { pts[${#pts[@]}]=$v; lpts[${#lpts[@]}]=$lv; } ;;
      -exec|-execdir|-ok|-okdir)
        v=${GS_L[$x]:-}; x=$((x + 1)); v=${v##*/}; g=1; up=0; gn=0; gpn=$v
        case $v in
          cat|less|more|head|tail|bat|strings|xxd|hexdump|od|base64|nl|tac) gp=print ;;
          grep|egrep|fgrep|rg) gp=grep ;;
          cp|mv|install) gp=copy ;;
          scp|rsync) gp=exfil ;;
          curl) gp=curl ;;
          *) gp="" ;;
        esac ;;
    esac
    neg=0
  done
  [ "$act" -gt 0 ] || return 0
  [ "${#sts[@]}" -gt 0 ] || { sts=(.); lsts=(.); }
  if [ "${#nms[@]}" -eq 0 ] && [ "${#pts[@]}" -eq 0 ]; then   # 이름 조건이 없으면 시작 경로 자체(find ~/.ssh -type f -exec cat {} \;)
    x=0; while [ "$x" -lt "${#sts[@]}" ]; do gs_class_any "${sts[$x]}" "${lsts[$x]}"; [ "$GS_C" = hard ] && { hit=${sts[$x]}; break; }; x=$((x + 1)); done
  fi
  x=0; while [ -z "$hit" ] && [ "$x" -lt "${#pts[@]}" ]; do gs_class_any "${pts[$x]}" "${lpts[$x]}"; [ "$GS_C" = hard ] && hit=${pts[$x]}; x=$((x + 1)); done
  x=0; while [ -z "$hit" ] && [ "$x" -lt "${#nms[@]}" ]; do   # -name 은 시작 경로 아래의 이름: 시작경로/이름 으로 분류(자격 증명 디렉터리 포함)
    y=0; while [ "$y" -lt "${#sts[@]}" ]; do
      s=${sts[$y]%/}; ls=${lsts[$y]%/}
      gs_class_any "$s/${nms[$x]}" "$ls/${lnms[$x]}"; [ "$GS_C" = hard ] && { hit=${nms[$x]}; break; }
      y=$((y + 1))
    done
    x=$((x + 1))
  done
  [ -n "$hit" ] || return 0
  case $act in
    4) gs_hit 3 secrets:exfil "차단 [secrets:exfil]: $ex — find 가 찾은 비밀 파일 외부 전송($hit)" ;;
    3) gs_hit 3 secrets:print "차단 [secrets:print]: $ex — find 가 찾은 비밀 파일 내용 출력($hit)" ;;
    2) gs_hit 2 secrets:hard-mention "확인 필요 [secrets:hard-mention]: $ex — find 가 찾은 비밀 파일을 출력 없이 검색($hit)" ;;
    1) gs_hit 2 secrets:copy "확인 필요 [secrets:copy]: $ex — find 가 찾은 비밀 파일 복사·이동($hit)" ;;
  esac
  return 0
}
gs_grep_nc() {  # <flag> — grep 류가 내용을 출력하지 않는 모드(-q -l -L -c, 긴 이름, 묶음 포함)면 nc=1 (F15; gs_eval 지역변수)
  local v=efmABCdD n=qlLc
  [ "$head" = rg ] && { v=efmABCdEgjMrtT; n=qlc; }   # rg: -L 은 --follow, -r 은 --replace(값)
  case $1 in
    --quiet|--silent|--files-with-matches|--files-without-match|--count|--count-matches) nc=1 ;;
    --*) ;;
    -?*) gs_bundle "$1" "$v"; case $GS_BB in *["$n"]*) nc=1 ;; esac ;;
  esac
  return 0
}
gs_secret_name() {  # <VAR_NAME> → 0 이면 비밀스러운 이름
  local re='(^|_)(API_?KEY|KEY|TOKEN|SECRET|PASSWORD|PASSWD|PASS|CREDENTIALS?|AUTH_TOKEN|PRIVATE|CLIENT_SECRET|ACCESS_KEY|SESSION_TOKEN)(_|$)'
  case $1 in PWD|OLDPWD|SSH_AUTH_SOCK|GPG_TTY|GIT_AUTHOR_NAME|GIT_COMMITTER_NAME|PATH) return 1 ;; esac
  [[ $1 =~ $re ]]
}
gs_env_rules() {  # 세그먼트 단위: 환경 덤프(low), 비밀 변수 출력(high), 비밀 출력 명령(high)
  local pm="" rest name nv vre='\$\{?([A-Za-z_][A-Za-z0-9_]*)'
  [ "${px:-0}" -eq 0 ] && [ "$i" -gt 0 ] && pm=${GS_M[$((i - 1))]}   # G-B: -exec 프로그램(px)은 이웃 세그먼트가 없다
  case $m in
    env|printenv|set|export|'export -p'|'declare -x'|'declare -px'|'declare -p'|'typeset -x'|'env -0'|'printenv -0')
      gs_hit 1 secrets:env-dump "확인 필요 [secrets:env-dump]: $ex — 환경 변수 전체 출력" ;;
  esac
  case $r in
    *'jq -n env'*|*'jq -n $ENV'*|*'node -p process.env'*|*'console.log(process.env)'*|*'print(dict(os.environ))'*|*'print(os.environ)'*|*'json.dumps(dict(os.environ))'*)
      gs_hit 1 secrets:env-dump "확인 필요 [secrets:env-dump]: $ex — 환경 변수 전체 출력" ;;
  esac
  case $head in
    echo|printf)   # 정규식(fork 없음)으로 비밀 이름 후보가 있을 때만 따옴표 문맥까지 다시 읽는다(F6)
      rest=$r; nv=0
      case $rest in *'$'*) [ "${#rest}" -le 8192 ] || { GS_OVERFLOW=1; rest=""; } ;; esac   # R5: 참조를 찾을 때마다 ${rest#*…} 가 그 위치의 제곱(100 KB 뒤 $A 하나에 7초) — 긴 글자는 보지 않고 too-complex 바닥
      while [[ $rest =~ $vre ]]; do
        nv=$((nv + 1)); if [ "$nv" -gt 64 ] || hook_time_up; then GS_OVERFLOW=1; break; fi   # R5: 변수 참조는 64개까지(참조마다 남은 글자를 다시 만든다 — 2만 개에 30초)
        name=${BASH_REMATCH[1]}; rest=${rest#*"${BASH_REMATCH[0]}"}
        if gs_secret_name "$name"; then gs_afork && gs_env_refs; break; fi   # R5: sp_varrefs 는 세그먼트마다 프로세스 치환 — 분석 fork 상한(넘으면 too-complex 바닥)
      done ;;
    printenv) [ "$e" -gt "$((j0 + 1))" ] && gs_secret_name "${GS_T[$((j0 + 1))]}" && gs_hit 2 secrets:env-secret "확인 필요 [secrets:env-secret]: $ex — 비밀 환경 변수 출력" ;;
    grep|rg|egrep|fgrep)
      case $pm in env|printenv|set|'export -p'|'declare -x'|'declare -px')
        rest=${m#* }; rest=${rest%% *}; nv=0
        while case $rest in -*) ;; *) false ;; esac; do   # R5: 같은 옵션이 두 번이면(grep -i -i) ${m#*"$rest" } 가 늘 첫 자리로 돌아가 끝없이 돌았다(10초 제한 → 판정 없이 통과) — 32번까지
          nv=$((nv + 1)); [ "$nv" -le 32 ] || { GS_OVERFLOW=1; rest=""; break; }
          rest=${m#*"$rest" }; rest=${rest%% *}
        done
        [ -n "$rest" ] && gs_secret_name "$rest" && gs_hit 2 secrets:env-secret "확인 필요 [secrets:env-secret]: $ex — 비밀 환경 변수 출력" ;;
      esac ;;
  esac
  case $m in
    'gh auth token'*|'gh auth status'*--show-token*|'gcloud auth print-access-token'*|'gcloud auth print-identity-token'*|'gcloud auth application-default print-access-token'*|'aws '*'secretsmanager get-secret-value'*|'aws '*'ssm get-parameter'*--with-decryption*|'aws '*'sts get-session-token'*|'aws configure get '*secret*|'vault kv get'*|'vault read'*|'vault login'*|'op read'*|'op item get'*|'kubectl '*'get secret'*' -o json'*|'kubectl '*'get secret'*' -o yaml'*|'kubectl '*'get secret'*' -ojson'*|'kubectl '*'get secret'*' -oyaml'*|'kubectl '*'get secret'*'-o=json'*|'kubectl '*'get secret'*'-o=yaml'*|'security find-generic-password'*' -w'*|'security find-internet-password'*' -w'*|'keyring get'*|'az keyvault secret show'*|'heroku config'*|'vercel env pull'*|'doppler secrets'*|'sops -d'*|'sops --decrypt'*|'age -d'*|'age --decrypt'*|'gpg -d'*|'gpg --decrypt'*)
      gs_hit 2 secrets:printer "확인 필요 [secrets:printer]: $ex — 비밀 값 출력 명령" ;;
  esac
  case $r in 'kubectl '*jsonpath*'.data'*|'docker inspect'*Env*|'docker container inspect'*Env*) gs_hit 2 secrets:printer "확인 필요 [secrets:printer]: $ex — 비밀 값 출력 명령" ;; esac
  case $m in   # F18: kubectl config view --raw(인수 순서 무관), docker inspect … | jq '…Env…'(Env 필터가 파이프 뒤 세그먼트)
    'kubectl '*) case " $m " in *' config '*) case " $m " in *' view '*) case " $m " in *' --raw '*|*' --raw=1 '*|*' --raw='[tT]*)
      gs_hit 2 secrets:printer "확인 필요 [secrets:printer]: $ex — 비밀 값 출력 명령" ;; esac ;; esac ;; esac ;;
    'docker inspect'*|'docker container inspect'*)
      if [ "${px:-0}" -eq 0 ] && [ "$((i + 1))" -lt "$GS_N" ]; then case ${GS_R[$((i + 1))]} in *Env*) case $H_CMD in *'|'*)
        gs_hit 2 secrets:printer "확인 필요 [secrets:printer]: $ex — 비밀 값 출력 명령(Env)" ;; esac ;; esac; fi ;;
  esac
}
gs_env_refs() {  # echo/printf: 값이 실제로 출력되는 비밀 변수 참조만 잡는다(F6; sp_varrefs awk 1회, gs_eval 지역변수 r ex)
  local nm op cx sh=0
  while IFS=$'\t' read -r nm op cx; do
    case $op in len|:+|+) continue ;; esac   # ${#V} ${V:+x} ${V+x} 는 값을 내보내지 않는다(:- := :? :0 # % / 는 내보낸다)
    if [ "$cx" = s ]; then                  # 작은따옴표 안 = 글자 그대로. 다만 셸·eval 세그먼트가 있으면 그 문자열을 실행할 수 있다
      [ "$sh" -ne 0 ] || { if gs_shell_seg; then sh=2; else sh=1; fi; }
      [ "$sh" -eq 1 ] && continue
    fi
    if gs_secret_name "$nm"; then gs_hit 2 secrets:env-secret "확인 필요 [secrets:env-secret]: $ex — 비밀 환경 변수(\$$nm) 출력"; return 0; fi
  done < <(sp_varrefs "$r")
  return 0
}
gs_shell_seg() {  # → 0 이면 표준 입력·파일·인수로 받은 문자열을 실행할 수 있는 세그먼트가 있다(echo 가 낸 문자열; F6)
  local x=0 y c
  while [ "$x" -lt "$GS_N" ]; do
    gs_head "${GS_M[$x]}"
    case $GS_HEAD in
      eval|source|.|ssh|su|envsubst) return 0 ;;   # envsubst 는 '$TOKEN' 문자열을 값으로 바꿔 낸다
      sh|bash|zsh|dash|ksh|mksh|fish)
        case ${GS_K[$x]} in *xargs*) return 0 ;; esac   # xargs bash -c: 표준 입력이 -c 의 명령 문자열이 된다
        y=${GS_TS[$x]}; c=0
        while [ "$y" -lt "${GS_TE[$x]}" ]; do case ${GS_T[$y]} in --*) ;; -*c*) c=1; break ;; esac; y=$((y + 1)); done
        [ "$c" -eq 1 ] || return 0 ;;
    esac
    x=$((x + 1))
  done
  return 1
}
gs_code() {  # <segment-index> <excerpt> — 코드 heredoc 본문(python/node/ruby/perl/php): 비밀 문자열 접두 검사 후에만 단어 단위 검사(C5)
  local r=${GS_R[$1]} low ex=$2
  gs_afork || return 0   # R5: 코드 heredoc 마다 tr 1회 — 분석 fork 상한(넘으면 too-complex 바닥)
  low=$(hook_lower "$r")
  if [ "${#GS_EXTRA[@]}" -eq 0 ]; then
    case $low in *.env*|*.envrc*|*id_rsa*|*id_ed25519*|*id_ecdsa*|*id_dsa*|*.pem*|*.key*|*.p12*|*.pfx*|*.jks*|*.keystore*|*.kdbx*|*.priv*|*.ovpn*|*.ppk*|*secring*|*credential*|*token.json*|*.token*|*netrc*|*.pgpass*|*.my.cnf*|*.boto*|*.s3cfg*|*.ssh*|*.aws*|*.kube*|*gcloud*|*.gnupg*|*.docker*|*npmrc*|*pypirc*|*vault-token*|*hosts.yml*|*huggingface*|*.azure*|*.cargo*|*.terraform.d*) ;; *) return 0 ;; esac
  fi
  gs_scan_text "$r" "$low" && gs_hit 3 secrets:print "차단 [secrets:print]: $ex — 코드에서 비밀 파일 읽기"
  return 0
}

gs_fexec() {  # find·gfind·fd(fdfind): -exec 로 실행하는 프로그램과 인수를 그 세그먼트의 토큰 범위로 따로 판정한다(G-B — find . -exec cat .env \;
  # 의 .env 는 find 의 인수로는 결정이 없다). 묶음 경계(fxs "처음:끝 …", 끝나지 않은 묶음 fxg·fxp)는 gs_eval 의 토큰 순회가 모은다: find 는 -exec|-execdir|-ok|-okdir
  # 다음 단어부터 ; 또는 {} 바로 뒤의 + 앞까지, fd 는 -x|--exec|-X|--exec-batch 다음부터 ; 앞 또는 세그먼트 끝까지(끝나지 않은 find 묶음도 판정한다 — 파서의
  # 셈과 같게). find 의 셸 -c 묶음(파서와 같은 조건: 프로그램이 셸이고 마지막 단어 앞에 c 가 든 글자 옵션)은 파서가 이미 sub 줄로 펼쳤으므로 다시 보지 않는다.
  # find 자체의 인수 판정은 그대로다. 작업 상한: 명령마다 GS_FXMAX 토큰(묶음마다 1 더) — 넘으면 남은 묶음·토큰은 보지 않고 too-complex 바닥
  # (bash 3.2 배열 접근은 위치에 비례해 토큰 수천 개인 find 를 두 번 읽으면 판정 시간이 두 배다). gs_eval 지역변수 i e fxs fxg fxp fxd
  local g p q h a x y w
  [ "$fxg" -eq 1 ] && [ "$e" -gt "$fxp" ] && fxs="$fxs$fxp:$e "
  for g in $fxs; do
    p=${g%%:*}; q=${g#*:}
    w=$((GS_FXMAX - GS_FXW)); [ "$w" -gt 1 ] || { GS_OVERFLOW=1; return 0; }
    [ $((q - p + 1)) -le "$w" ] || { q=$((p + w - 1)); GS_OVERFLOW=1; }
    GS_FXW=$((GS_FXW + q - p + 1)); h=${GS_L[$p]##*/}
    if [ "$fxd" -eq 0 ]; then case $h in sh|bash|zsh|dash|ksh|mksh)   # 파서가 펼친 셸 문자열(-c 가 마지막 단어 앞)
      x=$((p + 1)); y=0; while [ "$x" -lt $((q - 1)) ]; do case ${GS_T[$x]} in -*[!A-Za-z]*) ;; -*c*) y=1; break ;; esac; x=$((x + 1)); done
      [ "$y" -eq 1 ] && continue ;; esac
    fi
    a=$h; [ "$q" -gt $((p + 1)) ] && { printf -v a '%s ' "${GS_T[@]:$((p + 1)):$((q - p - 1))}"; a="$h ${a% }"; }
    gs_eval "$i" "$p" "$q" "$h" "$a"
  done
  return 0
}
gs_eval() {  # <segment-index> [<처음 토큰> <끝 토큰> <머리> <글자>] — 5개면 find·fd -exec 프로그램(그 세그먼트의 토큰 [처음, 끝))을 따로 판정한다
  # (G-B; gs_fexec). 그때 머리는 프로그램 이름(경로를 뗀 소문자), m·r 은 토큰을 이은 글자, 발췌는 find 세그먼트이고 이웃 세그먼트 규칙(px)은 쓰지 않는다
  local i=$1 m=${GS_M[$1]} r=${GS_R[$1]} k=${GS_K[$1]} head j j0 e t l prev="" pos=0 pat_seen=0 loader=0 ldr=0 dump=0 pr=0 fam="" ex dir rest lr lt \
    dd=0 xl=0 nc=0 grh="" grm="" pyt=0 gsc="" gpr=0 gnc=0 gpi=" " gpf=" " px=0 fx=0 fxd=0 fxg=0 fxp=0 fxl="" fxs=""
  hook_excerpt "$m" 120; ex=$HOOK_EX
  if [ $# -ge 5 ]; then px=1; j0=$2; e=$3; m=$5; r=$5; k=cmd; else j0=${GS_TS[$i]}; e=${GS_TE[$i]}; fi
  j=$j0
  if [ "$k" = code ]; then gs_code "$i" "$ex"; return 0; fi
  if [ "$px" -eq 1 ]; then head=$4; else gs_head "$m"; head=$GS_HEAD; case $head in find|gfind) fx=1 ;; fd|fdfind) fx=1; fxd=1 ;; esac; fi   # fx: -exec 묶음 경계를 모은다(G-B)
  case " $GS_PRINTERS " in *" $head "*|*" ${GS_L[$j0]:-} "*) pr=1 ;; esac   # 대문자 머리(NL .env)도 출력기(G7)
  case " $GS_LOADERS " in *" $head "*) ldr=1 ;; esac
  case $head in
    python*) pr=1; fam=code ;; node|ruby|perl|php) fam=code ;;
    grep|rg|egrep|fgrep) fam=grep ;; sed|awk|jq|yq) fam=script ;; curl|wget) fam=xfer ;;
    git) gs_git_scan ;;
  esac
  [ "$fam" = code ] && case $r in *pytest*) pyt=1 ;; esac   # F17: pytest -k/-m 의 식은 경로가 아니다
  j=$((j + 1))
  while [ "$j" -lt "$e" ]; do
    hook_time_up && { GS_OVERFLOW=1; break; }   # R5: 작업 시간 상한(토큰마다 경로를 분류한다)
    t=${GS_T[$j]}; l=${GS_L[$j]}; j=$((j + 1))
    if [ "$fx" -eq 1 ]; then   # G-B: find·fd 의 -exec 묶음 경계(토큰을 다시 읽지 않게 이 순회에서 모은다 — gs_fexec)
      if [ "$fxg" -eq 1 ]; then
        if [ "$t" = ';' ] || { [ "$fxd" -eq 0 ] && [ "$t" = + ] && [ "$fxl" = '{}' ] && [ $((j - 1)) -gt "$fxp" ]; }; then fxg=0; [ $((j - 1)) -gt "$fxp" ] && fxs="$fxs$fxp:$((j - 1)) "; fi
      else case $fxd:$t in 0:-exec|0:-execdir|0:-ok|0:-okdir|1:-x|1:--exec|1:-X|1:--exec-batch) fxg=1; fxp=$j ;; esac; fi
      fxl=$t
    fi
    case $prev in
      redir_in|redir_out) gs_class_any "$t" "$l"; gs_redir "$prev" "$t"; prev=""; continue ;;
      redir_dup) prev=""; case $t in [0-9]|[0-9][0-9]|-|[0-9]-) continue ;; esac   # >& 2 는 fd 복제, >& 파일 은 쓰기
                 gs_class_any "$t" "$l"; gs_redir redir_out "$t"; continue ;;
      patf) prev=""; gs_patf "$t" "$l"; continue ;;
      scrf) prev=""; gs_scrf "$t" "$l"; continue ;;
      skip) prev=""; continue ;;
      envfile) gs_class "$t" "$l"; [ "$GS_C" = hard ] && loader=1; prev=""; continue ;;
      glob) prev=""; case $t in '!'*) continue ;; esac; gs_glob_class "$t" "$l"   # G4: grep --include / rg -g
            case $GS_C in hard) grh=$t; grm="비밀 파일 글롭 검색($t)" ;; soft) gs_hit 2 secrets:soft "확인 필요 [secrets:soft]: $ex — 비밀 값이 들어 있을 수 있는 파일($t)" ;; esac; continue ;;
      code) gs_scan_text "$t" "$l" && gs_hit 3 secrets:print "차단 [secrets:print]: $ex — 코드에서 비밀 파일 읽기"; prev=""; continue ;;
      body) prev=""; case $t in *=) prev=body ;; esac   # F17: curl -d/--data/-F·wget --post-data 본문(KEY= 다음 값까지)은 경로가 아니다
            gs_class_any "$t" "$l"
            case $GS_C in
              hard) gs_hard "$t" ;;   # -d @.env 는 그대로 exfil
              soft) case $r in *"@$t"*) gs_hit 2 secrets:soft "확인 필요 [secrets:soft]: $ex — 비밀 값이 들어 있을 수 있는 파일($t)" ;; esac ;;   # @파일 업로드만
            esac
            continue ;;
    esac
    rest=${t#"${t%%[!0-9]*}"}; lr=${l#"${l%%[!0-9]*}"}   # 앞의 fd 번호(2 10 100)를 뗀다
    case $rest in
      '<'*|'>'*|'&>'*)   # 파서가 fd 번호·연산자를 한 단어로 준다(2>> 10>> 100>> >| 3<>; A)
        case $rest in '<<'*) case $rest in '<<'|'<<-'|'<<<') prev=skip ;; esac; continue ;; esac   # 구분자·문자열이 따로 온 << EOF·<<< x 만 다음 단어를 건너뛴다. 붙어 있으면(<<EOF 0<<<x) 다음 단어는 실제 인수다
        case $rest in
          '<&'*|'>&'[0-9]|'>&'[0-9][0-9]|'>&-'|'>&'[0-9]'-') continue ;;   # fd 복제·닫기(2>&1 >&2 <&0 >&-)는 파일이 아니다
          '>&'|'>&!'|'>&|') prev=redir_dup; continue ;;   # zsh 의 >&! >&| 는 덮어쓰기 강제 >&
          '>&'*) rest=${rest#>&}; rest=${rest#[|!]}; lr=${lr#>&}; lr=${lr#[|!]}; gs_class_any "$rest" "$lr"; gs_redir redir_out "$rest"; continue ;;   # >&파일 = >파일 2>&1
        esac
        case $rest in *'<'*) dir=redir_in ;; *) dir=redir_out ;; esac
        rest=${rest#&}; rest=${rest#>}; rest=${rest#>}; rest=${rest#[|!]}; rest=${rest#<}; rest=${rest#>}   # >! >>! &>! 는 zsh 의 >| (Bash 도구가 zsh 로 돌 수 있다)
        if [ -z "$rest" ]; then prev=$dir; else
          lr=${lr#&}; lr=${lr#>}; lr=${lr#>}; lr=${lr#[|!]}; lr=${lr#<}; lr=${lr#>}
          gs_class_any "$rest" "$lr"; gs_redir "$dir" "$rest"
        fi
        continue ;;
    esac
    case $l in --env-file|--env-file=|--envfile|--envfile=|--env_file|--env_file=) prev=envfile; continue ;; esac
    if [ "$xl" -eq 1 ]; then case $t in -?*) xl=0 ;; *) continue ;; esac; fi   # F3: zip -x 뒤 글롭 목록(다음 옵션까지)
    [ "$dd" -eq 0 ] && case $t in
      --) dd=1; continue ;;   # 뒤는 모두 위치 인수(grep -- -q .env)
      -?*)
        case $fam in
          grep) case $t in -e|--regexp|--regexp=) prev=skip; pat_seen=1 ;; -f|--file|--file=) prev=patf; pat_seen=1 ;;   # C: -f 패턴 파일은 분류. --regexp=값 은 패턴(5)
                  -e?*|--regexp=*) pat_seen=1 ;; -f?*) pat_seen=1; gs_patf "${t#-f}" "${l#-f}" ;;
                  --include|--include=|-g|--glob|--glob=|--iglob|--iglob=) prev=glob ;;
                  --exclude|--exclude=|--exclude-dir|--exclude-dir=) prev=skip ;;   # F3: 제외 글롭은 읽지 않는다(--exclude-from 은 분류)
                  --*) ;;
                  -?*) if [ "$head" = rg ]; then gs_bundle "$t" efmABCdEgjMrtT; else gs_bundle "$t" efmABCdD; fi   # -rf .env · -qf.env: 묶음의 f(gs_grep_nc 와 같은 값 글자)
                       case $GS_BV in
                         f) pat_seen=1; if [ -z "$GS_BA" ]; then prev=patf; else gs_patf "$GS_BA" "${l:$((${#l} - ${#GS_BA}))}"; fi ;;
                         e) pat_seen=1; [ -z "$GS_BA" ] && prev=skip ;;
                       esac ;;
                esac
                gs_grep_nc "$t" ;;
          script) case $head:$t in   # 4: sed·awk·jq·yq 의 -f/--file/--from-file 스크립트 파일은 건너뛰지 않고 분류한다(gawk·mawk 는 출력기가 아니라 원래 hard-mention)
                    yq:-f|yq:--file) prev=skip; pat_seen=1 ;;   # yq 의 -f 는 --front-matter 값(그대로)
                    yq:--file=*) pat_seen=1 ;;
                    *:-f|*:--file|*:--file=|*:--from-file|*:--from-file=) prev=scrf; pat_seen=1 ;;
                    sed:-f?*|awk:-f?*) pat_seen=1; gs_scrf "${t#-f}" "${l#-f}" ;;
                    *:-e|*:--expression) prev=skip; pat_seen=1 ;;
                    *:-e?*|*:--expression=*) pat_seen=1 ;;
                    sed:-[!-]*) gs_bundle "$t" efl   # -nf .env · -nf.env(묶음의 첫 값 글자가 f 일 때만)
                      if [ "$GS_BV" = f ]; then pat_seen=1; if [ -z "$GS_BA" ]; then prev=scrf; else gs_scrf "$GS_BA" "${l:$((${#l} - ${#GS_BA}))}"; fi; fi ;;
                  esac ;;
          code) case $t in -c|-e|--eval|-p|--print|-r|-ne|-pe|-ce|-le) prev=code ;; -m) prev=skip ;; -k) [ "$pyt" -eq 1 ] && prev=skip ;; esac ;;
          xfer) case $head:$t in *:-o|*:--output|*:-O) prev=redir_out ;;
                  curl:-d|curl:--data|curl:--data-raw|curl:--data-binary|curl:--data-urlencode|curl:--data-ascii|curl:--json|curl:-F|curl:--form|curl:--form-string|\
                  wget:--post-data|wget:--post-data=|wget:--body-data|wget:--body-data=) prev=body ;; esac ;;   # F17: 요청 본문
        esac
        case $head in
          tar|rsync) case $t in --exclude|--exclude=) prev=skip ;; esac ;;                   # F3
          zip) case $t in -x|--exclude) case $r in *@*) ;; *) xl=1 ;; esac ;; esac ;;      # F3: -x@목록파일 류는 그대로 분류
          openssl) case $t in -out|-keyout|-certout) prev=redir_out ;; esac ;;              # F3: 출력 파일 = 쓰기(> 와 같음)
          git) case $gsc in commit|tag|notes|stash) gs_git_msg "$t" ;;                    # 5
                 grep) case $t in --*) ;; -?*) gs_bundle "$t" efABCm; [ "$GS_BV" = f ] && [ -n "$GS_BA" ] && gs_patf "$GS_BA" "${l:$((${#l} - ${#GS_BA}))}" ;; esac ;;   # C: git grep -f.env
               esac ;;
          gh|glab) gs_gh_msg "$t" ;;                                                           # 5
        esac
        if [ "$ldr" -eq 1 ]; then case $t in -e|-f|--file) prev=envfile ;; esac; fi
        continue ;;
    esac
    pos=$((pos + 1))
    if [ "$pos" -eq 1 ] && [ "$pat_seen" -eq 0 ]; then case $fam in grep|script) continue ;; esac; fi
    gs_class_any "$t" "$l"
    case $GS_C in
      hard) if [ "$ldr" -eq 1 ]; then loader=1; else gs_hard "$t"; fi ;;
      soft) if [ "$pr" -eq 1 ] || case $head in cp|scp|rsync|curl|wget) ;; *) false ;; esac; then
              gs_hit 2 secrets:soft "확인 필요 [secrets:soft]: $ex — 비밀 값이 들어 있을 수 있는 파일($t)"; fi ;;
    esac
  done
  if [ "$loader" -eq 1 ]; then   # §3.3 규칙 1 (G3): env 파일 로더 + 출력기/환경 덤프 → deny. 로더만 있으면 none
    lt=${GS_T[$((e - 1))]:-}
    [ "$pr" -eq 1 ] && [ "$fam" != code ] && dump=1
    case $lt in env|printenv|set) dump=1 ;; esac
    case $m in env|'env '*|printenv|'printenv '*|set|'set -o'*|'export -p'*|'declare -x'*|'declare -px'*) dump=1 ;; esac
    case $r in *os.environ*|*process.env*|*printenv*|*getenv*|*'ENV.to_h'*|*'ENV.each'*|*'export -p'*|*'declare -x'*|*'env -0'*) dump=1 ;; esac
    [ "$dump" -eq 1 ] && gs_hit 3 secrets:print "차단 [secrets:print]: $ex — env 파일을 로드해 값을 출력"
  fi
  if [ -n "$grh" ]; then   # F15: 출력 없는 검색(-q -l -L -c)은 내용을 내보내지 않는다 → ask-high
    if [ "$nc" -eq 1 ]; then gs_hit 2 secrets:hard-mention "확인 필요 [secrets:hard-mention]: $ex — 비밀 파일을 출력 없이 검색($grh)"
    else gs_hit 3 secrets:print "차단 [secrets:print]: $ex — $grm"; fi
  fi
  case $head in find|gfind) gs_find ;; esac
  [ "$fx" -eq 0 ] || gs_fexec   # G-B: -exec 프로그램을 따로(한 단계만 — 묶음 안의 find -exec 는 다시 나누지 않는다)
  gs_env_rules
}

gs_bash() {
  local low i
  [ -n "$H_CMD" ] || exit 0
  low=$(hook_lower "$H_CMD")
  if [ "${#GS_EXTRA[@]}" -eq 0 ]; then
    case $low in
      *env*|*set*|*export*|*declare*|*typeset*|*key*|*token*|*secret*|*pass*|*credential*|*private*|*auth*|*vault*|*.pem*|*.p12*|*.pfx*|*.jks*|*.kdbx*|*.priv*|*id_rsa*|*id_ed25519*|*id_ecdsa*|*id_dsa*|*.ssh*|*.aws*|*.kube*|*gcloud*|*.gnupg*|*.docker*|*npmrc*|*pypirc*|*yarnrc*|*pip.conf*|*netrc*|*.pgpass*|*.my.cnf*|*.boto*|*.s3cfg*|*secring*|*.ovpn*|*.ppk*|*.tfvars*|*.tfstate*|*.jwt*|*.p8*|*.asc*|*'gh '*|*'aws '*|*'op '*|*kubectl*|*inspect*|*security*|*keyring*|*heroku*|*doppler*|*sops*|*'age '*|*gpg*|*jq*|*environ*|*hosts.yml*|*huggingface*|*.azure*|*.cargo*|*.terraform.d*) ;;
      *'.'[a-z]*[\*\?\[]*|*'.['*|*'id_'*|*cred*) ;;   # G4: 글롭이 비밀 파일 이름과 일치할 수 있는 형태(.e* .en? .[e]nv id_*)
      *) gs_pat_in "$low" || exit 0 ;;                  # F4: secret-patterns.txt 의 글롭은 파일에서 바로 읽는다(목록과 구성상 동기화)
    esac
  fi
  . "$GS_DIR/lib/shellparse.sh"
  gs_collect "$H_CMD"
  if [ "$GS_N" -gt 0 ]; then
    gs_tokenize
    i=0; while [ "$i" -lt "$GS_N" ]; do hook_time_up && { GS_OVERFLOW=1; break; }; gs_eval "$i"; i=$((i + 1)); done   # R5: 작업 시간 상한
  fi
  [ "$GS_OVERFLOW" -eq 1 ] && gs_too_complex   # R4 task2: 상한 초과 — 받은 세그먼트는 모두 판정하고(상한 앞의 deny 유지) 못 본 부분 때문에 too-complex 를 바닥으로
  gs_finish
}

gs_load_patterns
case $H_TOOL in Bash|Monitor) gs_bash ;; *) gs_file_tools ;; esac
exit 0
