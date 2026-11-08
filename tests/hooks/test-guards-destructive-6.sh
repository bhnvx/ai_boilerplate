#!/usr/bin/env bash
# tests/hooks/test-guards-destructive-6.sh — guard-destructive.sh 3b 회귀 테스트
# (I8 find -exec 셸 문자열: 깊이 0 시작 디렉터리도 판단 · 선형·유계 지연(작업량 상한) · 파서 문자열 수 불일치 되돌림 ·
#  I4 make -e 불리언 옵션 · I1–I7/I9 독립 점검의 완화 경계 핀 — r2b 보다 약해지지 않는지)
# 명령 문자열은 훅의 stdin JSON 으로만 전달되며 실행되지 않는다. 큰 명령은 파일로 만들어 넘긴다.
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
t_setup
HOOK="$T_HOOKS/guard-destructive.sh"
unset CLAUDE_GUARD_PROTECTED_BRANCHES CLAUDE_GUARD_ASK_ON_PUSH CLAUDE_GUARD_ALLOW_PATTERNS
run() { t_run_hook "$HOOK" "$1"; }
tj() {  # <tool> <cmd> [cwd] [mode] → PreToolUse JSON (Bash 와 Monitor 는 같은 command 입력)
  if [ "$1" = Bash ]; then t_bash_json "$2" "${3:-}" "${4:-}"
  else t_pre_json "$1" "{\"command\":$(t_json_str "$2")}" "${3:-}" "${4:-}"; fi
}
trs() { assert_contains "$1" "$(t_reason "$T_OUT")" "$2"; }
tt() {  # <name> <none|ask-low|ask-high|deny> <cmd> [cwd] [tool] — ask 이면 auto 로 다시 실행해 티어를 가른다
  local d a got out tool=${5:-Bash}
  run "$(tj "$tool" "$3" "${4:-}")"; out=$T_OUT; d=$(t_decision "$out"); got=$d
  if [ "$d" = ask ]; then
    run "$(tj "$tool" "$3" "${4:-}" auto)"; a=$(t_decision "$T_OUT")
    case $a in none) got=ask-low ;; ask) got=ask-high ;; *) got="ask/$a" ;; esac
  fi
  T_OUT=$out
  assert_eq "$1" "$2" "$got"
}
ts() {  # <name> <allow|deny|ask|none> <cmd> [cwd] — 서브에이전트(agent_id) 결정(원시값)
  run "$(t_bash_json "$3" "${4:-}" default '{"agent_id":"a1","agent_type":"implementer"}')"
  assert_eq "$1" "$2" "$(t_decision "$T_OUT")"
}
ttf() {  # <name> <expect> <cmd-file> — 큰 명령(파일)용 tt
  local d a got out
  run "$(t_bash_json_file "$3")"; out=$T_OUT; d=$(t_decision "$out"); got=$d
  if [ "$d" = ask ]; then
    run "$(t_bash_json_file "$3" "" auto)"; a=$(t_decision "$T_OUT")
    case $a in none) got=ask-low ;; ask) got=ask-high ;; *) got="ask/$a" ;; esac
  fi
  T_OUT=$out
  assert_eq "$1" "$2" "$got"
}
t_ms() {
  if command -v python3 >/dev/null 2>&1; then python3 -I -S -c 'import time; print(int(time.time()*1000))'
  elif command -v perl >/dev/null 2>&1; then perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'
  else echo 0; fi
}
t_under() { [ "$2" -lt "$3" ] && t_pass "$1 (${2}ms < ${3}ms)" || t_fail "$1" "${2}ms ≥ ${3}ms"; }
mkfind() {  # <kind> <N> [M] → $T_TMP/find.txt. 큰 find -exec 셸 문자열(실행되지 않음). 역슬래시로 넣은 " $ 는 파일에 글자 그대로 남는다
  local i n=$2 m=${3:-0} s=""
  case $1 in
    dirsargs)   s="find"; i=0; while [ "$i" -lt "$n" ]; do s="$s d$i"; i=$((i + 1)); done
      s="$s -exec sh -c 'rm -rf \"\$@\"' _"; i=0; while [ "$i" -lt "$m" ]; do s="$s {}"; i=$((i + 1)); done; s="$s \\;" ;;
    groups)     s="find . -name x"; i=0; while [ "$i" -lt "$n" ]; do s="$s -exec sh -c 'rm -rf \"\$1\"' _ {} \\;"; i=$((i + 1)); done ;;
    words_targets) s="find . -name x"; i=0; while [ "$i" -lt "$n" ]; do s="$s -o -name a$i"; i=$((i + 1)); done
      s="$s -exec sh -c 'rm -rf"; i=0; while [ "$i" -lt "$m" ]; do s="$s \"\$1\""; i=$((i + 1)); done; s="$s' _ {} \\;" ;;
    dirs_groups) s="find"; i=0; while [ "$i" -lt "$n" ]; do s="$s d$i"; i=$((i + 1)); done
      i=0; while [ "$i" -lt "$m" ]; do s="$s -exec sh -c 'rm -rf \"\$1\"' _ {} \\;"; i=$((i + 1)); done ;;
    targets_args|targets_argsf|targets_at)   # 한 그룹 안의 위치 매개변수 대상 N개 × {} 인수 M개(대상마다 인수 전체를 다시 읽으면 N×M)
      local rmo='rm -rf' pv='$1'; [ "$1" = targets_argsf ] && rmo='rm -f'; [ "$1" = targets_at ] && pv='$@'
      s="find . -exec sh -c '$rmo"; i=0; while [ "$i" -lt "$n" ]; do s="$s \"$pv\""; i=$((i + 1)); done
      s="$s' _"; i=0; while [ "$i" -lt "$m" ]; do s="$s {}"; i=$((i + 1)); done; s="$s \\;" ;;
    dirs_rmf)   s="find"; i=0; while [ "$i" -lt "$n" ]; do s="$s d$i"; i=$((i + 1)); done   # 시작 디렉터리 N개 × 비재귀 rm -f "$1"
      s="$s -exec sh -c 'rm -f \"\$1\"' _ {} \\;" ;;
    strs_rm)    s="rm -rf ~"; i=0; while [ "$i" -lt "$n" ]; do s="$s; sh -c 'true'"; i=$((i + 1)); done ;;   # 명령 문자열 N개(앞에 sentinel)
  esac
  printf '%s' "$s" > "$T_TMP/find.txt"
}

t_section "I8(3b): find 는 -mindepth N(N≥1) 이 없으면 시작 디렉터리 자체(깊이 0)도 넘긴다 → {} 는 <시작>+<시작>/x 로 판단"
# 시작 디렉터리가 루트·시스템·홈·상위(..)이면 그 자체를 지우는 것과 같아 deny(rm -rf / · /tmp · ~/projects · ./* · ../* 와 같음)
for c in "find / -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" "find / -name '*.tmp' -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" \
  "find /tmp -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" "find /Volumes -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" \
  "find ~/projects -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" "find . -exec sh -c 'rm -rf \"\$1\"/*' _ {} \\;" \
  "find .. -exec sh -c 'rm -rf \"\$1\"/*' _ {} \\;" "find / -maxdepth 1 -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" \
  "find / -exec sh -c 'rm -rf \"\$@\"' _ {} +"; do
  tt "I8(3b) deny: $c" deny "$c"; trs "I8(3b) rule id: $c" "[destructive:rm-root]"
done
ts "I8(3b) 서브에이전트 deny: find / … \$1" deny "find / -exec sh -c 'rm -rf \"\$1\"' _ {} \\;"
# 마지막 구성 요소가 . 또는 .. 이면 rm 이 거부하므로 깊이 0 은 건너뛴다 → <시작>/x 만 남아 find -exec rm 과 같은 ask-high 를 유지한다
for c in "find . -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" "find . -name '*.pyc' -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" \
  "find . -type f -exec sh -c 'rm -rf \"\$0\"' {} \\;"; do
  tt "I8(3b) ask-high(. 은 건너뜀): $c" ask-high "$c"; trs "I8(3b) rule id: $c" "[destructive:data-loss-misc]"
done
ts "I8(3b) 서브에이전트 ask: find . … \$1" ask "find . -exec sh -c 'rm -rf \"\$1\"' _ {} \\;"
t_section "I8(3b): -mindepth N(N≥1) 은 시작 디렉터리를 넘기지 않으므로 하위만 판단(ask-high, deny 아님)"
for c in "find . -mindepth 1 -exec sh -c 'rm -rf \"\$1\"/*' _ {} \\;" "find / -mindepth 1 -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" \
  "find / -mindepth 1 -maxdepth 1 -exec sh -c 'rm -rf \"\$1\"' _ {} \\;"; do
  tt "I8(3b) mindepth ask-high: $c" ask-high "$c"; trs "I8(3b) rule id: $c" "[destructive:data-loss-misc]"
done
tt "I8(3b) 직접형 기준: find / -exec rm -rf {} \\; → ask-high" ask-high "find / -exec rm -rf {} \\;"

t_section "I8(3b): 파서가 셈한 셸 문자열 수와 다르면 되돌린다(미확장 위치 매개변수 규칙: rec 면 deny)"
# 대문자 셸 이름(SH): 파서는 셸 문자열로 보지만(소문자화) gd_find_build 의 셈과 달라 되돌린다 → deny
tt "I8(3b) 문자열 수 불일치: find . -exec SH -c … → deny" deny "find . -exec SH -c 'rm -rf \"\$1\"' _ {} \\;"
trs "I8(3b) rule id: SH 불일치" "[destructive:rm-root]"
# 따옴표 친 \"-c\": 3b 파서 수정(uqt)으로 따옴표 없는 -c 와 같게 펼친다 — 시작 디렉터리 . 은 건너뛰고 하위만(ask-high), / 는 깊이 0 판단(deny)
tt "I8(3b) 따옴표 친 -c: find . -exec sh \"-c\" … → ask-high(따옴표 없는 -c 와 같음)" ask-high "find . -exec sh \"-c\" 'rm -rf \"\$1\"' _ {} \\;"
tt "I8(3b) 따옴표 친 -c: find / -exec sh \"-c\" … → deny" deny "find / -exec sh \"-c\" 'rm -rf \"\$1\"' _ {} \\;"
tt "I8(3b) 따옴표 친 -c: find . -exec sh '-c' … → ask-high" ask-high "find . -exec sh '-c' 'rm -rf \"\$1\"' _ {} \\;"
# find 밖의 sh -c · for 루프 · xargs 는 전처럼 deny(위치 매개변수를 못 푼다)
tt "I8(3b) find 밖 sh -c: → deny" deny "sh -c 'rm -rf \"\$1\"' _ x"
tt "I8(3b) for 루프: → deny" deny "find . -name x -exec sh -c 'for f; do rm -rf \"\$f\"; done' _ {} +"

t_section "I8(3b): 긴 find -exec 셸 문자열은 선형·유계 시간(세그먼트마다 표를 한 번만 만들고 판단 횟수에 상한) — <3000 ms"
# 리뷰가 지적한 모양: (1) {} 인수 다수(dirsargs 팬아웃) (2) -exec 그룹 다수(groups) (3) 위치 매개변수 대상 다수(words_targets).
# r3a 는 dirsargs 150×150(≈1.1KB)에서 12 초가 걸려 훅이 fail-open 했다. 새 코드는 같은 패턴을 한 번만 판단하고(dedup) 표를 한 번만 만든다.
mkfind dirsargs 60 60; ttf 'I8(3b) dirsargs 60×60(판단; dedup) → ask-high' ask-high "$T_TMP/find.txt"
t0=$(t_ms); run "$(t_bash_json_file "$T_TMP/find.txt")"; t1=$(t_ms); t_under 'I8(3b) dirsargs 60×60 시간' $((t1 - t0)) 3000
mkfind dirsargs 150 150; ttf 'I8(3b) dirsargs 150×150(≈1.1KB, 상한 초과→되돌림) → deny' deny "$T_TMP/find.txt"
t0=$(t_ms); run "$(t_bash_json_file "$T_TMP/find.txt")"; t1=$(t_ms); t_under 'I8(3b) dirsargs 150×150 시간' $((t1 - t0)) 3000
mkfind groups 40; ttf 'I8(3b) -exec 그룹 40개(표 1회) → ask-high' ask-high "$T_TMP/find.txt"
t0=$(t_ms); run "$(t_bash_json_file "$T_TMP/find.txt")"; t1=$(t_ms); t_under 'I8(3b) 그룹 40개 시간' $((t1 - t0)) 3000
mkfind words_targets 150 30; ttf 'I8(3b) 위치 매개변수 대상 30개 → ask-high' ask-high "$T_TMP/find.txt"
t0=$(t_ms); run "$(t_bash_json_file "$T_TMP/find.txt")"; t1=$(t_ms); t_under 'I8(3b) 대상 30개 시간' $((t1 - t0)) 3000
# 팬아웃(시작 디렉터리 × 그룹)이 명령 전체 상한을 넘으면 원래 규칙(deny)으로 되돌린다. 시간은 세그먼트 파싱에 좌우되므로(r2b 와 공유) 결정만 확인한다
mkfind dirs_groups 60 60; ttf 'I8(3b) dirs_groups 60×60(상한 초과) → deny' deny "$T_TMP/find.txt"
# 3b 검증: 한 그룹 안의 대상 N개 × 인수 M개. 대상마다 인수 전체를 다시 읽으면 N×M 이라 ≈3KB(200×600)에서 25 초 이상, ≈10KB 에서도
# 훅 시간 제한(10 초)을 넘어 fail-open 했다. $N 은 처음 10개 인수에서, $@ 는 그룹마다 한 번 만든 목록에서 읽고, 상한을 다 쓴 뒤의 대상은 인수를 읽지 않는다
mkfind targets_args 200 600; ttf 'I8(3b 검증) 대상 200 × 인수 600($1, 상한 초과) → deny' deny "$T_TMP/find.txt"
t0=$(t_ms); run "$(t_bash_json_file "$T_TMP/find.txt")"; t1=$(t_ms); t_under 'I8(3b 검증) 대상 200 × 인수 600($1) 시간' $((t1 - t0)) 3000
mkfind targets_at 200 600; ttf 'I8(3b 검증) 대상 200 × 인수 600($@, 상한 초과) → deny' deny "$T_TMP/find.txt"
t0=$(t_ms); run "$(t_bash_json_file "$T_TMP/find.txt")"; t1=$(t_ms); t_under 'I8(3b 검증) 대상 200 × 인수 600($@) 시간' $((t1 - t0)) 3000
mkfind targets_argsf 200 600; ttf 'I8(3b 검증) 비재귀 rm -f 대상 200 × 인수 600 → ask-high(상한 초과여도 find -exec rm 과 같게)' ask-high "$T_TMP/find.txt"
trs 'I8(3b 검증) rule id: 비재귀 상한 초과' "[destructive:data-loss-misc]"
t0=$(t_ms); run "$(t_bash_json_file "$T_TMP/find.txt")"; t1=$(t_ms); t_under 'I8(3b 검증) 비재귀 대상 200 × 인수 600 시간' $((t1 - t0)) 3000
# 상한을 넘어 위치 매개변수를 풀지 않아도 비재귀 rm -f 는 none 으로 떨어지지 않는다(r3a 의 find -exec rm 과 같은 ask-high 유지)
mkfind dirs_rmf 110; ttf 'I8(3b 검증) 시작 디렉터리 110 × rm -f "$1"(상한 초과) → ask-high' ask-high "$T_TMP/find.txt"
mkfind dirs_rmf 3; ttf 'I8(3b 검증) 시작 디렉터리 3 × rm -f "$1" → ask-high' ask-high "$T_TMP/find.txt"

t_section "기존 결함(3b 검증): 명령 문자열이 약 250개를 넘어도 bash 3.2 가 죽지 않는다(프로세스 치환 대신 명령 치환 + heredoc)"
# 이전에는 sh -c '…' 마다 < <(sp_segments …) 를 써서 약 255번째에서 bash 3.2 가 종료 133 으로 죽었고, 결정 없이 통과했다(fail-open, 원본부터)
mkfind strs_rm 260; ttf '기존 결함: rm -rf ~ 뒤 sh -c × 260 → deny' deny "$T_TMP/find.txt"; trs '기존 결함 rule id' "[destructive:rm-root]"

t_section "I8(3b 검증): 빈 인수(''·\"\")도 위치를 차지한다 — 건너뛰면 뒤 인수가 당겨져 다른 대상을 판단한다"
# $0 이나 $1 자리의 빈 인수를 버리면 \$1 이 ~·/·홈 대신 그 뒤의 build·x 로 풀려 deny 가 none·ask-low 로 약해졌다(r3a·r2b 는 deny)
for c in "find . -maxdepth 0 -exec sh -c 'rm -rf \"\$1\"' '' ~ build \\;" "find . -maxdepth 0 -exec sh -c 'rm -rf \"\$2\"' _ '' / build \\;" \
  "find . -exec sh -c 'rm -rf \"\$1\"' \"\" ~/projects {} \\;" "find . -execdir bash -c 'rm -rf \"\${1}\"' '' \"\$HOME\" x \\;" \
  "find . -exec sh -c 'rm -rf \"\$1\"/*' _ '' \\;" "bash -c \"find . -maxdepth 0 -exec sh -c 'rm -rf \\\"\\\$1\\\"' '' ~ build \\\\;\""; do
  tt "I8(3b 검증) 빈 인수 deny: $c" deny "$c"; trs "I8(3b 검증) rule id: $c" "[destructive:rm-root]"
done
tt "I8(3b 검증) 빈 인수 deny(Monitor)" deny "find . -maxdepth 0 -exec sh -c 'rm -rf \"\$1\"' '' ~ build \\;" "" Monitor
ts "I8(3b 검증) 서브에이전트 빈 인수 deny" deny "find . -maxdepth 0 -exec sh -c 'rm -rf \"\$1\"' '' ~ build \\;"
# 빈 인수 뒤의 무해한 인수는 그 자리 그대로 판단한다(r3a 와 같음)
tt "I8(3b 검증) 빈 \$0 뒤 \$1=build → none" none "find . -exec sh -c 'rm -rf \"\$1\"' '' build \\;"
tt "I8(3b 검증) 빈 \$1 뒤 \$2=build → none" none "find . -exec sh -c 'rm -rf \"\$2\"' _ '' build \\;"

t_section "I8(3b 검증): -r 없는 rm 은 디렉터리를 지우지 못하므로 시작 디렉터리 그 자체(깊이 0)는 판단하지 않는다"
# 임시·캐시 디렉터리에서 파일만 지우는 흔한 정리 명령이 시작 디렉터리(/tmp·~/.cache) 때문에 deny 가 되지 않는다(r3a 처럼 find -exec rm 과 같은 ask-high)
for c in "find /tmp -type f -name '*.sock' -exec sh -c 'rm -f \"\$1\"' _ {} \\;" "find ~/.cache -name '*.tmp' -exec sh -c 'rm \"\$1\"' _ {} \\;" \
  "find \"\$TMPDIR\" -name '*.tmp' -exec sh -c 'rm -f \"\$@\"' _ {} +" "find ~/Downloads -maxdepth 1 -name '*.part' -exec sh -c 'rm -f \"\$1\"' _ {} \\;" \
  "find / -exec sh -c 'rm -f \"\$1\"' _ {} \\;"; do
  tt "I8(3b 검증) 비재귀 ask-high: $c" ask-high "$c"; trs "I8(3b 검증) rule id: $c" "[destructive:data-loss-misc]"
done
# 시작 디렉터리에 무엇이 붙으면(\"\$1\"/* 등) 깊이 0 도 판단한다: rm -f /tmp/* 와 같은 deny. -r 이면 시작 디렉터리 자체도 판단(deny)
tt "I8(3b 검증) 비재귀 \"\$1\"/* → deny" deny "find /tmp -exec sh -c 'rm -f \"\$1\"/*' _ {} \\;"; trs "I8(3b 검증) rule id: 비재귀 /*" "[destructive:rm-root]"
tt "I8(3b 검증) 재귀는 그대로 deny" deny "find /tmp -type f -name '*.sock' -exec sh -c 'rm -rf \"\$1\"' _ {} \\;"
ts "I8(3b 검증) 서브에이전트 비재귀 ask" ask "find /tmp -type f -name '*.sock' -exec sh -c 'rm -f \"\$1\"' _ {} \\;"

t_section "I8(3b 검증): -mindepth/-maxdepth 값은 수로 읽고 여러 번 쓰면 마지막 값(find 와 같음)"
for c in "find / -mindepth 00 -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" "find /tmp -mindepth 00 -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" \
  "find / -mindepth 1 -mindepth 0 -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" \
  "find / -maxdepth 0 -maxdepth 1 -mindepth 1 -exec sh -c 'rm -rf \"\$1\"' _ {}/../../etc \\;"; do
  tt "I8(3b 검증) deny: $c" deny "$c"; trs "I8(3b 검증) rule id: $c" "[destructive:rm-root]"
done
for c in "find / -mindepth 0 -mindepth 1 -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" "find / -mindepth 01 -exec sh -c 'rm -rf \"\$1\"' _ {} \\;"; do
  tt "I8(3b 검증) ask-high(마지막 -mindepth ≥1): $c" ask-high "$c"
done

t_section "I4(3b): make -e(환경 변수 우선, 불리언)는 값을 받지 않으므로 뒤 타깃을 놓치지 않는다"
for c in 'make -e deploy' 'make -e ENV=production deploy' 'make -C infra -e deploy'; do
  tt "I4(3b) ask-high: $c" ask-high "$c"; trs "I4(3b) rule id: $c" "[destructive:deploy-runner]"
done
for c in 'make -e build' 'make -e' 'make -e test'; do
  tt "I4(3b) none: $c" none "$c"
done
tt 'I4(3b) 값 옵션 -W 는 값을 건너뛴다: make -W foo.c deploy → ask-high' ask-high 'make -W foo.c deploy'
# R4 task3 에서 -j 의 선택적 값 처리를 고쳤다(아래 전용 섹션) — 예전 한계(make -j deploy → none)는 이제 ask-high

t_section "I1–I7 독립 점검: r3a 의 완화 경계 핀(더 약해지지 않는지) — 블록 디바이스·SQL 미리 보기·문자열 cd·\$TMPDIR"
# I1: 덮어쓰기·결합 리디렉션으로 블록 디바이스에 쓰기는 deny, 임시/문자/null 대상은 none
tt 'I1 핀: cat x >| /dev/sda → deny' deny 'cat x >| /dev/sda'; trs 'I1 핀 rule id' "[destructive:system]"
tt 'I1 핀: cat x >&! /dev/disk2 → deny' deny 'cat x >&! /dev/disk2'
tt 'I1 핀: echo hi >| /tmp/x → none' none 'echo hi >| /tmp/x'
tt 'I1 핀: echo done >&2 → none' none 'echo done >&2'
# I5: liquibase·alembic 롤백 SQL 미리 보기는 none, DB 클라이언트로 넘기면 ask-high, 미리 보기 아닌 롤백은 ask-high
tt 'I5 핀: liquibase rollback-sql v1 → none' none 'liquibase rollback-sql v1'
tt 'I5 핀: liquibase rollback-sql v1 | psql "$DB" → ask-high' ask-high 'liquibase rollback-sql v1 | psql "$DB"'; trs 'I5 핀 rule id' "[destructive:db]"
tt 'I5 핀: liquibase rollback v1 → ask-high' ask-high 'liquibase rollback v1'
tt 'I5 핀: alembic downgrade -1 --sql → none' none 'alembic downgrade -1 --sql'
tt 'I5 핀: alembic downgrade -1 --sql | psql x → ask-high' ask-high 'alembic downgrade -1 --sql | psql x'
# I6: 명령 문자열 안의 cd 는 밖으로 새지 않는다(ask-low), eval 은 샌다(deny), 이웃 규칙 유지(deny)
tt "I6 핀: bash -c 'cd /tmp'; rm -rf x → ask-low" ask-low "bash -c 'cd /tmp'; rm -rf x"
tt "I6 핀: bash -c 'cd ~'; rm -rf Documents → ask-low" ask-low "bash -c 'cd ~'; rm -rf Documents"
tt "I6 핀: eval 'cd ~'; rm -rf Documents → deny" deny "eval 'cd ~'; rm -rf Documents"
tt "I6 핀: bash -c 'echo /' | xargs rm -rf → deny" deny "bash -c 'echo /' | xargs rm -rf"
# I7: \${TMPDIR:-글자그대로 임시경로} 는 none, 그 밖의 기본값은 \$TMP·\$TEMP 와 같이(ask-low/deny)
tt 'I7 핀: ${TMPDIR:-/tmp}/x → none' none 'rm -rf "${TMPDIR:-/tmp}/x"'
tt 'I7 핀: ${TMPDIR:-$HOME}/x → ask-low' ask-low 'rm -rf "${TMPDIR:-$HOME}/x"'
tt 'I7 핀: ${TMPDIR:=$HOME}/x → deny' deny 'rm -rf "${TMPDIR:=$HOME}/x"'
tt 'I7 핀: "$TMPDIR_BUILD"/* → deny' deny 'rm -rf "$TMPDIR_BUILD"/*'

t_section "R4 task3: make -j/--jobs/-l/--load-average 는 숫자만 값으로 먹는다(그 밖의 다음 단어는 타깃)"
# make -j deploy 처럼 숫자가 없으면 deploy 가 타깃 → make deploy 와 같은 ask-high[deploy-runner]
tt 'make deploy → ask-high' ask-high 'make deploy'; trs 'make deploy rule' '[destructive:deploy-runner]'
tt 'make -j deploy → ask-high' ask-high 'make -j deploy'; trs 'make -j deploy rule' '[destructive:deploy-runner]'
tt 'make --jobs deploy → ask-high' ask-high 'make --jobs deploy'
tt 'make -l deploy → ask-high' ask-high 'make -l deploy'
tt 'make --load-average deploy → ask-high' ask-high 'make --load-average deploy'
# 숫자 값(붙임·공백·=)이 있어도 그 다음 단어가 타깃
tt 'make -j 4 deploy → ask-high' ask-high 'make -j 4 deploy'
tt 'make -j4 deploy → ask-high' ask-high 'make -j4 deploy'
tt 'make --jobs=4 deploy → ask-high' ask-high 'make --jobs=4 deploy'
tt 'make -l 2 deploy → ask-high' ask-high 'make -l 2 deploy'
tt 'make -l2 deploy → ask-high' ask-high 'make -l2 deploy'
tt 'make --load-average=2 deploy → ask-high' ask-high 'make --load-average=2 deploy'
tt 'make -j -l deploy → ask-high' ask-high 'make -j -l deploy'
tt 'make -C sub -j deploy → ask-high' ask-high 'make -C sub -j deploy'
tt 'make ENV=1 -j deploy → ask-high' ask-high 'make ENV=1 -j deploy'
tt 'make -j ENV=1 deploy → ask-high' ask-high 'make -j ENV=1 deploy'
# 배포 타깃이 아니면 숫자 유무와 상관없이 none
tt 'make -j build → none' none 'make -j build'
tt 'make -j 4 build → none' none 'make -j 4 build'
tt 'make -l 2 build → none' none 'make -l 2 build'
tt 'make -j → none(타깃 없음)' none 'make -j'
tt 'make -j 4 → none(타깃 없음)' none 'make -j 4'
# 서브에이전트에서도 make -j deploy 는 ask(메인과 같은 티어 — destructive 는 agent 와 무관)
ts 'make -j deploy (sub) → ask' ask 'make -j deploy'

t_section "R4 통합 검증: 실행할 때 펼쳐지는 값(\$(nproc)·백틱·\$N·\"\$JOBS\")도 -j/-l 의 값 — 셸이 숫자로 바꿔 넘긴다(owner 패치는 타깃으로 읽어 r3b 의 ask-high 를 놓쳤다)"
tt 'make -j $(nproc) deploy → ask-high' ask-high 'make -j $(nproc) deploy'; trs 'make -j $(nproc) deploy rule' '[destructive:deploy-runner]'
tt 'make -j "$(nproc)" deploy → ask-high' ask-high 'make -j "$(nproc)" deploy'
tt 'make -j `nproc` deploy → ask-high' ask-high 'make -j `nproc` deploy'
tt 'make -j "$JOBS" deploy → ask-high' ask-high 'make -j "$JOBS" deploy'
tt 'make --jobs $N deploy → ask-high' ask-high 'make --jobs $N deploy'
tt 'make -l $LOAD deploy → ask-high' ask-high 'make -l $LOAD deploy'
tt 'make -l 2.5 deploy → ask-high' ask-high 'make -l 2.5 deploy'
tt 'make ENV=1 -j $(nproc) deploy → ask-high' ask-high 'make ENV=1 -j $(nproc) deploy'
tt 'make -C infra -j $(nproc) release → ask-high' ask-high 'make -C infra -j $(nproc) release'
tt 'make -j $(nproc) build → none' none 'make -j $(nproc) build'
tt 'make -j "$JOBS" → none(타깃 없음)' none 'make -j "$JOBS"'

t_section "R4 통합 검증: find -exec 셸 -c 뒤 옵션(-- · - · -x · -o 이름 · -co 이름)을 파서처럼 건너뛰고 위치 매개변수를 푼다(예전엔 한 칸 밀려 ask-high 가 ask-low)"
for c in "find . -exec sh -c -- 'rm -rf \"\$1\"' _ {} \\;" "find . -exec sh -c - 'rm -rf \"\$1\"' _ {} \\;" "find . -exec sh -c -x 'rm -rf \"\$1\"' _ {} \\;" \
         "find . -exec bash -c -o pipefail 'rm -rf \"\$1\"' _ {} \\;" "find . -exec bash -co pipefail 'rm -rf \"\$1\"' _ {} \\;" \
         "find . -name '*.pyc' -exec sh -c -e -- 'rm -rf \"\$1\"' _ {} \\;"; do
  tt "ask-high: $c" ask-high "$c"; trs "rule: $c" '[destructive:data-loss-misc]'
done
tt 'find / -exec sh -c -- rm "$1" → deny' deny "find / -exec sh -c -- 'rm -rf \"\$1\"' _ {} \\;"
tt 'find ~ -exec bash -c -o pipefail rm "$1" → deny' deny "find ~ -exec bash -c -o pipefail 'rm -rf \"\$1\"' _ {} \\;"
tt 'find . -exec sh -c -- echo "$1" → none' none "find . -exec sh -c -- 'echo \"\$1\"' _ {} \\;"
tt 'find . -exec sh -c -- 로 끝남(문자열 없음) → none' none "find . -exec sh -c -- \\;"

t_report
