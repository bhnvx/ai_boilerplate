#!/usr/bin/env bash
# dev_settings — install/apply 테스트 실행기. 각 스위트를 /bin/bash(3.2) 로 실행하고 PASS/FAIL/SKIP 을 합산한다.
# 사용법: tests/install/run.sh            (환경: DEV_SETTINGS_TEST_REPO, KEEP_TMP, BASH 로 다른 bash 지정 가능)
# 종료 코드: FAIL 이 하나라도 있으면 1.

HERE=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
REPO=${DEV_SETTINGS_TEST_REPO:-$(cd -P -- "$HERE/../.." && pwd -P)}
BASH_BIN=${BASH:-/bin/bash}
[ -x "$BASH_BIN" ] || BASH_BIN=/bin/bash
export DEV_SETTINGS_IN_TESTS=1
TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_SKIP=0; SUITE_FAIL=0

run_suite() {  # <script>
  local out rc line p f s
  out=$("$BASH_BIN" "$HERE/$1" 2>&1); rc=$?
  printf '%s\n' "$out" | grep -vE '^PASS '
  line=$(printf '%s\n' "$out" | grep -E '^RESULT PASS=' | tail -1)
  if [ -z "$line" ]; then
    printf 'FAIL %s: 결과 줄 없음(비정상 종료 %d)\n' "$1" "$rc"; SUITE_FAIL=$((SUITE_FAIL + 1)); return 0
  fi
  p=${line#*PASS=}; p=${p%% *}; f=${line#*FAIL=}; f=${f%% *}; s=${line#*SKIP=}
  TOTAL_PASS=$((TOTAL_PASS + p)); TOTAL_FAIL=$((TOTAL_FAIL + f)); TOTAL_SKIP=$((TOTAL_SKIP + s))
  [ "$rc" -eq 0 ] || SUITE_FAIL=$((SUITE_FAIL + 1))
}

echo "== tests/install ($BASH_BIN; repo: $REPO) =="
for s in test-install.sh test-install-upgrade.sh test-install-edge.sh test-install-safety.sh test-apply.sh test-apply-edge.sh; do
  echo "--- $s ---"
  run_suite "$s"
done

echo "--- (16) validate.sh --repo --quiet ---"
if [ -f "$REPO/scripts/validate.sh" ] && [ ! -f "$REPO/claude/global/hooks/run-hook.sh" ]; then
  echo "SKIP validate --repo — claude/global/hooks/run-hook.sh 미작성(훅 경로 검사가 FAIL 함)"; TOTAL_SKIP=$((TOTAL_SKIP + 1))
elif [ -f "$REPO/scripts/validate.sh" ]; then
  if (cd "$REPO" && "$BASH_BIN" scripts/validate.sh --repo --quiet > "${TMPDIR:-/tmp}/dev_settings.validate.$$" 2>&1); then
    echo "PASS validate --repo --quiet exit 0"; TOTAL_PASS=$((TOTAL_PASS + 1))
  else
    echo "FAIL validate --repo --quiet"; grep -E '^FAIL' "${TMPDIR:-/tmp}/dev_settings.validate.$$" | head -10
    TOTAL_FAIL=$((TOTAL_FAIL + 1)); SUITE_FAIL=$((SUITE_FAIL + 1))
  fi
  rm -f "${TMPDIR:-/tmp}/dev_settings.validate.$$"
else
  echo "SKIP validate --repo — scripts/validate.sh 없음"; TOTAL_SKIP=$((TOTAL_SKIP + 1))
fi

printf '== tests/install 합계: PASS %d · FAIL %d · SKIP %d ==\n' "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_SKIP"
[ "$TOTAL_FAIL" -eq 0 ] && [ "$SUITE_FAIL" -eq 0 ]
