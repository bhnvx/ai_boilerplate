#!/usr/bin/env bash
# dev_settings — apply.sh 파일 동작 헬퍼. 전제: install-common.sh 로드, TARGET/REPO_DIR/BK_PARENT/OPT_DRY/OPT_FORCE 설정.
# 각 동작은 계획 한 줄을 출력하고(OPT_DRY=1 이면 쓰지 않음) 카운터를 갱신한다.

COMMIT_FILES=(); NOTE_LINES=()

plan_line() { info "$(printf '%-18s' "$1") $2"; }
note() { NOTE_LINES[${#NOTE_LINES[@]}]="$1"; }
track_commit() { COMMIT_FILES[${#COMMIT_FILES[@]}]="$1"; }

# 백업 후 덮어쓰기(기존 파일이 있을 때만 백업).
overwrite_with_backup() {  # <src> <dest> <mode> <rel>
  if [ -f "$2" ]; then backup_file "$2" "$4" "$BK_PARENT" || die "백업 실패: $4"; fi
  place_file "$1" "$2" "$3" || die "복사 실패: $4"
}

# 없으면 생성, 있으면 유지(--force 면 백업 후 덮어쓰기).
apply_once() {  # <src> <rel> <mode>
  local src="$1" rel="$2" mode="$3" dest="$TARGET/$2"
  [ -f "$src" ] || { warn "소스 없음(건너뜀): ${src#"$REPO_DIR"/}"; return 0; }
  if [ ! -e "$dest" ]; then
    plan_line "생성" "$rel"; N_CREATE=$((N_CREATE + 1))
    [ "$OPT_DRY" = 1 ] || place_file "$src" "$dest" "$mode" || die "복사 실패: $rel"
  elif same_file "$src" "$dest"; then
    plan_line "변경 없음" "$rel"; N_SAME=$((N_SAME + 1))
  elif [ "$OPT_FORCE" = 1 ]; then
    plan_line "갱신(--force)" "$rel"; N_UPDATE=$((N_UPDATE + 1))
    [ "$OPT_DRY" = 1 ] || overwrite_with_backup "$src" "$dest" "$mode" "$rel"
  else
    plan_line "유지(기존 파일)" "$rel"; N_KEEP=$((N_KEEP + 1))
  fi
  track_commit "$rel"
}

# 없으면 생성, 같으면 유지, 다르면 .dev_settings.new 를 옆에 둠(--force 면 백업 후 덮어쓰기).
apply_sync() {  # <src> <rel> <mode>
  local src="$1" rel="$2" mode="$3" dest="$TARGET/$2" new
  new="$dest.dev_settings.new"
  [ -f "$src" ] || { warn "소스 없음(건너뜀): ${src#"$REPO_DIR"/}"; return 0; }
  if [ ! -e "$dest" ]; then
    plan_line "생성" "$rel"; N_CREATE=$((N_CREATE + 1))
    [ "$OPT_DRY" = 1 ] || place_file "$src" "$dest" "$mode" || die "복사 실패: $rel"
  elif same_file "$src" "$dest"; then
    plan_line "변경 없음" "$rel"; N_SAME=$((N_SAME + 1))
    [ "$OPT_DRY" = 1 ] || rm -f -- "$new"
  elif [ "$OPT_FORCE" = 1 ]; then
    plan_line "갱신(--force)" "$rel"; N_UPDATE=$((N_UPDATE + 1))
    [ "$OPT_DRY" = 1 ] || { overwrite_with_backup "$src" "$dest" "$mode" "$rel"; rm -f -- "$new"; }
  else
    plan_line "유지(사용자 편집)" "$rel  → $rel.dev_settings.new"; N_KEEP=$((N_KEEP + 1))
    if [ "$OPT_DRY" != 1 ] && ! same_file "$src" "$new"; then cp -- "$src" "$new" || die "복사 실패: $new"; fi
    warn "유지: $rel 이 템플릿과 다름 — $rel.dev_settings.new 와 비교 후 직접 반영"
  fi
}

# 프로젝트 CLAUDE.md 템플릿 렌더링: 1행의 <프로젝트명> 만 치환. 선택적으로 @AGENTS.md 를 앞에 붙인다.
render_claude_md() {  # <tmpl> <out> <project-name> <prepend-agents:0|1>
  local tmpl="$1" out="$2" name="$3" first line
  IFS= read -r first < "$tmpl" || first=""
  # 대입 문맥 + 따옴표 친 치환값: bash 5.2 의 patsub_replacement 가 프로젝트명의 `&` 를 바꾸지 못하게 한다(3.2 에서도 동작).
  line=${first//<프로젝트명>/"$name"}
  {
    [ "$4" = 1 ] && printf '@AGENTS.md\n\n'
    printf '%s\n' "$line"
    tail -n +2 -- "$tmpl"
  } > "$out"
}

# CLAUDE.md 처리. AGENTS.md 가 있으면 모든 렌더링에 @AGENTS.md 를 앞세운다(재적용·--force 에서도 유지 → 멱등).
apply_claude_md() {  # <work-dir>
  local tmpl="$REPO_DIR/claude/project-template/CLAUDE.md.tmpl" rendered="$1/CLAUDE.md" alt="$1/CLAUDE.alt.md" name dest new agents=0 lbl
  [ -f "$tmpl" ] || { warn "소스 없음(건너뜀): claude/project-template/CLAUDE.md.tmpl"; return 0; }
  name=${TARGET##*/}
  [ -f "$TARGET/AGENTS.md" ] && agents=1
  render_claude_md "$tmpl" "$rendered" "$name" "$agents"
  if [ -f "$TARGET/CLAUDE.md" ] || [ -L "$TARGET/CLAUDE.md" ]; then
    render_claude_md "$tmpl" "$alt" "$name" $((1 - agents))
    if ! same_file "$rendered" "$TARGET/CLAUDE.md" && same_file "$alt" "$TARGET/CLAUDE.md"; then
      # 손대지 않은 템플릿 사본인데 AGENTS.md 유무만 달라진 경우: 사용자 편집이 아니므로 @AGENTS.md 줄만 맞춘다(백업 후).
      if [ "$agents" = 1 ]; then lbl="갱신(@AGENTS.md 추가)"; else lbl="갱신(@AGENTS.md 제거)"; fi
      plan_line "$lbl" "CLAUDE.md"; N_UPDATE=$((N_UPDATE + 1))
      [ "$OPT_DRY" = 1 ] || { overwrite_with_backup "$rendered" "$TARGET/CLAUDE.md" 644 "CLAUDE.md"; rm -f -- "$TARGET/CLAUDE.md.dev_settings.new"; }
      track_commit "CLAUDE.md"
    else
      apply_sync "$rendered" "CLAUDE.md" 644
    fi
  elif [ -f "$TARGET/.claude/CLAUDE.md" ]; then
    dest="$TARGET/.claude/CLAUDE.md"; new="$dest.dev_settings.new"
    plan_line "유지(기존 파일)" ".claude/CLAUDE.md  → .claude/CLAUDE.md.dev_settings.new"; N_KEEP=$((N_KEEP + 1))
    if [ "$OPT_DRY" != 1 ] && ! same_file "$rendered" "$dest" && ! same_file "$rendered" "$new"; then
      cp -- "$rendered" "$new" || die "복사 실패: $new"
    fi
    [ "$OPT_FORCE" = 1 ] && warn ".claude/CLAUDE.md 가 있어 --force 로도 CLAUDE.md 를 새로 만들지 않는다"
  else
    apply_once "$rendered" "CLAUDE.md" 644
  fi
  if [ "$agents" = 1 ]; then
    if { [ "$OPT_DRY" = 1 ] && [ ! -e "$TARGET/CLAUDE.md" ]; } || [ "$(head -n 1 -- "$TARGET/CLAUDE.md" 2>/dev/null)" = "@AGENTS.md" ]; then
      log "AGENTS.md는 @import로 계속 로드됨 (CLAUDE.md 첫 줄 @AGENTS.md)"
    elif [ -L "$TARGET/CLAUDE.md" ]; then
      :   # CLAUDE.md 가 AGENTS.md 등으로 가는 링크 — 내용은 사용자의 것이므로 경고하지 않는다
    elif [ -f "$TARGET/CLAUDE.md" ]; then
      warn "AGENTS.md 가 있지만 CLAUDE.md 가 @AGENTS.md 를 import 하지 않는다 — CLAUDE.md 가 있으면 AGENTS.md 는 자동 로드되지 않으므로 필요하면 첫 줄에 @AGENTS.md 를 넣는다"
    fi
  fi
  note "CLAUDE.md 의 TODO 주석을 프로젝트에 맞게 채운다(/harness-init 이 도와준다)"
}

# .claude/settings.json 병합(템플릿 + 프로필 조각 + 포맷 훅 조각).
apply_settings() {  # <work-dir> <with-format-hook:0|1> <profiles...>
  local work="$1" fmt="$2" tpl="$REPO_DIR/claude/project-template/dot-claude" dest="$TARGET/.claude/settings.json" base="NONE" p f real link=""
  shift 2
  [ -f "$tpl/settings.json" ] || { warn "소스 없음(건너뜀): dot-claude/settings.json"; return 0; }
  # 심볼릭 링크(모노레포 공용 설정 등)면 링크가 아니라 대상을 읽고 대상을 교체한다(install.sh 와 같은 정책).
  real=$(resolve_link "$dest")
  if [ -L "$dest" ]; then
    link=$(abs_dir "$(dirname -- "$real")") && link="$link/${real##*/}" || link="$real"
    link="  (심볼릭 링크 → ${link#"$TARGET"/})"
  fi
  local -a args
  args=(--mode apply --base "$base" --overlay "$tpl/settings.json" --home "$HOME" --out "$work/settings.json")
  if [ -f "$real" ]; then
    json_ok "$real" || { warn ".claude/settings.json 이 유효한 JSON이 아니다(JSONC 불가) — 병합 건너뜀"; return 0; }
    args[3]="$real"
  fi
  for p in "$@"; do
    f="$REPO_DIR/profiles/$p/settings.fragment.json"
    if [ -f "$f" ]; then args[${#args[@]}]=--overlay; args[${#args[@]}]="$f"; fi
  done
  if [ "$fmt" = 1 ]; then
    f="$tpl/fragments/format-hook.json"
    if [ -f "$f" ]; then args[${#args[@]}]=--overlay; args[${#args[@]}]="$f"; else warn "소스 없음: fragments/format-hook.json"; fi
  else
    args[${#args[@]}]=--drop-hooks
  fi
  python3 -I "$REPO_DIR/scripts/merge-settings.py" "${args[@]}" 2> "$work/settings.err" || { cat "$work/settings.err" >&2; die "settings.json 병합 실패"; }
  if [ -f "$real" ] && same_file "$work/settings.json" "$real"; then
    plan_line "변경 없음" ".claude/settings.json$link"; N_SAME=$((N_SAME + 1))
  elif [ -f "$real" ]; then
    plan_line "갱신(병합)" ".claude/settings.json$link"; N_UPDATE=$((N_UPDATE + 1))
    if [ "$OPT_DRY" != 1 ]; then
      backup_file "$real" ".claude/settings.json" "$BK_PARENT" || die "백업 실패: .claude/settings.json"
      atomic_replace "$work/settings.json" "$real" || die "쓰기 실패: .claude/settings.json"
    fi
  else
    plan_line "생성" ".claude/settings.json$link"; N_CREATE=$((N_CREATE + 1))
    [ "$OPT_DRY" = 1 ] || atomic_replace "$work/settings.json" "$real" || die "쓰기 실패: .claude/settings.json"
  fi
  track_commit ".claude/settings.json"
  note ".claude/settings.json 의 permissions.allow 목록을 검토한다(프로젝트 명령만 남긴다)"
}

# .gitignore: 끝 개행 보장 후 gitignore.claude 의 빠진 줄만 추가. 기존 파일이 CRLF 면 CRLF 로 덧붙인다.
apply_gitignore() {
  local src="$REPO_DIR/claude/project-template/gitignore.claude" gi="$TARGET/.gitignore" line added=0 missing="" eol=$'\n' cr=$'\r'
  [ -f "$src" ] || { warn "소스 없음(건너뜀): gitignore.claude"; return 0; }
  if [ -f "$gi" ] && grep -q "${cr}\$" -- "$gi" 2>/dev/null; then eol=$'\r\n'; fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%"$cr"}
    [ -n "$line" ] || continue
    if [ -f "$gi" ] && tr -d '\r' < "$gi" | grep -qxF -- "$line"; then continue; fi
    missing="$missing$line$eol"; added=$((added + 1))
  done < "$src"
  if [ "$added" -eq 0 ]; then plan_line "변경 없음" ".gitignore"; N_SAME=$((N_SAME + 1)); return 0; fi
  plan_line "추가 ${added}줄" ".gitignore"; N_UPDATE=$((N_UPDATE + 1))
  [ "$OPT_DRY" = 1 ] && return 0
  if [ -f "$gi" ]; then
    backup_file "$gi" ".gitignore" "$BK_PARENT" || die "백업 실패: .gitignore"
    if [ -s "$gi" ] && [ "$(tail -c 1 -- "$gi" | od -An -c | tr -d ' ')" != '\n' ]; then printf '%s' "$eol" >> "$gi"; fi
  fi
  printf '%s' "$missing" >> "$gi" || die "쓰기 실패: .gitignore"
  track_commit ".gitignore"
}

# --with-format-hook 없이 다시 적용할 때 남은 .claude/hooks/ 정리(settings 의 PostToolUse 등록은 --drop-hooks 가 이미 뗐다).
# 세 파일이 저장소 사본과 같으면 백업 후 삭제; 하나라도 수정됐으면 WARN 만 하고 HOOKS_ORPHAN=1(커밋 목록에서 제외).
apply_prune_hooks() {
  local hdir="$TARGET/.claude/hooks" f modified=0
  HOOKS_ORPHAN=0
  [ -f "$hdir/format-on-edit.sh" ] || return 0
  for f in run-hook.sh format-on-edit.sh lib/common.sh; do
    [ -f "$hdir/$f" ] || continue
    same_file "$REPO_DIR/claude/global/hooks/$f" "$hdir/$f" || modified=1
  done
  if [ "$modified" = 1 ]; then
    HOOKS_ORPHAN=1
    warn "수정된 훅 파일 — .claude/hooks/ 는 더 이상 settings.json 에 등록되지 않는다. 수동 정리(다시 켜려면 --with-format-hook)"
    return 0
  fi
  for f in run-hook.sh format-on-edit.sh lib/common.sh; do
    [ -f "$hdir/$f" ] || continue
    plan_line "삭제(포맷 훅 해제)" ".claude/hooks/$f"; N_REMOVE=$((N_REMOVE + 1))
    [ "$OPT_DRY" = 1 ] && continue
    backup_file "$hdir/$f" ".claude/hooks/$f" "$BK_PARENT" || die "백업 실패: .claude/hooks/$f"
    rm -f -- "$hdir/$f" || die "삭제 실패: .claude/hooks/$f"
  done
  [ "$OPT_DRY" = 1 ] && return 0
  rmdir -- "$hdir/lib" 2>/dev/null; rmdir -- "$hdir" 2>/dev/null
  return 0
}
