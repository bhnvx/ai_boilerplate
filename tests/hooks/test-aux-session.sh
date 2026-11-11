#!/usr/bin/env bash
# tests/hooks/test-aux-session.sh — session-context.sh + lib/detect-stack.sh 테스트
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
t_setup
unset CLAUDE_PROJECT_DIR CLAUDE_SESSION_CONTEXT CLAUDE_GUARD_PROTECTED_BRANCHES
FIX="$T_REPO_ROOT/tests/hooks/fixtures/session-start.json"
DS="$T_HOOKS/lib/detect-stack.sh"

# ss_json <cwd> [source] — fixture 의 cwd/source 교체
ss_json() {
  if t_have_jq; then jq -c --arg c "$1" --arg s "${2:-startup}" '.cwd = $c | .source = $s' "$FIX"
  else python3 -I -S -c 'import json,sys
d=json.load(open(sys.argv[1])); d["cwd"]=sys.argv[2]; d["source"]=sys.argv[3]; print(json.dumps(d))' "$FIX" "$1" "${2:-startup}"; fi
}
ctx() {
  [ -n "$1" ] || { echo; return 0; }
  printf '%s' "$1" | python3 -I -S -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null
}
event() { printf '%s' "$1" | python3 -I -S -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])' 2>/dev/null; }
sc() { t_run_hook session-context "$(ss_json "$@")"; C=$(ctx "$T_OUT"); }

t_section "session-context: main 브랜치(보호)"
sc "$T_PROJ"
assert_rc "main: exit 0" 0
assert_eq "main: event SessionStart" "SessionStart" "$(event "$T_OUT")"
assert_contains "main: header" "$C" "[세션 컨텍스트 · ai_boilerplate 훅]"
assert_contains "main: date + source" "$C" "날짜: $(LC_ALL=C date '+%Y-%m-%d (%a)') · 소스: startup"
assert_contains "main: repo + branch + upstream" "$C" "저장소: proj dir · 브랜치: main (origin/main 대비 ahead 0 / behind 0)"
assert_contains "main: clean counts" "$C" "변경: 0 (staged 0 / unstaged 0 / untracked 0)"
assert_contains "main: recent commit" "$C" "최근 커밋: "
assert_contains "main: commit subject" "$C" " init"
assert_contains "main: protected warning" "$C" "⚠ 보호 브랜치(main)에서 작업 중"
assert_contains "main: rules line" "$C" "규칙 파일: CLAUDE.md ✗ · .claude/rules 0개 · CLAUDE.local.md ✗ · AGENTS.md ✗"
assert_contains "main: no stack" "$C" "스택: 감지 안 됨"
assert_not_contains "main: parser present → no guard warning" "$C" "가드 비활성"
n=$(printf '%s\n' "$C" | wc -l | tr -d ' ')
if [ "$n" -le 25 ]; then t_pass "main: ≤ 25 lines"; else t_fail "main: ≤ 25 lines" "lines=$n"; fi

CLAUDE_GUARD_PROTECTED_BRANCHES=none sc "$T_PROJ"
assert_not_contains "protected none: no warning" "$C" "보호 브랜치"
assert_contains "protected none: branch still shown" "$C" "브랜치: main"
CLAUDE_GUARD_PROTECTED_BRANCHES="develop,release" sc "$T_PROJ"
assert_not_contains "protected develop,release: main not warned" "$C" "보호 브랜치"
CLAUDE_GUARD_PROTECTED_BRANCHES="develop, main" sc "$T_PROJ"
assert_contains "protected list with comma+space" "$C" "보호 브랜치(main)"

t_section "session-context: 변경 수 · ahead · 규칙 · 스택"
(
  cd "$T_PROJ" || exit 1
  printf 'a\n' >staged.txt && t_git add staged.txt && t_git commit -q -m "second commit with a fairly long subject line that goes past sixty columns easily" &&
  printf 'b\n' >new.txt && t_git add new.txt && printf 'changed\n' >>README.md && printf 'u\n' >untracked.txt
) || t_fail "fixture changes"
mkdir -p "$T_PROJ/.claude/rules"
: >"$T_PROJ/CLAUDE.md"; : >"$T_PROJ/.claude/rules/a.md"; : >"$T_PROJ/.claude/rules/b.md"; : >"$T_PROJ/AGENTS.md"
: >"$T_PROJ/pyproject.toml"; : >"$T_PROJ/uv.lock"; : >"$T_PROJ/manage.py"
sc "$T_PROJ" resume
# untracked: untracked.txt CLAUDE.md AGENTS.md .claude/ pyproject.toml uv.lock manage.py = 7 (디렉터리는 1개로)
assert_contains "counts: staged/unstaged/untracked" "$C" "변경: 9 (staged 1 / unstaged 1 / untracked 7)"
assert_contains "ahead 1" "$C" "(origin/main 대비 ahead 1 / behind 0)"
assert_contains "source resume" "$C" "소스: resume"
assert_contains "rules present" "$C" "규칙 파일: CLAUDE.md ✓ · .claude/rules 2개 · CLAUDE.local.md ✗ · AGENTS.md ✓"
assert_contains "stack python(uv) · django" "$C" "스택: python(uv) · django"
assert_contains "long subject truncated by git" "$C" "second commit with a fairly long subject line that goes pa.."
assert_not_contains "truncated subject: no padding before separator" "$C" "  · "

mkdir -p "$T_PROJ/sub dir"
sc "$T_PROJ/sub dir"
assert_contains "subdirectory: repo root name" "$C" "저장소: proj dir"
assert_contains "subdirectory: rules from repo root" "$C" "CLAUDE.md ✓"
assert_contains "subdirectory: stack falls back to repo root" "$C" "스택: python(uv) · django"

t_section "session-context: feature/x 워크트리"
sc "$T_WT"
assert_contains "worktree: branch without upstream" "$C" "브랜치: feature/x (upstream 없음)"
assert_contains "worktree: repo name" "$C" "저장소: wt feature"
assert_not_contains "worktree: no protected warning" "$C" "보호 브랜치"
(cd "$T_WT" && t_git checkout -q --detach) || t_fail "detach fixture"
sc "$T_WT"
assert_contains "detached HEAD shown" "$C" "브랜치: HEAD 분리("
assert_not_contains "detached: no protected warning" "$C" "보호 브랜치"

t_section "session-context: 보호 브랜치 해석(D11 — guard-destructive 와 동일)"
(cd "$T_WT" && t_git checkout -q -b release/1.0) || t_fail "release/1.0 fixture"
CLAUDE_GUARD_PROTECTED_BRANCHES='release/*' sc "$T_WT"
assert_contains "glob release/*: warned on release/1.0" "$C" "⚠ 보호 브랜치(release/1.0)에서 작업 중"
CLAUDE_GUARD_PROTECTED_BRANCHES='main,release/*' sc "$T_WT"
assert_contains "list main,release/*: warned" "$C" "보호 브랜치(release/1.0)"
CLAUDE_GUARD_PROTECTED_BRANCHES='main master' sc "$T_WT"
assert_not_contains "main master: release/1.0 not warned" "$C" "보호 브랜치"
sc "$T_WT"
assert_not_contains "unset (default main master): release/1.0 not warned" "$C" "보호 브랜치"
CLAUDE_GUARD_PROTECTED_BRANCHES='' sc "$T_PROJ"
assert_not_contains "empty value: branch rules off (main not warned)" "$C" "보호 브랜치"
assert_contains "empty value: branch still shown" "$C" "브랜치: main"
CLAUDE_GUARD_PROTECTED_BRANCHES='NONE' sc "$T_PROJ"
assert_not_contains "NONE (uppercase): off" "$C" "보호 브랜치"
CLAUDE_GUARD_PROTECTED_BRANCHES=' None ' sc "$T_PROJ"
assert_not_contains "' None ' (spaces, mixed case): off" "$C" "보호 브랜치"
CLAUDE_GUARD_PROTECTED_BRANCHES='ma*' sc "$T_PROJ"
assert_contains "glob ma*: main warned" "$C" "보호 브랜치(main)"
CLAUDE_GUARD_PROTECTED_BRANCHES=' , ' sc "$T_PROJ"
assert_not_contains "only separators: no warning" "$C" "보호 브랜치"
CLAUDE_GUARD_PROTECTED_BRANCHES='*' sc "$T_PROJ"
assert_contains "glob * (not expanded to file names): main warned" "$C" "보호 브랜치(main)"

t_section "session-context: git 아님 · 끄기 · 파서"
mkdir -p "$T_TMP/plain dir"
sc "$T_TMP/plain dir"
assert_contains "non-git: date line" "$C" "날짜: "
assert_not_contains "non-git: no repo line" "$C" "브랜치"
assert_not_contains "non-git: no commit line" "$C" "최근 커밋"
CLAUDE_SESSION_CONTEXT=off sc "$T_PROJ"
assert_eq "off: no output" "" "$T_OUT"
assert_rc "off: exit 0" 0
HOOK_FORCE_PARSER=python3 sc "$T_PROJ"
if t_json_valid "$T_OUT"; then t_pass "python3 parser: valid JSON"; else t_fail "python3 parser: valid JSON" "$T_OUT"; fi
assert_contains "python3 parser: branch" "$C" "브랜치: main"
HOOK_FORCE_PARSER=none sc "$T_PROJ"
assert_contains "no parser: plain text context" "$T_OUT" "[세션 컨텍스트 · ai_boilerplate 훅]"
assert_contains "no parser: guard warning" "$T_OUT" "⚠ 가드 비활성: jq/python3 없음"
assert_contains "no parser: cwd from regex" "$T_OUT" "저장소: proj dir"
CLAUDE_PROJECT_DIR=$T_PROJ t_run_hook session-context '{"hook_event_name":"SessionStart","source":"clear"}'
assert_contains "cwd missing: CLAUDE_PROJECT_DIR used" "$(ctx "$T_OUT")" "저장소: proj dir"
t_run_hook session-context ""
assert_rc "empty stdin: exit 0" 0
assert_contains "empty stdin: still a context" "$(ctx "$T_OUT")" "날짜: "

t_section "detect-stack"
mk() { mkdir -p "$1"; [ $# -lt 3 ] || printf '%s\n' "$3" >"$1/$2"; }
D="$T_TMP/stacks"
mk "$D/uv django" pyproject.toml '[project]
name = "x"
dependencies = ["Django>=5.0", "psycopg[binary]"]
[tool.uv]
dev-dependencies = ["pytest"]'
mk "$D/fastapi" requirements.txt 'fastapi[standard]==0.115.0
uvicorn'
mk "$D/pnpm ts" package.json '{"name":"w","dependencies":{"react":"^18.3.0","next":"14.2.0"},"devDependencies":{"typescript":"^5.6.0"}}'
: >"$D/pnpm ts/pnpm-lock.yaml"; : >"$D/pnpm ts/tsconfig.json"
mk "$D/go" go.mod 'module example.com/x'
mk "$D/poetry" pyproject.toml '[tool.poetry]
name = "x"
[tool.poetry.dependencies]
python = "^3.12"
fastapi = "^0.110"'
mk "$D/manage only" manage.py 'print(1)'
mk "$D/pkgmgr" package.json '{"name":"x","packageManager":"yarn@4.1.0"}'
mk "$D/misc" Cargo.toml '[package]'; : >"$D/misc/Dockerfile"; : >"$D/misc/Gemfile"; : >"$D/misc/app.csproj"
mk "$D/pipenv" Pipfile '[packages]
django = "*"'
mk "$D/empty"
mk "$D/stub" pyproject.toml '[tool.pytest.ini_options]
DJANGO_SETTINGS_MODULE = "x.settings"
[tool.django-stubs]'
# A9: 의존성 모양만 인정(설명 문구·주석·npm 스크립트 이름 제외)
mk "$D/flask desc" pyproject.toml '[project]
name = "x"
description = "not a django project, uses flask"
dependencies = ["flask>=3"]  # not "django>=4"
# "fastapi>=0.1" was removed'
mk "$D/req comment" requirements.txt '# TODO: maybe migrate to django later
flask==3
django-environ==0.11'
mk "$D/pkg scripts" package.json '{"name":"react","scripts":{"next":"next dev","typescript":"tsc -b"}}'
mk "$D/pkg tags" package.json '{"dependencies":{"react":"workspace:*","next":"latest"},"devDependencies":{"typescript":"~5.6.0"}}'
mk "$D/setup cfg" setup.cfg '[options]
install_requires =
    Django>=4.2  # LTS
    requests'
mk "$D/req crlf"; printf 'FastAPI\r\nuvicorn\r\n' >"$D/req crlf/requirements.txt"
mk "$D/pep508" pyproject.toml '[project]
dependencies = [
  "fastapi[standard]>=0.115",
  "Django ; python_version >= \"3.10\"",
]'
mk "$D/uvicorn cfg" pyproject.toml '[tool.uvicorn]
port = 8000'
mk "$D/poetry key" pyproject.toml '[tool.poetry.dependencies]
Django = { version = "^5.0", extras = ["argon2"] }'
ds() { "$BASH" "$DS" "$1"; }
assert_eq "uv+django" "python uv django" "$(ds "$D/uv django")"
assert_eq "fastapi (requirements)" "python pip fastapi" "$(ds "$D/fastapi")"
assert_eq "pnpm+ts+react+next" "node pnpm typescript react next" "$(ds "$D/pnpm ts")"
assert_eq "go" "go" "$(ds "$D/go")"
assert_eq "poetry+fastapi" "python poetry fastapi" "$(ds "$D/poetry")"
assert_eq "manage.py only" "python django" "$(ds "$D/manage only")"
assert_eq "packageManager field" "node yarn" "$(ds "$D/pkgmgr")"
assert_eq "rust ruby dotnet docker" "rust ruby dotnet docker" "$(ds "$D/misc")"
assert_eq "pipenv+django" "python pipenv django" "$(ds "$D/pipenv")"
assert_eq "no false django from settings keys" "python" "$(ds "$D/stub")"
assert_eq "description/comment mention: no django/fastapi" "python" "$(ds "$D/flask desc")"
assert_eq "requirements comment + django-environ: no django" "python pip" "$(ds "$D/req comment")"
assert_eq "package.json script names: no react/next/typescript" "node" "$(ds "$D/pkg scripts")"
assert_eq "package.json workspace:/latest/~ versions" "node typescript react next" "$(ds "$D/pkg tags")"
assert_eq "setup.cfg install_requires + inline comment" "python django" "$(ds "$D/setup cfg")"
assert_eq "CRLF requirements (FastAPI)" "python pip fastapi" "$(ds "$D/req crlf")"
assert_eq "PEP 508 strings (extras, marker)" "python django fastapi" "$(ds "$D/pep508")"
assert_eq "[tool.uvicorn] is not [tool.uv]" "python" "$(ds "$D/uvicorn cfg")"
assert_eq "poetry inline-table key" "python poetry django" "$(ds "$D/poetry key")"
assert_eq "empty dir: no output" "" "$(ds "$D/empty")"
assert_eq "missing dir: no output" "" "$(ds "$D/nope")"
"$BASH" "$DS" "$D/nope"; assert_eq "missing dir: exit 0" 0 "$?"
. "$DS"; detect_stack "$D/uv django"
assert_eq "sourced: DETECT_STACK" "python uv django" "$DETECT_STACK"
ds_out=$(PATH=$(t_make_shim bash grep tr) ds "$D/fastapi")
assert_eq "restricted PATH (bash grep tr only)" "python pip fastapi" "$ds_out"

t_report
