#!/usr/bin/env bash
# lib/common.sh — ai_boilerplate 훅 공통 함수 (bash 3.2 호환; set -u / set -e 사용 금지)
# 사용법: . "$(cd -P -- "$(dirname -- "$0")" && pwd -P)/lib/common.sh"
# 원칙: 결정은 오직 stdout JSON + exit 0. 파서(jq/python3)가 없으면 조용히 통과(fail-open).
# 전역: HOOK_INPUT(stdin 전체), HOOK_JSON_TOOL(jq|python3|빈값), HOOK_NAME($0 의 basename, .sh 제거)
# 테스트용: HOOK_FORCE_PARSER=jq|python3|none 으로 파서를 강제한다(jq 강제 시 python3 재시도 없음).

HOOK_INPUT=""
HOOK_JSON_TOOL=""
HOOK_NAME=${0##*/}; HOOK_NAME=${HOOK_NAME%.sh}
HOOK_EX=""; HOOK_ABS=""; HOOK_PROT=""; HOOK_PROT_LOADED=0; HOOK_BYTE=0
HOOK_JSON_MAX=10000   # JSON 빌더가 문자열 값을 자르는 길이(코드 포인트 기준 — 바이트가 아님; C8)
# 작업 시간 상한(R5): 훅 제한 시간(settings.json 10초)을 넘기면 판정 없이 통과(fail-open)하므로, 가드는 세그먼트·토큰 반복마다
# hook_time_up 으로 경과 시간을 본다. HOOK_TLIM 초(기본 6; 테스트 전용 env, 숫자가 아니면 상한 없음)에 닿으면 남은 부분을 보지 않고
# too-complex 를 바닥으로 둔다. 개수 상한(세그먼트·토큰·fork)이 평소의 큰 명령을 먼저 막고, 이것은 느린 기계·부하에서의 마지막 안전판이다.
# SECONDS 는 정수 초라 실제로는 5~6초에 멈춘다(환경에서 물려받은 값은 버린다)
SECONDS=0
HOOK_TLIM_S=${HOOK_TLIM:-6}; case $HOOK_TLIM_S in ''|*[!0-9]*) HOOK_TLIM_S=999999 ;; esac
hook_time_up() { [ "$SECONDS" -ge "$HOOK_TLIM_S" ]; }
# SP_SUBFLAT(lib/shellparse.sh P-D)은 가드가 가장 깊은 재파싱 한 번에만 붙이는 내부 인터페이스다 — 환경에서 물려받은 값은 버린다
# (남아 있으면 최상위·얕은 재파싱의 sub RAW 까지 평탄해져 문자열 안의 줄·heredoc 종료 토큰이 사라진다; R6)
unset SP_SUBFLAT
# hook_longhead <세그먼트(MASKED)> → 0 이면 첫 단어(명령 이름)가 4096자를 넘는다 — 실행 파일 이름은 PATH_MAX 를 넘을 수 없다. R5: 그런 머리에
# ${x%% *}·${x#* }·${x##*/} 같은 패턴 제거를 쓰면 bash 3.2 에서 길이의 제곱(150 KB 머리에 20초 넘게)이라 가드는 그 세그먼트를 보지 않고 too-complex 바닥
hook_longhead() { [ "${#1}" -gt 4096 ] || return 1; case ${1:0:4096} in *[[:space:]]*) return 1 ;; esac; return 0; }

# python3 폴백: 인수 VAR=.a.b|.c 마다 첫 non-null/non-false 값을 NUL 로 이어 출력. 선두 필드 "ok".
# 잘못된 UTF-8·홀로 남은 서로게이트 이스케이프(\ud800)는 U+FFFD/'?' 로 바꾸고 계속 진행한다(C3).
HOOK_PY_FIELDS='import json,sys
try:
    d=json.loads(sys.stdin.buffer.read().decode("utf-8","replace"))
except Exception:
    sys.exit(1)
out=["ok"]
for spec in sys.argv[1:]:
    val=None
    for alt in spec.split("=",1)[1].split("|"):
        cur=d
        for k in alt.strip().split("."):
            if k=="": continue
            if isinstance(cur,dict) and k in cur: cur=cur[k]
            else:
                cur=None; break
        if cur is not None and cur is not False:
            val=cur; break
    if val is None or val is False: val=""
    elif val is True: val="true"
    elif not isinstance(val,str): val=json.dumps(val,ensure_ascii=False,separators=(",",":"))
    out.append(val)
sys.stdout.buffer.write("\0".join(out).encode("utf-8","replace"))'

# python3 JSON 빌더: argv[1]=최대 코드 포인트 수, 이후 event key1 value1 [key2 value2]. 잘못된 바이트는 치환한다.
HOOK_PY_JSON='import json,sys
n=int(sys.argv[1]); a=[s.encode("utf-8","replace").decode("utf-8")[:n] for s in sys.argv[2:]]
o={"hookEventName":a[0],a[1]:a[2]}
if len(a)>4 and a[3]: o[a[3]]=a[4]
print(json.dumps({"hookSpecificOutput":o}))'

hook_debug() {
  [ "${CLAUDE_HOOKS_DEBUG:-}" = "1" ] && printf '[%s] %s\n' "$HOOK_NAME" "$*" >&2
  return 0
}

# 파서 감지(한 번만). 반환 0 = 파서 있음, 1 = 없음.
hook_detect_parser() {
  [ -n "$HOOK_JSON_TOOL" ] && return 0
  case ${HOOK_FORCE_PARSER:-} in
    jq)      command -v jq >/dev/null 2>&1 && HOOK_JSON_TOOL=jq ;;
    python3) command -v python3 >/dev/null 2>&1 && HOOK_JSON_TOOL=python3 ;;
    none)    HOOK_JSON_TOOL="" ;;
    *) if command -v jq >/dev/null 2>&1; then HOOK_JSON_TOOL=jq
       elif command -v python3 >/dev/null 2>&1; then HOOK_JSON_TOOL=python3; fi ;;
  esac
  [ -n "$HOOK_JSON_TOOL" ]
}

# stdin 전체를 HOOK_INPUT 에 읽는다(크기 제한 없음). cat 1회(fork 1) — read -d '' 는 바이트 단위 syscall 이라
# 입력 크기에 비례해 느려진다(A3). 끝의 개행은 사라지지만 JSON 에는 영향 없음. 파서도 감지한다. 항상 0.
hook_read_input() {
  HOOK_INPUT=""
  if [ ! -t 0 ]; then HOOK_INPUT=$(cat) || :; fi
  hook_detect_parser
  return 0
}

# 내부: 파서 1회 호출 결과(NUL 구분)를 __ok 와 지정 변수들에 읽는다. $1=jq|python3, 나머지=spec (__expr/__ok 는 호출자 지역변수)
__hook_fields_read() {
  local __tool=$1 __spec __var; shift
  if [ "$__tool" = jq ]; then
    {
      IFS= read -r -d '' __ok || :
      for __spec in "$@"; do __var=${__spec%%=*}; IFS= read -r -d '' "$__var" || :; done
    } < <(printf '%s' "$HOOK_INPUT" | jq -j "$__expr" 2>/dev/null)
  else
    {
      IFS= read -r -d '' __ok || :
      for __spec in "$@"; do __var=${__spec%%=*}; IFS= read -r -d '' "$__var" || :; done
    } < <(printf '%s' "$HOOK_INPUT" | python3 -I -S -c "$HOOK_PY_FIELDS" "$@" 2>/dev/null)
  fi
}

# hook_fields VAR=.path[|.alt.path]... — 파서 1회 호출로 여러 필드를 전역 변수에 넣는다.
# null/false 는 다음 대안으로; 객체·배열·숫자는 JSON 문자열. 반환 0 성공 / 1 파서 없음 / 2 JSON 오류(변수는 빈 값).
# jq 가 거부하는 입력(홀로 남은 \uD800 등)은 python3 가 있으면 python3 로 한 번 재시도한다(C3).
hook_fields() {
  local __spec __var __paths __expr="" __ok="" __rep=' // '
  hook_detect_parser || return 1
  for __spec in "$@"; do
    __var=${__spec%%=*}
    case $__var in [A-Za-z_]*) ;; *) return 2 ;; esac
    eval "$__var=''"
  done
  if [ "$HOOK_JSON_TOOL" = jq ]; then
    for __spec in "$@"; do
      __paths=${__spec#*=}
      __expr="$__expr, (${__paths//|/$__rep} // \"\")"
    done
    __expr="[\"ok\"$__expr] | map(. // \"\" | tostring) | join(\"\\u0000\")"
    __hook_fields_read jq "$@"
    if [ "$__ok" != ok ] && [ "${HOOK_FORCE_PARSER:-}" != jq ] && command -v python3 >/dev/null 2>&1; then
      hook_debug "jq 가 입력을 해석하지 못함 → python3 재시도"
      for __spec in "$@"; do __var=${__spec%%=*}; eval "$__var=''"; done
      __hook_fields_read python3 "$@"
    fi
  else
    __hook_fields_read python3 "$@"
  fi
  [ "$__ok" = ok ] || return 2
  return 0
}

# PreToolUse 공통 필드. 반환 0 성공 / 1 파서 없음 / 2 JSON 오류 → 호출자는 `|| exit 0` (또는 hook_require_pretooluse).
# H_TOOL H_CWD H_MODE(기본 default) H_CMD H_PATH(file_path|notebook_path|path) H_GLOB H_PATTERN H_EVENT H_SOURCE
# H_AGENT(.agent_type — --agent 로 띄운 메인 세션에도 있음) H_AGENT_ID(.agent_id — 서브에이전트/팀원 안에서만; D6)
hook_load_pretooluse() {
  hook_fields H_TOOL=.tool_name H_CWD=.cwd H_MODE=.permission_mode H_CMD=.tool_input.command \
    'H_PATH=.tool_input.file_path|.tool_input.notebook_path|.tool_input.path' \
    H_GLOB=.tool_input.glob H_PATTERN=.tool_input.pattern H_EVENT=.hook_event_name \
    H_SOURCE=.source H_AGENT=.agent_type H_AGENT_ID=.agent_id || return $?
  [ -n "$H_MODE" ] || H_MODE=default
  # 0x1E·0x1F 는 공용 파서가 셸 문자열 안의 개행·탭을 담는 예약 바이트다(lib/shellparse.sh, R4·R6). 명령에 든 0x1E 를 그대로 두면 파서가
  # 줄 구분으로 읽어 heredoc 본문이 일찍 끝나고 뒤 명령이 따옴표에 묻힐 수 있고, 0x1F 는 탭(공백류)으로 되살아난다. 셸에서 둘은 보통 글자라
  # (IFS 가 아니다) 공백으로 바꾸면 한 단어가 갈라져 뒤 명령이 숨는다 — heredoc 구분자(cat <<E␞F 의 본문이 끝나지 않는다)·주석(echo a␞#; rm -rf /
  # 의 # 가 단어 처음이 된다)·대입 경계(x=␞1 git push …). 그래서 둘 다 쓰지 않는 보통 글자 0x1D 로 바꾼다(R6 통합: R4 의 공백 변환을 고친다).
  # R5: ${H_CMD//…} 는 bash 3.2 에서 바꿀 때마다 문자열을 다시 만들어 0x1E 1만 개(10 KB)에 40초를 넘겼다(세 가드가 모두 판정 없이 통과) —
  # tr 1회(선형, 두 바이트를 한 번에). 끝의 줄바꿈은 명령 치환이 지우므로 표시 글자로 지킨다. 둘 중 하나라도 있을 때만 fork 한다
  case $H_CMD in *$'\036'*|*$'\037'*) H_CMD=$(printf '%s.' "$H_CMD" | LC_ALL=C tr '\036\037' '\035\035'); H_CMD=${H_CMD%.} ;; esac
  return 0
}

# 가드용: 필드를 읽고 실패를 처리한다. 파서 없음 → exit 0(fail-open). JSON 해석 실패인데 stdin 이 "tool_name" 을
# 담고 있으면(도구 호출이 분명한데 검사를 못 하는 상황) ask 로 사용자 확인을 요청하고 exit 0 (C3). 성공 시 반환 0.
hook_require_pretooluse() {
  local __rc
  hook_load_pretooluse; __rc=$?
  [ "$__rc" -eq 0 ] && return 0
  if [ "$__rc" -eq 2 ]; then
    case $HOOK_INPUT in
      *'"tool_name"'*) hook_emit_pre ask "확인 필요 [hook:parse-error]: 훅 입력 JSON 을 해석하지 못해 $HOOK_NAME 검사를 건너뛴다 — 명령·경로를 직접 확인할 것" hook:parse-error ;;
    esac
  fi
  exit 0
}

# 내부: hookSpecificOutput JSON 한 줄 (jq -n --arg / python json.dumps — 직접 이스케이프 금지).
# 문자열 값은 HOOK_JSON_MAX 코드 포인트에서 자른다(바이트 슬라이스로 깨진 글자가 생기지 않도록; C8).
__hook_json() {
  hook_detect_parser || return 1
  if [ "$HOOK_JSON_TOOL" = jq ]; then
    jq -cn --arg e "$1" --arg k1 "$2" --arg v1 "$3" --arg k2 "${4:-}" --arg v2 "${5:-}" --argjson n "$HOOK_JSON_MAX" \
      '{hookSpecificOutput:({hookEventName:$e} + {($k1):($v1|.[0:$n])} + (if $k2 == "" then {} else {($k2):($v2|.[0:$n])} end))}'
  else
    python3 -I -S -c "$HOOK_PY_JSON" "$HOOK_JSON_MAX" "$1" "$2" "$3" "${4:-}" "${5:-}"
  fi
}

# hook_emit_pre <allow|deny|ask> <reason> [<rule-id>] — allow 는 출력 없음. 로그는 항상. 호출자가 exit 0.
hook_emit_pre() {
  hook_log "$HOOK_NAME" "$1" "${3:-}" "$2"
  [ "$1" = allow ] && return 0
  __hook_json PreToolUse permissionDecision "$1" permissionDecisionReason "$2"
}

# hook_emit_context <EventName> <text>
hook_emit_context() {
  __hook_json "$1" additionalContext "$2"
}

# hook_emit_system <text> — {"systemMessage": …} 한 줄: 사용자에게 보이는 경고(모델에는 전달되지 않는다). Stop·SubagentStop 알림용
hook_emit_system() {
  hook_detect_parser || return 1
  if [ "$HOOK_JSON_TOOL" = jq ]; then jq -cn --arg m "$1" --argjson n "$HOOK_JSON_MAX" '{systemMessage:($m|.[0:$n])}'
  else python3 -I -S -c 'import json,sys
print(json.dumps({"systemMessage":sys.argv[2].encode("utf-8","replace").decode("utf-8")[:int(sys.argv[1])]}))' "$HOOK_JSON_MAX" "$1"; fi
}

# hook_off <VAR_NAME> — 값이 off|0|false|no (대소문자 무시) 이면 0
hook_off() {
  local __n=$1 __v
  case $__n in [A-Za-z_]*) ;; *) return 1 ;; esac
  eval "__v=\${$__n:-}"
  case $__v in [Oo][Ff][Ff]|0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]) return 0 ;; esac
  return 1
}

# 내부: HOOK_BYTE = 1바이트 문자열의 바이트 값(0..255). LC_ALL=C 인 호출자에서만 쓸 것.
__hook_byte() {
  HOOK_BYTE=0
  [ -n "$1" ] || return 0
  printf -v HOOK_BYTE '%d' "'$1" 2>/dev/null || HOOK_BYTE=0
  [ "$HOOK_BYTE" -lt 0 ] && HOOK_BYTE=$((HOOK_BYTE + 256))
  return 0
}

# hook_excerpt <string> [<n>=120] → HOOK_EX: 앞 n 바이트 이내로 자르되 UTF-8 문자 중간에서 끊지 않는다(fork 없음).
# 로케일과 무관하게 바이트 기준으로 동작한다(local LC_ALL=C). 결과는 항상 유효한 UTF-8 접두(입력이 유효할 때).
hook_excerpt() {
  local LC_ALL=C __s=$1 __n=${2:-120} __t __k=0
  HOOK_EX=$__s
  [ "${#__s}" -gt "$__n" ] || return 0
  HOOK_EX=${__s:0:$__n}; __t=$HOOK_EX
  while [ "$__k" -lt 3 ] && [ -n "$__t" ]; do          # 끝에서부터 연속 바이트(10xxxxxx) 개수를 센다
    __hook_byte "${__t: -1}"
    if [ "$HOOK_BYTE" -ge 128 ] && [ "$HOOK_BYTE" -le 191 ]; then __k=$((__k + 1)); __t=${__t%?}; else break; fi
  done
  [ -n "$__t" ] || return 0
  __hook_byte "${__t: -1}"                               # 그 앞 바이트가 선두 바이트면 길이가 맞는지 확인
  if [ "$HOOK_BYTE" -ge 192 ] && [ "$HOOK_BYTE" -le 223 ]; then [ "$__k" -eq 1 ] || HOOK_EX=${__t%?}
  elif [ "$HOOK_BYTE" -ge 224 ] && [ "$HOOK_BYTE" -le 239 ]; then [ "$__k" -eq 2 ] || HOOK_EX=${__t%?}
  elif [ "$HOOK_BYTE" -ge 240 ]; then [ "$__k" -eq 3 ] || HOOK_EX=${__t%?}
  fi
  return 0
}

# hook_log <hook> <decision> <rule> <excerpt> — CLAUDE_HOOKS_LOG 가 설정된 경우만 append (발췌 ≤ 200 바이트, 한 줄, 유효한 UTF-8)
hook_log() {
  [ -n "${CLAUDE_HOOKS_LOG:-}" ] || return 0
  local __x
  hook_excerpt "${4:-}" 200; __x=$HOOK_EX           # 먼저 자른다(긴 문자열의 ${x//…} 는 bash 3.2 에서 제곱 비용)
  __x=${__x//$'\n'/ }; __x=${__x//$'\r'/ }; __x=${__x//$'\t'/ }
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$1" "$2" "${3:-}" "$__x" \
    >>"$CLAUDE_HOOKS_LOG" 2>/dev/null
  return 0
}

# hook_abspath_var <path> [<base>] → HOOK_ABS (fork 없음). 텍스트 정규화만(파일시스템 접근 없음):
# 선두 ~ / $HOME / ${HOME} → $HOME, 상대경로 → <base>(기본 H_CWD, 없으면 PWD) 기준, // 와 /./ 축약, 끝 / 제거. .. 은 유지.
hook_abspath_var() {
  local __p=$1 __b=${2:-${H_CWD:-$PWD}}
  case $__p in
    '~')           __p=$HOME ;;
    '~/'*)         __p=$HOME${__p#\~} ;;
    '$HOME')       __p=$HOME ;;
    '$HOME/'*)     __p=$HOME${__p#\$HOME} ;;
    '${HOME}')     __p=$HOME ;;
    '${HOME}/'*)   __p=$HOME${__p#\$\{HOME\}} ;;
  esac
  case $__p in /*) ;; *) __p=$__b/$__p ;; esac
  while case $__p in *//*) ;; *) false ;; esac; do __p=${__p//\/\//\/}; done
  while case $__p in */./*) ;; *) false ;; esac; do __p=${__p//\/.\//\/}; done
  case $__p in */.) __p=${__p%/.} ;; esac
  while case $__p in ?*/) ;; *) false ;; esac; do __p=${__p%/}; done
  [ -n "$__p" ] || __p=/
  HOOK_ABS=$__p
  return 0
}

# hook_abspath <path> [<base>] — hook_abspath_var 와 같되 결과를 출력한다($(...) 로 받으면 fork 1회)
hook_abspath() {
  hook_abspath_var "$1" "${2:-}"
  printf '%s\n' "$HOOK_ABS"
}

# hook_lower <string> — tr 1회로 ASCII 소문자화(명령 전체에 한 번만 쓸 것)
hook_lower() {
  printf '%s\n' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

# 보호 브랜치 목록(D11) → HOOK_PROT (공백 구분; 빈값 = 브랜치 규칙 전부 끔). CLAUDE_GUARD_PROTECTED_BRANCHES 는
# 쉼표/공백 구분 목록이고 항목은 셸 글롭일 수 있다(release/*). 값이 none(대소문자 무관) 또는 빈 문자열이면 끔,
# 변수가 아예 설정되지 않은 경우에만 기본값 "main master".
hook_protected_branches() {
  local __v=${CLAUDE_GUARD_PROTECTED_BRANCHES-main master} __o=$-
  __v=${__v//,/ }
  set -f; set -- $__v
  case $__o in *f*) ;; *) set +f ;; esac
  HOOK_PROT=""; HOOK_PROT_LOADED=1
  if [ $# -eq 1 ]; then case $1 in [Nn][Oo][Nn][Ee]) return 0 ;; esac; fi
  HOOK_PROT=$*
  return 0
}

# hook_is_protected_branch <branch> → 0 이면 보호 브랜치(목록 항목은 이름 또는 글롭)
hook_is_protected_branch() {
  local __b __o=$-
  [ -n "${1:-}" ] || return 1
  [ "$HOOK_PROT_LOADED" = 1 ] || hook_protected_branches
  [ -n "$HOOK_PROT" ] || return 1
  set -f
  for __b in $HOOK_PROT; do
    case $1 in $__b) case $__o in *f*) ;; *) set +f ;; esac; return 0 ;; esac
  done
  case $__o in *f*) ;; *) set +f ;; esac
  return 1
}
