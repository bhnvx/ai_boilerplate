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
GS_C=none                                   # gs_class 결과
GS_PATS=(); GS_EXTRA=(); GS_ALLOW=()
GS_PRINTERS='cat less more head tail bat grep rg egrep fgrep awk sed cut sort uniq strings xxd hexdump od base64 scp rsync curl wget nc tar zip gzip bzip2 xz 7z python node ruby perl php jq yq openssl'
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
  local t=$1 l=$2 b lb p abs ext
  GS_C=none
  [ -n "$t" ] || return 0
  while case $t in ?*/) ;; *) false ;; esac; do t=${t%/}; l=${l%/}; done
  b=${t##*/}; lb=${l##*/}
  for p in ${GS_ALLOW[@]+"${GS_ALLOW[@]}"}; do case $b in $p) return 0 ;; esac; case $t in $p) return 0 ;; esac; done
  for p in ${GS_EXTRA[@]+"${GS_EXTRA[@]}"}; do case $lb in $p) GS_C=hard; return 0 ;; esac; case $l in $p) GS_C=hard; return 0 ;; esac; done
  case $lb in
    *.example|*.sample|*.template|*.dist|*.md|*.pub|*.lock|*.py|*.pyi|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.vue|*.svelte|*.html|*.htm|*.css|*.scss|*.go|*.rs|*.java|*.kt|*.kts|*.rb|*.php|*.sql|*.sh|*.bash|*.zsh|*.swift|*.c|*.h|*.cpp|*.cc|*.cs|*.dart|*.ex|*.exs|*.lua|*.pl|*.r|*.scala|*.tf|*.proto|*.graphql|*.ipynb|*.csv|*.svg|*.png|*.jpg|*.jpeg|*.gif|*.pdf|*.xlsx|*.docx) return 0 ;;
  esac
  case /$l/ in */tests/fixtures/*|*/test/fixtures/*|*/__fixtures__/*|*/testdata/*) return 0 ;; esac
  for p in ${GS_PATS[@]+"${GS_PATS[@]}"}; do case $lb in $p) GS_C=hard; return 0 ;; esac; done
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
      case $body in *,*) a=${body%%,*}; body=${body#*,} ;; *) a=$body; body="" ;; esac
      gs_glob_class "$pre$a$suf" "$pre$a$suf"
      case $GS_C in hard) sev=3 ;; soft) [ "$sev" -lt 2 ] && sev=2 ;; esac
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
  [ "$GS_C" = none ] || return 0
  case $1 in *[\*\?\[\{]*) gs_glob_class "$1" "$2" ;; esac
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
  fi
  gs_finish
}
# ---- Bash ----
GS_N=0; GS_K=(); GS_M=(); GS_R=(); GS_E=()  # 작업 세그먼트(kind masked raw envfile); sub/heredoc 은 깊이 1 로 분해
GS_T=(); GS_L=(); GS_TS=(); GS_TE=()       # 토큰, 소문자 토큰, 세그먼트별 [시작,끝)
GS_HEAD=""; GS_ENVF=""
gs_add_seg() { GS_K[$GS_N]=$1; GS_M[$GS_N]=$2; GS_R[$GS_N]=$3; GS_E[$GS_N]=$GS_ENVF; GS_ENVF=""; GS_N=$((GS_N + 1)); }
gs_head() { set -f; set -- $1; GS_HEAD=${1:-}; set +f; }
gs_expand() {  # <shell-text> — 내부 명령 문자열을 세그먼트로 추가(sub 는 더 분해하지 않음)
  local k m r
  while IFS=$'\t' read -r k m r; do case $k in cmd*|sub) gs_add_seg "$k" "$m" "$r" ;; envfile) GS_ENVF=$r ;; esac; done < <(sp_segments "$1")
}
gs_collect() {
  local k m r hd=""
  while IFS=$'\t' read -r k m r; do
    case $k in
      envfile) GS_ENVF=$r ;;   # G3: 파서가 벗긴 러너(uv run --env-file …)의 env 파일 → 다음 cmd 세그먼트에 붙인다
      cmd*) gs_add_seg "$k" "$m" "$r"; case $r in *'<<'*) gs_head "$m"; hd=$GS_HEAD ;; esac ;;
      sub) gs_expand "$r" ;;
      heredoc) case $hd in
                 sh|bash|zsh|dash|ksh|mksh) gs_expand "$r" ;;
                 python*|node|ruby|perl|php) gs_add_seg code "$hd <heredoc>" "$r" ;;
               esac ;;
    esac
  done < <(sp_segments "$1")
}
gs_tokenize() {  # 세그먼트마다 한 줄씩 awk 1회 + tr 1회로 토큰화(따옴표 상태가 세그먼트를 넘지 않음; C1). 코드 본문은 토큰화하지 않음(C5)
  local i=0 s=0 n=0 buf="" toks lows t r
  while [ "$i" -lt "$GS_N" ]; do
    r=${GS_R[$i]}; case $r in *\\) r=${r%?} ;; esac          # 끝의 역슬래시 제거(${r%\\} 는 bash 3.2 에서 길이의 제곱 비용)
    [ "${GS_K[$i]}" = code ] && r=""
    if [ -n "${GS_E[$i]}" ]; then case $r in *' '*) r="${r%% *} --env-file \"${GS_E[$i]}\" ${r#* }" ;; *) r="$r --env-file \"${GS_E[$i]}\"" ;; esac; fi
    buf="$buf$r"$'\n'; i=$((i + 1))
  done
  toks=$(sp_tokens_lines "${buf%$'\n'}"); lows=$(hook_lower "$toks")
  set -f; IFS=$'\n'; GS_T=($toks); GS_L=($lows); unset IFS; set +f
  GS_TS[0]=0
  for t in ${GS_T[@]+"${GS_T[@]}"}; do
    if [ "$t" = __SP_SEG__ ]; then GS_TE[$s]=$n; s=$((s + 1)); GS_TS[$s]=$((n + 1)); fi
    n=$((n + 1))
  done
  while [ "$s" -lt "$GS_N" ]; do GS_TE[$s]=$n; s=$((s + 1)); GS_TS[$s]=$n; done
}

gs_redir() {  # <redir_in|redir_out> <target> — GS_C 는 이미 계산됨(gs_eval 지역변수 pr/ex 사용)
  case $GS_C in
    hard) if [ "$1" = redir_in ]; then
            if [ "$pr" -eq 1 ]; then gs_hit 3 secrets:print "차단 [secrets:print]: $ex — 비밀 파일 내용 출력"
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
    cat) if [ "$i" -gt 0 ] && case ${GS_M[$((i - 1))]} in export|'export '*|set|'set -a'*|'set -o allexport'*|eval|'eval '*|env|'env '*) ;; *) false ;; esac; then
           gs_hit 2 secrets:source "확인 필요 [secrets:source]: $ex — 비밀 파일을 셸 환경에 로드"
         elif [ "$((i + 1))" -lt "$GS_N" ] && case ${GS_M[$((i + 1))]} in 'export $(…)'*|'export "$(…)'*|'env $(…)'*|'eval $(…)'*|'eval "$(…)'*|'set -a'*|'source <('*|'. <('*) ;; *) false ;; esac; then
           gs_hit 2 secrets:source "확인 필요 [secrets:source]: $ex — 비밀 파일을 셸 환경에 로드"
         else gs_hit 3 secrets:print "차단 [secrets:print]: $ex — 비밀 파일 내용 출력"; fi ;;
    cp|mv|install) gs_hit 2 secrets:copy "확인 필요 [secrets:copy]: $ex — 비밀 파일 복사·이동" ;;
    rm|shred) gs_hit 2 secrets:remove "확인 필요 [secrets:remove]: $ex — 비밀 파일 삭제" ;;
    ls|test|'['|stat|file|touch|chmod|chown|chgrp|wc|du|realpath|dirname|basename|find|mkdir|rmdir|echo|printf) ;;
    source|.) gs_hit 2 secrets:source "확인 필요 [secrets:source]: $ex — 비밀 파일을 셸 환경에 로드" ;;
    git) case $m in 'git add '*) gs_hit 2 secrets:git-add "확인 필요 [secrets:git-add]: $ex — 비밀 파일 스테이징(커밋 유출 위험)" ;;
           *) [ "$q" -eq 1 ] || gs_hit 2 secrets:hard-mention "확인 필요 [secrets:hard-mention]: $ex — 비밀 파일 경로 사용($t)" ;; esac ;;
    *) if [ "$pr" -eq 1 ]; then gs_hit 3 secrets:print "차단 [secrets:print]: $ex — 비밀 파일 내용 출력"
       else gs_hit 2 secrets:hard-mention "확인 필요 [secrets:hard-mention]: $ex — 비밀 파일 경로 사용($t)"; fi ;;
  esac
}
gs_secret_name() {  # <VAR_NAME> → 0 이면 비밀스러운 이름
  local re='(^|_)(API_?KEY|KEY|TOKEN|SECRET|PASSWORD|PASSWD|PASS|CREDENTIALS?|AUTH_TOKEN|PRIVATE|CLIENT_SECRET|ACCESS_KEY|SESSION_TOKEN)(_|$)'
  case $1 in PWD|OLDPWD|SSH_AUTH_SOCK|GPG_TTY|GIT_AUTHOR_NAME|GIT_COMMITTER_NAME|PATH) return 1 ;; esac
  [[ $1 =~ $re ]]
}
gs_env_rules() {  # 세그먼트 단위: 환경 덤프(low), 비밀 변수 출력(high), 비밀 출력 명령(high)
  local pm="" rest name vre='\$\{?([A-Za-z_][A-Za-z0-9_]*)'
  [ "$i" -gt 0 ] && pm=${GS_M[$((i - 1))]}
  case $m in
    env|printenv|set|export|'export -p'|'declare -x'|'declare -px'|'declare -p'|'typeset -x'|'env -0'|'printenv -0')
      gs_hit 1 secrets:env-dump "확인 필요 [secrets:env-dump]: $ex — 환경 변수 전체 출력" ;;
  esac
  case $r in
    *'jq -n env'*|*'jq -n $ENV'*|*'node -p process.env'*|*'console.log(process.env)'*|*'print(dict(os.environ))'*|*'print(os.environ)'*|*'json.dumps(dict(os.environ))'*)
      gs_hit 1 secrets:env-dump "확인 필요 [secrets:env-dump]: $ex — 환경 변수 전체 출력" ;;
  esac
  case $head in
    echo|printf)
      rest=$r
      while [[ $rest =~ $vre ]]; do
        name=${BASH_REMATCH[1]}; rest=${rest#*"${BASH_REMATCH[0]}"}
        gs_secret_name "$name" && gs_hit 2 secrets:env-secret "확인 필요 [secrets:env-secret]: $ex — 비밀 환경 변수(\$$name) 출력"
      done ;;
    printenv) [ "$e" -gt "$((j0 + 1))" ] && gs_secret_name "${GS_T[$((j0 + 1))]}" && gs_hit 2 secrets:env-secret "확인 필요 [secrets:env-secret]: $ex — 비밀 환경 변수 출력" ;;
    grep|rg|egrep|fgrep)
      case $pm in env|printenv|set|'export -p'|'declare -x'|'declare -px')
        rest=${m#* }; rest=${rest%% *}; while case $rest in -*) ;; *) false ;; esac; do rest=${m#*"$rest" }; rest=${rest%% *}; done
        gs_secret_name "$rest" && gs_hit 2 secrets:env-secret "확인 필요 [secrets:env-secret]: $ex — 비밀 환경 변수 출력" ;;
      esac ;;
  esac
  case $m in
    'gh auth token'*|'gh auth status'*--show-token*|'gcloud auth print-access-token'*|'gcloud auth print-identity-token'*|'aws '*'secretsmanager get-secret-value'*|'aws '*'ssm get-parameter'*--with-decryption*|'aws '*'sts get-session-token'*|'aws configure get '*secret*|'vault kv get'*|'vault read'*|'vault login'*|'op read'*|'op item get'*|'kubectl '*'get secret'*' -o json'*|'kubectl '*'get secret'*' -o yaml'*|'kubectl '*'get secret'*' -ojson'*|'kubectl '*'get secret'*' -oyaml'*|'kubectl '*'get secret'*'-o=json'*|'kubectl '*'get secret'*'-o=yaml'*|'security find-generic-password'*' -w'*|'security find-internet-password'*' -w'*|'keyring get'*|'az keyvault secret show'*|'heroku config'*|'vercel env pull'*|'doppler secrets'*|'sops -d'*|'sops --decrypt'*|'age -d'*|'age --decrypt'*|'gpg -d'*|'gpg --decrypt'*)
      gs_hit 2 secrets:printer "확인 필요 [secrets:printer]: $ex — 비밀 값 출력 명령" ;;
  esac
  case $r in 'kubectl '*jsonpath*'.data'*|'docker inspect'*Env*) gs_hit 2 secrets:printer "확인 필요 [secrets:printer]: $ex — 비밀 값 출력 명령" ;; esac
}
gs_code() {  # <segment-index> <excerpt> — 코드 heredoc 본문(python/node/ruby/perl/php): 비밀 문자열 접두 검사 후에만 단어 단위 검사(C5)
  local r=${GS_R[$1]} low ex=$2
  low=$(hook_lower "$r")
  if [ "${#GS_EXTRA[@]}" -eq 0 ]; then
    case $low in *.env*|*.envrc*|*id_rsa*|*id_ed25519*|*id_ecdsa*|*id_dsa*|*.pem*|*.key*|*.p12*|*.pfx*|*.jks*|*.keystore*|*.kdbx*|*.priv*|*.ovpn*|*.ppk*|*secring*|*credential*|*token.json*|*.token*|*netrc*|*.pgpass*|*.my.cnf*|*.boto*|*.s3cfg*|*.ssh*|*.aws*|*.kube*|*gcloud*|*.gnupg*|*.docker*|*npmrc*|*pypirc*|*vault-token*|*hosts.yml*|*huggingface*|*.azure*|*.cargo*|*.terraform.d*) ;; *) return 0 ;; esac
  fi
  gs_scan_text "$r" "$low" && gs_hit 3 secrets:print "차단 [secrets:print]: $ex — 코드에서 비밀 파일 읽기"
  return 0
}

gs_eval() {  # <segment-index>
  local i=$1 m=${GS_M[$1]} r=${GS_R[$1]} k=${GS_K[$1]} head j j0 e t l prev="" pos=0 pat_seen=0 loader=0 ldr=0 dump=0 pr=0 fam="" ex dir rest lr lt
  hook_excerpt "$m" 120; ex=$HOOK_EX; j0=${GS_TS[$i]}; e=${GS_TE[$i]}; j=$j0
  if [ "$k" = code ]; then gs_code "$i" "$ex"; return 0; fi
  gs_head "$m"; head=$GS_HEAD
  case " $GS_PRINTERS " in *" $head "*) pr=1 ;; esac
  case " $GS_LOADERS " in *" $head "*) ldr=1 ;; esac
  case $head in
    python*) pr=1; fam=code ;; node|ruby|perl|php) fam=code ;;
    grep|rg|egrep|fgrep) fam=grep ;; sed|awk|jq|yq) fam=script ;; curl|wget) fam=xfer ;;
  esac
  j=$((j + 1))
  while [ "$j" -lt "$e" ]; do
    t=${GS_T[$j]}; l=${GS_L[$j]}; j=$((j + 1))
    case $prev in
      redir_in|redir_out) gs_class_any "$t" "$l"; gs_redir "$prev" "$t"; prev=""; continue ;;
      skip) prev=""; continue ;;
      envfile) gs_class "$t" "$l"; [ "$GS_C" = hard ] && loader=1; prev=""; continue ;;
      glob) prev=""; case $t in '!'*) continue ;; esac; gs_glob_class "$t" "$l"   # G4: grep --include / rg -g
            case $GS_C in hard) gs_hit 3 secrets:print "차단 [secrets:print]: $ex — 비밀 파일 글롭 검색($t)" ;; soft) gs_hit 2 secrets:soft "확인 필요 [secrets:soft]: $ex — 비밀 값이 들어 있을 수 있는 파일($t)" ;; esac; continue ;;
      code) gs_scan_text "$t" "$l" && gs_hit 3 secrets:print "차단 [secrets:print]: $ex — 코드에서 비밀 파일 읽기"; prev=""; continue ;;
    esac
    case $t in
      [0-9]'<'*|'<'*|[0-9]'>'*|'>'*|'&>'*)
        case $t in *'<<'*) prev=skip; continue ;; '>&'*|[0-9]'>&'*|'<&'*|[0-9]'<&'*) continue ;; esac
        case $t in *'<'*) dir=redir_in ;; *) dir=redir_out ;; esac
        rest=${t#[0-9]}; rest=${rest#&}; rest=${rest#>}; rest=${rest#>}; rest=${rest#|}; rest=${rest#<}
        if [ -z "$rest" ]; then prev=$dir; else
          lr=${l#[0-9]}; lr=${lr#&}; lr=${lr#>}; lr=${lr#>}; lr=${lr#|}; lr=${lr#<}
          gs_class_any "$rest" "$lr"; gs_redir "$dir" "$rest"
        fi
        continue ;;
    esac
    case $l in --env-file|--env-file=|--envfile|--envfile=|--env_file|--env_file=) prev=envfile; continue ;; esac
    case $t in
      -?*)
        case $fam in
          grep) case $t in -e|--regexp|-f|--file) prev=skip; pat_seen=1 ;; -e?*|--regexp=*|-f?*|--file=*) pat_seen=1 ;;
                  --include|--include=|-g|--glob|--glob=|--iglob|--iglob=) prev=glob ;; esac ;;
          script) case $t in -e|-f|--expression|--file|--from-file) prev=skip; pat_seen=1 ;; -e?*|--expression=*|--file=*) pat_seen=1 ;; esac ;;
          code) case $t in -c|-e|--eval|-p|--print|-r|-ne|-pe|-ce|-le) prev=code ;; -m) prev=skip ;; esac ;;
          xfer) case $t in -o|--output|-O) prev=redir_out ;; esac ;;
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
      *) exit 0 ;;
    esac
  fi
  . "$GS_DIR/lib/shellparse.sh"
  gs_collect "$H_CMD"
  [ "$GS_N" -gt 0 ] || gs_finish
  gs_tokenize
  i=0; while [ "$i" -lt "$GS_N" ]; do gs_eval "$i"; i=$((i + 1)); done
  gs_finish
}

gs_load_patterns
case $H_TOOL in Bash|Monitor) gs_bash ;; *) gs_file_tools ;; esac
exit 0
