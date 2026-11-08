#!/usr/bin/env bash
# tests/hooks/test-lib-parse-4.sh — lib/shellparse.sh 라운드 2: 리디렉션 연산자(>| · fd 번호 연산자)와 셸 문자열 실행기(sub 줄).
# 바뀌지 않아야 하는 형태(> >> 2> 2>&1 &> << <<< |& 1&>f 따옴표 안)도 함께 고정한다.
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
. "$T_HOOKS/lib/shellparse.sh"
t_setup

NL=$'\n'
segs() { sp_segments "$1" | sed $'s/\t/ <T> /g'; }
seg_case() { assert_eq "seg: $1" "$3" "$(segs "$2")"; }   # <name> <command> <expected lines, fields joined by " <T> ">
tok() { sp_tokens "$1" | tr '\n' '|'; }
wds() { sp_words "$1" | tr '\n' '|'; }
tl() { sp_tokens_lines "$1" | tr '\n' '|'; }
c1() { printf 'cmd <T> %s <T> %s' "$1" "${2:-$1}"; }                   # cmd 줄(masked, raw)
grp() { printf 'push <T> ( <T> (\nsub <T> %s <T> %s\npop <T> ) <T> )' "$1" "${2:-$1}"; }   # push/sub/pop 묶음

t_section "A: >| 는 파이프가 아니라 리디렉션 한 연산자"
seg_case '>| spaced' 'echo x >| .env' "$(c1 'echo x >| .env')"
seg_case '>| attached' 'echo x >|.env | wc -l' "$(c1 'echo x >|.env')${NL}$(c1 'wc -l')"
seg_case '1>| 2>|' 'echo x 1>| a 2>| b' "$(c1 'echo x 1>| a 2>| b')"
seg_case '>| after 2>&1' 'make 2>&1 >| build.log' "$(c1 'make 2>&1 >| build.log')"
seg_case '>| to a block device' 'cat image.iso >| /dev/disk2' "$(c1 'cat image.iso >| /dev/disk2')"
seg_case 'zsh >&| spaced' 'echo x >&| .env' "$(c1 'echo x >&| .env')"
seg_case 'zsh >&| attached then pipe' 'echo x >&|.env | wc -l' "$(c1 'echo x >&|.env')${NL}$(c1 'wc -l')"
seg_case '>&2 then pipe stays a pipe' 'a >&2|b' "$(c1 'a >&2')${NL}$(c1 'b')"
seg_case '|& stays a pipe' 'ls |& cat' "$(c1 'ls')${NL}$(c1 'cat')"
seg_case '>| inside $(…)' 'y=$(echo x >| f)' "assign <T> y=\$(…) <T> y=\$(…)${NL}push <T> ( <T> (${NL}$(c1 'echo x >| f')${NL}pop <T> ) <T> )"
seg_case '>| in quotes is text' "echo '>|' \">| b\"" "$(c1 "echo 'Q' \"Q\"" "echo '>|' \">| b\"")"
seg_case '|| and |& still split' 'false || make |& tee log' "$(c1 false)${NL}$(c1 make)${NL}$(c1 'tee log')"

t_section "A: fd 번호가 붙은 연산자는 한 단어"
seg_case '2>> spaced' 'echo x 2>> .env' "$(c1 'echo x 2>> .env')"
seg_case '2>> attached' 'echo x 2>>.env' "$(c1 'echo x 2>>.env')"
seg_case '10>>' 'echo x 10>> log' "$(c1 'echo x 10>> log')"
seg_case '3<>' 'exec 3<> rw.txt' "$(c1 '3<> rw.txt')"
assert_eq 'tokens: 2>> is one token' 'echo|x|2>>|.env|' "$(tok 'echo x 2>> .env')"
assert_eq 'tokens: 2>>file is one token' 'echo|x|2>>.env|' "$(tok 'echo x 2>>.env')"
assert_eq 'tokens: >| and 1>|' 'echo|>||a|1>||b|' "$(tok 'echo >| a 1>| b')"
assert_eq 'words: 2>> and 10>>' 'cmd|2>>|a|10>>|b|' "$(wds 'cmd 2>> a 10>> b')"
assert_eq 'tokens_lines: 2>> per line' 'a|2>>|f|__SP_SEG__|b|1>||g|__SP_SEG__|' "$(tl "a 2>> f${NL}b 1>| g")"

t_section "A: 바뀌지 않는 형태"
seg_case '> >> 2> &> unchanged' 'cmd > a >> b 2> c &> d' "$(c1 'cmd > a >> b 2> c &> d')"
seg_case '2>&1 and >&2 unchanged' 'cmd 2>&1 >&2 2>&-' "$(c1 'cmd 2>&1 >&2 2>&-')"
seg_case '&>> unchanged' 'cmd &>> all.log' "$(c1 'cmd &>> all.log')"
seg_case '1&>f: the 1 is an argument (unchanged)' 'echo x 1&>f' "$(c1 'echo x 1& >f')"
seg_case 'a1>b: word then redirect (unchanged)' 'echo a1>b' "$(c1 'echo a1 >b')"
assert_eq 'tokens: 2> file unchanged' 'cmd|2>|f|' "$(tok 'cmd 2> f')"
assert_eq 'tokens: <<< unchanged' 'cat|<<<|a b|' "$(tok 'cat <<< "a b"')"

t_section "B: 셸 문자열 실행기 — 원래 cmd 줄 + push/sub/pop + 같은 cmd 줄"
FX="find . -name x -exec sh -c 'Q' \\;"; FR="find . -name x -exec sh -c 'cat .env' \\;"
seg_case 'find -exec sh -c' "$FR" "$(c1 "$FX" "$FR")${NL}$(grp 'cat .env')${NL}$(c1 "$FX" "$FR")"
FX="find . -execdir /bin/bash -lc \"Q\" _ {} +"; FR="find . -execdir /bin/bash -lc \"rm -rf \\\"\$1\\\"\" _ {} +"
seg_case 'find -execdir /bin/bash -lc … {} +' "$FR" "$(c1 "$FX" "$FR")${NL}$(grp 'rm -rf "Q"' 'rm -rf "$1"')${NL}$(c1 "$FX" "$FR")"
FX="find . -ok sh -c 'Q' \\; -okdir zsh -c 'Q' \\;"; FR="find . -ok sh -c 'a' \\; -okdir zsh -c 'b' \\;"
seg_case 'find -ok and -okdir (two strings)' "$FR" "$(c1 "$FX" "$FR")${NL}$(grp a)${NL}$(grp b)${NL}$(c1 "$FX" "$FR")"
seg_case 'find -exec non-shell: unchanged' 'find . -exec cat {} \;' "$(c1 'find . -exec cat {} \;')"
seg_case 'find -exec sh without -c: unchanged' 'find . -exec sh x.sh {} \;' "$(c1 'find . -exec sh x.sh {} \;')"
seg_case "watch 'str'" "watch -n 1 'cat .env'" "$(c1 "watch -n 1 'Q'" "watch -n 1 'cat .env'")${NL}$(grp 'cat .env')${NL}$(c1 "watch -n 1 'Q'" "watch -n 1 'cat .env'")"
seg_case 'watch cmd args' 'watch -dn1 --interval 5 kubectl get pods' "$(c1 'watch -dn1 --interval 5 kubectl get pods')${NL}$(grp 'kubectl get pods')${NL}$(c1 'watch -dn1 --interval 5 kubectl get pods')"
seg_case 'watch -- cmd' 'watch -n1 -- ls -la' "$(c1 'watch -n1 -- ls -la')${NL}$(grp 'ls -la')${NL}$(c1 'watch -n1 -- ls -la')"
seg_case 'watch alone: unchanged' 'watch' "$(c1 watch)"
seg_case 'sudo watch keeps kind' "sudo watch 'ls'" "cmd+sudo <T> watch 'Q' <T> watch 'ls'${NL}$(grp ls)${NL}cmd+sudo <T> watch 'Q' <T> watch 'ls'"
# 라운드 3(항목 1): 옵션 인수 개수를 아는 podman exec|run 은 런타임 줄 + push/안쪽 명령 줄(+ sh -c 의 sub)/pop + 런타임 줄로 바뀌었다.
# 모르는 옵션이 있을 때의 라운드 2 모양(push/sub/pop 만)은 test-lib-parse-5.sh 가 고정한다.
FX="podman exec -it ctr sh -c 'Q'"; FR="podman exec -it ctr sh -c 'cat .env'"
seg_case 'podman exec … sh -c (라운드 3: 안쪽 명령 줄도)' "$FR" "$(c1 "$FX" "$FR")${NL}push <T> ( <T> (${NL}$(c1 "sh -c 'Q'" "sh -c 'cat .env'")${NL}sub <T> cat .env <T> cat .env${NL}pop <T> ) <T> )${NL}$(c1 "$FX" "$FR")"
FX="podman run --rm --network host img bash -c \"Q\""; FR="podman run --rm --network host img bash -c \"make test\""
seg_case 'podman run (라운드 3: --network 값을 알아 벗긴다)' "$FR" "$(c1 "$FX" "$FR")${NL}push <T> ( <T> (${NL}$(c1 'bash -c "Q"' 'bash -c "make test"')${NL}sub <T> make test <T> make test${NL}pop <T> ) <T> )${NL}$(c1 "$FX" "$FR")"
seg_case 'podman exec non-shell (라운드 3: 안쪽 명령을 묶음으로)' 'podman exec ctr cat .env' "$(c1 'podman exec ctr cat .env')${NL}push <T> ( <T> (${NL}$(c1 'cat .env')${NL}pop <T> ) <T> )${NL}$(c1 'podman exec ctr cat .env')"
FX="nsenter -t 1 -m -u sh -c 'Q'"; FR="nsenter -t 1 -m -u sh -c 'ls /'"
seg_case 'nsenter … sh -c' "$FR" "$(c1 "$FX" "$FR")${NL}$(grp 'ls /')${NL}$(c1 "$FX" "$FR")"
seg_case 'nsenter non-shell: unchanged' 'nsenter --target 1 --mount ls' "$(c1 'nsenter --target 1 --mount ls')"

t_section "B: env -S 묶음은 출력 맨 끝(env 를 벗긴 cmd 줄과 이웃은 그대로)"
seg_case "env -S 'str'" "env -S 'cat .env'" "$(c1 "env -S 'Q'" "env -S 'cat .env'")${NL}$(grp 'cat .env')"
seg_case 'env --split-string= + rest' "env --split-string='python3 -u' app.py" "$(c1 'app.py')${NL}$(grp 'python3 -u app.py')"
seg_case 'env -S + pipe: groups after every segment' "env -S 'x' echo / | xargs rm -rf" "$(c1 'echo /')${NL}cmd+xargs <T> rm -rf <T> rm -rf${NL}$(grp 'x echo /')"
seg_case 'env -iS attached' "env -iS'cat .env'" "$(c1 "env -iS'Q'" "env -iS'cat .env'")${NL}$(grp 'cat .env')"
seg_case 'env without -S: unchanged' 'env -i PATH=/usr/bin ls' "assign <T> PATH=/usr/bin <T> PATH=/usr/bin${NL}$(c1 'ls')"
seg_case 'docker exec unchanged' "docker exec ctr sh -c 'cat .env'" "$(c1 "sh -c 'Q'" "sh -c 'cat .env'")${NL}sub <T> cat .env <T> cat .env"
seg_case 'bash -c unchanged' "bash -c 'echo hi'" "$(c1 "bash -c 'Q'" "bash -c 'echo hi'")${NL}sub <T> echo hi <T> echo hi"
t_report
