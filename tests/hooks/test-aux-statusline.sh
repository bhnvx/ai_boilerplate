#!/usr/bin/env bash
# tests/hooks/test-aux-statusline.sh — statusline.sh 테스트(fixture, rate_limits, 색/ASCII, 2초 git 캐시, 빈 stdin)
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
t_setup
unset CLAUDE_STATUSLINE_COLOR NO_COLOR LC_ALL LC_CTYPE
export LANG=en_US.UTF-8
export TMPDIR="$T_TMP/tmp dir"; mkdir -p "$TMPDIR"
FIX="$T_REPO_ROOT/tests/hooks/fixtures/statusline.json"
FIXRL="$T_REPO_ROOT/tests/hooks/fixtures/statusline-ratelimit.json"
ESC=$(printf '\033')

# with_dir <fixture> <dir> → workspace.current_dir / cwd 교체
with_dir() {
  if t_have_jq; then jq -c --arg d "$2" '.workspace.current_dir = $d | .cwd = $d' "$1"
  else python3 -I -S -c 'import json,sys
d=json.load(open(sys.argv[1])); d.setdefault("workspace",{})["current_dir"]=sys.argv[2]; d["cwd"]=sys.argv[2]; print(json.dumps(d))' "$1" "$2"; fi
}
sl() { t_run_hook statusline "$1"; L=$T_OUT; }
lines() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }

t_section "fixture(기본)"
CLAUDE_STATUSLINE_COLOR=0 sl "$(cat "$FIX")"
assert_rc "fixture: exit 0" 0
assert_eq "fixture: exactly one line" 1 "$(lines "$L")"
assert_eq "fixture: full line (no git dir)" "Opus 5.5 │ ctx 73% │ \$1.23 │ example-project │ eff xhigh │ PR #42" "$L"
CLAUDE_STATUSLINE_COLOR=0 HOOK_FORCE_PARSER=python3 sl "$(cat "$FIX")"
assert_eq "fixture: python3 parser same line" "Opus 5.5 │ ctx 73% │ \$1.23 │ example-project │ eff xhigh │ PR #42" "$L"

t_section "git 브랜치 · 변경 표시 · 2초 캐시"
J=$(with_dir "$FIX" "$T_PROJ")
CLAUDE_STATUSLINE_COLOR=0 sl "$J"
assert_contains "repo: branch shown" "$L" "│ ⎇ main │"
assert_contains "repo: dirname with space" "$L" "│ proj dir │"
key=$(printf '%s' "$T_PROJ" | cksum); key=${key%% *}
cache="$TMPDIR/claude-statusline-$key"
if [ -f "$cache" ]; then t_pass "cache file written"; else t_fail "cache file written" "$cache"; fi
printf 'dirty\n' >>"$T_PROJ/README.md"
CLAUDE_STATUSLINE_COLOR=0 sl "$J"
assert_contains "cache hit within 2s: still clean" "$L" "⎇ main │"
{ read -r t; rest=$(cat); } <"$cache"; printf '%s\n%s\n' "$((t - 10))" "$rest" >"$cache"
CLAUDE_STATUSLINE_COLOR=0 sl "$J"
assert_contains "cache expired: dirty marker" "$L" "⎇ main* │"
CLAUDE_STATUSLINE_COLOR=0 sl "$(with_dir "$FIX" "$T_WT")"
assert_contains "worktree: feature branch" "$L" "⎇ feature/x │"
mkdir -p "$T_TMP/plain"
CLAUDE_STATUSLINE_COLOR=0 sl '{"model":{"display_name":"M"},"workspace":{"current_dir":"'"$T_TMP/plain"'"},"worktree":{"branch":"wt/y"}}'
assert_eq "non-git: worktree.branch fallback" "M │ ⎇ wt/y │ plain" "$L"

t_section "rate_limits"
CLAUDE_STATUSLINE_COLOR=0 sl "$(cat "$FIXRL")"
assert_contains "ratelimit: 5h shown" "$L" "5h 83%"
assert_contains "ratelimit: 7d ≥ 50 shown" "$L" "5h 83% 7d 55%"
assert_not_contains "ratelimit: cost hidden" "$L" '$0.50'
assert_contains "ratelimit: ctx from tokens" "$L" "ctx 25%"
CLAUDE_STATUSLINE_COLOR=0 sl '{"model":{"display_name":"M"},"cwd":"/","rate_limits":{"five_hour":{"used_percentage":12.4},"seven_day":{"used_percentage":49.4}},"cost":{"total_cost_usd":3}}'
assert_eq "ratelimit: 7d < 50 hidden, root dir" "M │ 5h 12% │ /" "$L"
CLAUDE_STATUSLINE_COLOR=0 sl '{"model":{"display_name":"M"},"cwd":"/","rate_limits":{"seven_day":{"used_percentage":49.4}},"cost":{"total_cost_usd":3}}'
assert_eq "ratelimit: only 7d < 50 → cost fallback" "M │ \$3.00 │ /" "$L"
sl "$(cat "$FIXRL")"
assert_contains "color: 5h ≥ 80 red" "$L" "${ESC}[31m5h 83%${ESC}[0m"

t_section "ctx · 비용 · 색"
sl '{"model":{"display_name":"M"},"cwd":"/x","context_window":{"used_percentage":72.6}}'
assert_contains "color: ctx ≥ 70 yellow" "$L" "${ESC}[33mctx 73%${ESC}[0m"
sl '{"model":{"display_name":"M"},"cwd":"/x","context_window":{"used_percentage":91}}'
assert_contains "color: ctx ≥ 85 red" "$L" "${ESC}[31mctx 91%${ESC}[0m"
NO_COLOR=1 sl '{"model":{"display_name":"M"},"cwd":"/x","context_window":{"used_percentage":91}}'
assert_not_contains "NO_COLOR: no escape" "$L" "$ESC"
CLAUDE_STATUSLINE_COLOR=0 sl '{"model":{"display_name":"M"},"cwd":"/x","context_window":{"used_percentage":0,"total_input_tokens":0,"context_window_size":200000},"cost":{"total_cost_usd":0.005}}'
assert_eq "ctx 0 omitted, cost rounded" "M │ \$0.01 │ x" "$L"
CLAUDE_STATUSLINE_COLOR=0 sl '{"model":{"display_name":"M"},"cwd":"/x","context_window":{"used_percentage":null},"cost":{"total_cost_usd":12}}'
assert_eq "null pct, integer cost" "M │ \$12.00 │ x" "$L"
CLAUDE_STATUSLINE_COLOR=0 sl '{"model":{"display_name":"M"},"cwd":"/x","cost":{"total_cost_usd":1e-05}}'
assert_eq "scientific cost" "M │ \$0.00 │ x" "$L"

t_section "ASCII · 한 줄 보장 · 빈 입력"
LANG=C CLAUDE_STATUSLINE_COLOR=0 sl "$J"
assert_contains "ASCII separators" "$L" "Opus 5.5 | git:main"
assert_not_contains "ASCII: no box char" "$L" "│"
LANG=ko_KR.UTF-8 CLAUDE_STATUSLINE_COLOR=0 sl "$J"
assert_contains "ko_KR.UTF-8 → unicode separators" "$L" "Opus 5.5 │ ⎇ main"
sl '{"model":{"display_name":"Bad\nName\u001b[2J"},"cwd":"/x"}'
assert_eq "control chars: one line" 1 "$(lines "$L")"
assert_not_contains "control chars: escape stripped" "$L" "$ESC[2J"
t_run_hook statusline ""
assert_rc "empty stdin: exit 0" 0
assert_eq "empty stdin: no output" "" "$T_OUT"
t_run_hook statusline "not json"
assert_rc "invalid JSON: exit 0" 0
assert_eq "invalid JSON: at most one line" 0 "$(lines "$T_OUT")"
HOOK_FORCE_PARSER=none t_run_hook statusline "$(cat "$FIX")"
assert_contains "no parser: notice line" "$T_OUT" "jq/python3 없음"
assert_eq "no parser: one line" 1 "$(lines "$T_OUT")"

t_report
