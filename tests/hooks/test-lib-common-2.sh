#!/usr/bin/env bash
# tests/hooks/test-lib-common-2.sh — lib/common.sh 회귀 테스트(A3 큰 stdin, C3 서로게이트·파싱 실패 ask, C8 코드 포인트 절단, D6 H_AGENT_ID, D11 보호 브랜치 헬퍼)
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
t_setup
. "$T_HOOKS/lib/common.sh"
NL=$'\n'
t_ms() {
  if command -v python3 >/dev/null 2>&1; then python3 -I -S -c 'import time; print(int(time.time()*1000))'
  elif command -v perl >/dev/null 2>&1; then perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'
  else echo 0; fi
}
t_under() { [ "$2" -lt "$3" ] && t_pass "$1 (${2}ms < ${3}ms)" || t_fail "$1" "${2}ms ≥ ${3}ms"; }
load_with() { HOOK_FORCE_PARSER=$1; HOOK_JSON_TOOL=""; HOOK_INPUT=$2; H_AGENT=x; H_AGENT_ID=x; H_CMD=x; hook_load_pretooluse; LOAD_RC=$?; }

t_section "D6: H_AGENT_ID"
for P in jq python3; do
  command -v "$P" >/dev/null 2>&1 || continue
  load_with "$P" '{"tool_name":"Bash","tool_input":{"command":"ls"},"agent_id":"a-1","agent_type":"implementer"}'
  assert_eq "$P: H_AGENT_ID" a-1 "$H_AGENT_ID"; assert_eq "$P: H_AGENT" implementer "$H_AGENT"
  load_with "$P" '{"tool_name":"Bash","tool_input":{"command":"ls"},"agent_type":"implementer"}'
  assert_eq "$P: H_AGENT_ID empty without agent_id" "" "$H_AGENT_ID"
done

t_section "C3: lone surrogate escape → python3 retry; forced jq → rc 2"
SUR='{"tool_name":"Bash","tool_input":{"command":"git push --force origin main \ud800"}}'
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  load_with jq "$SUR"; assert_eq "forced jq: surrogate → rc 2 (no retry)" 2 "$LOAD_RC"
  load_with "" "$SUR"; assert_eq "auto: surrogate → python3 retry rc 0" 0 "$LOAD_RC"
  assert_eq "auto: parser stays jq" jq "$HOOK_JSON_TOOL"
  assert_contains "auto: command recovered" "$H_CMD" 'git push --force origin main'
fi
if command -v python3 >/dev/null 2>&1; then
  load_with python3 "$SUR"; assert_eq "python3: surrogate → rc 0" 0 "$LOAD_RC"
  assert_contains "python3: command recovered" "$H_CMD" 'git push --force origin main'
fi
HOOK_FORCE_PARSER=""; HOOK_JSON_TOOL=""

t_section "C3: hook_require_pretooluse"
req() { printf '%s' "$2" | env "$1" "$BASH" -c '. "$1/lib/common.sh"; hook_read_input; hook_require_pretooluse; printf "loaded:%s" "$H_TOOL"' guard-x "$T_HOOKS"; }
assert_eq "valid input → continues" "loaded:Bash" "$(req HOOK_FORCE_PARSER= '{"tool_name":"Bash","tool_input":{"command":"ls"}}')"
assert_eq "garbage without tool_name → silent exit" "" "$(req HOOK_FORCE_PARSER= 'not json')"
assert_eq "empty stdin → silent exit" "" "$(req HOOK_FORCE_PARSER= '')"
OUT=$(req HOOK_FORCE_PARSER= '{"tool_name":"Bash","tool_input":{"command":"ls"')
assert_eq "truncated JSON with tool_name → ask" ask "$(t_decision "$OUT")"
assert_contains "parse-error reason names the rule" "$(t_reason "$OUT")" '[hook:parse-error]'
assert_eq "no parser → silent exit" "" "$(req HOOK_FORCE_PARSER=none '{"tool_name":"Bash"')"

t_section "C8: hook_excerpt never splits a UTF-8 character (locale-independent)"
ex() { hook_excerpt "$1" "$2"; printf '%s' "$HOOK_EX"; }
for L in C en_US.UTF-8; do
  export LC_ALL=$L LANG=$L
  assert_eq "$L: ascii cut" abc "$(ex abcdef 3)"
  assert_eq "$L: 4 bytes of 한한한 → 한 (dangling lead byte dropped)" 한 "$(ex 한한한 4)"
  assert_eq "$L: 5 bytes → 한 (partial 2 bytes dropped)" 한 "$(ex 한한한 5)"
  assert_eq "$L: 6 bytes → 한한" 한한 "$(ex 한한한 6)"
  assert_eq "$L: ab + partial → ab" ab "$(ex ab한 4)"
  assert_eq "$L: short string unchanged" 한한한 "$(ex 한한한 120)"
  assert_eq "$L: empty" "" "$(ex '' 5)"
  assert_eq "$L: 2-byte char (é) partial dropped" "a" "$(ex aé 2)"
  assert_eq "$L: 4-byte char (😀) partial dropped" "a" "$(ex a😀 4)"
  assert_eq "$L: 4-byte char complete kept" "a😀" "$(ex a😀 5)"
  long=$(awk 'BEGIN{while(i++<130)printf "a"}'); assert_eq "$L: default 120" 120 "$(ex "$long" | wc -c | tr -d ' ')"
done
unset LC_ALL; export LANG=en_US.UTF-8
assert_eq "locale restored after hook_excerpt" 3 "$(x=한한한; hook_excerpt "$x" 100; printf '%s' "${#x}")"

t_section "C8: JSON builder truncates by code points; hook_log stays valid UTF-8 under C"
long=$(awk 'BEGIN{while(i++<12000)printf "a"}')
for P in jq python3; do
  command -v "$P" >/dev/null 2>&1 || continue
  HOOK_FORCE_PARSER=$P; HOOK_JSON_TOOL=""
  OUT=$(hook_emit_pre deny "$long" r)
  assert_eq "$P: reason cut to HOOK_JSON_MAX code points" "$HOOK_JSON_MAX" "$(t_reason "$OUT" | tr -d '\n' | wc -c | tr -d ' ')"
  KOR=$(awk 'BEGIN{while(i++<300)printf "한"}')
  hook_excerpt "$KOR" 120; OUT=$(LC_ALL=C LANG=C hook_emit_pre deny "차단 [x]: $HOOK_EX — 끝" x)
  printf '%s' "$OUT" | python3 -I -S -c 'import json,sys
r=json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"]
sys.exit(1 if ("�" in r or any(0xD800<=ord(c)<=0xDFFF for c in r) or not r.endswith("끝")) else 0)' 2>/dev/null
  assert_eq "$P: Korean excerpt under C locale → clean reason" 0 "$?"
done
HOOK_FORCE_PARSER=""; HOOK_JSON_TOOL=""
LOG="$T_TMP/hooks.log"; KOR=$(awk 'BEGIN{while(i++<300)printf "가"}')
CLAUDE_HOOKS_LOG=$LOG LC_ALL=C LANG=C hook_log guard-x deny r "$KOR"
python3 -I -S -c 'import sys; f=open(sys.argv[1],"rb").read(); f.decode("utf-8"); sys.exit(0 if len(f.split(b"\t")[4].rstrip(b"\n"))<=200 else 1)' "$LOG" 2>/dev/null
assert_eq "hook_log excerpt under C locale is valid UTF-8 and ≤ 200 bytes" 0 "$?"

t_section "D11: hook_is_protected_branch"
pb() {  # <value|UNSET> <branch> → prints 0/1
  if [ "$1" = UNSET ]; then (unset CLAUDE_GUARD_PROTECTED_BRANCHES; HOOK_PROT_LOADED=0; hook_is_protected_branch "$2"; echo $?)
  else (export CLAUDE_GUARD_PROTECTED_BRANCHES="$1"; HOOK_PROT_LOADED=0; hook_is_protected_branch "$2"; echo $?); fi
}
assert_eq "unset: main protected" 0 "$(pb UNSET main)"
assert_eq "unset: master protected" 0 "$(pb UNSET master)"
assert_eq "unset: dev not protected" 1 "$(pb UNSET dev)"
for v in none NONE None '' ' ' ' none '; do assert_eq "[$v]: main not protected" 1 "$(pb "$v" main)"; done
assert_eq "main,release/*: release/1.0" 0 "$(pb 'main,release/*' release/1.0)"
assert_eq "main,release/*: main" 0 "$(pb 'main,release/*' main)"
assert_eq "main,release/*: dev" 1 "$(pb 'main,release/*' dev)"
assert_eq "main master (spaces)" 0 "$(pb 'main master' master)"
assert_eq "dev: main not protected" 1 "$(pb dev main)"
assert_eq "dev: dev protected" 0 "$(pb dev dev)"
assert_eq "none,main: 'none' is a branch name here" 0 "$(pb 'none,main' main)"
assert_eq "empty branch → 1" 1 "$(pb UNSET '')"
assert_eq "glob does not match slash-less name" 1 "$(pb 'release/*' release)"

t_section "hook_abspath_var mirrors hook_abspath (no fork)"
H_CWD='/base dir'
for p in '~/x//y/' 'rel/./z/.' '$HOME' '${HOME}/a' '/' '../..' '~' '~bob/x'; do
  hook_abspath_var "$p"; assert_eq "abspath_var [$p]" "$(hook_abspath "$p")" "$HOOK_ABS"
done

t_section "A3: hook_read_input is size-independent (2MB stdin)"
awk 'BEGIN{printf "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\",\"content\":\""; s=""; while(length(s)<1000) s=s "a"; for(i=0;i<2000;i++) printf "%s", s; printf "\"}}\n"}' >"$T_TMP/big.json"
t0=$(t_ms)
LEN=$("$BASH" -c '. "$1/lib/common.sh"; hook_read_input; hook_load_pretooluse; printf "%s %s" "${#HOOK_INPUT}" "$H_CMD"' bash "$T_HOOKS" <"$T_TMP/big.json")
t1=$(t_ms)
assert_eq "2MB stdin read fully and parsed" "$(( $(wc -c <"$T_TMP/big.json") - 1 )) ls" "$LEN"
t_under "2MB stdin read+parse" $((t1 - t0)) 1500
t_report
