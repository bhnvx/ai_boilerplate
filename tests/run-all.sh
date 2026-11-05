#!/usr/bin/env bash
# dev_settings 전체 테스트 실행기.
# - tests/hooks/test-*.sh 를 /bin/bash(3.2)로 한 번, PATH의 다른 bash(예: brew bash 5)가 있으면 그것으로 한 번 더
# - tests/skills/test-*.sh 를 같은 방식으로
# - tests/install/run.sh 를 /bin/bash로 한 번
# - scripts/merge-settings.py --selftest
# 결과 요약을 출력하고 하나라도 실패하면 exit 1.
#
# usage: tests/run-all.sh [--quick] [--filter <부분문자열>] [--verbose]
#   --quick    추가 bash 실행 생략(/bin/bash만)
#   --filter   이름에 부분문자열이 들어간 스위트만 실행(selftest 포함 여부도 이름으로 판단)
#   --verbose  성공한 스위트의 출력도 모두 표시
# 환경: DEV_SETTINGS_IN_TESTS=1 을 내보내 scripts/validate.sh --repo 가 이 실행기를 재귀 호출하지 않게 한다.

ROOT=$(cd -P -- "$(dirname -- "$0")/.." && pwd -P) || exit 1
cd "$ROOT" || exit 1
export DEV_SETTINGS_IN_TESTS=1

quick=0 filter='' verbose=0
while [ $# -gt 0 ]; do
  case $1 in
    --quick) quick=1 ;;
    --filter) [ $# -gt 1 ] || { echo 'run-all.sh: --filter 값 없음' >&2; exit 2; }; filter=$2; shift ;;
    --verbose) verbose=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) printf 'run-all.sh: 알 수 없는 인수: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

BASE_BASH=/bin/bash
[ -x "$BASE_BASH" ] || BASE_BASH=$(command -v bash)
base_ver=$("$BASE_BASH" -c 'echo "$BASH_VERSION"')

# 두 번째 bash: PATH에서 /bin/bash와 버전이 다른 첫 번째 bash
EXTRA_BASH=''
if [ "$quick" = 0 ]; then
  for b in $(type -ap bash 2>/dev/null); do
    [ -x "$b" ] || continue
    v=$("$b" -c 'echo "$BASH_VERSION"' 2>/dev/null) || continue
    if [ -n "$v" ] && [ "$v" != "$base_ver" ]; then EXTRA_BASH=$b; extra_ver=$v; break; fi
  done
fi

LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dev_settings-tests.XXXXXX") || exit 1
trap 'rm -rf "$LOG_DIR"' EXIT
trap 'exit 130' INT TERM

pass=0 fail=0 n=0
failed_names=''

want() { # want <이름>
  [ -z "$filter" ] && return 0
  case $1 in *"$filter"*) return 0 ;; esac
  return 1
}

run_suite() { # run_suite <표시 이름> <명령...>
  label=$1; shift
  n=$((n + 1))
  log="$LOG_DIR/suite-$n.log"
  start=$(date +%s)
  "$@" >"$log" 2>&1 </dev/null
  rc=$?
  secs=$(( $(date +%s) - start ))
  last=$(grep -v '^[[:space:]]*$' "$log" | tail -n 1)
  if [ "$rc" -eq 0 ]; then
    pass=$((pass + 1))
    printf 'PASS %-48s %3ss  %s\n' "$label" "$secs" "$last"
    [ "$verbose" = 1 ] && sed 's/^/    /' "$log"
  else
    fail=$((fail + 1))
    failed_names="$failed_names
  - $label (exit $rc)"
    printf 'FAIL %-48s %3ss  exit %s\n' "$label" "$secs" "$rc"
    echo '    ---- 출력(마지막 40줄) ----'
    tail -n 40 "$log" | sed 's/^/    /'
  fi
}

missing_suite() { # missing_suite <표시 이름>
  n=$((n + 1)); fail=$((fail + 1))
  failed_names="$failed_names
  - $1 (파일 없음)"
  printf 'FAIL %-48s       파일 없음\n' "$1"
}

echo "dev_settings 테스트 · bash $base_ver ($BASE_BASH)${EXTRA_BASH:+ + bash $extra_ver ($EXTRA_BASH)}"

# 1) 훅 스위트
found=0
for t in tests/hooks/test-*.sh; do
  [ -f "$t" ] || continue
  found=1
  want "$t" || continue
  run_suite "$t [bash ${base_ver%%(*}]" "$BASE_BASH" "$t"
  if [ -n "$EXTRA_BASH" ]; then
    run_suite "$t [bash ${extra_ver%%(*}]" "$EXTRA_BASH" "$t"
  fi
done
if [ "$found" = 0 ] && want tests/hooks/test-; then
  missing_suite 'tests/hooks/test-*.sh'
fi

# 1b) 스킬 스위트
found_sk=0
for t in tests/skills/test-*.sh; do
  [ -f "$t" ] || continue
  found_sk=1
  want "$t" || continue
  run_suite "$t [bash ${base_ver%%(*}]" "$BASE_BASH" "$t"
  if [ -n "$EXTRA_BASH" ]; then
    run_suite "$t [bash ${extra_ver%%(*}]" "$EXTRA_BASH" "$t"
  fi
done
if [ "$found_sk" = 0 ] && want tests/skills/test-; then
  missing_suite 'tests/skills/test-*.sh'
fi

# 2) 설치 스위트
if want tests/install/run.sh; then
  if [ -f tests/install/run.sh ]; then
    run_suite "tests/install/run.sh [bash ${base_ver%%(*}]" "$BASE_BASH" tests/install/run.sh
  else
    missing_suite tests/install/run.sh
  fi
fi

# 3) merge-settings selftest
if want merge-settings; then
  if [ ! -f scripts/merge-settings.py ]; then
    missing_suite 'scripts/merge-settings.py --selftest'
  elif ! command -v python3 >/dev/null 2>&1; then
    missing_suite 'scripts/merge-settings.py --selftest (python3 없음)'
  else
    run_suite 'scripts/merge-settings.py --selftest' python3 scripts/merge-settings.py --selftest
  fi
fi

echo "----"
if [ "$n" -eq 0 ]; then
  echo "실행한 스위트 없음 (--filter '$filter')"
  exit 1
fi
if [ "$fail" -gt 0 ]; then
  printf '요약: 스위트 %s개 중 PASS %s · FAIL %s%s\n' "$n" "$pass" "$fail" "$failed_names"
  exit 1
fi
printf '요약: 스위트 %s개 모두 PASS\n' "$n"
exit 0
