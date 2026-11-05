#!/usr/bin/env bash
# /review-diff 스킬 동적 컨텍스트: 브랜치, 변경 파일, diff 통계(작업 트리·스테이징), diff 줄 수를 출력한다.
# 사용법: context.sh [project-dir]
# 계약: 항상 exit 0, bash 3.2 호환, 읽기 전용 git 명령만 쓴다.
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

printf '프로젝트: %s\n' "$dir"
if ! command -v git >/dev/null 2>&1; then
  printf '(git 없음 — diff를 모을 수 없음)\n'
  exit 0
fi
if [ "$(g rev-parse --is-inside-work-tree)" != "true" ]; then
  printf '(git 저장소 아님 — 파일 인수로 범위를 지정하거나 저장소에서 실행)\n'
  exit 0
fi

# branch --show-current는 git 2.22+ → symbolic-ref는 모든 버전에서 동작
branch=$(g symbolic-ref --short -q HEAD)
[ -n "$branch" ] || branch="(detached HEAD)"
upstream=$(g rev-parse --abbrev-ref --symbolic-full-name '@{u}')
if g rev-parse --verify --quiet HEAD >/dev/null; then
  has_head=1
  head_line=$(g log -1 --no-color --format='%h %s')
else
  has_head=0
  head_line="(커밋 없음)"
fi
printf '브랜치: %s · upstream: %s · HEAD: %s\n' "$branch" "${upstream:-(없음)}" "$head_line"

printf '\n변경 파일 (git status --short):\n```\n'
cap "$(g status --short)" "(변경 없음)"
printf '```\n\n작업 트리 diff 통계 (git diff --stat):\n```\n'
cap "$(g diff --stat --no-color)" "(unstaged 변경 없음)"
printf '```\n\n스테이징 diff 통계 (git diff --staged --stat):\n```\n'
cap "$(g diff --staged --stat --no-color)" "(스테이징 없음)"
printf '```\n'

if [ "$has_head" = 1 ]; then
  lines=$(g diff HEAD --no-color --no-ext-diff | wc -l | tr -d ' ')
  printf '\n기본 범위(git diff HEAD, 스테이징 포함) diff 줄 수: %s' "${lines:-0}"
else
  lines=$(g diff --staged --no-color --no-ext-diff | wc -l | tr -d ' ')
  printf '\n기본 범위(첫 커밋 전: git diff --staged) diff 줄 수: %s' "${lines:-0}"
fi
if [ "${lines:-0}" -gt 4000 ] 2>/dev/null; then
  printf ' — 4,000줄 초과: 파일별로 나눠 위임\n'
else
  printf '\n'
fi
untracked=$(g ls-files --others --exclude-standard | wc -l | tr -d ' ')
if [ "${untracked:-0}" -gt 0 ] 2>/dev/null; then
  printf 'untracked 파일 %s개 — diff에 포함되지 않음(필요하면 내용을 직접 읽어 포함)\n' "$untracked"
fi
exit 0
