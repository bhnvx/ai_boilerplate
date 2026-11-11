#!/usr/bin/env bash
# dev_settings — install.sh 테스트 1부: 신규 설치, 사용자 설정 보존, 멱등성, 외부 스킬 보존, 훅 중복 제거, dry-run.
. "$(cd -P -- "$(dirname -- "$0")" && pwd -P)/helpers.sh"

G="claude/global"
new_home; H1="$NEW_HOME"; C1="$H1/.claude"
# (4) 설치 전 다른 스킬 디렉터리를 심어 둔다(learned/synced 는 Claude Code 소유).
mkdir -p "$C1/skills/learned" "$C1/skills/synced/other"
printf 'learned\n' > "$C1/skills/learned/x.md"; printf '# other\n' > "$C1/skills/synced/other/SKILL.md"
snapshot "$C1/skills/learned" "$TROOT/learned.before"; snapshot "$C1/skills/synced" "$TROOT/synced.before"

echo "## (1) 빈 홈에 설치"
run_install "$H1"
assert_install_ok "install: exit 0"
assert_file "install: manifest written" "$C1/dev_settings.manifest.json"
assert_file "install: repo path written" "$C1/dev_settings.repo"
assert_eq "install: repo path content" "$REPO" "$(cat "$C1/dev_settings.repo" 2>/dev/null)"
assert_eq "install: manifest version 1" 1 "$(jq_py "$C1/dev_settings.manifest.json" 'd["version"]')"
if need "install: CLAUDE.md" "$G/CLAUDE.md.tmpl"; then assert_file "install: CLAUDE.md installed" "$C1/CLAUDE.md"; fi
for f in "$REPO/$G"/rules/*.md; do [ -f "$f" ] && assert_file "install: rules/${f##*/}" "$C1/rules/${f##*/}"; done
for f in "$REPO/$G"/agents/*.md; do [ -f "$f" ] && assert_file "install: agents/${f##*/}" "$C1/agents/${f##*/}"; done
if need "install: hooks" "$G/hooks"; then
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$C1/hooks/$f" ] || { fail "install: hooks/$f installed"; continue; }
    n=$((n + 1))
    case $f in *.sh) assert_exec "install: hooks/$f mode 755" "$C1/hooks/$f" ;; esac
  done <<EOF
$(cd "$REPO/$G/hooks" && find . -type f ! -name .DS_Store | sed 's|^\./||' | sort)
EOF
  [ "$n" -gt 0 ] && pass "install: $n hook files present"
fi
if need "install: skills" "$G/skills"; then
  for d in "$REPO/$G"/skills/*/; do
    d=${d%/}; name=${d##*/}
    assert_file "install: skills/$name/SKILL.md" "$C1/skills/$name/SKILL.md"
    [ -f "$d/context.sh" ] && assert_exec "install: skills/$name/context.sh mode 755" "$C1/skills/$name/context.sh"
  done
fi
if need "install: validate copy" scripts/validate.sh; then
  assert_exec "install: skills/harness-check/validate.sh 755" "$C1/skills/harness-check/validate.sh"
  assert_file "install: schema copy" "$C1/skills/harness-check/claude-code-settings.schema.json"
fi
if need "install: settings" "$G/settings.json"; then
  S="$C1/settings.json"
  assert_file "settings: created" "$S"
  hook_commands "$S" > "$TROOT/cmds.txt"
  for h in guard-secrets guard-destructive guard-migrations; do assert_contains "settings: PreToolUse $h" "$TROOT/cmds.txt" "PreToolUse	\"\$HOME\"/.claude/hooks/run-hook.sh $h"; done
  assert_contains "settings: SessionStart session-context" "$TROOT/cmds.txt" "SessionStart	\"\$HOME\"/.claude/hooks/run-hook.sh session-context"
  assert_contains "settings: Stop stop-verify" "$TROOT/cmds.txt" "Stop	\"\$HOME\"/.claude/hooks/run-hook.sh stop-verify"
  assert_contains "settings: SubagentStop subagent-scope" "$TROOT/cmds.txt" "SubagentStop	\"\$HOME\"/.claude/hooks/run-hook.sh subagent-scope"
  for f in stop-verify.sh subagent-scope.sh lib/transcript.sh; do assert_file "install: hooks/$f" "$C1/hooks/$f"; done
  assert_eq "settings: deny has Read(//**/.env)" True "$(jq_py "$S" '"Read(//**/.env)" in d["permissions"]["deny"]')"
  assert_eq "settings: statusLine command" True "$(jq_py "$S" '"statusline.sh" in d["statusLine"]["command"]')"
  assert_eq "settings: language korean" korean "$(jq_py "$S" 'd["language"]')"
  assert_eq "settings: worktree.baseRef head" head "$(jq_py "$S" 'd["worktree"]["baseRef"]')"
  assert_eq "manifest: settings.hooks recorded" True "$(jq_py "$C1/dev_settings.manifest.json" 'len(d["settings"]["hooks"])>=6')"
  assert_eq "manifest: deny rules recorded" True "$(jq_py "$C1/dev_settings.manifest.json" '"Read(//**/.env)" in d["settings"]["permissions"]["deny"]')"
fi
assert_eq "manifest: files map non-empty" True "$(jq_py "$C1/dev_settings.manifest.json" 'len(d["files"])>0')"
assert_eq "install: no stage dir left" "" "$(ls -d "$C1"/.dev_settings.stage.* 2>/dev/null)"

echo "## (3) 두 번째 실행 → 변경 없음"
snapshot "$H1" "$TROOT/h1.a"
run_install "$H1"
assert_install_ok "rerun: exit 0"
assert_contains "rerun: prints 변경 없음" "$OUT" "변경 없음"
snapshot "$H1" "$TROOT/h1.b"
assert_same "rerun: every cksum under home unchanged" "$TROOT/h1.a" "$TROOT/h1.b"
assert_eq "rerun: no backup dir created" "" "$(ls -d "$C1"/backups/dev_settings/[0-9]* 2>/dev/null)"

echo "## (4) learned/synced 스킬 디렉터리 보존"
snapshot "$C1/skills/learned" "$TROOT/learned.after"; snapshot "$C1/skills/synced" "$TROOT/synced.after"
assert_same "skills/learned untouched" "$TROOT/learned.before" "$TROOT/learned.after"
assert_same "skills/synced untouched" "$TROOT/synced.before" "$TROOT/synced.after"

echo "## (2) 사용자 settings.json 값 보존 + validate --installed"
new_home; H2="$NEW_HOME"; C2="$H2/.claude"; mkdir -p "$C2"
cat > "$C2/settings.json" <<'EOF'
{
  "model": "fable",
  "effortLevel": "xhigh",
  "modelSettings": { "fable": { "effortLevel": "xhigh" } },
  "enabledPlugins": { "ecc@ecc": true, "humanize-korean@im-not-ai": true },
  "extraKnownMarketplaces": { "ecc": { "source": { "source": "github", "repo": "example/ecc" } } },
  "permissions": { "allow": ["Bash(ls *)"] }
}
EOF
cp "$C2/settings.json" "$TROOT/user-settings.json"
run_install "$H2"
assert_install_ok "seeded: exit 0"
for k in model effortLevel modelSettings enabledPlugins extraKnownMarketplaces; do
  assert_eq "seeded: $k byte-identical" "$(jq_py "$TROOT/user-settings.json" "d[\"$k\"]")" "$(jq_py "$C2/settings.json" "d[\"$k\"]")"
done
assert_eq "seeded: user allow rule kept first" "Bash(ls *)" "$(jq_py "$C2/settings.json" 'd["permissions"]["allow"][0]')"
if need "seeded: validate --installed" scripts/validate.sh claude/global/hooks; then
  if /bin/bash "$REPO/scripts/validate.sh" --installed --home "$H2" > "$TROOT/val.txt" 2>&1; then pass "seeded: validate --installed exit 0"
  else fail "seeded: validate --installed exit 0" "$(grep -E '^FAIL' "$TROOT/val.txt" | head -3 | tr '\n' ' ')"; fi
fi

echo "## (5) 같은 매처의 사용자 훅 보존 + 순서만 다른 매처의 우리 명령 중복 제거"
if need "hooks dedupe" "$G/settings.json"; then
  new_home; H5="$NEW_HOME"; C5="$H5/.claude"; mkdir -p "$C5"
  python3 -I - "$REPO/$G/settings.json" "$C5/settings.json" <<'PY'
import json, sys
src = json.load(open(sys.argv[1], encoding="utf-8"))
matcher = None
for g in src["hooks"]["PreToolUse"]:
    if any("guard-secrets" in h.get("command", "") for h in g["hooks"]):
        matcher = "|".join(reversed(g["matcher"].split("|")))
base = {"hooks": {"PreToolUse": [
    {"matcher": "Bash", "hooks": [{"type": "command", "command": "echo user-hook"}]},
    {"matcher": matcher or "Bash", "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/run-hook.sh guard-secrets", "timeout": 5}]},
]}}
json.dump(base, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
PY
  run_install "$H5"
  assert_install_ok "dedupe: exit 0"
  hook_commands "$C5/settings.json" > "$TROOT/cmds5.txt"
  assert_contains "dedupe: user hook kept" "$TROOT/cmds5.txt" "echo user-hook"
  assert_eq "dedupe: guard-secrets exactly once" 1 "$(grep -c 'guard-secrets' "$TROOT/cmds5.txt")"
  assert_eq "dedupe: guard-destructive present" 1 "$(grep -c 'guard-destructive' "$TROOT/cmds5.txt")"
  assert_eq "dedupe: base matcher string kept" True "$(jq_py "$C5/settings.json" 'any(g.get("matcher","").startswith("Bash|") for g in d["hooks"]["PreToolUse"]) if "|" in str([g.get("matcher") for g in d["hooks"]["PreToolUse"]]) else True')"
  assert_eq "dedupe: overlay timeout propagated" True "$(jq_py "$C5/settings.json" 'all(h.get("timeout")!=5 for g in d["hooks"]["PreToolUse"] for h in g["hooks"] if "guard-secrets" in h.get("command",""))')"
fi

echo "## (9) --dry-run 은 아무것도 쓰지 않는다"
new_home; H9="$NEW_HOME"
snapshot "$H9" "$TROOT/h9.a"
run_install "$H9" --dry-run
assert_eq "dry-run(empty home): exit 0" 0 "$RC"
assert_contains "dry-run: plan printed" "$OUT" "계획"
assert_no_file "dry-run(empty home): .claude not created" "$H9/.claude"
snapshot "$H1" "$TROOT/h1.c"
run_install "$H1" --dry-run
snapshot "$H1" "$TROOT/h1.d"
assert_same "dry-run(installed home): cksums identical" "$TROOT/h1.c" "$TROOT/h1.d"

t_report "test-install"
