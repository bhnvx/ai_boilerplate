#!/usr/bin/env bash
# /harness-init 스킬 동적 컨텍스트: dev_settings 저장소 위치, apply.sh 유무, 감지된 스택, 프로젝트 하네스 파일 현황.
# 사용법: context.sh [project-dir]
# 계약: 항상 exit 0, bash 3.2 호환, 아무것도 쓰지 않는다.
set +e
# 오래된 git(< 2.15)은 --no-optional-locks 옵션이 없다 → 환경 변수로 같은 효과(모르는 git은 무시).
GIT_OPTIONAL_LOCKS=0
export GIT_OPTIONAL_LOCKS

dir=${1:-}
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  dir=$(pwd -P 2>/dev/null || pwd)
fi
cfg="$HOME/.claude"

have() { if [ -e "$dir/$1" ]; then printf '있음'; else printf '없음'; fi; }
# sq <s>: 셸에 그대로 붙여 넣을 수 있게 작은따옴표로 감싼다(내부 ' → '\'').
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

printf '프로젝트: %s\n' "$dir"

# 1) dev_settings 저장소 경로(install.sh가 기록)
repo=""
if [ -f "$cfg/dev_settings.repo" ]; then
  IFS= read -r repo < "$cfg/dev_settings.repo"
  repo=${repo%$'\r'}
fi
if [ -z "$repo" ]; then
  printf 'dev_settings 저장소: (미설치: install.sh 실행 필요)\n'
elif [ ! -d "$repo" ]; then
  printf 'dev_settings 저장소: %s (경로 없음: 저장소를 옮겼으면 install.sh 재실행 필요)\n' "$repo"
else
  printf 'dev_settings 저장소: %s\n' "$repo"
  if [ -f "$repo/apply.sh" ]; then
    printf 'apply.sh: 있음 (%s/apply.sh)\n' "$repo"
  else
    printf 'apply.sh: 없음 (저장소가 불완전함)\n'
  fi
fi

# 2) 스택 감지(전역 훅 라이브러리 재사용)
ds="$cfg/hooks/lib/detect-stack.sh"
if [ -f "$ds" ]; then
  stack=$(bash "$ds" "$dir" 2>/dev/null)
  stack=$(printf '%s' "$stack" | tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//')
  if [ -n "$stack" ]; then
    printf '감지된 스택: %s\n' "$stack"
  else
    printf '감지된 스택: (감지된 스택 없음)\n'
  fi
else
  stack=""
  printf '감지된 스택: (detect-stack 없음)\n'
fi

# 3) --profile auto 결과 추정(apply.sh 매핑: python→python, django→python+django, fastapi→python+fastapi, node→node)
prof=""
case " $stack " in *" python "*|*" django "*|*" fastapi "*) prof="python" ;; esac
case " $stack " in *" django "*) prof="$prof django" ;; esac
case " $stack " in *" fastapi "*) prof="$prof fastapi" ;; esac
case " $stack " in *" node "*) prof="${prof:+$prof }node" ;; esac
if [ -n "$prof" ]; then
  printf 'auto 프로필(추정): %s\n' "$prof"
else
  printf 'auto 프로필(추정): 없음 (공통 템플릿만 적용)\n'
fi

# 4) 프로젝트 하네스 파일 현황
printf '\n프로젝트 파일 현황:\n'
printf -- '- CLAUDE.md: %s\n' "$(have CLAUDE.md)"
printf -- '- .claude/CLAUDE.md: %s\n' "$(have .claude/CLAUDE.md)"
printf -- '- AGENTS.md: %s\n' "$(have AGENTS.md)"
printf -- '- CLAUDE.local.md: %s\n' "$(have CLAUDE.local.md)"
printf -- '- .claude/settings.json: %s\n' "$(have .claude/settings.json)"
printf -- '- .claude/settings.local.json: %s\n' "$(have .claude/settings.local.json)"
printf -- '- .claude/rules/project.md: %s\n' "$(have .claude/rules/project.md)"
printf -- '- .gitignore: %s\n' "$(have .gitignore)"

# 5) git 상태와 ECC 플러그인(포맷 훅 상호배제 판단용)
if command -v git >/dev/null 2>&1 &&
   [ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]; then
  # branch --show-current는 git 2.22+ → symbolic-ref는 모든 버전에서 동작
  br=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null)
  dirty=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  printf -- '- git: 저장소 (브랜치 %s, 미커밋 변경 %s개)\n' "${br:-(detached HEAD)}" "${dirty:-0}"
else
  printf -- '- git: 저장소 아님\n'
fi
# ECC quality-gate는 기본적으로 검사만 한다. ECC_QUALITY_GATE_FIX=true(그리고 minimal 프로필이 아니고
# post:quality-gate가 꺼지지 않음)일 때만 포맷하며, 그때 포맷 훅은 ECC가 고치는 타입만 건너뛴다.
ecc_re='"ecc@ecc"[[:space:]]*:[[:space:]]*true'
if [ -f "$cfg/settings.json" ] && grep -Eq "$ecc_re" "$cfg/settings.json" 2>/dev/null; then
  ecc_fix=$(printf '%s' "${ECC_QUALITY_GATE_FIX:-}" | tr '[:upper:]' '[:lower:]')
  ecc_prof=$(printf '%s' "${ECC_HOOK_PROFILE:-}" | tr '[:upper:]' '[:lower:]')
  ecc_dis=$(printf '%s' "${ECC_DISABLED_HOOKS:-}" | tr '[:upper:]' '[:lower:]')
  case $ecc_dis in *post:quality-gate*) ecc_fix=off ;; esac
  [ "$ecc_prof" = minimal ] && ecc_fix=off
  if [ "$ecc_fix" = true ]; then
    printf -- '- ECC 플러그인: 활성, ECC_QUALITY_GATE_FIX=true — 포맷 훅은 ECC가 고치는 타입(.py .go .ts .tsx .js .jsx .json .md)을 건너뛰고 나머지(bash -n·shfmt·rustfmt·terraform fmt·taplo)만 실행\n'
  else
    printf -- '- ECC 플러그인: 활성 (quality-gate는 기본적으로 검사만 하므로 포맷 훅과 겹치지 않음)\n'
  fi
else
  printf -- '- ECC 플러그인: 비활성 또는 확인 불가\n'
fi

if [ -n "$repo" ] && [ -f "$repo/apply.sh" ]; then
  printf '\n미리보기 명령: bash %s %s --profile auto --dry-run\n' "$(sq "$repo/apply.sh")" "$(sq "$dir")"
fi
exit 0
