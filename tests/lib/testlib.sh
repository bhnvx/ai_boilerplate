#!/usr/bin/env bash
# tests/lib/testlib.sh — 훅 테스트 공용 라이브러리 (bash 3.2 호환)
# 사용: . "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"; t_setup; ...; t_report
# 전역: T_REPO_ROOT T_HOOKS T_TMP T_HOME T_PROJ(main, upstream origin/main) T_WT(feature/x 워크트리) T_BARE
#       T_RC T_OUT T_ERR(마지막 t_run_hook 결과) T_PASS T_FAIL
# 모든 훅은 "$BASH" "$hook" 로 실행한다(BASH 기본 /bin/bash). 실제 ~/.claude 는 절대 건드리지 않는다.
: "${BASH:=/bin/bash}"
T_REPO_ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
T_HOOKS="$T_REPO_ROOT/claude/global/hooks"
T_PASS=0; T_FAIL=0; T_RC=0; T_OUT=""; T_ERR=""; T_TMP=""

t_git() { git -c user.name=tester -c user.email=tester -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

t_cleanup() { [ -n "$T_TMP" ] && [ "${T_KEEP:-}" != "1" ] && rm -rf "$T_TMP"; return 0; }

# 임시 HOME(공백 포함) + 임시 프로젝트(공백 포함, git main 브랜치, 가짜 upstream) + feature/x 워크트리
t_setup() {
  local base=${TMPDIR:-/tmp}; base=${base%/}
  T_TMP=$(mktemp -d "$base/devset test.XXXXXX") || { echo "mktemp 실패" >&2; exit 1; }
  trap t_cleanup EXIT
  T_HOME="$T_TMP/home dir"; T_PROJ="$T_TMP/proj dir"; T_WT="$T_TMP/wt feature"; T_BARE="$T_TMP/remote.git"
  mkdir -p "$T_HOME/.claude" "$T_PROJ"
  export HOME=$T_HOME GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
  unset CLAUDE_HOOKS_DISABLE CLAUDE_HOOKS_LOG CLAUDE_HOOKS_DEBUG HOOK_FORCE_PARSER
  (
    cd "$T_PROJ" || exit 1
    t_git init -q . && t_git symbolic-ref HEAD refs/heads/main &&
    printf 'hello\n' >README.md && t_git add README.md && t_git commit -q -m init &&
    t_git clone -q --bare . "$T_BARE" && t_git remote add origin "$T_BARE" && t_git fetch -q origin &&
    t_git branch -q --set-upstream-to=origin/main main &&
    t_git worktree add -q "$T_WT" -b feature/x
  ) || { echo "fixture 저장소 생성 실패" >&2; exit 1; }
  return 0
}

# t_make_shim [cmd...] — 지정 명령만 심볼릭 링크한 bin 디렉터리를 만들고 경로를 출력(PATH 제한용)
t_make_shim() {
  local d="$T_TMP/shim" n p
  [ $# -gt 0 ] || set -- bash sh git jq python3 awk sed grep tr date mktemp cat head tail wc cksum \
    dirname basename env uname cut sort uniq cmp mkdir rm cp mv ls chmod touch readlink true false expr sleep kill
  rm -rf "$d"; mkdir -p "$d"
  for n in "$@"; do p=$(command -v "$n" 2>/dev/null) && [ -x "$p" ] && ln -s "$p" "$d/$n"; done
  printf '%s\n' "$d"
}

t_have_jq() { command -v jq >/dev/null 2>&1; }

# t_json_str <string> → JSON 문자열 리터럴
t_json_str() {
  if t_have_jq; then jq -cn --arg s "$1" '$s'
  else python3 -I -S -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; fi
}

# t_pre_json <tool> <tool_input-json> [cwd] [permission_mode] [extra-json-object] → PreToolUse 입력 JSON 한 줄
t_pre_json() {
  local tool=$1 input=$2 cwd=${3:-$T_PROJ} mode=${4:-default} extra=${5:-}
  [ -n "$extra" ] || extra='{}'
  if t_have_jq; then
    jq -cn --arg t "$tool" --argjson i "$input" --arg c "$cwd" --arg m "$mode" --argjson x "$extra" \
      '{session_id:"test",hook_event_name:"PreToolUse",tool_name:$t,tool_input:$i,cwd:$c,permission_mode:$m} + $x'
  else
    python3 -I -S -c 'import json,sys
t,i,c,m,x=sys.argv[1:6]
d={"session_id":"test","hook_event_name":"PreToolUse","tool_name":t,"tool_input":json.loads(i),"cwd":c,"permission_mode":m}
d.update(json.loads(x)); print(json.dumps(d))' "$tool" "$input" "$cwd" "$mode" "$extra"
  fi
}
# t_bash_json "<command>" [cwd] [mode] [extra]  /  t_path_json <tool> <path> [cwd] [mode] [extra]
t_bash_json() { t_pre_json Bash "{\"command\":$(t_json_str "$1")}" "${2:-}" "${3:-}" "${4:-}"; }
t_path_json() { t_pre_json "$1" "{\"file_path\":$(t_json_str "$2")}" "${3:-}" "${4:-}" "${5:-}"; }
# t_bash_json_file <file> [cwd] [mode] [extra] — 명령 문자열을 파일에서 읽는다(큰 명령: Linux 의 인수 128KB 한도 회피)
t_bash_json_file() {
  local f=$1 cwd=${2:-$T_PROJ} mode=${3:-default} extra=${4:-}
  [ -n "$extra" ] || extra='{}'
  if t_have_jq; then
    jq -cn --rawfile s "$f" --arg c "$cwd" --arg m "$mode" --argjson x "$extra" \
      '{session_id:"test",hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$s},cwd:$c,permission_mode:$m} + $x'
  else
    python3 -I -S -c 'import json,sys
f,c,m,x=sys.argv[1:5]
d={"session_id":"test","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":open(f,encoding="utf-8").read()},"cwd":c,"permission_mode":m}
d.update(json.loads(x)); print(json.dumps(d))' "$f" "$cwd" "$mode" "$extra"
  fi
}

# t_run_hook <hook-name|path> <stdin> [args...] → T_RC T_OUT T_ERR
t_run_hook() {
  local h=$1 in=$2; shift 2
  case $h in */*) ;; *) h="$T_HOOKS/$h.sh" ;; esac
  T_OUT=$(printf '%s' "$in" | "$BASH" "$h" "$@" 2>"$T_TMP/stderr.txt"); T_RC=$?
  T_ERR=$(cat "$T_TMP/stderr.txt" 2>/dev/null)
  return 0
}

# t_decision <out> → allow|deny|ask|defer|none(출력 없음)|invalid(JSON 아님)
t_decision() {
  local d
  [ -n "$1" ] || { echo none; return 0; }
  if t_have_jq; then d=$(printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)
  else d=$(printf '%s' "$1" | python3 -I -S -c 'import json,sys
try: print(json.load(sys.stdin).get("hookSpecificOutput",{}).get("permissionDecision","none"))
except Exception: pass' 2>/dev/null); fi
  [ -n "$d" ] || d=invalid
  printf '%s\n' "$d"
}
# t_reason <out> → permissionDecisionReason (없으면 빈 줄)
t_reason() {
  [ -n "$1" ] || { echo; return 0; }
  if t_have_jq; then printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null
  else printf '%s' "$1" | python3 -I -S -c 'import json,sys
try: print(json.load(sys.stdin).get("hookSpecificOutput",{}).get("permissionDecisionReason",""))
except Exception: print("")' 2>/dev/null; fi
}
# t_json_valid <string> → 0 이면 유효한 JSON
t_json_valid() {
  if t_have_jq; then printf '%s' "$1" | jq -e . >/dev/null 2>&1
  else printf '%s' "$1" | python3 -I -S -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; fi
}

t_pass() { T_PASS=$((T_PASS + 1)); [ "${T_VERBOSE:-}" = "1" ] && printf '  ok   %s\n' "$1"; return 0; }
t_fail() { T_FAIL=$((T_FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }

assert_eq() {  # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then t_pass "$1"; else t_fail "$1" "expected=[$2] actual=[$3]"; fi
}
assert_rc() { assert_eq "$1 (rc)" "$2" "$T_RC"; }
assert_contains() {  # <name> <haystack> <needle>
  case $2 in *"$3"*) t_pass "$1" ;; *) t_fail "$1" "missing [$3] in [${2:0:300}]" ;; esac
}
assert_not_contains() {
  case $2 in *"$3"*) t_fail "$1" "unexpected [$3] in [${2:0:300}]" ;; *) t_pass "$1" ;; esac
}
# assert_decision <name> <expected: allow|deny|ask|none> — 마지막 t_run_hook 의 T_OUT 기준
assert_decision() {
  local d; d=$(t_decision "$T_OUT")
  if [ "$d" = "$2" ]; then t_pass "$1"; else t_fail "$1" "expected=$2 actual=$d rc=$T_RC out=[${T_OUT:0:200}] err=[${T_ERR:0:200}]"; fi
}

t_section() { printf '%s\n' "## $1"; }

# t_ms → 벽시계 ms(python3, 없으면 perl, 둘 다 없으면 0). t_under <이름> <ms> <상한 ms> — 시간 상한(스위트에 같은 이름의 정의가 있으면 그것을 쓴다).
# 상한은 이 기계 유휴 중앙값(가장 느린 awk)의 2.5배 이상으로 잡고(GitHub macos-latest 는 1.4–1.5배 느리다) 8000 ms 를 넘지 않게 둔다(훅 제한 10초 안)
t_ms() {
  if command -v python3 >/dev/null 2>&1; then python3 -I -S -c 'import time; print(int(time.time()*1000))'
  elif command -v perl >/dev/null 2>&1; then perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'
  else echo 0; fi
}
t_under() { [ "$2" -lt "$3" ] && t_pass "$1 (${2}ms < ${3}ms)" || t_fail "$1" "${2}ms ≥ ${3}ms"; }

t_report() {
  printf '%s: PASS %d / FAIL %d (bash %s)\n' "${0##*/}" "$T_PASS" "$T_FAIL" "$BASH_VERSION"
  [ "$T_FAIL" -eq 0 ] || exit 1
  exit 0
}
