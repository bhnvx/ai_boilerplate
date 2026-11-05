#!/usr/bin/env bash
# tests/hooks/test-lib-common.sh — lib/common.sh 와 run-hook.sh 테스트 (jq 경로 + python3 폴백)
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
t_setup
. "$T_HOOKS/lib/common.sh"

J='{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp/a b","permission_mode":"acceptEdits","tool_input":{"command":"echo \"hi\"\tx\n","file_path":"/p q","glob":"*.env","pattern":{"k":1}},"source":"startup","agent_type":"implementer"}'

load_with() {  # <parser> <json>
  HOOK_FORCE_PARSER=$1; HOOK_JSON_TOOL=""; HOOK_INPUT=$2
  H_TOOL=x; H_CWD=x; H_MODE=x; H_CMD=x; H_PATH=x; H_GLOB=x; H_PATTERN=x; H_EVENT=x; H_SOURCE=x; H_AGENT=x
  hook_load_pretooluse; LOAD_RC=$?
}
for P in jq python3; do
  if [ "$P" = jq ] && ! command -v jq >/dev/null 2>&1; then continue; fi
  if [ "$P" = python3 ] && ! command -v python3 >/dev/null 2>&1; then continue; fi
  t_section "hook_load_pretooluse ($P)"
  load_with "$P" "$J"
  assert_eq "$P: rc" 0 "$LOAD_RC"
  assert_eq "$P: parser" "$P" "$HOOK_JSON_TOOL"
  assert_eq "$P: H_TOOL" Bash "$H_TOOL"
  assert_eq "$P: H_CWD with space" "/tmp/a b" "$H_CWD"
  assert_eq "$P: H_MODE" acceptEdits "$H_MODE"
  assert_eq "$P: H_CMD keeps tab/newline/quotes" $'echo "hi"\tx\n' "$H_CMD"
  assert_eq "$P: H_PATH" "/p q" "$H_PATH"
  assert_eq "$P: H_GLOB" '*.env' "$H_GLOB"
  assert_eq "$P: H_PATTERN object → JSON" '{"k":1}' "$H_PATTERN"
  assert_eq "$P: H_EVENT" PreToolUse "$H_EVENT"
  assert_eq "$P: H_SOURCE" startup "$H_SOURCE"
  assert_eq "$P: H_AGENT" implementer "$H_AGENT"
  load_with "$P" '{"tool_name":"Read","tool_input":{"notebook_path":"/n.ipynb"}}'
  assert_eq "$P: mode default when absent" default "$H_MODE"
  assert_eq "$P: H_PATH from notebook_path" /n.ipynb "$H_PATH"
  assert_eq "$P: missing fields empty" "" "$H_CMD$H_AGENT$H_CWD"
  load_with "$P" '{"tool_name":"Grep","permission_mode":null,"tool_input":{"path":"~/.aws","file_path":null}}'
  assert_eq "$P: null mode → default" default "$H_MODE"
  assert_eq "$P: H_PATH from path when file_path null" '~/.aws' "$H_PATH"
  load_with "$P" 'not json'
  assert_eq "$P: invalid JSON rc" 2 "$LOAD_RC"
  assert_eq "$P: invalid JSON leaves vars empty" "" "$H_TOOL$H_CMD"

  t_section "hook_emit_pre / hook_emit_context ($P)"
  REASON=$'차단 [x:y]: "quoted" \\ back\tslash\x01ctrl\nnewline'
  OUT=$(hook_emit_pre deny "$REASON" x:y); RC=$?
  assert_eq "$P: emit deny rc" 0 "$RC"
  t_json_valid "$OUT"; assert_eq "$P: emit deny valid JSON" 0 "$?"
  assert_eq "$P: emit deny decision" deny "$(t_decision "$OUT")"
  assert_eq "$P: emit deny reason round-trips" "$REASON" "$(t_reason "$OUT")"
  assert_eq "$P: emit deny event" PreToolUse "$(printf '%s' "$OUT" | python3 -I -S -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])' 2>/dev/null || printf '%s' "$OUT" | jq -r .hookSpecificOutput.hookEventName)"
  assert_eq "$P: emit ask decision" ask "$(t_decision "$(hook_emit_pre ask '확인')")"
  OUT=$(hook_emit_pre allow 'reason' rule); assert_eq "$P: emit allow prints nothing" "" "$OUT"
  OUT=$(hook_emit_context SessionStart $'줄1\n줄2 "q"')
  t_json_valid "$OUT"; assert_eq "$P: emit context valid JSON" 0 "$?"
  assert_contains "$P: emit context event" "$OUT" '"hookEventName"'
  assert_contains "$P: emit context key" "$OUT" '"additionalContext"'
done

t_section "no parser"
load_with none "$J"
assert_eq "none: rc 1" 1 "$LOAD_RC"
OUT=$(HOOK_FORCE_PARSER=none HOOK_JSON_TOOL="" hook_emit_pre deny r); assert_eq "none: emit prints nothing, rc≠0" "" "$OUT"
HOOK_FORCE_PARSER=""; HOOK_JSON_TOOL=""

t_section "hook_off / hook_abspath / hook_lower / hook_log / hook_read_input"
for v in off OFF Off 0 false FALSE no No; do X=$v; hook_off X; assert_eq "off: [$v]" 0 "$?"; done
for v in on 1 true yes "" protected; do X=$v; hook_off X; assert_eq "not off: [$v]" 1 "$?"; done
unset UNSET_VAR_ZZ; hook_off UNSET_VAR_ZZ; assert_eq "off: unset var" 1 "$?"
H_CWD='/base dir'
assert_eq "abspath: ~ with //" "$HOME/x/y" "$(hook_abspath '~/x//y/')"
assert_eq "abspath: relative + /./ + trailing /." "/base dir/rel/z" "$(hook_abspath 'rel/./z/.')"
assert_eq "abspath: \$HOME" "$HOME" "$(hook_abspath '$HOME')"
assert_eq "abspath: \${HOME}/a" "$HOME/a" "$(hook_abspath '${HOME}/a')"
assert_eq "abspath: root" / "$(hook_abspath '/')"
assert_eq "abspath: .. kept" '/b/../..' "$(hook_abspath '../..' /b)"
assert_eq "abspath: explicit base" '/other/f' "$(hook_abspath 'f' /other/)"
assert_eq "abspath: bare ~" "$HOME" "$(hook_abspath '~')"
assert_eq "abspath: ~user not expanded" '/base dir/~bob/x' "$(hook_abspath '~bob/x')"
assert_eq "lower: ascii only, utf-8 untouched" 'abc 한글 def' "$(hook_lower 'ABC 한글 Def')"
LOG="$T_TMP/hooks.log"
CLAUDE_HOOKS_LOG= hook_log h d r x; [ -e "$LOG" ]; assert_eq "log: nothing when unset" 1 "$?"
long=$(printf 'a%.0s' $(seq 1 250) 2>/dev/null || awk 'BEGIN{while(i++<250)printf "a"}')
CLAUDE_HOOKS_LOG=$LOG hook_log guard-x ask secrets:print "multi${NL:-$'\n'}line	tab $long"
assert_eq "log: one line written" 1 "$(wc -l <"$LOG" | tr -d ' ')"
assert_eq "log: 5 tab fields" 5 "$(awk -F '\t' '{print NF}' "$LOG")"
assert_eq "log: fields" 'guard-x ask secrets:print' "$(awk -F '\t' '{print $2, $3, $4}' "$LOG")"
assert_eq "log: excerpt ≤ 200 and single-line" yes "$(awk -F '\t' '{print (length($5) <= 200 && $5 ~ /^multi line tab a+$/) ? "yes" : "no"}' "$LOG")"
OUT=$(printf 'line1\n"q"\tt\nline3' | "$BASH" -c '. "$1/lib/common.sh"; hook_read_input; printf "%s|%s" "$HOOK_INPUT" "$HOOK_NAME"' bash "$T_HOOKS")
assert_eq "read_input: stdin verbatim + HOOK_NAME from \$0" $'line1\n"q"\tt\nline3|bash' "$OUT"

t_section "run-hook.sh"
HD="$T_TMP/hooks dir"; mkdir -p "$HD/lib"; cp "$T_HOOKS/run-hook.sh" "$HD/"; cp "$T_HOOKS/lib/common.sh" "$HD/lib/"
printf '#!/usr/bin/env bash\nif [ x; then\n' >"$HD/broken.sh"
printf '#!/usr/bin/env bash\nprintf "%%s" "{\\"hookSpecificOutput\\":{\\"hookEventName\\":\\"PreToolUse\\",\\"permissionDecision\\":\\"deny\\",\\"permissionDecisionReason\\":\\"r\\"}}"\nexit 2\n' >"$HD/exit2.sh"
printf '#!/usr/bin/env bash\n. "$(cd -P -- "$(dirname -- "$0")" && pwd -P)/lib/common.sh"\nhook_read_input\nhook_load_pretooluse || exit 0\nprintf "%%s %%s %%s" "$H_TOOL" "$1" "$HOOK_NAME"\nexit 1\n' >"$HD/echo.sh"
t_run_hook "$HD/run-hook.sh" '{}' broken
assert_rc "launcher: syntax-error hook exit" 0; assert_eq "launcher: syntax-error hook stdout empty" "" "$T_OUT"
t_run_hook "$HD/run-hook.sh" '{}' missing-hook
assert_rc "launcher: missing hook exit" 0; assert_eq "launcher: missing hook silent" "" "$T_OUT$T_ERR"
CLAUDE_HOOKS_DEBUG=1 t_run_hook "$HD/run-hook.sh" '{}' missing-hook
assert_contains "launcher: missing hook debug line" "$T_ERR" 'run-hook:'
CLAUDE_HOOKS_DISABLE=1 t_run_hook "$HD/run-hook.sh" '{"tool_name":"Bash"}' echo arg1
assert_rc "launcher: CLAUDE_HOOKS_DISABLE=1 exit" 0; assert_eq "launcher: disabled runs nothing" "" "$T_OUT"
t_run_hook "$HD/run-hook.sh" '{}' exit2
assert_rc "launcher: exit 2 mapped to 0" 0; assert_eq "launcher: JSON passed through" deny "$(t_decision "$T_OUT")"
t_run_hook "$HD/run-hook.sh" '{"tool_name":"Bash","tool_input":{"command":"ls"}}' echo arg1
assert_rc "launcher: hook exit 1 → 0" 0; assert_eq "launcher: stdin + args + HOOK_NAME" "Bash arg1 echo" "$T_OUT"
t_run_hook "$HD/run-hook.sh" '{}' ; assert_rc "launcher: no name" 0
t_run_hook "$HD/run-hook.sh" '{}' '../echo'; assert_eq "launcher: path traversal name ignored" "" "$T_OUT"
t_run_hook "$HD/run-hook.sh" '{}' 'lib/common'; assert_eq "launcher: slash in name ignored" "" "$T_OUT"
t_report
