#!/usr/bin/env bash
# /preflight 스킬 동적 컨텍스트: 베이스 대비 변경 범위, 파일 분류, 마이그레이션·의존성 신호,
# 환경 변수 동기화, 시크릿 후보(위치만), 프로젝트 명령, 감지된 스택을 출력한다.
# 사용법: context.sh [project-dir] [base-ref]
# 계약: 항상 exit 0, bash 3.2 호환, 아무것도 쓰지 않는다(읽기 전용 git 명령만). 비밀 값은 출력하지 않는다.
set +e

PF_DIR=${1:-}
if [ -z "$PF_DIR" ] || [ ! -d "$PF_DIR" ]; then
  PF_DIR=$(pwd -P 2>/dev/null || pwd)
fi
arg_base=${2:-}
here=$(cd -P -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
if [ -z "$here" ] || [ ! -f "$here/lib.sh" ]; then
  printf '(preflight/lib.sh 없음 — 설치가 불완전함: 사용자에게 /harness-check 실행을 제안)\n'
  exit 0
fi
# shellcheck source=lib.sh
. "$here/lib.sh"

fence() { printf '```\n'; }

printf '프로젝트: %s\n' "$PF_DIR"

in_git=0
if command -v git >/dev/null 2>&1 && [ "$(pf_git rev-parse --is-inside-work-tree)" = "true" ]; then
  in_git=1
fi

if [ "$in_git" = 1 ]; then
  PF_HAS_HEAD=0
  pf_git rev-parse --verify --quiet HEAD >/dev/null && PF_HAS_HEAD=1
  pf_pick_base "$arg_base"
  branch=$(pf_git symbolic-ref --short -q HEAD)   # branch --show-current는 git 2.22+
  [ -n "$branch" ] || branch="(detached HEAD)"
  if [ -n "$PF_BASE" ]; then
    base_line="$PF_BASE ($PF_BASE_HOW)"
  elif [ "$PF_HAS_HEAD" = 1 ]; then
    base_line="없음 (첫 커밋뿐 — 작업 트리 변경만 비교)"
  else
    base_line="없음 (커밋 없음 — 스테이징·untracked만 비교)"
  fi
  printf '브랜치: %s · 베이스: %s\n' "$branch" "$base_line"
  [ -n "$PF_BASE_NOTE" ] && printf '참고: %s\n' "$PF_BASE_NOTE"

  printf '\n### 변경 파일 (git status --short)\n'
  fence; pf_cap "$(pf_git status --short)" "(작업 트리 변경 없음)" 40; fence
  if [ -n "$PF_BASE" ]; then
    printf '\n### 커밋된 변경 (git diff --stat %s...HEAD)\n' "$PF_BASE"
    fence; pf_cap "$(pf_git diff --stat --no-color "$PF_BASE...HEAD")" "(베이스 이후 커밋 없음)" 40; fence
  fi
  if [ "$PF_HAS_HEAD" = 1 ]; then
    printf '\n### 미커밋 변경 (git diff --stat HEAD, 스테이징 포함)\n'
    fence; pf_cap "$(pf_git diff --stat --no-color HEAD)" "(미커밋 변경 없음)" 40; fence
  else
    printf '\n### 스테이징 변경 (git diff --staged --stat)\n'
    fence; pf_cap "$(pf_git diff --staged --stat --no-color)" "(스테이징 없음)" 40; fence
  fi

  # 변경 파일 목록(커밋 + 미커밋 + untracked) 분류
  changed=$(
    {
      [ -n "$PF_BASE" ] && pf_git diff --name-only "$PF_BASE...HEAD"
      if [ "$PF_HAS_HEAD" = 1 ]; then pf_git diff --name-only HEAD; else pf_git diff --name-only --cached; fi
      pf_git ls-files --others --exclude-standard
    } | LC_ALL=C sort -u
  )
  cls=""; n_mig=0; n_model=0; n_secret=0; n_env=0; manifests=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    pf_cat "$p"
    cls="$cls$PF_CAT	$p
"
    case $PF_CAT in
      MIG) n_mig=$((n_mig + 1)) ;;
      MODEL) n_model=$((n_model + 1)) ;;
      SECRET) n_secret=$((n_secret + 1)) ;;
      ENV) n_env=$((n_env + 1)) ;;
      DEPS) [ "$PF_SUB" = manifest ] && manifests="$manifests$p
" ;;
    esac
  done <<EOF
$changed
EOF

  printf '\n### 변경 파일 분류\n'
  if [ -n "$cls" ]; then
    printf '%s' "$cls" | pf_cls_report 15
  else
    printf '(변경 파일 없음)\n'
  fi

  printf '\n### 신호\n'
  sig=0
  if [ "$n_model" -gt 0 ] && [ "$n_mig" = 0 ]; then
    printf -- '- [주의] 모델·스키마 파일 변경 %s개, 마이그레이션 변경 없음 — 누락 여부를 프로젝트의 --check 류 명령으로 확인\n' "$n_model"
    sig=1
  fi
  if [ "$n_mig" -gt 0 ]; then
    printf -- '- [주의] 마이그레이션 변경 %s개 — 적용된 마이그레이션 수정 여부·파괴적 변경(2단계) 확인\n' "$n_mig"
    sig=1
  fi
  if [ "$n_secret" -gt 0 ]; then
    printf -- '- [중단] 비밀 파일 의심 경로가 변경 목록에 있음 — 커밋 대상인지, .gitignore 누락인지 확인\n'
    sig=1
  fi
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    case $m in */*) mdir=${m%/*}/ ;; *) mdir="" ;; esac
    for l in uv.lock poetry.lock Pipfile.lock pnpm-lock.yaml yarn.lock package-lock.json bun.lock bun.lockb \
             Cargo.lock go.sum Gemfile.lock composer.lock; do
      [ -f "$PF_DIR/$mdir$l" ] || continue
      case "
$changed
" in
        *"
$mdir$l
"*) ;;
        *) printf -- '- [확인] %s 변경, %s 변경 없음 — 의존성을 바꿨다면 lockfile 동기화 필요\n' "$m" "$mdir$l"; sig=1 ;;
      esac
    done
  done <<EOF
$manifests
EOF
  [ "$sig" = 0 ] && printf '(특이 신호 없음)\n'

  # 추가된 줄: 환경 변수 참조와 시크릿 후보
  triaged=$(pf_added_lines | pf_triage)
  printf '\n### 환경 변수 (추가된 줄 기준)\n'
  env_cand=$(pf_tag E "$triaged")
  env_keys=$(printf '%s\n' "$env_cand" | pf_env_refs)
  set_keys=$(printf '%s\n' "$env_cand" | pf_settings_refs)
  pf_example_files
  ex_keys=$(pf_example_keys)
  ignore_re='^(NODE_ENV|PATH|HOME|USER|PWD|SHELL|LANG|TZ|CI|TMPDIR|HOSTNAME)$'
  if [ -z "$env_keys" ] && [ -z "$set_keys" ]; then
    printf '(새 환경 변수 참조 없음)\n'
  elif [ -z "$PF_EXAMPLE_FILES" ]; then
    [ -n "$env_keys" ] && printf -- '- 참조 키: %s\n' "$(printf '%s\n' "$env_keys" | pf_join)"
    [ -n "$set_keys" ] && printf -- '- settings 참조: %s\n' "$(printf '%s\n' "$set_keys" | pf_join)"
    printf -- '- 환경 예시 파일(.env.example 등) 없음 — 새 키 문서화 위치 확인\n'
  else
    if [ -n "$env_keys" ]; then
      printf -- '- 참조 키: %s\n' "$(printf '%s\n' "$env_keys" | pf_join)"
      miss=$(LC_ALL=C comm -23 <(printf '%s\n' "$env_keys" | grep -vE "$ignore_re") <(printf '%s\n' "$ex_keys") | pf_join)
      if [ -n "$miss" ]; then
        printf -- '- [확인] %s에 없는 키: %s\n' "$PF_EXAMPLE_FILES" "$miss"
      else
        printf -- '- %s와 동기화됨\n' "$PF_EXAMPLE_FILES"
      fi
    fi
    if [ -n "$set_keys" ]; then
      miss=$(LC_ALL=C comm -23 <(printf '%s\n' "$set_keys") <(printf '%s\n' "$ex_keys") | pf_join)
      [ -n "$miss" ] && printf -- '- settings 참조 중 %s에 없는 키(환경 변수가 아닐 수 있음): %s\n' "$PF_EXAMPLE_FILES" "$miss"
    fi
  fi

  printf '\n### 시크릿 스캔 (추가된 줄, 위치만 표시)\n'
  hits=$(pf_secret_scan "$(pf_tag S "$triaged")")
  if [ -n "$hits" ]; then
    printf -- '- [중단] 비밀 값 후보 발견 — 값을 출력하지 말고 사용자에게 위치만 보고\n'
    pf_cap "$hits" "" 30
  else
    printf '(발견 없음)\n'
  fi
  if printf '%s\n' "$triaged" | grep -qx 'T'; then
    printf -- '- 참고: 추가된 줄이 20000줄을 넘어 앞부분만 검사함\n'
  fi
else
  printf '(git 저장소 아님 — 변경 분석 생략, 명령·스택만 표시)\n'
fi

printf '\n### 프로젝트 명령 (CLAUDE.md "## 명령어")\n'
cmds=$(pf_claude_commands)
if [ -n "$cmds" ]; then
  printf '%s\n' "$cmds"
else
  printf '(CLAUDE.md에 "## 명령어" 코드블록 없음 — 스택 기본값을 제안하고 확인받을 것)\n'
fi
hints=$(pf_cmd_hints)
[ -n "$hints" ] && printf '%s\n' "$hints"

printf '\n### 감지된 스택\n'
ds="$HOME/.claude/hooks/lib/detect-stack.sh"
if [ -f "$ds" ]; then
  stack=$(bash "$ds" "$PF_DIR" 2>/dev/null | tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//')
  printf '%s\n' "${stack:-(감지된 스택 없음)}"
else
  printf '(detect-stack 없음)\n'
fi
exit 0
