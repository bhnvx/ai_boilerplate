#!/usr/bin/env bash
# dev_settings — 프로젝트에 Claude Code 하네스 템플릿 적용(CLAUDE.md, .claude/settings.json, rules, gitignore, .worktreeinclude).
# 사용법: ./apply.sh <project-dir> [--profile python|django|fastapi|node|sandbox|auto]... [--with-format-hook] [--force] [--dry-run] [--team] [--yes] [--help]
#   프로필은 선택형 add-on: --profile 을 생략하면 적용하지 않는다(auto 는 detect-stack.sh 감지 결과로 언어 프로필만 고른다).
# 종료 코드: 0 성공 · 1 거부/실패(롤백 없음 — 바뀐 파일만 백업) · 2 사용법 오류 · 3 적용됐지만 validate FAIL. bash 3.2 호환.

REPO_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P) || exit 1
. "$REPO_DIR/scripts/lib/install-common.sh" || exit 1
. "$REPO_DIR/scripts/lib/install-apply.sh" || exit 1

usage() {
  cat <<'EOF'
사용법: ./apply.sh <project-dir> [--profile python|django|fastapi|node|sandbox|auto]... [--with-format-hook] [--force] [--dry-run] [--team] [--yes] [--help]

  --profile <p>       언어 프로필(선택형 add-on, 반복 가능, 쉼표 구분 가능, --profile=<p> 도 가능).
                      생략하면 언어 프로필 없이 공통 템플릿만 적용한다(감지된 스택이 있으면 --profile auto 가
                      고를 프로필을 안내만 한다). auto = hooks/lib/detect-stack.sh 로 감지해 고른다.
                      django/fastapi 는 python 을 함께 적용한다.
                      sandbox = Bash 명령을 OS 샌드박스 안에서 실행하는 설정과 규칙(언어와 무관, auto 가 고르지 않는다).
  --with-format-hook  PostToolUse 포맷 훅과 .claude/hooks/ 복사. 프로젝트에 포매터 설정이 있으면 권장.
                      ECC quality-gate 는 기본적으로 검사만 하므로 겹치지 않는다; ECC_QUALITY_GATE_FIX=true 일 때만
                      ECC 가 고치는 파일 타입을 건너뛴다. 플래그 없이 다시 적용하면 훅 등록을 떼고 복사한 훅 파일을
                      정리한다(저장소 사본과 같을 때만 삭제, 수정됐으면 WARN).
  --force             기존 CLAUDE.md·규칙 파일을 백업 후 덮어쓰기(심볼릭 링크는 일반 파일로 교체, 링크 대상은 유지)
  --dry-run           계획만 출력(아무것도 쓰지 않음)
  --yes, -y           --force 덮어쓰기 확인 생략(비대화형 실행에서 --force 를 쓰려면 필수)
  --team              전역 git.md 를 .claude/rules/git.md 로 함께 복사(팀 컨벤션 동봉)
  -h, --help          이 도움말

종료 코드: 0 성공 · 1 거부/실패(롤백 없음 — 바뀐 파일만 ~/.claude/backups/dev_settings/apply/ 에 백업) · 2 사용법 오류
          · 3 적용됐지만 validate FAIL
EOF
}

TARGET_ARG=""; PROFILES_ARG=""; OPT_FMT=0; OPT_FORCE=0; OPT_DRY=0; OPT_TEAM=0; OPT_YES=0
while [ $# -gt 0 ]; do
  case $1 in
    --profile) [ $# -ge 2 ] || { usage; exit 2; }; PROFILES_ARG="$PROFILES_ARG,$2"; shift ;;
    --profile=*) PROFILES_ARG="$PROFILES_ARG,${1#--profile=}" ;;
    --with-format-hook) OPT_FMT=1 ;;
    --force) OPT_FORCE=1 ;;
    --dry-run) OPT_DRY=1 ;;
    --team) OPT_TEAM=1 ;;
    --yes|-y) OPT_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) printf '알 수 없는 옵션: %s\n\n' "$1" >&2; usage; exit 2 ;;
    *) [ -z "$TARGET_ARG" ] || { printf '프로젝트 디렉터리는 하나만 지정한다\n\n' >&2; usage; exit 2; }; TARGET_ARG="$1" ;;
  esac
  shift
done
[ -n "$TARGET_ARG" ] || { usage; exit 2; }

require_python
[ -d "$TARGET_ARG" ] || die "디렉터리가 아니다: $TARGET_ARG"
TARGET=$(abs_dir "$TARGET_ARG") || die "디렉터리에 들어갈 수 없다: $TARGET_ARG"
[ -n "${HOME:-}" ] || die "HOME 이 비어 있다"
HOME_ABS=$(abs_dir "$HOME" 2>/dev/null || printf '%s' "$HOME")
[ "$TARGET" = "$HOME_ABS" ] && die "거부: 홈 디렉터리 자체에는 적용하지 않는다 ($TARGET)"
# ~/.claude 가 심볼릭 링크면 실제 위치도 거부한다(TARGET 은 이미 링크가 풀린 경로).
CLAUDE_HOME="$HOME_ABS/.claude"; CLAUDE_HOME_REAL=$(abs_dir "$CLAUDE_HOME") || CLAUDE_HOME_REAL="$CLAUDE_HOME"
{ is_under "$TARGET" "$CLAUDE_HOME" || is_under "$TARGET" "$CLAUDE_HOME_REAL"; } && die "거부: ~/.claude 아래에는 적용하지 않는다 ($TARGET)"
[ "$TARGET" = "$REPO_DIR" ] && die "거부: dev_settings 저장소 자체에는 적용하지 않는다 ($TARGET)"
[ -d "$REPO_DIR/claude/project-template" ] || die "claude/project-template/ 이 없다"
# --force 는 확인이 필요한 작업: 대화형이면 묻고, 비대화형이면 --yes 가 있어야 한다(install.sh 와 같은 규칙).
if [ "$OPT_FORCE" = 1 ] && [ "$OPT_DRY" != 1 ] && [ "$OPT_YES" != 1 ]; then
  if [ ! -t 0 ]; then die "확인이 필요한 작업(--force 덮어쓰기) — 비대화형 실행이면 --yes 를 지정" 2; fi
  printf '기존 CLAUDE.md·규칙 파일을 백업 후 덮어쓴다(--force). 진행할까? [y/N] '
  read -r ans; case $ans in y|Y|yes|YES) ;; *) die "중단" 1 ;; esac
fi
BK_PARENT="$HOME_ABS/.claude/backups/dev_settings/apply/${TARGET##*/}"

# 프로필 결정 ------------------------------------------------------------------
PROFILES=()
add_profile() {
  local p
  for p in ${PROFILES[@]+"${PROFILES[@]}"}; do [ "$p" = "$1" ] && return 0; done
  if [ -d "$REPO_DIR/profiles/$1" ]; then PROFILES[${#PROFILES[@]}]="$1"; else warn "프로필 없음(건너뜀): profiles/$1"; fi
}
detect_profiles() {  # [hint] — hint 면 detect-stack.sh 가 없어도 경고하지 않는다(--profile 생략 시 안내용)
  local ds="$REPO_DIR/claude/global/hooks/lib/detect-stack.sh" tokens t
  if [ ! -f "$ds" ]; then [ "${1:-}" = hint ] || warn "hooks/lib/detect-stack.sh 없음 — 자동 감지 불가, --profile 로 지정"; return 0; fi
  tokens=$("$INSTALL_BASH" "$ds" "$TARGET" 2>/dev/null) || tokens=""
  DETECTED="$tokens"
  for t in $tokens; do
    case $t in
      django) add_profile python; add_profile django ;;
      fastapi) add_profile python; add_profile fastapi ;;
      python) add_profile python ;;
      node) add_profile node ;;
    esac
  done
}
DETECTED=""
set -f; IFS=','; set -- $PROFILES_ARG; unset IFS; set +f
for p in "$@"; do
  p=$(printf '%s' "$p" | tr -d '[:space:]')
  case $p in
    "") ;;
    auto) detect_profiles ;;
    python|node|sandbox) add_profile "$p" ;;
    django|fastapi) add_profile python; add_profile "$p" ;;
    *) printf '알 수 없는 프로필: %s\n\n' "$p" >&2; usage; exit 2 ;;
  esac
done
# --profile 생략: 프로필은 선택형 add-on 이라 적용하지 않는다. --profile auto 가 고를 프로필은 안내만 한다.
# 규칙 파일이 이미 다 있는 프로필(예: 예전 버전이 암묵적 auto 로 적용)은 따로 밝힌다 — 빠진 것처럼 읽히지 않게.
AUTO_HINT=""; AUTO_HAVE=""
if [ -z "$PROFILES_ARG" ]; then
  detect_profiles hint
  AUTO_HINT="${PROFILES[*]+"${PROFILES[*]}"}"
  for p in ${PROFILES[@]+"${PROFILES[@]}"}; do
    n_rules=0; n_have=0
    for f in "$REPO_DIR/profiles/$p/rules"/*.md; do
      [ -f "$f" ] || continue
      n_rules=$((n_rules + 1)); [ -f "$TARGET/.claude/rules/${f##*/}" ] && n_have=$((n_have + 1))
    done
    [ "$n_rules" -gt 0 ] && [ "$n_have" = "$n_rules" ] && AUTO_HAVE="$AUTO_HAVE${AUTO_HAVE:+ }$p"
  done
  PROFILES=()
fi

# 실행 ------------------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dev_settings.apply.XXXXXX") || die "임시 디렉터리 생성 실패"
trap 'rm -rf -- "$WORK"' EXIT
log "dev_settings 적용 — 프로젝트: $TARGET$( [ "$OPT_DRY" = 1 ] && printf ' (dry-run: 쓰지 않음)')"
[ -n "$DETECTED" ] && log "감지된 스택: $DETECTED"
PLIST="${PROFILES[*]+"${PROFILES[*]}"}"; [ -n "$PLIST" ] || PLIST="(없음)"
[ -z "$PROFILES_ARG" ] && PLIST="(없음) — --profile 을 지정하지 않아 언어 프로필을 적용하지 않는다"
log "프로필: $PLIST"
[ -n "$AUTO_HINT" ] && log "힌트: --profile auto 를 붙이면 $AUTO_HINT 프로필을 적용한다${AUTO_HAVE:+(규칙 파일이 이미 있는 프로필: $AUTO_HAVE)}"
log "── 계획 ──"
apply_claude_md "$WORK"
apply_sync "$REPO_DIR/claude/project-template/CLAUDE.local.md.example" "CLAUDE.local.md.example" 644
apply_settings "$WORK" "$OPT_FMT" ${PROFILES[@]+"${PROFILES[@]}"}
apply_sync "$REPO_DIR/claude/project-template/dot-claude/settings.local.json.example" ".claude/settings.local.json.example" 644
apply_once "$REPO_DIR/claude/project-template/dot-claude/rules/project.md" ".claude/rules/project.md" 644
for p in ${PROFILES[@]+"${PROFILES[@]}"}; do
  for f in "$REPO_DIR/profiles/$p/rules"/*.md; do
    [ -f "$f" ] && apply_once "$f" ".claude/rules/${f##*/}" 644
  done
done
if [ "$OPT_TEAM" = 1 ]; then apply_sync "$REPO_DIR/claude/global/rules/git.md" ".claude/rules/git.md" 644; fi
apply_seed "$REPO_DIR/claude/project-template/dot-worktreeinclude" ".worktreeinclude" 644
HOOKS_ORPHAN=0
if [ "$OPT_FMT" = 1 ]; then
  for f in run-hook.sh format-on-edit.sh lib/common.sh; do
    apply_sync "$REPO_DIR/claude/global/hooks/$f" ".claude/hooks/$f" 755
  done
else
  apply_prune_hooks
fi
apply_gitignore

# 사후 -------------------------------------------------------------------------
if [ "$OPT_DRY" = 1 ]; then log "dry-run 종료 — 아무것도 쓰지 않았다."; exit 0; fi
run_validate --project "$TARGET"
log "── 요약 ──"
info "생성 $N_CREATE · 갱신 $N_UPDATE · 유지 $N_KEEP · 삭제 $N_REMOVE · 변경 없음 $N_SAME · 경고 $N_WARN"
[ -n "${BK_DIR:-}" ] && [ -d "$BK_DIR" ] && info "백업: $BK_DIR"
log "── 커밋할 파일 ──"
for f in CLAUDE.md .gitignore .worktreeinclude .claude/settings.json; do [ -f "$TARGET/$f" ] && info "$f"; done
[ -d "$TARGET/.claude/rules" ] && info ".claude/rules/*.md"
if [ -d "$TARGET/.claude/hooks" ]; then
  # 참조되지 않는(수정된) 훅 파일만 남은 경우는 커밋 목록에서 뺀다.
  if [ "$HOOKS_ORPHAN" = 0 ] || grep -qF -- '.claude/hooks/' "$TARGET/.claude/settings.json" 2>/dev/null; then info ".claude/hooks/**"; fi
fi
log "── 커밋하지 않을 파일(gitignore.claude 가 제외) ──"
info "CLAUDE.local.md · .claude/settings.local.json · *.dev_settings.new"
log "── 선택: 팀원용 예시(커밋 가능) ──"
info "CLAUDE.local.md.example · .claude/settings.local.json.example"
log "── TODO ──"
for n in ${NOTE_LINES[@]+"${NOTE_LINES[@]}"}; do info "$n"; done
if [ "${VALIDATE_RC:-0}" = 1 ]; then log "validate.sh 가 FAIL 을 보고했다(종료 코드 3)."; exit 3; fi
exit 0
