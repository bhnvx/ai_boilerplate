#!/usr/bin/env bash
# dev_settings — install.sh 테스트 2부: 사용자 편집 보존/--force/--restore, 구버전 훅 제거, 사용자 삭제 규칙,
# 실패 주입 롤백, --uninstall.
. "$(cd -P -- "$(dirname -- "$0")" && pwd -P)/helpers.sh"

G="claude/global"
first_manifest_file() {  # <manifest> <prefix>  → 접두사로 시작하는 첫 파일 키
  jq_py "$1" "next((k for k in d['files'] if k.startswith('$2')), '')"
}

echo "## (6) 손으로 고친 규칙 파일 → 유지 + .dev_settings.new + WARN; --force 덮어쓰기; --restore"
new_home; HA="$NEW_HOME"; CA="$HA/.claude"
run_install "$HA"; assert_install_ok "edit: initial install"
REL=$(first_manifest_file "$CA/dev_settings.manifest.json" "rules/")
if [ -z "$REL" ]; then skip "edit: cases" "설치된 rules/*.md 없음"; else
  SRC="$REPO/$G/$REL"
  printf '\n- 사용자 추가 줄 MARKER-EDIT\n' >> "$CA/$REL"
  run_install "$HA"; assert_install_ok "edit: rerun exit"
  assert_contains "edit: prints 유지" "$OUT" "유지"
  assert_contains "edit: WARN mentions .dev_settings.new" "$OUT" "$REL.dev_settings.new"
  assert_file "edit: .dev_settings.new written" "$CA/$REL.dev_settings.new"
  assert_same "edit: .new equals repo source" "$SRC" "$CA/$REL.dev_settings.new"
  assert_contains "edit: user edit kept" "$CA/$REL" "MARKER-EDIT"
  run_install "$HA"; snapshot "$HA" "$TROOT/ha.1"; run_install "$HA"; snapshot "$HA" "$TROOT/ha.2"
  assert_same "edit: repeated rerun stable (no new backups/.new churn)" "$TROOT/ha.1" "$TROOT/ha.2"
  run_install "$HA" --force --yes; assert_install_ok "force: exit"
  assert_same "force: file overwritten with source" "$SRC" "$CA/$REL"
  assert_no_file "force: .dev_settings.new removed" "$CA/$REL.dev_settings.new"
  BK=$(ls -d "$CA"/backups/dev_settings/[0-9]* 2>/dev/null | tail -1)
  if [ -n "$BK" ] && [ -f "$BK/$REL" ]; then
    assert_contains "force: backup holds edited version" "$BK/$REL" "MARKER-EDIT"
    assert_contains "force: summary names --restore" "$OUT" "--restore ${BK##*/}"
    run_install "$HA" --restore "${BK##*/}" --yes
    assert_eq "restore: exit 0" 0 "$RC"
    assert_contains "restore: edited version back" "$CA/$REL" "MARKER-EDIT"
  else fail "force: backup dir with $REL exists" "$BK"; fi
fi

echo "## (7) 업그레이드: 매니페스트의 old-hook 파일·설정 항목 제거"
new_home; HB="$NEW_HOME"; CB="$HB/.claude"
run_install "$HB"; assert_install_ok "upgrade: initial install"
MF="$CB/dev_settings.manifest.json"
mkdir -p "$CB/hooks"; printf '#!/usr/bin/env bash\nexit 0\n' > "$CB/hooks/old-hook.sh"; chmod 755 "$CB/hooks/old-hook.sh"
OLDCK=$(cksum < "$CB/hooks/old-hook.sh" | awk '{print $1}')
HAVE_SETTINGS=0; [ -f "$REPO/$G/settings.json" ] && [ -f "$CB/settings.json" ] && HAVE_SETTINGS=1
if [ "$HAVE_SETTINGS" = 1 ]; then
  printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\\"$HOME\\"/.claude/hooks/run-hook.sh old-hook","timeout":10}]}]}}\n' > "$TROOT/ov.json"
  python3 -I "$REPO/scripts/merge-settings.py" --mode install --base "$CB/settings.json" --overlay "$TROOT/ov.json" \
    --home "$HB" --write-manifest "$TROOT/ov.manifest.json" --out "$TROOT/merged.json" 2>/dev/null && cp "$TROOT/merged.json" "$CB/settings.json"
fi
python3 -I - "$MF" "$OLDCK" "$TROOT/ov.manifest.json" "$HAVE_SETTINGS" <<'PY'
import json, sys
mf, ck, ovm, have = sys.argv[1:5]
m = json.load(open(mf, encoding="utf-8"))
m["files"]["hooks/old-hook.sh"] = int(ck)
if have == "1":
    m["settings"]["hooks"].extend(json.load(open(ovm, encoding="utf-8"))["settings"]["hooks"])
open(mf, "w", encoding="utf-8").write(json.dumps(m, indent=2, ensure_ascii=False) + "\n")
PY
[ "$HAVE_SETTINGS" = 1 ] && assert_eq "upgrade: seed has old-hook handler" 1 "$(hook_commands "$CB/settings.json" | grep -c old-hook)"
run_install "$HB" --yes; assert_install_ok "upgrade: reinstall exit"
assert_contains "upgrade: plan shows 삭제(구버전)" "$OUT" "삭제(구버전)"
assert_no_file "upgrade: old-hook.sh removed" "$CB/hooks/old-hook.sh"
assert_eq "upgrade: manifest no longer lists old-hook" False "$(jq_py "$MF" '"hooks/old-hook.sh" in d["files"]')"
if [ "$HAVE_SETTINGS" = 1 ]; then
  assert_eq "upgrade: old-hook handler removed from settings" 0 "$(hook_commands "$CB/settings.json" | grep -c old-hook)"
  assert_eq "upgrade: manifest settings.hooks has no old-hook" 0 "$(jq_py "$MF" 'sum(1 for h in d["settings"]["hooks"] if "old-hook" in h["key"])')"
  assert_eq "upgrade: our guard hooks still present" True "$(hook_commands "$CB/settings.json" | grep -q guard-destructive && echo True || echo False)"
else skip "upgrade: settings assertions" "의존 파일 없음: $G/settings.json"; fi

echo "## (8) 사용자가 지운 allow 규칙은 다시 추가하지 않는다(--force 제외)"
RULE=$(jq_py "$MF" '(d["settings"]["permissions"]["allow"] or [""])[0]')
if [ -z "$RULE" ] || [ "$HAVE_SETTINGS" != 1 ]; then skip "user-deleted rule" "매니페스트에 allow 규칙 없음"; else
  python3 -I - "$CB/settings.json" "$RULE" <<'PY'
import json, sys
p, rule = sys.argv[1:3]
d = json.load(open(p, encoding="utf-8"))
d["permissions"]["allow"] = [r for r in d["permissions"]["allow"] if r != rule]
open(p, "w", encoding="utf-8").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
  run_install "$HB"; assert_install_ok "user-deleted: reinstall exit"
  assert_eq "user-deleted: rule not re-added" False "$(jq_py "$CB/settings.json" "\"$RULE\" in d['permissions']['allow']")"
  assert_contains "user-deleted: prints 유지(사용자 삭제)" "$OUT" "유지(사용자 삭제)"
  run_install "$HB" --force --yes; assert_install_ok "user-deleted: --force exit"
  assert_eq "user-deleted: --force re-adds rule" True "$(jq_py "$CB/settings.json" "\"$RULE\" in d['permissions']['allow']")"
fi

echo "## (10) 실패 주입(DEV_SETTINGS_FAIL_AT=place) → 롤백 후 홈이 그대로"
REL=$(first_manifest_file "$MF" "rules/"); AG=$(first_manifest_file "$MF" "agents/")
if [ -z "$REL" ] || [ -z "$AG" ]; then skip "rollback" "rules/agents 설치본 없음"; else
  printf 'old content\n' > "$CB/$REL"
  OLDCK=$(cksum < "$CB/$REL" | awk '{print $1}')
  python3 -I - "$MF" "$REL" "$OLDCK" <<'PY'
import json, sys
mf, rel, ck = sys.argv[1:4]
m = json.load(open(mf, encoding="utf-8")); m["files"][rel] = int(ck)
open(mf, "w", encoding="utf-8").write(json.dumps(m, indent=2, ensure_ascii=False) + "\n")
PY
  rm -f "$CB/$AG"
  snapshot "$HB" "$TROOT/hb.before"
  DEV_SETTINGS_FAIL_AT=place run_install "$HB"
  assert_eq "rollback: exit 1" 1 "$RC"
  assert_contains "rollback: prints 롤백" "$OUT" "롤백"
  snapshot "$HB" "$TROOT/hb.after"
  assert_same "rollback: home identical to before (files + cksums)" "$TROOT/hb.before" "$TROOT/hb.after"
  assert_eq "rollback: no stage dir left" "" "$(ls -d "$CB"/.dev_settings.stage.* 2>/dev/null)"
  run_install "$HB"; assert_install_ok "rollback: repair install exit"
  assert_same "rollback: repaired file equals source" "$REPO/$G/$REL" "$CB/$REL"
  # (D4) 사용자가 지운 관리 파일은 설정 규칙과 같은 정책: 유지(사용자 삭제), --force 때만 복원
  assert_contains "user-deleted file: prints 유지(사용자 삭제)" "$OUT" "유지(사용자 삭제)  $AG"
  assert_no_file "user-deleted file: not re-created without --force" "$CB/$AG"
  assert_eq "user-deleted file: still listed in manifest" True "$(jq_py "$MF" "\"$AG\" in d['files']")"
  run_install "$HB"; snapshot "$HB" "$TROOT/hb.1"; run_install "$HB"; snapshot "$HB" "$TROOT/hb.2"
  assert_same "user-deleted file: reruns stable" "$TROOT/hb.1" "$TROOT/hb.2"
  run_install "$HB" --force --yes; assert_install_ok "user-deleted file: --force exit"
  assert_file "user-deleted file: --force restores it" "$CB/$AG"
fi

echo "## (11) --uninstall: 파일·관리 설정 제거, 사용자 키 유지"
new_home; HC="$NEW_HOME"; CC="$HC/.claude"; mkdir -p "$CC/skills/learned"
printf '{"model":"fable","effortLevel":"xhigh","permissions":{"allow":["Bash(ls *)"]}}\n' > "$CC/settings.json"
printf 'keep\n' > "$CC/skills/learned/k.md"
run_install "$HC"; assert_install_ok "uninstall: initial install"
jq_py "$CC/dev_settings.manifest.json" 'list(d["files"])' > "$TROOT/files.json"
run_install "$HC" --uninstall --yes
assert_eq "uninstall: exit 0" 0 "$RC"
assert_eq "uninstall: all manifest files gone" 0 "$(python3 -I -c 'import json,os,sys
print(sum(1 for f in json.load(open(sys.argv[1])) if os.path.exists(os.path.join(sys.argv[2], f))))' "$TROOT/files.json" "$CC")"
assert_no_file "uninstall: manifest removed" "$CC/dev_settings.manifest.json"
assert_no_file "uninstall: repo file removed" "$CC/dev_settings.repo"
assert_file "uninstall: learned skill untouched" "$CC/skills/learned/k.md"
assert_eq "uninstall: user model kept" fable "$(jq_py "$CC/settings.json" 'd["model"]')"
assert_eq "uninstall: user allow kept" True "$(jq_py "$CC/settings.json" '"Bash(ls *)" in d["permissions"]["allow"]')"
if [ -f "$REPO/$G/settings.json" ]; then
  assert_eq "uninstall: our hooks removed" 0 "$(hook_commands "$CC/settings.json" | grep -c run-hook.sh)"
  assert_eq "uninstall: our deny removed" False "$(jq_py "$CC/settings.json" '"Read(//**/.env)" in (d.get("permissions",{}).get("deny") or [])')"
  assert_eq "uninstall: statusLine/language removed" True "$(jq_py "$CC/settings.json" '"statusLine" not in d and "language" not in d')"
fi
assert_eq "uninstall: backup dir created" True "$( [ -n "$(ls -d "$CC"/backups/dev_settings/[0-9]* 2>/dev/null)" ] && echo True || echo False)"

t_report "test-install-upgrade"
