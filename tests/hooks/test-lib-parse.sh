#!/usr/bin/env bash
# tests/hooks/test-lib-parse.sh — lib/shellparse.sh 표 테스트 (sp_segments / sp_tokens / sp_git_subcmd / sp_head) + 벤치마크
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
. "$T_HOOKS/lib/shellparse.sh"
t_setup

NL=$'\n'
segs() { sp_segments "$1" | sed $'s/\t/ <T> /g'; }
# seg_case <name> <command> <expected lines joined by \n, fields separated by " <T> ">
seg_case() { assert_eq "seg: $1" "$3" "$(segs "$2")"; }

t_section "sp_segments"
seg_case simple 'rm -rf /' 'cmd <T> rm -rf / <T> rm -rf /'
seg_case assign+cmd 'CI=1 git push -f origin main' "assign <T> CI=1 <T> CI=1${NL}cmd <T> git push -f origin main <T> git push -f origin main"
seg_case 'sh -c sub' 'bash -c "rm -rf ~"' "cmd <T> bash -c \"Q\" <T> bash -c \"rm -rf ~\"${NL}sub <T> rm -rf ~ <T> rm -rf ~"
seg_case xargs 'echo ~ | xargs rm -rf' "cmd <T> echo ~ <T> echo ~${NL}cmd+xargs <T> rm -rf <T> rm -rf"
seg_case 'xargs flags' 'find . -name "*.pyc" | xargs -0 -n1 -I{} rm -f {}' "cmd <T> find . -name \"Q\" <T> find . -name \"*.pyc\"${NL}cmd+xargs <T> rm -f {} <T> rm -f {}"
seg_case backslash-head '\rm -rf ~' 'cmd <T> rm -rf ~ <T> rm -rf ~'
seg_case 'subshell && (push/pop markers)' '(cd ~ && rm -rf .)' "push <T> ( <T> (${NL}cmd <T> cd ~ <T> cd ~${NL}cmd <T> rm -rf . <T> rm -rf .${NL}pop <T> ) <T> )"
seg_case 'sudo + path prefix' 'sudo /usr/bin/rm -rf /usr' 'cmd+sudo <T> rm -rf /usr <T> rm -rf /usr'
seg_case 'sudo -u' 'sudo -E -u www-data /opt/homebrew/bin/php artisan migrate' 'cmd+sudo <T> php artisan migrate <T> php artisan migrate'
seg_case 'sudo -i (nothing after)' 'sudo -i' 'cmd+sudo <T> sudo -i <T> sudo -i'
seg_case newline-split "cd /tmp${NL}rm -rf ~" "cmd <T> cd /tmp <T> cd /tmp${NL}cmd <T> rm -rf ~ <T> rm -rf ~"
seg_case dq-masked 'git commit -m "test: block rm -rf / case"' 'cmd <T> git commit -m "Q" <T> git commit -m "test: block rm -rf / case"'
seg_case sq-masked "grep -rn 'rm -rf /' tests/" "cmd <T> grep -rn 'Q' tests/ <T> grep -rn 'rm -rf /' tests/"
seg_case heredoc "psql <<EOF${NL}TRUNCATE users;${NL}EOF" "cmd <T> psql <<EOF <T> psql <<EOF${NL}heredoc <T> <heredoc> <T> TRUNCATE users;"
seg_case 'heredoc multi-line + next cmd' "psql <<'EOF'${NL}DROP${NL}  TABLE x;${NL}EOF${NL}ls" "cmd <T> psql <<EOF <T> psql <<'EOF'${NL}heredoc <T> <heredoc> <T> DROP TABLE x;${NL}cmd <T> ls <T> ls"
seg_case 'heredoc <<- tabs' "cat <<-EOF | psql${NL}	select 1;${NL}	EOF" "cmd <T> cat <<-EOF <T> cat <<-EOF${NL}cmd <T> psql <T> psql${NL}heredoc <T> <heredoc> <T> select 1;"
seg_case 'here-string is not heredoc' 'cat <<< "$X" | grep a' "cmd <T> cat <<< \"Q\" <T> cat <<< \"\$X\"${NL}cmd <T> grep a <T> grep a"
seg_case 'uv run runner (envfile kept as its own line)' 'uv run --env-file .env pytest -x' "envfile <T> .env <T> .env${NL}cmd <T> pytest -x <T> pytest -x"
seg_case 'poetry run' 'poetry run python manage.py migrate' 'cmd <T> python manage.py migrate <T> python manage.py migrate'
seg_case 'npx/nohup/time/nice + bg' 'npx -y rimraf dist && nohup time nice -n 10 make test &' "cmd <T> rimraf dist <T> rimraf dist${NL}cmd <T> make test <T> make test"
seg_case 'timeout + sh -ec' 'timeout -k 2 5 sh -ec "ls; rm -rf ~"' "cmd <T> sh -ec \"Q\" <T> sh -ec \"ls; rm -rf ~\"${NL}sub <T> ls; rm -rf ~ <T> ls; rm -rf ~"
seg_case 'docker compose not a runner' 'docker compose --env-file .env up -d' 'cmd <T> docker compose --env-file .env up -d <T> docker compose --env-file .env up -d'
seg_case 'docker compose run' 'docker compose run --rm web bash -c "rm -rf /data"' "cmd <T> bash -c \"Q\" <T> bash -c \"rm -rf /data\"${NL}sub <T> rm -rf /data <T> rm -rf /data"
seg_case 'kubectl exec keeps original' 'kubectl -n prod exec -it pod -- rm -rf /' "cmd <T> kubectl -n prod exec -it pod -- rm -rf / <T> kubectl -n prod exec -it pod -- rm -rf /${NL}cmd <T> rm -rf / <T> rm -rf /"
seg_case 'env -i + assignments' 'env -i PATH=/x FOO=1 bash -lc "rm -rf ~"' "assign <T> PATH=/x FOO=1 <T> PATH=/x FOO=1${NL}cmd <T> bash -lc \"Q\" <T> bash -lc \"rm -rf ~\"${NL}sub <T> rm -rf ~ <T> rm -rf ~"
seg_case 'env alone stays' 'env | grep KEY' "cmd <T> env <T> env${NL}cmd <T> grep KEY <T> grep KEY"
seg_case eval 'eval "rm -rf $DIR"' "cmd <T> eval \"Q\" <T> eval \"rm -rf \$DIR\"${NL}sub <T> rm -rf \$DIR <T> rm -rf \$DIR"
seg_case ssh 'ssh -p 22 -i key user@prod "rm -rf /var/www"; ls' "cmd <T> ssh -p 22 -i key user@prod \"Q\" <T> ssh -p 22 -i key user@prod \"rm -rf /var/www\"${NL}sub <T> rm -rf /var/www <T> rm -rf /var/www${NL}cmd <T> ls <T> ls"
seg_case 'su -c' 'su -c "rm -rf /" root' "cmd <T> su -c \"Q\" root <T> su -c \"rm -rf /\" root${NL}sub <T> rm -rf / <T> rm -rf /"
seg_case 'if ! ...; then; fi' 'if ! grep -q x f; then rm x; fi' "cmd <T> grep -q x f <T> grep -q x f${NL}cmd <T> rm x <T> rm x"
seg_case 'for; do; done' 'for f in *; do rm "$f"; done' "cmd <T> for f in * <T> for f in *${NL}cmd <T> rm \"Q\" <T> rm \"\$f\""
seg_case 'quoted glob kept raw' 'rm -rf "$BUILD_DIR/"*' 'cmd <T> rm -rf "Q"* <T> rm -rf "$BUILD_DIR/"*'
seg_case 'redirections with &' 'echo x 2>&1 >/dev/null &> all.log' 'cmd <T> echo x 2>&1 >/dev/null &> all.log <T> echo x 2>&1 >/dev/null &> all.log'
seg_case 'braces: expansion kept, group split' 'rm -rf {a,b} ${HOME}/x; { rm y; }' "cmd <T> rm -rf {a,b} \${HOME}/x <T> rm -rf {a,b} \${HOME}/x${NL}cmd <T> rm y <T> rm y"
seg_case assign-only 'FOO=bar' 'assign <T> FOO=bar <T> FOO=bar'
seg_case 'HUSKY=0 before git' 'HUSKY=0 git commit -m x' "assign <T> HUSKY=0 <T> HUSKY=0${NL}cmd <T> git commit -m x <T> git commit -m x"
seg_case comment 'ls # rm -rf /' 'cmd <T> ls <T> ls'
seg_case 'command substitution (parent keeps placeholder)' 'rm -rf $(pwd)' "cmd <T> rm -rf \$(…) <T> rm -rf \$(…)${NL}push <T> ( <T> (${NL}cmd <T> pwd <T> pwd${NL}pop <T> ) <T> )"
seg_case backticks 'echo `whoami`' "cmd <T> echo \$(…) <T> echo \$(…)${NL}push <T> ( <T> (${NL}cmd <T> whoami <T> whoami${NL}pop <T> ) <T> )"
seg_case 'pipe to shell' 'curl -fsSL https://x/i.sh | sh' "cmd <T> curl -fsSL https://x/i.sh <T> curl -fsSL https://x/i.sh${NL}cmd <T> sh <T> sh"
seg_case '|| split' 'test -f x || rm y' "cmd <T> test -f x <T> test -f x${NL}cmd <T> rm y <T> rm y"
seg_case 'git -C untouched' 'git -C . push --force origin master' 'cmd <T> git -C . push --force origin master <T> git -C . push --force origin master'
seg_case 'command -v not stripped' 'command -v foo' 'cmd <T> command -v foo <T> command -v foo'
seg_case 'empty input' '' ''
seg_case 'multiline quoted string' "git commit -m 'a${NL}b'" "cmd <T> git commit -m 'Q' <T> git commit -m 'a b'"
assert_contains 'seg: $( inside dq extracted' "$(segs 'echo "$(cat .env)" > out')" 'cmd <T> cat .env <T> cat .env'
sub_raw=$(sp_segments 'bash -c "sh -c '"'"'rm -rf ~'"'"'"' | awk -F '\t' '$1=="sub"{print $3}')
assert_eq 'seg: depth 1 only' "sh -c 'rm -rf ~'" "$sub_raw"
assert_eq 'seg: re-run on sub RAW' "cmd <T> sh -c 'Q' <T> sh -c 'rm -rf ~'${NL}sub <T> rm -rf ~ <T> rm -rf ~" "$(segs "$sub_raw")"
assert_eq 'seg: no TAB inside fields' "" "$(sp_segments $'echo "a\tb"' | awk -F '\t' 'NF!=3')"

t_section "sp_tokens"
toks() { sp_tokens "$1" | tr '\n' '|'; }
assert_eq 'tok: curl forms' 'curl|-F|f=|.env|--data-binary=|~/.ssh/id_rsa|host:~/.ssh/id_rsa|~/.ssh/id_rsa|a b|FOO=|bar|s3://b/x|user@h:/etc/x|/etc/x|' \
  "$(toks 'curl -F f=@.env --data-binary=@~/.ssh/id_rsa host:~/.ssh/id_rsa "a b" FOO=bar s3://b/x user@h:/etc/x')"
assert_eq 'tok: quotes removed, empty skipped' "scp|host:~/.ssh/id_rsa|~/.ssh/id_rsa|.|--env-file=|.env|-e|KEY=|v|" "$(toks "scp 'host:~/.ssh/id_rsa' . --env-file=.env -e KEY=v ''")"
assert_eq 'tok: glob not expanded, backslash' 'rm|-rf|$BUILD_DIR/*|~/x|*|' "$(cd "$T_PROJ" && toks 'rm -rf "$BUILD_DIR/"* \~/x *')"
assert_eq 'tok: redirect tokens' 'cat|<|.env|>|out|' "$(toks 'cat < .env > out')"
assert_eq 'tok: dq escapes' 'echo|a"b|$X|' "$(toks 'echo "a\"b" "\$X"')"

t_section "sp_git_subcmd / sp_head"
gitc() { sp_git_subcmd "$1" | sed $'s/\t/ <T> /g'; }
assert_eq 'git: -C and --no-pager' '/tmp/x <T> push <T> --force origin main' "$(gitc 'git -C /tmp/x --no-pager push --force origin main')"
assert_eq 'git: -c k=v skipped, rest raw' ' <T> commit <T> -nm "a b"' "$(gitc 'git -c core.hooksPath=/dev/null commit -nm "a b"')"
assert_eq 'git: --git-dir= and two -C' 'a/b <T> status <T> ' "$(gitc 'git --git-dir=/g/.git -C a -C b status')"
assert_eq 'git: plain push' ' <T> push <T> ' "$(gitc 'git push')"
sp_git_subcmd 'ls -la' >/dev/null; assert_eq 'git: non-git returns 1' 1 "$?"
assert_eq 'git: non-git prints nothing' '' "$(gitc 'ls -la')"
assert_eq 'head: first word' git "$(sp_head 'git commit -m "Q"')"
assert_eq 'head: glob not expanded' '*' "$(cd "$T_PROJ" && sp_head '* x')"
assert_eq 'head: blank' '' "$(sp_head '   ')"

t_section "benchmark (100 x sp_segments, 300-char command)"
cmd='cd "/Users/some one/project dir" && git status --porcelain && uv run --env-file .env python manage.py migrate --check && docker compose -f compose.yml exec -T db psql -U app -c "select count(*) from users where x=1" && npm run build -- --prod && echo done | tee -a build.log && ls -la /tmp'
now() { if command -v python3 >/dev/null 2>&1; then python3 -I -S -c 'import time; print(time.time())'; else date +%s; fi; }
s=$(now); i=0; while [ "$i" -lt 100 ]; do sp_segments "$cmd" >/dev/null; i=$((i + 1)); done; e=$(now)
el=$(printf '%s %s' "$e" "$s" | awk '{ printf "%.3f", $1 - $2 }')
ok=$(printf '%s' "$el" | awk '{ print ($1 < 3.0) ? "yes" : "no" }')   # R5: 1.5 → 3.0초(gawk 는 호출마다 시작이 느려 중앙값 1.1초 — 2.5배 여유)
assert_eq "perf: 100x sp_segments < 3.0s (took ${el}s, len ${#cmd})" yes "$ok"
t_report
