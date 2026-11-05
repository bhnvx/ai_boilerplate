#!/usr/bin/env bash
# run-hook.sh <name> [args...] — 훅 런처. stdin/stdout 은 그대로 전달하고 종료 코드는 항상 0.
# 이유: 훅 파일에 문법 오류가 있으면 bash 가 exit 2 로 끝나고, PreToolUse 에서는 그것이 모든 도구를
#       차단한다. 우리 훅은 결정을 stdout JSON 으로만 내리므로 비 0 종료를 0 으로 바꿔도 잃는 것이 없다.
# CLAUDE_HOOKS_DISABLE=1 → 즉시 exit 0 (전체 끄기). CLAUDE_HOOKS_DEBUG=1 → stderr 진단 1줄.
# 훅 파일은 심볼릭 링크가 아닌 복사본으로 설치한다(install.sh).
[ "${CLAUDE_HOOKS_DISABLE:-}" = "1" ] && exit 0
name=${1:-}
case $name in ''|*/*|.*) exit 0 ;; esac
shift
dir=$(cd -P -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) || exit 0
hook="$dir/$name.sh"
if [ ! -r "$hook" ]; then
  [ "${CLAUDE_HOOKS_DEBUG:-}" = "1" ] && printf 'run-hook: 훅 파일 없음: %s\n' "$hook" >&2
  exit 0
fi
"${BASH:-bash}" "$hook" "$@"
rc=$?
if [ "${CLAUDE_HOOKS_DEBUG:-}" = "1" ] && [ "$rc" -ne 0 ]; then
  printf 'run-hook: %s 종료 코드 %s → 0 으로 처리\n' "$name" "$rc" >&2
fi
exit 0
