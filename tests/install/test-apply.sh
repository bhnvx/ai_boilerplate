#!/usr/bin/env bash
# dev_settings — apply.sh 테스트: 프로필(auto/명시), CLAUDE.md 생성·AGENTS.md·.claude/CLAUDE.md, settings 병합,
# gitignore 1회 추가, 포맷 훅 opt-in, --team, --dry-run, 거부 목록. 모든 경로에 공백 포함.
. "$(cd -P -- "$(dirname -- "$0")" && pwd -P)/helpers.sh"

PT="claude/project-template"
new_home; HM="$NEW_HOME"
new_proj() {  # <name> → NEW_PROJ (공백 포함 경로, git init)
  NEW_PROJ="$TROOT/$1 dir"; mkdir -p "$NEW_PROJ"
  (cd "$NEW_PROJ" && git init -q 2>/dev/null) || true
}

echo "## (12) uv+django 프로젝트에 --profile auto / 명시 프로필"
new_proj proj; P="$NEW_PROJ"
touch "$P/pyproject.toml" "$P/uv.lock" "$P/manage.py"
printf 'node_modules\n*.pyc' > "$P/.gitignore"   # 끝 개행 없음
run_apply "$HM" "$P" --profile auto
assert_eq "apply(auto): exit 0" 0 "$RC" || sed -n '1,30p' "$OUT"
if need "apply(auto): stack detected" claude/global/hooks/lib/detect-stack.sh; then
  assert_contains "apply(auto): prints detected stack" "$OUT" "감지된 스택"
  assert_file "apply(auto): django profile rule" "$P/.claude/rules/django.md"
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
  assert_file "dot-claude-md: template offered as .dev_settings.new" "$PD/.claude/CLAUDE.md.dev_settings.new"
  new_proj existing; PE="$NEW_PROJ"; printf '# mine\n' > "$PE/CLAUDE.md"
  run_apply "$HM" "$PE" --profile python
  assert_eq "existing-md: kept" "# mine" "$(cat "$PE/CLAUDE.md")"
  assert_file "existing-md: .dev_settings.new beside it" "$PE/CLAUDE.md.dev_settings.new"
  run_apply "$HM" "$PE" --profile python --force --yes
  assert_not_contains "existing-md: --force overwrote" "$PE/CLAUDE.md" "# mine"
  assert_eq "existing-md: --force made a backup" True "$( [ -n "$(ls -d "$HM/.claude/backups/dev_settings/apply/existing dir"/* 2>/dev/null)" ] && echo True || echo False)"
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
