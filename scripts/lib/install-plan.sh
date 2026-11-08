#!/usr/bin/env bash
# dev_settings — install.sh 계획 단계: 대상 열거, 이전 매니페스트 로드, 파일별 동작 계산.
# 전제: REPO_DIR, CLAUDE_DIR, OPT_FORCE, OPT_NO_SETTINGS, STAGE, HOME_DIR 설정, install-common.sh 로드.

T_SRC=(); T_REL=(); T_MODE=(); T_ACTION=()      # 대상 파일(소스 절대 경로 / CLAUDE_DIR 상대 경로 / 모드 / 동작)
M_REL=(); M_CK=(); M_COMMIT=""; M_FILE=""        # 이전 매니페스트
S_REL=(); S_ACTION=()                            # 매니페스트에만 있는(구버전) 파일
SETTINGS_ACTION="skip"; SETTINGS_BASE_CK=""; SETTINGS_DIFF=""

add_target() {  # <src-abs> <rel> <mode>
  [ -f "$1" ] || return 0
  case ${1##*/} in .DS_Store|*.dev_settings.new|.gitkeep) return 0 ;; esac
  T_SRC[${#T_SRC[@]}]="$1"; T_REL[${#T_REL[@]}]="$2"; T_MODE[${#T_MODE[@]}]="$3"
}

mode_for() { case $1 in *.sh|*.bash) printf 755 ;; *) printf 644 ;; esac; }

add_tree() {  # <src-dir> <dest-prefix>  (하위 파일 전부)
  local dir="$1" prefix="$2" f
  [ -d "$dir" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    add_target "$dir/$f" "$prefix$f" "$(mode_for "$f")"
  done <<EOF
$(list_files "$dir")
EOF
}

plan_targets() {
  local g="$REPO_DIR/claude/global" f d name
  if [ -f "$g/CLAUDE.md.tmpl" ]; then add_target "$g/CLAUDE.md.tmpl" "CLAUDE.md" 644
  else warn "소스 없음(건너뜀): claude/global/CLAUDE.md.tmpl"; fi
  for d in rules agents; do
    if [ -d "$g/$d" ]; then
      for f in "$g/$d"/*.md; do [ -f "$f" ] && add_target "$f" "$d/${f##*/}" 644; done
    else warn "소스 없음(건너뜀): claude/global/$d/"; fi
  done
  if [ -d "$g/hooks" ]; then add_tree "$g/hooks" "hooks/"; else warn "소스 없음(건너뜀): claude/global/hooks/"; fi
  if [ -d "$g/skills" ]; then
    for d in "$g/skills"/*/; do
      [ -d "$d" ] || continue
      d=${d%/}; name=${d##*/}
      add_tree "$d" "skills/$name/"
    done
  else warn "소스 없음(건너뜀): claude/global/skills/"; fi
  if [ -f "$REPO_DIR/scripts/validate.sh" ]; then
    add_target "$REPO_DIR/scripts/validate.sh" "skills/harness-check/validate.sh" 755
  else warn "소스 없음(건너뜀): scripts/validate.sh"; fi
  if [ -f "$REPO_DIR/schemas/claude-code-settings.schema.json" ]; then
    add_target "$REPO_DIR/schemas/claude-code-settings.schema.json" "skills/harness-check/claude-code-settings.schema.json" 644
  else warn "소스 없음(건너뜀): schemas/claude-code-settings.schema.json"; fi
}

# 이전 매니페스트 로드(없거나 깨지면 빈 상태).
load_manifest() {
  local file="$1" line rel ck
  M_FILE=""
  [ -f "$file" ] || return 0
  if ! json_ok "$file"; then warn "이전 매니페스트가 손상됨 — 무시: $file"; return 0; fi
  M_FILE="$file"
  M_COMMIT=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("commit",""))' "$file" 2>/dev/null)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rel=${line%	*}; ck=${line##*	}
    M_REL[${#M_REL[@]}]="$rel"; M_CK[${#M_CK[@]}]="$ck"
  done <<EOF
$(python3 -I -c 'import json,sys
m=json.load(open(sys.argv[1],encoding="utf-8"))
for k,v in (m.get("files") or {}).items(): print("%s\t%s" % (k, v))' "$file" 2>/dev/null)
EOF
}

manifest_ck() {  # <rel> → cksum 또는 빈 문자열
  local i=0 n=${#M_REL[@]}
  while [ "$i" -lt "$n" ]; do
    if [ "${M_REL[$i]}" = "$1" ]; then printf '%s' "${M_CK[$i]}"; return 0; fi
    i=$((i + 1))
  done
  printf ''
}

target_has() {  # <rel> 이 대상 목록에 있으면 0
  local i=0 n=${#T_REL[@]}
  while [ "$i" -lt "$n" ]; do
    [ "${T_REL[$i]}" = "$1" ] && return 0
    i=$((i + 1))
  done
  return 1
}

compute_plan() {
  local i=0 n=${#T_SRC[@]} src dest mck dck act rel
  while [ "$i" -lt "$n" ]; do
    src="${T_SRC[$i]}"; dest="$CLAUDE_DIR/${T_REL[$i]}"
    if [ ! -e "$dest" ]; then
      # 이전 설치가 놓은 파일이 없어졌으면 사용자가 지운 것: 설정 규칙과 같은 정책으로 유지하고 --force 때만 복원. 깨진 링크는 교체.
      if [ ! -L "$dest" ] && [ -n "$(manifest_ck "${T_REL[$i]}")" ] && [ "$OPT_FORCE" != 1 ]; then act=keep-user-deleted
      else act=create; fi
    elif same_file "$src" "$dest"; then act=skip-identical
    else
      mck=$(manifest_ck "${T_REL[$i]}"); dck=$(ck_file "$dest")
      if [ -n "$mck" ]; then
        if [ "$dck" = "$mck" ] || [ "$OPT_FORCE" = 1 ]; then act=update; else act=keep-user-edited; fi
      else
        if [ "$OPT_FORCE" = 1 ]; then act=update; else act=conflict; fi
      fi
    fi
    T_ACTION[$i]="$act"
    i=$((i + 1))
  done
  i=0; n=${#M_REL[@]}
  while [ "$i" -lt "$n" ]; do
    rel="${M_REL[$i]}"
    if [ "$rel" != "settings.json" ] && ! target_has "$rel"; then
      dest="$CLAUDE_DIR/$rel"
      if [ -f "$dest" ]; then
        if [ "$(ck_file "$dest")" = "${M_CK[$i]}" ] || [ "$OPT_FORCE" = 1 ]; then act=remove-stale; else act=keep-modified-stale; fi
        S_REL[${#S_REL[@]}]="$rel"; S_ACTION[${#S_ACTION[@]}]="$act"
      fi
    fi
    i=$((i + 1))
  done
}

# 설정 병합을 스테이지에 생성하고 동작을 결정한다. 결과: $STAGE/settings.json, $STAGE/settings.manifest.json
plan_settings() {
  local overlay="$REPO_DIR/claude/global/settings.json" target="$CLAUDE_DIR/settings.json" real base args
  SETTINGS_ACTION="skip"
  [ "$OPT_NO_SETTINGS" = 1 ] && return 0
  if [ ! -f "$overlay" ]; then warn "소스 없음(건너뜀): claude/global/settings.json"; return 0; fi
  real=$(resolve_link "$target")
  if [ -f "$real" ]; then
    base="$real"; SETTINGS_BASE_CK=$(ck_file "$real")
    if ! json_ok "$real"; then
      # 병합 도구의 `<file>: line X col Y` 메시지를 보여 주고, 파일을 하나도 놓기 전에 중단한다(die 가 스테이지를 치운다).
      python3 -I "$REPO_DIR/scripts/merge-settings.py" --mode install --base "$real" --overlay "$overlay" \
        --out "$STAGE/settings.json" 2>&1 >/dev/null | sed 's/^/  /' >&2
      die "기존 settings.json 이 유효한 JSON이 아니다(JSONC 불가) — 고친 뒤 ./install.sh 를 다시 실행(병합을 건너뛰려면 --no-settings)"
    fi
  else base="NONE"; SETTINGS_BASE_CK=""; fi
  set -- --mode install --base "$base" --overlay "$overlay" --home "$HOME_DIR" \
         --write-manifest "$STAGE/settings.manifest.json" --diff --out "$STAGE/settings.json"
  [ -n "$M_FILE" ] && set -- "$@" --manifest "$M_FILE"
  [ "$OPT_FORCE" = 1 ] && set -- "$@" --force
  if ! python3 -I "$REPO_DIR/scripts/merge-settings.py" "$@" 2> "$STAGE/settings.diff"; then
    cat "$STAGE/settings.diff" >&2
    die "settings.json 병합 실패"
  fi
  SETTINGS_DIFF="$STAGE/settings.diff"
  if [ "$base" = "NONE" ]; then SETTINGS_ACTION=create
  elif same_file "$STAGE/settings.json" "$real"; then SETTINGS_ACTION=skip-identical
  else SETTINGS_ACTION=update; fi
}

label_of() {
  case $1 in
    create) printf '생성          ' ;;
    update) printf '갱신          ' ;;
    skip-identical) printf '변경 없음     ' ;;
    keep-user-edited) printf '유지(사용자 편집)' ;;
    keep-user-deleted) printf '유지(사용자 삭제)' ;;
    conflict) printf '유지(기존 파일 충돌)' ;;
    remove-stale) printf '삭제(구버전)  ' ;;
    keep-modified-stale) printf '유지(구버전·사용자 편집)' ;;
    skip) printf '건너뜀        ' ;;
    *) printf '%s' "$1" ;;
  esac
}

count_action() {
  case $1 in
    create) N_CREATE=$((N_CREATE + 1)) ;;
    update) N_UPDATE=$((N_UPDATE + 1)) ;;
    skip-identical) N_SAME=$((N_SAME + 1)) ;;
    keep-user-edited|keep-user-deleted|conflict|keep-modified-stale) N_KEEP=$((N_KEEP + 1)) ;;
    remove-stale) N_REMOVE=$((N_REMOVE + 1)) ;;
  esac
}

print_plan() {
  local i=0 n=${#T_SRC[@]} act
  log "── 계획 ($CLAUDE_DIR) ──"
  while [ "$i" -lt "$n" ]; do
    act="${T_ACTION[$i]}"; count_action "$act"
    case $act in
      keep-user-edited|conflict) info "$(label_of "$act")  ${T_REL[$i]}  → ${T_REL[$i]}.dev_settings.new" ;;
      keep-user-deleted) info "$(label_of "$act")  ${T_REL[$i]}  (--force 로 복원)" ;;
      *) info "$(label_of "$act")  ${T_REL[$i]}" ;;
    esac
    i=$((i + 1))
  done
  i=0; n=${#S_REL[@]}
  while [ "$i" -lt "$n" ]; do
    count_action "${S_ACTION[$i]}"; info "$(label_of "${S_ACTION[$i]}")  ${S_REL[$i]}"
    i=$((i + 1))
  done
  count_action "$SETTINGS_ACTION"
  info "$(label_of "$SETTINGS_ACTION")  settings.json"
  if [ -n "$SETTINGS_DIFF" ] && [ -s "$SETTINGS_DIFF" ]; then
    # 병합 도구의 경고(유지/충돌)는 항상 보여 주고, diff 는 바뀔 때만 보여 준다.
    grep -E '^(유지\(|WARN)' "$SETTINGS_DIFF" | sed 's/^/  settings: /'
    # 사용자가 지운 관리 항목은 매니페스트에 기억해 계속 넣지 않는다 — 되살리는 방법을 알린다(파일의 '(--force 로 복원)'과 같은 정책)
    if grep -qE '^유지\(사용자 삭제\)' "$SETTINGS_DIFF"; then
      info "settings: 위 '유지(사용자 삭제)' 항목은 다시 넣지 않는다(--force 로 복원)"
    fi
    if [ "$SETTINGS_ACTION" != "skip-identical" ] && grep -qvE '^(유지\(|WARN)' "$SETTINGS_DIFF"; then
      log "── settings.json diff ──"; grep -vE '^(유지\(|WARN)' "$SETTINGS_DIFF"
    fi
  fi
}

plan_has_changes() {
  [ "$N_CREATE" -gt 0 ] || [ "$N_UPDATE" -gt 0 ] || [ "$N_REMOVE" -gt 0 ] && return 0
  case $SETTINGS_ACTION in create|update) return 0 ;; esac
  return 1
}
