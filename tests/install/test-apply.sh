#!/usr/bin/env bash
# ai_boilerplate — apply.sh 테스트: 프로필(생략/auto/명시), CLAUDE.md 생성·AGENTS.md·.claude/CLAUDE.md, settings 병합,
# gitignore 1회 추가, 포맷 훅 opt-in, --team, --dry-run, 거부 목록. 모든 경로에 공백 포함.
. "$(cd -P -- "$(dirname -- "$0")" && pwd -P)/helpers.sh"

PT="claude/project-template"
new_home; HM="$NEW_HOME"
new_proj() {  # <name> → NEW_PROJ (공백 포함 경로, git init)
  NEW_PROJ="$TROOT/$1 dir"; mkdir -p "$NEW_PROJ"
  (cd "$NEW_PROJ" && git init -q 2>/dev/null) || true
}

echo "## (12-0) --profile 생략: 프로필은 선택형 — 적용하지 않고 --profile auto 가 고를 프로필만 안내 (D01)"
new_proj noprof; PN="$NEW_PROJ"
touch "$PN/pyproject.toml" "$PN/uv.lock" "$PN/manage.py"
run_apply "$HM" "$PN"
assert_eq "no-profile: exit 0" 0 "$RC" || sed -n '1,30p' "$OUT"
assert_no_file "no-profile: no python rule" "$PN/.claude/rules/python.md"
assert_no_file "no-profile: no django rule" "$PN/.claude/rules/django.md"
assert_contains "no-profile: says no profile was applied" "$OUT" "프로필: (없음) — --profile 을 지정하지 않아 언어 프로필을 적용하지 않는다"
if need "no-profile: hint" claude/global/hooks/lib/detect-stack.sh; then
  assert_contains "no-profile: hint names what --profile auto would apply" "$OUT" "힌트: --profile auto 를 붙이면 python django 프로필을 적용한다"
  assert_not_contains "no-profile: hint does not mark missing rule files as present" "$OUT" "규칙 파일이 이미 있는 프로필"
fi
need "no-profile: project.md" "$PT/dot-claude/rules/project.md" && assert_file "no-profile: common rules still applied" "$PN/.claude/rules/project.md"
if need "no-profile: fragment" profiles/python/settings.fragment.json "$PT/dot-claude/settings.json"; then
  FRAG_RULE=$(jq_py "$REPO/profiles/python/settings.fragment.json" '(d.get("permissions",{}).get("allow") or [""])[0]')
  [ -n "$FRAG_RULE" ] && assert_eq "no-profile: python fragment not merged" False "$(jq_py "$PN/.claude/settings.json" "\"$FRAG_RULE\" in d['permissions'].get('allow', [])")"
fi
# 예전 버전(암묵적 auto)이 프로필을 적용한 프로젝트: --profile 없이 다시 적용해도 그대로 두고, 힌트는 이미 있는 규칙 파일을 밝힌다
if need "no-profile(applied): rules" claude/global/hooks/lib/detect-stack.sh profiles/python/rules/python.md profiles/django/rules/django.md; then
  new_proj applied; PA="$NEW_PROJ"; touch "$PA/pyproject.toml" "$PA/uv.lock" "$PA/manage.py"
  mkdir -p "$PA/.claude/rules"; printf 'mine py\n' > "$PA/.claude/rules/python.md"; printf 'mine dj\n' > "$PA/.claude/rules/django.md"
  run_apply "$HM" "$PA"
  assert_eq "no-profile(applied): exit 0" 0 "$RC"
  assert_eq "no-profile(applied): rule files untouched" "mine py|mine dj" "$(cat "$PA/.claude/rules/python.md")|$(cat "$PA/.claude/rules/django.md")"
  assert_contains "no-profile(applied): hint says which profiles already have rule files" "$OUT" \
    "힌트: --profile auto 를 붙이면 python django 프로필을 적용한다(규칙 파일이 이미 있는 프로필: python django)"
  rm -f "$PA/.claude/rules/django.md"; run_apply "$HM" "$PA" --dry-run
  assert_contains "no-profile(applied): only profiles whose rule files all exist are marked" "$OUT" "(규칙 파일이 이미 있는 프로필: python)"
fi
new_proj nostack; run_apply "$HM" "$NEW_PROJ" --dry-run
assert_eq "no-profile(no stack): exit 0" 0 "$RC"
assert_contains "no-profile(no stack): says no profile was applied" "$OUT" "프로필: (없음) — --profile 을 지정하지 않아"
assert_not_contains "no-profile(no stack): no hint" "$OUT" "힌트:"

echo "## (12) uv+django 프로젝트에 --profile auto / 명시 프로필"
new_proj proj; P="$NEW_PROJ"
touch "$P/pyproject.toml" "$P/uv.lock" "$P/manage.py"
printf 'node_modules\n*.pyc' > "$P/.gitignore"   # 끝 개행 없음
run_apply "$HM" "$P" --profile auto
assert_eq "apply(auto): exit 0" 0 "$RC" || sed -n '1,30p' "$OUT"
if need "apply(auto): stack detected" claude/global/hooks/lib/detect-stack.sh; then
  assert_contains "apply(auto): prints detected stack" "$OUT" "감지된 스택"
  assert_file "apply(auto): python profile rule" "$P/.claude/rules/python.md"
  assert_file "apply(auto): django profile rule" "$P/.claude/rules/django.md"
  assert_not_contains "apply(auto): no hint when --profile is given" "$OUT" "힌트:"
fi
if need "apply: CLAUDE.md" "$PT/CLAUDE.md.tmpl"; then
  assert_file "apply: CLAUDE.md created" "$P/CLAUDE.md"
  assert_eq "apply: CLAUDE.md heading carries project name" True "$(head -1 "$P/CLAUDE.md" | grep -qF 'proj dir' && echo True || echo False)"
  assert_not_contains "apply: placeholder replaced in heading" "$P/CLAUDE.md" "# <프로젝트명>"
fi
need "apply: local example" "$PT/CLAUDE.local.md.example" && assert_file "apply: CLAUDE.local.md.example copied" "$P/CLAUDE.local.md.example"
need "apply: project.md" "$PT/dot-claude/rules/project.md" && assert_file "apply: .claude/rules/project.md" "$P/.claude/rules/project.md"
need "apply: settings.local example" "$PT/dot-claude/settings.local.json.example" && assert_file "apply: settings.local.json.example" "$P/.claude/settings.local.json.example"
if need "apply: settings" "$PT/dot-claude/settings.json"; then
  assert_file "apply: .claude/settings.json created" "$P/.claude/settings.json"
  assert_eq "apply: settings valid JSON with \$schema" True "$(jq_py "$P/.claude/settings.json" '"$schema" in d')"
  assert_eq "apply: no hooks without --with-format-hook" True "$(jq_py "$P/.claude/settings.json" '"hooks" not in d or not d["hooks"]')"
fi
assert_no_file "apply: no .claude/hooks without flag" "$P/.claude/hooks"
if need "apply: gitignore" "$PT/gitignore.claude"; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    assert_eq "gitignore: line present once [$line]" 1 "$(grep -cxF -- "$line" "$P/.gitignore")"
  done < "$REPO/$PT/gitignore.claude"
  assert_eq "gitignore: original lines kept" 2 "$(grep -cE '^(node_modules|\*\.pyc)$' "$P/.gitignore")"
  assert_eq "gitignore: newline inserted before append" 0 "$(grep -c '^\*\.pyc#' "$P/.gitignore")"
fi
LINES1=$(count_lines "$P/.gitignore")
run_apply "$HM" "$P" --profile django
assert_eq "apply(django): exit 0" 0 "$RC"
if need "apply(django): profile rules" profiles/python/rules profiles/django/rules; then
  assert_file "apply(django): python rule" "$P/.claude/rules/python.md"
  assert_file "apply(django): django rule" "$P/.claude/rules/django.md"
  assert_eq "apply(django): rules have paths frontmatter" 2 "$(grep -l '^paths:' "$P/.claude/rules/python.md" "$P/.claude/rules/django.md" 2>/dev/null | grep -c '')"
fi
if need "apply(django): fragment merged" profiles/python/settings.fragment.json; then
  FRAG_RULE=$(jq_py "$REPO/profiles/python/settings.fragment.json" '(d.get("permissions",{}).get("allow") or [""])[0]')
  [ -n "$FRAG_RULE" ] && assert_eq "apply(django): python fragment rule merged" True "$(jq_py "$P/.claude/settings.json" "\"$FRAG_RULE\" in d['permissions']['allow']")"
fi
assert_eq "apply(rerun): gitignore not duplicated" "$LINES1" "$(count_lines "$P/.gitignore")"
assert_contains "apply(rerun): CLAUDE.md unchanged" "$OUT" "변경 없음"

echo "## (12b) --with-format-hook → 훅 복사 + PostToolUse; 다시 플래그 없이 → 제거"
run_apply "$HM" "$P" --profile django --with-format-hook
assert_apply_ok "format-hook: exit 0"
if need "format-hook: hook sources" claude/global/hooks/run-hook.sh claude/global/hooks/format-on-edit.sh claude/global/hooks/lib/common.sh; then
  for f in run-hook.sh format-on-edit.sh lib/common.sh; do assert_exec "format-hook: .claude/hooks/$f (755)" "$P/.claude/hooks/$f"; done
fi
if need "format-hook: fragment" "$PT/dot-claude/fragments/format-hook.json"; then
  assert_eq "format-hook: PostToolUse entry present" 1 "$(hook_commands "$P/.claude/settings.json" | grep -c 'format-on-edit')"
  run_apply "$HM" "$P" --profile django
  assert_eq "format-hook: removed without flag (--drop-hooks)" 0 "$(hook_commands "$P/.claude/settings.json" | grep -c 'format-on-edit')"
fi

echo "## (12c) --team 은 전역 git.md 를 동봉"
if need "team: git.md" claude/global/rules/git.md; then
  run_apply "$HM" "$P" --profile django --team
  assert_eq "team: exit 0" 0 "$RC"
  assert_same "team: .claude/rules/git.md equals global git.md" "$REPO/claude/global/rules/git.md" "$P/.claude/rules/git.md"
fi

echo "## (13) AGENTS.md 만 있는 프로젝트 / .claude/CLAUDE.md 가 있는 프로젝트"
if need "agents-md: template" "$PT/CLAUDE.md.tmpl"; then
  new_proj agents; PA="$NEW_PROJ"; printf '# agents\n' > "$PA/AGENTS.md"
  run_apply "$HM" "$PA" --profile python
  assert_eq "agents-md: exit 0" 0 "$RC"
  assert_eq "agents-md: CLAUDE.md starts with @AGENTS.md" "@AGENTS.md" "$(head -1 "$PA/CLAUDE.md" 2>/dev/null)"
  assert_eq "agents-md: blank line after import" "" "$(sed -n '2p' "$PA/CLAUDE.md")"
  assert_contains "agents-md: notice printed" "$OUT" "AGENTS.md는 @import로 계속 로드됨"
  new_proj dotclaude; PD="$NEW_PROJ"; mkdir -p "$PD/.claude"; printf '# existing\n' > "$PD/.claude/CLAUDE.md"
  run_apply "$HM" "$PD" --profile python
  assert_eq "dot-claude-md: exit 0" 0 "$RC"
  assert_no_file "dot-claude-md: no new CLAUDE.md" "$PD/CLAUDE.md"
  assert_eq "dot-claude-md: existing file untouched" "# existing" "$(cat "$PD/.claude/CLAUDE.md")"
  assert_file "dot-claude-md: template offered as .ai_boilerplate.new" "$PD/.claude/CLAUDE.md.ai_boilerplate.new"
  run_apply "$HM" "$PD" --profile python --force --yes
  assert_eq "dot-claude-md --force: exit 0" 0 "$RC"
  assert_no_file "dot-claude-md --force: still no root CLAUDE.md" "$PD/CLAUDE.md"
  assert_eq "dot-claude-md --force: existing file untouched" "# existing" "$(cat "$PD/.claude/CLAUDE.md")"
  assert_contains "dot-claude-md --force: WARN explains it" "$OUT" ".claude/CLAUDE.md 가 있어 --force 로도 CLAUDE.md 를 새로 만들지 않는다"
  assert_file "dot-claude-md --force: candidate stays next to .claude/CLAUDE.md" "$PD/.claude/CLAUDE.md.ai_boilerplate.new"
  new_proj existing; PE="$NEW_PROJ"; printf '# mine\n' > "$PE/CLAUDE.md"
  run_apply "$HM" "$PE" --profile python
  assert_eq "existing-md: kept" "# mine" "$(cat "$PE/CLAUDE.md")"
  assert_file "existing-md: .ai_boilerplate.new beside it" "$PE/CLAUDE.md.ai_boilerplate.new"
  run_apply "$HM" "$PE" --profile python --force --yes
  assert_not_contains "existing-md: --force overwrote" "$PE/CLAUDE.md" "# mine"
  assert_eq "existing-md: --force made a backup" True "$( [ -n "$(ls -d "$HM/.claude/backups/ai_boilerplate/apply/existing dir"/* 2>/dev/null)" ] && echo True || echo False)"
fi

echo "## (13b) .worktreeinclude: 없으면 생성, 있으면 --force 로도 유지"
if need "worktreeinclude: template" "$PT/dot-worktreeinclude" "$PT/gitignore.claude"; then
  assert_same "worktreeinclude: created from template" "$REPO/$PT/dot-worktreeinclude" "$P/.worktreeinclude"
  assert_eq "worktreeinclude: template copies no secret file by default" 0 "$(grep -cE '^[^#]*\.env' "$REPO/$PT/dot-worktreeinclude")"
  # 패턴에 맞으면서 gitignore된 파일만 복사되므로, 템플릿의 항목은 gitignore.claude 가 제외하는 파일이어야 한다
  while IFS= read -r line; do
    case $line in ''|'#'*) continue ;; esac
    assert_eq "worktreeinclude: [$line] is ignored by gitignore.claude" 1 "$(grep -cxF -- "$line" "$REPO/$PT/gitignore.claude")"
  done < "$REPO/$PT/dot-worktreeinclude"
  new_proj wti; PW="$NEW_PROJ"; printf '.env\n' > "$PW/.worktreeinclude"
  run_apply "$HM" "$PW"
  assert_eq "worktreeinclude(existing): kept" ".env" "$(cat "$PW/.worktreeinclude")"
  assert_matches "worktreeinclude(existing): plan says kept" "$OUT" '유지\(기존 파일\) +\.worktreeinclude'
  assert_contains "worktreeinclude: listed as a file to commit" "$OUT" "  .worktreeinclude"
  run_apply "$HM" "$PW" --force --yes
  assert_eq "worktreeinclude(existing): --force does not overwrite" ".env" "$(cat "$PW/.worktreeinclude")"
  assert_no_file "worktreeinclude(existing): no .ai_boilerplate.new" "$PW/.worktreeinclude.ai_boilerplate.new"
fi

echo "## (13c) --profile sandbox: 샌드박스 설정·규칙을 더한다(auto 는 고르지 않는다)"
if need "sandbox: profile" profiles/sandbox/settings.fragment.json profiles/sandbox/rules/sandbox.md "$PT/dot-claude/settings.json"; then
  SBX="$REPO/profiles/sandbox/settings.fragment.json"
  assert_no_file "sandbox: not applied by --profile auto/django" "$P/.claude/rules/sandbox.md"
  assert_eq "sandbox: no sandbox key without the profile" False "$(jq_py "$P/.claude/settings.json" '"sandbox" in d')"
  assert_eq "sandbox: fragment keeps the approval flow (no auto-allow)" True "$(jq_py "$SBX" 'd["sandbox"]["enabled"] is True and d["sandbox"]["autoAllowBashIfSandboxed"] is False')"
  assert_eq "sandbox: fragment does not widen the boundary" True "$(jq_py "$SBX" 'not any(k in d["sandbox"] for k in ("excludedCommands", "ignoreViolations", "enableWeakerNetworkIsolation", "enableWeakerNestedSandbox", "network")) and sorted(d["sandbox"]["filesystem"]) == ["denyRead"]')"
  assert_eq "sandbox: fragment denyRead uses literal home paths only" True "$(jq_py "$SBX" 'all(p.startswith("~/") and "*" not in p for p in d["sandbox"]["filesystem"]["denyRead"])')"
  new_proj sbx; PS="$NEW_PROJ"
  run_apply "$HM" "$PS" --profile sandbox
  assert_apply_ok "sandbox: exit 0"
  assert_same "sandbox: rule copied" "$REPO/profiles/sandbox/rules/sandbox.md" "$PS/.claude/rules/sandbox.md"
  assert_eq "sandbox: settings carry the fragment's sandbox block" True "$(jq_py "$PS/.claude/settings.json" "d['sandbox'] == json.load(open('$SBX', encoding='utf-8'))['sandbox']")"
  assert_eq "sandbox: unsandboxed retry asks" True "$(jq_py "$PS/.claude/settings.json" '"Bash(dangerouslyDisableSandbox:true)" in d["permissions"]["ask"]')"
  assert_not_contains "sandbox: no validate WARN/FAIL for the sandbox keys" "$OUT" "스키마 스냅샷에 없는 키"
  run_apply "$HM" "$PS" --profile sandbox
  assert_matches "sandbox(rerun): settings unchanged" "$OUT" '변경 없음 +\.claude/settings\.json'
  # 이미 있는 값은 유지하고 없는 키만 더한다(다른 프로필 조각과 같은 병합 규칙)
  new_proj sbx2; PS2="$NEW_PROJ"; mkdir -p "$PS2/.claude"
  printf '{"sandbox":{"enabled":false,"excludedCommands":["docker"]}}\n' > "$PS2/.claude/settings.json"
  run_apply "$HM" "$PS2" --profile sandbox,python
  assert_eq "sandbox(existing): user's values kept" True "$(jq_py "$PS2/.claude/settings.json" 'd["sandbox"]["enabled"] is False and d["sandbox"]["excludedCommands"] == ["docker"]')"
  assert_eq "sandbox(existing): missing keys added" True "$(jq_py "$PS2/.claude/settings.json" '"~/.ssh" in d["sandbox"]["filesystem"]["denyRead"]')"
  assert_file "sandbox: combines with a language profile" "$PS2/.claude/rules/python.md"
fi

echo "## (14) 거부: \$HOME, \$HOME/.claude/x, 저장소 자체, 없는 디렉터리, 잘못된 프로필"
run_apply "$HM" "$HM"; assert_eq "refuse: HOME → exit 1" 1 "$RC"
mkdir -p "$HM/.claude/x"; run_apply "$HM" "$HM/.claude/x"; assert_eq "refuse: HOME/.claude/x → exit 1" 1 "$RC"
run_apply "$HM" "$REPO"; assert_eq "refuse: REPO_DIR → exit 1" 1 "$RC"
run_apply "$HM" "$TROOT/does not exist"; assert_eq "refuse: missing dir → exit 1" 1 "$RC"
new_proj bad; run_apply "$HM" "$NEW_PROJ" --profile cobol; assert_eq "refuse: unknown profile → exit 2" 2 "$RC"
assert_no_file "refuse: nothing written to HOME" "$HM/CLAUDE.md"

echo "## (dry-run) 아무것도 쓰지 않는다"
new_proj dry; PR="$NEW_PROJ"; snapshot "$PR" "$TROOT/dry.a"
run_apply "$HM" "$PR" --profile python --dry-run
assert_eq "dry-run: exit 0" 0 "$RC"
snapshot "$PR" "$TROOT/dry.b"
assert_same "dry-run: project untouched" "$TROOT/dry.a" "$TROOT/dry.b"
assert_no_file "dry-run: no CLAUDE.md" "$PR/CLAUDE.md"

t_report "test-apply"
