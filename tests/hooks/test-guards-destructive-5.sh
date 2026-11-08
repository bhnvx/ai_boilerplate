#!/usr/bin/env bash
# tests/hooks/test-guards-destructive-5.sh — guard-destructive.sh 3차 후속 회귀 테스트
# (I1 덮어쓰기·결합 리디렉션의 블록 디바이스 쓰기 · I2 배포 이름의 테스트 접미 · I3 긴 세그먼트(결정 불변·시간) ·
#  I4 make 타깃의 KEY=VALUE·경로가 붙은 인터프리터 · I5 liquibase SQL 미리 보기와 DB 클라이언트로 넘긴 미리 보기 ·
#  I6 명령 문자열 안 cd 격리 · I7 ${TMPDIR:-기본값} · I8 find -exec 셸 문자열의 위치 매개변수 · I9 2차(R1–R5) 형태 보강)
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
tt() {  # <name> <none|ask-low|ask-high|deny> <cmd> [cwd] [tool] — ask 이면 auto 로 다시 실행해 티어를 가른다(T_OUT 은 기본 모드 결과)
  local d a got out tool=${5:-Bash}
  run "$(tj "$tool" "$3" "${4:-}")"; out=$T_OUT; d=$(t_decision "$out"); got=$d
  if [ "$d" = ask ]; then
    run "$(tj "$tool" "$3" "${4:-}" auto)"; a=$(t_decision "$T_OUT")
    case $a in none) got=ask-low ;; ask) got=ask-high ;; *) got="ask/$a" ;; esac
  fi
  T_OUT=$out
  assert_eq "$1" "$2" "$got"
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
mkcmd() {  # <앞> <인수 개수> <뒤> → $T_TMP/cmd.txt = "<앞> a0 a1 … <뒤>"
  { printf '%s' "$1"; awk -v n="$2" 'BEGIN { for (i = 0; i < n; i++) printf " a%d", i }'; printf '%s' "$3"; } >"$T_TMP/cmd.txt"
}

t_section "I1: 덮어쓰기(>| >! >&| >&!)·결합(>& &> 2>) 리디렉션으로 블록 디바이스에 쓰기 → deny system"
for c in 'cat image.iso > /dev/disk2' 'cat image.iso >| /dev/disk2' 'cat image.iso >! /dev/disk2' 'cat image.iso >&| /dev/disk2' \
  'cat image.iso >&! /dev/disk2' 'cat image.iso >&/dev/disk2' 'cat image.iso >& /dev/rdisk2' 'cat image.iso &> /dev/sda' \
  'cat image.iso 2> /dev/nvme0n1' 'cat image.iso 1>| /dev/rdisk3' 'cat image.iso >>! /dev/sdb' 'cat image.iso &>| /dev/disk2' \
  'cat image.iso &>! /dev/hda' 'cat image.iso >|/dev/disk2' 'cat image.iso > "/dev/disk2"' "cat image.iso >| '/dev/sda'"; do
  tt "I1 deny: $c" deny "$c"; trs "I1 rule id: $c" "[destructive:system]"
done
tt 'I1 Monitor deny: >| /dev/disk2' deny 'cat image.iso >| /dev/disk2' "" Monitor
for c in 'cat x > /dev/null' 'cat x >& /dev/null' 'cat x 2>/dev/tty' 'cat x >| /tmp/x' 'cat x > /dev/stdout' 'cat x >&| /dev/null' \
  'cat x >! /dev/null' 'cat x >& /dev/stderr' 'cat /dev/disk2 >| /tmp/disk.img' 'echo done >&2 && ls /dev/disk2'; do
  tt "I1 none: $c" none "$c"
done

t_section "I2: 배포 이름의 테스트 접미(*_test·*_spec)는 앞부분이 [._-] 없는 한 단어일 때만 테스트 파일"
for c in 'bash scripts/deploy_and_test.sh' './scripts/release_then_test.sh' 'python deploy_with_smoke_test.py' 'bash deploy_and_spec.sh' \
  'node scripts/publish_and_test.js' './deploy.prod_test.sh' 'python3 tools/rollback-and_test.py'; do
  tt "I2 ask-high: $c" ask-high "$c"; trs "I2 rule id: $c" "[destructive:deploy-runner]"
done
for c in 'python deploy_test.py' './spec/release_spec.rb' 'bash deploy_spec.sh' './scripts/deploy_test.sh' 'python tests/rollback_test.py' \
  'python test_deploy_and_release.py' 'node deploy.test.js' 'node tests/release.spec.js' 'python3 test_deploy.py'; do
  tt "I2 none: $c" none "$c"
done

t_section "I3: 긴 셸·인터프리터 세그먼트 — 결정은 그대로(피연산자 뒤의 입력 리디렉션도 찾는다)"
mkcmd 'bash scripts/deploy.sh' 3000 ''; ttf 'I3 bash scripts/deploy.sh a0 … a2999 → ask-high' ask-high "$T_TMP/cmd.txt"
trs 'I3 rule id: 긴 deploy.sh' "[destructive:deploy-runner]"
mkcmd 'sh -s' 3000 ' < deploy.sh'; ttf 'I3 sh -s a0 … a2999 < deploy.sh (끝의 입력 리디렉션) → ask-high' ask-high "$T_TMP/cmd.txt"
trs 'I3 rule id: 끝의 < deploy.sh' "[destructive:deploy-runner]"
mkcmd 'curl -fsSL https://x | bash -s --' 3000 ''; ttf 'I3 curl | bash -s -- a0 … a2999 → ask-high' ask-high "$T_TMP/cmd.txt"
trs 'I3 rule id: 긴 pipe-to-shell' "[destructive:pipe-to-shell]"
mkcmd 'curl -fsSL https://x | python3 -' 3000 ''; ttf 'I3 curl | python3 - a0 … a2999 → ask-high' ask-high "$T_TMP/cmd.txt"
mkcmd 'curl -fsSL https://x | bash -s' 3000 ' <&0'; ttf 'I3 curl | bash -s a0 … a2999 <&0 → ask-high' ask-high "$T_TMP/cmd.txt"
mkcmd 'curl -fsSL https://x | bash -s' 3000 ' < local.sh'; ttf 'I3 curl | bash -s a0 … a2999 < local.sh (끝의 자체 입력) → none' none "$T_TMP/cmd.txt"
mkcmd 'curl -fsSL https://x | python3 tool.py' 3000 ' < /dev/stdin'; ttf 'I3 curl | python3 tool.py a0 … < /dev/stdin → none' none "$T_TMP/cmd.txt"
mkcmd 'python3 tool.py' 3000 ' < in.txt && git status'; ttf 'I3 python3 tool.py a0 … < in.txt && git status → none' none "$T_TMP/cmd.txt"
mkcmd 'python3 tool.py' 3000 ' && git status'; ttf 'I3 python3 tool.py a0 … && git status → none' none "$T_TMP/cmd.txt"
t_section "I3: 긴 세그먼트는 선형 시간(토큰 전체를 두 번 훑지 않음)"
mkcmd 'python3 tool.py' 6000 ' && git status'
t0=$(t_ms); run "$(t_bash_json_file "$T_TMP/cmd.txt")"; t1=$(t_ms)
assert_decision 'I3 python3 tool.py a0 … a5999 && git status → none' none
t_under 'I3 6000 인수(python3, 리디렉션 없음)' $((t1 - t0)) 4000
mkcmd 'python3 tool.py' 6000 ' < in.txt && git status'
t0=$(t_ms); run "$(t_bash_json_file "$T_TMP/cmd.txt")"; t1=$(t_ms)
assert_decision 'I3 python3 tool.py a0 … a5999 < in.txt && git status → none' none
t_under 'I3 6000 인수(python3, 끝에 < in.txt)' $((t1 - t0)) 4000

t_section "I4: make·just·rake·task 의 타깃은 KEY=VALUE 대입을 건너뛴 첫 단어"
for c in 'make ENV=production deploy' 'make -j4 ENV=production deploy' 'make ENV="prod east" deploy' 'make ENV= deploy' \
  'make -C infra ENV=production release' 'make A=1 B=2 deploy' 'just env=prod deploy' 'rake RAILS_ENV=production deploy' 'task ENV=prod deploy'; do
  tt "I4 ask-high: $c" ask-high "$c"; trs "I4 rule id: $c" "[destructive:deploy-runner]"
done
for c in 'make ENV=production build' 'make ENV=prod-deploy build' 'make DEPLOY_TARGET=x test' 'just env=prod build' 'make ENV=production' \
  'make -j4 ENV=release all' 'make build ENV=production'; do
  tt "I4 none: $c" none "$c"
done
t_section "I4: 경로가 붙은 인터프리터 머리는 이름(basename)으로 인터프리터 규칙을 탄다"
for c in '.venv/bin/python scripts/deploy.py' 'venv/bin/python3 deploy.py' '/usr/bin/python3 deploy.py' '/bin/bash ./deploy.sh' \
  '~/.nvm/versions/node/v20.11.0/bin/node scripts/release.js' '/opt/homebrew/opt/python@3.12/bin/python3.12 deploy.py' \
  '.venv/bin/python -u scripts/deploy.py' './env/bin/python -m pdb scripts/deploy.py' '/usr/local/bin/zsh -e deploy.sh' \
  '/opt/tools/bin/bash < scripts/deploy.sh'; do
  tt "I4 ask-high: $c" ask-high "$c"; trs "I4 rule id: $c" "[destructive:deploy-runner]"
done
for c in '.venv/bin/python scripts/build.py' '.venv/bin/python -m pytest tests/test_deploy.py' '.venv/bin/python -c "import deploy"' \
  '/bin/bash -n deploy.sh' 'venv/bin/python manage.py check --deploy' '.venv/bin/python -m py_compile scripts/deploy.py' \
  './bin/server --env production' '.venv/bin/python scripts/deploy_test.py'; do
  tt "I4 none: $c" none "$c"
done

t_section "I5: liquibase 의 SQL 미리 보기(*-sql·*SQL·*Sql)는 SQL 출력만 → 통과(guard-migrations 와 같음)"
for c in 'liquibase rollback-sql v1' 'liquibase --changelog-file=x.xml rollbackSQL v1' 'liquibase rollback-count-sql 1' \
  'liquibase rollbackCountSQL 1' 'liquibase future-rollback-sql' 'liquibase update-sql' 'liquibase update-sql > out.sql' \
  'liquibase rollback-sql v1 > rollback.sql' 'liquibase --url=jdbc:x rollback-to-date-sql 2024-01-01' 'liquibase rollbackToDateSql 2024-01-01' \
  'alembic upgrade head --sql > x.sql' 'alembic downgrade -1 --sql > d.sql' 'liquibase updateSQL | psql "$DB"' \
  'alembic upgrade head --sql | psql "$DB"' 'liquibase rollback-sql v1 | tee rb.sql' 'flask db downgrade --sql > down.sql' \
  'liquibase update > rollback.log' 'liquibase rollback-sql v1 2> rollback.err' 'liquibase --changelog-file=rollback.xml update' 'liquibase update'; do
  tt "I5 none: $c" none "$c"
done
t_section "I5: 롤백 SQL 미리 보기를 DB 클라이언트로 넘기면 실행된다 → ask-high db(미리 보기가 아닌 동사와 같음)"
for c in 'liquibase rollback-sql v1 | psql "$DATABASE_URL"' 'liquibase --changelog-file=x.xml rollbackSQL v1 | mysql -u root app' \
  'liquibase future-rollback-sql | psql "$DB"' 'liquibase rollback-count-sql 1 | sqlite3 app.db' 'liquibase rollback-sql v1 | mariadb app' \
  'liquibase rollback-sql v1 | clickhouse-client' 'alembic downgrade -1 --sql | psql "$DB"' 'alembic -c alembic.ini downgrade -1 --sql | psql "$DB"' \
  'flask db downgrade --sql | psql "$DB"' 'alembic downgrade base --sql | tee down.sql | psql "$DB"' 'alembic downgrade -1 --sql | sqlcmd -S db -d app' \
  'psql "$DB" -f <(alembic downgrade -1 --sql)' 'psql -c "$(liquibase rollback-sql v1)"' \
  'liquibase rollback v1' 'liquibase rollbackCount 1' 'liquibase rollbacksql v1' 'liquibase dropAll' 'liquibase --output-file=x-sql rollback v1' \
  'liquibase rollbackToDate 2024-01-01 > out.txt' 'java -jar liquibase.jar rollback v1' 'liquibase --changelog-file rollback.xml rollback-count 1'; do
  tt "I5 ask-high: $c" ask-high "$c"; trs "I5 rule id: $c" "[destructive:db]"
done

t_section "I6: 명령 문자열(bash -c·sh -c 등) 안의 cd 는 바깥 작업 디렉터리를 바꾸지 않는다(rm -rf x 단독과 같은 결정)"
tt 'I6 기준: rm -rf x → ask-low' ask-low 'rm -rf x'
for c in "bash -c 'cd /tmp'; rm -rf x" "sh -c 'cd /tmp' && rm -rf x" "zsh -c 'cd /var/tmp'; rm -rf x" "bash -c \"cd /tmp\" ; rm -rf x" \
  "bash -c 'pushd /tmp'; rm -rf x" "bash -c 'bash -c \"cd /tmp\"; rm -rf x'" "bash -c 'cd ~'; rm -rf Documents" "bash -c 'cd /'; rm -rf usr" \
  "bash -c 'cd /tmp'; rm -rf ./x" "(cd /tmp); rm -rf x"; do
  tt "I6 ask-low: $c" ask-low "$c"; trs "I6 rule id: $c" "[destructive:rm-recursive]"
done
for c in "bash -c 'cd /tmp && rm -rf x'" "bash -c 'cd /tmp; rm -rf build/x'" "sh -c 'cd /var/tmp && rm -rf cache'" \
  "bash -c 'cd /tmp'; rm -rf /tmp/x" "eval 'cd /tmp'; rm -rf x"; do
  tt "I6 none: $c" none "$c"
done
tt "I6 안에서는 cd 적용: bash -c 'cd ~ && rm -rf Documents' → deny" deny "bash -c 'cd ~ && rm -rf Documents'"
tt "I6 eval 은 같은 셸: eval 'cd ~'; rm -rf Documents → deny" deny "eval 'cd ~'; rm -rf Documents"
tt "I6 브랜치 가정은 밖으로 이어진다: bash -c 'git checkout main'; git push --force → deny" deny "bash -c 'git checkout main'; git push --force" "$T_WT"
tt 'I6 기준: worktree 에서 git push --force → ask-high' ask-high 'git push --force' "$T_WT"
tt "I6 이웃 세그먼트 규칙 유지: bash -c 'echo /' | xargs rm -rf → deny" deny "bash -c 'echo /' | xargs rm -rf"

t_section "I7: \${TMPDIR:-기본값} 은 기본값이 글자 그대로의 임시 경로일 때만 임시 경로 지름길"
for c in 'rm -rf "${TMPDIR:-/tmp}/x"' 'rm -rf "${TMPDIR:-/var/tmp}/x"' 'rm -rf "${TMPDIR:-/tmp}"/build' 'rm -rf "${TMPDIR:-/private/tmp}/x"' \
  'rm -rf "${TMPDIR:-/tmp/}/x"' 'rm -rf "${TMPDIR-/tmp}/x"' 'rm -rf "${TMPDIR:=/tmp}/x"' 'rm -rf "${TMPDIR=/var/tmp}/x"' \
  'rm -rf "$TMPDIR"/x' 'rm -rf "${TMPDIR}"/x' 'rm -rf "${TMPDIR:?}"/x' 'rm -rf "${TMPDIR:?TMPDIR unset}/x"' 'rm -rf "${TMPDIR%/}/x"' \
  'rm -rf "${TMPDIR%%/}/x"' 'rm -rf "$TMPDIR/build"'; do
  tt "I7 none: $c" none "$c"
done
for c in 'rm -rf "${TMPDIR:-$HOME}/x"' 'rm -rf "${TMPDIR:-/}/x"' 'rm -rf "${TMPDIR:-..}/x"' 'rm -rf "${TMPDIR:-$HOME}/Documents"' \
  'rm -rf "${TMPDIR:-/tmp/..}/x"' 'rm -rf "${TMPDIR:-${HOME}}/x"' 'rm -rf "${TMPDIR:-/home}/x"'; do
  tt "I7 ask-low(\${TMP:-…} 와 같음): $c" ask-low "$c"; trs "I7 rule id: $c" "[destructive:rm-recursive]"
done
for c in 'rm -rf "${TMPDIR:=$HOME}/x"' 'rm -rf "${TMPDIR-$HOME}/x"' 'rm -rf "${TMPDIR=$HOME}/x"' 'rm -rf "${TMPDIR:+$HOME}/x"' \
  'rm -rf "${TMPDIR%/*}/x"' 'rm -rf "${TMPDIR:-${HOME}}"' 'rm -rf "$TMPDIR_BUILD"/*' 'rm -rf "$TMPDIR_OLD"'; do
  tt "I7 deny: $c" deny "$c"; trs "I7 rule id: $c" "[destructive:rm-root]"
done

t_section "I8: find -exec 셸 문자열의 위치 매개변수(\$0 \$1 \$@)는 find 시작 디렉터리 아래 경로(find -exec rm 과 같은 ask-high)"
tt "I8 기준: find . -exec rm -rf {} \\; → ask-high" ask-high "find . -name '*.pyc' -exec rm -rf {} \\;"
for c in "find . -name '*.pyc' -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" "find . -name '*.pyc' -exec sh -c 'rm -rf \"\$@\"' _ {} +" \
  "find . -type f -exec bash -c 'rm -f \"\$0\"' {} \\;" "find src tests -name '*.o' -exec sh -c 'rm -f \"\$1\"' sh {} \\;" \
  "find . -name '*.bak' -execdir sh -c 'rm -rf \"\$1\"' sh {} \\;" "find . -name x -exec sh -c 'rm -rf \"\${1}\"' _ {} \\;" \
  "find . -name '*.tmp' -exec sh -c 'rm -rf \$1' _ {} \\;" "find build -name '*.o' -exec sh -c 'rm -rf \"\$1\".bak' _ {} \\;" \
  "find -L . -name '*.pyc' -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" \
  "find . -name a -exec sh -c 'rm \"\$1\"' _ {} \\; -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" \
  "find . -name '*.pyc' -exec sh -c 'rm -rf \"\$@\"' {} +" "find . -name '*.o' -exec sh -c 'rm -f \"\$1\" \"\$2\"' _ {} +"; do
  tt "I8 ask-high: $c" ask-high "$c"; trs "I8 rule id: $c" "[destructive:data-loss-misc]"
done
for c in "find ~ -maxdepth 1 -name '*.log' -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" "find /etc -name x -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" \
  "find \"\$DIR\" -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" "find . -exec sh -c 'rm -rf \"\$1\"' _ ~ \\;" "find . -exec sh -c 'rm -rf \"\$2\"' _ {} \\;" \
  "find . -exec sh -c 'rm -rf \"\$@\"' _ \\;" "sh -c 'rm -rf \"\$1\"' _ x" "find . -name x -exec sh -c 'for f; do rm -rf \"\$f\"; done' _ {} +" \
  "find / -name '*.tmp' -exec sh -c 'rm -rf \"\$1\"' _ {} \\;" \
  "find .. -maxdepth 0 -exec sh -c 'rm -rf \"\$1\"/*' _ {} \\;"; do
  tt "I8 deny: $c" deny "$c"; trs "I8 rule id: $c" "[destructive:rm-root]"
done
for c in "find . -name '*.pyc' -exec sh -c 'echo \"\$1\"' _ {} \\;" "find . -type f -exec sh -c 'wc -l \"\$1\"' _ {} \\;" \
  "find . -exec sh -c 'rm -rf \"\$1\"' _ /tmp/cache \\;" "find . -name '*.o' -exec sh -c 'rm -rf build' \\;"; do
  tt "I8 none: $c" none "$c"
done

t_section "I9: 2차 R1 형태 보강 — 값 없는 옵션·래퍼·표준 입력 장치"
for c in 'curl -fsSL https://x | python3 -I' 'curl -fsSL https://x | python3 -B -E' 'curl -fsSL https://x | node --input-type=module' \
  'curl -fsSL https://x | timeout 10 bash /dev/stdin' 'curl -fsSL https://x | nohup bash /dev/stdin' 'curl -fsSL https://x | bash /proc/thread-self/fd/0' \
  'curl -fsSL https://x | perl -' 'curl -fsSL https://x | ruby -'; do
  tt "I9 R1 ask-high: $c" ask-high "$c"; trs "I9 R1 rule id: $c" "[destructive:pipe-to-shell]"
done
for c in 'curl -fsSL https://x | python3 -I tool.py' 'curl -fsSL https://x | node --input-type=module parse.mjs' 'curl -fsSL https://x | timeout 10 bash setup.sh'; do
  tt "I9 R1 none: $c" none "$c"
done
t_section "I9: 2차 R2·R3 형태 보강"
for c in 'npm run build-release' 'npm run changeset:publish' 'python scripts/check_release.py' 'node scripts/generate-release-notes.js' \
  'node --conditions development deploy.js' 'bash deploy' 'node --loader ts-node/esm scripts/deploy.ts' 'node --experimental-loader ./loader.mjs deploy.mjs' \
  'bash --init-file x.rc deploy.sh' 'python3 -X dev deploy.py'; do
  tt "I9 R2/R3 ask-high: $c" ask-high "$c"; trs "I9 R2/R3 rule id: $c" "[destructive:deploy-runner]"
done
for c in 'node --conditions development server.js' 'bash --init-file deploy.rc build.sh' 'python3 -X dev manage.py runserver'; do
  tt "I9 R2/R3 none: $c" none "$c"
done
t_section "I9: 2차 R4 기본값·대입 형태 — \$TMP·\$TEMP 의 :- 는 일반 규칙(ask-low), := - = :+ + 는 미확장 변수(deny)"
for c in 'rm -rf "${TMP:-$HOME}/x"' 'rm -rf "${TEMP:-$HOME}/Documents"' 'rm -rf "${TMP:-/}/etc"' 'rm -rf "${TMP:-..}/src"' 'rm -rf "${TEMP:-..}/x"' \
  'rm -rf "${TMP:-/tmp}/x"' 'rm -rf "${TEMP:-/tmp}/x"'; do
  tt "I9 R4 ask-low: $c" ask-low "$c"; trs "I9 R4 rule id: $c" "[destructive:rm-recursive]"
done
for c in 'rm -rf "${TMP-$HOME}/x"' 'rm -rf "${TEMP:=$HOME}/x"' 'rm -rf "${TMP=$HOME}/x"' 'rm -rf "${TEMP=$HOME}/x"' 'rm -rf "${TMP:+$HOME}/x"' \
  'rm -rf "${TEMP+x}/y"'; do
  tt "I9 R4 deny: $c" deny "$c"; trs "I9 R4 rule id: $c" "[destructive:rm-root]"
done
for c in 'rm -rf "${TMP:?}/x"' 'rm -rf "${TEMP?}/x"' 'rm -rf "${TMP%/}/x"' 'rm -rf "$TEMP/x"'; do
  tt "I9 R4 none: $c" none "$c"
done
t_section "I9: 2차 R5 형태 보강"
for c in 'npx mikro-orm-esm schema:drop' 'migrate -prefetch 10 -path db -database x down 1' 'migrate -lock-timeout 30 -path db -database x drop -f' \
  'flask --env-file .env db downgrade' 'npx typeorm schema:drop' 'atlas --env prod schema clean --auto-approve'; do
  tt "I9 R5 ask-high: $c" ask-high "$c"; trs "I9 R5 rule id: $c" "[destructive:db]"
done
for c in 'migrate -prefetch 10 -path db -database x up' 'flask --env-file .env db upgrade' 'npx mikro-orm-esm migration:up'; do
  tt "I9 R5 none: $c" none "$c"
done
t_report
