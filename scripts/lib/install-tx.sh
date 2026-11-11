#!/usr/bin/env bash
# ai_boilerplate — install.sh 트랜잭션: 스테이지 → 검증 → 백업 → 배치 → settings → 매니페스트, 실패 시 롤백.
# 전제: install-common.sh, install-plan.sh 로드 후 계획(compute_plan/plan_settings)이 끝난 상태.

STAGE=""; BK_DIR=""; BK_PARENT=""; TX_ACTIVE=0; TX_ROLLED=0; CLAUDE_DIR_NEW=0; BK_PARENT_NEW=0
RB_NEW=()     # 이번 실행에서 새로 만든 파일(롤백 시 삭제)
RB_NEWDIR=()  # 이번 실행에서 새로 만든 디렉터리(롤백 시 비어 있으면 삭제; 깊은 것부터 기록됨)

tx_begin() {  # <dry-run:0|1>
  BK_PARENT="$CLAUDE_DIR/backups/ai_boilerplate"
  if [ "$1" = 1 ]; then
    STAGE=$(mktemp -d "${TMPDIR:-/tmp}/ai_boilerplate.dry.XXXXXX") || die "임시 디렉터리 생성 실패"
  else
    [ -d "$CLAUDE_DIR" ] || CLAUDE_DIR_NEW=1
    mkdir -p -- "$CLAUDE_DIR" || die "디렉터리 생성 실패: $CLAUDE_DIR"
    # 강제 종료 등으로 남은 하루 이상 지난 스테이지 디렉터리를 치운다(동시 실행 중인 다른 설치는 건드리지 않음).
    find "$CLAUDE_DIR" -maxdepth 1 -name '.ai_boilerplate.stage.*' -type d -mtime +0 -prune -exec rm -rf -- {} \; 2>/dev/null
    STAGE=$(mktemp -d "$CLAUDE_DIR/.ai_boilerplate.stage.XXXXXX") || die "스테이지 생성 실패"
  fi
  mkdir -p -- "$STAGE/files"
}

tx_cleanup() { [ -n "$STAGE" ] && [ -d "$STAGE" ] && rm -rf -- "$STAGE"; return 0; }

# <path> 의 아직 없는 상위 디렉터리를 RB_NEWDIR 에 기록한다(롤백 때 빈 디렉터리를 남기지 않기 위해). 항상 0.
tx_note_new_dirs() {
  local d
  d=$(dirname -- "$1")
  while [ ! -d "$d" ] && [ "$d" != "$CLAUDE_DIR" ] && [ "$d" != / ] && [ "$d" != . ]; do
    RB_NEWDIR[${#RB_NEWDIR[@]}]="$d"; d=$(dirname -- "$d")
  done
  return 0
}

# 생성/갱신 대상을 스테이지에 복사하고 트리를 검증한다.
tx_stage() {
  local i=0 n=${#T_SRC[@]} rel
  while [ "$i" -lt "$n" ]; do
    case ${T_ACTION[$i]} in
      create|update)
        rel="${T_REL[$i]}"
        mkdir -p -- "$(dirname -- "$STAGE/files/$rel")" || die "스테이지 복사 실패: $rel"
        cp -- "${T_SRC[$i]}" "$STAGE/files/$rel" || die "스테이지 복사 실패: $rel" ;;
    esac
    i=$((i + 1))
  done
  validate_tree "$STAGE/files" || die "스테이지 검증 실패 — 저장소 파일을 고친 뒤 다시 실행"
  if [ "$SETTINGS_ACTION" != skip ]; then
    json_ok "$STAGE/settings.json" || die "병합된 settings.json 이 유효한 JSON이 아니다"
  fi
}

tx_fail() {
  printf '오류: %s\n' "$*" >&2
  if [ "$TX_ACTIVE" = 1 ] && [ "$TX_ROLLED" = 0 ]; then tx_rollback; fi
  tx_cleanup
  [ "$CLAUDE_DIR_NEW" = 1 ] && rmdir -- "$CLAUDE_DIR" 2>/dev/null
  exit 1
}
tx_on_err() { tx_fail "명령 실패(ERR) — 롤백"; }
tx_on_signal() { tx_fail "중단 신호 수신 — 롤백"; }

# 롤백: 새 파일 삭제 → 백업 복구(실패한 파일은 WARN, 백업 디렉터리 보존) → 새로 만든 빈 디렉터리 제거.
tx_rollback() {
  local f rel target d rb_fail=0
  TX_ROLLED=1
  trap - ERR INT TERM
  log "── 롤백 ──"
  for f in ${RB_NEW[@]+"${RB_NEW[@]}"}; do rm -f -- "$f" && info "삭제  ${f#"$CLAUDE_DIR"/}"; done
  if [ -n "$BK_DIR" ] && [ -d "$BK_DIR" ]; then
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      target="$CLAUDE_DIR/$rel"
      [ "$rel" = settings.json ] && target=$(resolve_link "$target")
      [ -f "$BK_DIR/$rel.ai_boilerplate.link" ] && continue   # 심볼릭 링크였던 파일은 아래에서 링크로 되돌린다
      same_file "$BK_DIR/$rel" "$target" && continue   # 아직 바뀌지 않은 파일은 건드리지 않는다
      mkdir -p -- "$(dirname -- "$target")" 2>/dev/null
      if fail_at restore || ! restore_file "$BK_DIR/$rel" "$target"; then
        rb_fail=1; warn "복구 실패: $rel"
      else info "복구  $rel"; fi
    done <<EOF
$(list_files "$BK_DIR")
EOF
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      target="$CLAUDE_DIR/$rel"
      mkdir -p -- "$(dirname -- "$target")" 2>/dev/null
      if fail_at restore || ! restore_link "$BK_DIR/$rel.ai_boilerplate.link" "$target"; then
        rb_fail=1; warn "복구 실패: $rel (심볼릭 링크)"
      else info "복구  $rel (심볼릭 링크 → $(cat -- "$BK_DIR/$rel.ai_boilerplate.link"))"; fi
    done <<EOF
$(list_links "$BK_DIR")
EOF
    if [ "$rb_fail" = 0 ]; then rm -rf -- "$BK_DIR"; BK_DIR=""; fi
  fi
  # 깊은 디렉터리가 먼저 비워져야 상위가 지워지므로 몇 번 되풀이한다(최대 깊이 skills/<name>, hooks/lib).
  for pass in 1 2 3; do
    for d in ${RB_NEWDIR[@]+"${RB_NEWDIR[@]}"}; do [ -d "$d" ] && rmdir -- "$d" 2>/dev/null; done
  done
  if [ "$BK_PARENT_NEW" = 1 ] && [ -z "$BK_DIR" ]; then rmdir -- "$BK_PARENT" 2>/dev/null; rmdir -- "$CLAUDE_DIR/backups" 2>/dev/null; fi
  if [ "$rb_fail" = 0 ]; then
    log "롤백 완료 — 설치 전 상태로 되돌렸다."
  else
    log "롤백 일부 실패 — 복구되지 않은 파일이 있다(위 WARN). 백업 보존: $BK_DIR"
    info "되돌리기: ./install.sh --restore ${BK_DIR##*/}${OPT_HOME_ARG:+ --home \"$HOME_DIR\"}"
  fi
  return 0
}

# 바뀔 파일만 백업한다(갱신·삭제·settings).
tx_backup() {
  local i=0 n=${#T_SRC[@]} dest real
  while [ "$i" -lt "$n" ]; do
    dest="$CLAUDE_DIR/${T_REL[$i]}"
    case ${T_ACTION[$i]} in
      update) backup_file "$dest" "${T_REL[$i]}" "$BK_PARENT" || tx_fail "백업 실패: ${T_REL[$i]}" ;;
      # 깨진 심볼릭 링크 자리에 새로 놓는 경우: 링크 기록만 남긴다(롤백 때 링크 복원)
      create) if [ -L "$dest" ]; then backup_file "$dest" "${T_REL[$i]}" "$BK_PARENT" || tx_fail "백업 실패: ${T_REL[$i]}"; fi ;;
    esac
    # 바뀌거나 지워질 .ai_boilerplate.new 만 백업(동일하면 그대로 두므로 백업 불필요)
    if [ -f "$dest.ai_boilerplate.new" ]; then
      case ${T_ACTION[$i]} in
        keep-user-edited|conflict) same_file "${T_SRC[$i]}" "$dest.ai_boilerplate.new" && { i=$((i + 1)); continue; } ;;
      esac
      backup_file "$dest.ai_boilerplate.new" "${T_REL[$i]}.ai_boilerplate.new" "$BK_PARENT" || tx_fail "백업 실패"
    fi
    i=$((i + 1))
  done
  i=0; n=${#S_REL[@]}
  while [ "$i" -lt "$n" ]; do
    [ "${S_ACTION[$i]}" = remove-stale ] && { backup_file "$CLAUDE_DIR/${S_REL[$i]}" "${S_REL[$i]}" "$BK_PARENT" || tx_fail "백업 실패: ${S_REL[$i]}"; }
    i=$((i + 1))
  done
  if [ "$SETTINGS_ACTION" = update ]; then
    real=$(resolve_link "$CLAUDE_DIR/settings.json")
    backup_file "$real" "settings.json" "$BK_PARENT" || tx_fail "백업 실패: settings.json"
  fi
}

# 파일 배치: 생성/갱신 복사, 유지 파일은 .ai_boilerplate.new 생성, 구버전 삭제.
tx_place() {
  local i=0 n=${#T_SRC[@]} rel dest new placed=0
  while [ "$i" -lt "$n" ]; do
    rel="${T_REL[$i]}"; dest="$CLAUDE_DIR/$rel"; new="$dest.ai_boilerplate.new"
    case ${T_ACTION[$i]} in
      create|update)
        [ -e "$dest" ] || { RB_NEW[${#RB_NEW[@]}]="$dest"; tx_note_new_dirs "$dest"; }
        place_file "$STAGE/files/$rel" "$dest" "${T_MODE[$i]}" || tx_fail "복사 실패: $rel"
        [ -f "$new" ] && rm -f -- "$new"
        placed=$((placed + 1))
        fail_at place && tx_fail "주입된 실패(AI_BOILERPLATE_FAIL_AT=place)" ;;
      keep-user-edited|conflict)
        if ! same_file "${T_SRC[$i]}" "$new"; then
          [ -e "$new" ] || { RB_NEW[${#RB_NEW[@]}]="$new"; tx_note_new_dirs "$new"; }
          cp -- "${T_SRC[$i]}" "$new" || tx_fail "복사 실패: $new"
        fi
        warn "유지: $rel 은 사용자가 편집함 — 새 버전은 $rel.ai_boilerplate.new 에 둠(비교 후 직접 반영)" ;;
      skip-identical) [ -f "$new" ] && rm -f -- "$new" ;;
    esac
    i=$((i + 1))
  done
  i=0; n=${#S_REL[@]}
  while [ "$i" -lt "$n" ]; do
    case ${S_ACTION[$i]} in
      remove-stale) rm -f -- "$CLAUDE_DIR/${S_REL[$i]}" || tx_fail "삭제 실패: ${S_REL[$i]}"
                    rmdir -- "$(dirname -- "$CLAUDE_DIR/${S_REL[$i]}")" 2>/dev/null || true ;;
      keep-modified-stale) warn "유지: ${S_REL[$i]} 은 저장소에서 사라졌지만 사용자가 편집함 — 직접 정리" ;;
    esac
    i=$((i + 1))
  done
  return 0
}

# settings.json 은 마지막에, 같은 디렉터리의 임시 파일을 통해 원자적으로 교체한다.
tx_settings() {
  local target="$CLAUDE_DIR/settings.json" real
  case $SETTINGS_ACTION in create|update) ;; *) return 0 ;; esac
  real=$(resolve_link "$target")
  if [ -f "$real" ] && [ "$(ck_file "$real")" != "$SETTINGS_BASE_CK" ]; then
    tx_fail "settings.json가 설치 중 변경됨 — 다시 실행"
  fi
  fail_at settings && tx_fail "주입된 실패(AI_BOILERPLATE_FAIL_AT=settings)"
  [ -e "$real" ] || { RB_NEW[${#RB_NEW[@]}]="$real"; tx_note_new_dirs "$real"; }
  atomic_replace "$STAGE/settings.json" "$real" || tx_fail "settings.json 쓰기 실패"
}

# 매니페스트와 저장소 경로 파일을 쓴다. settings 섹션: 이번 병합 결과 또는 이전 매니페스트 유지.
tx_manifest() {
  local list="$STAGE/files.list" i=0 n=${#T_SRC[@]} ssrc="NONE" commit repo_file="$CLAUDE_DIR/ai_boilerplate.repo"
  fail_at manifest && tx_fail "주입된 실패(AI_BOILERPLATE_FAIL_AT=manifest)"
  : > "$list"
  while [ "$i" -lt "$n" ]; do
    printf '%s\t%s\n' "${T_REL[$i]}" "$(ck_file "${T_SRC[$i]}")" >> "$list"
    i=$((i + 1))
  done
  if [ "$SETTINGS_ACTION" != skip ] && [ -f "$STAGE/settings.manifest.json" ]; then ssrc="$STAGE/settings.manifest.json"
  elif [ -n "$M_FILE" ]; then ssrc="PREV:$M_FILE"; fi
  commit=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || printf unknown)
  # 내용(installed_at 제외)이 기존 매니페스트와 같으면 다시 쓰지 않는다(멱등성). 출력: same|changed
  python3 -I - "$STAGE/manifest.json" "$list" "$ssrc" "$REPO_DIR" "$commit" "$(now_iso)" "$CLAUDE_DIR/ai_boilerplate.manifest.json" <<'PY' > "$STAGE/manifest.state" || tx_fail "매니페스트 생성 실패"
import json, os, sys
out, files_list, ssrc, repo, commit, iso, prev = sys.argv[1:8]
files = {}
for line in open(files_list, encoding="utf-8"):
    line = line.rstrip("\n")
    if line:
        rel, ck = line.rsplit("\t", 1)
        files[rel] = int(ck or 0)
settings = {}
if ssrc.startswith("PREV:"):
    settings = json.load(open(ssrc[5:], encoding="utf-8")).get("settings", {})
elif ssrc != "NONE":
    settings = json.load(open(ssrc, encoding="utf-8")).get("settings", {})
m = {"version": 1, "repo": repo, "commit": commit, "installed_at": iso, "mode": "copy",
     "files": files, "settings": settings}
old = None
if os.path.isfile(prev):
    try:
        old = json.load(open(prev, encoding="utf-8"))
    except Exception:
        old = None
strip = lambda d: {k: v for k, v in d.items() if k != "installed_at"}
if isinstance(old, dict) and strip(old) == strip(m):
    print("same")
else:
    open(out, "w", encoding="utf-8").write(json.dumps(m, indent=2, ensure_ascii=False) + "\n")
    print("changed")
PY
  state=$(cat "$STAGE/manifest.state" 2>/dev/null)
  if [ "$state" = changed ]; then
    [ -e "$CLAUDE_DIR/ai_boilerplate.manifest.json" ] || RB_NEW[${#RB_NEW[@]}]="$CLAUDE_DIR/ai_boilerplate.manifest.json"
    [ -f "$CLAUDE_DIR/ai_boilerplate.manifest.json" ] && backup_file "$CLAUDE_DIR/ai_boilerplate.manifest.json" "ai_boilerplate.manifest.json" "$BK_PARENT"
    atomic_replace "$STAGE/manifest.json" "$CLAUDE_DIR/ai_boilerplate.manifest.json" || tx_fail "매니페스트 쓰기 실패"
  fi
  printf '%s\n' "$REPO_DIR" > "$STAGE/repo"
  if ! same_file "$STAGE/repo" "$repo_file"; then
    [ -e "$repo_file" ] || RB_NEW[${#RB_NEW[@]}]="$repo_file"
    atomic_replace "$STAGE/repo" "$repo_file" || tx_fail "ai_boilerplate.repo 쓰기 실패"
  fi
}

# 실제 설치 실행(4~6단계는 트랩 보호).
tx_run() {
  TX_ACTIVE=1
  BK_PARENT_NEW=0; [ -d "$BK_PARENT" ] || BK_PARENT_NEW=1
  set -E
  trap tx_on_err ERR
  trap tx_on_signal INT TERM
  tx_backup
  tx_place
  tx_settings
  tx_manifest
  trap - ERR INT TERM
  set +E
  TX_ACTIVE=0
  prune_backups "$BK_PARENT" 10
}
