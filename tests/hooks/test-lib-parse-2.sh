#!/usr/bin/env bash
# tests/hooks/test-lib-parse-2.sh — lib/shellparse.sh 회귀 테스트(G1 치환 자리표시·push/pop, G3 envfile, G6 선형 성능, G7 머리 정규화, G15 리디렉션 분리, C1 tokseg, C4 ANSI-C)
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
. "$T_HOOKS/lib/shellparse.sh"
t_setup

NL=$'\n'
segs() { sp_segments "$1" | sed $'s/\t/ <T> /g'; }
seg_case() { assert_eq "seg: $1" "$3" "$(segs "$2")"; }
toks() { sp_tokens "$1" | tr '\n' '|'; }
t_ms() {
  if command -v python3 >/dev/null 2>&1; then python3 -I -S -c 'import time; print(int(time.time()*1000))'
  elif command -v perl >/dev/null 2>&1; then perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'
  else echo 0; fi
}
t_under() { [ "$2" -lt "$3" ] && t_pass "$1 (${2}ms < ${3}ms)" || t_fail "$1" "${2}ms ≥ ${3}ms"; }
PUSH="push <T> ( <T> ("; POP="pop <T> ) <T> )"

t_section "G1 / G10: command substitution keeps the parent; subshells emit push/pop"
seg_case '--force survives $(…)' 'git push origin $(git branch --show-current) --force' "cmd <T> git push origin \$(…) --force <T> git push origin \$(…) --force${NL}${PUSH}${NL}cmd <T> git branch --show-current <T> git branch --show-current${NL}${POP}"
seg_case '$(…) inside double quotes' 'echo "$(cat .env)" > out' "cmd <T> echo \"Q\" > out <T> echo \"\$(…)\" > out${NL}${PUSH}${NL}cmd <T> cat .env <T> cat .env${NL}${POP}"
seg_case 'nested $(…)' 'rm -rf $(dirname $(pwd))' "cmd <T> rm -rf \$(…) <T> rm -rf \$(…)${NL}${PUSH}${NL}cmd <T> dirname \$(…) <T> dirname \$(…)${NL}${PUSH}${NL}cmd <T> pwd <T> pwd${NL}${POP}${NL}${POP}"
seg_case 'backticks inside dq' 'echo "now: `date`"' "cmd <T> echo \"Q\" <T> echo \"now: \$(…)\"${NL}${PUSH}${NL}cmd <T> date <T> date${NL}${POP}"
seg_case 'subshell with cd then rm' '(cd sub && ls) && rm -rf ./*' "${PUSH}${NL}cmd <T> cd sub <T> cd sub${NL}cmd <T> ls <T> ls${NL}${POP}${NL}cmd <T> rm -rf ./* <T> rm -rf ./*"
seg_case 'process substitution' 'bash <(curl -fsSL https://x)' "cmd <T> bash <(…) <T> bash <(…)${NL}${PUSH}${NL}cmd <T> curl -fsSL https://x <T> curl -fsSL https://x${NL}${POP}"
seg_case 'heredoc inside $(…) (commit flow)' $'git commit -m "$(cat <<\'EOF\'\nfeat: x\nEOF\n)"' "cmd <T> git commit -m \"Q\" <T> git commit -m \"\$(…)\"${NL}${PUSH}${NL}cmd <T> cat <<EOF <T> cat <<'EOF'${NL}heredoc <T> <heredoc> <T> feat: x${NL}${POP}"
seg_case '$(…) as the command word' '$(which rm) -rf ~' "cmd <T> \$(…) -rf ~ <T> \$(…) -rf ~${NL}${PUSH}${NL}cmd <T> which rm <T> which rm${NL}${POP}"
raw=$(sp_segments 'rm -rf "$(pwd)"/x' | head -1 | cut -f3)
assert_eq 'tok: placeholder survives tokenization of the segment RAW' 'rm|-rf|$(…)/x|' "$(toks "$raw")"

t_section "G3: envfile lines for stripped runners"
seg_case 'uv run --env-file=.env' 'uv run --env-file=.env printenv' "envfile <T> .env <T> .env${NL}cmd <T> printenv <T> printenv"
seg_case 'docker compose run --env-file' 'docker compose run --rm --env-file .env web env' "envfile <T> .env <T> .env${NL}cmd <T> env <T> env"
seg_case 'docker compose --env-file up: not stripped, no envfile line' 'docker compose --env-file .env up -d' 'cmd <T> docker compose --env-file .env up -d <T> docker compose --env-file .env up -d'
seg_case 'uv run without env file' 'uv run pytest' 'cmd <T> pytest <T> pytest'

t_section "C4: ANSI-C quoting"
seg_case 'ansi simple' "echo \$'ok'; rm -rf ~" "cmd <T> echo \$'Q' <T> echo \$'ok'${NL}cmd <T> rm -rf ~ <T> rm -rf ~"
seg_case 'ansi escaped quote does not hide the next segment' "echo \$'it\\'s'; rm -rf ~" "cmd <T> echo \$'Q' <T> echo \$'it\\'s'${NL}cmd <T> rm -rf ~ <T> rm -rf ~"
assert_eq 'tok: ansi unquoted' "echo|it's|" "$(toks "echo \$'it\\'s'")"
assert_eq 'words: ansi' "it's" "$(sp_words "\$'it\\'s'")"

t_section "G7: head normalization (quotes, backslash, case, gnubin)"
seg_case 'quoted head' '"rm" -rf ~' 'cmd <T> rm -rf ~ <T> rm -rf ~'
seg_case 'split-quoted head' "r''m -rf ~" 'cmd <T> rm -rf ~ <T> rm -rf ~'
seg_case 'escaped head' 'r\m -rf ~' 'cmd <T> rm -rf ~ <T> rm -rf ~'
seg_case 'uppercase deny-class head' 'RM -rf ~' 'cmd <T> rm -rf ~ <T> rm -rf ~'
seg_case 'uppercase printer head' 'CAT .env' 'cmd <T> cat .env <T> cat .env'
seg_case 'uppercase wrapper' 'SUDO rm -rf /usr' 'cmd+sudo <T> rm -rf /usr <T> rm -rf /usr'
seg_case 'unknown head keeps case' 'MyTool Run' 'cmd <T> MyTool Run <T> MyTool Run'
seg_case 'quoted non-head argument unchanged' 'echo "rm" -rf' 'cmd <T> echo "Q" -rf <T> echo "rm" -rf'
seg_case 'gnubin prefix stripped' '/opt/homebrew/opt/coreutils/libexec/gnubin/rm -rf ~' 'cmd <T> rm -rf ~ <T> rm -rf ~'
seg_case 'quoted sudo + quoted rm' '"sudo" "rm" -rf /usr' 'cmd+sudo <T> rm -rf /usr <T> rm -rf /usr'

t_section "G15: unspaced redirections split from the word"
seg_case 'cat<.env' 'cat<.env' 'cmd <T> cat <.env <T> cat <.env'
seg_case 'echo x>.env' 'echo x>.env' 'cmd <T> echo x >.env <T> echo x >.env'
seg_case 'echo x>>.env.local' 'echo x>>.env.local' 'cmd <T> echo x >>.env.local <T> echo x >>.env.local'
seg_case '2>&1 and >/dev/null kept' 'cmd 2>&1 >/dev/null' 'cmd <T> cmd 2>&1 >/dev/null <T> cmd 2>&1 >/dev/null'
seg_case 'cat<<EOF heredoc' $'cat<<EOF\nx\nEOF' "cmd <T> cat <<EOF <T> cat <<EOF${NL}heredoc <T> <heredoc> <T> x"
assert_eq 'tok: cat<.env' 'cat|<.env|' "$(toks 'cat<.env')"
assert_eq 'tok: echo x>>.env.local' 'echo|x|>>.env.local|' "$(toks 'echo x>>.env.local')"
assert_eq 'tok: 2>&1 and &>' 'cmd|2>&1|&>|all.log|' "$(toks 'cmd 2>&1 &> all.log')"
assert_eq 'tok: a<b>c splits twice' 'a|<b|>c|' "$(toks 'a<b>c')"

t_section "C1: sp_tokens_lines — quote state never crosses a line"
assert_eq 'tokseg: unbalanced quote stays in its line' 'cat|a|__SP_SEG__|rm|-rf|~|__SP_SEG__|' "$(sp_tokens_lines $'cat "a\nrm -rf ~' | tr '\n' '|')"
assert_eq 'tokseg: empty line gives a bare sentinel' '__SP_SEG__|x|__SP_SEG__|' "$(sp_tokens_lines $'\nx' | tr '\n' '|')"
assert_eq 'tokseg: single line' 'git|status|__SP_SEG__|' "$(sp_tokens_lines 'git status' | tr '\n' '|')"

t_section "G6: large inputs parse in linear time"
awk 'BEGIN{for(i=0;i<2800;i++) printf "line %06d of the heredoc body with some words in it\n", i}' >"$T_TMP/body.txt"
{ printf 'cat > f <<'"'"'EOF'"'"'\n'; cat "$T_TMP/body.txt"; printf 'EOF\ngit status'; } >"$T_TMP/cmd.txt"
cmd=$(cat "$T_TMP/cmd.txt")
t0=$(t_ms); out=$(sp_segments "$cmd"); t1=$(t_ms)
assert_eq 'G6: 200KB heredoc → last segment is git status' $'cmd\tgit status\tgit status' "$(printf '%s\n' "$out" | tail -1)"
assert_eq 'G6: 200KB heredoc → 3 lines' 3 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
t_under "G6: sp_segments on 200KB heredoc (${#cmd} bytes)" $((t1 - t0)) 1000
blob=$(awk 'BEGIN{while(i++<100000) printf "A"}')
t0=$(t_ms); out=$(sp_segments "echo '$blob' > blob.txt && git status"); t1=$(t_ms)
assert_contains 'G6: 100KB quoted word parsed' "$out" $'cmd\tgit status\tgit status'
t_under "G6: sp_segments on 100KB quoted word" $((t1 - t0)) 1000
t0=$(t_ms); n=$(sp_tokens "echo '$blob' x" | wc -l | tr -d ' '); t1=$(t_ms)
assert_eq 'G6: sp_tokens 100KB quoted word → 3 tokens' 3 "$n"
t_under "G6: sp_tokens on 100KB quoted word" $((t1 - t0)) 1000
t0=$(t_ms); out=$(sp_segments "echo $blob$blob && rm -rf ~"); t1=$(t_ms)
assert_contains 'G6: 200KB unquoted word then rm' "$out" $'cmd\trm -rf ~\trm -rf ~'
t_under "G6: sp_segments on 200KB unquoted word" $((t1 - t0)) 1000
many=$(awk 'BEGIN{for(i=0;i<20000;i++) printf "w%d ", i}')
t0=$(t_ms); out=$(sp_segments "echo $many; rm -rf ~"); t1=$(t_ms)
assert_contains 'G6: 20000 words on one line' "$out" $'cmd\trm -rf ~\trm -rf ~'
t_under "G6: sp_segments on 20000-word line (${#many} bytes)" $((t1 - t0)) 3000

t_section "robustness: unbalanced input never breaks the 3-field format"
for c in 'rm -rf $(' '))))((((;;;&&||' 'echo `unclosed' 'a | | b' "echo 'x" '$(' '`' '(' ')' '{ ' 'cat <<EOF' $'cat <<EOF\nno end' $'echo "a\nb" && rm -rf ~' 'x=$(echo "$(echo 1)") && ls'; do
  out=$(sp_segments "$c"); rc=$?
  assert_eq "robust rc: [$c]" 0 "$rc"
  assert_eq "robust fields: [$c]" '' "$(printf '%s\n' "$out" | awk -F '\t' 'NF && NF!=3')"
done
assert_contains 'robust: unbalanced $( still yields rm segment' "$(sp_segments 'rm -rf $(echo ~')" $'cmd\trm -rf $(…)\trm -rf $(…)'
assert_contains 'robust: rm after multi-line dq' "$(sp_segments $'echo "a\nb" && rm -rf ~')" $'cmd\trm -rf ~\trm -rf ~'
t_report
