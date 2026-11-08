#!/usr/bin/env bash
# tests/hooks/test-guards-migrations-6.sh — guard-migrations.sh 회귀 테스트(3b차 리뷰)
# 선형 시간(도구 단어가 많은 세그먼트·이름 없는 세그먼트의 쓰기·셸 문자열·긴 옵션 묶음·쓰는 대상이 수천 개) · 미리 보기 보류를 지우지 않는 sh -c·ssh·eval 단계
# 한 명령짜리 묶음·DB 클라이언트 인수 안의 미리 보기 · zsh 덮어쓰기 강제 쓰기(>!·>&|) · git 의 작업 트리를 모르는 형태 · 컨테이너 --entrypoint·래퍼 뒤의 셸
# 저장소 안 cd 후보의 마이그레이션 판정(S1 남은 틈) · zsh cdpath · 따옴표로 나뉜 이름·도구 단어
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
apl() {  # <cmd> — ask-low(auto 에서 조용히 통과), 서브에이전트 deny
  tb "apply: $1" ask "$1"; trs "apply rule id: $1" "[migrations:apply]"
  tb "apply silenced in auto: $1" none "$1" "" auto
  tbs "subagent apply: $1" deny "$1"
}
rbk() { tb "rollback main (guard-destructive owns the ask): $1" none "$1"; tbs "rollback subagent: $1" deny "$1"; }
t_ms() {  # 벽시계 ms(test-guards-destructive-2.sh 와 같다)
  if command -v python3 >/dev/null 2>&1; then python3 -I -S -c 'import time; print(int(time.time()*1000))'
  elif command -v perl >/dev/null 2>&1; then perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'
  else echo 0; fi
}
t_under() { [ "$2" -lt "$3" ] && t_pass "$1 (${2}ms < ${3}ms)" || t_fail "$1" "${2}ms ≥ ${3}ms"; }
tbig() {  # <name> <expect> <cmd-file> [extra] — 큰 명령은 파일에서 읽고 3000ms 안에 끝나야 한다(10초 제한을 넘기면 판정 없이 통과)
  local t0 t1
  t0=$(t_ms); run "$(t_bash_json_file "$3" "" "" "${4:-}")"; t1=$(t_ms)
  assert_decision "$1" "$2"; assert_rc "$1" 0; t_under "$1" $((t1 - t0)) 3000
}
rep() { local i=0; while [ "$i" -lt "$2" ]; do printf '%s' "${1//@/$i}"; i=$((i + 1)); done; }   # <단위(@ = 번호)> <반복 수>

mkdir -p "$T_PROJ/migrations" "$T_PROJ/app/migrations" "$T_PROJ/src" "$T_PROJ/db/migrate" "$T_PROJ/alembic/versions"
printf 'from django.db import migrations\n' >"$T_PROJ/migrations/0001_initial.py"
printf '# app only\n' >"$T_PROJ/app/migrations/0005_app_only.py"
printf 'class CreateUsers; end\n' >"$T_PROJ/db/migrate/20240101_create_users.rb"
printf 'revision = "0001"\n' >"$T_PROJ/alembic/versions/0001_init.py"
printf 'x = 1\n' >"$T_PROJ/template.py"
APP="$T_PROJ/app"
DECOY="$T_TMP/decoy6"   # 같은 이름의 하위 디렉터리(migrate·versions·src·web)를 가진 미끼 — 마이그레이션 파일은 없다
mkdir -p "$DECOY/migrate" "$DECOY/versions" "$DECOY/src" "$DECOY/web"
CF="$T_TMP/cmd.txt"

t_section "리뷰 3b: 도구 단어가 아주 많은 세그먼트도 선형 시간(같은 도구 이름은 한 번만 — r2b·r3a 는 4KB 에 8초, 16KB 에 10초 넘김)"
{ printf 'echo '; rep 'goose x ' 2000; printf '; echo x > migrations/0001_initial.py'; } >"$CF"
tbig '2000 tool words in one segment, then an existing migration write → ask' ask "$CF"
tbig '2000 tool words (subagent) → deny' deny "$CF" "$AGENT_ID"
{ printf 'echo '; rep 'flyway status liquibase x goose y ' 600; printf '; goose -dir db/migrations up'; } >"$CF"
tbig 'many mixed tool words, then goose up → ask (apply)' ask "$CF"
crt 'echo goose goose flyway x; echo x > migrations/0009_new.py'
apl 'docker run --rm --name goose flyway/flyway migrate'   # 뒤에 나온 도구 단어를 먼저(R9) — 중복을 없애도 순서는 같다
apl 'goose flyway goose -dir db up'

t_section "리뷰 3b: 마이그레이션 이름·어휘가 없는 세그먼트는 쓰기·셸 문자열을 따지지 않는다(세그먼트마다 awk — 64KB 에 10초 넘김)"
{ rep 'echo "line @" > /tmp/a@.txt; ' 1000; printf 'echo x > migrations/0001_initial.py'; } >"$CF"
tbig '1000 quoted writes to /tmp, then an existing migration write → ask' ask "$CF"
{ rep "sh -c 'echo @'; " 1000; printf 'echo x > migrations/0001_initial.py'; } >"$CF"
tbig '1000 sh -c without migration words, then an existing migration write → ask' ask "$CF"
{ rep "podman exec web sh -c 'echo @'; " 400; printf 'echo x > migrations/0001_initial.py'; } >"$CF"
tbig '400 podman exec … sh -c, then an existing migration write → ask' ask "$CF"
{ rep "sed -i '' s/a/b/ f@.txt; " 1000; printf 'sed -i s/a/b/ migrations/0001_initial.py'; } >"$CF"
tbig '1000 quoted sed -i on other files, then sed -i on a migration → ask' ask "$CF"
for c in "podman exec web sh -c 'echo x > /app/migrations/0001_initial.py'" "sh -c \"echo x > '$T_PROJ/migrations/0001_initial.py'\"" \
  "docker run --rm --unknown-opt img sh -c 'sed -i s/a/b/ /app/migrations/0001_initial.py'" "cd app/migrations; echo \"x\" > 0005_app_only.py" \
  "cd app && sh -c 'echo x > migrations/0005_app_only.py'" 'echo x > mig"rations"/0001_initial.py' "sed -i s/a/b/ m'igrations'/0001_initial.py" \
  "sh -c 'echo x > mi\\grations/0001_initial.py'" "podman exec web sh -c \"echo x > /app/mig'rations'/0001_initial.py\""; do
  blk edit-existing "$c"   # 이름이 문자열·기준 디렉터리에 있으면 그대로 본다(따옴표·역슬래시로 나뉜 이름도)
done
blk edit-existing "sh -c 'echo x > 0001_initial.py'" "$T_PROJ/migrations"   # 세션 cwd 가 마이그레이션 디렉터리
blk edit-existing "cd migrations && sh -c 'echo x > 0001_initial.py'"
for c in "sh -c 'npx prisma db push'" "docker run --rm --unknown-opt img sh -c 'npx prisma db push'" "bash -lc 'rails db:migrate'" \
  "podman exec web sh -c 'supabase db push'"; do
  apl "$c"   # 이름이 없어도 명령 어휘(prisma·rails·supabase)가 있으면 안쪽 명령을 본다
done
for c in 'echo "x" > /tmp/a.txt; sh -c "echo hi" > /tmp/b.txt' "podman exec web sh -c 'ls /app' > /tmp/ls.txt" \
  "sh -c 'cat /etc/hosts' | grep -c x"; do
  pas "$c"
done

t_section "리뷰 3b: zsh 의 덮어쓰기 강제 쓰기(>!·>>!·&>!·>&!·>&|)도 쓰기 리디렉션(Bash 도구가 zsh 로 돌 수 있다 — e7fd115 은 물었다)"
for c in 'echo x >! migrations/0001_initial.py' 'echo x >!migrations/0001_initial.py' 'echo x >>! migrations/0001_initial.py' \
  'echo x &>! migrations/0001_initial.py' 'echo x >&! migrations/0001_initial.py' 'echo x >&| migrations/0001_initial.py' \
  'echo x 2>! migrations/0001_initial.py' 'cat template.py >! migrations/0001_initial.py' 'cd app && echo x >! migrations/0005_app_only.py'; do
  blk edit-existing "$c"
done
crt 'echo x >! migrations/0009_new.py'
for c in 'echo x >! /tmp/out.txt; ls migrations' '[ ! -f migrations/0001_initial.py ] && echo missing' \
  'if ! grep -q x migrations/0001_initial.py; then echo no; fi'; do
  pas "$c"
done
tm 'Monitor zsh >! onto an existing migration (subagent) → deny' deny 'echo x >! migrations/0001_initial.py' "$AGENT_ID"
{ printf 'echo "'; rep '>!' 3000; printf '"; echo x >! migrations/0001_initial.py'; } >"$CF"
tbig '3000 >! in a string, then >! onto an existing migration → ask' ask "$CF"

t_section "리뷰 3b: 아주 긴 옵션 묶음(-bbbb…·perl -pppp…i)은 글자마다 돌지 않는다"
{ printf 'cp -'; rep b 16000; printf ' template.py migrations/0001_initial.py'; } >"$CF"
tbig 'cp with a 16000-letter bundle onto a migration → ask' ask "$CF"
{ printf 'perl -'; rep p 16000; printf 'i -e 1 migrations/0001_initial.py'; } >"$CF"
tbig 'perl with a 16000-letter bundle (in-place) onto a migration → ask' ask "$CF"
{ printf 'sed -'; rep n 16000; printf 'i s/a/b/ migrations/0001_initial.py'; } >"$CF"
tbig 'sed with a 16000-letter bundle ending in i → ask' ask "$CF"
for c in 'cp -bv template.py migrations/0001_initial.py' 'cp -vt migrations src/0001_initial.py' 'install -Dm644 template.py migrations/0001_initial.py' \
  'sed -ni.bak s/a/b/p migrations/0001_initial.py' 'curl -sSLo migrations/0001_initial.py http://x.invalid/a' \
  'wget -qO migrations/0001_initial.py http://x.invalid/a' 'truncate -cs0 migrations/0001_initial.py' 'git restore -SW migrations/0001_initial.py' \
  'rsync -av -e ssh template.py migrations/0001_initial.py' 'patch -Np1 migrations/0001_initial.py x.diff' 'cp -Q template.py migrations/0001_initial.py'; do
  blk edit-existing "$c"   # 패턴으로 바꾼 묶음 해석이 글자 단위 해석과 같다
done
for c in 'git restore -S migrations/0001_initial.py' 'patch -C migrations/0001_initial.py x.diff' 'install -dm755 migrations/x' \
  'cp -t /tmp migrations/0001_initial.py' 'perl -ne print migrations/0001_initial.py'; do
  pas "$c"
done

t_section "리뷰 3b: 쓰는 대상·지우는 대상이 수천 개인 세그먼트(줄 목록을 배열로 — 64KB 에 15초)"
{ printf 'echo x'; rep ' > /tmp/a@' 2000; printf ' > migrations/0001_initial.py'; } >"$CF"
tbig '2000 redirect targets in one segment including an existing migration → ask' ask "$CF"
{ printf 'rm -f'; rep ' /tmp/f@.txt' 2000; printf ' migrations/0001_initial.py'; } >"$CF"
tbig 'rm of 2000 files including a migration → ask' ask "$CF"; trs 'rm of 2000 files rule id' '[migrations:delete]'
{ printf 'cp'; rep ' /tmp/s@.py' 1000; printf ' migrations/'; } >"$CF"
tbig 'cp of 1000 new files into migrations/ → none (creation)' none "$CF"
tbig 'cp of 1000 new files into migrations/ (subagent) → deny' deny "$CF" "$AGENT_ID"

t_section "리뷰 3b: 미리 보기 보류는 sh -c·ssh·eval 단계의 안쪽 명령이 지우지 않는다"
for c in 'liquibase update-sql | sh -c "grep -v x" | psql' 'alembic upgrade head --sql | bash -c "cat" | psql "$DB"' \
  'ssh host liquibase update-sql | psql "$DB"' 'eval liquibase update-sql | psql' 'liquibase update-sql | sh -c "tee /tmp/u.sql" | psql'; do
  apl "$c"
done
rbk 'ssh host liquibase rollback-sql v1 | psql'
for c in 'liquibase update-sql | sh -c "cat > /tmp/u.sql"' "alembic upgrade head --sql | sh -c 'grep x' > out.sql" \
  'ssh host liquibase update-sql > /tmp/u.sql' 'eval liquibase update-sql | less'; do
  pas "$c"
done
tm 'Monitor preview | sh -c filter | psql (subagent) → deny' deny 'liquibase update-sql | sh -c "grep -v x" | psql' "$AGENT_ID"

t_section "리뷰 3b: 한 명령짜리 묶음의 출력을 DB 클라이언트로 넘기는 미리 보기"
for c in '( liquibase update-sql ) | psql "$DB"' '{ liquibase update-sql; } | psql "$DB"' 'echo "$(alembic upgrade head --sql)" | psql "$DB"' \
  '(alembic upgrade head --sql) | mysql app' $'{\n  liquibase update-sql\n} | psql'; do
  apl "$c"
done
rbk '( alembic downgrade -1 --sql ) | psql'
for c in '( liquibase update-sql ) > out.sql' '{ liquibase update-sql; } | less' '( liquibase update-sql; ) || psql' \
  '{ liquibase update-sql; } > /tmp/x.sql; psql -c "select 1"'; do
  pas "$c"
done

t_section "리뷰 3b: DB 클라이언트 인수의 \$(…)·<(…) 안의 미리 보기는 그 클라이언트가 실행한다"
for c in 'psql -c "$(alembic upgrade head --sql)"' 'psql "$DB" < <(alembic upgrade head --sql)' 'psql "$DB" <<< "$(liquibase update-sql)"' \
  'mysql -e "$(liquibase update-sql)" app' 'psql -f <(alembic upgrade head --sql)' 'docker exec -i db psql -c "$(alembic upgrade head --sql)"' \
  'ssh db "psql -c \"$(alembic upgrade head --sql)\""' 'cat <(alembic upgrade head --sql) | psql'; do
  apl "$c"
done
rbk 'psql -c "$(alembic downgrade -1 --sql)"'
for c in 'echo "$(alembic upgrade head --sql)" > out.sql' 'diff <(alembic upgrade head --sql) expected.sql' \
  'psql -c "$(cat x.sql)"; alembic upgrade head --sql | less' 'grep -c x <(alembic upgrade head --sql)'; do
  pas "$c"
done

t_section "리뷰 3b: 따옴표·역슬래시로 나뉜 도구 단어(alem\"bic\"·li'quibase')도 본다(명령 전체의 어휘 검사가 먼저 끝내지 않게)"
for c in 'alem\bic upgrade head' "li'quibase' update-sql | psql" "goo'se' -dir db up" 'fly"way" migrate'; do
  apl "$c"
done
rbk 'alem"bic" downgrade base'
crt 'echo x > "migr"ations/0009_new.py'
pas 'echo "a" > /tmp/x; ls'

t_section "리뷰 3b: git 의 작업 트리를 모르는 형태(core.worktree·--config-env·GIT_WORK_TREE)는 쓰는 경로를 이미 있는 파일로도 본다"
for c in "git -c core.worktree='$APP' checkout HEAD -- migrations/0005_app_only.py" "git -c core.WorkTree='$APP' restore migrations/0005_app_only.py" \
  "git -c core.worktree=../app checkout HEAD -- migrations/0005_app_only.py" "git --config-env=core.worktree=WT checkout -- migrations/0005_app_only.py" \
  "git --config-env core.worktree=WT restore migrations/0005_app_only.py" "GIT_WORK_TREE='$APP' git checkout HEAD -- migrations/0005_app_only.py" \
  "export GIT_WORK_TREE='$APP'; git restore migrations/0005_app_only.py" "git -c core.worktree='$APP/migrations' checkout HEAD -- 0005_app_only.py" \
  "git -c core.worktree='$APP' -C src checkout HEAD -- migrations/0005_app_only.py"; do
  blk edit-existing "$c"
done
crt "git -c core.worktree='$APP' checkout HEAD -- migrations/0009_new.py"   # 절대 경로 작업 트리는 그 아래에서 존재를 본다
for c in "git -c core.worktree='$APP' status" 'git -c user.name=x checkout main' "GIT_WORK_TREE='$APP' git diff -- migrations" \
  "git -c core.worktree=../app log -- migrations/0005_app_only.py"; do
  pas "$c"
done

t_section "리뷰 3b: 컨테이너의 --entrypoint 와 래퍼(env·nice·busybox) 뒤의 셸(공용 파서가 벗기지 않는 옵션이 있을 때)"
for c in "docker run --rm --unknown-opt --entrypoint sh img -c 'echo x > /app/migrations/0001_initial.py'" \
  "docker run --rm --unknown-opt --entrypoint=/bin/bash img -lc 'sed -i s/a/b/ /app/migrations/0001_initial.py'" \
  "docker run --rm --unknown-opt img env sh -c 'echo x > /app/migrations/0001_initial.py'" \
  "docker run --rm --unknown-opt img env -i FOO=1 /bin/sh -c 'echo x > /app/migrations/0001_initial.py'" \
  "docker run --rm --unknown-opt --entrypoint tee img /app/migrations/0001_initial.py" \
  "docker run --rm img busybox sh -c 'echo x > /app/migrations/0001_initial.py'" \
  "docker run --rm --unknown-opt img nice -n 5 sh -c 'echo x > /app/migrations/0001_initial.py'" \
  "podman run --rm --unknown-opt img timeout 5 bash -c 'echo x > /app/migrations/0001_initial.py'" \
  "docker compose run --rm --entrypoint sh web -c 'echo x > /app/migrations/0001_initial.py'" \
  "docker compose run --rm --entrypoint=sh web -c 'sed -i s/a/b/ /app/migrations/0001_initial.py'"; do
  blk edit-existing "$c"   # docker compose run 의 --entrypoint 는 공용 파서가 값과 함께 벗긴다 — 남은 -c '…' 를 셸 문자열로
done
apl "docker compose run --entrypoint bash web -lc 'python manage.py migrate'"
for c in "docker run --rm --unknown-opt --entrypoint sh img -c 'cat /app/migrations/0001_initial.py'" \
  "docker run --rm --unknown-opt img env FOO=1 python -V" "docker run --rm --unknown-opt --entrypoint /bin/true img" \
  "docker compose run --rm --entrypoint sh web -c 'cat /app/migrations/0001_initial.py'"; do
  pas "$c"
done

t_section "리뷰 3b: 돌지 않았을 수 있는 절대 cd 뒤의 상대 cd — 저장소 안 후보는 마이그레이션 판정에도 쓴다(S1 남은 틈)"
for c in "false && cd '$DECOY'; cd migrate; echo x > 20240101_create_users.rb" "cd '$DECOY' & cd migrate; sed -i s/a/b/ 20240101_create_users.rb" \
  "false && cd '$DECOY'; cd migrate && cp ../../template.py 20240101_create_users.rb"; do
  blk edit-existing "$c" "$T_PROJ/db"
done
blk delete "false && cd '$DECOY'; cd migrate; rm 20240101_create_users.rb" "$T_PROJ/db"
blk edit-existing "cd '$T_PROJ/db'; false && cd '$DECOY'; cd migrate; echo x > 20240101_create_users.rb"
blk edit-existing "false && cd '$DECOY'; cd versions; echo x > 0001_init.py" "$T_PROJ/alembic"
crt "false && cd '$DECOY'; cd migrate; echo x > 20990101_new.rb" "$T_PROJ/db"
for c in "false && cd '$DECOY'; cd migrate; cat 20240101_create_users.rb > /tmp/x.rb" "false && cd '$DECOY'; cd src; echo x > out.txt"; do
  pas "$c" "$T_PROJ/db"
done
GA="$T_TMP/tools/goose/app"   # 저장소 밖 조상(…/goose)의 이름은 후보에 넣지 않는다
mkdir -p "$GA/web" "$GA/migrations" && (cd "$GA" && t_git init -q .) || exit 1
for c in 'cd web && cd .. && echo x > notes.txt; ls migrations' 'false && cd /tmp; cd ..; echo x > notes.txt; ls migrations'; do
  pas "$c" "$GA"
done

t_section "리뷰 3b: zsh 의 cdpath=(…) 뒤의 상대 cd 는 모르는 위치"
blk edit-existing "cdpath=('$APP'); cd migrations; echo x > 0009_new.py"
blk edit-existing "cdpath+=('$APP'); cd migrations && echo x > 0009_new.py"
crt "cd migrations; echo x > 0009_new.py"

t_report
