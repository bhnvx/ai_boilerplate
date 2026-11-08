#!/usr/bin/env bash
# tests/hooks/test-lib-parse-5.sh — lib/shellparse.sh 라운드 3: 컨테이너 런타임(항목 1)·접두 래퍼(항목 2)·셸 문자열 실행기(항목 3).
# 새 형태는 원래 줄을 바꾸지 않고 B 묶음을 더한다: 런타임·래퍼 줄 + push + 안쪽 명령(+ sh -c 의 sub) + pop + 같은 줄.
# 옵션 인수 개수를 모르는 형태·명령이 없는 형태는 라운드 2 출력 그대로(벗기지 않음)인지 함께 고정한다.
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
. "$T_HOOKS/lib/shellparse.sh"
t_setup

NL=$'\n'
segs() { sp_segments "$1" | sed $'s/\t/ <T> /g'; }
seg_case() { assert_eq "seg: $1" "$3" "$(segs "$2")"; }   # <name> <command> <expected lines, fields joined by " <T> ">
kl() { printf '%s <T> %s <T> %s' "$1" "$2" "${3:-$2}"; }               # <kind> <masked> [raw] — 한 줄
c1() { kl cmd "$1" "${2:-$1}"; }
grp() { printf 'push <T> ( <T> (\nsub <T> %s <T> %s\npop <T> ) <T> )' "$1" "${2:-$1}"; }   # 라운드 2 실행기 묶음(push/sub/pop)
blk() {  # <kind> <masked> <raw> <inner line>... — B 묶음: 줄 + push + 안쪽 줄들 + pop + 같은 줄
  local k=$1 m=$2 r=$3 b l; shift 3
  b="$(kl "$k" "$m" "$r")${NL}push <T> ( <T> ("
  for l in "$@"; do b="$b${NL}$l"; done
  printf '%s' "$b${NL}pop <T> ) <T> )${NL}$(kl "$k" "$m" "$r")"
}
same() { seg_case "$1 (그대로)" "$1" "$(c1 "${2:-$1}" "${3:-$1}")"; }   # 벗기지 않는 형태: 한 줄 그대로
sub1() { printf 'sub <T> %s <T> %s' "$1" "${2:-$1}"; }

t_section "항목 1: podman·nerdctl exec|run 과 docker run·docker container exec|run·docker-compose exec|run"
R='podman exec web sh -c "cat /app/.env"'
seg_case 'podman exec sh -c' "$R" "$(blk cmd 'podman exec web sh -c "Q"' "$R" "$(c1 'sh -c "Q"' 'sh -c "cat /app/.env"')" "$(sub1 'cat /app/.env')")"
seg_case 'podman exec -it' 'podman exec -it web cat .env' "$(blk cmd 'podman exec -it web cat .env' 'podman exec -it web cat .env' "$(c1 'cat .env')")"
seg_case 'podman container exec' 'podman container exec web cat .env' "$(blk cmd 'podman container exec web cat .env' 'podman container exec web cat .env' "$(c1 'cat .env')")"
R='podman run --rm -v "$PWD":/w img cat /w/.env'
seg_case 'podman run -v value' "$R" "$(blk cmd 'podman run --rm -v "Q":/w img cat /w/.env' "$R" "$(c1 'cat /w/.env')")"
seg_case 'podman global bool + run' 'podman --remote run --rm img ls' "$(blk cmd 'podman --remote run --rm img ls' 'podman --remote run --rm img ls' "$(c1 ls)")"
seg_case 'nerdctl exec' 'nerdctl exec web cat .env' "$(blk cmd 'nerdctl exec web cat .env' 'nerdctl exec web cat .env' "$(c1 'cat .env')")"
seg_case 'nerdctl -n run' 'nerdctl -n k8s.io run --rm img cat .env' "$(blk cmd 'nerdctl -n k8s.io run --rm img cat .env' 'nerdctl -n k8s.io run --rm img cat .env' "$(c1 'cat .env')")"
R='docker run --rm img sh -c "rm -rf /data"'
seg_case 'docker run sh -c' "$R" "$(blk cmd 'docker run --rm img sh -c "Q"' "$R" "$(c1 'sh -c "Q"' 'sh -c "rm -rf /data"')" "$(sub1 'rm -rf /data')")"
R='docker run --rm -it -v "$PWD":/app -w /app node:20 npm test'
seg_case 'docker run -v -w (corpus B419)' "$R" "$(blk cmd 'docker run --rm -it -v "Q":/app -w /app node:20 npm test' "$R" "$(c1 'npm test')")"
seg_case 'docker --context run' 'docker --context prod run --rm img ls' "$(blk cmd 'docker --context prod run --rm img ls' 'docker --context prod run --rm img ls' "$(c1 ls)")"
seg_case 'docker run bundle -itv value' 'docker run -itv /x:/y img ls' "$(blk cmd 'docker run -itv /x:/y img ls' 'docker run -itv /x:/y img ls' "$(c1 ls)")"
seg_case 'docker run attached -eA=1 --name=web' 'docker run -eA=1 --name=web img ls' "$(blk cmd 'docker run -eA=1 --name=web img ls' 'docker run -eA=1 --name=web img ls' "$(c1 ls)")"
seg_case 'docker container exec' 'docker container exec -it web cat .env' "$(blk cmd 'docker container exec -it web cat .env' 'docker container exec -it web cat .env' "$(c1 'cat .env')")"
seg_case 'docker container run' 'docker container run --rm img cat .env' "$(blk cmd 'docker container run --rm img cat .env' 'docker container run --rm img cat .env' "$(c1 'cat .env')")"
R='docker-compose exec web sh -c "rm -rf /app"'
seg_case 'docker-compose exec sh -c' "$R" "$(blk cmd 'docker-compose exec web sh -c "Q"' "$R" "$(c1 'sh -c "Q"' 'sh -c "rm -rf /app"')" "$(sub1 'rm -rf /app')")"
seg_case 'docker-compose -f run -e' 'docker-compose -f a.yml run --rm -e A=1 web pytest' "$(blk cmd 'docker-compose -f a.yml run --rm -e A=1 web pytest' 'docker-compose -f a.yml run --rm -e A=1 web pytest' "$(c1 pytest)")"
seg_case 'docker-compose exec -T --index' 'docker-compose exec -T --index 2 web ls' "$(blk cmd 'docker-compose exec -T --index 2 web ls' 'docker-compose exec -T --index 2 web ls' "$(c1 ls)")"
seg_case 'docker-compose run -- service' 'docker-compose run --rm -- web ls' "$(blk cmd 'docker-compose run --rm -- web ls' 'docker-compose run --rm -- web ls' "$(c1 ls)")"

t_section "항목 1: --entrypoint 는 안쪽 명령의 머리(빈 값은 이미지 기본값 초기화)"
R='docker run --entrypoint sh img -c "cat .env"'
seg_case '--entrypoint sh' "$R" "$(blk cmd 'docker run --entrypoint sh img -c "Q"' "$R" "$(c1 'sh -c "Q"' 'sh -c "cat .env"')" "$(sub1 'cat .env')")"
seg_case '--entrypoint=/bin/cat (경로를 뗀다)' 'docker run --entrypoint=/bin/cat img /app/.env' "$(blk cmd 'docker run --entrypoint=/bin/cat img /app/.env' 'docker run --entrypoint=/bin/cat img /app/.env' "$(c1 'cat /app/.env')")"
R='docker run --entrypoint "" img cat .env'
seg_case '--entrypoint "" (초기화)' "$R" "$(blk cmd 'docker run --entrypoint "Q" img cat .env' "$R" "$(c1 'cat .env')")"
seg_case 'docker-compose run --entrypoint (인수 없음)' 'docker-compose run --entrypoint printenv web' "$(blk cmd 'docker-compose run --entrypoint printenv web' 'docker-compose run --entrypoint printenv web' "$(c1 printenv)")"

t_section "항목 1: 종류·대입·이웃·중첩"
seg_case 'sudo podman (두 줄 모두 +sudo)' 'sudo podman exec web cat .env' "$(blk cmd+sudo 'podman exec web cat .env' 'podman exec web cat .env' "$(kl cmd+sudo 'cat .env')")"
seg_case 'podman exec … sudo (안쪽만 +sudo)' 'podman exec web sudo cat .env' "$(blk cmd 'podman exec web sudo cat .env' 'podman exec web sudo cat .env' "$(kl cmd+sudo 'cat .env')")"
seg_case 'assign before runtime' 'HUSKY=0 podman exec web git commit -m x' "assign <T> HUSKY=0 <T> HUSKY=0${NL}$(blk cmd 'podman exec web git commit -m x' 'podman exec web git commit -m x' "$(c1 'git commit -m x')")"
seg_case 'pipe: next segment still follows the runtime line' 'podman exec web cat x | xargs rm -rf' "$(blk cmd 'podman exec web cat x' 'podman exec web cat x' "$(c1 'cat x')")${NL}$(kl cmd+xargs 'rm -rf')"
seg_case 'wrapper then runtime: one group' 'caffeinate -i podman exec web cat .env' "$(blk cmd 'caffeinate -i podman exec web cat .env' 'caffeinate -i podman exec web cat .env' "$(c1 'cat .env')")"
seg_case 'runtime then wrapper: one group' 'podman exec web caffeinate -i cat .env' "$(blk cmd 'podman exec web caffeinate -i cat .env' 'podman exec web caffeinate -i cat .env' "$(c1 'cat .env')")"
seg_case 'kubectl exec keeps its own shape' 'kubectl exec pod -- podman exec ctr cat .env' "$(c1 'kubectl exec pod -- podman exec ctr cat .env')${NL}$(c1 'cat .env')"
seg_case 'docker exec keeps its own shape' 'docker exec ctr flock /tmp/l rm -rf /' "$(blk cmd 'flock /tmp/l rm -rf /' 'flock /tmp/l rm -rf /' "$(c1 'rm -rf /')")"

t_section "항목 1: 벗기지 않는 형태(라운드 2 출력 그대로)"
FX='podman run --foo bar img bash -c "Q"'; FR='podman run --foo bar img bash -c "make test"'
seg_case 'unknown option: round-2 podman sh -c group' "$FR" "$(c1 "$FX" "$FR")${NL}$(grp 'make test')${NL}$(c1 "$FX" "$FR")"
same 'podman run --foo bar img cat .env'
same 'docker run $OPTS img cat .env'
same 'docker run hello-world'
same 'docker run --rm -p 8000:8000 fp-app:dev'
same 'docker run --rm'
same 'podman exec -l cat .env'
same 'docker create img ls'
same 'nerdctl compose exec web ls'
same 'docker-compose up -d'
same 'docker-compose run --rm web'
same 'docker run --rm --entrypoint sh'
seg_case 'docker exec (existing shape)' 'docker exec ctr cat .env' "$(c1 'cat .env')"
seg_case 'docker compose run (existing shape)' 'docker compose run --rm web pytest -q' "$(c1 'pytest -q')"
seg_case 'kubectl exec (existing shape)' 'kubectl exec pod -- ls' "$(c1 'kubectl exec pod -- ls')${NL}$(c1 ls)"

t_section "항목 2: 접두 래퍼(flock·mise exec|x·caffeinate·chrt·ionice·taskset·setsid·unbuffer)"
R="flock /tmp/l sed -i 's/a/b/' migrations/0001_initial.py 2>&1"
seg_case 'flock file cmd' "$R" "$(blk cmd "flock /tmp/l sed -i 'Q' migrations/0001_initial.py 2>&1" "$R" "$(c1 "sed -i 'Q' migrations/0001_initial.py 2>&1" "sed -i 's/a/b/' migrations/0001_initial.py 2>&1")")"
seg_case 'flock -w -E file cmd' 'flock -w 5 -E 3 /tmp/l rm -rf x' "$(blk cmd 'flock -w 5 -E 3 /tmp/l rm -rf x' 'flock -w 5 -E 3 /tmp/l rm -rf x' "$(c1 'rm -rf x')")"
seg_case 'flock fd-like name then cmd' 'flock 9 rm x' "$(blk cmd 'flock 9 rm x' 'flock 9 rm x' "$(c1 'rm x')")"
R="mise exec -- sed -i 's/a/b/' x 2>/dev/null"
seg_case 'mise exec --' "$R" "$(blk cmd "mise exec -- sed -i 'Q' x 2>/dev/null" "$R" "$(c1 "sed -i 'Q' x 2>/dev/null" "sed -i 's/a/b/' x 2>/dev/null")")"
seg_case 'mise x tool@ver --' 'mise x node@20 -- node app.js' "$(blk cmd 'mise x node@20 -- node app.js' 'mise x node@20 -- node app.js' "$(c1 'node app.js')")"
seg_case 'mise exec tools --' 'mise exec node@20 python@3.12 -- cat .env' "$(blk cmd 'mise exec node@20 python@3.12 -- cat .env' 'mise exec node@20 python@3.12 -- cat .env' "$(c1 'cat .env')")"
seg_case 'caffeinate -i tee < 2>&1' 'caffeinate -i tee migrations/0001_initial.py < x.py 2>&1' "$(blk cmd 'caffeinate -i tee migrations/0001_initial.py < x.py 2>&1' 'caffeinate -i tee migrations/0001_initial.py < x.py 2>&1' "$(c1 'tee migrations/0001_initial.py < x.py 2>&1')")"
seg_case 'caffeinate -dims -t -w' 'caffeinate -dims -t 60 -w 123 python manage.py migrate' "$(blk cmd 'caffeinate -dims -t 60 -w 123 python manage.py migrate' 'caffeinate -dims -t 60 -w 123 python manage.py migrate' "$(c1 'python manage.py migrate')")"
seg_case 'chrt policy prio' 'chrt -f 99 rm -rf /' "$(blk cmd 'chrt -f 99 rm -rf /' 'chrt -f 99 rm -rf /' "$(c1 'rm -rf /')")"
seg_case 'ionice -c3' 'ionice -c3 rm -rf /' "$(blk cmd 'ionice -c3 rm -rf /' 'ionice -c3 rm -rf /' "$(c1 'rm -rf /')")"
seg_case 'ionice -c 2 -n 7' 'ionice -c 2 -n 7 cat .env' "$(blk cmd 'ionice -c 2 -n 7 cat .env' 'ionice -c 2 -n 7 cat .env' "$(c1 'cat .env')")"
seg_case 'taskset -c list' 'taskset -c 0,1 make' "$(blk cmd 'taskset -c 0,1 make' 'taskset -c 0,1 make' "$(c1 make)")"
seg_case 'taskset mask' 'taskset 0x3 cat .env' "$(blk cmd 'taskset 0x3 cat .env' 'taskset 0x3 cat .env' "$(c1 'cat .env')")"
seg_case 'setsid -f' 'setsid -f cat .env' "$(blk cmd 'setsid -f cat .env' 'setsid -f cat .env' "$(c1 'cat .env')")"
seg_case 'unbuffer -p' 'unbuffer -p rm -rf x' "$(blk cmd 'unbuffer -p rm -rf x' 'unbuffer -p rm -rf x' "$(c1 'rm -rf x')")"
seg_case 'sudo flock' 'sudo flock /tmp/l rm -rf /x' "$(blk cmd+sudo 'flock /tmp/l rm -rf /x' 'flock /tmp/l rm -rf /x' "$(kl cmd+sudo 'rm -rf /x')")"
seg_case 'pipe into wrapped xargs' 'echo / | caffeinate -i xargs rm -rf' "$(c1 'echo /')${NL}$(blk cmd 'caffeinate -i xargs rm -rf' 'caffeinate -i xargs rm -rf' "$(kl cmd+xargs 'rm -rf')")"
seg_case 'wrapped cd stays inside push/pop' 'caffeinate -i cd /tmp; rm -rf build' "$(blk cmd 'caffeinate -i cd /tmp' 'caffeinate -i cd /tmp' "$(c1 'cd /tmp')")${NL}$(c1 'rm -rf build')"
seg_case 'CAFFEINATE (대소문자 무시)' 'CAFFEINATE -i rm -rf /' "$(blk cmd 'caffeinate -i rm -rf /' 'caffeinate -i rm -rf /' "$(c1 'rm -rf /')")"
seg_case 'nested wrappers: one group' 'caffeinate -dims flock -w 5 /tmp/l rm -rf /' "$(blk cmd 'caffeinate -dims flock -w 5 /tmp/l rm -rf /' 'caffeinate -dims flock -w 5 /tmp/l rm -rf /' "$(c1 'rm -rf /')")"

t_section "항목 2: 벗기지 않는 형태"
same 'caffeinate'
same 'caffeinate -d'
same 'flock /tmp/l'
same 'chrt -p 99 1234'
same 'chrt -m'
same 'chrt -f x cat .env'
same 'ionice -p 1234'
same 'taskset -p 0x3 1234'
same 'taskset zz cat .env'
same 'mise run test'
same 'mise install'
same 'mise exec node@20'
same 'mise exec --'
same "flock -c 'x' /tmp/l" "flock -c 'Q' /tmp/l"   # -c 는 잠금 파일 뒤에만 온다(앞이면 flock 이 오류)
same 'setsid --foo x'
same 'caffeinate -x cat .env'

t_section "항목 3: 셸 문자열 실행기(flock 파일 -c · mise exec -c · script -c · runuser -c · su -lc/--command)"
for R in "flock /tmp/l -c 'cat .env'" "flock -n /tmp/l --command 'cat .env'" "mise exec -c 'cat .env'" "mise x --command='cat .env'" \
  "script -c 'cat .env' /dev/null" "script -qc 'cat .env' /dev/null" "script --command='cat .env' out.log" "script -c'cat .env' /dev/null" \
  "runuser -l app -c 'cat .env'" "runuser app --command 'cat .env'" "su -lc 'cat .env' app" "su --command='cat .env' app" "su --command 'cat .env' app"; do
  pre=${R%%"'cat .env'"*}; suf=${R#*"'cat .env'"}; M="$pre'Q'$suf"   # 치환 문자열 없이(bash 5 의 patsub_replacement 와 무관)
  seg_case "$R" "$R" "$(c1 "$M" "$R")${NL}$(grp 'cat .env')${NL}$(c1 "$M" "$R")"
done
seg_case 'su -c (existing plain sub)' "su -c 'cat .env' app" "$(c1 "su -c 'Q' app" "su -c 'cat .env' app")${NL}$(sub1 'cat .env')"
R="chroot /mnt sh -c 'rm -rf /'"
seg_case 'chroot dir sh -c' "$R" "$(blk cmd "chroot /mnt sh -c 'Q'" "$R" "$(c1 "sh -c 'Q'" "sh -c 'rm -rf /'")" "$(sub1 'rm -rf /')")"
seg_case 'chroot --userspec= dir cmd' 'chroot --userspec=app:app /srv/root cat .env' "$(blk cmd 'chroot --userspec=app:app /srv/root cat .env' 'chroot --userspec=app:app /srv/root cat .env' "$(c1 'cat .env')")"
R="unshare -rn sh -c 'cat .env'"
seg_case 'unshare -rn sh -c' "$R" "$(blk cmd "unshare -rn sh -c 'Q'" "$R" "$(c1 "sh -c 'Q'" "sh -c 'cat .env'")" "$(sub1 'cat .env')")"
seg_case 'unshare long bools' 'unshare --mount --pid --fork rm -rf /' "$(blk cmd 'unshare --mount --pid --fork rm -rf /' 'unshare --mount --pid --fork rm -rf /' "$(c1 'rm -rf /')")"
R="systemd-run --user --unit=x sh -c 'cat .env'"
seg_case 'systemd-run --unit= sh -c' "$R" "$(blk cmd "systemd-run --user --unit=x sh -c 'Q'" "$R" "$(c1 "sh -c 'Q'" "sh -c 'cat .env'")" "$(sub1 'cat .env')")"
seg_case 'systemd-run -p value' 'systemd-run --scope -p MemoryMax=1G rm -rf /' "$(blk cmd 'systemd-run --scope -p MemoryMax=1G rm -rf /' 'systemd-run --scope -p MemoryMax=1G rm -rf /' "$(c1 'rm -rf /')")"
seg_case 'runuser -u user -- cmd' 'runuser -u app -- cat .env' "$(blk cmd 'runuser -u app -- cat .env' 'runuser -u app -- cat .env' "$(c1 'cat .env')")"
seg_case 'script -q file cmd (BSD)' 'script -q /dev/null cat .env' "$(blk cmd 'script -q /dev/null cat .env' 'script -q /dev/null cat .env' "$(c1 'cat .env')")"

t_section "항목 3: 벗기지 않는 형태"
same 'script out.log'
same 'script -q out.log'
same 'script -t 0 out.log'
same 'chroot /mnt'
same 'unshare -r'
same 'systemd-run --user'
same 'runuser app'
same 'su root'
same 'su -'

t_section "sp_tokens·sp_words·sp_tokens_lines 는 바뀌지 않는다"
assert_eq 'tokens: podman sh -c' 'podman|exec|web|sh|-c|cat /app/.env|' "$(sp_tokens 'podman exec web sh -c "cat /app/.env"' | tr '\n' '|')"
assert_eq 'words: flock -c' "flock|/tmp/l|-c|cat .env|" "$(sp_words "flock /tmp/l -c 'cat .env'" | tr '\n' '|')"
assert_eq 'tokens_lines: wrapper' 'caffeinate|-i|rm|-rf|/|__SP_SEG__|' "$(sp_tokens_lines 'caffeinate -i rm -rf /' | tr '\n' '|')"

t_section "라운드 3b: 따옴표·역슬래시 친 -c 도 안쪽 문자열을 sub 으로 낸다(원래 none 이던 우회 차단)"
# 최상위 셸: cmd + sub. "-c" '-c' \-c -"c" "-lc" 를 -c 로 보고 unq(uqt) 로 찾는다.
seg_case 'sh "-c"'   "sh \"-c\" 'cat .env'"   "$(c1 "sh \"Q\" 'Q'" "sh \"-c\" 'cat .env'")${NL}$(sub1 'cat .env')"
seg_case "sh '-c'"   "sh '-c' 'cat .env'"     "$(c1 "sh 'Q' 'Q'" "sh '-c' 'cat .env'")${NL}$(sub1 'cat .env')"
seg_case 'sh \-c'    "sh \\-c 'cat .env'"     "$(c1 "sh \\-c 'Q'" "sh \\-c 'cat .env'")${NL}$(sub1 'cat .env')"
seg_case 'sh -"c"'   "sh -\"c\" 'cat .env'"   "$(c1 "sh -\"Q\" 'Q'" "sh -\"c\" 'cat .env'")${NL}$(sub1 'cat .env')"
seg_case 'bash "-lc"' "bash \"-lc\" 'cat .env'" "$(c1 "bash \"Q\" 'Q'" "bash \"-lc\" 'cat .env'")${NL}$(sub1 'cat .env')"
seg_case 'su "-c"'   "su \"-c\" 'cat .env' app" "$(c1 "su \"Q\" 'Q' app" "su \"-c\" 'cat .env' app")${NL}$(sub1 'cat .env')"
# find -exec: cmd + 실행기 묶음 + cmd
FR="find . -maxdepth 0 -exec sh \"-c\" 'cat .env' \\;"; FM="find . -maxdepth 0 -exec sh \"Q\" 'Q' \\;"
seg_case 'find -exec sh "-c"' "$FR" "$(c1 "$FM" "$FR")${NL}$(grp 'cat .env')${NL}$(c1 "$FM" "$FR")"
FR="find . -maxdepth 0 -exec sh '-c' 'rm -rf /' \\;"; FM="find . -maxdepth 0 -exec sh 'Q' 'Q' \\;"
seg_case "find -exec sh '-c'" "$FR" "$(c1 "$FM" "$FR")${NL}$(grp 'rm -rf /')${NL}$(c1 "$FM" "$FR")"
# flock·script·runuser·mise 실행기의 따옴표 친 -c/--command: cmd + 묶음 + cmd
R="flock /tmp/l \"-c\" 'cat .env'"; M="flock /tmp/l \"Q\" 'Q'"
seg_case 'flock "-c"' "$R" "$(c1 "$M" "$R")${NL}$(grp 'cat .env')${NL}$(c1 "$M" "$R")"
R="flock /tmp/l '--command' 'cat .env'"; M="flock /tmp/l 'Q' 'Q'"
seg_case "flock '--command'" "$R" "$(c1 "$M" "$R")${NL}$(grp 'cat .env')${NL}$(c1 "$M" "$R")"
R="script \"-c\" 'cat .env' /dev/null"; M="script \"Q\" 'Q' /dev/null"
seg_case 'script "-c"' "$R" "$(c1 "$M" "$R")${NL}$(grp 'cat .env')${NL}$(c1 "$M" "$R")"
R="runuser \"-c\" 'cat .env' app"; M="runuser \"Q\" 'Q' app"
seg_case 'runuser "-c"' "$R" "$(c1 "$M" "$R")${NL}$(grp 'cat .env')${NL}$(c1 "$M" "$R")"
R="mise exec \"-c\" 'cat .env'"; M="mise exec \"Q\" 'Q'"
seg_case 'mise exec "-c"' "$R" "$(c1 "$M" "$R")${NL}$(grp 'cat .env')${NL}$(c1 "$M" "$R")"
# mise exec "--" (따옴표 친 구분자)도 -- 처럼 래퍼로 벗긴다(안쪽 psql, sub 없음)
R="mise exec \"--\" psql -c 'DROP TABLE t'"
seg_case 'mise exec "--"' "$R" "$(blk cmd "mise exec \"Q\" psql -c 'Q'" "$R" "$(c1 "psql -c 'Q'" "psql -c 'DROP TABLE t'")")"

t_section "라운드 3b: 벗긴 컨테이너 안쪽이 prefix(busybox·tini·gosu) 뒤 중첩 sh -c 면 그 문자열도 검사(r2b podman 복원)"
R="podman run -i img busybox sh -c 'cat .env'"
seg_case 'podman run busybox sh -c' "$R" "$(blk cmd "podman run -i img busybox sh -c 'Q'" "$R" "$(c1 "busybox sh -c 'Q'" "busybox sh -c 'cat .env'")" "$(sub1 'cat .env')")"
R="podman exec -i web tini -- sh -c 'cat .env'"
seg_case 'podman exec tini -- sh -c' "$R" "$(blk cmd "podman exec -i web tini -- sh -c 'Q'" "$R" "$(c1 "tini -- sh -c 'Q'" "tini -- sh -c 'cat .env'")" "$(sub1 'cat .env')")"
R="podman container run -i img gosu app sh -c 'rm -rf /'"
seg_case 'podman gosu sh -c' "$R" "$(blk cmd "podman container run -i img gosu app sh -c 'Q'" "$R" "$(c1 "gosu app sh -c 'Q'" "gosu app sh -c 'rm -rf /'")" "$(sub1 'rm -rf /')")"
R="podman run -i img /opt/bin/bash -c 'cat .env'"
seg_case 'podman /opt/bin/bash -c (비정규 경로)' "$R" "$(blk cmd "podman run -i img /opt/bin/bash -c 'Q'" "$R" "$(c1 "/opt/bin/bash -c 'Q'" "/opt/bin/bash -c 'cat .env'")" "$(sub1 'cat .env')")"
R="podman run -i img DASH -c 'cat .env'"
seg_case 'podman DASH -c (대문자)' "$R" "$(blk cmd "podman run -i img DASH -c 'Q'" "$R" "$(c1 "DASH -c 'Q'" "DASH -c 'cat .env'")" "$(sub1 'cat .env')")"
R="docker run --rm img dumb-init sh -c 'cat .env'"
seg_case 'docker run dumb-init sh -c' "$R" "$(blk cmd "docker run --rm img dumb-init sh -c 'Q'" "$R" "$(c1 "dumb-init sh -c 'Q'" "dumb-init sh -c 'cat .env'")" "$(sub1 'cat .env')")"
R="nerdctl run -i img tini -- sh -c 'cat .env'"
seg_case 'nerdctl run tini -- sh -c' "$R" "$(blk cmd "nerdctl run -i img tini -- sh -c 'Q'" "$R" "$(c1 "tini -- sh -c 'Q'" "tini -- sh -c 'cat .env'")" "$(sub1 'cat .env')")"
R="docker-compose exec web busybox sh -c 'cat .env'"
seg_case 'docker-compose exec busybox sh -c' "$R" "$(blk cmd "docker-compose exec web busybox sh -c 'Q'" "$R" "$(c1 "busybox sh -c 'Q'" "busybox sh -c 'cat .env'")" "$(sub1 'cat .env')")"

t_section "라운드 3b: 바뀌지 않아야 하는 형태(중복 sub 없음·래퍼/최상위는 중첩 스캔 안 함)"
R="podman run -i img sh -c 'cat .env'"
seg_case 'podman run sh -c (안쪽 머리가 셸: sub 1개)' "$R" "$(blk cmd "podman run -i img sh -c 'Q'" "$R" "$(c1 "sh -c 'Q'" "sh -c 'cat .env'")" "$(sub1 'cat .env')")"
R="caffeinate -i busybox sh -c 'cat .env'"
seg_case 'caffeinate busybox sh -c (래퍼: 중첩 스캔 안 함)' "$R" "$(blk cmd "caffeinate -i busybox sh -c 'Q'" "$R" "$(c1 "busybox sh -c 'Q'" "busybox sh -c 'cat .env'")")"
same "busybox sh -c 'cat .env'" "busybox sh -c 'Q'"

t_section "라운드 3b: 시간 한도 — 중첩 sh -c 컨테이너 세그먼트도 선형(200개 < 3000ms)"
t_ms() { if command -v python3 >/dev/null 2>&1; then python3 -I -S -c 'import time; print(int(time.time()*1000))'; elif command -v perl >/dev/null 2>&1; then perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; else echo 0; fi; }
t_under() { [ "$2" -lt "$3" ] && t_pass "$1 (${2}ms < ${3}ms)" || t_fail "$1" "${2}ms ≥ ${3}ms"; }
nested=$(awk 'BEGIN{for(i=0;i<200;i++) printf "docker run --rm img busybox sh -c %cecho x%c; ", 39, 39}')
t0=$(t_ms); out=$(sp_segments "$nested"); t1=$(t_ms)
assert_eq 'R3b: 200개 중첩 컨테이너 → sub 200개' 200 "$(printf '%s\n' "$out" | grep -c '^sub')"
t_under "R3b: sp_segments 200개 중첩 sh -c 컨테이너 (${#nested} bytes)" $((t1 - t0)) 3000

t_section "라운드 3b 검증: 셸 -c 뒤 옵션(-- - -x -e -o 이름)을 건너뛴 첫 인수가 문자열(POSIX sh -c [옵션] 문자열)"
seg_case 'sh -c --' "sh -c -- 'cat .env'" "$(c1 "sh -c -- 'Q'" "sh -c -- 'cat .env'")${NL}$(sub1 'cat .env')"
seg_case 'bash -c -x' "bash -c -x 'cat .env'" "$(c1 "bash -c -x 'Q'" "bash -c -x 'cat .env'")${NL}$(sub1 'cat .env')"
seg_case 'bash -c -o pipefail' "bash -c -o pipefail 'cat .env'" "$(c1 "bash -c -o pipefail 'Q'" "bash -c -o pipefail 'cat .env'")${NL}$(sub1 'cat .env')"
seg_case 'bash -co pipefail' "bash -co pipefail 'cat .env'" "$(c1 "bash -co pipefail 'Q'" "bash -co pipefail 'cat .env'")${NL}$(sub1 'cat .env')"
seg_case 'sh -c - (단독 -)' "sh -c - 'cat .env'" "$(c1 "sh -c - 'Q'" "sh -c - 'cat .env'")${NL}$(sub1 'cat .env')"
seg_case 'sh -c +x "-e"' "sh -c +x \"-e\" 'cat .env'" "$(c1 "sh -c +x \"Q\" 'Q'" "sh -c +x \"-e\" 'cat .env'")${NL}$(sub1 'cat .env')"
seg_case 'sh -c 문자열 뒤 -x 는 인수(그대로)' "sh -c 'echo hi' -x" "$(c1 "sh -c 'Q' -x" "sh -c 'echo hi' -x")${NL}$(sub1 'echo hi')"
FR="find . -maxdepth 0 -exec sh -c -- 'cat .env' \\;"; FM="find . -maxdepth 0 -exec sh -c -- 'Q' \\;"
seg_case 'find -exec sh -c --' "$FR" "$(c1 "$FM" "$FR")${NL}$(grp 'cat .env')${NL}$(c1 "$FM" "$FR")"

t_section "라운드 3b 검증: 경로·대문자 셸 이름(/opt/homebrew/opt/bash/bin/bash · DASH · KSH)도 셸 -c 로(최상위)"
seg_case 'homebrew opt bash' "/opt/homebrew/opt/bash/bin/bash -c 'cat .env'" "$(c1 "/opt/homebrew/opt/bash/bin/bash -c 'Q'" "/opt/homebrew/opt/bash/bin/bash -c 'cat .env'")${NL}$(sub1 'cat .env')"
seg_case 'DASH -c' "DASH -c 'cat .env'" "$(c1 "DASH -c 'Q'" "DASH -c 'cat .env'")${NL}$(sub1 'cat .env')"
seg_case 'KSH -lc' "KSH -lc 'cat .env'" "$(c1 "KSH -lc 'Q'" "KSH -lc 'cat .env'")${NL}$(sub1 'cat .env')"
same "bashful -c 'cat .env'" "bashful -c 'Q'"

t_section "라운드 3b 검증: 래퍼·실행기의 따옴표 친 옵션(\"-n\" \"-u\" '-s' \"-S\" \"-exec\")도 옵션으로 건너뛴다"
seg_case 'nice "-n"' "nice \"-n\" 5 cat .env" "$(c1 'cat .env')"
seg_case 'sudo "-u"' "sudo \"-u\" root cat .env" "$(kl cmd+sudo 'cat .env')"
seg_case "timeout '-s'" "timeout '-s' KILL 5 cat .env" "$(c1 'cat .env')"
seg_case 'xargs "-I"' "xargs \"-I\" {} cat {}" "$(kl cmd+xargs 'cat {}')"
seg_case 'env "-S"' "env \"-S\" 'cat .env'" "$(c1 "env \"Q\" 'Q'" "env \"-S\" 'cat .env'")${NL}$(grp 'cat .env')"
seg_case 'watch "-n"' "watch \"-n\" 1 cat .env" "$(c1 'watch "Q" 1 cat .env' 'watch "-n" 1 cat .env')${NL}$(grp 'cat .env')${NL}$(c1 'watch "Q" 1 cat .env' 'watch "-n" 1 cat .env')"
FR="find . -maxdepth 0 \"-exec\" sh -c 'cat .env' \\;"; FM="find . -maxdepth 0 \"Q\" sh -c 'Q' \\;"
seg_case 'find "-exec"' "$FR" "$(c1 "$FM" "$FR")${NL}$(grp 'cat .env')${NL}$(c1 "$FM" "$FR")"
same 'command "-v" rm' 'command "Q" rm'

t_section "라운드 3b 검증: su·runuser 는 -- 뒤 인수를 사용자의 셸이 받는다(셸 -c 묶음)"
R="su -- app -lc 'cat .env'"; M="su -- app -lc 'Q'"
seg_case 'su -- app -lc' "$R" "$(c1 "$M" "$R")${NL}$(grp 'cat .env')${NL}$(c1 "$M" "$R")"
R="su \"--\" app -lc 'cat .env'"; M="su \"Q\" app -lc 'Q'"
seg_case 'su "--" app -lc' "$R" "$(c1 "$M" "$R")${NL}$(grp 'cat .env')${NL}$(c1 "$M" "$R")"
R="runuser -- app -c 'cat .env'"; M="runuser -- app -c 'Q'"
seg_case 'runuser -- app -c' "$R" "$(c1 "$M" "$R")${NL}$(grp 'cat .env')${NL}$(c1 "$M" "$R")"
same 'su -- app'

t_section "라운드 3b 검증: 따옴표 친 묶음에 붙은 -c 값은 따옴표를 벗긴 단어에서 자른다(어긋나지 않게)"
R="script \"-qccat .env\" /dev/null"; M="script \"Q\" /dev/null"
seg_case 'script "-qc…" (따옴표 친 붙은 값: 어긋나지 않게)' "$R" "$(c1 "$M" "$R")${NL}$(grp 'cat .env')${NL}$(c1 "$M" "$R")"

t_section "라운드 3b 검증: 시간 한도 — -c 뒤 옵션 2000개 · su -- 뒤 인수 2000개 · 따옴표 친 옵션 1000쌍도 선형(< 3000ms)"
long=$(awk 'BEGIN{printf "sh -c"; for(i=0;i<2000;i++) printf " -x"; printf " %cecho x%c", 39, 39}')
t0=$(t_ms); out=$(sp_segments "$long"); t1=$(t_ms)
assert_eq 'R3b 검증: -c 뒤 옵션 2000개 → sub 1개(echo x)' 'echo x' "$(printf '%s\n' "$out" | awk -F'\t' '$1=="sub"{print $3}')"
t_under "R3b 검증: sp_segments sh -c + 옵션 2000개 (${#long} bytes)" $((t1 - t0)) 3000
long=$(awk 'BEGIN{printf "su -- app"; for(i=0;i<2000;i++) printf " %ca%d%c", 34, i, 34; printf " -lc %cecho x%c", 39, 39}')
t0=$(t_ms); out=$(sp_segments "$long"); t1=$(t_ms)
assert_eq 'R3b 검증: su -- 뒤 인수 2000개 → 묶음 1개' 1 "$(printf '%s\n' "$out" | grep -c '^sub')"
t_under "R3b 검증: sp_segments su -- + 인수 2000개 (${#long} bytes)" $((t1 - t0)) 3000
long=$(awk 'BEGIN{printf "nice"; for(i=0;i<1000;i++) printf " %c-n%c 5", 34, 34; printf " cat .env"}')
t0=$(t_ms); out=$(sp_segments "$long"); t1=$(t_ms)
assert_eq 'R3b 검증: 따옴표 친 옵션 1000쌍 → 안쪽 cat .env' 'cat .env' "$(printf '%s\n' "$out" | awk -F'\t' '$1=="cmd"{print $3}')"
t_under "R3b 검증: sp_segments nice \"-n\" 5 x1000 (${#long} bytes)" $((t1 - t0)) 3000
t_report
