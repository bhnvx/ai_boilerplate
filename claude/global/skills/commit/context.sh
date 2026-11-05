#!/usr/bin/env bash
# /commit 스킬 동적 컨텍스트: 보호 브랜치, 현재 브랜치, 변경 요약, 최근 커밋을 출력한다.
# 사용법: context.sh [project-dir]
# 계약: 항상 exit 0, bash 3.2 호환, 저장소를 변경하지 않는다(읽기 전용 git 명령만).
set +e
# 오래된 git(< 2.15)은 --no-optional-locks 옵션이 없다 → 환경 변수로 같은 효과(모르는 git은 무시).
GIT_OPTIONAL_LOCKS=0
export GIT_OPTIONAL_LOCKS

dir=${1:-}
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  dir=$(pwd -P 2>/dev/null || pwd)
fi
max_lines=60

g() { git -c core.quotePath=false -C "$dir" "$@" 2>/dev/null; }

# cap <text> [<empty-label>]: 처음 max_lines줄만 출력하고 생략 줄 수를 알린다.
cap() {
  if [ -z "$1" ]; then
    printf '%s\n' "${2:-(없음)}"
    return 0
  fi
  total=$(printf '%s\n' "$1" | wc -l | tr -d ' ')
  printf '%s\n' "$1" | head -n "$max_lines"
  if [ "${total:-0}" -gt "$max_lines" ] 2>/dev/null; then
    printf '… (%s줄 중 %s줄만 표시)\n' "$total" "$max_lines"
  fi
  return 0
}

# 보호 브랜치: 쉼표·공백 구분, glob 허용(release/*). 미설정일 때만 기본값, none(대소문자 무관)·빈 값은 비활성.
if [ -n "${CLAUDE_GUARD_PROTECTED_BRANCHES+x}" ]; then
  prot_raw=$CLAUDE_GUARD_PROTECTED_BRANCHES; prot_src='CLAUDE_GUARD_PROTECTED_BRANCHES'
else
  prot_raw='main master'; prot_src='기본값, CLAUDE_GUARD_PROTECTED_BRANCHES 미설정'
fi
prot=$(printf '%s' "$prot_raw" | tr ',\t\r\n' '    ' | tr -s ' ' | sed 's/^ //; s/ $//')
prot_off=0
if [ -z "$prot" ] || [ "$(printf '%s' "$prot" | tr '[:upper:]' '[:lower:]')" = none ]; then prot_off=1; fi

# is_prot <branch>: 보호 브랜치 목록(glob 포함)에 있으면 0
is_prot() {
  local p
  set -f
  for p in $prot; do
    case $1 in $p) set +f; return 0 ;; esac
  done
  set +f
  return 1
}

printf '프로젝트: %s\n' "$dir"
if [ "$prot_off" = 1 ]; then
  printf '보호 브랜치: none (보호 브랜치 규칙 비활성)\n'
else
  printf '보호 브랜치: %s (%s)\n' "$prot" "$prot_src"
fi

if ! command -v git >/dev/null 2>&1; then
  printf '현재 브랜치: (git 없음)\n'
  exit 0
fi
if [ "$(g rev-parse --is-inside-work-tree)" != "true" ]; then
  printf '현재 브랜치: (git 저장소 아님)\n'
  exit 0
fi

# branch --show-current는 git 2.22+ → symbolic-ref는 모든 버전에서 동작
branch=$(g symbolic-ref --short -q HEAD)
if [ -z "$branch" ]; then
  printf '현재 브랜치: (detached HEAD) — 커밋 전 브랜치 생성 여부 확인\n'
elif [ "$prot_off" = 1 ]; then
  printf '현재 브랜치: %s\n' "$branch"
elif is_prot "$branch"; then
  printf '현재 브랜치: %s — 보호 브랜치: 커밋 전에 멈추고 브랜치 생성 여부를 사용자에게 확인\n' "$branch"
else
  printf '현재 브랜치: %s — 보호 브랜치 아님\n' "$branch"
fi

printf '\n변경 파일 (git status --short):\n```\n'
cap "$(g status --short)" "(변경 없음)"
printf '```\n\n스테이징 요약 (git diff --staged --stat):\n```\n'
cap "$(g diff --staged --stat --no-color)" "(스테이징 없음)"
printf '```\n\n최근 커밋 (메시지 형식 참고):\n```\n'
if g rev-parse --verify --quiet HEAD >/dev/null; then
  cap "$(g log -5 --no-color --format='%h %s')" "(커밋 없음)"
else
  printf '(커밋 없음: 첫 커밋)\n'
fi
printf '```\n'
exit 0
