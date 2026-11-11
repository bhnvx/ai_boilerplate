#!/usr/bin/env bash
# ai_boilerplate — install.sh 테스트 2부: 사용자 편집 보존/--force/--restore, 구버전 훅 제거, 사용자 삭제 규칙,
# 실패 주입 롤백, --uninstall.
. "$(cd -P -- "$(dirname -- "$0")" && pwd -P)/helpers.sh"

G="claude/global"
first_manifest_file() {  # <manifest> <prefix>  → 접두사로 시작하는 첫 파일 키
  jq_py "$1" "next((k for k in d['files'] if k.startswith('$2')), '')"
}

echo "## (6) 손으로 고친 규칙 파일 → 유지 + .ai_boilerplate.new + WARN; --force 덮어쓰기; --restore"
new_home; HA="$NEW_HOME"; CA="$HA/.claude"
run_install "$HA"; assert_install_ok "edit: initial install"
REL=$(first_manifest_file "$CA/ai_boilerplate.manifest.json" "rules/")
if [ -z "$REL" ]; then skip "edit: cases" "설치된 rules/*.md 없음"; else
  SRC="$REPO/$G/$REL"
  printf '\n- 사용자 추가 줄 MARKER-EDIT\n' >> "$CA/$REL"
  run_install "$HA"; assert_install_ok "edit: rerun exit"
  assert_contains "edit: prints 유지" "$OUT" "유지"
  assert_contains "edit: WARN mentions .ai_boilerplate.new" "$OUT" "$REL.ai_boilerplate.new"
  assert_file "edit: .ai_boilerplate.new written" "$CA/$REL.ai_boilerplate.new"
  assert_same "edit: .new equals repo source" "$SRC" "$CA/$REL.ai_boilerplate.new"
  assert_contains "edit: user edit kept" "$CA/$REL" "MARKER-EDIT"
  run_install "$HA"; snapshot "$HA" "$TROOT/ha.1"; run_install "$HA"; snapshot "$HA" "$TROOT/ha.2"
  assert_same "edit: repeated rerun stable (no new backups/.new churn)" "$TROOT/ha.1" "$TROOT/ha.2"
  run_install "$HA" --force --yes; assert_install_ok "force: exit"
  assert_same "force: file overwritten with source" "$SRC" "$CA/$REL"
  assert_no_file "force: .ai_boilerplate.new removed" "$CA/$REL.ai_boilerplate.new"
  BK=$(ls -d "$CA"/backups/ai_boilerplate/[0-9]* 2>/dev/null | tail -1)
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
MF="$CB/ai_boilerplate.manifest.json"
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

echo "## (8b) 사용자가 지운 관리 항목(규칙·훅·statusLine·worktree.baseRef)은 저장소 커밋이 바뀌어 매니페스트를 다시 써도"
echo "##      다시 넣지 않는다. --force 는 다시 넣고 그 기억을 비운다(사용자가 다시 넣어 둔 항목의 기억은 남긴다)."
echo "##      --uninstall 은 설치가 넣은 것만 지운다"
if ! command -v git >/dev/null 2>&1; then skip "deleted-memory" "git 없음"
elif need "deleted-memory: settings" "$G/settings.json"; then
  # 커밋을 바꿀 수 있게 작업 트리를 새 git 저장소로 복사한다(원본 .git 은 건드리지 않는다. 사용자 git 설정·훅도 읽지 않는다).
  RCP="$TROOT/commit repo"; mkdir -p "$RCP"
  (cd "$REPO" && tar cf - --exclude ./.git --exclude ./tests .) | (cd "$RCP" && tar xf -)
  rcp_git() {
    HOME="$TROOT" XDG_CONFIG_HOME="$TROOT" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      git -C "$RCP" -c user.name=tester -c user.email=tester -c commit.gpgsign=false -c core.hooksPath=/dev/null \
        -c init.defaultBranch=main "$@"
  }
  rcp_commit() { rcp_git add -A >/dev/null 2>&1 && rcp_git commit -q --allow-empty -m "$1" >/dev/null 2>&1; }
  rcp_install() {  # <home> [args...]  → OUT, RC
    local home="$1"; shift
    /bin/bash "$RCP/install.sh" --home "$home" "$@" > "$OUT" 2>&1 < /dev/null; RC=$?
  }
  rcp_head() { rcp_git rev-parse HEAD 2>/dev/null; }
  # 사용자가 관리 항목을 지운다: allow 규칙 하나, guard-destructive 훅, statusLine, worktree(→ worktree.baseRef)
  user_delete() {  # <settings.json> <rule>
    python3 -I - "$1" "$2" <<'PY'
import json, sys
p, rule = sys.argv[1:3]
d = json.load(open(p, encoding="utf-8"))
d["permissions"]["allow"] = [r for r in d["permissions"]["allow"] if r != rule]
d.pop("statusLine", None); d.pop("worktree", None)
for g in d["hooks"]["PreToolUse"]:
    g["hooks"] = [h for h in g["hooks"] if "guard-destructive" not in h.get("command", "")]
d["hooks"]["PreToolUse"] = [g for g in d["hooks"]["PreToolUse"] if g["hooks"]]
open(p, "w", encoding="utf-8").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
  }
  absent_all() {  # <settings.json> <rule> → True 면 지운 네 항목이 모두 없음
    python3 -I - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
cmds = [h.get("command", "") for gs in (d.get("hooks") or {}).values() for g in gs for h in g.get("hooks") or []]
print(sys.argv[2] not in d["permissions"]["allow"] and "statusLine" not in d and "worktree" not in d
      and not any("guard-destructive" in c for c in cmds))
PY
  }
  SEED='{\n  "model": "fable",\n  "permissions": {\n    "allow": [\n      "Bash(ls *)"\n    ]\n  }\n}\n'
  if ! { rcp_git init -q && rcp_commit c1; }; then skip "deleted-memory" "저장소 사본에 git 커밋 실패"; else
    new_home; HD="$NEW_HOME"; CD="$HD/.claude"; MD="$CD/ai_boilerplate.manifest.json"; mkdir -p "$CD"
    printf '%b' "$SEED" > "$CD/settings.json"; cp "$CD/settings.json" "$TROOT/dm.seed.json"
    rcp_install "$HD"; assert_install_ok "deleted-memory: install exit"
    DRULE=$(jq_py "$MD" '(d["settings"]["permissions"]["allow"] or [""])[0]')
    user_delete "$CD/settings.json" "$DRULE"
    rcp_commit c2; C2=$(rcp_head)
    rcp_install "$HD"; assert_install_ok "deleted-memory: reinstall (commit changed) exit"
    assert_eq "deleted-memory: manifest rewritten for the new commit" "$C2" "$(jq_py "$MD" 'd["commit"]')"
    assert_eq "deleted-memory: nothing re-added after the rewrite" True "$(absent_all "$CD/settings.json" "$DRULE")"
    assert_eq "deleted-memory: manifest remembers the rule" True "$(jq_py "$MD" "\"$DRULE\" in d['settings']['user_deleted']['permissions']['allow']")"
    assert_eq "deleted-memory: manifest remembers worktree.baseRef and statusLine with values" True \
      "$(jq_py "$MD" 'd["settings"]["user_deleted"]["values"].get("worktree.baseRef") == "head" and "statusline.sh" in d["settings"]["user_deleted"]["values"]["statusLine"]["command"]')"
    assert_eq "deleted-memory: manifest remembers the hook" True "$(jq_py "$MD" 'any("guard-destructive" in h["key"] for h in d["settings"]["user_deleted"]["hooks"])')"
    assert_eq "deleted-memory: remembered rule is not a claim" False "$(jq_py "$MD" "\"$DRULE\" in d['settings']['permissions']['allow']")"
    rcp_install "$HD"; assert_install_ok "deleted-memory: reinstall again exit"
    assert_eq "deleted-memory: still absent on the next run" True "$(absent_all "$CD/settings.json" "$DRULE")"
    assert_contains "deleted-memory: says 유지(사용자 삭제)" "$OUT" "유지(사용자 삭제): $DRULE"
    assert_contains "deleted-memory: says how to restore" "$OUT" "settings: 위 '유지(사용자 삭제)' 항목은 다시 넣지 않는다(--force 로 복원)"
    rcp_commit c3; C3=$(rcp_head)
    rcp_install "$HD"; assert_install_ok "deleted-memory: second rewrite exit"
    assert_eq "deleted-memory: second rewrite for the new commit" "$C3" "$(jq_py "$MD" 'd["commit"]')"
    assert_eq "deleted-memory: still absent after a second rewrite" True "$(absent_all "$CD/settings.json" "$DRULE")"
    rcp_install "$HD" --force --yes; assert_install_ok "deleted-memory: --force exit"
    assert_eq "deleted-memory: --force re-adds the rule" True "$(jq_py "$CD/settings.json" "\"$DRULE\" in d['permissions']['allow']")"
    assert_eq "deleted-memory: --force re-adds worktree.baseRef" head "$(jq_py "$CD/settings.json" 'd["worktree"]["baseRef"]')"
    assert_eq "deleted-memory: --force re-adds statusLine" True "$(jq_py "$CD/settings.json" '"statusline.sh" in d["statusLine"]["command"]')"
    assert_eq "deleted-memory: --force re-adds the hook" 1 "$(hook_commands "$CD/settings.json" | grep -c guard-destructive)"
    assert_eq "deleted-memory: --force clears the memory" False "$(jq_py "$MD" '"user_deleted" in d["settings"]')"
    assert_not_contains "deleted-memory: --force prints no restore hint" "$OUT" "--force 로 복원)"
    assert_eq "deleted-memory: --force claims the rule again" True "$(jq_py "$MD" "\"$DRULE\" in d['settings']['permissions']['allow']")"
    rcp_install "$HD" --uninstall --yes; assert_eq "deleted-memory: uninstall exit 0" 0 "$RC"
    assert_same "deleted-memory: uninstall leaves the user's settings byte-identical" "$TROOT/dm.seed.json" "$CD/settings.json"
    # 기억한 상태(--force 없이)에서 제거해도 깨끗하다. 사용자가 기억된 규칙을 직접 다시 넣으면 사용자의 것(제거해도 남는다).
    new_home; HE="$NEW_HOME"; CE="$HE/.claude"; ME="$CE/ai_boilerplate.manifest.json"; mkdir -p "$CE"
    printf '%b' "$SEED" > "$CE/settings.json"
    rcp_install "$HE"; assert_install_ok "deleted-memory(re-add): install exit"
    user_delete "$CE/settings.json" "$DRULE"
    rcp_commit c4; rcp_install "$HE"; assert_install_ok "deleted-memory(re-add): reinstall exit"
    python3 -I -c 'import json,sys
d = json.load(open(sys.argv[1], encoding="utf-8")); d["permissions"]["allow"].append(sys.argv[2])
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")' "$CE/settings.json" "$DRULE"
    rcp_commit c5; rcp_install "$HE"; assert_install_ok "deleted-memory(re-add): reinstall after re-adding exit"
    assert_eq "deleted-memory(re-add): user's rule kept" True "$(jq_py "$CE/settings.json" "\"$DRULE\" in d['permissions']['allow']")"
    assert_eq "deleted-memory(re-add): not claimed" False "$(jq_py "$ME" "\"$DRULE\" in d['settings']['permissions']['allow']")"
    assert_eq "deleted-memory(re-add): still remembered" True "$(jq_py "$ME" "\"$DRULE\" in d['settings'].get('user_deleted', {}).get('permissions', {}).get('allow', [])")"
    # 사용자가 다시 넣은 규칙을 또 지우면(사본 홈) 계속 지운 것으로 본다
    HE2="$HE again"; cp -R "$HE" "$HE2"
    python3 -I -c 'import json,sys
d = json.load(open(sys.argv[1], encoding="utf-8")); d["permissions"]["allow"].remove(sys.argv[2])
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")' "$HE2/.claude/settings.json" "$DRULE"
    rcp_commit c6; rcp_install "$HE2"; assert_install_ok "deleted-memory(re-add): reinstall after deleting again exit"
    assert_eq "deleted-memory(re-add): deleting it again keeps it out" False "$(jq_py "$HE2/.claude/settings.json" "\"$DRULE\" in d['permissions']['allow']")"
    # 매니페스트를 다시 쓰는 --force(커밋 변경) 뒤에도 사용자가 다시 넣어 둔 규칙의 기억은 남는다 → 또 지워도 다시 넣지 않는다(사본 홈)
    HE3="$HE forced"; cp -R "$HE" "$HE3"
    rcp_commit c7; rcp_install "$HE3" --force --yes; assert_install_ok "deleted-memory(re-add): --force exit"
    assert_eq "deleted-memory(re-add): --force rewrote the manifest" "$(rcp_head)" "$(jq_py "$HE3/.claude/ai_boilerplate.manifest.json" 'd["commit"]')"
    assert_eq "deleted-memory(re-add): --force keeps the memory of the re-added rule" True "$(jq_py "$HE3/.claude/ai_boilerplate.manifest.json" "\"$DRULE\" in d['settings'].get('user_deleted', {}).get('permissions', {}).get('allow', [])")"
    python3 -I -c 'import json,sys
d = json.load(open(sys.argv[1], encoding="utf-8")); d["permissions"]["allow"].remove(sys.argv[2])
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")' "$HE3/.claude/settings.json" "$DRULE"
    rcp_install "$HE3"; assert_install_ok "deleted-memory(re-add): reinstall after --force and deleting again exit"
    assert_eq "deleted-memory(re-add): deleting it again after --force keeps it out" False "$(jq_py "$HE3/.claude/settings.json" "\"$DRULE\" in d['permissions']['allow']")"
    assert_contains "deleted-memory(re-add): says 유지(사용자 삭제) after --force" "$OUT" "유지(사용자 삭제): $DRULE"
    rcp_install "$HE" --uninstall --yes; assert_eq "deleted-memory(re-add): uninstall exit 0" 0 "$RC"
    assert_eq "deleted-memory(re-add): uninstall keeps the user's re-added rule and the user's keys" \
      "{\"model\": \"fable\", \"permissions\": {\"allow\": [\"Bash(ls *)\", \"$DRULE\"]}}" "$(jq_py "$CE/settings.json" 'd')"
  fi
fi

echo "## (8c) 넣을 관리 항목이 모두 사용자 삭제인 컨테이너(hooks·permissions 를 통째로 지움)는 빈 채로 만들지 않는다:"
echo "##      settings.json 을 다시 쓰지 않고 --uninstall 뒤에 빈 껍데기가 남지 않는다"
if need "empty containers: settings" "$G/settings.json"; then
  new_home; HN="$NEW_HOME"; CN="$HN/.claude"; mkdir -p "$CN"
  printf '{\n  "model": "fable"\n}\n' > "$CN/settings.json"; cp "$CN/settings.json" "$TROOT/ec.seed.json"
  run_install "$HN"; assert_install_ok "empty containers: install exit"
  python3 -I -c 'import json,sys
d = json.load(open(sys.argv[1], encoding="utf-8")); d.pop("hooks", None); d.pop("permissions", None)
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")' "$CN/settings.json"
  cp "$CN/settings.json" "$TROOT/ec.cut.json"
  run_install "$HN"; assert_install_ok "empty containers: reinstall exit"
  assert_same "empty containers: settings.json not rewritten (no empty hooks/permissions)" "$TROOT/ec.cut.json" "$CN/settings.json"
  assert_contains "empty containers: says 유지(사용자 삭제) for hooks" "$OUT" "유지(사용자 삭제): hook"
  run_install "$HN" --uninstall --yes; assert_eq "empty containers: uninstall exit 0" 0 "$RC"
  assert_same "empty containers: uninstall leaves the user's settings byte-identical" "$TROOT/ec.seed.json" "$CN/settings.json"
fi

echo "## (8d) 형식이 틀린 매니페스트 settings(손으로 고침·손상): 예외 없이 진행하고 WARN 으로 알린다(설치·--uninstall)"
if need "malformed manifest: settings" "$G/settings.json"; then
  new_home; HQ="$NEW_HOME"; CQ="$HQ/.claude"; MQ="$CQ/ai_boilerplate.manifest.json"
  run_install "$HQ"; assert_install_ok "malformed manifest: install exit"
  python3 -I -c 'import json,sys
m = json.load(open(sys.argv[1], encoding="utf-8")); m["settings"]["user_deleted"] = [1]
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(m, indent=2) + "\n")' "$MQ"
  run_install "$HQ"; assert_install_ok "malformed manifest: reinstall exit"
  assert_contains "malformed manifest: plan warns about settings.user_deleted" "$OUT" "settings: WARN 매니페스트 settings.user_deleted 형식이 잘못돼 무시함"
  python3 -I -c 'import json,sys
m = json.load(open(sys.argv[1], encoding="utf-8")); m["settings"] = []
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(m, indent=2) + "\n")' "$MQ"
  run_install "$HQ" --uninstall --yes; assert_eq "malformed manifest: uninstall exit 0" 0 "$RC"
  assert_contains "malformed manifest: uninstall warns even when settings.json is unchanged" "$OUT" "settings: WARN 매니페스트 settings 형식이 잘못돼 무시함"
fi

echo "## (10) 실패 주입(AI_BOILERPLATE_FAIL_AT=place) → 롤백 후 홈이 그대로"
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
  AI_BOILERPLATE_FAIL_AT=place run_install "$HB"
  assert_eq "rollback: exit 1" 1 "$RC"
  assert_contains "rollback: prints 롤백" "$OUT" "롤백"
  snapshot "$HB" "$TROOT/hb.after"
  assert_same "rollback: home identical to before (files + cksums)" "$TROOT/hb.before" "$TROOT/hb.after"
  assert_eq "rollback: no stage dir left" "" "$(ls -d "$CB"/.ai_boilerplate.stage.* 2>/dev/null)"
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
jq_py "$CC/ai_boilerplate.manifest.json" 'list(d["files"])' > "$TROOT/files.json"
run_install "$HC" --uninstall --yes
assert_eq "uninstall: exit 0" 0 "$RC"
assert_eq "uninstall: all manifest files gone" 0 "$(python3 -I -c 'import json,os,sys
print(sum(1 for f in json.load(open(sys.argv[1])) if os.path.exists(os.path.join(sys.argv[2], f))))' "$TROOT/files.json" "$CC")"
assert_no_file "uninstall: manifest removed" "$CC/ai_boilerplate.manifest.json"
assert_no_file "uninstall: repo file removed" "$CC/ai_boilerplate.repo"
assert_file "uninstall: learned skill untouched" "$CC/skills/learned/k.md"
assert_eq "uninstall: user model kept" fable "$(jq_py "$CC/settings.json" 'd["model"]')"
assert_eq "uninstall: user allow kept" True "$(jq_py "$CC/settings.json" '"Bash(ls *)" in d["permissions"]["allow"]')"
if [ -f "$REPO/$G/settings.json" ]; then
  assert_eq "uninstall: our hooks removed" 0 "$(hook_commands "$CC/settings.json" | grep -c run-hook.sh)"
  assert_eq "uninstall: our deny removed" False "$(jq_py "$CC/settings.json" '"Read(//**/.env)" in (d.get("permissions",{}).get("deny") or [])')"
  assert_eq "uninstall: statusLine/language removed" True "$(jq_py "$CC/settings.json" '"statusLine" not in d and "language" not in d')"
fi
assert_eq "uninstall: backup dir created" True "$( [ -n "$(ls -d "$CC"/backups/ai_boilerplate/[0-9]* 2>/dev/null)" ] && echo True || echo False)"

echo "## (11b) 관리 설정 값(language·statusLine·worktree.baseRef): 일반 설치는 사용자 값 유지, --force 는 저장소 값(백업 후),"
echo "##       --uninstall 은 설치가 넣은 worktree.baseRef 만 제거(사용자의 다른 worktree 키 유지) (D03)"
if need "managed values: settings" "$G/settings.json"; then
  new_home; HV="$NEW_HOME"; CV="$HV/.claude"; mkdir -p "$CV"
  printf '{\n  "language": "english",\n  "worktree": { "baseRef": "fresh", "symlinkDirectories": ["node_modules"] },\n  "statusLine": { "type": "command", "command": "mine.sh" }\n}\n' > "$CV/settings.json"
  run_install "$HV"; assert_install_ok "managed values: plain install exit"
  assert_eq "managed values: plain keeps language" english "$(jq_py "$CV/settings.json" 'd["language"]')"
  assert_eq "managed values: plain keeps statusLine" mine.sh "$(jq_py "$CV/settings.json" 'd["statusLine"]["command"]')"
  assert_eq "managed values: plain keeps worktree.baseRef" fresh "$(jq_py "$CV/settings.json" 'd["worktree"]["baseRef"]')"
  assert_eq "managed values: user's baseRef not claimed" False "$(jq_py "$CV/ai_boilerplate.manifest.json" 'bool(d["settings"].get("worktree.baseRef"))')"
  run_install "$HV" --force --yes; assert_install_ok "managed values: --force exit"
  assert_eq "managed values: --force sets language" korean "$(jq_py "$CV/settings.json" 'd["language"]')"
  assert_eq "managed values: --force sets statusLine" True "$(jq_py "$CV/settings.json" '"statusline.sh" in d["statusLine"]["command"]')"
  assert_eq "managed values: --force sets worktree.baseRef" head "$(jq_py "$CV/settings.json" 'd["worktree"]["baseRef"]')"
  assert_eq "managed values: --force keeps other worktree keys" '["node_modules"]' "$(jq_py "$CV/settings.json" 'd["worktree"]["symlinkDirectories"]')"
  BKV=$(ls -d "$CV"/backups/ai_boilerplate/[0-9]* 2>/dev/null | tail -1)
  assert_eq "managed values: --force backed up the user baseRef" fresh "$(jq_py "$BKV/settings.json" 'd["worktree"]["baseRef"]')"
  new_home; HW="$NEW_HOME"; CW="$HW/.claude"; mkdir -p "$CW"
  printf '{\n  "worktree": { "symlinkDirectories": ["node_modules"] }\n}\n' > "$CW/settings.json"
  run_install "$HW"; assert_install_ok "worktree add: install exit"
  assert_eq "worktree add: baseRef added beside the user key" head "$(jq_py "$CW/settings.json" 'd["worktree"]["baseRef"]')"
  assert_eq "worktree add: manifest claims worktree.baseRef" True "$(jq_py "$CW/ai_boilerplate.manifest.json" 'bool(d["settings"].get("worktree.baseRef"))')"
  run_install "$HW" --uninstall --yes; assert_eq "worktree add: uninstall exit 0" 0 "$RC"
  assert_eq "worktree add: uninstall removes only baseRef" '{"symlinkDirectories": ["node_modules"]}' "$(jq_py "$CW/settings.json" 'd.get("worktree")')"
  new_home; HX="$NEW_HOME"; CX="$HX/.claude"
  run_install "$HX"; assert_install_ok "worktree edit: install exit"
  python3 -I -c 'import json,sys
d = json.load(open(sys.argv[1], encoding="utf-8")); d["worktree"]["baseRef"] = "fresh"
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(d, indent=2) + "\n")' "$CX/settings.json"
  run_install "$HX" --uninstall --yes; assert_eq "worktree edit: uninstall exit 0" 0 "$RC"
  assert_eq "worktree edit: user-changed baseRef kept" '{"baseRef": "fresh"}' "$(jq_py "$CX/settings.json" 'd.get("worktree")')"
  assert_contains "worktree edit: says 유지(사용자 편집)" "$OUT" "유지(사용자 편집): worktree.baseRef"
  # 계획 출력: 일반 설치는 사용자가 고친 값을 유지하며 알리고, --force 는 바꾸는 값을 '유지'라고 하지 않는다
  new_home; HY="$NEW_HOME"; CY="$HY/.claude"
  run_install "$HY"; assert_install_ok "force output: install exit"
  python3 -I -c 'import json,sys
d = json.load(open(sys.argv[1], encoding="utf-8")); d["worktree"]["baseRef"] = "fresh"; d["language"] = "english"
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")' "$CY/settings.json"
  run_install "$HY"; assert_install_ok "force output: plain reinstall exit"
  assert_contains "force output: plain says it keeps worktree.baseRef" "$OUT" "settings: 유지(사용자 편집): worktree.baseRef"
  assert_contains "force output: plain says it keeps language" "$OUT" "settings: 유지(사용자 편집): language"
  run_install "$HY" --force --yes; assert_install_ok "force output: --force exit"
  assert_not_contains "force output: --force does not say 유지 for values it replaces" "$OUT" "유지(사용자 편집)"
  assert_eq "force output: --force replaced the values" "head korean" \
    "$(jq_py "$CY/settings.json" 'd["worktree"]["baseRef"] + " " + d["language"]')"
  # --force 가 사용자 $schema 를 저장소 값으로 바꾸면 우리 값으로 기록한다 → --uninstall 이 저장소 URL 을 남기지 않는다
  new_home; HS="$NEW_HOME"; CS="$HS/.claude"; mkdir -p "$CS"
  printf '{\n  "$schema": "mine",\n  "model": "fable"\n}\n' > "$CS/settings.json"
  run_install "$HS"; assert_install_ok "schema force: install exit"
  assert_eq "schema force: plain keeps the user's \$schema" mine "$(jq_py "$CS/settings.json" 'd["$schema"]')"
  run_install "$HS" --force --yes; assert_install_ok "schema force: --force exit"
  assert_eq "schema force: manifest records the replaced \$schema" True "$(jq_py "$CS/ai_boilerplate.manifest.json" 'd["settings"]["schema"]')"
  run_install "$HS" --uninstall --yes; assert_eq "schema force: uninstall exit 0" 0 "$RC"
  assert_eq "schema force: uninstall leaves only the user's keys" '{"model": "fable"}' "$(jq_py "$CS/settings.json" 'd')"
fi

t_report "test-install-upgrade"
