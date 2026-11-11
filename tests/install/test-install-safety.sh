#!/usr/bin/env bash
# ai_boilerplate — install.sh 테스트 4부(안전성): 읽기 전용 settings.json · 롤백(복구 실패 시 백업 보존, 빈 디렉터리 정리) ·
# 백업 디렉터리 이름 · place_file/atomic_replace 원자성과 심볼릭 링크 · 도움말의 종료 코드 · dotfiles 링크 CLAUDE.md --force.
. "$(cd -P -- "$(dirname -- "$0")" && pwd -P)/helpers.sh"

G="claude/global"
is_writable() { [ -w "$1" ] && echo True || echo False; }
ROOT_USER=0; [ "$(id -u)" = 0 ] && ROOT_USER=1   # root 는 모드 비트를 무시하므로 읽기 전용 검사는 건너뛴다

echo "## (S1) 읽기 전용(0444) settings.json 도 교체되고 모드가 유지된다"
new_home; HR="$NEW_HOME"; CR="$HR/.claude"; mkdir -p "$CR"
printf '{\n  "model": "fable"\n}\n' > "$CR/settings.json"; cp "$CR/settings.json" "$TROOT/ro.seed"; chmod 444 "$CR/settings.json"
run_install "$HR"; assert_install_ok "readonly: install exit"
if [ "$ROOT_USER" = 1 ]; then skip "readonly: mode checks" "root 실행"; else
  assert_eq "readonly: settings.json still read-only" False "$(is_writable "$CR/settings.json")"
fi
assert_eq "readonly: merged (our hooks present)" True "$(hook_commands "$CR/settings.json" | grep -q guard-destructive && echo True || echo False)"
assert_eq "readonly: user key kept" fable "$(jq_py "$CR/settings.json" 'd["model"]')"
# 설정이 바뀐 뒤 실패(매니페스트 단계) → 롤백이 읽기 전용 파일도 되돌린다(cp 실패 시 임시 파일 + mv)
new_home; HR2="$NEW_HOME"; CR2="$HR2/.claude"; mkdir -p "$CR2"
cp "$TROOT/ro.seed" "$CR2/settings.json"; chmod 444 "$CR2/settings.json"
AI_BOILERPLATE_FAIL_AT=manifest run_install "$HR2"
assert_eq "readonly rollback: exit 1" 1 "$RC"
assert_contains "readonly rollback: settings restored" "$OUT" "복구  settings.json"
assert_contains "readonly rollback: complete" "$OUT" "롤백 완료"
assert_same "readonly rollback: settings.json content back to the seed" "$TROOT/ro.seed" "$CR2/settings.json"
[ "$ROOT_USER" = 1 ] || assert_eq "readonly rollback: still read-only" False "$(is_writable "$CR2/settings.json")"
assert_eq "readonly rollback: backup dir removed after a full restore" "" "$(ls -d "$CR2"/backups/ai_boilerplate/[0-9]* 2>/dev/null)"
assert_no_file "readonly rollback: placed files removed" "$CR2/hooks"

echo "## (S2) 롤백 중 복구 실패 → 백업 보존 + --restore 안내 (AI_BOILERPLATE_FAIL_AT=manifest,restore)"
new_home; HF="$NEW_HOME"; CF="$HF/.claude"; mkdir -p "$CF"
printf '{\n  "model": "fable"\n}\n' > "$CF/settings.json"; cp "$CF/settings.json" "$TROOT/rf.seed"
AI_BOILERPLATE_FAIL_AT=manifest,restore run_install "$HF"
assert_eq "restore-fail: exit 1" 1 "$RC"
assert_contains "restore-fail: WARN 복구 실패" "$OUT" "복구 실패: settings.json"
assert_contains "restore-fail: says partial rollback" "$OUT" "롤백 일부 실패"
assert_contains "restore-fail: backup preserved notice" "$OUT" "백업 보존"
assert_contains "restore-fail: prints a --restore hint" "$OUT" "--restore "
assert_no_file "restore-fail: new files still removed" "$CF/hooks"
BKF=$(ls -d "$CF"/backups/ai_boilerplate/[0-9]* 2>/dev/null | tail -1)
assert_eq "restore-fail: backup dir kept with settings.json" True "$( [ -n "$BKF" ] && [ -f "$BKF/settings.json" ] && echo True || echo False)"
if [ -n "$BKF" ]; then
  assert_same "restore-fail: backup holds the original settings" "$TROOT/rf.seed" "$BKF/settings.json"
  run_install "$HF" --restore "${BKF##*/}" --yes
  assert_eq "restore-fail: manual --restore exit 0" 0 "$RC"
  assert_same "restore-fail: manual --restore brings the seed back" "$TROOT/rf.seed" "$CF/settings.json"
fi

echo "## (S3) 빈 홈에서 롤백 → 새로 만든 빈 디렉터리(.claude 포함)도 남기지 않는다"
new_home; HZ="$NEW_HOME"
AI_BOILERPLATE_FAIL_AT=place run_install "$HZ"
assert_eq "fresh rollback(place): exit 1" 1 "$RC"
assert_eq "fresh rollback(place): no directories left" 1 "$(find "$HZ" -type d | grep -c '')"
new_home; HZ2="$NEW_HOME"
AI_BOILERPLATE_FAIL_AT=settings run_install "$HZ2"
assert_eq "fresh rollback(settings): exit 1" 1 "$RC"
assert_eq "fresh rollback(settings): no files left" 0 "$(find "$HZ2" -type f | grep -c '')"
assert_eq "fresh rollback(settings): no directories left (rules/hooks/lib/skills/*)" 1 "$(find "$HZ2" -type d | grep -c '')"

echo "## (S4) 백업 디렉터리 이름: YYYYmmdd-HHMMSS.XXXXXX (6자 접미사, POSIX mkdtemp)"
REL=$(jq_py "$CR/ai_boilerplate.manifest.json" "next((k for k in d['files'] if k.startswith('rules/')), '')")
if [ -z "$REL" ]; then skip "backup name" "rules/*.md 없음"; else
  printf '\n- MARKER\n' >> "$CR/$REL"
  run_install "$HR" --force --yes; assert_install_ok "backup name: --force exit"
  BKN=$(ls -d "$CR"/backups/ai_boilerplate/[0-9]* 2>/dev/null | tail -1); BKN=${BKN##*/}
  re='^[0-9]{8}-[0-9]{6}\.[A-Za-z0-9]{6}$'
  assert_eq "backup name: [$BKN] matches the template" True "$([[ $BKN =~ $re ]] && echo True || echo False)"
fi

echo "## (S5) place_file: 임시 파일 + mv(새 inode) · 심볼릭 링크는 일반 파일로 교체(대상 보존) · atomic_replace 읽기 전용"
U="$TROOT/unit dir"; mkdir -p "$U"
(
  REPO_DIR="$REPO"; . "$REPO/scripts/lib/install-common.sh"
  printf 'new\n' > "$U/src"; printf 'old\n' > "$U/dest"
  ino1=$(ls -i "$U/dest" | awk '{print $1}')
  place_file "$U/src" "$U/dest" 644 || exit 1
  ino2=$(ls -i "$U/dest" | awk '{print $1}')
  [ "$ino1" != "$ino2" ] || exit 2
  [ "$(cat "$U/dest")" = new ] || exit 3
  printf 'team\n' > "$U/target"; ln -s target "$U/link"
  place_file "$U/src" "$U/link" 644 || exit 4
  [ ! -L "$U/link" ] || exit 5
  [ "$(cat "$U/target")" = team ] || exit 6
  [ "$(cat "$U/link")" = new ] || exit 7
  ls -d "$U"/.ai_boilerplate.tmp.* >/dev/null 2>&1 && exit 8
  [ "$ROOT_USER" = 1 ] && exit 0
  printf 'ro\n' > "$U/ro"; chmod 444 "$U/ro"
  atomic_replace "$U/src" "$U/ro" || exit 9
  [ "$(cat "$U/ro")" = new ] || exit 10
  [ ! -w "$U/ro" ] || exit 11
  exit 0
) > "$TROOT/unit.out" 2>&1; URC=$?
assert_eq "unit: place_file/atomic_replace (exit code = failed step)" 0 "$URC"

echo "## (S6) --help: 종료 코드 2(사용법 오류)와 --yes 의 비대화형 규칙, dry-run 범위를 설명한다"
/bin/bash "$REPO/install.sh" --help > "$OUT" 2>&1 < /dev/null; RC=$?
assert_eq "help: exit 0" 0 "$RC"
assert_contains "help: exit code 2 documented" "$OUT" "2 사용법 오류"
assert_contains "help: exit code 1 says rolled back" "$OUT" "1 실패(롤백됨)"
assert_contains "help: --yes required when non-interactive" "$OUT" "비대화형"
assert_contains "help: dry-run covers uninstall/restore" "$OUT" "--uninstall/--restore 와 함께"
assert_contains "help: lists -y (D18)" "$OUT" "--yes, -y"
assert_contains "help: lists --home=<dir> (D18)" "$OUT" "--home=<dir>"
assert_contains "help: lists -h, --help (D18)" "$OUT" "-h, --help"
assert_contains "help: --force names the replaced settings keys (D03)" "$OUT" "language·statusLine·worktree.baseRef"
new_home; HY="$NEW_HOME"
/bin/bash "$REPO/install.sh" --home="$HY" -y --dry-run > "$OUT" 2>&1 < /dev/null; RC=$?
assert_eq "parser: --home=<dir> -y --dry-run exit 0 (D18)" 0 "$RC"
assert_contains "parser: --home=<dir> targets that home" "$OUT" "대상: $(cd -P -- "$HY" && pwd -P)/.claude"

echo "## (S7) ~/.claude/CLAUDE.md 가 dotfiles 를 가리키는 링크 → --force 는 링크를 일반 파일로 바꾸고 대상은 그대로"
if need "dotfiles link: template" "$G/CLAUDE.md.tmpl"; then
  new_home; HD="$NEW_HOME"; CD="$HD/.claude"; mkdir -p "$CD" "$HD/dotfiles"
  printf '# my dotfiles claude md\n' > "$HD/dotfiles/CLAUDE.md"; ln -s ../dotfiles/CLAUDE.md "$CD/CLAUDE.md"
  run_install "$HD"; assert_install_ok "dotfiles link: install without --force exit"
  assert_contains "dotfiles link: conflict kept" "$OUT" "유지(기존 파일 충돌)"
  assert_eq "dotfiles link: still a symlink" True "$([ -L "$CD/CLAUDE.md" ] && echo True || echo False)"
  assert_eq "dotfiles link: dotfiles untouched" "# my dotfiles claude md" "$(cat "$HD/dotfiles/CLAUDE.md")"
  run_install "$HD" --force --yes; assert_install_ok "dotfiles link: --force exit"
  assert_contains "dotfiles link: notice printed" "$OUT" "심볼릭 링크를 일반 파일로 교체"
  assert_eq "dotfiles link: now a regular file" True "$([ -f "$CD/CLAUDE.md" ] && [ ! -L "$CD/CLAUDE.md" ] && echo True || echo False)"
  assert_same "dotfiles link: content is the template" "$REPO/$G/CLAUDE.md.tmpl" "$CD/CLAUDE.md"
  assert_eq "dotfiles link: dotfiles file still untouched" "# my dotfiles claude md" "$(cat "$HD/dotfiles/CLAUDE.md")"
  BKD=""; for d in "$CD"/backups/ai_boilerplate/[0-9]*/; do [ -f "${d}CLAUDE.md" ] && BKD="${d%/}"; done
  assert_eq "dotfiles link: link target content backed up" "# my dotfiles claude md" "$(cat "$BKD/CLAUDE.md" 2>/dev/null)"
  assert_eq "dotfiles link: link text recorded in the backup" ../dotfiles/CLAUDE.md "$(cat "$BKD/CLAUDE.md.ai_boilerplate.link" 2>/dev/null)"
  echo "## (S9) --restore 는 심볼릭 링크였던 파일을 링크로 되돌린다(dry-run 은 계획만)"
  if [ -n "$BKD" ]; then
    run_install "$HD" --restore "${BKD##*/}" --dry-run
    assert_eq "restore link: dry-run exit 0" 0 "$RC"
    assert_contains "restore link: dry-run lists the link" "$OUT" "복구  CLAUDE.md (심볼릭 링크 → ../dotfiles/CLAUDE.md)"
    assert_eq "restore link: dry-run leaves the regular file" True "$([ -f "$CD/CLAUDE.md" ] && [ ! -L "$CD/CLAUDE.md" ] && echo True || echo False)"
    run_install "$HD" --restore "${BKD##*/}" --yes
    assert_eq "restore link: exit 0" 0 "$RC"
    assert_eq "restore link: CLAUDE.md is the same symlink again" ../dotfiles/CLAUDE.md "$(readlink "$CD/CLAUDE.md" 2>/dev/null)"
    assert_eq "restore link: dotfiles untouched" "# my dotfiles claude md" "$(cat "$HD/dotfiles/CLAUDE.md")"
    assert_eq "restore link: no link record copied into ~/.claude" 0 "$(find "$CD" -path "$CD/backups" -prune -o -name '*.ai_boilerplate.link' -print | grep -c '')"
  fi
fi

echo "## (S8) 링크를 --force 로 덮은 뒤 실패 → 롤백이 심볼릭 링크를 되살린다(깨진 링크 포함)"
if need "link rollback: template" "$G/CLAUDE.md.tmpl"; then
  new_home; HL="$NEW_HOME"; CL="$HL/.claude"; mkdir -p "$CL" "$HL/dotfiles"
  printf '# my dotfiles claude md\n' > "$HL/dotfiles/CLAUDE.md"; ln -s ../dotfiles/CLAUDE.md "$CL/CLAUDE.md"
  AI_BOILERPLATE_FAIL_AT=manifest run_install "$HL" --force --yes
  assert_eq "link rollback: exit 1" 1 "$RC"
  assert_contains "link rollback: link restore reported" "$OUT" "복구  CLAUDE.md (심볼릭 링크 → ../dotfiles/CLAUDE.md)"
  assert_contains "link rollback: complete" "$OUT" "롤백 완료"
  assert_eq "link rollback: same symlink again" ../dotfiles/CLAUDE.md "$(readlink "$CL/CLAUDE.md" 2>/dev/null)"
  assert_eq "link rollback: dotfiles untouched" "# my dotfiles claude md" "$(cat "$HL/dotfiles/CLAUDE.md")"
  assert_eq "link rollback: no link record left" 0 "$(find "$HL" -name '*.ai_boilerplate.link' | grep -c '')"
  assert_eq "link rollback: backup dir removed after a full restore" "" "$(ls -d "$CL"/backups/ai_boilerplate/[0-9]* 2>/dev/null)"
  # 실패가 배치 전(설정 단계)에 나도 링크는 그대로다
  AI_BOILERPLATE_FAIL_AT=settings run_install "$HL" --force --yes
  assert_eq "link rollback(settings): exit 1" 1 "$RC"
  assert_eq "link rollback(settings): symlink kept" ../dotfiles/CLAUDE.md "$(readlink "$CL/CLAUDE.md" 2>/dev/null)"
  # 깨진 링크 자리는 '생성'으로 계획된다 → 실패하면 깨진 링크를 그대로 되돌린다
  new_home; HK="$NEW_HOME"; CK="$HK/.claude"; mkdir -p "$CK"; ln -s ../nowhere/CLAUDE.md "$CK/CLAUDE.md"
  AI_BOILERPLATE_FAIL_AT=manifest run_install "$HK"
  assert_eq "broken link rollback: exit 1" 1 "$RC"
  assert_contains "broken link rollback: link restore reported" "$OUT" "복구  CLAUDE.md (심볼릭 링크 → ../nowhere/CLAUDE.md)"
  assert_eq "broken link rollback: broken symlink restored" ../nowhere/CLAUDE.md "$(readlink "$CK/CLAUDE.md" 2>/dev/null)"
fi

echo "## (S3b) 계획 단계에서 중단(병합 실패) → 이번 실행이 만든 빈 ~/.claude 를 남기지 않는다"
BR="$TROOT/broken repo"; mkdir -p "$BR"
(cd "$REPO" && tar cf - --exclude ./.git --exclude ./tests .) | (cd "$BR" && tar xf -)
printf '{ "permissions": \n' > "$BR/$G/settings.json"
new_home; HX="$NEW_HOME"
/bin/bash "$BR/install.sh" --home "$HX" --yes > "$OUT" 2>&1 < /dev/null; RC=$?
assert_eq "plan abort: exit 1" 1 "$RC"
assert_contains "plan abort: merge failure reported" "$OUT" "settings.json 병합 실패"
assert_no_file "plan abort: no ~/.claude left" "$HX/.claude"
new_home; HX2="$NEW_HOME"; mkdir -p "$HX2/.claude"
/bin/bash "$BR/install.sh" --home "$HX2" --yes > "$OUT" 2>&1 < /dev/null; RC=$?
assert_eq "plan abort(existing dir): exit 1" 1 "$RC"
assert_eq "plan abort(existing dir): ~/.claude kept" True "$([ -d "$HX2/.claude" ] && echo True || echo False)"
assert_eq "plan abort(existing dir): no stage dir left" 0 "$(find "$HX2/.claude" -name '.ai_boilerplate.stage.*' | grep -c '')"

t_report "test-install-safety"
