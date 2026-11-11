#!/usr/bin/env bash
# ai_boilerplate — install.sh / apply.sh 공용 헬퍼 (bash 3.2 호환, GNU 전용 도구 금지).
# 소스 전제: 호출자가 REPO_DIR 를 설정한다. 모든 경로는 따옴표로 감싼다.

N_CREATE=0; N_UPDATE=0; N_KEEP=0; N_REMOVE=0; N_SAME=0; N_WARN=0

log()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*" >&2; N_WARN=$((N_WARN + 1)); }
# 오류 메시지 후 종료. 스테이지 디렉터리(STAGE)가 있으면 항상 치운다(실패 시 ~/.claude 에 잔재를 남기지 않음).
# usage: die <message> [exit-code=1]
die() {
  printf '오류: %s\n' "$1" >&2
  if [ -n "${STAGE:-}" ] && [ -d "$STAGE" ]; then rm -rf -- "$STAGE"; fi
  # install.sh 가 이번 실행에서 만든 ~/.claude 는 비어 있으면 지운다(계획 단계에서 중단된 경우; rmdir 은 빈 디렉터리만 지움).
  if [ "${CLAUDE_DIR_NEW:-0}" = 1 ] && [ -n "${CLAUDE_DIR:-}" ]; then rmdir -- "$CLAUDE_DIR" 2>/dev/null; fi
  exit "${2:-1}"
}

# 스크립트 실행용 bash: /bin/bash 가 없는 시스템(NixOS 등)에서는 현재 bash 로 대체.
INSTALL_BASH=/bin/bash
[ -x "$INSTALL_BASH" ] || INSTALL_BASH=${BASH:-bash}

# 테스트 전용 실패 주입: AI_BOILERPLATE_FAIL_AT 에 쉼표로 나열된 지점 이름이 있으면 0.
# usage: fail_at <point>
fail_at() {
  case ",${AI_BOILERPLATE_FAIL_AT:-}," in *",$1,"*) return 0 ;; esac
  return 1
}

# 파일의 cksum(CRC) 만 출력. 없으면 빈 문자열.
ck_file() {
  if [ -f "$1" ]; then cksum < "$1" 2>/dev/null | awk '{print $1}'; else printf ''; fi
}

# 두 파일 내용이 같으면 0.
same_file() { [ -f "$1" ] && [ -f "$2" ] && cmp -s -- "$1" "$2"; }

# 디렉터리를 심볼릭 링크 해석 포함 절대 경로로. 없으면 빈 문자열 + 실패.
abs_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

# 심볼릭 링크를 끝까지 따라간 최종 경로(readlink 루프; readlink -f 금지).
resolve_link() {
  local p="$1" t d n=0
  while [ -L "$p" ] && [ "$n" -lt 40 ]; do
    t=$(readlink "$p") || break
    case $t in
      /*) p="$t" ;;
      *) d=$(dirname -- "$p"); p="$d/$t" ;;
    esac
    n=$((n + 1))
  done
  printf '%s\n' "$p"
}

# $1 이 디렉터리 $2 안(또는 동일)이면 0.
is_under() {
  case "$1/" in
    "$2"/*) return 0 ;;
  esac
  return 1
}

now_ts()  { date +%Y%m%d-%H%M%S; }
now_iso() { date +%Y-%m-%dT%H:%M:%S%z; }

# 파이썬 확인(JSON 처리에 필수).
require_python() {
  command -v python3 >/dev/null 2>&1 || die "python3 가 필요하다(JSON 병합·검증). 설치 후 다시 실행."
  python3 -I -c 'import json, sys' 2>/dev/null || die "python3 가 json 모듈을 불러오지 못한다."
}

# JSON 파일 파싱 가능 여부(0=정상).
json_ok() { python3 -I -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$1" 2>/dev/null; }

# 파일을 목적지 디렉터리 안의 임시 파일로 쓴 뒤 원자적으로 교체. 기존 모드는 유지(cp -p 트릭).
# 읽기 전용(0444 등) 목적지도 교체한다: 임시 파일에 잠시 쓰기 권한을 주고 쓴 뒤 원래대로 되돌린다.
# 호출자는 심볼릭 링크를 resolve_link 로 먼저 해석한다(링크 자체가 아니라 대상을 교체).
# usage: atomic_replace <src> <dest>
atomic_replace() {
  local src="$1" dest="$2" dir tmp ro=0
  dir=$(dirname -- "$dest")
  mkdir -p -- "$dir" || return 1
  tmp=$(mktemp "$dir/.ai_boilerplate.tmp.XXXXXX") || return 1
  if [ -f "$dest" ]; then
    cp -p -- "$dest" "$tmp" 2>/dev/null || true
    [ -w "$dest" ] || ro=1
    chmod u+w "$tmp" 2>/dev/null || true   # BSD chmod 는 모드 뒤의 -- 를 파일명으로 본다 — 경로는 항상 디렉터리명으로 시작
  fi
  cat -- "$src" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  [ "$ro" = 1 ] && chmod a-w "$tmp" 2>/dev/null
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
}

# 파일 배치: 같은 디렉터리의 임시 파일에 복사·chmod 후 mv 로 원자적으로 교체(다른 세션이 훅을 읽는 중에도 안전).
# 목적지가 심볼릭 링크(살아 있든 깨졌든)면 링크를 지우고 일반 파일로 둔다 — 링크 대상은 절대 쓰지 않는다
# (예: CLAUDE.md → AGENTS.md). 호출자가 미리 백업한다(backup_file 은 링크를 따라가므로 대상 내용이 보존됨).
# usage: place_file <src> <dest> <mode>
place_file() {
  local src="$1" dest="$2" mode="$3" dir tmp
  dir=$(dirname -- "$dest")
  mkdir -p -- "$dir" || return 1
  tmp=$(mktemp "$dir/.ai_boilerplate.tmp.XXXXXX") || return 1
  cat -- "$src" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod "$mode" "$tmp" || { rm -f -- "$tmp"; return 1; }
  if [ -L "$dest" ]; then
    info "심볼릭 링크를 일반 파일로 교체(링크 대상은 그대로 둠): ${dest##*/} → $(readlink -- "$dest" 2>/dev/null)"
    rm -f -- "$dest" || { rm -f -- "$tmp"; return 1; }
  fi
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
}

# 백업 디렉터리를 지연 생성(umask 077). BK_DIR 전역에 저장.
# usage: ensure_backup_dir <parent-dir>
ensure_backup_dir() {
  local parent="$1" old_umask
  [ -n "${BK_DIR:-}" ] && return 0
  old_umask=$(umask)
  umask 077
  mkdir -p -- "$parent" || { umask "$old_umask"; return 1; }
  BK_DIR=$(mktemp -d "$parent/$(now_ts).XXXXXX") || { umask "$old_umask"; return 1; }
  umask "$old_umask"
}

# 백업 사본을 되돌린다: cp -p(모드 보존) 가 읽기 전용 대상 등으로 실패하면 임시 파일 + mv 로 교체한다.
# usage: restore_file <backup-copy> <target>
restore_file() {
  cp -p -- "$1" "$2" 2>/dev/null && return 0
  atomic_replace "$1" "$2"
}

# 파일을 백업 디렉터리에 상대 경로 그대로 보존(cp -p). 심볼릭 링크(깨진 링크 포함)면 링크 텍스트를
# <rel>.ai_boilerplate.link 에 남겨 롤백·--restore 가 링크를 다시 만들게 한다(place_file 이 링크를 일반 파일로 바꾸므로).
# usage: backup_file <abs-path> <rel-path> <backup-parent>
backup_file() {
  local src="$1" rel="$2" parent="$3" lt
  [ -f "$src" ] || [ -L "$src" ] || return 0
  ensure_backup_dir "$parent" || return 1
  mkdir -p -- "$(dirname -- "$BK_DIR/$rel")" || return 1
  if [ -L "$src" ]; then
    lt=$(readlink -- "$src") || return 1
    printf '%s' "$lt" > "$BK_DIR/$rel.ai_boilerplate.link" || return 1
  fi
  [ -f "$src" ] || return 0
  cp -p -- "$src" "$BK_DIR/$rel"
}

# 백업에 링크 기록(<rel>.ai_boilerplate.link)이 있는 상대 경로 목록(정렬, 개행 구분).
# usage: list_links <backup-dir>
list_links() {
  [ -d "$1" ] || return 0
  (cd -P -- "$1" && find . -type f -name '*.ai_boilerplate.link' -print \
    | sed -e 's|^\./||' -e 's|\.ai_boilerplate\.link$||' | LC_ALL=C sort)
}

# 링크 기록대로 <target> 을 심볼릭 링크로 되돌린다. 이미 같은 링크면 그대로 둔다.
# usage: restore_link <link-record> <target>
restore_link() {
  local lt
  lt=$(cat -- "$1") || return 1
  [ -n "$lt" ] || return 1
  if [ -L "$2" ] && [ "$(readlink -- "$2")" = "$lt" ]; then return 0; fi
  rm -f -- "$2" || return 1
  ln -s -- "$lt" "$2"
}

# 오래된 백업 정리: <parent> 아래 YYYYmmdd-HHMMSS.XXXX 형태 디렉터리를 최근 N개만 남긴다.
# usage: prune_backups <parent> <keep>
prune_backups() {
  local parent="$1" keep="$2" n cut d re
  [ -d "$parent" ] || return 0
  re='^[0-9]{8}-[0-9]{6}\.[A-Za-z0-9]+$'
  n=0
  for d in "$parent"/*/; do
    d=${d%/}; d=${d##*/}
    [[ $d =~ $re ]] && n=$((n + 1))
  done
  [ "$n" -le "$keep" ] && return 0
  cut=$((n - keep))
  for d in "$parent"/*/; do
    d=${d%/}
    [[ ${d##*/} =~ $re ]] || continue
    [ "$cut" -gt 0 ] || break
    rm -rf -- "$d"
    cut=$((cut - 1))
  done
}

# 정렬된 파일 목록(상대 경로, 개행 구분)을 출력. .DS_Store, *.ai_boilerplate.new, 링크 기록(*.ai_boilerplate.link) 제외.
# usage: list_files <dir>
list_files() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  (cd -P -- "$dir" && find . -type f ! -name .DS_Store ! -name '*.ai_boilerplate.new' ! -name '*.ai_boilerplate.link' ! -name .gitkeep -print \
    | sed 's|^\./||' | LC_ALL=C sort)
}

# `bash -n` 과 JSON 파싱으로 스테이지 트리를 검증. 실패 시 1.
# usage: validate_tree <dir>
validate_tree() {
  local dir="$1" f rc=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case $f in
      *.sh|*.bash) "$INSTALL_BASH" -n -- "$dir/$f" 2>/dev/null || { warn "문법 오류: $f"; rc=1; } ;;
      *.json) json_ok "$dir/$f" || { warn "JSON 파싱 실패: $f"; rc=1; } ;;
    esac
  done <<EOF
$(list_files "$dir")
EOF
  return $rc
}

# validate.sh 를 중단 없이 실행. 결과: VALIDATE_RC (0 정상/WARN, 1 FAIL, 없음=skip).
run_validate() {
  local v="$REPO_DIR/scripts/validate.sh"
  VALIDATE_RC=0
  if [ ! -f "$v" ]; then
    warn "scripts/validate.sh 없음 — 검증 건너뜀"
    return 0
  fi
  log "── validate.sh ──"
  if "$INSTALL_BASH" "$v" "$@"; then VALIDATE_RC=0; else VALIDATE_RC=1; fi
  return 0
}
