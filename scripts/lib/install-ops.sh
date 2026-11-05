#!/usr/bin/env bash
# dev_settings — install.sh 부가 동작: --uninstall, --restore, 사후 요약.
# 전제: install-common.sh, install-plan.sh, install-tx.sh 로드.

usage() {
  cat <<'EOF'
사용법: ./install.sh [--dry-run] [--force] [--no-settings] [--home <dir>] [--uninstall] [--restore <timestamp>] [--yes]

  --dry-run        아무것도 쓰지 않고 계획만 출력: 파일별 계획과 settings.json diff.
                   --uninstall/--restore 와 함께 쓰면 제거·복구 계획만 출력한다.
  --force          사용자가 편집한 파일·충돌 파일도 덮어쓰기(백업 후), 사용자가 지운 규칙·파일 복원
  --no-settings    ~/.claude/settings.json 병합 건너뜀
  --home <dir>     $HOME 대신 사용할 홈 디렉터리(테스트용; <dir>/.claude 에 설치). 빈 값은 오류(종료 코드 2).
  --uninstall      매니페스트에 기록된 파일과 관리 설정 항목 제거(사용자 편집은 유지)
  --restore <ts>   backups/dev_settings/<ts>* 백업을 되돌림(요약에 찍힌 이름, 앞부분만, 또는 전체 경로)
  --yes            확인 질문 없이 진행. 비대화형 실행(CI·파이프·Claude Code 의 Bash 도구)에서는 파괴적 작업
                   (--uninstall, --restore, 구버전 파일 삭제, --force 덮어쓰기)에 필수 — 없으면 종료 코드 2.
                   단순 설치(추가·백업만 하는 경우)는 질문 없이 진행한다.

종료 코드: 0 성공(validate OK/WARN) · 1 실패(롤백됨) · 2 사용법 오류 · 3 설치됐지만 validate FAIL
EOF
}

# 파괴적 작업 확인. --yes 면 통과; TTY 면 [y/N] 질문; 비대화형이면 --yes 가 필수(종료 코드 2).
# usage: confirm <prompt> <what>
confirm() {
  [ "$OPT_YES" = 1 ] && return 0
  if [ ! -t 0 ]; then die "확인이 필요한 작업(${2:-$1}) — 비대화형 실행이면 --yes 를 지정" 2; fi
  printf '%s [y/N] ' "$1"
  read -r ans
  case $ans in y|Y|yes|YES) return 0 ;; esac
  return 1
}

print_summary() {
  log "── 요약 ──"
  info "생성 $N_CREATE · 갱신 $N_UPDATE · 유지 $N_KEEP · 삭제 $N_REMOVE · 변경 없음 $N_SAME · 경고 $N_WARN"
  if [ -n "${BK_DIR:-}" ] && [ -d "$BK_DIR" ]; then
    info "백업: $BK_DIR"
    info "되돌리기: ./install.sh --restore ${BK_DIR##*/}${OPT_HOME_ARG:+ --home \"$HOME_DIR\"}"
  fi
}

print_next_steps() {
  log "── 다음 단계 ──"
  info "1. Claude Code 를 재시작한다(설정·훅 재로드)."
  info "2. 아무 프로젝트에서 /harness-check 로 설치 상태를 확인한다."
  info "3. 프로젝트 적용: ./apply.sh <project-dir> --profile auto  또는 프로젝트 안에서 /harness-init"
}

# 매니페스트 기준 제거. 사용자 편집 파일은 유지(WARN). OPT_DRY=1 이면 계획(삭제/갱신 줄과 settings diff)만 출력하고 쓰지 않는다.
op_uninstall() {
  local manifest="$CLAUDE_DIR/dev_settings.manifest.json" i=0 n dest rel d empty_overlay removed=0 real dry="${OPT_DRY:-0}"
  [ -f "$manifest" ] || die "설치 정보가 없다: $manifest (설치되지 않았거나 이미 제거됨)"
  load_manifest "$manifest"
  [ -n "$M_FILE" ] || die "매니페스트를 읽을 수 없다: $manifest"
  BK_PARENT="$CLAUDE_DIR/backups/dev_settings"
  if [ "$dry" = 1 ]; then log "── 제거 계획 ($CLAUDE_DIR) — dry-run: 쓰지 않음 ──"
  else confirm "$CLAUDE_DIR 에서 dev_settings 설치본을 제거할까?" "제거(--uninstall)" || die "취소함" 1; fi
  n=${#M_REL[@]}
  while [ "$i" -lt "$n" ]; do
    rel="${M_REL[$i]}"; dest="$CLAUDE_DIR/$rel"
    if [ -f "$dest" ]; then
      if [ "$(ck_file "$dest")" = "${M_CK[$i]}" ] || [ "$OPT_FORCE" = 1 ]; then
        removed=$((removed + 1)); info "삭제  $rel"
        if [ "$dry" != 1 ]; then
          backup_file "$dest" "$rel" "$BK_PARENT" || die "백업 실패: $rel"
          rm -f -- "$dest"
          d=$(dirname -- "$dest")   # 비게 된 상위 디렉터리만 제거(skills/ 포함 — 다른 스킬이 있으면 rmdir 이 실패해 남는다)
          while [ "$d" != "$CLAUDE_DIR" ] && rmdir -- "$d" 2>/dev/null; do d=$(dirname -- "$d"); done
        fi
      else
        warn "유지: $rel 은 사용자가 편집함 — 직접 삭제"
      fi
    fi
    [ "$dry" = 1 ] || rm -f -- "$dest.dev_settings.new"
    i=$((i + 1))
  done
  real=$(resolve_link "$CLAUDE_DIR/settings.json")
  if [ "$OPT_NO_SETTINGS" != 1 ] && [ -f "$real" ]; then
    if ! json_ok "$real"; then
      warn "settings.json 이 유효한 JSON이 아니다(JSONC 불가) — 관리 항목(훅·deny·statusLine)을 직접 제거: $real"
    else
      if [ "$dry" = 1 ]; then STAGE=$(mktemp -d "${TMPDIR:-/tmp}/dev_settings.dry.XXXXXX") || die "임시 디렉터리 생성 실패"
      else STAGE=$(mktemp -d "$CLAUDE_DIR/.dev_settings.stage.XXXXXX") || die "스테이지 생성 실패"; fi
      empty_overlay="$STAGE/empty.json"; printf '{}\n' > "$empty_overlay"
      if python3 -I "$REPO_DIR/scripts/merge-settings.py" --mode install --base "$real" --overlay "$empty_overlay" \
           --manifest "$manifest" --home "$HOME_DIR" --diff --out "$STAGE/settings.json" 2> "$STAGE/err"; then
        if same_file "$STAGE/settings.json" "$real"; then info "변경 없음  settings.json"
        else
          info "갱신  settings.json (관리 항목 제거)"
          grep -E '^(유지\(|WARN)' "$STAGE/err" | sed 's/^/  settings: /'
          if [ "$dry" = 1 ]; then log "── settings.json diff ──"; grep -vE '^(유지\(|WARN)' "$STAGE/err"
          else
            backup_file "$real" "settings.json" "$BK_PARENT" || die "백업 실패: settings.json"
            atomic_replace "$STAGE/settings.json" "$real" || die "settings.json 쓰기 실패"
          fi
        fi
      else
        cat "$STAGE/err" >&2; warn "settings.json 정리 실패 — 수동으로 확인"
      fi
      tx_cleanup
    fi
  fi
  info "삭제  dev_settings.manifest.json"; info "삭제  dev_settings.repo"
  if [ "$dry" = 1 ]; then log "dry-run 종료 — 아무것도 쓰지 않았다. (삭제 예정 파일 $removed 개)"; return 0; fi
  backup_file "$manifest" "dev_settings.manifest.json" "$BK_PARENT"
  rm -f -- "$manifest" "$CLAUDE_DIR/dev_settings.repo"
  rmdir -- "$CLAUDE_DIR/skills" 2>/dev/null
  log "제거 완료: 파일 $removed 개 삭제. 백업: ${BK_DIR:-없음}"
  return 0
}

# 백업 디렉터리 내용을 되돌린다. 인수: 백업 이름(앞부분만도 가능), 끝 슬래시가 붙은 이름, 전체 경로.
# OPT_DRY=1 이면 복구 계획만 출력한다.
op_restore() {
  local ts="$1" parent="$CLAUDE_DIR/backups/dev_settings" match="" d n=0 rel target re
  ts=${ts%/}; ts=${ts##*/}
  re='^[0-9]{8}(-[0-9]{6}(\.[A-Za-z0-9]+)?)?$'
  [[ $ts =~ $re ]] || die "--restore 값은 백업 이름(YYYYmmdd-HHMMSS.XXXXXX, 앞부분만도 가능)이어야 한다: $1" 2
  for d in "$parent/$ts"*/; do
    [ -d "$d" ] || continue
    n=$((n + 1)); match="${d%/}"
  done
  [ "$n" -ge 1 ] || die "백업을 찾을 수 없다: $parent/$ts*"
  [ "$n" -eq 1 ] || die "여러 백업이 일치한다 — 전체 이름을 지정: $(ls -1 "$parent" | grep "^$ts" | tr '\n' ' ')"
  if [ "${OPT_DRY:-0}" = 1 ]; then log "── 복구 계획 ($match → $CLAUDE_DIR) — dry-run: 쓰지 않음 ──"
  else confirm "$match 의 내용을 $CLAUDE_DIR 로 되돌릴까?" "복구(--restore)" || die "취소함" 1; fi
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    target="$CLAUDE_DIR/$rel"
    [ "$rel" = settings.json ] && target=$(resolve_link "$target")
    info "복구  $rel"
    [ "${OPT_DRY:-0}" = 1 ] && continue
    mkdir -p -- "$(dirname -- "$target")" || die "디렉터리 생성 실패"
    restore_file "$match/$rel" "$target" || die "복구 실패: $rel"
  done <<EOF
$(list_files "$match")
EOF
  if [ "${OPT_DRY:-0}" = 1 ]; then log "dry-run 종료 — 아무것도 쓰지 않았다."; else log "복구 완료: $match"; fi
}
