#!/usr/bin/env bash
# tests/hooks/test-aux-stop.sh — stop-verify.sh(Stop) · subagent-scope.sh(SubagentStop) · lib/transcript.sh 테스트
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
t_setup
unset CLAUDE_STOP_VERIFY CLAUDE_STOP_VERIFY_EXTRA CLAUDE_SUBAGENT_SCOPE
TX="$T_TMP/tx.jsonl"; EMPTY='{}'

# tx <종류> <값>… 을 이어 세션 기록(JSONL)을 만든다: U <글> · UL <글>(content 배열) · E <도구> <경로> · B <명령> · R(도구 결과) ·
#   T <응답 글> · M <글>(isMeta) · RAW <한 줄 그대로>
tx() {
  python3 -I -S -c 'import json,sys
a=sys.argv[2:]; out=[]; i=0
def asst(c): return {"type":"assistant","message":{"role":"assistant","content":c}}
while i<len(a):
    k=a[i]
    if k=="U": out.append({"type":"user","message":{"role":"user","content":a[i+1]}}); i+=2
    elif k=="UL": out.append({"type":"user","message":{"role":"user","content":[{"type":"text","text":a[i+1]}]}}); i+=2
    elif k=="M": out.append({"type":"user","isMeta":True,"message":{"role":"user","content":a[i+1]}}); i+=2
    elif k=="E":
        key="notebook_path" if a[i+1]=="NotebookEdit" else "file_path"
        out.append(asst([{"type":"tool_use","id":"t","name":a[i+1],"input":{key:a[i+2]}}])); i+=3
    elif k=="B": out.append(asst([{"type":"tool_use","id":"t","name":"Bash","input":{"command":a[i+1],"description":"d"}}])); i+=2
    elif k=="R": out.append({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}); i+=1
    elif k=="T": out.append(asst([{"type":"text","text":a[i+1]}])); i+=2
    elif k=="RAW": out.append(a[i+1]); i+=2
    else: raise SystemExit("tx: "+k)
with open(sys.argv[1],"w",encoding="utf-8") as f:
    for o in out: f.write((o if isinstance(o,str) else json.dumps(o,ensure_ascii=False))+"\n")' "$TX" "$@"
}
# stop_in [last-message] [extra-json] · sub_in <agent_type> [extra-json] → 훅 입력 JSON
stop_in() {
  python3 -I -S -c 'import json,sys
d={"session_id":"t","transcript_path":sys.argv[1],"cwd":sys.argv[2],"permission_mode":"default","hook_event_name":"Stop","stop_hook_active":False,"last_assistant_message":sys.argv[3]}
d.update(json.loads(sys.argv[4])); print(json.dumps(d))' "$TX" "$T_PROJ" "${1:-작업을 마쳤습니다.}" "${2:-$EMPTY}"
}
sub_in() {
  python3 -I -S -c 'import json,sys
d={"session_id":"t","transcript_path":"/nonexistent/main.jsonl","agent_transcript_path":sys.argv[1],"cwd":sys.argv[2],"permission_mode":"default","hook_event_name":"SubagentStop","stop_hook_active":False,"agent_id":"a1","agent_type":sys.argv[3],"last_assistant_message":"done"}
d.update(json.loads(sys.argv[4])); print(json.dumps(d))' "$TX" "$T_PROJ" "$1" "${2:-$EMPTY}"
}
field() {  # <out> <systemMessage|context|event>
  [ -n "$1" ] || { echo; return 0; }
  printf '%s' "$1" | python3 -I -S -c 'import json,sys
d=json.load(sys.stdin); h=d.get("hookSpecificOutput",{})
print({"systemMessage":d.get("systemMessage",""),"context":h.get("additionalContext",""),"event":h.get("hookEventName","")}[sys.argv[1]])' "$2" 2>/dev/null
}
sv() { t_run_hook stop-verify "$(stop_in "$@")"; MSG=$(field "$T_OUT" systemMessage); }
ss() { t_run_hook subagent-scope "$(sub_in "$@")"; MSG=$(field "$T_OUT" systemMessage); }
quiet() { assert_eq "$1 (rc)" 0 "$T_RC"; assert_eq "$1 → 출력 없음" "" "$T_OUT"; }
PARSERS="python3"; t_have_jq && PARSERS="jq python3"

for P in $PARSERS; do
export HOOK_FORCE_PARSER=$P
t_section "stop-verify [$P]: 알림 조건"
tx U "기능 추가해줘" E Edit "$T_PROJ/src/app.py" R T "완료"
sv
assert_rc "edit, no verify: exit 0" 0
assert_contains "edit, no verify: 알림" "$MSG" "[stop:unverified]"
assert_contains "edit, no verify: 파일 이름" "$MSG" "파일 1개를 수정했지만(app.py)"
if t_json_valid "$T_OUT"; then t_pass "출력은 유효한 JSON"; else t_fail "출력은 유효한 JSON" "$T_OUT"; fi
assert_eq "기본은 additionalContext 없음" "" "$(field "$T_OUT" context)"

tx U "x" E Edit "$T_PROJ/src/app.py" R B "uv run pytest -q tests/" R T "완료"
sv; quiet "edit → pytest"
tx U "x" B "pytest -q" R E Write "$T_PROJ/src/app.py" R
sv; assert_contains "pytest → edit(검증이 수정보다 앞): 알림" "$MSG" "[stop:unverified]"
tx U "x" E Edit "$T_PROJ/src/a.py" R B "pytest" R E Edit "$T_PROJ/src/a.py" R
sv; assert_contains "검증 뒤 같은 파일을 다시 수정: 알림" "$MSG" "파일 1개"
tx U "x" E Edit "$T_PROJ/a.py" E Write "$T_PROJ/b.ts" E MultiEdit "$T_PROJ/c.go" E NotebookEdit "$T_PROJ/d.ipynb" E Edit "$T_PROJ/e.rs"
sv; assert_contains "파일 5개: 이름 3개 + 외 2개" "$MSG" "파일 5개를 수정했지만(a.py, b.ts, c.go 외 2개)"

t_section "stop-verify [$P]: 알리지 않는 경우"
tx U "x" E Edit "$T_PROJ/README.md" E Write "$T_PROJ/docs/guide.rst" E Write "$T_PROJ/notes.TXT"
sv; quiet "문서만 수정"
tx U "x" E Write "/tmp/scratch/x.py" E Write "/private/tmp/y.py" E Write "/var/folders/ab/T/z.py" E Edit "$T_HOME/.claude/plans/p.py" E Edit "$T_PROJ/.claude/settings.json"
sv; quiet "임시 디렉터리·.claude 아래만 수정"
tx U "x" E Edit "$T_PROJ/src/app.py" R T "수정했습니다"
sv "변경 파일: src/app.py — 수정. 미검증: 테스트를 실행하지 못함"; quiet "응답에 미검증 표기"
sv "Changed app.py. Tests were not run."; quiet "응답에 not run 표기"
tx U "x" B "ls" R T "파일 목록입니다"
sv; quiet "수정 없음"
tx U "먼저" E Edit "$T_PROJ/src/app.py" R T "수정함" U "설명해줘" B "git status" R T "설명"
sv; quiet "앞 턴의 수정은 세지 않는다"
tx U "먼저" E Edit "$T_PROJ/src/app.py" R UL "배열 content 사용자 입력" T "답"
sv; quiet "content 배열(text) 사용자 입력도 턴 시작"
tx U "x" E Edit "$T_PROJ/src/app.py" R M "<local-command-stdout>meta</local-command-stdout>" T "완료"
sv; assert_contains "isMeta 줄은 턴 시작이 아님: 알림" "$MSG" "[stop:unverified]"
tx U "x" E Edit "$T_PROJ/src/app.py"
sv "완료" '{"stop_hook_active":true}'; quiet "stop_hook_active"
CLAUDE_STOP_VERIFY=off sv; quiet "CLAUDE_STOP_VERIFY=off"
CLAUDE_STOP_VERIFY=0 sv; quiet "CLAUDE_STOP_VERIFY=0"

t_section "stop-verify [$P]: remind · 입력 이상"
tx U "x" E Edit "$T_PROJ/src/app.py"
CLAUDE_STOP_VERIFY=remind sv
assert_eq "remind: systemMessage 없음" "" "$MSG"
assert_eq "remind: hookEventName" "Stop" "$(field "$T_OUT" event)"
assert_contains "remind: additionalContext" "$(field "$T_OUT" context)" "[stop:unverified]"
assert_contains "remind: 할 일 안내" "$(field "$T_OUT" context)" "'미검증'으로 보고에 적을 것"
CLAUDE_STOP_VERIFY=REMIND sv "완료" '{"stop_hook_active":true}'; quiet "remind + stop_hook_active(한 번만)"
tx RAW 'not json at all' RAW '{"type":"assistant","message":{"content":"str"}}' RAW '[1,2]' RAW '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":"x"}]}}' U "x" E Edit "$T_PROJ/src/app.py" RAW '{"broken":'
sv; assert_contains "깨진 줄은 건너뛴다" "$MSG" "파일 1개"
t_run_hook stop-verify ""; quiet "빈 입력"
t_run_hook stop-verify '{"hook_event_name":"Stop"}'; quiet "transcript_path 없음"
t_run_hook stop-verify '{"hook_event_name":"Stop","transcript_path":"/nonexistent/x.jsonl","stop_hook_active":false}'; quiet "기록 파일 없음"
t_run_hook stop-verify '{not json'; quiet "입력 JSON 깨짐"
t_run_hook "$T_HOOKS/run-hook.sh" "$(stop_in)" stop-verify
assert_contains "런처 경유" "$(field "$T_OUT" systemMessage)" "[stop:unverified]"

t_section "stop-verify [$P]: 검증 명령 판별"
vcmd() {  # <yes|no> <명령>
  tx U "x" E Edit "$T_PROJ/src/app.py" R B "$2" R
  t_run_hook stop-verify "$(stop_in)"
  if [ "$1" = yes ]; then assert_eq "검증으로 본다: $2" "" "$T_OUT"
  else assert_contains "검증으로 보지 않는다: $2" "$(field "$T_OUT" systemMessage)" "[stop:unverified]"; fi
}
for c in 'pytest' '.venv/bin/pytest -q' 'python3 -m pytest tests/' 'python -m unittest' 'uv run ruff check src' 'mypy src' \
  'npm test' 'npm run test:unit' 'pnpm run lint' 'yarn typecheck' 'bun run build' 'npx --no-install tsc --noEmit' 'npx vitest run' \
  'node_modules/.bin/jest' 'make check' 'make -C backend test' 'just lint' 'go test ./...' 'go vet ./...' 'cargo build' 'cargo clippy' \
  './gradlew test' 'mvn -q verify' 'python manage.py test app' 'php artisan test' 'bundle exec rspec' 'terraform validate' \
  'bash tests/run-all.sh' 'bash scripts/validate.sh --repo --quiet' 'bash -n install.sh' 'node --check src/a.js' 'shellcheck x.sh' \
  './scripts/test.sh' 'bash scripts/check.sh' 'python tests/run.py' 'cd web && npm run test' 'docker compose run --rm app pytest'; do
  vcmd yes "$c"
done
for c in 'git status' 'ls -la' 'npm install' 'npm ci' 'git checkout main' 'cat pytest.ini' 'cat jest.config.js' 'python scripts/latest.py' \
  'make install' 'go run .' 'cargo run' 'echo done' 'git commit -m fix' 'cd tests' 'python3 app.py' 'uv sync'; do
  vcmd no "$c"
done
tx U "x" E Edit "$T_PROJ/src/app.py" R B "mytool verify-all" R
sv; assert_contains "EXTRA 없음: 알림" "$MSG" "[stop:unverified]"
CLAUDE_STOP_VERIFY_EXTRA='mytool +verify' sv; quiet "CLAUDE_STOP_VERIFY_EXTRA"

t_section "subagent-scope [$P]: 소유 파일 대조"
PR="1. 목표: 뷰 수정. 사용자 요청 원문: \"고쳐줘\"
2. 범위: 읽을 곳 src/ / 소유 파일(수정 허용) src/api/views.py, tests/test_views.py / 수정 금지 src/settings.py · 마이그레이션
5. 완료 조건: 테스트 통과"
tx U "$PR" E Edit "$T_PROJ/src/api/views.py" R E Write "$T_PROJ/tests/test_views.py" R T "완료"
ss implementer; quiet "소유 파일만 수정"
tx U "$PR" E Edit "$T_PROJ/src/api/views.py" R E Edit "$T_PROJ/src/settings.py" R E Write "$T_PROJ/src/api/urls.py"
ss implementer
assert_rc "범위 밖: exit 0" 0
assert_contains "범위 밖: 알림" "$MSG" "[subagent:out-of-scope]"
assert_contains "범위 밖: 에이전트·파일" "$MSG" "implementer가 위임 프롬프트의 소유 파일 밖을 수정했다: src/settings.py, src/api/urls.py"
assert_contains "범위 밖: 선언 표시" "$MSG" "(소유 파일: src/api/views.py, tests/test_views.py)"
assert_not_contains "범위 밖: 소유 파일은 빼고" "$MSG" "밖을 수정했다: src/api/views.py"
if t_json_valid "$T_OUT"; then t_pass "출력은 유효한 JSON"; else t_fail "출력은 유효한 JSON" "$T_OUT"; fi
tx U "$PR" E Edit "$T_PROJ/src/api/views.py" E Write "/tmp/scratch/notes.py" E Write "/private/tmp/x/y.py"
ss implementer; quiet "임시 디렉터리 수정은 세지 않는다"
tx U "$PR" B "ls" R T "읽기만"
ss implementer; quiet "수정 없음"

tx U "범위: 소유 파일(수정 허용): \`src/api/\`, tests/*.py, ./conf/app.toml / 수정 금지 나머지" \
  E Edit "$T_PROJ/src/api/v1/views.py" E Edit "$T_PROJ/tests/test_a.py" E Edit "$T_PROJ/conf/app.toml"
ss implementer; quiet "디렉터리·글롭·./ 항목"
tx U "범위: 소유 파일(수정 허용): \`src/api/\`, tests/*.py / 수정 금지 나머지" E Edit "$T_PROJ/src/apix/views.py" E Edit "$T_PROJ/lib/tests/a.py"
ss implementer; assert_contains "디렉터리 이름 접두는 소유가 아님" "$MSG" "src/apix/views.py, lib/tests/a.py"
tx U "소유 파일 밖은 수정하지 말 것.
소유 파일(수정 허용):
- src/a.py
- \`src/b.py\` (신규)
3. 이미 확인한 사실: src/c.py:10" E Edit "$T_PROJ/src/a.py" E Write "$T_PROJ/src/b.py"
ss implementer; quiet "목록 형식 선언(앞 문장의 '소유 파일'은 건너뛴다)"
tx U "소유 파일(수정 허용):
- src/a.py
3. 이미 확인한 사실: src/c.py:10" E Edit "$T_PROJ/src/c.py"
ss implementer; assert_contains "목록 뒤 줄은 소유가 아님" "$MSG" "밖을 수정했다: src/c.py (소유 파일: src/a.py)"
tx U "Scope: owned files: src/a.py src/b.py" E Edit "$T_PROJ/src/a.py" E Edit "$T_PROJ/src/z.py"
ss general-purpose; assert_contains "owned files(영문)" "$MSG" "general-purpose가 위임 프롬프트의 소유 파일 밖을 수정했다: src/z.py"
tx U "범위: 소유 파일 \`$T_PROJ/src/a.py\`, /opt/app/b.py / 수정 금지 없음" E Edit "$T_PROJ/src/a.py" E Edit "/opt/app/b.py"
ss implementer; quiet "절대 경로 선언(공백이 든 경로는 백틱)"
tx U "범위: 소유 파일 \`my dir/a.py\` / 수정 금지 없음" E Edit "$T_PROJ/my dir/a.py" E Edit "$T_PROJ/my dir/b.py"
ss implementer; assert_contains "백틱 항목은 통째로 한 경로" "$MSG" "밖을 수정했다: my dir/b.py (소유 파일: my dir/a.py)"
tx U "2. 범위: 읽을 곳 src/ / 소유 파일 없음(읽기 전용) / 수정 금지 전부" E Edit "$T_PROJ/src/a.py"
ss explorer; assert_contains "소유 없음인데 수정" "$MSG" "밖을 수정했다: src/a.py (소유 파일: 없음)"
mkdir -p "$T_PROJ/pkg"
tx U "소유 파일(수정 허용) pkg, Makefile2" E Edit "$T_PROJ/pkg/x.py" E Edit "$T_PROJ/Makefile2"
ss implementer; assert_contains "구분자 없는 낱말은 있는 경로만(pkg 는 소유, Makefile2 는 아님)" "$MSG" "밖을 수정했다: Makefile2 (소유 파일: pkg)"
tx U "소유 파일(수정 허용) a.py, b.py, c.py, d.py, e.py, f.py, g.py" E Edit "$T_PROJ/1.py" E Edit "$T_PROJ/2.py" E Edit "$T_PROJ/3.py" E Edit "$T_PROJ/4.py" E Edit "$T_PROJ/5.py" E Edit "$T_PROJ/6.py"
ss implementer; assert_contains "많은 항목은 줄여 쓴다" "$MSG" "1.py, 2.py, 3.py, 4.py, 5.py 외 1개 (소유 파일: a.py, b.py, c.py, d.py, e.py 외 2개)"
# 에이전트 memory(memory: project|local|user)는 자기 기록이라 범위 밖 수정으로 세지 않는다
tx U "$PR" E Edit "$T_PROJ/src/api/views.py" E Write "$T_PROJ/.claude/agent-memory/implementer/MEMORY.md" \
  E Edit "$T_PROJ/.claude/agent-memory-local/implementer/notes.md" E Write "$HOME/.claude/agent-memory/implementer/MEMORY.md"
ss implementer; quiet "에이전트 memory 디렉터리 수정은 세지 않는다"
tx U "$PR" E Write "$T_PROJ/.claude/agent-memory/implementer/MEMORY.md" E Edit "$T_PROJ/src/settings.py" E Edit "$T_PROJ/.claude/agent-memoryx/a.md"
ss implementer
assert_contains "memory 와 함께 고친 범위 밖 파일은 알린다(이름이 비슷한 디렉터리 포함)" "$MSG" "밖을 수정했다: src/settings.py, .claude/agent-memoryx/a.md (소유 파일:"
assert_not_contains "memory 파일은 목록에 없다" "$MSG" "MEMORY.md"

t_section "subagent-scope [$P]: 선언 없음 · 모드 · 입력 이상"
tx U "views.py 를 고쳐줘" E Edit "$T_PROJ/src/a.py"
ss implementer
assert_contains "implementer 선언 없음: 알림" "$MSG" "[subagent:no-scope]"
assert_contains "implementer 선언 없음: 파일" "$MSG" "수정 파일 1개: src/a.py"
ss dev-settings:implementer
assert_contains "플러그인 이름공간이 붙은 implementer 도 알린다" "$MSG" "[subagent:no-scope]"
ss myimplementer; quiet "이름이 implementer 로 끝날 뿐인 에이전트는 통과"
ss Explore; quiet "다른 에이전트는 선언이 없으면 통과"
ss ""; quiet "agent_type 빈 값(내부 에이전트)"
tx U "$PR" E Edit "$T_PROJ/src/settings.py"
CLAUDE_SUBAGENT_SCOPE=remind ss implementer
assert_eq "remind: systemMessage 없음" "" "$MSG"
assert_eq "remind: hookEventName" "SubagentStop" "$(field "$T_OUT" event)"
assert_contains "remind: additionalContext" "$(field "$T_OUT" context)" "[subagent:out-of-scope]"
assert_contains "remind: 되돌리지 말고 보고" "$(field "$T_OUT" context)" "더 고치거나 되돌리지 말고"
CLAUDE_SUBAGENT_SCOPE=remind ss implementer '{"stop_hook_active":true}'; quiet "remind + stop_hook_active"
CLAUDE_SUBAGENT_SCOPE=off ss implementer; quiet "CLAUDE_SUBAGENT_SCOPE=off"
t_run_hook subagent-scope ""; quiet "빈 입력"
t_run_hook subagent-scope '{"hook_event_name":"SubagentStop","agent_type":"implementer"}'; quiet "agent_transcript_path 없음"
t_run_hook subagent-scope '{"hook_event_name":"SubagentStop","agent_type":"implementer","agent_transcript_path":"/nonexistent/a.jsonl"}'; quiet "기록 파일 없음"
t_run_hook "$T_HOOKS/run-hook.sh" "$(sub_in implementer)" subagent-scope
assert_contains "런처 경유" "$(field "$T_OUT" systemMessage)" "[subagent:out-of-scope]"
done
unset HOOK_FORCE_PARSER

t_section "파서 없음 · 큰 기록 · 로그"
tx U "x" E Edit "$T_PROJ/src/app.py"
HOOK_FORCE_PARSER=none sv; quiet "stop-verify: 파서 없음(fail-open)"
tx U "$PR" E Edit "$T_PROJ/src/settings.py"
HOOK_FORCE_PARSER=none ss implementer; quiet "subagent-scope: 파서 없음(fail-open)"
# 끝 4 MB 만 읽는다: 그보다 앞의 수정은 보지 않는다(비용 상한), 끝부분의 수정은 본다
python3 -I -S -c 'import json,sys
f=open(sys.argv[1],"w",encoding="utf-8")
e=lambda p: json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":p}}]}})+"\n"
pad=json.dumps({"type":"user","message":{"content":[{"type":"tool_result","content":"x"*4000}]}})+"\n"
f.write(json.dumps({"type":"user","message":{"content":"x"}})+"\n"); f.write(e(sys.argv[2]+"/old.py"))
for i in range(1200): f.write(pad)
if sys.argv[3]=="tail": f.write(e(sys.argv[2]+"/new.py"))' "$TX" "$T_PROJ" none
sv; quiet "4 MB 보다 앞의 수정은 보지 않는다"
python3 -I -S -c 'import json,sys
f=open(sys.argv[1],"a",encoding="utf-8")
f.write(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":sys.argv[2]+"/new.py"}}]}})+"\n")' "$TX" "$T_PROJ"
t0=$(t_ms); sv; t1=$(t_ms)
assert_contains "큰 기록의 끝부분 수정은 본다" "$MSG" "파일 1개를 수정했지만(new.py)"
t_under "5 MB 기록 처리 시간" $((t1 - t0)) 3000
LOG="$T_TMP/hooks.log"; : >"$LOG"
tx U "x" E Edit "$T_PROJ/src/app.py"
CLAUDE_HOOKS_LOG=$LOG sv
tx U "$PR" E Edit "$T_PROJ/src/settings.py"
CLAUDE_HOOKS_LOG=$LOG CLAUDE_SUBAGENT_SCOPE=remind ss implementer
assert_contains "로그: stop-verify" "$(cat "$LOG")" "stop-verify	notify	stop:unverified	app.py"
assert_contains "로그: subagent-scope" "$(cat "$LOG")" "subagent-scope	remind	subagent:out-of-scope	src/settings.py"

t_section "lib/transcript.sh: jq 와 python3 출력 일치"
if t_have_jq; then
  tx U "프롬프트 첫 줄
둘째 줄" M "meta" E Edit "$T_PROJ/a b/탭	이름.py" B "printf 'a\tb'
echo 둘째" R E NotebookEdit "$T_PROJ/n.ipynb" T "끝" UL "배열 입력" RAW 'garbage' RAW '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x"}},{"type":"tool_use","name":"Monitor","input":{"command":"tail -f log"}},{"type":"tool_use","name":"Write","input":{}}]}}'
  ev() { HOOK_FORCE_PARSER=$1 "$BASH" -c '. "$1/lib/common.sh"; . "$1/lib/transcript.sh"; hook_tx_events "$2"; echo "rc=$?"; hook_tx_prompt "$2"' _ "$T_HOOKS" "$TX"; }
  A=$(ev jq); B=$(ev python3)
  assert_eq "이벤트·프롬프트 출력 동일" "$A" "$B"
  assert_contains "U·E·B 순서" "$A" "U
E	$T_PROJ/a b/탭 이름.py
B	printf 'a\tb' echo 둘째
E	$T_PROJ/n.ipynb
U
B	tail -f log
rc=0"
  assert_contains "프롬프트는 첫 사용자 입력 전체" "$A" "프롬프트 첫 줄
둘째 줄"
else
  t_pass "jq 없음 — 일치 검사 생략"
fi
t_report
