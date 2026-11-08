#!/usr/bin/env bash
# tests/hooks/test-guards-migrations-7.sh — guard-migrations.sh 회귀 테스트(3b차 검증)
# 이름이 든 기준 디렉터리(cd migrations·세션 cwd)나 세그먼트마다 어휘가 있어 건너뛰기가 듣지 않는 큰 명령도 선형 시간
# (따옴표 세그먼트의 빠른 길·awk 상한·가장 센 결정에서 멈춤) · 빠른 길은 awk 로 나눈 단어와 같다 · zsh 의 >>&·>>&|·>>&!
# · 서비스가 많은 모노레포 루프(S1 후보와 따라간 디렉터리를 두 번 세지 않는다)
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
t_setup
HOOK="$T_HOOKS/guard-migrations.sh"
AGENT_ID='{"agent_id":"agent-1","agent_type":"implementer"}'
run() { t_run_hook "$HOOK" "$1"; }
tb()  { run "$(t_bash_json "$3" "${4:-}" "${5:-}" "${6:-}")"; assert_decision "$1" "$2"; }   # <name> <expect> <cmd> [cwd] [mode] [extra]
tbs() { tb "$1" "$2" "$3" "${4:-}" default "$AGENT_ID"; }                                       # 서브에이전트
trs() { assert_contains "$1" "$(t_reason "$T_OUT")" "$2"; }
tm()  {  # <name> <expect> <cmd> [extra] — Monitor
  local j mi; j=$(t_json_str "$3"); mi="{\"command\":$j}"
  run "$(t_pre_json Monitor "$mi" "" default "${4:-}")"; assert_decision "$1" "$2"
}
blk() {  # <rule> <cmd> [cwd] — 메인 ask(규칙 id, auto 에서도 ask = ask-high), 서브에이전트 deny
  tb "block: $2" ask "$2" "${3:-}"; trs "block rule id: $2" "[migrations:$1]"
  tb "block stays ask in auto: $2" ask "$2" "${3:-}" auto
  tbs "subagent block: $2" deny "$2" "${3:-}"
}
crt() { tb "create (main none): $1" none "$1" "${2:-}"; tbs "create (subagent deny): $1" deny "$1" "${2:-}"; }   # 새 마이그레이션 생성
pas() { tb "pass: $1" none "$1" "${2:-}"; tbs "subagent pass: $1" none "$1" "${2:-}"; }
t_ms() {  # 벽시계 ms(test-guards-destructive-2.sh 와 같다)
  if command -v python3 >/dev/null 2>&1; then python3 -I -S -c 'import time; print(int(time.time()*1000))'
  elif command -v perl >/dev/null 2>&1; then perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'
  else echo 0; fi
}
t_under() { [ "$2" -lt "$3" ] && t_pass "$1 (${2}ms < ${3}ms)" || t_fail "$1" "${2}ms ≥ ${3}ms"; }
tbig() {  # <name> <expect> <cmd-file> [cwd] [extra] — 큰 명령은 파일에서 읽고 7500ms 안에 끝나야 한다(10초 제한을 넘기면 판정 없이 통과).
  # R5: 3000 → 7500 — 이 기계의 gawk 중앙값이 2.8초(600 podman exec, awk 150회)라 macOS CI(1.4–1.5배)·부하에서 실패했다. 예전 2차 비용(16 KB 에 5–20초, 64 KB 에 10–40초)은 여전히 잡는다
  local t0 t1
  t0=$(t_ms); run "$(t_bash_json_file "$3" "${4:-}" "" "${5:-}")"; t1=$(t_ms)
  assert_decision "$1" "$2"; assert_rc "$1" 0; t_under "$1" $((t1 - t0)) 7500
}
rep() { local i=0; while [ "$i" -lt "$2" ]; do printf '%s' "${1//@/$i}"; i=$((i + 1)); done; }   # <단위(@ = 번호)> <반복 수>

mkdir -p "$T_PROJ/migrations" "$T_PROJ/app/migrations" "$T_PROJ/logs"
printf 'from django.db import migrations\n' >"$T_PROJ/migrations/0001_initial.py"
printf '# app only\n' >"$T_PROJ/app/migrations/0005_app_only.py"
printf 'x = 1\n' >"$T_PROJ/template.py"
CF="$T_TMP/cmd.txt"
MIG="$T_PROJ/migrations"

t_section "리뷰 3b 검증: 이름이 든 기준 디렉터리가 있거나 세그먼트마다 어휘가 있어도 큰 명령은 선형 시간(r3a·3b 패치는 16KB 에 5–20초, 64KB 에 10–40초)"
{ printf 'cd migrations; '; rep 'echo "line @" > /tmp/a@.txt; ' 1500; printf 'echo x > 0001_initial.py'; } >"$CF"
tbig 'cd migrations, 1500 quoted writes to /tmp, then an existing migration write → ask' ask "$CF"
tbig 'cd migrations, 1500 quoted writes to /tmp, then an existing migration write (subagent) → deny' deny "$CF" "" "$AGENT_ID"
{ rep 'echo "line @" > /tmp/a@.txt; ' 1500; printf 'echo x > 0001_initial.py'; } >"$CF"
tbig 'session cwd migrations/, 1500 quoted writes to /tmp, then an existing migration write → ask' ask "$CF" "$MIG"
{ printf 'cd migrations; '; rep "sed -i '' s/a/b/ f@.txt; " 1000; printf 'sed -i s/a/b/ 0001_initial.py'; } >"$CF"
tbig 'cd migrations, 1000 sed -i with a quoted suffix, then sed -i on a migration → ask' ask "$CF"
{ printf 'cd migrations; '; rep "sh -c 'echo @'; " 1000; printf 'echo x > 0001_initial.py'; } >"$CF"
tbig 'cd migrations, 1000 sh -c, then an existing migration write → ask' ask "$CF"
{ printf 'cd migrations; '; rep "podman exec web sh -c 'echo @'; " 600; printf 'echo x > 0001_initial.py'; } >"$CF"
tbig 'cd migrations, 600 podman exec … sh -c, then an existing migration write → ask' ask "$CF"
tbig 'cd migrations, 600 podman exec … sh -c, then an existing migration write (subagent) → deny' deny "$CF" "" "$AGENT_ID"
{ rep 'grep "x" migrations/0001_initial.py > /tmp/o@; ' 1000; printf 'echo x > migrations/0001_initial.py'; } >"$CF"
tbig '1000 quoted greps of a migration, then an existing migration write → ask' ask "$CF"
{ rep 'sh -c "ls migrations"; ' 1500; printf 'echo x > migrations/0001_initial.py'; } >"$CF"
tbig '1500 sh -c with a migration word, then an existing migration write → ask' ask "$CF"
{ rep "docker run --rm --unknown-opt img sh -c 'ls /app/migrations'; " 800; printf 'echo x > migrations/0001_initial.py'; } >"$CF"
tbig '800 docker run … sh -c with a migration word, then an existing migration write → ask' ask "$CF"
{ printf 'cd app/migrations && '; rep 'cp "a@" /tmp/; ' 1000; printf 'echo x > 0005_app_only.py'; } >"$CF"
tbig 'cd app/migrations, 1000 cp of quoted names, then an existing migration write → ask' ask "$CF"
{ printf 'echo x > migrations/0001_initial.py; '; rep 'sh -c "ls migrations"; ' 1500; printf 'true'; } >"$CF"
tbig 'an existing migration write first, then 1500 sh -c → ask (stops at the strongest decision)' ask "$CF"
{ printf 'cd migrations; '; rep 'echo "line @" > /tmp/a@.txt; ' 1500; printf 'true'; } >"$CF"
tbig 'cd migrations, 1500 quoted writes to /tmp only → none' none "$CF"
{ printf 'cd migrations; '; rep 'cp "a@" /tmp/; ' 150; printf 'true'; } >"$CF"
tbig 'cd migrations, 150 cp of quoted names to /tmp → none (exact fast path)' none "$CF"
# awk 상한(150번)을 넘으면 그 뒤의 따옴표 안 공백이 있는 쓰는 명령은 이미 있는 마이그레이션 수정으로 본다(이름이 든 기준 디렉터리가 있을 때만)
{ printf 'cd migrations; '; rep "sed -i 's/a b/c/' f@.txt; " 300; printf 'true'; } >"$CF"
tbig 'cd migrations, 300 sed -i with a quoted space (past the awk limit) → ask (conservative)' ask "$CF"
trs 'past the awk limit: reason says the command was too large' '명령이 너무 커서'
{ rep "sed -i 's/a b/c/' f@.txt; " 300; printf 'true'; } >"$CF"
tbig '300 sed -i with a quoted space, no migration name or base → none' none "$CF"
# 상한을 넘은 뒤의 셸 문자열: 어휘도 쓰기도 없으면 넘기고, 여러 명령이 든 문자열의 쓰기는 보수적으로 본다. 컨테이너 줄은 cp·이름·어휘가 있을 때만
{ printf 'cd migrations; '; rep "sh -c 'echo @'; " 400; printf 'true'; } >"$CF"
tbig 'cd migrations, 400 sh -c without a write (past the awk limit) → none' none "$CF"
tbig 'cd migrations, 400 sh -c without a write (past the awk limit, subagent) → none' none "$CF" "" "$AGENT_ID"
# R4 통합: 상한 뒤의 여러 줄 셸 문자열(공용 파서가 개행을 0x1E 로 담는다)도 여러 명령 — 쓰는 명령이 다음 줄 첫 낱말이어도 한 세그먼트로 보고 끝내지 않는다
{ printf 'cd migrations; '; rep "sh -c 'echo @'; " 400; printf "sh -c 'echo a\nsed -i s/a/b/ 0001_initial.py'"; } >"$CF"
tbig 'cd migrations, 400 sh -c, then a multi-line string editing a migration (past the awk limit) → ask' ask "$CF"
tbig 'cd migrations, 400 sh -c, then a multi-line string editing a migration (past the awk limit, subagent) → deny' deny "$CF" "" "$AGENT_ID"
{ printf 'cd migrations; '; rep "sh -c 'echo @'; " 400; printf "sh -c 'echo a\necho b'"; } >"$CF"
tbig 'cd migrations, 400 sh -c, then a benign multi-line string (past the awk limit) → none' none "$CF"
{ printf 'cd migrations; '; rep "podman exec web sh -c 'echo @'; " 200; printf 'true'; } >"$CF"
tbig 'cd migrations, 200 podman exec … sh -c without a write (past the awk limit) → none' none "$CF"
{ printf 'cd migrations; '; rep "sh -c 'echo @'; " 200; printf "sh -c 'echo a; echo x > 0001_initial.py'"; } >"$CF"
tbig 'cd migrations, 200 sh -c, then a compound sh -c writing a migration (past the awk limit) → ask' ask "$CF"
tbig 'cd migrations, 200 sh -c, then a compound sh -c writing a migration (past the awk limit, subagent) → deny' deny "$CF" "" "$AGENT_ID"
{ printf 'cd migrations; '; rep "podman exec web sh -c 'echo @'; " 200; printf "podman exec web sh -c 'echo x > /app/migrations/0001_initial.py'"; } >"$CF"
tbig 'cd migrations, 200 podman exec, then a container write to a migration (past the awk limit) → ask' ask "$CF"
{ printf 'cd migrations; '; rep "sh -c 'echo @'; " 200; printf "sh -c 'cd /tmp; python manage.py migrate'"; } >"$CF"
tbig 'cd migrations, 200 sh -c, then a compound sh -c applying migrations (past the awk limit, subagent) → deny' deny "$CF" "" "$AGENT_ID"

t_section "리뷰 3b 검증: 따옴표 세그먼트의 빠른 길(awk 없이)은 awk 로 나눈 단어와 같은 판정"
for c in 'echo "a b" > migrations/0001_initial.py' "echo 'x' >> migrations/0001_initial.py" 'printf "%s\n" x > migrations/0001_initial.py' \
  'echo x > "migrations/0001_initial.py"' 'echo x > mig"rations"/0001_initial.py' "sed -i '' s/a/b/ migrations/0001_initial.py" \
  "sed -i \"\" 's/a/b/' migrations/0001_initial.py" 'cp "template.py" "migrations/0001_initial.py"' '"sed" -i s/a/b/ migrations/0001_initial.py' \
  'tee "migrations/0001_initial.py" < /dev/null' 'git checkout -- "migrations/0001_initial.py"' 'cat <<< "x" > migrations/0001_initial.py' \
  "echo \"it's\" > migrations/0001_initial.py" "echo \$'a' > migrations/0001_initial.py" 'dd if=/dev/null "of=migrations/0001_initial.py"' \
  "cd migrations && echo \"a b\" > 0001_initial.py" "sed -i '' s/a/b/ 0001_initial.py"; do
  case $c in "sed -i '' s/a/b/ 0001_initial.py") blk edit-existing "$c" "$MIG" ;; *) blk edit-existing "$c" ;; esac
done
blk delete 'rm "migrations/0001_initial.py"'
crt 'echo "a b" > migrations/0009_new.py'
for c in 'echo "a b" > /tmp/x; ls migrations' 'cp "migrations/0001_initial.py" /tmp/x.py' "sed -n 's/a/b/p' migrations/0001_initial.py" \
  'grep "x" migrations/0001_initial.py > /tmp/o' 'echo "> migrations/0001_initial.py"' 'git log --format="%h" -- migrations > /tmp/log'; do
  pas "$c"
done

t_section "리뷰 3b 검증: zsh 의 >>&·>>&|·>>&!(표준 출력·오류를 덧붙여 쓰기)도 쓰기 리디렉션(e7fd115 은 >>& 를 물었다)"
for c in 'echo x >>& migrations/0001_initial.py' 'echo x >>&| migrations/0001_initial.py' 'echo x >>&! migrations/0001_initial.py' \
  'echo x >>&migrations/0001_initial.py' 'cd app && echo x >>& migrations/0005_app_only.py'; do
  blk edit-existing "$c"
done
crt 'echo x >>& migrations/0009_new.py'
for c in 'echo x >>& /tmp/out.log; ls migrations' 'echo ">>&"; cat migrations/0001_initial.py'; do
  pas "$c"
done
tm 'Monitor zsh >>& onto an existing migration (subagent) → deny' deny 'echo x >>& migrations/0001_initial.py' "$AGENT_ID"

t_section "리뷰 3b 검증: 서비스가 많은 모노레포 루프 — S1 후보로 먼저 들어간 디렉터리를 따라가면 후보에서 뺀다(3b 패치는 46개부터 로그 쓰기를 물었다)"
i=0; while [ "$i" -lt 60 ]; do mkdir -p "$T_PROJ/services/s$i/migrations"; printf 'x\n' >"$T_PROJ/services/s$i/migrations/0001_x.py"; i=$((i + 1)); done
{ rep 'cd services/s@/migrations && ls > ../../../logs/s@.log; cd ../../..; ' 60; printf 'true'; } >"$CF"
tbig '60-service loop writing logs → none' none "$CF"
tbig '60-service loop writing logs (subagent) → none' none "$CF" "" "$AGENT_ID"
{ rep '(cd services/s@/migrations && python check.py > ../../../logs/s@.txt) && ' 60; printf 'true'; } >"$CF"
tbig '60 subshells writing logs → none' none "$CF"
{ rep 'cd services/s@/migrations && ls > ../../../logs/s@.log; cd ../../..; ' 60; printf 'echo x > services/s1/migrations/0001_x.py'; } >"$CF"
tbig '60-service loop, then an existing migration write → ask' ask "$CF"

t_report
