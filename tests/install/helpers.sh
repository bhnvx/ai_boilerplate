#!/usr/bin/env bash
# ai_boilerplate — install/apply 테스트 공용 헬퍼 (bash 3.2). 소스하는 쪽이 REPO 를 쓸 수 있다.
# 환경: AI_BOILERPLATE_TEST_REPO=<dir> 로 다른 저장소 사본을 대상으로 실행 가능(기본: 이 저장소).
#       KEEP_TMP=1 이면 임시 디렉터리를 남긴다.

HELPERS_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO=${AI_BOILERPLATE_TEST_REPO:-$(cd -P -- "$HELPERS_DIR/../.." && pwd -P)}
T_PASS=0; T_FAIL=0; T_SKIP=0
TROOT=$(mktemp -d "${TMPDIR:-/tmp}/ai_boilerplate test.XXXXXX") || { echo "임시 디렉터리 생성 실패" >&2; exit 1; }
OUT="$TROOT/out.txt"; RC=0; HOME_N=0
export AI_BOILERPLATE_IN_TESTS=1
cleanup() { [ "${KEEP_TMP:-0}" = 1 ] || rm -rf -- "$TROOT"; }
trap cleanup EXIT

pass() { T_PASS=$((T_PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { T_FAIL=$((T_FAIL + 1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
skip() { T_SKIP=$((T_SKIP + 1)); printf 'SKIP %s%s\n' "$1" "${2:+ — $2}"; }

# 저장소에 의존 파일이 있으면 0. 없으면 SKIP 을 찍고 1.
need() {  # <name> <repo-relative path>...
  local name="$1"; shift
  local p
  for p in "$@"; do
    [ -e "$REPO/$p" ] || { skip "$name" "의존 파일 없음: $p"; return 1; }
  done
  return 0
}

assert_true() {  # <name> <cmd...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}
assert_eq() {  # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "기대 [$2] 실제 [$3]"; fi
}
assert_file() { if [ -f "$2" ]; then pass "$1"; else fail "$1" "파일 없음: $2"; fi; }
assert_no_file() { if [ ! -e "$2" ]; then pass "$1"; else fail "$1" "파일이 있음: $2"; fi; }
assert_exec() { if [ -x "$2" ]; then pass "$1"; else fail "$1" "실행 권한 없음: $2"; fi; }
assert_contains() {  # <name> <file> <needle>
  if grep -qF -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1" "[$3] 없음 (파일 $2)"; fi
}
assert_not_contains() {
  if grep -qF -- "$3" "$2" 2>/dev/null; then fail "$1" "[$3] 가 있음 (파일 $2)"; else pass "$1"; fi
}
assert_matches() {  # <name> <file> <ERE>  (계획 줄처럼 공백 패딩이 있는 출력용)
  if grep -qE -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1" "/$3/ 없음 (파일 $2)"; fi
}
assert_same() {  # <name> <file a> <file b>
  if cmp -s -- "$2" "$3"; then pass "$1"; else fail "$1" "내용이 다름: $2 vs $3"; fi
}
count_lines() { grep -c '' -- "$1" 2>/dev/null || printf 0; }

# 공백이 들어간 새 홈 디렉터리를 만들고 NEW_HOME 에 담는다(서브셸을 피해 카운터를 유지).
new_home() {
  HOME_N=$((HOME_N + 1))
  NEW_HOME="$TROOT/home $HOME_N dir"
  mkdir -p -- "$NEW_HOME"
}

# apply.sh 종료 코드 확인(--with-format-hook 용): 0 → PASS; 3 은 훅 소스가 아직 없을 때만 SKIP.
assert_apply_ok() {  # <name>
  if [ "$RC" = 0 ]; then pass "$1"
  elif [ "$RC" = 3 ] && [ ! -f "$REPO/claude/global/hooks/run-hook.sh" ]; then
    skip "$1" "validate FAIL — claude/global/hooks/run-hook.sh 미작성 상태(종료 코드 3)"
  else fail "$1" "종료 코드 $RC: $(grep -E '^(FAIL|오류)' "$OUT" | head -3 | tr '\n' ' ')"; fi
}

# install.sh 종료 코드 확인: 0 → PASS; 3(validate FAIL) 은 훅 소스가 아직 없을 때만 SKIP; 그 외 FAIL.
assert_install_ok() {  # <name>
  if [ "$RC" = 0 ]; then pass "$1"
  elif [ "$RC" = 3 ] && { [ ! -d "$REPO/claude/global/hooks" ] || [ ! -f "$REPO/scripts/validate.sh" ]; }; then
    skip "$1" "validate FAIL — claude/global/hooks 미작성 상태(종료 코드 3)"
  else fail "$1" "종료 코드 $RC: $(grep -E '^(FAIL|오류)' "$OUT" | head -3 | tr '\n' ' ')"; fi
}

# 디렉터리 전체의 (상대경로, cksum) 스냅샷을 파일로 저장.
snapshot() {  # <dir> <out-file>
  : > "$2"
  [ -d "$1" ] || return 0
  (cd -P -- "$1" && find . -type f -print | LC_ALL=C sort) | while IFS= read -r f; do
    printf '%s\t%s\n' "$f" "$(cksum < "$1/$f" | awk '{print $1}')" >> "$2"
  done
}

# stdin 은 항상 /dev/null(비대화형): 확인이 필요한 작업은 --yes 없이는 종료 코드 2 가 나야 하고, 터미널에서도 멈추지 않는다.
run_install() {  # <home> [args...]  → OUT, RC
  local home="$1"; shift
  /bin/bash "$REPO/install.sh" --home "$home" "$@" > "$OUT" 2>&1 < /dev/null; RC=$?
  return 0
}

run_apply() {  # <home> <project> [args...]  → OUT, RC  (HOME 을 바꿔 실행)
  local home="$1" proj="$2"; shift 2
  HOME="$home" /bin/bash "$REPO/apply.sh" "$proj" "$@" > "$OUT" 2>&1 < /dev/null; RC=$?
  return 0
}

# python3 로 JSON 질의. 실패 시 빈 문자열.  usage: jq_py <file> <python expr using d>
jq_py() {
  python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
r=eval(sys.argv[2])
print(json.dumps(r, ensure_ascii=False) if not isinstance(r,(str,int,float,bool)) else r)' "$1" "$2" 2>/dev/null
}

# settings.json 의 모든 command 훅 명령을 개행 구분으로 출력.
hook_commands() {
  python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
for ev,groups in (d.get("hooks") or {}).items():
    for g in groups:
        for h in g.get("hooks") or []:
            print(ev+"\t"+str(h.get("command","")))' "$1" 2>/dev/null
}

t_report() {  # <suite-name>
  printf '%s: PASS %d · FAIL %d · SKIP %d\n' "$1" "$T_PASS" "$T_FAIL" "$T_SKIP"
  printf 'RESULT PASS=%d FAIL=%d SKIP=%d\n' "$T_PASS" "$T_FAIL" "$T_SKIP"
  [ "$T_FAIL" -eq 0 ]
}
