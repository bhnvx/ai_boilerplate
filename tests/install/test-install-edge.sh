#!/usr/bin/env bash
# dev_settings — install.sh 테스트 3부(경계): --home '' · 비대화형 확인(--yes 필수) · --uninstall/--restore --dry-run ·
# --restore 인수 정규화 · JSONC/비객체 settings.json 은 파일 배치 전 중단 · 스테이지 정리 · --uninstall 잔재 없음 ·
# 저장소를 가리키는 심볼릭 링크 ~/.claude 거부 · 저장소 훅 문법 오류.
. "$(cd -P -- "$(dirname -- "$0")" && pwd -P)/helpers.sh"

G="claude/global"
stage_dirs() { ls -d "$1"/.dev_settings.stage.* 2>/dev/null; }

echo "## (E1) --home '' 은 실제 HOME 으로 대체하지 않고 종료 코드 2"
new_home; HE="$NEW_HOME"
HOME="$HE" /bin/bash "$REPO/install.sh" --home "" --dry-run > "$OUT" 2>&1 < /dev/null; RC=$?
assert_eq "empty --home: exit 2" 2 "$RC"
assert_contains "empty --home: message" "$OUT" "--home 값이 비어 있다"
HOME="$HE" /bin/bash "$REPO/install.sh" --home= > "$OUT" 2>&1 < /dev/null; RC=$?
assert_eq "empty --home=: exit 2" 2 "$RC"
assert_no_file "empty --home: nothing written to HOME" "$HE/.claude"

echo "## (E2) 비대화형(stdin 이 TTY 아님)에서 파괴적 작업은 --yes 가 필수(종료 코드 2), 단순 설치는 질문 없음"
new_home; HA="$NEW_HOME"; CA="$HA/.claude"
run_install "$HA"; assert_install_ok "confirm: plain install needs no --yes"
MF="$CA/dev_settings.manifest.json"
run_install "$HA" --uninstall
assert_eq "confirm: uninstall without --yes → exit 2" 2 "$RC"
assert_contains "confirm: names the action" "$OUT" "확인이 필요한 작업(제거(--uninstall))"
assert_contains "confirm: tells to pass --yes" "$OUT" "--yes 를 지정"
assert_file "confirm: nothing removed" "$MF"
# 구버전 파일 삭제가 계획에 들어가면 설치도 확인이 필요하다
mkdir -p "$CA/hooks"; printf '#!/usr/bin/env bash\nexit 0\n' > "$CA/hooks/old-hook.sh"
python3 -I - "$MF" "$(cksum < "$CA/hooks/old-hook.sh" | awk '{print $1}')" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8")); m["files"]["hooks/old-hook.sh"] = int(sys.argv[2])
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(m, indent=2, ensure_ascii=False) + "\n")
PY
run_install "$HA"
assert_eq "confirm: stale removal without --yes → exit 2" 2 "$RC"
assert_contains "confirm: stale removal names the action" "$OUT" "확인이 필요한 작업(구버전 파일 삭제)"
assert_file "confirm: stale file untouched" "$CA/hooks/old-hook.sh"
assert_eq "confirm: no stage dir left after exit 2" "" "$(stage_dirs "$CA")"
run_install "$HA" --yes; assert_install_ok "confirm: --yes proceeds"
assert_no_file "confirm: stale file removed with --yes" "$CA/hooks/old-hook.sh"
REL=$(jq_py "$MF" "next((k for k in d['files'] if k.startswith('rules/')), '')")
if [ -z "$REL" ]; then skip "confirm: --force cases" "rules/*.md 없음"; else
  printf '\n- MARKER\n' >> "$CA/$REL"
  run_install "$HA" --force
  assert_eq "confirm: --force overwrite without --yes → exit 2" 2 "$RC"
  assert_contains "confirm: --force names the action" "$OUT" "확인이 필요한 작업(--force 덮어쓰기)"
  assert_contains "confirm: edited file untouched" "$CA/$REL" "MARKER"
  run_install "$HA" --force --yes; assert_install_ok "confirm: --force --yes proceeds"
  assert_same "confirm: --force --yes overwrote" "$REPO/$G/$REL" "$CA/$REL"
fi

echo "## (E3) --uninstall --dry-run / --restore --dry-run 은 계획만 출력하고 아무것도 쓰지 않는다"
snapshot "$HA" "$TROOT/ha.u1"
run_install "$HA" --uninstall --dry-run
assert_eq "uninstall dry-run: exit 0" 0 "$RC"
assert_contains "uninstall dry-run: lists 삭제" "$OUT" "삭제  CLAUDE.md"
assert_contains "uninstall dry-run: settings plan line" "$OUT" "settings.json (관리 항목 제거)"
assert_contains "uninstall dry-run: settings diff shown" "$OUT" "settings.json diff"
assert_contains "uninstall dry-run: says dry-run" "$OUT" "dry-run 종료"
snapshot "$HA" "$TROOT/ha.u2"
assert_same "uninstall dry-run: every cksum under home identical" "$TROOT/ha.u1" "$TROOT/ha.u2"
assert_file "uninstall dry-run: manifest still there" "$MF"
assert_eq "uninstall dry-run: no stage dir" "" "$(stage_dirs "$CA")"
BK=""; for d in "$CA"/backups/dev_settings/[0-9]*/; do [ -n "$REL" ] && [ -f "$d$REL" ] && BK="${d%/}"; done
if [ -z "$BK" ]; then skip "restore dry-run" "rules 파일이 든 백업 없음"; else
  snapshot "$HA" "$TROOT/ha.r1"
  run_install "$HA" --restore "${BK##*/}" --dry-run
  assert_eq "restore dry-run: exit 0" 0 "$RC"
  assert_contains "restore dry-run: lists 복구" "$OUT" "복구  $REL"
  assert_contains "restore dry-run: says dry-run" "$OUT" "dry-run 종료"
  snapshot "$HA" "$TROOT/ha.r2"
  assert_same "restore dry-run: home identical" "$TROOT/ha.r1" "$TROOT/ha.r2"
  assert_not_contains "restore dry-run: nothing restored" "$CA/$REL" "MARKER"

  echo "## (E4) --restore 인수: 끝 슬래시·전체 경로 허용, 잘못된 값은 종료 코드 2"
  run_install "$HA" --restore "${BK##*/}/" --yes
  assert_eq "restore slash: exit 0" 0 "$RC"
  assert_contains "restore slash: edited version back in place" "$CA/$REL" "MARKER"
  assert_no_file "restore slash: no misplaced file at ~/.claude root" "$CA/${REL##*/}"
  run_install "$HA" --restore "$BK" --yes
  assert_eq "restore full path: exit 0" 0 "$RC"
  run_install "$HA" --restore "../etc" --yes
  assert_eq "restore invalid name: exit 2" 2 "$RC"
  run_install "$HA" --restore "20990101-000000.ZZZZZZ" --yes
  assert_eq "restore missing backup: exit 1" 1 "$RC"
  run_install "$HA" --restore "${BK##*/}"
  assert_eq "restore without --yes (non-interactive): exit 2" 2 "$RC"
fi

echo "## (E5) 유효하지 않은 settings.json(JSONC) → 파일을 하나도 놓기 전에 종료 코드 1, 스테이지 없음"
new_home; HJ="$NEW_HOME"; CJ="$HJ/.claude"; mkdir -p "$CJ"
printf '{\n // comment\n "model": "fable"\n}\n' > "$CJ/settings.json"; cp "$CJ/settings.json" "$TROOT/jsonc.json"
run_install "$HJ"
assert_eq "jsonc: exit 1" 1 "$RC"
assert_contains "jsonc: line/col from the merge tool" "$OUT" "line 2 col"
assert_contains "jsonc: hint mentions --no-settings" "$OUT" "--no-settings"
assert_no_file "jsonc: no hooks placed" "$CJ/hooks"
assert_no_file "jsonc: no manifest" "$CJ/dev_settings.manifest.json"
assert_same "jsonc: settings.json untouched" "$TROOT/jsonc.json" "$CJ/settings.json"
assert_eq "jsonc: no stage dir left" "" "$(stage_dirs "$CJ")"
run_install "$HJ" --no-settings
assert_eq "jsonc: --no-settings installs the files (exit 0 or 3)" True "$( { [ "$RC" = 0 ] || [ "$RC" = 3 ]; } && echo True || echo False)"
assert_file "jsonc: --no-settings wrote the manifest" "$CJ/dev_settings.manifest.json"
assert_same "jsonc: --no-settings leaves settings.json alone" "$TROOT/jsonc.json" "$CJ/settings.json"

echo "## (E6) 최상위가 객체가 아닌 settings.json → 종료 코드 1, 스테이지 정리"
new_home; HN="$NEW_HOME"; CN="$HN/.claude"; mkdir -p "$CN"; printf '[]\n' > "$CN/settings.json"
run_install "$HN"
assert_eq "non-object settings: exit 1" 1 "$RC"
assert_contains "non-object settings: message" "$OUT" "최상위가 JSON 객체가 아니다"
assert_eq "non-object settings: no stage dir left" "" "$(stage_dirs "$CN")"
assert_no_file "non-object settings: nothing placed" "$CN/hooks"

echo "## (E7) --uninstall 잔재 없음: \$schema 미추가, 빈 skills/ 제거, settings.json 원복"
new_home; HU="$NEW_HOME"; CU="$HU/.claude"; mkdir -p "$CU"
printf '{\n  "model": "fable",\n  "permissions": {\n    "allow": [\n      "Bash(ls *)"\n    ]\n  }\n}\n' > "$CU/settings.json"
cp "$CU/settings.json" "$TROOT/seed.json"
run_install "$HU"; assert_install_ok "residue: install"
assert_eq "residue: manifest claims \$schema" True "$(jq_py "$CU/dev_settings.manifest.json" 'd["settings"].get("schema", False)')"
run_install "$HU" --uninstall --yes
assert_eq "residue: uninstall exit 0" 0 "$RC"
assert_same "residue: settings.json byte-identical to the seed" "$TROOT/seed.json" "$CU/settings.json"
assert_eq "residue: no \$schema" False "$(jq_py "$CU/settings.json" '"$schema" in d')"
assert_no_file "residue: empty skills/ removed" "$CU/skills"
assert_no_file "residue: no hooks dir" "$CU/hooks"
assert_eq "residue: only settings.json and backups remain" "settings.json" "$(ls -A "$CU" | grep -v '^backups$' | tr '\n' ' ' | sed 's/ $//')"

echo "## (E8) ~/.claude 가 저장소(사본)를 가리키는 심볼릭 링크 → 거부, 저장소 오염 없음"
RC_DIR="$TROOT/repo copy"; cp -R "$REPO" "$RC_DIR" 2>/dev/null
if [ ! -f "$RC_DIR/install.sh" ]; then skip "repo copy cases" "cp -R 실패"; else
  new_home; HL="$NEW_HOME"; ln -s "$RC_DIR/claude/global" "$HL/.claude"
  snapshot "$RC_DIR/claude/global" "$TROOT/rc.before"
  /bin/bash "$RC_DIR/install.sh" --home "$HL" --yes > "$OUT" 2>&1 < /dev/null; RC=$?
  assert_eq "symlinked ~/.claude → repo: exit 1" 1 "$RC"
  assert_contains "symlinked ~/.claude: message" "$OUT" "저장소 안에 있다"
  snapshot "$RC_DIR/claude/global" "$TROOT/rc.after"
  assert_same "symlinked ~/.claude: repo copy untouched" "$TROOT/rc.before" "$TROOT/rc.after"
  assert_no_file "symlinked ~/.claude: no CLAUDE.md written into the repo" "$RC_DIR/claude/global/CLAUDE.md"

  echo "## (E9) 저장소 훅에 문법 오류 → 스테이지 검증 실패(종료 코드 1), 스테이지 정리, 파일 미배치"
  printf '\nif [ ; then\n' >> "$RC_DIR/claude/global/hooks/statusline.sh"
  new_home; HS="$NEW_HOME"
  /bin/bash "$RC_DIR/install.sh" --home "$HS" --yes > "$OUT" 2>&1 < /dev/null; RC=$?
  assert_eq "broken hook: exit 1" 1 "$RC"
  assert_contains "broken hook: WARN 문법 오류" "$OUT" "문법 오류: hooks/statusline.sh"
  assert_contains "broken hook: stage validation failed" "$OUT" "스테이지 검증 실패"
  assert_eq "broken hook: no stage dir left" "" "$(stage_dirs "$HS/.claude")"
  assert_no_file "broken hook: nothing placed" "$HS/.claude/hooks"
  assert_no_file "broken hook: no manifest" "$HS/.claude/dev_settings.manifest.json"
fi

t_report "test-install-edge"
