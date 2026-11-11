#!/usr/bin/env bash
# ai_boilerplate — 플러그인 배포판 테스트: marketplace.json·plugin.json 구조, hooks 가 전역 settings.json 과 같은지,
# 플러그인 경로(공백이 든 경로, ~/.claude 가 없는 HOME)에서 훅이 그대로 동작하는지, install.sh 가 매니페스트를 복사하지 않는지.
# Claude Code 자체는 실행하지 않는다(`claude plugin validate` 는 수동 확인 — docs/install.md).
. "$(cd -P -- "$(dirname -- "$0")" && pwd -P)/helpers.sh"

MK=".claude-plugin/marketplace.json"; PJ="claude/global/.claude-plugin/plugin.json"
if ! need "plugin: manifests" "$MK" "$PJ" claude/global/settings.json claude/global/hooks/run-hook.sh; then
  t_report "test-plugin"; exit $?
fi

echo "## (P1) 매니페스트 구조"
NAME=$(jq_py "$REPO/$PJ" 'd["name"]')
assert_eq "plugin.json: kebab-case name" True "$(jq_py "$REPO/$PJ" '__import__("re").match(r"^[a-z0-9]+(-[a-z0-9]+)*$", d["name"]) is not None')"
assert_eq "marketplace: entry points at ./claude/global with the same name" True \
  "$(jq_py "$REPO/$MK" "any(e.get('source') == './claude/global' and e.get('name') == '$NAME' for e in d['plugins'])")"
assert_eq "marketplace: owner.name set, no email" True "$(jq_py "$REPO/$MK" 'bool(d["owner"]["name"]) and "email" not in d["owner"]')"
assert_eq "plugin.json: author has no email" True "$(jq_py "$REPO/$PJ" '"email" not in d.get("author", {})')"
# version 을 적으면 그 문자열로 고정되어 커밋이 바뀌어도 갱신되지 않는다 → 적지 않는다(커밋 SHA 가 버전이 된다).
assert_eq "plugin.json: version not pinned" True "$(jq_py "$REPO/$PJ" '"version" not in d')"
assert_eq "plugin.json: only keys the plugin loader reads" "[]" \
  "$(jq_py "$REPO/$PJ" 'sorted(set(d) - {"name", "description", "author", "homepage", "repository", "license", "keywords", "hooks"})')"

echo "## (P2) hooks 는 전역 settings.json 과 같다(명령 경로만 플러그인 기준)"
SAME=$(python3 -I -c 'import json,sys
s=json.load(open(sys.argv[1],encoding="utf-8")); p=json.load(open(sys.argv[2],encoding="utf-8"))
def tr(o):
    if isinstance(o,dict): return {k:tr(v) for k,v in o.items()}
    if isinstance(o,list): return [tr(v) for v in o]
    if isinstance(o,str): return o.replace("\"$HOME\"/.claude/hooks/","\"${CLAUDE_PLUGIN_ROOT}\"/hooks/")
    return o
print(tr(s["hooks"])==p["hooks"])' "$REPO/claude/global/settings.json" "$REPO/$PJ" 2>/dev/null)
assert_eq "plugin hooks equal settings hooks" True "$SAME"
assert_eq "plugin hooks: no \$HOME or .claude path left" 0 "$(hook_commands "$REPO/$PJ" | grep -c -e 'HOME' -e '~/' -e '\.claude/')"
assert_eq "plugin hooks: every command goes through the launcher" 0 \
  "$(hook_commands "$REPO/$PJ" | cut -f2 | grep -vc '^"${CLAUDE_PLUGIN_ROOT}"/hooks/run-hook\.sh [a-z-]*$')"
while IFS= read -r hn; do
  [ -n "$hn" ] && assert_file "plugin hooks: $hn.sh exists in the plugin root" "$REPO/claude/global/hooks/$hn.sh"
done <<EOF
$(hook_commands "$REPO/$PJ" | cut -f2 | sed 's/.* //')
EOF

echo "## (P3) 플러그인 경로에서 훅 실행(공백이 든 경로, ~/.claude 없는 HOME)"
PLUG="$TROOT/plug in/root"; EH="$TROOT/empty home"; PRJ="$TROOT/proj"
mkdir -p "$PLUG" "$EH" "$PRJ"
cp -R "$REPO/claude/global/hooks" "$PLUG/hooks"
# plugin_cmd <event> <hook-name> [<root>] → 등록된 명령 한 줄(root 를 주면 ${CLAUDE_PLUGIN_ROOT} 를 글자 그대로 치환)
plugin_cmd() {
  python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
for g in d["hooks"].get(sys.argv[2]) or []:
    for h in g.get("hooks") or []:
        c=h.get("command","")
        if c.endswith(" "+sys.argv[3]):
            print(c.replace("${CLAUDE_PLUGIN_ROOT}",sys.argv[4]) if len(sys.argv)>4 else c); raise SystemExit' "$REPO/$PJ" "$@" 2>/dev/null
}
# run_plugin_hook <event> <name> <stdin-json> → H_ENV(환경 변수로 전달) · H_SUBST(명령 문자열에 치환) · H_RC
run_plugin_hook() {
  local c1 c2 r1 r2
  c1=$(plugin_cmd "$1" "$2"); c2=$(plugin_cmd "$1" "$2" "$PLUG")
  H_ENV=$(printf '%s' "$3" | HOME="$EH" CLAUDE_PLUGIN_ROOT="$PLUG" CLAUDE_PROJECT_DIR="$PRJ" /bin/bash -c "$c1" 2>/dev/null); r1=$?
  H_SUBST=$(unset CLAUDE_PLUGIN_ROOT; printf '%s' "$3" | HOME="$EH" CLAUDE_PROJECT_DIR="$PRJ" /bin/bash -c "$c2" 2>/dev/null); r2=$?
  H_RC="$r1/$r2"
}
decision() {
  printf '%s' "$1" | python3 -I -c 'import json,sys
try: print(json.load(sys.stdin).get("hookSpecificOutput",{}).get("permissionDecision",""))
except Exception: print("")' 2>/dev/null
}
pre_in() {  # <tool> <tool_input-json>
  printf '{"session_id":"t","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s,"cwd":"%s","permission_mode":"default"}' "$1" "$2" "$PRJ"
}
run_plugin_hook PreToolUse guard-secrets "$(pre_in Read "{\"file_path\":\"$PRJ/.env\"}")"
assert_eq "guard-secrets from plugin root: deny (env)" deny "$(decision "$H_ENV")"
assert_eq "guard-secrets from plugin root: deny (substituted path)" deny "$(decision "$H_SUBST")"
assert_eq "guard-secrets: launcher exit 0" "0/0" "$H_RC"
run_plugin_hook PreToolUse guard-secrets "$(pre_in Read "{\"file_path\":\"$PRJ/src/app.py\"}")"
assert_eq "guard-secrets from plugin root: ordinary file passes" "/" "$(decision "$H_ENV")/$(decision "$H_SUBST")"
run_plugin_hook PreToolUse guard-destructive "$(pre_in Bash '{"command":"rm -rf /"}')"
assert_eq "guard-destructive from plugin root: deny" "deny/deny" "$(decision "$H_ENV")/$(decision "$H_SUBST")"
run_plugin_hook PreToolUse guard-migrations "$(pre_in Bash '{"command":"ls"}')"
assert_eq "guard-migrations from plugin root: ordinary command passes" "/ 0/0" "$(decision "$H_ENV")/$(decision "$H_SUBST") $H_RC"
run_plugin_hook SessionStart session-context '{"hook_event_name":"SessionStart","source":"startup"}'
assert_eq "session-context from plugin root: emits SessionStart context" SessionStart \
  "$(printf '%s' "$H_ENV" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])' 2>/dev/null)"
run_plugin_hook Stop stop-verify '{"hook_event_name":"Stop"}'
assert_eq "stop-verify from plugin root: quiet, exit 0" "/ 0/0" "$H_ENV/$H_SUBST $H_RC"
run_plugin_hook SubagentStop subagent-scope '{"hook_event_name":"SubagentStop"}'
assert_eq "subagent-scope from plugin root: quiet, exit 0" "/ 0/0" "$H_ENV/$H_SUBST $H_RC"
assert_no_file "plugin hooks: nothing created under HOME" "$EH/.claude"

echo "## (P4) install.sh 는 플러그인 매니페스트를 ~/.claude 에 복사하지 않는다"
new_home; HP="$NEW_HOME"
run_install "$HP"
assert_install_ok "install: exit 0"
assert_no_file "install: no .claude-plugin in ~/.claude" "$HP/.claude/.claude-plugin"
assert_eq "install: no plugin manifest anywhere under ~/.claude" 0 "$(find "$HP/.claude" -name plugin.json -o -name marketplace.json 2>/dev/null | grep -c '')"

t_report "test-plugin"
