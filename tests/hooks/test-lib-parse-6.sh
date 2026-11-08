#!/usr/bin/env bash
# tests/hooks/test-lib-parse-6.sh — lib/shellparse.sh 라운드 4:
#   task1 sub 레코드의 개행 인코딩(0x1E) — MASKED 는 공백 그대로, RAW 만 0x1E, 생개행 없음, 재파싱 때 heredoc·줄 잇기·주석이 top-level 과 같게.
#   task2 명령 치환 수에 선형(push/pop 이 매번 복사하지 않음) — 넉넉한 시간 상한(<3000 ms)으로 고정.
#   백스톱 overflow 레코드(작업 상한 초과)와 입력에 이미 든 0x1E(파서는 줄 구분으로 읽는다 — 가드는 그 전에 보통 글자 0x1D 로 바꾼다: test-guards-cross.sh).
#   R5 상한을 넘으면 읽은 부분을 마무리해 내고(상한 앞에서 만든 줄을 버리지 않음) overflow 는 맨 끝 한 줄. 상한은 push/pop·env -S 줄도 센다.
# 파서만 직접 부른다(가드 없음). 명령 문자열은 실행되지 않는다.
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
. "$T_HOOKS/lib/shellparse.sh"
t_setup

NL=$'\n'; RS=$'\036'; PH=$'$(\342\200\246)'
vis() { local s=$1; s=${s//$'\t'/<T>}; s=${s//$RS/<NL>}; printf '%s' "$s"; }   # 탭→<T>, 0x1E→<NL>
segs() { local o; o=$(sp_segments "$1"); vis "$o"; }
seg_case() { assert_eq "seg: $1" "$3" "$(segs "$2")"; }
t_ms() {
  if command -v python3 >/dev/null 2>&1; then python3 -I -S -c 'import time; print(int(time.time()*1000))'
  elif command -v perl >/dev/null 2>&1; then perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'
  else echo 0; fi
}
t_under() { [ "$2" -lt "$3" ] && t_pass "$1 (${2}ms < ${3}ms)" || t_fail "$1" "${2}ms ≥ ${3}ms"; }

t_section "task1: sub 레코드의 개행 — MASKED 는 공백, RAW 는 0x1E(생개행 없음)"
# sh -c 'echo start<NL>rm -rf ~' : cmd 줄(원문은 공백으로 평탄화) + sub 줄(RAW 에만 0x1E)
seg_case 'sh -c 두 줄 문자열' "sh -c 'echo start${NL}rm -rf ~'" \
"cmd<T>sh -c 'Q'<T>sh -c 'echo start rm -rf ~'
sub<T>echo start rm -rf ~<T>echo start<NL>rm -rf ~"
# bash -c 'cd x<NL>rm -rf ~'
seg_case 'bash -c 두 줄' "bash -c 'cd x${NL}rm -rf ~'" \
"cmd<T>bash -c 'Q'<T>bash -c 'cd x rm -rf ~'
sub<T>cd x rm -rf ~<T>cd x<NL>rm -rf ~"
# 컨테이너 busybox prefix 뒤 sh -c : 예전엔 생개행으로 레코드가 깨졌다 — 이제 sub 줄에 0x1E
seg_case 'docker busybox sh -c 두 줄' "docker run --rm img busybox sh -c 'echo a${NL}rm -rf ~'" \
"cmd<T>docker run --rm img busybox sh -c 'Q'<T>docker run --rm img busybox sh -c 'echo a rm -rf ~'
push<T>(<T>(
cmd<T>busybox sh -c 'Q'<T>busybox sh -c 'echo a rm -rf ~'
sub<T>echo a rm -rf ~<T>echo a<NL>rm -rf ~
pop<T>)<T>)
cmd<T>docker run --rm img busybox sh -c 'Q'<T>docker run --rm img busybox sh -c 'echo a rm -rf ~'"
# 큰따옴표 안의 개행은 한 단어 안에 남는다(sub RAW 에서 0x1E)
seg_case '따옴표 안 개행' "sh -c 'echo \"line1${NL}line2\"'" \
"cmd<T>sh -c 'Q'<T>sh -c 'echo \"line1 line2\"'
sub<T>echo \"Q\"<T>echo \"line1<NL>line2\""

t_section "task1: 모든 레코드는 알려진 kind + 정확히 탭 2개 + 생개행 없음"
check_records() {  # <name> <command> — sp_segments 출력의 각 줄을 검사
  local o line kind nt bad="" IFS=
  o=$(sp_segments "$2")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    nt=${line//[!$'\t']/}; nt=${#nt}
    kind=${line%%$'\t'*}
    case $kind in cmd|cmd+sudo|cmd+xargs|cmd+sudo+xargs|sub|heredoc|assign|envfile|push|pop|overflow) ;; *) bad="kind=$kind" ;; esac
    [ "$nt" -eq 2 ] || bad="tabs=$nt line=[$(vis "$line")]"
  done <<CR
$o
CR
  [ -z "$bad" ] && t_pass "records: $1" || t_fail "records: $1" "$bad"
}
check_records 'sh -c 개행'            "sh -c 'echo start${NL}rm -rf ~'"
check_records 'heredoc in string'     "sh -c 'cat <<EOF${NL}body${NL}EOF'"
check_records 'nested sh -c 개행'     "sh -c 'sh -c \"echo a${NL}rm -rf ~\"'"
check_records 'find -exec 개행'       "find . -maxdepth 0 -exec sh -c 'echo s${NL}rm -rf ~' ';'"
check_records 'eval 개행'             "eval \"echo a${NL}rm -rf ~\""
check_records 'CRLF'                  "sh -c 'echo a$'\r'${NL}rm -rf ~'"
check_records '백슬래시-개행 이음'    "sh -c 'echo a\\${NL}b'"

t_section "task1: sub RAW 재파싱이 top-level 과 같다(heredoc·주석·줄 잇기)"
# sub RAW 를 다시 sp_segments 에 넣으면 0x1E 가 줄로 되살아나 heredoc 본문이 생긴다(소비자 재파싱 경로)
reparse_sub() {  # <command> → 첫 sub 줄의 RAW 를 다시 파싱한 결과(vis)
  local o sr
  o=$(sp_segments "$1")
  sr=$(printf '%s\n' "$o" | awk -F'\t' '$1=="sub"{print $3; exit}')
  vis "$(sp_segments "$sr")"
}
assert_eq 'heredoc 재파싱' \
"cmd<T>cat <<EOF<T>cat <<EOF
heredoc<T><heredoc><T>secret body" \
"$(reparse_sub "sh -c 'cat <<EOF${NL}secret body${NL}EOF'")"
# 주석은 개행에서 끝난다: 재파싱하면 'echo a' 와 'rm -rf ~' 두 세그먼트(주석 줄은 사라진다)
assert_eq '주석 재파싱' \
"cmd<T>echo a<T>echo a
cmd<T>rm -rf ~<T>rm -rf ~" \
"$(reparse_sub "sh -c 'echo a${NL}# c${NL}rm -rf ~'")"
# 백슬래시-개행은 줄을 잇는다: 재파싱하면 한 단어 'ab'
assert_eq '줄 잇기 재파싱' \
"cmd<T>echo ab<T>echo ab" \
"$(reparse_sub "sh -c 'echo a\\${NL}b'")"

t_section "백스톱: 입력에 이미 든 0x1E 는 파서가 줄 구분으로 읽는다(가드는 명령의 0x1E 를 먼저 보통 글자 0x1D 로 바꾼다 — lib/common.sh)"
seg_case '입력의 0x1E' "rm${RS}-rf /" \
"cmd<T>rm<T>rm
cmd<T>-rf /<T>-rf /"
check_records '입력 0x1E 형식' "cat .e${RS}nv"

t_section "백스톱: overflow 레코드(작업 상한 초과)"
BIGSUB=$(awk 'BEGIN{s="echo"; for(i=0;i<40;i++) s=s " $(echo " i ")"; print s}')
# R5: 상한을 넘으면 입력을 더 읽지 않되, 읽은 부분(치환 3개와 막 연 4번째)은 입력이 거기서 끝난 것처럼 마무리하고 overflow 는 맨 끝 한 줄
assert_eq 'SP_WBMAX=10 이면 읽은 부분을 마무리하고 overflow 는 맨 끝 한 줄' \
"cmd<T>echo ${PH} ${PH} ${PH} ${PH}<T>echo ${PH} ${PH} ${PH} ${PH}
push<T>(<T>(
cmd<T>echo 0<T>echo 0
pop<T>)<T>)
push<T>(<T>(
cmd<T>echo 1<T>echo 1
pop<T>)<T>)
push<T>(<T>(
cmd<T>echo 2<T>echo 2
pop<T>)<T>)
push<T>(<T>(
pop<T>)<T>)
overflow<T><T>" \
"$(SP_WBMAX=10 segs "$BIGSUB")"
# 기본 상한(5000 레코드)에서는 40개 치환은 넘지 않는다
assert_eq '기본 상한에서는 overflow 없음' 0 \
"$(sp_segments "$BIGSUB" | grep -c '^overflow')"
# 200개 치환도 기본 상한 아래(코퍼스 최대 15 레코드)
assert_eq '200 치환도 overflow 없음' 0 \
"$(sp_segments "$(awk 'BEGIN{s="echo"; for(i=0;i<200;i++) s=s " $(echo " i ")"; print s}')" | grep -c '^overflow')"

t_section "task2: 명령 치환 수에 선형 — 넉넉한 시간 상한(<3000 ms). 상한을 넉넉히 올려 전부 파싱한다"
export SP_WBMAX=500000   # 선형성 측정을 위해 백스톱을 넉넉히 — 2000개 치환을 끝까지 파싱한다
mksub() { awk -v n="$1" -v k="$2" 'BEGIN{s="echo"; for(i=0;i<n;i++){ if(k=="bt") s=s " `echo " i "`"; else if(k=="q") s=s " \"$(echo " i ")\""; else s=s " $(echo " i ")" } print s}'; }
for k in dollar bt q; do
  S=$(mksub 2000 "$k")
  t0=$(t_ms); C=$(sp_segments "$S" | wc -l | tr -d ' '); t1=$(t_ms)
  t_under "task2 2000개 치환($k) 선형 시간" $((t1 - t0)) 3000
  assert_eq "task2 2000개 치환($k) 레코드 수" 6001 "$C"   # cmd + (push,cmd,pop)*2000
done
# 중첩·heredoc·그룹이 섞여도 2000 단위에서 넉넉히 통과
S=$(awk 'BEGIN{s="echo"; for(i=0;i<2000;i++) s=s " $(echo $(echo " i "))"; print s}')
t0=$(t_ms); sp_segments "$S" >/dev/null; t1=$(t_ms); t_under 'task2 2000개 중첩 치환 시간' $((t1 - t0)) 3000
unset SP_WBMAX

t_section "R5: 작업 상한을 넘어도 상한 앞에서 만든 줄은 버리지 않는다 — 열린 서브셸·치환 안의 줄, 그 바깥 세그먼트, env -S 묶음, B 묶음, 그 줄의 heredoc(r4 는 overflow 한 줄만 남거나 push 만 남았다)"
ov_case() {  # <name> <wbmax> <command> <expected(vis)>
  assert_eq "R5 overflow: $1" "$4" "$(SP_WBMAX=$2 segs "$3")"
}
ov_case '열린 서브셸 안의 줄' 3 '(git push --force origin main; a; b; c)' \
"push<T>(<T>(
cmd<T>git push --force origin main<T>git push --force origin main
cmd<T>a<T>a
pop<T>)<T>)
overflow<T><T>"
ov_case '열린 치환의 바깥 세그먼트' 2 'rm -rf / $(a; b; c)' \
"cmd<T>rm -rf / ${PH}<T>rm -rf / ${PH}
push<T>(<T>(
cmd<T>a<T>a
pop<T>)<T>)
overflow<T><T>"
ov_case '백틱 치환의 바깥 세그먼트' 2 'rm -rf / `a; b; c`' \
"cmd<T>rm -rf / ${PH}<T>rm -rf / ${PH}
push<T>(<T>(
cmd<T>a<T>a
pop<T>)<T>)
overflow<T><T>"
ov_case 'env -S 묶음(출력 맨 끝)' 4 "env -S 'rm -rf /' true; a; b; c" \
"cmd<T>true<T>true
cmd<T>a<T>a
push<T>(<T>(
sub<T>rm -rf / true<T>rm -rf / true
pop<T>)<T>)
overflow<T><T>"
ov_case 'B 묶음은 짝을 맞춰 끝까지' 2 'caffeinate -i rm -rf /; a; b' \
"cmd<T>caffeinate -i rm -rf /<T>caffeinate -i rm -rf /
push<T>(<T>(
cmd<T>rm -rf /<T>rm -rf /
pop<T>)<T>)
cmd<T>caffeinate -i rm -rf /<T>caffeinate -i rm -rf /
overflow<T><T>"
ov_case '그 줄의 heredoc 본문' 1 "cat <<EOF${NL}body${NL}EOF" \
"cmd<T>cat <<EOF<T>cat <<EOF
heredoc<T><heredoc><T>body
overflow<T><T>"
# END 마무리(닫히지 않은 따옴표)에서 상한을 넘어도 overflow 는 맨 끝(r4 는 env -S 묶음이 overflow 뒤에 나왔다)
ov_case 'END 마무리에서 넘어도 overflow 는 맨 끝' 4 "env -S 'x' y; echo 'unterminated" \
"cmd<T>y<T>y
cmd<T>echo 'Q<T>echo 'unterminated
push<T>(<T>(
sub<T>x y<T>x y
pop<T>)<T>)
overflow<T><T>"
# 마무리에서 새로 생기는 줄은 64줄까지 — 깊게 열린 치환마다 바깥 세그먼트가 있어도 유계, push/pop 짝은 맞는다
balance() {  # <command> [wbmax] → "<줄 수> <push-pop> <overflow 줄 수> <마지막 kind>"
  local o n p q v last
  if [ -n "${2:-}" ]; then o=$(SP_WBMAX=$2 sp_segments "$1"); else o=$(sp_segments "$1"); fi
  n=$(printf '%s\n' "$o" | wc -l | tr -d ' '); p=$(printf '%s\n' "$o" | grep -c '^push'); q=$(printf '%s\n' "$o" | grep -c '^pop')
  v=$(printf '%s\n' "$o" | grep -c '^overflow'); last=${o##*$'\n'}; printf '%s %s %s %s\n' "$n" $((p - q)) "$v" "${last%%$'\t'*}"
}
S=$(awk 'BEGIN{for(i=0;i<300;i++) printf "a $("; print "b"}')   # 닫히지 않은 치환 300겹, 겹마다 바깥 세그먼트(a $(…))
r=$(balance "$S" 100); n=${r%% *}
[ "$n" -le 230 ] && t_pass "R5 깊은 치환: 마무리 줄 유계 ($n ≤ 100+2×64+2)" || t_fail "R5 깊은 치환: 마무리 줄 유계" "$n"
assert_eq 'R5 깊은 치환: push/pop 짝·overflow 맨 끝 한 번' "0 1 overflow" "${r#* }"

t_section "R5: 상한은 push/pop·env -S 줄도 센다 — 빈 ()·\$()·env -S 만 많은 명령도 출력 줄 수·시간이 유계(r4 는 out() 만 상한을 봐 () 2만 개가 4만 줄, env -S 5000개가 2만 줄이었다)"
for k in paren dollar envs open; do
  case $k in
    paren)  S=$(awk 'BEGIN{for(i=0;i<20000;i++) printf "()"; print ""}') ;;
    dollar) S=$(awk 'BEGIN{printf "echo "; for(i=0;i<20000;i++) printf "$()"; print ""}') ;;
    envs)   S=$(awk 'BEGIN{for(i=0;i<5000;i++) printf "env -S %ctrue%c x;", 39, 39; print ""}') ;;
    open)   S=$(awk 'BEGIN{for(i=0;i<20000;i++) printf "("; print "echo x"}') ;;
  esac
  t0=$(t_ms); r=$(balance "$S"); t1=$(t_ms)
  n=${r%% *}
  [ "$n" -le 5200 ] && t_pass "R5 $k: 줄 수 유계 ($n ≤ 5200)" || t_fail "R5 $k: 줄 수 유계" "$n > 5200"
  assert_eq "R5 $k: push/pop 짝·overflow 맨 끝 한 번" "0 1 overflow" "${r#* }"
  t_under "R5 $k: 시간 유계" $((t1 - t0)) 3000
done
# 상한 아래는 그대로(통과): () 100개는 200줄·overflow 없음, env -S 10개는 40줄
assert_eq 'R5: 상한 아래 () 100개는 그대로' "200 0 0 pop" "$(balance "$(awk 'BEGIN{for(i=0;i<100;i++) printf "()"; print ""}')")"
assert_eq 'R5: 상한 아래 env -S 10개는 그대로' "40 0 0 pop" "$(balance "$(awk 'BEGIN{for(i=0;i<10;i++) printf "env -S %ctrue%c x;", 39, 39; print ""}')")"
t_section "라운드 5: 호출 하나의 단어 수 상한(24000) — 세그먼트 하나의 단어를 잇는 비용이 단어 수의 제곱(BWK awk 에서 10만 단어 200 KB 에 5.9초)이라 넘으면 overflow"
W25=$(awk 'BEGIN{for(i=0;i<25000;i++) printf " a"}'); W23=$(awk 'BEGIN{for(i=0;i<23000;i++) printf " a"}')
assert_eq 'R5: 단어 2만 5천 개 세그먼트 → 앞 세그먼트 뒤 overflow(그 세그먼트는 내지 않는다)' \
"cmd<T>cat .env<T>cat .env
overflow<T><T>" "$(segs "cat .env; echo$W25; rm -rf ~")"
assert_eq 'R5: 단어 2만 3천 개는 끝까지 나눈다' "cmd<T>rm -rf ~<T>rm -rf ~" "$(segs "echo$W23; rm -rf ~" | tail -n 1)"
assert_eq 'R5: 2만 3천 개에 overflow 없음' 0 "$(sp_segments "echo$W23; rm -rf ~" | grep -c '^overflow')"
W100=$(awk 'BEGIN{for(i=0;i<100000;i++) printf " a"}')
t0=$(t_ms); C=$(sp_segments "echo$W100; rm -rf ~" | tail -n 1); t1=$(t_ms)
assert_eq 'R5: 단어 10만 개 → overflow 로 끝난다' "overflow<T><T>" "$(vis "$C")"
t_under 'R5: 단어 10만 개(200 KB) 파싱 시간' $((t1 - t0)) 3000

t_section "라운드 5: 단어 하나의 조각(이스케이프·따옴표·\$ 마다 하나) 상한 8192 — BWK awk 는 조각마다 단어 전체를 복사해 \\\\ 10만 개(200 KB)에 파싱만 3초"
BS10=$(awk 'BEGIN{for(i=0;i<10000;i++) printf "\\\\"}'); BS8=$(awk 'BEGIN{for(i=0;i<8000;i++) printf "\\\\"}')
assert_eq 'R5: 조각 1만 개 단어 → 앞 세그먼트 뒤 overflow' "cmd<T>cat .env<T>cat .env
overflow<T><T>" "$(segs "cat .env; echo $BS10; rm -rf ~")"
assert_eq 'R5: 조각 8000개 단어는 끝까지 나눈다' "cmd<T>rm -rf ~<T>rm -rf ~" "$(segs "echo $BS8; rm -rf ~" | tail -n 1)"
Q10=$(awk 'BEGIN{for(i=0;i<10000;i++) printf "\047a\047"}')
assert_eq 'R5: 작은따옴표 조각 1만 개 → overflow' 1 "$(sp_segments "echo $Q10; rm -rf ~" | grep -c '^overflow')"
BS100=$(awk 'BEGIN{for(i=0;i<100000;i++) printf "\\\\"}')
t0=$(t_ms); sp_segments "cat .env; echo $BS100" >/dev/null; t1=$(t_ms)
t_under 'R5: \\\\ 10만 개(200 KB) 파싱 시간' $((t1 - t0)) 3000

t_section "R5 통합: 단어·조각 상한에 걸리면 읽다 만 그 세그먼트만 버린다(그 세그먼트를 잇는 비용 때문에 둔 상한) — 열린 서브셸·치환 안의 앞 줄, 그 세그먼트의 닫힌 치환 묶음, 열린 치환의 바깥 세그먼트, env -S 묶음, 앞 세그먼트의 heredoc 은 마무리해 내고 overflow 는 맨 끝 한 번"
assert_eq 'R5 통합: 단어 상한 — 열린 서브셸 안의 앞 줄' "push<T>(<T>(
cmd<T>cat .env<T>cat .env
pop<T>)<T>)
overflow<T><T>" "$(segs "(cat .env; echo$W25)")"
assert_eq 'R5 통합: 단어 상한 — 버린 세그먼트 안의 닫힌 치환 묶음' "push<T>(<T>(
cmd<T>cat .env<T>cat .env
pop<T>)<T>)
overflow<T><T>" "$(segs "echo \$(cat .env)$W25")"
assert_eq 'R5 통합: 단어 상한 — 열린 치환의 바깥 세그먼트' "cmd<T>git push --force origin main ${PH}<T>git push --force origin main ${PH}
push<T>(<T>(
pop<T>)<T>)
overflow<T><T>" "$(segs "git push --force origin main \$(echo$W25)")"
assert_eq 'R5 통합: 단어 상한 — env -S 묶음' "cmd<T>x<T>x
push<T>(<T>(
sub<T>cat .env x<T>cat .env x
pop<T>)<T>)
overflow<T><T>" "$(segs "env -S 'cat .env' x; echo$W25")"
assert_eq 'R5 통합: 단어 상한 — 앞 세그먼트의 heredoc 본문' "cmd<T>cat <<EOF<T>cat <<EOF
heredoc<T><heredoc><T>body
overflow<T><T>" "$(segs "cat <<EOF; echo$W25${NL}body${NL}EOF")"
assert_eq 'R5 통합: 조각 상한 — 열린 서브셸 안의 앞 줄' "push<T>(<T>(
cmd<T>cat .env<T>cat .env
pop<T>)<T>)
overflow<T><T>" "$(segs "(cat .env; echo $BS10)")"
# 통과: 상한 아래(단어 2만 3천 개)는 서브셸 안에서도 끝까지 낸다(overflow 없음)
assert_eq 'R5 통합: 상한 아래 서브셸은 그대로' "4 0 0 pop" "$(balance "(cat .env; echo$W23)")"

t_section "라운드 5: sp_tokens_lines 의 토큰 상한(3번째 인수) — 넘으면 상한에 닿은 줄까지만(__SP_SEG__ 도), 끝에 __SP_TRUNC__. 없으면 예전과 같다"
assert_eq 'R5: 토큰 상한 4 — 상한에 닿은 줄까지만' 'a|b|c|__SP_SEG__|d|__SP_SEG__|__SP_TRUNC__|' "$(sp_tokens_lines $'a b c\nd e\nf' '' 4 | tr '\n' '|')"
assert_eq 'R5: 토큰 상한 없음(예전과 같다)' 'a|b|c|__SP_SEG__|d|e|__SP_SEG__|f|__SP_SEG__|' "$(sp_tokens_lines $'a b c\nd e\nf' | tr '\n' '|')"
assert_eq 'R5: 상한에 딱 닿으면 잘림 표시 없음' 'a|b|__SP_SEG__|c|__SP_SEG__|' "$(sp_tokens_lines $'a b\nc' '' 3 | tr '\n' '|')"
assert_eq 'R5: keep-empty + 토큰 상한(줄 끝에서 닿으면 다음 줄부터 버린다)' 'a|__SP_EMPTY__|c|__SP_SEG__|__SP_TRUNC__|' "$(sp_tokens_lines $'a "" c\nd e' keep-empty 3 | tr '\n' '|')"
assert_eq 'R5: sp_tokens 는 상한 없음(예전과 같다)' 'x|a=|b|c|' "$(sp_tokens 'x a=b @c' | tr '\n' '|')"
T100=$(awk 'BEGIN{for(i=0;i<100000;i++) printf "a "}')
t0=$(t_ms); C=$(sp_tokens_lines "$T100" '' 3000 | wc -l | tr -d ' '); t1=$(t_ms)
assert_eq 'R5: 단어 10만 개 줄을 토큰 3000개에서 자른다(토큰 + __SP_SEG__ + __SP_TRUNC__)' 3002 "$C"

t_report
