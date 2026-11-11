#!/usr/bin/env bash
# ai_boilerplate — Claude Code 전역 하네스 설치(~/.claude, 복사 모드).
# 사용법: ./install.sh [--dry-run] [--force] [--no-settings] [--home <dir>] [--uninstall] [--restore <ts>] [--yes] [--help]
# 종료 코드: 0 성공 · 1 실패(롤백됨) · 2 사용법 오류 · 3 설치됐지만 validate FAIL. bash 3.2 호환.
# 비대화형 실행(stdin 이 TTY 아님)에서 파괴적 작업(--uninstall/--restore/구버전 삭제/--force 덮어쓰기)은 --yes 가 필수.

REPO_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P) || exit 1
for lib in install-common install-plan install-tx install-ops; do
  . "$REPO_DIR/scripts/lib/$lib.sh" || { printf '오류: scripts/lib/%s.sh 를 읽을 수 없다\n' "$lib" >&2; exit 1; }
done

OPT_DRY=0; OPT_FORCE=0; OPT_NO_SETTINGS=0; OPT_YES=0; OPT_UNINSTALL=0; OPT_RESTORE=""; OPT_HOME_ARG=""; OPT_HOME_SET=0
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) OPT_DRY=1 ;;
    --force) OPT_FORCE=1 ;;
    --no-settings) OPT_NO_SETTINGS=1 ;;
    --home) [ $# -ge 2 ] || { usage; exit 2; }; OPT_HOME_ARG="$2"; OPT_HOME_SET=1; shift ;;
    --home=*) OPT_HOME_ARG="${1#--home=}"; OPT_HOME_SET=1 ;;
    --uninstall) OPT_UNINSTALL=1 ;;
    --restore) [ $# -ge 2 ] || { usage; exit 2; }; OPT_RESTORE="$2"; shift ;;
    --yes|-y) OPT_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf '알 수 없는 옵션: %s\n\n' "$1" >&2; usage; exit 2 ;;
  esac
  shift
done

require_python
# 빈 --home 은 실제 $HOME 으로 조용히 대체하지 않는다(테스트·CI 에서 변수가 비었을 때 실제 ~/.claude 를 건드리는 사고 방지).
if [ "$OPT_HOME_SET" = 1 ] && [ -z "$OPT_HOME_ARG" ]; then printf '오류: --home 값이 비어 있다\n\n' >&2; usage; exit 2; fi
if [ -n "$OPT_HOME_ARG" ]; then
  case $OPT_HOME_ARG in /*) HOME_DIR="$OPT_HOME_ARG" ;; *) HOME_DIR="$PWD/$OPT_HOME_ARG" ;; esac
  if [ -d "$HOME_DIR" ]; then HOME_DIR=$(abs_dir "$HOME_DIR"); fi
else
  [ -n "${HOME:-}" ] || die "HOME 이 비어 있다"
  HOME_DIR=$(abs_dir "$HOME") || die "HOME 디렉터리에 들어갈 수 없다: $HOME"
fi
CLAUDE_DIR="$HOME_DIR/.claude"
# ~/.claude 가 심볼릭 링크면 실제 위치로도 검사한다(저장소를 가리키는 링크에 설치하면 저장소가 오염된다).
CLAUDE_DIR_REAL="$CLAUDE_DIR"
if [ -d "$CLAUDE_DIR" ]; then CLAUDE_DIR_REAL=$(abs_dir "$CLAUDE_DIR") || CLAUDE_DIR_REAL="$CLAUDE_DIR"; fi
for d in "$CLAUDE_DIR" "$CLAUDE_DIR_REAL"; do
  is_under "$d" "$REPO_DIR" && die "설치 대상($d)이 저장소 안에 있다 — --home 을 다른 곳으로(~/.claude 가 저장소를 가리키는 링크면 먼저 해제)"
done
[ -f "$REPO_DIR/scripts/merge-settings.py" ] || die "scripts/merge-settings.py 가 없다"

if [ -n "$OPT_RESTORE" ]; then op_restore "$OPT_RESTORE"; exit 0; fi
if [ "$OPT_UNINSTALL" = 1 ]; then op_uninstall; exit 0; fi

log "ai_boilerplate 설치 — 저장소: $REPO_DIR"
log "대상: $CLAUDE_DIR$( [ "$OPT_DRY" = 1 ] && printf ' (dry-run: 쓰지 않음)')"
load_manifest "$CLAUDE_DIR/ai_boilerplate.manifest.json"
plan_targets
[ "${#T_SRC[@]}" -gt 0 ] || die "설치할 소스 파일이 없다(claude/global/ 비어 있음)"
compute_plan
tx_begin "$OPT_DRY"
plan_settings
print_plan

if [ "$OPT_DRY" = 1 ]; then
  tx_cleanup
  log "dry-run 종료 — 아무것도 쓰지 않았다."
  exit 0
fi

CUR_COMMIT=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || printf unknown)
if plan_has_changes || [ "$N_KEEP" -gt 0 ]; then
  if [ "$N_REMOVE" -gt 0 ] || { [ "$OPT_FORCE" = 1 ] && [ "$N_UPDATE" -gt 0 ]; }; then
    what="구버전 파일 삭제"; [ "$N_REMOVE" -gt 0 ] || what="--force 덮어쓰기"
    confirm "위 계획대로 진행할까?" "$what" || die "취소함" 1
  fi
  tx_stage
  tx_run
elif [ -z "$M_FILE" ] || [ "$M_COMMIT" != "$CUR_COMMIT" ]; then
  tx_manifest
  log "변경 없음 — 매니페스트만 갱신(커밋 $CUR_COMMIT)."
else
  log "변경 없음 — 이미 최신 상태."
fi
tx_cleanup

run_validate --installed --home "$HOME_DIR"
print_summary
print_next_steps
if [ "${VALIDATE_RC:-0}" = 1 ]; then
  log "validate.sh 가 FAIL 을 보고했다 — 위 항목을 확인(종료 코드 3)."
  exit 3
fi
exit 0
