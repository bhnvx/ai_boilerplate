#!/usr/bin/env bash
# ai_boilerplate — apply.sh 테스트 2부(경계): CLAUDE.md→AGENTS.md 심볼릭 링크 + --force · AGENTS.md 재적용 멱등성 ·
# 심볼릭 링크 .claude/settings.json · CRLF .gitignore · 포맷 훅 해제 시 훅 파일 정리 · `&`/`$` 가 든 프로젝트명 ·
# 심볼릭 링크 ~/.claude 거부 · 도움말·요약 문구.
. "$(cd -P -- "$(dirname -- "$0")" && pwd -P)/helpers.sh"

PT="claude/project-template"
new_home; HM="$NEW_HOME"
new_proj() { NEW_PROJ="$TROOT/$1 dir"; mkdir -p "$NEW_PROJ"; (cd "$NEW_PROJ" && git init -q 2>/dev/null) || true; }
is_link() { [ -L "$1" ] && echo True || echo False; }
first_line() { head -n 1 -- "$1" 2>/dev/null; }

echo "## (A1) CLAUDE.md → AGENTS.md 심볼릭 링크 + --force: AGENTS.md 는 그대로, CLAUDE.md 는 일반 파일"
if need "symlink: template" "$PT/CLAUDE.md.tmpl"; then
  new_proj symlink; P="$NEW_PROJ"
  printf '# AGENTS\nteam instructions here\n' > "$P/AGENTS.md"; ln -s AGENTS.md "$P/CLAUDE.md"
  run_apply "$HM" "$P" --profile python
  assert_eq "symlink: without --force exit 0" 0 "$RC"
  assert_eq "symlink: link kept without --force" True "$(is_link "$P/CLAUDE.md")"
  assert_contains "symlink: AGENTS.md untouched (no --force)" "$P/AGENTS.md" "team instructions here"
  assert_not_contains "symlink: no misleading import WARN for a link" "$OUT" "import 하지 않는다"
  run_apply "$HM" "$P" --profile python --force --yes
  assert_eq "symlink: --force exit 0" 0 "$RC"
  assert_contains "symlink: notice printed" "$OUT" "심볼릭 링크를 일반 파일로 교체"
  assert_eq "symlink: CLAUDE.md is now a regular file" False "$(is_link "$P/CLAUDE.md")"
  assert_eq "symlink: CLAUDE.md imports AGENTS.md" "@AGENTS.md" "$(first_line "$P/CLAUDE.md")"
  assert_contains "symlink: AGENTS.md content preserved" "$P/AGENTS.md" "team instructions here"
  assert_eq "symlink: AGENTS.md still 2 lines" 2 "$(count_lines "$P/AGENTS.md")"
  BK=""; for d in "$HM/.claude/backups/ai_boilerplate/apply/symlink dir"/*/; do [ -f "${d}CLAUDE.md" ] && BK="${d%/}"; done
  assert_contains "symlink: link target content backed up as CLAUDE.md" "$BK/CLAUDE.md" "team instructions here"
fi

echo "## (A2) AGENTS.md 만 있는 프로젝트: 재적용은 변경 없음(.ai_boilerplate.new 없음), --force 도 @AGENTS.md 유지"
if need "agents idem: template" "$PT/CLAUDE.md.tmpl"; then
  new_proj agents2; PA="$NEW_PROJ"; printf '# agents\n' > "$PA/AGENTS.md"
  run_apply "$HM" "$PA" --profile python; assert_eq "agents idem: first apply exit 0" 0 "$RC"
  run_apply "$HM" "$PA" --profile python; assert_eq "agents idem: second apply exit 0" 0 "$RC"
  assert_matches "agents idem: second run prints 변경 없음 CLAUDE.md" "$OUT" '변경 없음 +CLAUDE\.md$'
  assert_not_contains "agents idem: no WARN 유지" "$OUT" "WARN 유지: CLAUDE.md"
  assert_no_file "agents idem: no .ai_boilerplate.new" "$PA/CLAUDE.md.ai_boilerplate.new"
  assert_contains "agents idem: import notice still printed" "$OUT" "AGENTS.md는 @import로 계속 로드됨"
  run_apply "$HM" "$PA" --profile python --force --yes; assert_eq "agents idem: --force exit 0" 0 "$RC"
  assert_eq "agents idem: --force keeps @AGENTS.md" "@AGENTS.md" "$(first_line "$PA/CLAUDE.md")"
  rm -f "$PA/AGENTS.md"
  run_apply "$HM" "$PA" --profile python; assert_eq "agents idem: AGENTS.md removed → exit 0" 0 "$RC"
  assert_contains "agents idem: import line dropped (unmodified template copy)" "$OUT" "갱신(@AGENTS.md 제거)"
  assert_eq "agents idem: first line is the heading" "# agents2 dir — 작업 가이드" "$(first_line "$PA/CLAUDE.md")"
  printf '# agents\n' > "$PA/AGENTS.md"
  run_apply "$HM" "$PA" --profile python; assert_eq "agents idem: AGENTS.md back → exit 0" 0 "$RC"
  assert_contains "agents idem: import line added back" "$OUT" "갱신(@AGENTS.md 추가)"
  assert_eq "agents idem: first line is @AGENTS.md again" "@AGENTS.md" "$(first_line "$PA/CLAUDE.md")"
  printf '\nuser edit\n' >> "$PA/CLAUDE.md"; rm -f "$PA/AGENTS.md"
  run_apply "$HM" "$PA" --profile python
  assert_contains "agents idem: edited copy is kept, not rewritten" "$OUT" "유지(사용자 편집)"
  assert_eq "agents idem: edited copy keeps its first line" "@AGENTS.md" "$(first_line "$PA/CLAUDE.md")"
fi

echo "## (A3) .claude/settings.json 이 심볼릭 링크 → 링크는 유지하고 대상을 병합한다"
if need "settings link: template" "$PT/dot-claude/settings.json"; then
  new_proj setlink; PS="$NEW_PROJ"; mkdir -p "$PS/.claude" "$PS/shared"
  printf '{"permissions":{"allow":["Bash(x *)"]}}\n' > "$PS/shared/settings.json"
  ln -s ../shared/settings.json "$PS/.claude/settings.json"
  run_apply "$HM" "$PS" --profile python; assert_eq "settings link: exit 0" 0 "$RC"
  assert_eq "settings link: still a symlink" True "$(is_link "$PS/.claude/settings.json")"
  assert_eq "settings link: target merged (\$schema)" True "$(jq_py "$PS/shared/settings.json" '"$schema" in d')"
  assert_eq "settings link: user rule kept in target" True "$(jq_py "$PS/shared/settings.json" '"Bash(x *)" in d["permissions"]["allow"]')"
  assert_contains "settings link: plan shows the link target" "$OUT" "심볼릭 링크 → shared/settings.json"
  run_apply "$HM" "$PS" --profile python
  assert_matches "settings link: rerun 변경 없음" "$OUT" '변경 없음 +\.claude/settings\.json'
fi

echo "## (A4) CRLF .gitignore 에는 CRLF 로 덧붙인다"
if need "crlf: gitignore.claude" "$PT/gitignore.claude"; then
  new_proj crlf; PC="$NEW_PROJ"; printf 'node_modules\r\n*.pyc' > "$PC/.gitignore"   # CRLF, 끝 개행 없음
  run_apply "$HM" "$PC" --profile python; assert_eq "crlf: exit 0" 0 "$RC"
  total=$(count_lines "$PC/.gitignore"); crl=$(grep -c $'\r$' "$PC/.gitignore")
  assert_eq "crlf: every line ends with CR ($total lines)" "$total" "$crl"
  assert_eq "crlf: nothing glued to *.pyc" 0 "$(tr -d '\r' < "$PC/.gitignore" | grep -c '^\*\.pyc.')"
  run_apply "$HM" "$PC" --profile python
  assert_matches "crlf: rerun 변경 없음 .gitignore" "$OUT" '변경 없음 +\.gitignore$'
  assert_eq "crlf: rerun line count stable" "$total" "$(count_lines "$PC/.gitignore")"
fi

echo "## (A5) --with-format-hook 뒤 플래그 없이 적용 → 저장소 사본과 같은 훅 파일은 백업 후 삭제, 수정됐으면 WARN + 커밋 목록 제외"
if need "prune: hook sources" claude/global/hooks/run-hook.sh claude/global/hooks/format-on-edit.sh claude/global/hooks/lib/common.sh "$PT/dot-claude/fragments/format-hook.json"; then
  new_proj prune; PP="$NEW_PROJ"
  run_apply "$HM" "$PP" --profile python --with-format-hook; assert_apply_ok "prune: with-format-hook exit"
  assert_file "prune: hook copied" "$PP/.claude/hooks/format-on-edit.sh"
  run_apply "$HM" "$PP" --profile python --dry-run
  assert_eq "prune: dry-run exit 0" 0 "$RC"
  assert_contains "prune: dry-run lists 삭제(포맷 훅 해제)" "$OUT" "삭제(포맷 훅 해제)"
  assert_file "prune: dry-run removes nothing" "$PP/.claude/hooks/format-on-edit.sh"
  run_apply "$HM" "$PP" --profile python; assert_eq "prune: exit 0" 0 "$RC"
  assert_matches "prune: lists each removed file" "$OUT" '삭제\(포맷 훅 해제\) +\.claude/hooks/lib/common\.sh'
  assert_no_file "prune: format-on-edit.sh removed" "$PP/.claude/hooks/format-on-edit.sh"
  assert_no_file "prune: run-hook.sh removed" "$PP/.claude/hooks/run-hook.sh"
  assert_no_file "prune: lib/common.sh removed" "$PP/.claude/hooks/lib/common.sh"
  assert_no_file "prune: empty hooks dir removed" "$PP/.claude/hooks"
  assert_eq "prune: PostToolUse handler gone" 0 "$(hook_commands "$PP/.claude/settings.json" | grep -c format-on-edit)"
  assert_contains "prune: summary counts 삭제 3" "$OUT" "삭제 3"
  assert_not_contains "prune: commit list has no .claude/hooks" "$OUT" ".claude/hooks/**"
  BKP=""; for d in "$HM/.claude/backups/ai_boilerplate/apply/prune dir"/*/; do [ -f "${d}.claude/hooks/format-on-edit.sh" ] && BKP="${d%/}"; done
  assert_eq "prune: removed hooks were backed up" True "$([ -n "$BKP" ] && echo True || echo False)"
  run_apply "$HM" "$PP" --profile python --with-format-hook; assert_apply_ok "prune(mod): re-enable exit"
  printf '\n# local tweak\n' >> "$PP/.claude/hooks/format-on-edit.sh"
  run_apply "$HM" "$PP" --profile python; assert_eq "prune(mod): exit 0" 0 "$RC"
  assert_contains "prune(mod): WARN 수정된 훅 파일" "$OUT" "수정된 훅 파일"
  assert_file "prune(mod): modified hook kept" "$PP/.claude/hooks/format-on-edit.sh"
  assert_file "prune(mod): sibling hook kept too" "$PP/.claude/hooks/run-hook.sh"
  assert_not_contains "prune(mod): .claude/hooks/** excluded from the commit list" "$OUT" ".claude/hooks/**"
  run_apply "$HM" "$PP" --profile python --with-format-hook
  assert_contains "prune(mod): re-enabling lists .claude/hooks/** again" "$OUT" ".claude/hooks/**"
fi

echo "## (A6) 프로젝트명에 & 와 \$ 가 있어도 제목이 그대로 들어간다(bash 5.2 patsub_replacement 대비)"
if need "amp: template" "$PT/CLAUDE.md.tmpl"; then
  PX="$TROOT/pr & \$Y dir"; mkdir -p "$PX"
  run_apply "$HM" "$PX" --profile python; assert_eq "amp: exit 0" 0 "$RC"
  assert_eq "amp: heading carries the literal name" "# pr & \$Y dir — 작업 가이드" "$(first_line "$PX/CLAUDE.md")"
fi

echo "## (A7) ~/.claude 가 심볼릭 링크일 때 그 실제 디렉터리 아래도 거부한다"
new_home; HL="$NEW_HOME"; mkdir -p "$TROOT/real claude/proj"; ln -s "$TROOT/real claude" "$HL/.claude"
run_apply "$HL" "$TROOT/real claude/proj"
assert_eq "symlinked ~/.claude: refuse real dir → exit 1" 1 "$RC"
assert_contains "symlinked ~/.claude: message" "$OUT" "~/.claude 아래에는 적용하지 않는다"
assert_no_file "symlinked ~/.claude: nothing written" "$TROOT/real claude/proj/CLAUDE.md"

echo "## (A8) 도움말·요약 문구: ECC 겹침 설명, 종료 코드, 팀원용 예시 파일"
/bin/bash "$REPO/apply.sh" --help > "$OUT" 2>&1 < /dev/null; RC=$?
assert_eq "help: exit 0" 0 "$RC"
assert_contains "help: ECC quality-gate only checks by default" "$OUT" "ECC quality-gate 는 기본적으로 검사만"
assert_contains "help: ECC_QUALITY_GATE_FIX mentioned" "$OUT" "ECC_QUALITY_GATE_FIX=true"
assert_not_contains "help: old 'ECC 없는 PC' claim gone" "$OUT" "ECC 플러그인이 없는 PC"
assert_contains "help: exit code 1 says no rollback" "$OUT" "롤백 없음"
assert_contains "help: omitting --profile applies no profile (D01)" "$OUT" "생략하면 언어 프로필 없이"
assert_not_contains "help: no 'default auto' claim (D01)" "$OUT" "기본 auto"
assert_contains "help: lists -h, --help" "$OUT" "-h, --help"
assert_contains "help: synopsis ends with [--help]" "$OUT" "[--yes] [--help]"
assert_contains "help: --profile=<p> form documented" "$OUT" "--profile=<p>"
/bin/bash "$REPO/apply.sh" -h > "$TROOT/help-short.txt" 2>&1 < /dev/null
assert_same "help: -h prints the same help" "$OUT" "$TROOT/help-short.txt"
new_proj eqform; touch "$NEW_PROJ/pyproject.toml"; run_apply "$HM" "$NEW_PROJ" --profile=python --dry-run
assert_eq "help: --profile=python accepted" 0 "$RC"
assert_contains "help: --profile=python selects python" "$OUT" "프로필: python"
new_proj summary; run_apply "$HM" "$NEW_PROJ" --profile python
assert_contains "summary: team example files listed as optional" "$OUT" "선택: 팀원용 예시(커밋 가능)"
assert_contains "summary: example files named" "$OUT" "CLAUDE.local.md.example · .claude/settings.local.json.example"

echo "## (A9) --force 는 확인이 필요한 작업: 비대화형이면 --yes 없이는 exit 2, --yes 면 진행 (D2)"
if need "force-yes: template" "$PT/CLAUDE.md.tmpl"; then
  new_proj forceyes; PF="$NEW_PROJ"; printf '# mine\n' > "$PF/CLAUDE.md"
  run_apply "$HM" "$PF" --profile python --force
  assert_eq "force-yes: non-tty --force without --yes exits 2" 2 "$RC"
  assert_contains "force-yes: message names --yes" "$OUT" "--yes"
  assert_contains "force-yes: CLAUDE.md untouched" "$PF/CLAUDE.md" "# mine"
  run_apply "$HM" "$PF" --profile python --force --dry-run
  assert_eq "force-yes: --dry-run needs no --yes" 0 "$RC"
  run_apply "$HM" "$PF" --profile python --force --yes
  assert_eq "force-yes: --force --yes exits 0" 0 "$RC"
  assert_not_contains "force-yes: CLAUDE.md overwritten" "$PF/CLAUDE.md" "# mine"
fi

t_report "test-apply-edge"
