#!/usr/bin/env bash
# tests/hooks/test-guards-migrations-4.sh — guard-migrations.sh 회귀 테스트(2차 수정 R1–R12)
# R1 __pycache__/.. · R2 cd 합집합·따라갈 수 없는 cwd 변경 · R3 원격·컨테이너 쓰기 · R4 제자리 수정 명령 · R5 ~+ ~- ~user
# R6 cd 세그먼트의 리디렉션 · R7 cp/mv/install 옵션 · R8 명령 전체의 파괴적 내용 · R9 뒤의 도구 단어 · R10 liquibase *-sql
# R11 세그먼트가 많은 명령(bash 3.2 프로세스 치환 한도) · R12 cwd 기준 경로
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
t_setup
HOOK="$T_HOOKS/guard-migrations.sh"
AGENT_ID='{"agent_id":"agent-1","agent_type":"implementer"}'
run() { t_run_hook "$HOOK" "$1"; }
tb()  { run "$(t_bash_json "$3" "${4:-}" "${5:-}" "${6:-}")"; assert_decision "$1" "$2"; }   # <name> <expect> <cmd> [cwd] [mode] [extra]
tbs() { tb "$1" "$2" "$3" "${4:-}" default "$AGENT_ID"; }                                       # 서브에이전트
trs() { assert_contains "$1" "$(t_reason "$T_OUT")" "$2"; }
tm()  {  # <name> <expect> <cmd> [extra] — Monitor (bash 3.2 의 "$( … \" … )" 중첩 문제를 피하려고 변수로 먼저 만든다)
  local j mi; j=$(t_json_str "$3"); mi="{\"command\":$j}"
  run "$(t_pre_json Monitor "$mi" "" default "${4:-}")"; assert_decision "$1" "$2"
}
tf()  {  # <name> <expect> <tool> <path> [extra] — Edit/Write
  local fp ti; fp=$(t_json_str "$4"); ti="{\"file_path\":$fp,\"content\":\"x = 1\",\"old_string\":\"a\",\"new_string\":\"b\"}"
  run "$(t_pre_json "$3" "$ti" "" default "${5:-}")"; assert_decision "$1" "$2"
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

mkdir -p "$T_PROJ/migrations/__pycache__" "$T_PROJ/app/migrations" "$T_PROJ/src" "$T_PROJ/db/migrations" "$T_PROJ/db/migrate" \
  "$T_PROJ/prisma/migrations/2024_x" "$T_PROJ/scripts"
printf 'from django.db import migrations\n' >"$T_PROJ/migrations/0001_initial.py"
printf '# root only\n' >"$T_PROJ/migrations/0002_only_root.py"
: >"$T_PROJ/migrations/__init__.py"
: >"$T_PROJ/migrations/__pycache__/0001_initial.cpython-312.pyc"
printf 'from django.db import migrations\n' >"$T_PROJ/app/migrations/0001_initial.py"
printf '# app only\n' >"$T_PROJ/app/migrations/0005_app_only.py"
printf 'CREATE TABLE t (id int);\n' >"$T_PROJ/db/migrations/20240101_init.sql"
printf 'class X < ActiveRecord::Migration[7.1]; end\n' >"$T_PROJ/db/migrate/001_x.rb"
printf 'CREATE TABLE t (id int);\n' >"$T_PROJ/prisma/migrations/2024_x/migration.sql"
printf 'x = 1\n' >"$T_PROJ/template.py"
MIG="$T_PROJ/migrations"
HD_NEW="cat > migrations/0009_new.py <<'EOF'"$'\nx = 1\nEOF'

t_section "R1: __pycache__ 예외는 .. 이 없는 경로에만"
blk delete 'git rm -r migrations/__pycache__/..'
blk delete 'rm migrations/__pycache__/../0001_initial.py'
blk delete 'rm -f ./migrations/__pycache__/../*.py'
blk edit-existing 'echo x > migrations/__pycache__/../0001_initial.py'
blk edit-existing "sed -i '' s/a/b/ migrations/__pycache__/../0001_initial.py"
tm "Monitor rm via __pycache__/.. → ask" ask 'rm migrations/__pycache__/../0001_initial.py'
tm "Monitor rm via __pycache__/.. (subagent) → deny" deny 'rm migrations/__pycache__/../0001_initial.py' "$AGENT_ID"
for t in Edit Write; do
  tf "$t via __pycache__/.. (existing) → ask" ask $t 'migrations/__pycache__/../0001_initial.py'
  trs "$t via __pycache__/.. rule id" "[migrations:edit-existing]"
  tf "$t via __pycache__/.. (subagent) → deny" deny $t 'migrations/__pycache__/../0001_initial.py' "$AGENT_ID"
  tf "$t via a missing dir/.. (existing after folding) → ask" ask $t 'migrations/nope/../0001_initial.py'
  tf "$t of a .pyc → none" none $t 'migrations/__pycache__/0001_initial.cpython-312.pyc'
  tf "$t of a .pyc (subagent) → none" none $t 'migrations/__pycache__/0001_initial.cpython-312.pyc' "$AGENT_ID"
  tf "$t of a new file via __pycache__/.. → none (creation)" none $t 'migrations/__pycache__/../0009_new.py'
  tf "$t of a new file via __pycache__/.. (subagent) → deny" deny $t 'migrations/__pycache__/../0009_new.py' "$AGENT_ID"
done
pas 'rm -rf migrations/__pycache__'
pas 'rm -f migrations/*.pyc'
pas 'rm src/../tools/migrate_helper.py'
pas 'git rm -r --cached migrations/__pycache__'

t_section "R2: 상대 경로의 존재 여부는 세션 cwd 와 cd 가 닿은 모든 디렉터리의 합집합"
for c in 'false && cd src; echo x > migrations/0001_initial.py' \
  "[ -f app/manage.py ] && cd app; cat > migrations/0002_only_root.py <<'EOF'"$'\nx = 1\nEOF' \
  'if false; then cd src; fi; echo x > migrations/0001_initial.py' 'cd src | cat; echo x > migrations/0001_initial.py' \
  'cd src & echo x > migrations/0001_initial.py' 'while false; do cd src; done; echo x > migrations/0001_initial.py' \
  'echo src | xargs cd; echo x > migrations/0001_initial.py' 'cd src extra; echo x > migrations/0001_initial.py' \
  "sh -c \"sh -c 'cd src'; echo x > migrations/0001_initial.py\"" 'cd app && echo x > migrations/0002_only_root.py' \
  'cd src && echo x > migrations/0001_initial.py'; do
  blk edit-existing "$c"
done
t_section "R2: eval·source·.·pushd -n·cd \"\"·z·함수·CDPATH 뒤의 상대 경로는 있는 파일로"
for c in 'eval "cd app"; echo x > migrations/0009_new.py' '. ./scripts/enter-app.sh && echo x > migrations/0009_new.py' \
  'source ./scripts/enter-app.sh; echo x > migrations/0009_new.py' 'pushd -n src >/dev/null; echo x > migrations/0009_new.py' \
  'cd ""; echo x > migrations/0009_new.py' 'z app && echo x > migrations/0009_new.py' 'zoxide query app; zi app; echo x > migrations/0009_new.py' \
  'f() { cd src; }; f; echo x > migrations/0009_new.py' 'function g { cd app; }; g; echo x > migrations/0009_new.py' \
  'CDPATH=/srv cd app && echo x > migrations/0009_new.py' 'export CDPATH=/srv; cd app; echo x > migrations/0009_new.py' \
  'cd "$APP_DIR"; echo x > migrations/0009_new.py' 'popd; echo x > migrations/0009_new.py' 'pushd +1; echo x > migrations/0009_new.py'; do
  blk edit-existing "$c"
done
tm "Monitor false && cd; write existing → ask" ask 'false && cd src; echo x > migrations/0001_initial.py'
tm "Monitor eval cd; write new → ask" ask 'eval "cd app"; echo x > migrations/0009_new.py'
crt "cd app && $HD_NEW"
crt "f() { echo hi; }; f; $HD_NEW"
crt "cd /tmp && echo x > migrations/0009_new.py"
crt "sudo cd app; echo x > migrations/0009_new.py"
crt "cd src && cd .. && $HD_NEW"
crt "sh -c \"sh -c 'cd src'; cd app && echo x > migrations/0009_new.py\""   # 중첩 sh -c 의 cd 는 새지 않는다(새면 src/app 이 없어 ask)
crt "(cd src); cd app && echo x > migrations/0009_new.py"
pas 'eval "echo hi"; cat migrations/0001_initial.py'
pas '. .venv/bin/activate && ls migrations/'
tm "Monitor creation → none" none "$HD_NEW"

t_section "R3: ssh·컨테이너 안의 쓰기와 host:path 목적지는 이미 있는 파일로"
for c in "ssh prod 'echo x > /srv/app/migrations/0009_new.py'" "cat fix.py | ssh prod 'tee /srv/app/migrations/0009_new.py'" \
  "docker exec web sh -c 'echo x > /app/migrations/0009_new.py'" 'docker exec web cp /tmp/x.py /app/migrations/0009_new.py' \
  "kubectl exec api-0 -- sh -c 'echo x > /app/migrations/0009_new.py'" 'docker compose exec -T web tee /app/app/migrations/0009_new.py < fix.py' \
  "ssh prod 'cd /srv/app && echo x > migrations/0009_new.py'" "docker compose -f dc.yml run --rm web sh -c 'cat > /app/migrations/0009_new.py' < x.py" \
  'podman exec web tee /app/migrations/0009_new.py < x.py' "podman exec -it web sh -c 'echo x > /app/migrations/0009_new.py'" \
  'docker-compose exec -T web tee /app/migrations/0009_new.py < x.py' 'docker container exec web tee /app/migrations/0009_new.py < x.py' \
  'docker run --rm -v "$PWD:/app" -w /app python:3 cp /tmp/x.py /app/migrations/0009_new.py' \
  'scp fix.py prod:/srv/app/migrations/0009_new.py' 'scp -P 2222 fix.py prod:/srv/app/migrations/' \
  'rsync -az -e ssh fix.py prod:/srv/app/migrations/0009_new.py' 'docker cp fix.py web:/app/migrations/0009_new.py' \
  'kubectl cp fix.py api-0:/app/migrations/0009_new.py' 'kubectl cp -n prod fix.py prod/api-0:/app/migrations/0009_new.py'; do
  blk edit-existing "$c"
done
tm "Monitor ssh write → ask" ask "ssh prod 'echo x > /srv/app/migrations/0009_new.py'"
for c in 'scp prod:/srv/app/migrations/0001_initial.py /tmp/' 'docker cp web:/app/migrations/0001_initial.py /tmp/backup.py' \
  "ssh prod 'cat /srv/app/migrations/0001_initial.py'" 'kubectl cp api-0:/app/migrations/0001_initial.py ./backup.py' \
  'rsync -a prod:/srv/app/migrations/ /tmp/mig-backup/' 'podman exec web cat /app/migrations/0001_initial.py' \
  'docker run --rm -v "$PWD/migrations:/m" alpine ls /m' 'docker compose up -d goose' 'podman ps --filter name=migrations'; do
  pas "$c"
done
crt "$HD_NEW"   # 로컬 생성은 그대로

t_section "R4: 리디렉션 없이 제자리에서 쓰는 명령(있으면 edit-existing, 없으면 생성)"
for c in "perl -pi -e 's/AddField/RemoveField/' migrations/0001_initial.py 2>&1" "perl -pi -e 's/a/b/' migrations/0001_initial.py" \
  "perl -i.bak -pe 's/a/b/' migrations/0001_initial.py" "perl -p -i -e 's/a/b/' migrations/0001_initial.py" \
  "ruby -pi -e 'gsub(/a/, \"b\")' migrations/0001_initial.py" "gsed -i 's/a/b/' migrations/0001_initial.py 2>/dev/null" \
  "sed --in-place 's/a/b/' migrations/0001_initial.py 2>&1" "sed -i.bak 's/a/b/' migrations/0001_initial.py" \
  "sed -Ei 's/a/b/' migrations/0001_initial.py" "sed -i -e 's/a/b/' -e 's/c/d/' migrations/0001_initial.py" \
  'git checkout HEAD~1 -- migrations/0001_initial.py 2>/dev/null' 'git checkout migrations/0001_initial.py' 'git checkout -- migrations/' \
  'git restore migrations/0001_initial.py' 'git restore --source=HEAD~2 --worktree migrations/0001_initial.py' 'git restore -SW migrations/0001_initial.py' \
  'git -C app checkout -- migrations/0005_app_only.py' 'dd if=template.py of=migrations/0001_initial.py 2>/dev/null' \
  'curl -sSo migrations/0001_initial.py https://example.com/x.py 2>/dev/null' 'curl --output migrations/0001_initial.py https://example.com/x.py' \
  'curl -o 0001_initial.py --output-dir migrations https://example.com/x.py' 'wget -O migrations/0001_initial.py https://example.com/x.py' \
  'wget -qO migrations/0001_initial.py https://example.com/x.py' 'wget --output-document=migrations/0001_initial.py https://example.com/x.py' \
  'truncate -s 0 migrations/0001_initial.py' 'patch migrations/0001_initial.py < fix.diff' 'patch -p0 -o migrations/0001_initial.py template.py fix.diff'; do
  blk edit-existing "$c"
done
tm "Monitor perl -pi → ask" ask "perl -pi -e 's/a/b/' migrations/0001_initial.py"
for c in 'curl -o migrations/0009_new.py https://example.com/x.py' 'wget -O db/migrations/20240501_new.sql https://example.com/x.sql' \
  'git checkout origin/main -- migrations/0009_new.py' 'dd if=template.py of=migrations/0009_new.py' 'truncate -s 0 migrations/0009_new.py'; do
  crt "$c"
done
for c in "perl -ne 'print if /AddField/' migrations/0001_initial.py" "perl -MList::Util=sum -e 'print 1' migrations/0001_initial.py" \
  "ruby -e 'puts File.read(ARGV[0])' migrations/0001_initial.py" "sed -n '1,40p' migrations/0001_initial.py" 'git checkout main' \
  'git checkout -b feature/migrations-cleanup' 'git restore --staged migrations/0001_initial.py' 'dd if=migrations/0001_initial.py of=/tmp/x.py' \
  'curl -o /tmp/x.py https://example.com/migrations/0001_initial.py' 'wget -O - https://example.com/migrations/0001_initial.py | head' \
  'truncate -r migrations/0001_initial.py /tmp/x.txt' 'patch --dry-run migrations/0001_initial.py < fix.diff' 'git diff migrations/ > /tmp/mig.patch'; do
  pas "$c"
done

t_section "R5: ~+ ~- ~user 경로는 있는 파일로"
blk edit-existing 'echo x > ~+/migrations/0009_new.py'
blk edit-existing 'cd src && echo x > ~-/migrations/0009_new.py'
blk edit-existing 'echo x > ~nobody/migrations/0009_new.py'
pas 'cat ~+/migrations/0001_initial.py'
pas 'echo x > ~/notes-migrations.txt'

t_section "R6: cd·pushd 세그먼트의 리디렉션도 본다(cd 전에 옛 cwd 에서 열린다)"
blk edit-existing 'cd . > migrations/0001_initial.py'
blk edit-existing 'pushd src > migrations/0001_initial.py'
blk edit-existing 'cd src 2> migrations/0001_initial.py'
pas 'cd migrations > /dev/null && ls'
pas 'pushd app/migrations > /dev/null && ls && popd > /dev/null'
pas 'cd migrations > 0001_initial.py'   # 옛 cwd(루트)에 만드는 파일 — 마이그레이션이 아니다

t_section "R7: cp·mv·install 옵션(-vt DIR, 값을 받는 옵션, 모르는 옵션은 옛 규칙)"
blk delete 'mv -vt app/ migrations'
blk delete 'mv -ft /tmp/old migrations'
blk delete 'mv --weird-flag template.py migrations/0009_new.py'
for c in 'cp --no-preserve mode template.py migrations/0001_initial.py' 'cp --sparse always template.py migrations/0001_initial.py' \
  'cp --suffix .orig -b template.py migrations/0001_initial.py' 'cp -S .orig -b template.py migrations/0001_initial.py' \
  'cp -vt migrations/ /tmp/0001_initial.py' 'install -Dt migrations/ /tmp/0001_initial.py' 'cp --target=migrations/ /tmp/0001_initial.py' \
  'cp --weird-flag template.py migrations/0009_new.py' 'cp -Q template.py migrations/0009_new.py' 'install -D -m 644 template.py migrations/0001_initial.py'; do
  blk edit-existing "$c"
done
for c in 'cp --no-preserve=mode migrations/0001_initial.py /tmp/x.py' 'cp -av migrations /tmp/backup' 'cp --sparse=always migrations/0001_initial.py /tmp/x.py' \
  'install -d migrations/new_dir' 'cp -t /tmp/ migrations/0001_initial.py'; do
  pas "$c"
done
crt 'mv -v /tmp/0009_new.py migrations/'
crt 'cp -vt migrations/ /tmp/0009_new.py'

t_section "R8: 마이그레이션을 만드는 명령 어디에든 파괴적 내용이 있으면 destructive-schema"
for c in "cat > /tmp/m.py <<'EOF'"$'\nop.drop_table("users")\nEOF\n'"mv /tmp/m.py migrations/0009_drop.py" \
  "cat > /tmp/m.sql <<'EOF'"$'\nDROP TABLE users;\nEOF\n'"cp /tmp/m.sql db/migrations/20240401_drop.sql" \
  "echo 'DROP TABLE users;' | sed 's/x/y/' | tee db/migrations/20240401_drop.sql" \
  "cat > migrations/0009_new.py <<'A'"$'\nx = 1\nA\n'"cat > /tmp/notes.md <<'B'"$'\nwe may DROP TABLE legacy later\nB' \
  "X='ALTER TABLE users DROP COLUMN email;'; echo \"\$X\" > db/migrations/20240402_drop.sql"; do
  blk destructive-schema "$c"
done
pas "cat > /tmp/m.py <<'EOF'"$'\nop.drop_table("users")\nEOF\n'"mv /tmp/m.py /tmp/other.py"
crt "cat > /tmp/m.py <<'EOF'"$'\nop.add_column("users", sa.Column("x"))\nEOF\n'"mv /tmp/m.py migrations/0009_add.py"
crt 'truncate -s 0 migrations/0009_empty.py'   # 명령 이름 truncate 는 파괴적 내용이 아니다

t_section "R9: 뒤에 나온 도구 단어가 앞의 것보다 먼저, 스크립트 이름의 : 뒤도 도구"
for c in 'docker run --rm --name goose flyway/flyway migrate' 'docker run --rm -v ./x:/alembic liquibase/liquibase update' \
  'docker run --rm -w /goose flyway/flyway -url=jdbc:x migrate' 'pnpm run db:goose up' 'alembic -n goose upgrade head' \
  'flyway -url=jdbc:postgresql://localhost/goose migrate'; do
  apl "$c"
done
pas 'docker run --rm --name goose flyway/flyway info'
pas 'pnpm run db:goose status'
pas 'brew upgrade goose'
tb 'rollback via later tool word (main) → none' none 'docker run --rm --name goose flyway/flyway clean'
tbs 'rollback via later tool word (subagent) → deny' deny 'docker run --rm --name goose flyway/flyway clean'

t_section "R10: liquibase 의 *-sql·*SQL 은 SQL 만 출력한다(적용·롤백 아님)"
for c in 'liquibase --changelog-file=db/changelog.xml update-sql' 'liquibase --changelog-file=x.xml updateSQL' 'liquibase update-sql' \
  'liquibase rollback-sql v1' 'liquibase --changelog-file=x.xml rollbackSQL v1' 'liquibase future-rollback-sql' 'liquibase update-count-sql 2' \
  'liquibase --changelog-file=x.xml update-to-tag-sql v2'; do
  pas "$c"
done
for c in 'liquibase --changelog-file=x.xml update' 'liquibase update-count 2' 'liquibase update-to-tag v1'; do apl "$c"; done
tb 'liquibase rollback (main) → none (guard-destructive owns the ask)' none 'liquibase --changelog-file=x.xml rollback v1'
tbs 'liquibase rollback (subagent) → deny' deny 'liquibase --changelog-file=x.xml rollback v1'
tbs 'liquibase rollback-count (subagent) → deny' deny 'liquibase rollback-count 1'

t_section "R11: 세그먼트가 많아도 죽지 않는다(bash 3.2 의 < <(…) 한도)"
rep() { local c='' i=0; while [ "$i" -lt "$2" ]; do c="$c$1; "; i=$((i + 1)); done; printf '%s' "$c$3"; }
C=$(rep 'cd src' 400 'echo x > migrations/0001_initial.py'); tb '400 cd segments + existing write → ask' ask "$C"; assert_rc '400 cd segments' 0
C=$(rep 'echo a > /tmp/x.txt' 400 'echo x > migrations/0001_initial.py'); tb '400 redirect segments + existing write → ask' ask "$C"; assert_rc '400 redirect segments' 0
C=$(rep "echo 'a' > /tmp/x.txt" 400 'echo x > migrations/0001_initial.py'); tb '400 quoted redirect segments + existing write → ask' ask "$C"; assert_rc '400 quoted redirect segments' 0
C=$(rep 'rm -f /tmp/x.txt' 400 'echo x > migrations/0001_initial.py'); tb '400 rm segments + existing write → ask' ask "$C"; assert_rc '400 rm segments' 0
C=$(rep 'cd /tmp' 400 'ls migrations > /tmp/out.txt'); tb '400 cd segments, no migration write → none' none "$C"; assert_rc '400 cd segments (pass)' 0
C=$(rep 'echo a > /tmp/x.txt' 400 'cat migrations/0001_initial.py'); tb '400 redirect segments, read only → none' none "$C"; assert_rc '400 redirect segments (pass)' 0
C=$(rep 'cd /tmp' 400 'echo x > migrations/0009_new.py'); tbs '400 cd segments + creation (subagent) → deny' deny "$C"

t_section "R12: 경로를 cwd 기준으로도 판정(cd migrations 뒤, 세션 cwd 가 마이그레이션 디렉터리)"
blk edit-existing 'cd migrations && echo x > 0001_initial.py'
blk delete 'cd migrations && rm 0001_initial.py'
blk edit-existing "cd migrations && sed -i '' s/a/b/ 0001_initial.py"
blk edit-existing 'cd db && echo x > migrate/001_x.rb'
blk edit-existing 'cd prisma/migrations && echo x > 2024_x/migration.sql'
blk edit-existing 'cd app/src && echo x > ../migrations/0005_app_only.py'
blk edit-existing "sed -i '' s/a/b/ 0001_initial.py" "$MIG"
blk edit-existing 'echo x >> 0001_initial.py' "$MIG"
blk delete 'rm 0001_initial.py' "$MIG"
blk edit-existing 'git checkout -- .' "$MIG"
blk edit-existing 'cp /tmp/x.py 0001_initial.py' "$MIG"
tm "Monitor cd migrations && write → ask" ask 'cd migrations && echo x > 0001_initial.py'
crt "cd migrations && cat > 0009_new.py <<'EOF'"$'\nx\nEOF'
crt 'echo x > 0009_new.py' "$MIG"
for c in 'cd migrations && ls' 'cd migrations && cat 0001_initial.py > /tmp/x.py' 'cd migrations && rm -rf __pycache__' \
  'cd migrations && rm -f *.pyc' 'cd migrations && git diff . > /tmp/mig.patch'; do
  pas "$c"
done
for c in 'ls -la' 'cat 0001_initial.py' 'git status' 'echo x > /tmp/out.txt' 'rm -rf __pycache__'; do pas "$c" "$MIG"; done
GP="$T_TMP/gp/goose"   # 저장소 루트 위의 디렉터리 이름(…/goose/ 에 클론)은 보지 않는다
mkdir -p "$GP/internal" && (cd "$GP" && t_git init -q .) && : >"$GP/main.go"
for c in 'echo x > main.go' 'cd internal && echo x > a.go' "sed -i '' s/a/b/ main.go" 'rm main.go'; do pas "$c" "$GP"; done

t_section "R2 재검토: /dev/.. 경로·perl/ruby -0·-l 묶음·sed 긴 옵션 줄임·sudo/xargs cd 의 리디렉션"
for c in "echo x > '/dev/..$T_PROJ/migrations/0001_initial.py'" 'echo x > /dev/..$PWD/migrations/0001_initial.py' \
  "cat fix.py | tee '/dev/../$T_PROJ/migrations/0001_initial.py'" "cp template.py '/dev/..$T_PROJ/migrations/0001_initial.py'" \
  "sed -i '' s/a/b/ '/dev/..$T_PROJ/migrations/0001_initial.py'" \
  "perl -0pi -e 's/AddField/RemoveField/s' migrations/0001_initial.py 2>&1" "perl -lpi -e 's/a/b/' migrations/0001_initial.py" \
  "perl -pli -e 's/a/b/' migrations/0001_initial.py" "perl -00pi -e 's/a/b/' migrations/0001_initial.py" \
  "perl -F: -lapi -e 's/a/b/' migrations/0001_initial.py" "ruby -0pi -e 'x' migrations/0001_initial.py 2>&1" \
  'sed -i --e=s/a/b/ migrations/0001_initial.py' "gsed --in-pl 's/a/b/' migrations/0001_initial.py" "sed --in 's/a/b/' migrations/0001_initial.py" \
  'sudo cd > migrations/0001_initial.py' 'echo . | xargs cd > migrations/0001_initial.py' 'sudo cd src 2> migrations/0001_initial.py'; do
  blk edit-existing "$c"
done
tm "Monitor > /dev/..ABS → ask" ask "echo x > '/dev/..$T_PROJ/migrations/0001_initial.py'"
blk destructive-schema "cat > '/dev/..$T_PROJ/migrations/0009_new.py' <<'X'"$'\nop.drop_table("users")\nX'
crt "echo x > '/dev/..$T_PROJ/migrations/0009_new.py'"
for c in 'echo x > /dev/null; cat migrations/0001_initial.py' 'ls migrations 2> /dev/stderr' "perl -0ne 'print' migrations/0001_initial.py" \
  "perl -lne 'print' migrations/0001_initial.py" "perl -0777 -ne 'print' migrations/0001_initial.py" \
  "sed --quiet --expression=p migrations/0001_initial.py" 'sudo cd /tmp > /dev/null; ls migrations'; do
  pas "$c"
done
C=$(rep 'cd src' 3000 'echo x > migrations/0001_initial.py'); tb '3000 relative cd segments + existing write → ask' ask "$C"; assert_rc '3000 cd src' 0
t_report
