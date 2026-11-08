#!/usr/bin/env bash
# tests/hooks/test-guards-secrets-2.sh — guard-secrets.sh 회귀 테스트(검증 결과 G1·G3·G4·G7·G15·G18·G19, C3·C5·C8, D5)
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
t_setup
HOOK="$T_HOOKS/guard-secrets.sh"
run() {  # <json> [VAR=VAL ...]
  local in=$1; shift
  if [ $# -gt 0 ]; then
    T_OUT=$(printf '%s' "$in" | env "$@" "$BASH" "$HOOK" 2>"$T_TMP/stderr.txt"); T_RC=$?
    T_ERR=$(cat "$T_TMP/stderr.txt" 2>/dev/null)
  else t_run_hook "$HOOK" "$in"; fi
}
tb() { run "$(t_bash_json "$3" "${4:-}" "${5:-}")"; assert_decision "$1" "$2"; }     # <name> <expect> <cmd> [cwd] [mode]
tp() { run "$(t_path_json "$3" "$4")"; assert_decision "$1" "$2"; }                   # <name> <expect> <tool> <path>
trs() { assert_contains "$1" "$(t_reason "$T_OUT")" "$2"; }
t_ms() {
  if command -v python3 >/dev/null 2>&1; then python3 -I -S -c 'import time; print(int(time.time()*1000))'
  elif command -v perl >/dev/null 2>&1; then perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'
  else echo 0; fi
}
t_under() { [ "$2" -lt "$3" ] && t_pass "$1 (${2}ms < ${3}ms)" || t_fail "$1" "${2}ms ≥ ${3}ms"; }

t_section "G3: env-file loader + printer/dump → deny (§3.3 rule 1)"
tb 'uv run --env-file .env printenv' deny 'uv run --env-file .env printenv'
trs "G3 rule id" "[secrets:print]"
tb 'uv run --env-file .env printenv auto → deny' deny 'uv run --env-file .env printenv' "" auto
tb 'uv run --env-file .env env' deny 'uv run --env-file .env env'
tb 'uv run --env-file=.env printenv' deny 'uv run --env-file=.env printenv'
tb 'uv run --env-file .env python -c print(os.environ)' deny 'uv run --env-file .env python -c "import os; print(os.environ)"'
tb 'docker run --env-file .env alpine env' deny 'docker run --rm --env-file .env alpine env'
tb 'docker compose run --env-file .env web printenv' deny 'docker compose run --rm --env-file .env web printenv'
tb 'dotenv -e .env -- printenv' deny 'dotenv -e .env -- printenv'
tb 'uv run --env-file .env pytest → silent' none 'uv run --env-file .env pytest'
tb 'uv run --env-file .env manage.py migrate → silent' none 'uv run --env-file .env python manage.py migrate'
tb 'docker compose --env-file .env up → silent' none 'docker compose --env-file .env up -d'
tb 'dotenv -e .env -- python app.py → silent' none 'dotenv -e .env -- python app.py'
tb 'docker run --env-file .env img npm start → silent' none 'docker run --env-file .env img npm start'
tb 'env-cmd -f .env npm start → silent' none 'env-cmd -f .env npm start'

t_section "G4: glob arguments in Bash (and grep --include / rg -g)"
tb 'grep KEY .env*' deny 'grep KEY .env*'
tb 'grep --include=".env*"' deny 'grep -rn API_KEY --include=".env*" .'
tb 'grep --include ".env*"' deny 'grep -rn API_KEY --include ".env*" .'
tb "rg -g '.env*'" deny "rg KEY -g '.env*'"
tb "rg --glob='*.pem'" deny "rg -n BEGIN --glob='*.pem' ."
tb 'cat .env*' deny 'cat .env*'
tb 'head .env*' deny 'head .env*'
tb 'cat .e*' deny 'cat .e*'
tb 'cat .en?' deny 'cat .en?'
tb 'cat .[e]nv' deny 'cat .[e]nv'
tb 'cat id_*' deny 'cat id_*'
tb 'cat .env.{local,production}' deny 'cat .env.{local,production}'
tb 'cat "$(pwd)/.env"' deny 'cat "$(pwd)/.env"'
tb 'cat $(pwd)/config/.env.local' deny 'cat $(pwd)/config/.env.local'
tb 'grep --include="*.py" → silent' none 'grep -rn TODO --include="*.py" .'
tb "rg -g '!.env*' negation → silent" none "rg KEY -g '!.env*' src/"
tb 'cat *.md → silent' none 'cat *.md'
tb 'ls .env* → silent' none 'ls .env*'
tb 'rm -f *.pyc → silent' none 'rm -f *.pyc'

t_section "G15: unspaced redirections"
tb 'cat<.env' deny 'cat<.env'
tb 'python3<.env' deny 'python3<.env'
tb 'base64<.env' deny 'base64<.env'
tb 'echo x>.env' ask 'echo x>.env'
trs "G15 write rule id" "[secrets:write]"
tb 'echo x>>.env.local' ask 'echo x>>.env.local'
tb 'echo x>out.txt → silent' none 'echo KEY=1>out.txt'
tb 'ls 2>/dev/null → silent' none 'ls .env 2>/dev/null'
tb 'cat <<<"$X" → silent' none 'cat <<<"$X"'

t_section "G18: Grep brace globs"
tg() {  # <name> <expect> <glob> — bash 3.2 는 "$( … '…"…' )" 를 잘못 파싱하므로 JSON 을 변수로 먼저 만든다
  local j; j=$(t_pre_json Grep "{\"pattern\":\"KEY\",\"glob\":$(t_json_str "$3")}"); run "$j"; assert_decision "$1" "$2"
}
tg "grep glob *.{env,pem}" deny '*.{env,pem}'
tg "grep glob {.env,.env.local}" deny '{.env,.env.local}'
tg "grep glob .env.{local,prod}" deny '.env.{local,prod}'
tg "grep glob *.{py,ts} → none" none '*.{py,ts}'
tg "grep glob **/*.{json,secret} → soft ask" ask '**/*.{json,secret}'
tg "grep glob .[e]nv" deny '.[e]nv'

t_section "R7: {a,b} 대안은 명령마다 256개까지 분류(넘으면 더 펼치지 않고 too-complex 바닥) — {a,b} 16개(대안 6만 5천 개)에 25~30초였다"
B16=$(awk 'BEGIN{for(i=0;i<16;i++) printf "{a,b}"}')
t0=$(t_ms); tb "cat {a,b}×16x; cat .env → deny" deny "cat ${B16}x; cat .env"; t1=$(t_ms); trs "{a,b}×16 뒤 cat .env rule" "[secrets:print]"
t_under "cat {a,b}×16x; cat .env 시간" $((t1 - t0)) 3000
t0=$(t_ms); tb "cat {a,b}×16x → none(비밀 이름 없음)" none "cat ${B16}x"; t1=$(t_ms)
t_under "cat {a,b}×16x 시간" $((t1 - t0)) 3000
t0=$(t_ms); tb "echo token {a,b}×16x → ask(too-complex)" ask "echo token ${B16}x"; t1=$(t_ms); trs "{a,b}×16 too-complex" "[secrets:too-complex]"
t_under "echo token {a,b}×16x 시간" $((t1 - t0)) 3000
run "$(t_bash_json "echo token ${B16}x" '' '' '{"agent_id":"sub1","agent_type":"general-purpose"}')"; assert_decision "echo token {a,b}×16x (서브에이전트) → deny" deny
tb "cat {a,b}.txt → none" none 'cat {a,b}.txt'
tb "cat {a,.env} → deny" deny 'cat {a,.env}'
tb "cat {a,b}{c,d}{e,f}{g,h}{i,j}{k,l}.env → deny(첫 대안이 hard)" deny 'cat {a,b}{c,d}{e,f}{g,h}{i,j}{k,l}.env'
t0=$(t_ms); tg "grep glob {a,b}×16.env → deny" deny "${B16}.env"; t1=$(t_ms)
t_under "grep glob {a,b}×16.env 시간" $((t1 - t0)) 3000
t0=$(t_ms); tg "grep glob {a,b}×16.txt → ask(too-complex)" ask "${B16}.txt"; t1=$(t_ms); trs "grep glob {a,b}×16 too-complex" "[secrets:too-complex]"
t_under "grep glob {a,b}×16.txt 시간" $((t1 - t0)) 3000
tg "grep glob {src,lib}/*.{ts,tsx} → none" none '{src,lib}/*.{ts,tsx}'

t_section "G19: credential stores and .env variants"
for p in '~/.config/gh/hosts.yml' '~/.vault-token' '~/.cargo/credentials.toml' '~/.cargo/credentials' '~/.terraform.d/credentials.tfrc.json' '~/.huggingface/token' '~/.cache/huggingface/token' '~/.azure/accessTokens.json' '~/.azure/msal_token_cache.json' 'config/app.env' 'docker/prod.env' '.env~' '.env_prod' '.env_local'; do
  tp "G19 Read $p → deny" deny Read "$p"
done
for p in 'src/env.ts' '.env.example' 'prod.env.example' 'environment.yml' 'config/env.go' 'docs/env.md' 'app.envrc.sample' 'README.md'; do
  tp "G19 Read $p → none" none Read "$p"
done
tb 'cat ~/.vault-token' deny 'cat ~/.vault-token'
tb 'cat docker/prod.env' deny 'cat docker/prod.env'
tb 'cat .env_prod' deny 'cat .env_prod'

t_section "G7: quoted / uppercase printer heads"
tb '"cat" .env' deny '"cat" .env'
tb "c''at .env" deny "c''at .env"
tb 'CAT .env' deny 'CAT .env'
tb 'Grep KEY .env' deny 'Grep KEY .env'

t_section "C5: code heredocs — prefilter before word scan"
awk 'BEGIN{for(i=0;i<1500;i++){printf "def f_%d(x):\n    pass\n    return settings.get(\"k_%d\", x)\n", i, i}}' >"$T_TMP/body.py"
{ printf 'python3 - <<'"'"'PY'"'"'\n'; cat "$T_TMP/body.py"; printf 'PY'; } >"$T_TMP/cmd.txt"
t0=$(t_ms); run "$(t_bash_json_file "$T_TMP/cmd.txt")"; t1=$(t_ms)
assert_decision "100KB python heredoc without secrets → none" none
t_under "100KB python heredoc ($(wc -c <"$T_TMP/cmd.txt" | tr -d ' ') bytes)" $((t1 - t0)) 1500
{ printf 'python3 - <<'"'"'PY'"'"'\n'; cat "$T_TMP/body.py"; printf 'print(open(".env").read())\nPY'; } >"$T_TMP/cmd.txt"
t0=$(t_ms); run "$(t_bash_json_file "$T_TMP/cmd.txt")"; t1=$(t_ms)
assert_decision "100KB python heredoc reading .env → deny" deny
t_under "100KB python heredoc with .env" $((t1 - t0)) 3000
tb 'python heredoc os.environ.get → silent' none $'python3 - <<\'PY\'\nimport os\nprint(os.environ.get("HOME"))\nPY'
tb 'node heredoc readFileSync(.env) → deny' deny $'node - <<\'JS\'\nconst fs=require("fs"); console.log(fs.readFileSync(".env","utf8"))\nJS'
tb 'python heredoc ~/.kube/config → deny' deny $'python3 - <<\'PY\'\nprint(open(os.path.expanduser("~/.kube/config")).read())\nPY'

t_section "D5 Monitor / C3 parse failure / C8 locale"
run "$(t_pre_json Monitor '{"command":"cat .env"}')"; assert_decision "Monitor cat .env → deny" deny
run "$(t_pre_json Monitor '{"ws":"wss://example/stream"}')"; assert_decision "Monitor ws → none" none
J=$(t_bash_json 'cat .env PLACEHOLDER'); J=${J/PLACEHOLDER/\\ud800}
run "$J"; assert_decision "C3 surrogate: jq fails → python3 retry → deny" deny
run "$J" HOOK_FORCE_PARSER=jq; assert_decision "C3 surrogate, jq only → ask [hook:parse-error]" ask
trs "C3 parse-error rule id" "[hook:parse-error]"
run '{"tool_name":"Read","tool_input":{"file_path":"x"'; assert_decision "truncated JSON with tool_name → ask" ask
run "$(t_bash_json 'cat ./비밀폴더_가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가/.env')" LC_ALL=C LANG=C
assert_decision "C8 Korean path under C locale → deny" deny
printf '%s' "$T_OUT" | python3 -I -S -c 'import json,sys
r=json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"]
sys.exit(1 if ("�" in r or any(0xD800<=ord(c)<=0xDFFF for c in r)) else 0)'
assert_eq "C8 reason has no U+FFFD / surrogates" 0 "$?"
t_report
