#!/usr/bin/env bash
# tests/hooks/test-aux-format.sh — format-on-edit.sh 테스트(가짜 포매터, ECC 겹침 방지, watchdog, 경로 제외, 셔뱅)
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
t_setup
unset CLAUDE_PROJECT_DIR CLAUDE_FORMAT_ON_EDIT CLAUDE_FORMAT_TIMEOUT ECC_DISABLED_HOOKS ECC_QUALITY_GATE_FIX ECC_HOOK_PROFILE
export TMPDIR="$T_TMP/tmp dir"; mkdir -p "$TMPDIR"
SHIM=$(t_make_shim)
FAKE="$T_TMP/fake bin"; mkdir -p "$FAKE"
P=$T_PROJ
PP=$(cd -P -- "$P" && pwd -P)   # 훅은 물리 경로를 포매터에 넘긴다(/var ↔ /private/var)
LOG="$T_TMP/argv.log"

# PostToolUse 입력 JSON
post_json() { t_path_json "${3:-Edit}" "$1" "${2:-$P}" default '{"hook_event_name":"PostToolUse","tool_response":{"success":true}}'; }
# fmt <file> [cwd] [tool] — 제한된 PATH(shim + 가짜 bin)로 훅 실행
fmt() { PATH="$FAKE:$SHIM" t_run_hook format-on-edit "$(post_json "$@")"; }
ctx() {
  [ -n "$1" ] || { echo; return 0; }
  if t_have_jq; then printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""'
  else printf '%s' "$1" | python3 -I -S -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; fi
}
event() { printf '%s' "$1" | python3 -I -S -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])' 2>/dev/null; }
# 가짜 실행 파일: argv 를 LOG 에 남기고 본문 실행
mkfake() { # <path> <body>
  mkdir -p "${1%/*}"
  printf '#!/bin/sh\nprintf "%%s\\n" "${0##*/} $*" >>"%s"\n%s\n' "$LOG" "$2" >"$1"; chmod 755 "$1"
}
write() { mkdir -p "${1%/*}"; printf '%s\n' "$2" >"$1"; }

t_section "기본: 포매터 없음 / 대상 아님"
write "$P/app/plain.py" 'x = 1'
fmt "$P/app/plain.py"
assert_rc "no config: exit 0" 0
assert_eq "no config: no output" "" "$T_OUT"
write "$P/pyproject.toml" '[project]
name = "demo"
[tool.ruff]
line-length = 100'
fmt "$P/app/plain.py"
assert_eq "ruff configured but no binary: no output" "" "$T_OUT"
CLAUDE_FORMAT_ON_EDIT=off fmt "$P/app/plain.py"
assert_eq "off switch: no output" "" "$T_OUT"
PATH="$FAKE:$SHIM" t_run_hook format-on-edit "$(t_path_json Read "$P/app/plain.py" "$P" default '{"hook_event_name":"PostToolUse"}')"
assert_eq "Read tool ignored" "" "$T_OUT"
fmt "$T_TMP/outside.py"
assert_eq "file outside project: no output" "" "$T_OUT"
fmt "$P/app/missing.py"
assert_eq "missing file: no output" "" "$T_OUT"
t_run_hook format-on-edit ""
assert_rc "empty stdin: exit 0" 0
assert_eq "empty stdin: no output" "" "$T_OUT"

t_section "bash -n"
write "$P/scripts/bad.sh" 'if then fi ('
fmt "$P/scripts/bad.sh"
assert_contains "sh syntax error: context has bash -n" "$(ctx "$T_OUT")" "bash -n: scripts/bad.sh 문법 오류"
assert_eq "sh syntax error: event PostToolUse" "PostToolUse" "$(event "$T_OUT")"
assert_not_contains "sh syntax error: absolute path stripped" "$(ctx "$T_OUT")" "$P/scripts"
write "$P/scripts/good.sh" 'echo ok'
fmt "$P/scripts/good.sh"
assert_eq "valid sh: no output" "" "$T_OUT"
# 셔뱅(A7): bash/sh 계열이나 셔뱅 없음만 bash -n, zsh·fish 등은 건너뜀
write "$P/scripts/z.sh" '#!/usr/bin/env zsh
for f (*.txt) print -r -- $f
if [[ $1 == (start|stop) ]]; then print ok; fi'
fmt "$P/scripts/z.sh"
assert_eq "zsh shebang (env): bash -n skipped" "" "$T_OUT"
write "$P/scripts/z2.sh" '#!/bin/zsh -f
for f (*.txt) print -r -- $f'
fmt "$P/scripts/z2.sh"
assert_eq "zsh shebang (path + option): skipped" "" "$T_OUT"
write "$P/scripts/f.sh" '#!/usr/bin/env fish
if then fi ('
fmt "$P/scripts/f.sh"
assert_eq "fish shebang: skipped" "" "$T_OUT"
write "$P/scripts/envs.sh" '#!/usr/bin/env -S bash -e
if then fi ('
fmt "$P/scripts/envs.sh"
assert_contains "env -S bash shebang: checked" "$(ctx "$T_OUT")" "bash -n: scripts/envs.sh 문법 오류"
write "$P/scripts/posix.sh" '#! /bin/sh
if then fi ('
fmt "$P/scripts/posix.sh"
assert_contains "sh shebang (with space): checked" "$(ctx "$T_OUT")" "bash -n: scripts/posix.sh 문법 오류"
printf '#!/bin/bash\r\nif then fi (\r\n' >"$P/scripts/crlf.sh"
fmt "$P/scripts/crlf.sh"
assert_contains "bash shebang with CRLF: checked" "$(ctx "$T_OUT")" "bash -n: scripts/crlf.sh 문법 오류"

t_section "ruff(.venv/bin/ruff 가짜)"
mkfake "$P/.venv/bin/ruff" 'f=""; for a; do case $a in /*) f=$a ;; esac; done
case $1 in
  format) printf "# formatted\n" >>"$f"; exit 0 ;;
  check) printf "%s:1:1: F401 [*] os imported but unused\n%s:2:80: E501 Line too long\nFound 2 errors.\n" "$f" "$f"; exit 1 ;;
esac'
write "$P/app/views.py" 'import os'
: >"$LOG"
fmt "$P/app/views.py"
C=$(ctx "$T_OUT")
assert_contains "ruff: lint context" "$C" "ruff: app/views.py 린트 이슈 2개:"
assert_contains "ruff: lint line relative" "$C" "app/views.py:1:1: F401"
assert_contains "ruff: changed notice" "$C" "포매터(ruff)가 app/views.py를 수정했다"
# A2: --force-exclude 로 프로젝트 exclude 를 명시 경로에도 적용
assert_contains "ruff: argv format --force-exclude" "$(cat "$LOG")" "ruff format --force-exclude $PP/app/views.py"
assert_contains "ruff: argv check --force-exclude concise" "$(cat "$LOG")" "ruff check --force-exclude $PP/app/views.py --output-format concise"
assert_not_contains "ruff: never --fix" "$(cat "$LOG")" "--fix"
if t_json_valid "$T_OUT"; then t_pass "ruff: output is JSON"; else t_fail "ruff: output is JSON" "$T_OUT"; fi
: >"$LOG"
HOOK_FORCE_PARSER=python3 fmt "$P/app/views.py"
assert_contains "ruff (python3 parser): lint context" "$(ctx "$T_OUT")" "린트 이슈 2개"
write "$P/app/a&b.py" 'import os'
fmt "$P/app/a&b.py"
assert_contains "ruff: '&' in file name kept in lint line" "$(ctx "$T_OUT")" "app/a&b.py:1:1: F401"
write "$P/app/migrations/0001_initial.py" 'x = 1'
: >"$LOG"
fmt "$P/app/migrations/0001_initial.py"
assert_eq "migrations path: no output" "" "$T_OUT"
assert_eq "migrations path: ruff not called" "" "$(cat "$LOG")"
write "$P/node_modules/pkg/index.py" 'x = 1'
fmt "$P/node_modules/pkg/index.py"
assert_eq "node_modules path: no output" "" "$T_OUT"
write "$P/uv.lock" 'version = 1'
fmt "$P/uv.lock"
assert_eq "lockfile: no output" "" "$T_OUT"
write "$P/sub dir/pkg/mod.py" 'x=1'
write "$P/sub dir/pyproject.toml" '[project]
name = "sub"'
fmt "$P/sub dir/pkg/mod.py"
assert_eq "nearest pyproject without ruff: no output" "" "$T_OUT"

t_section "ruff 모노레포: cwd 기준 상대 경로 → root 기준(A10)"
write "$P/mono/backend/pyproject.toml" '[tool.ruff]
line-length = 100'
# 진짜 ruff 처럼 자기 cwd 기준 상대 경로로 출력(논리·물리 cwd 둘 다 시도)
mkfake "$P/mono/backend/.venv/bin/ruff" 'f=""; for a; do case $a in /*) f=$a ;; esac; done
c=$(pwd -P)
case $f in "$PWD"/*) r=${f#"$PWD"/} ;; "$c"/*) r=${f#"$c"/} ;; *) r=$f ;; esac
case $1 in
  format) exit 0 ;;
  check) printf "%s:1:8: F401 [*] os imported but unused\n" "$r"; exit 1 ;;
esac'
write "$P/mono/backend/app/v.py" 'import os'
fmt "$P/mono/backend/app/v.py"
C=$(ctx "$T_OUT")
assert_contains "monorepo: header relpath from root" "$C" "ruff: mono/backend/app/v.py 린트 이슈 1개:"
assert_contains "monorepo: lint line rewritten to root-relative" "$C" "mono/backend/app/v.py:1:8: F401"
assert_not_contains "monorepo: no cwd-relative lint line" "$C" "
app/v.py:1:8"

t_section "ECC quality-gate 겹침 방지(D1) / force / 캐시"
ECCS="$T_HOME/.claude/settings.json"
write "$ECCS" '{"enabledPlugins":{"ecc@ecc":true,"other@x":false}}'
rm -f "$TMPDIR"/claude-format-ecc.*
fmt "$P/scripts/bad.sh"
assert_contains "ECC check-only (no ECC_QUALITY_GATE_FIX): bash -n runs" "$(ctx "$T_OUT")" "bash -n"
: >"$LOG"; fmt "$P/app/views.py"
assert_contains "ECC check-only: ruff still runs" "$(cat "$LOG")" "ruff format"
ECC_QUALITY_GATE_FIX=true fmt "$P/scripts/bad.sh"
assert_contains "ECC fix mode: bash -n always runs" "$(ctx "$T_OUT")" "bash -n"
: >"$LOG"; ECC_QUALITY_GATE_FIX=TRUE fmt "$P/app/views.py"
assert_eq "ECC fix mode (TRUE): .py skipped" "" "$T_OUT"
assert_eq "ECC fix mode: ruff not called" "" "$(cat "$LOG")"
set -- "$TMPDIR"/claude-format-ecc.*
ECCC=$1
if [ -f "$ECCC" ]; then t_pass "ECC cache written"; else t_fail "ECC cache written" "$ECCC"; fi
: >"$LOG"; ECC_QUALITY_GATE_FIX=true fmt "$P/app/views.py"
assert_eq "ECC fix mode (cached): ruff not called" "" "$(cat "$LOG")"
: >"$LOG"; ECC_QUALITY_GATE_FIX=yes fmt "$P/app/views.py"
assert_contains "ECC_QUALITY_GATE_FIX=yes (not true): ruff runs" "$(cat "$LOG")" "ruff format"
: >"$LOG"; ECC_QUALITY_GATE_FIX=true CLAUDE_FORMAT_ON_EDIT=force fmt "$P/app/views.py"
assert_contains "force bypasses ECC skip" "$(cat "$LOG")" "ruff format"
: >"$LOG"; ECC_QUALITY_GATE_FIX=true ECC_HOOK_PROFILE=" Minimal " fmt "$P/app/views.py"
assert_contains "ECC profile minimal: ruff runs" "$(cat "$LOG")" "ruff format"
: >"$LOG"; ECC_QUALITY_GATE_FIX=true ECC_HOOK_PROFILE=strict fmt "$P/app/views.py"
assert_eq "ECC profile strict: .py skipped" "" "$(cat "$LOG")"
: >"$LOG"; ECC_QUALITY_GATE_FIX=true ECC_DISABLED_HOOKS="pre:x, POST:Quality-Gate " fmt "$P/app/views.py"
assert_contains "ECC quality-gate disabled (case/space-insensitive): ruff runs" "$(cat "$LOG")" "ruff format"
: >"$LOG"; ECC_QUALITY_GATE_FIX=true ECC_DISABLED_HOOKS="post:quality-gate-extra" fmt "$P/app/views.py"
assert_eq "other ECC hook id disabled: .py still skipped" "" "$(cat "$LOG")"
mkfake "$FAKE/gofmt" 'exit 0'
write "$P/cmd/main.go" 'package main'
: >"$LOG"; ECC_QUALITY_GATE_FIX=true fmt "$P/cmd/main.go"
assert_eq "ECC fix mode: .go skipped" "" "$(cat "$LOG")"
: >"$LOG"; fmt "$P/cmd/main.go"
assert_contains "ECC check-only: gofmt runs" "$(cat "$LOG")" "gofmt -w"
rm -f "$FAKE/gofmt" "$TMPDIR"/claude-format-ecc.*
: >"$LOG"; HOOK_FORCE_PARSER=python3 ECC_QUALITY_GATE_FIX=true fmt "$P/app/views.py"
assert_eq "ECC fix mode (python3 check): .py skipped" "" "$(cat "$LOG")"
# A8: settings.json 이 캐시와 같은 초에 바뀌면 캐시를 쓰지 않는다(엄밀히 새로울 때만 사용)
write "$ECCS" '{"enabledPlugins":{"ecc@ecc":false}}'
touch -r "$ECCC" "$ECCS"
: >"$LOG"; ECC_QUALITY_GATE_FIX=true fmt "$P/app/views.py"
assert_contains "settings changed in cache's second: stale cache ignored" "$(cat "$LOG")" "ruff format"
rm -f "$TMPDIR"/claude-format-ecc.*
: >"$LOG"; ECC_QUALITY_GATE_FIX=true fmt "$P/app/views.py"
assert_contains "ECC disabled in settings: ruff runs" "$(cat "$LOG")" "ruff format"
rm -f "$ECCS" "$TMPDIR"/claude-format-ecc.*
: >"$LOG"; ECC_QUALITY_GATE_FIX=true fmt "$P/app/views.py"
assert_contains "no settings.json: ruff runs" "$(cat "$LOG")" "ruff format"

t_section "watchdog(CLAUDE_FORMAT_TIMEOUT)"
# 시간은 ms 로 잰다(t_ms·t_under: tests/lib/testlib.sh). 감시가 멈추지 못하면 포매터가 30초를 다 쓰므로 상한과 분명히 갈린다(R5: 초 단위 date 는 ±1초 오차)
mkfake "$FAKE/gofmt" 'exec sleep 30'
write "$P/cmd/main.go" 'package main'
t0=$(t_ms)
CLAUDE_FORMAT_TIMEOUT=1 fmt "$P/cmd/main.go"
t1=$(t_ms)
t_under "slow formatter killed at the 1s timeout" $((t1 - t0)) 4000
assert_contains "timeout reported" "$(ctx "$T_OUT")" "포매터 실패(gofmt): 시간 초과(1초)"
# A6: TERM 을 무시하는 포매터는 2초 뒤 KILL(약 3초)
mkfake "$FAKE/gofmt" 'trap "" TERM; i=0; while [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done'
t0=$(t_ms)
CLAUDE_FORMAT_TIMEOUT=1 fmt "$P/cmd/main.go"
t1=$(t_ms)
t_under "TERM-ignoring formatter KILLed (~3s)" $((t1 - t0)) 8000
assert_contains "TERM-ignoring: timeout reported" "$(ctx "$T_OUT")" "포매터 실패(gofmt): 시간 초과(1초)"
rm -f "$FAKE/gofmt"

t_section "prettier / biome"
mkfake "$P/web/node_modules/.bin/prettier" 'for a; do f=$a; done; printf "// pretty\n" >>"$f"'
write "$P/web/package.json" '{"name":"web","devDependencies":{"prettier":"^3.0.0"}}'
write "$P/web/src/app.ts" 'let a=1'
: >"$LOG"
fmt "$P/web/src/app.ts"
assert_eq "prettier dependency only (no config): no output" "" "$T_OUT"
write "$P/web/.prettierrc.json" '{}'
fmt "$P/web/src/app.ts"
assert_contains "prettier config: changed notice" "$(ctx "$T_OUT")" "포매터(prettier)가 web/src/app.ts를 수정했다"
assert_contains "prettier argv" "$(cat "$LOG")" "prettier --write --log-level warn $PP/web/src/app.ts"
rm -f "$P/web/.prettierrc.json"
write "$P/web/package.json" '{"name":"web","prettier":{"semi":false}}'
fmt "$P/web/src/app.ts"
assert_contains "package.json prettier key: runs" "$(ctx "$T_OUT")" "포매터(prettier)"
# D1: ECC fix 모드여도 ECC 가 쓰지 않는 타입(.css 등)은 계속 포맷
write "$T_HOME/.claude/settings.json" '{"enabledPlugins":{"ecc@ecc":true}}'
rm -f "$TMPDIR"/claude-format-ecc.*
: >"$LOG"; ECC_QUALITY_GATE_FIX=true fmt "$P/web/src/app.ts"
assert_eq "ECC fix mode: .ts skipped" "" "$(cat "$LOG")"
write "$P/web/src/site.css" 'a{color:red}'
: >"$LOG"; ECC_QUALITY_GATE_FIX=true fmt "$P/web/src/site.css"
assert_contains "ECC fix mode: .css still formatted" "$(cat "$LOG")" "prettier --write --log-level warn $PP/web/src/site.css"
rm -f "$T_HOME/.claude/settings.json" "$TMPDIR"/claude-format-ecc.*
write "$P/manage.py" 'print(1)'
write "$P/web/templates/base.html" '<p>x</p>'
fmt "$P/web/templates/base.html"
assert_eq "django project: .html skipped" "" "$T_OUT"
rm -f "$P/manage.py"
mkfake "$P/web/node_modules/.bin/prettier" 'echo "[error] boom: bad syntax" >&2; exit 2'
fmt "$P/web/src/app.ts"
assert_contains "formatter failure reported" "$(ctx "$T_OUT")" "포매터 실패(prettier): [error] boom: bad syntax"
rm -rf "$P/web/node_modules/.bin/prettier"
write "$P/web/package.json" '{"name":"web"}'
write "$P/web/biome.json" '{}'
mkfake "$P/web/node_modules/.bin/biome" 'exit 0'
: >"$LOG"
fmt "$P/web/src/app.ts"
assert_contains "biome argv" "$(cat "$LOG")" "biome format --write --no-errors-on-unmatched $PP/web/src/app.ts"
assert_eq "biome unchanged file: no output" "" "$T_OUT"
write "$P/web/README.md" '# web'
: >"$LOG"
fmt "$P/web/README.md"
assert_eq "biome not used for .md" "" "$(cat "$LOG")"

t_section "black + isort"
write "$P/legacy/pyproject.toml" '[tool.black]
line-length = 88
[tool.isort]
profile = "black"'
mkfake "$P/legacy/.venv/bin/black" 'exit 0'
mkfake "$P/legacy/.venv/bin/isort" 'exit 0'
write "$P/legacy/mod.py" 'import sys'
: >"$LOG"
fmt "$P/legacy/mod.py"
assert_contains "black argv" "$(cat "$LOG")" "black -q $PP/legacy/mod.py"
assert_contains "isort argv --filter-files with black profile" "$(cat "$LOG")" "isort -q --filter-files --profile black $PP/legacy/mod.py"
# A2: black 은 명시 경로에 exclude/extend-exclude 를 적용하지 않으므로 force-exclude 없으면 건너뜀
write "$P/legacy/pyproject.toml" '[tool.black]
line-length = 88
  extend-exclude = "old/"
[tool.isort]
profile = "black"'
: >"$LOG"; fmt "$P/legacy/mod.py"
assert_not_contains "black extend-exclude w/o force-exclude: black skipped" "$(cat "$LOG")" "black -q"
assert_contains "black skipped: isort still runs" "$(cat "$LOG")" "isort -q --filter-files --profile black"
write "$P/legacy/pyproject.toml" '[tool.black]
exclude = "old/"
force-exclude = "old/"'
: >"$LOG"; fmt "$P/legacy/mod.py"
assert_contains "black with force-exclude: runs" "$(cat "$LOG")" "black -q $PP/legacy/mod.py"
write "$P/legacy/pyproject.toml" '[tool.black]
line-length = 88
[tool.other]
exclude = ["x"]'
: >"$LOG"; fmt "$P/legacy/mod.py"
assert_contains "exclude in another section: black runs" "$(cat "$LOG")" "black -q $PP/legacy/mod.py"
write "$P/legacy/pyproject.toml" '[tool.isort]
profile = "black"'
: >"$LOG"; fmt "$P/legacy/mod.py"
assert_contains "isort only: --filter-files, no black profile" "$(cat "$LOG")" "isort -q --filter-files $PP/legacy/mod.py"
assert_not_contains "isort only: black not called" "$(cat "$LOG")" "black -q"

t_section "CLAUDE_PROJECT_DIR / 워크트리 cwd / 심볼릭 링크"
write "$T_WT/tools/w.sh" 'fi'
CLAUDE_PROJECT_DIR=$P fmt "$T_WT/tools/w.sh" "$T_WT" Write
assert_contains "worktree cwd outside CLAUDE_PROJECT_DIR: runs" "$(ctx "$T_OUT")" "bash -n: tools/w.sh"
CLAUDE_PROJECT_DIR=$P fmt "$T_WT/tools/w.sh" "$P" MultiEdit
assert_eq "outside both roots: no output" "" "$T_OUT"
CLAUDE_PROJECT_DIR=$P fmt "$P/scripts/bad.sh" "$T_WT"
assert_contains "inside CLAUDE_PROJECT_DIR: relpath from project" "$(ctx "$T_OUT")" "bash -n: scripts/bad.sh"
ln -s "$P" "$T_TMP/proj link"
fmt "$T_TMP/proj link/scripts/bad.sh" "$P"
assert_contains "symlinked path resolved physically" "$(ctx "$T_OUT")" "bash -n: scripts/bad.sh"
ln -s "$P/scripts/bad.sh" "$P/scripts/link.sh"
fmt "$P/scripts/link.sh"
assert_eq "symlink file itself: skipped" "" "$T_OUT"

t_section "root 밖: .. / 디렉터리 심볼릭 링크(A4)"
write "$T_TMP/sibling/bad.sh" 'if then fi ('
fmt "$P/../sibling/bad.sh"
assert_eq "<root>/../sibling: outside → no output" "" "$T_OUT"
fmt "../sibling/bad.sh"
assert_eq "relative ../sibling: outside → no output" "" "$T_OUT"
ln -s "$T_TMP/sibling" "$P/ext"
fmt "$P/ext/bad.sh"
assert_eq "dir symlink pointing outside root: no output" "" "$T_OUT"
fmt "$P/scripts/../scripts/bad.sh"
assert_contains ".. that stays inside root: runs with clean relpath" "$(ctx "$T_OUT")" "bash -n: scripts/bad.sh 문법 오류"
fmt "$P/scripts/"
assert_eq "path ending in /: no output" "" "$T_OUT"

t_section "공백 포함 경로 / 상대 경로"
write "$P/my dir/x y.sh" 'echo "unterminated'
fmt "my dir/x y.sh"
assert_contains "relative path with spaces" "$(ctx "$T_OUT")" "bash -n: my dir/x y.sh 문법 오류"

t_report
