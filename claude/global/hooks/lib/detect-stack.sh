#!/usr/bin/env bash
# lib/detect-stack.sh — 디렉터리의 언어·프레임워크 스택 감지 (bash 3.2 호환, 순수 bash + grep, python 불필요)
# 실행: detect-stack.sh <dir>   → 공백 구분 토큰 한 줄(감지 없으면 출력 없음). 항상 exit 0.
# source: . lib/detect-stack.sh; detect_stack <dir>  → 전역 DETECT_STACK 에 같은 토큰 문자열(fork 최소화용)
# 토큰 순서: python [uv|poetry|pipenv|pip] django fastapi node [pnpm|yarn|bun|npm] typescript react next
#            go rust ruby php java dotnet docker
# 하위 디렉터리는 보지 않는다(주어진 디렉터리만). 사용처: session-context, apply.sh(--profile auto, 생략 시 안내),
#   harness-init·preflight 스킬 context.sh.
# 의존성은 "의존성 모양"일 때만 인정한다(# 주석 줄·설명 문구·npm 스크립트 이름은 무시):
#   python: 줄 맨 앞 이름(requirements·setup.cfg·TOML 키 django = …) 또는 따옴표로 시작하는 PEP 508 문자열("Django>=5")
#   package.json: "react"|"next"|"typescript" 키의 값이 버전·범위·태그·프로토콜(^ ~ 숫자 * workspace: npm: latest …)

DETECT_STACK=""

# 내부: 토큰 추가
__ds_add() { DETECT_STACK="${DETECT_STACK:+$DETECT_STACK }$1"; }

# 내부: 디렉터리 안에 glob 에 맞는 파일이 하나라도 있으면 0 (nullglob 없이 안전)
__ds_any() {
  local f
  for f in "$@"; do [ -e "$f" ] && return 0; done
  return 1
}

detect_stack() {
  local d=${1:-.} f m l py_files node_mgr pkg="" py_hit="" has_py=0 py_uv=0 py_poetry=0 py_dj=0 py_fa=0
  # 이름 뒤: 공백 후 버전 연산자·extras·마커·URL(@)·구분자·닫는 따옴표 또는 줄 끝. 앞: 줄 머리(공백 허용) 또는 따옴표
  local re_dj='(^[[:space:]]*|["'"'"'])django[[:space:]]*([<>=~!;[,@"'"'"']|$)'
  local re_fa='(^[[:space:]]*|["'"'"'])fastapi[[:space:]]*([<>=~!;[,@"'"'"']|$)'
  DETECT_STACK=""
  d=${d%/}; [ -n "$d" ] || d=/
  [ -d "$d" ] || return 0

  # --- Python -------------------------------------------------------------
  py_files=()
  for f in "$d/pyproject.toml" "$d/Pipfile" "$d/setup.cfg" "$d"/requirements*.txt "$d"/requirements/*.txt; do
    [ -f "$f" ] && py_files[${#py_files[@]}]=$f
  done
  if [ ${#py_files[@]} -gt 0 ] || __ds_any "$d/setup.py" "$d/uv.lock" "$d/poetry.lock" "$d/Pipfile.lock" "$d/manage.py"; then
    has_py=1
  fi
  if [ "$has_py" = 1 ]; then
    if [ ${#py_files[@]} -gt 0 ]; then
      # grep 1회 + tr 1회: [tool.uv / [tool.poetry 섹션 줄과, 주석(#) 앞에 django/fastapi 가 있는 줄(소문자로)
      py_hit=$(LC_ALL=C grep -Eih -- '^\[tool\.(uv|poetry)|^[^#]*(django|fastapi)' \
        ${py_files[@]+"${py_files[@]}"} 2>/dev/null | LC_ALL=C tr '[:upper:]' '[:lower:]')
      while IFS= read -r l; do
        l=${l%$'\r'}
        case $l in
          '[tool.uv]'*|'[tool.uv.'*) py_uv=1; continue ;;
          '[tool.poetry]'*|'[tool.poetry.'*) py_poetry=1; continue ;;
        esac
        l=${l%%#*}
        [[ $l =~ $re_dj ]] && py_dj=1
        [[ $l =~ $re_fa ]] && py_fa=1
      done <<DS_EOF
$py_hit
DS_EOF
    fi
    __ds_add python
    m=""
    if [ -e "$d/uv.lock" ]; then m=uv
    elif [ -e "$d/poetry.lock" ]; then m=poetry
    elif [ "$py_uv" = 1 ]; then m=uv
    elif [ "$py_poetry" = 1 ]; then m=poetry
    fi
    if [ -z "$m" ]; then
      if __ds_any "$d/Pipfile" "$d/Pipfile.lock"; then m=pipenv
      elif __ds_any "$d"/requirements*.txt "$d"/requirements/*.txt; then m=pip
      fi
    fi
    [ -n "$m" ] && __ds_add "$m"
    if [ -e "$d/manage.py" ] || [ "$py_dj" = 1 ]; then __ds_add django; fi
    [ "$py_fa" = 1 ] && __ds_add fastapi
  fi

  # --- Node ---------------------------------------------------------------
  if [ -f "$d/package.json" ]; then
    __ds_add node
    node_mgr=""
    if __ds_any "$d/pnpm-lock.yaml" "$d/pnpm-workspace.yaml"; then node_mgr=pnpm
    elif [ -e "$d/yarn.lock" ]; then node_mgr=yarn
    elif __ds_any "$d/bun.lockb" "$d/bun.lock"; then node_mgr=bun
    elif __ds_any "$d/package-lock.json" "$d/npm-shrinkwrap.json"; then node_mgr=npm
    fi
    # grep 1회: packageManager 필드 + 값이 버전 모양인 react / next / typescript 키(스크립트 "next": "next dev" 제외)
    pkg=$(LC_ALL=C grep -Eo -- '"packageManager"[[:space:]]*:[[:space:]]*"[a-z]+|"(react|next|typescript)"[[:space:]]*:[[:space:]]*"([~^0-9*<>="]|v[0-9]|(workspace|npm|file|link|portal|patch|catalog|jsr|github|git|git\+[a-z]+|https?):|(latest|next|canary|beta|rc|alpha|experimental)")' \
      "$d/package.json" 2>/dev/null)
    if [ -z "$node_mgr" ]; then
      case $pkg in
        *'"packageManager"'*'"pnpm'*) node_mgr=pnpm ;;
        *'"packageManager"'*'"yarn'*) node_mgr=yarn ;;
        *'"packageManager"'*'"bun'*)  node_mgr=bun ;;
        *'"packageManager"'*'"npm'*)  node_mgr=npm ;;
      esac
    fi
    [ -n "$node_mgr" ] && __ds_add "$node_mgr"
  fi
  if [ -e "$d/tsconfig.json" ]; then __ds_add typescript
  else case $pkg in *'"typescript"'*) __ds_add typescript ;; esac
  fi
  case $pkg in *'"react"'*) __ds_add react ;; esac
  case $pkg in *'"next"'*) __ds_add next ;; esac

  # --- 기타 언어 / 런타임 ------------------------------------------------------
  [ -e "$d/go.mod" ] && __ds_add go
  [ -e "$d/Cargo.toml" ] && __ds_add rust
  [ -e "$d/Gemfile" ] && __ds_add ruby
  [ -e "$d/composer.json" ] && __ds_add php
  __ds_any "$d/pom.xml" "$d/build.gradle" "$d/build.gradle.kts" "$d/settings.gradle" "$d/settings.gradle.kts" && __ds_add java
  __ds_any "$d"/*.csproj "$d"/*.fsproj "$d"/*.sln "$d/global.json" && __ds_add dotnet
  __ds_any "$d/Dockerfile" "$d"/*.Dockerfile "$d/compose.yaml" "$d/compose.yml" \
    "$d/docker-compose.yml" "$d/docker-compose.yaml" && __ds_add docker
  return 0
}

# 직접 실행된 경우에만 출력(source 된 경우는 함수만 정의)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  detect_stack "${1:-.}"
  [ -n "$DETECT_STACK" ] && printf '%s\n' "$DETECT_STACK"
  exit 0
fi
