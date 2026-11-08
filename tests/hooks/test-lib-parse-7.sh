#!/usr/bin/env bash
# tests/hooks/test-lib-parse-7.sh — lib/shellparse.sh 라운드 6:
#   P-A  sub RAW 의 탭 인코딩(0x1F) — 재파싱 때 탭으로 되살려 <<- 종료 토큰이 어긋나지 않는다. 레코드는 탭 정확히 2개, MASKED 에 0x1E/0x1F 없음.
#   P-B  따옴표 없는 heredoc 본문의 치환($(…)·`…`)을 heredoc 레코드 뒤에 push/sub/pop 그룹으로. 따옴표 구분자·이스케이프 \$(·\`·치환 없는 본문은 그룹 없음.
#   P-C  셸이 스크립트로 읽는 heredoc 본문(bash <<EOF · cat <<EOF | bash · docker exec -i sh <<EOF …)을 heredoc 레코드 뒤(그 heredoc 의 P-B 앞)에 push/sub/pop.
#        소유권은 heredoc 마다(마지막 세그먼트가 아니라 << 를 가진 세그먼트와 그 파이프라인). bash -c 'cat' <<EOF · bash ./s.sh <<EOF 는 아님.
#        P-C 묶음의 push 줄은 push<T><<<T><< 다(명령 치환 묶음 push<T>(<T>( 와 구분). 서브셸·치환·백틱 안의 heredoc 도 그 깊이에서 소유권을 본다.
#   P-D  SP_SUBFLAT=1 이면 sub RAW 가 R4 이전처럼 평탄(개행·탭·CR 모두 공백). 다른 값·미설정은 기존 인코딩.
#   예산: 새 그룹도 WBMAX 에 센다 · overflow 는 맨 끝 한 번 · push/pop 짝 맞춤.
# 파서만 직접 부른다(가드 없음). 명령 문자열은 실행되지 않는다.
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
. "$T_HOOKS/lib/shellparse.sh"
t_setup

NL=$'\n'; TAB=$'\t'; RS=$'\036'; US=$'\037'
vis() { local s=$1; s=${s//$'\t'/<T>}; s=${s//$RS/<NL>}; s=${s//$US/<TB>}; printf '%s' "$s"; }   # 탭→<T>, 0x1E→<NL>, 0x1F→<TB>
segs() { local o; o=$(sp_segments "$1"); vis "$o"; }
seg_case() { assert_eq "seg: $1" "$3" "$(segs "$2")"; }
reparse_sub() {  # <command> → 첫 sub 줄의 RAW 를 다시 파싱한 결과(vis) — 소비자(가드)의 재파싱 경로
  local o sr; o=$(sp_segments "$1"); sr=$(printf '%s\n' "$o" | awk -F'\t' '$1=="sub"{print $3; exit}'); vis "$(sp_segments "$sr")"
}
balance() {  # <command> [wbmax] → "<줄 수> <push-pop> <overflow 줄 수> <마지막 kind>"
  local o n p q v last
  if [ -n "${2:-}" ]; then o=$(SP_WBMAX=$2 sp_segments "$1"); else o=$(sp_segments "$1"); fi
  n=$(printf '%s\n' "$o" | wc -l | tr -d ' '); p=$(printf '%s\n' "$o" | grep -c '^push'); q=$(printf '%s\n' "$o" | grep -c '^pop')
  v=$(printf '%s\n' "$o" | grep -c '^overflow'); last=${o##*$'\n'}; printf '%s %s %s %s\n' "$n" $((p - q)) "$v" "${last%%$'\t'*}"
}
check_records() {  # <name> <command> — 각 레코드가 알려진 kind + 탭 정확히 2개 + MASKED(필드 2)에 0x1E/0x1F 없음 + 생개행 없음
  local o line kind nt bad="" f1 f2 IFS=
  o=$(sp_segments "$2")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    nt=${line//[!$'\t']/}; nt=${#nt}
    kind=${line%%$'\t'*}
    case $kind in cmd|cmd+sudo|cmd+xargs|cmd+sudo+xargs|sub|heredoc|assign|envfile|push|pop|overflow) ;; *) bad="kind=$kind" ;; esac
    [ "$nt" -eq 2 ] || bad="tabs=$nt line=[$(vis "$line")]"
    f1=${line#*$'\t'}; f2=${f1%%$'\t'*}   # MASKED 필드
    case $kind$'\t'$f2 in *$RS*|*$US*) bad="masked has 0x1E/0x1F: [$(vis "$line")]" ;; esac
  done <<CR
$o
CR
  [ -z "$bad" ] && t_pass "records: $1" || t_fail "records: $1" "$bad"
}

t_section "P-A: sub RAW 는 탭을 0x1F 로 보존(MASKED 는 공백) — 재파싱 때 탭·<<- 종료 토큰 복원"
# sh -c 'cat <<-EOF\n\tdata\n\tEOF\nrm -rf /' : sub RAW 는 개행 0x1E·탭 0x1F
seg_case 'sh -c <<- 탭 종료 토큰' "sh -c 'cat <<-EOF${NL}${TAB}data${NL}${TAB}EOF${NL}rm -rf /'" \
"cmd<T>sh -c 'Q'<T>sh -c 'cat <<-EOF  data  EOF rm -rf /'
sub<T>cat <<-EOF  data  EOF rm -rf /<T>cat <<-EOF<NL><TB>data<NL><TB>EOF<NL>rm -rf /"
# 재파싱하면 0x1F 가 탭으로 되살아나 <<-EOF 종료 토큰이 맞고, 본문 뒤의 rm -rf / 가 별도 명령으로 드러난다
assert_eq 'P-A 재파싱: 탭 종료 토큰 복원 + 뒤 명령' \
"cmd<T>psql <<-EOF<T>psql <<-EOF
heredoc<T><heredoc><T>SELECT 1;
cmd<T>rm -rf /<T>rm -rf /" \
"$(reparse_sub "sh -c 'psql <<-EOF${NL}${TAB}SELECT 1;${NL}${TAB}EOF${NL}rm -rf /'")"
check_records 'P-A 레코드 형식' "sh -c 'cat <<-EOF${NL}${TAB}data${NL}${TAB}EOF${NL}rm -rf /'"
# 큰따옴표 안의 탭도 sub RAW 에서 0x1F
seg_case 'P-A 따옴표 안 탭' "sh -c 'echo \"a${TAB}b\"'" \
"cmd<T>sh -c 'Q'<T>sh -c 'echo \"a b\"'
sub<T>echo \"Q\"<T>echo \"a<TB>b\""
# 백스톱: 입력에 이미 든 0x1F 는 파서가 탭으로 되살려 읽는다(가드는 넘기기 전 보통 글자 0x1D 로 — lib/common.sh)
seg_case '입력의 0x1F 는 탭' "echo${US}a" "cmd<T>echo a<T>echo a"
check_records '입력 0x1F 형식' "cat${US}.env"

t_section "P-C: 셸이 스크립트로 읽는 heredoc 본문 → push/sub/pop(줄 유지)"
seg_case 'bash <<'"'"'EOF'"'"' rm -rf ~' "bash <<'EOF'${NL}rm -rf ~${NL}EOF" \
"cmd<T>bash <<EOF<T>bash <<'EOF'
heredoc<T><heredoc><T>rm -rf ~
push<T><<<T><<
sub<T>rm -rf ~<T>rm -rf ~
pop<T>)<T>)"
# 여러 줄 본문은 sub RAW 에서 줄이 0x1E 로 유지된다(flatten 되어 한 echo 가 되지 않는다)
seg_case 'bash <<EOF 여러 줄 본문' "bash <<EOF${NL}echo a${NL}cat .env${NL}EOF" \
"cmd<T>bash <<EOF<T>bash <<EOF
heredoc<T><heredoc><T>echo a cat .env
push<T><<<T><<
sub<T>echo a cat .env<T>echo a<NL>cat .env
pop<T>)<T>)"
# 파이프라인 소유권: cat <<EOF | bash → bash 가 본문을 읽는다
seg_case 'cat <<EOF | bash' "cat <<EOF | bash${NL}echo a${NL}rm -rf /${NL}EOF" \
"cmd<T>cat <<EOF<T>cat <<EOF
cmd<T>bash<T>bash
heredoc<T><heredoc><T>echo a rm -rf /
push<T><<<T><<
sub<T>echo a rm -rf /<T>echo a<NL>rm -rf /
pop<T>)<T>)"
# <<- 셸 본문: 줄마다 선두 탭 제거
seg_case 'bash <<- 셸 본문 탭 제거' "bash <<-'EOF'${NL}${TAB}echo a${NL}${TAB}rm -rf /${NL}${TAB}EOF" \
"cmd<T>bash <<-EOF<T>bash <<-'EOF'
heredoc<T><heredoc><T>echo a rm -rf /
push<T><<<T><<
sub<T>echo a rm -rf /<T>echo a<NL>rm -rf /
pop<T>)<T>)"
# 출력 리디렉션이 있어도 표준 입력(heredoc)은 셸이 읽는다
seg_case 'bash <<EOF > out.log' "bash <<EOF > out.log${NL}rm -rf /${NL}EOF" \
"cmd<T>bash <<EOF > out.log<T>bash <<EOF > out.log
heredoc<T><heredoc><T>rm -rf /
push<T><<<T><<
sub<T>rm -rf /<T>rm -rf /
pop<T>)<T>)"
# bash -s 도 표준 입력을 스크립트로 읽는다
seg_case 'bash -s <<EOF' "bash -s <<'EOF'${NL}rm -rf /${NL}EOF" \
"cmd<T>bash -s <<EOF<T>bash -s <<'EOF'
heredoc<T><heredoc><T>rm -rf /
push<T><<<T><<
sub<T>rm -rf /<T>rm -rf /
pop<T>)<T>)"

t_section "P-C 소유권(pass): 본문을 셸이 읽지 않으면 그룹 없음"
# bash -c '문자열' 은 heredoc 을 그 문자열의 표준 입력으로 받는다 — 스크립트가 아니다
seg_case 'bash -c 문자열 + heredoc (그룹 없음)' "bash -c 'cat' <<EOF${NL}rm -rf /${NL}EOF" \
"cmd<T>bash -c 'Q' <<EOF<T>bash -c 'cat' <<EOF
sub<T>cat<T>cat
heredoc<T><heredoc><T>rm -rf /"
# bash 스크립트파일 — heredoc 은 데이터
seg_case 'bash 스크립트파일 + heredoc (그룹 없음)' "bash ./s.sh <<'EOF'${NL}rm -rf /${NL}EOF" \
"cmd<T>bash ./s.sh <<EOF<T>bash ./s.sh <<'EOF'
heredoc<T><heredoc><T>rm -rf /"
# cat 은 셸이 아니다 — 파일로 쓰는 heredoc 은 그룹 없음
seg_case 'cat > 파일 heredoc (그룹 없음)' "cat > /tmp/s.sh <<'EOF'${NL}rm -rf /${NL}EOF" \
"cmd<T>cat > /tmp/s.sh <<EOF<T>cat > /tmp/s.sh <<'EOF'
heredoc<T><heredoc><T>rm -rf /"
# heredoc 2개: << 를 가진 세그먼트별 소유 — 첫째(cat)는 그룹 없음, 둘째(bash)만 그룹
seg_case 'heredoc 2개: 소유권은 heredoc 마다' "cat <<'A' > /tmp/f; bash <<'B'${NL}rm -rf /${NL}A${NL}echo ok${NL}B" \
"cmd<T>cat <<A > /tmp/f<T>cat <<'A' > /tmp/f
cmd<T>bash <<B<T>bash <<'B'
heredoc<T><heredoc><T>rm -rf /
heredoc<T><heredoc><T>echo ok
push<T><<<T><<
sub<T>echo ok<T>echo ok
pop<T>)<T>)"

t_section "P-C 래퍼: docker exec -i / sudo bash / 벗기는 래퍼 뒤 셸도 본문을 읽는다"
# 파서가 sudo 를 벗겨 cmd+sudo 로(머리는 bash) — heredoc 소유자는 벗긴 bash
seg_case 'sudo bash <<EOF' "sudo bash <<'EOF'${NL}rm -rf /${NL}EOF" \
"cmd+sudo<T>bash <<EOF<T>bash <<'EOF'
heredoc<T><heredoc><T>rm -rf /
push<T><<<T><<
sub<T>rm -rf /<T>rm -rf /
pop<T>)<T>)"
# docker exec -i ctr sh <<EOF : 파서가 sh 까지 벗긴다 → 머리는 sh
seg_case 'docker exec -i sh <<EOF' "docker exec -i ctr sh <<'EOF'${NL}rm -rf /${NL}EOF" \
"cmd<T>sh <<EOF<T>sh <<'EOF'
heredoc<T><heredoc><T>rm -rf /
push<T><<<T><<
sub<T>rm -rf /<T>rm -rf /
pop<T>)<T>)"

t_section "P-B: 따옴표 없는 heredoc 본문의 치환 → push/sub/pop(최상위 \$() 처럼 재파싱)"
seg_case 'cat <<EOF $(…) 본문' "cat <<EOF${NL}\$(cat .env)${NL}EOF" \
"cmd<T>cat <<EOF<T>cat <<EOF
heredoc<T><heredoc><T>\$(cat .env)
push<T>(<T>(
sub<T>cat .env<T>cat .env
pop<T>)<T>)"
seg_case 'cat <<EOF 백틱 본문' "cat <<EOF${NL}\`cat .env\`${NL}EOF" \
"cmd<T>cat <<EOF<T>cat <<EOF
heredoc<T><heredoc><T>\`cat .env\`
push<T>(<T>(
sub<T>cat .env<T>cat .env
pop<T>)<T>)"
# 치환이 본문 줄을 넘으면 sub RAW 에서 개행 0x1E 로 유지(R10)
seg_case 'P-B 여러 줄 치환' "cat > /tmp/o <<EOF${NL}x=\$(echo a;${NL}rm -rf /)${NL}EOF" \
"cmd<T>cat > /tmp/o <<EOF<T>cat > /tmp/o <<EOF
heredoc<T><heredoc><T>x=\$(echo a; rm -rf /)
push<T>(<T>(
sub<T>echo a; rm -rf /<T>echo a;<NL>rm -rf /
pop<T>)<T>)"
# 중첩 괄호·중첩 $() 는 최상위 $() 와 같게 바깥 ) 로 끝난다
seg_case 'P-B 중첩 괄호' "cat <<EOF${NL}\$(echo \$(date) && (cd /tmp))${NL}EOF" \
"cmd<T>cat <<EOF<T>cat <<EOF
heredoc<T><heredoc><T>\$(echo \$(date) && (cd /tmp))
push<T>(<T>(
sub<T>echo \$(date) && (cd /tmp)<T>echo \$(date) && (cd /tmp)
pop<T>)<T>)"

t_section "P-B(pass): 이스케이프·따옴표 구분자·치환 없는 본문은 그룹 없음"
# \$( 는 리터럴 — 그룹 없음
seg_case 'P-B 이스케이프 \$( (그룹 없음)' "cat <<EOF${NL}\\\$(cat .env)${NL}EOF" \
"cmd<T>cat <<EOF<T>cat <<EOF
heredoc<T><heredoc><T>\\\$(cat .env)"
# 따옴표 구분자 'EOF' — 치환 펼치지 않음
seg_case 'P-B 따옴표 구분자 (그룹 없음)' "cat <<'EOF'${NL}\$(cat .env)${NL}EOF" \
"cmd<T>cat <<EOF<T>cat <<'EOF'
heredoc<T><heredoc><T>\$(cat .env)"
# 치환 없는 본문 — 그룹 없음
seg_case 'P-B 치환 없는 본문 (그룹 없음)' "cat <<EOF${NL}just text here${NL}EOF" \
"cmd<T>cat <<EOF<T>cat <<EOF
heredoc<T><heredoc><T>just text here"

t_section "P-C + P-B 동시: 셸이 읽고 따옴표 없는 본문 → P-C 그룹이 먼저, 그 다음 P-B"
# bash <<EOF 본문에 치환: P-C(본문 스크립트) 다음 P-B($() 전개)
seg_case 'P-C 다음 P-B 순서' "bash <<EOF${NL}\$(id)${NL}EOF" \
"cmd<T>bash <<EOF<T>bash <<EOF
heredoc<T><heredoc><T>\$(id)
push<T><<<T><<
sub<T>\$(id)<T>\$(id)
pop<T>)<T>)
push<T>(<T>(
sub<T>id<T>id
pop<T>)<T>)"
# 따옴표 없는 본문의 이스케이프 \$( 는 P-B 그룹이 없지만, P-C 의 따옴표 제거(\$→$)로 inner 셸이 실행한다(R24).
# MASKED 는 평탄 본문(따옴표 제거 전 \$ 유지), RAW 는 따옴표 제거 후 $
seg_case 'P-C 따옴표 제거 \$( (P-B 없음, P-C 에서 실행)' "bash <<EOF${NL}echo \\\$(rm -rf ~)${NL}EOF" \
"cmd<T>bash <<EOF<T>bash <<EOF
heredoc<T><heredoc><T>echo \\\$(rm -rf ~)
push<T><<<T><<
sub<T>echo \\\$(rm -rf ~)<T>echo \$(rm -rf ~)
pop<T>)<T>)"

t_section "P-D: SP_SUBFLAT=1 이면 sub RAW 평탄(공백); 미설정·다른 값은 기존 인코딩"
assert_eq 'P-D 미설정: 개행 0x1E' \
"cmd<T>sh -c 'Q'<T>sh -c 'a b'
sub<T>a b<T>a<NL>b" "$(segs "sh -c 'a${NL}b'")"
assert_eq 'P-D SP_SUBFLAT=1: 개행 공백' \
"cmd<T>sh -c 'Q'<T>sh -c 'a b'
sub<T>a b<T>a b" "$(SP_SUBFLAT=1 segs "sh -c 'a${NL}b'")"
assert_eq 'P-D SP_SUBFLAT=1: 탭 공백' \
"cmd<T>sh -c 'Q'<T>sh -c 'a b'
sub<T>a b<T>a b" "$(SP_SUBFLAT=1 segs "sh -c 'a${TAB}b'")"
assert_eq 'P-D 다른 값(2)은 기존 인코딩' \
"cmd<T>sh -c 'Q'<T>sh -c 'a b'
sub<T>a b<T>a<NL>b" "$(SP_SUBFLAT=2 segs "sh -c 'a${NL}b'")"

t_section "예산: 새 그룹도 WBMAX 에 센다 · overflow 는 맨 끝 한 번 · push/pop 짝 맞춤"
# 낮은 상한: cmd·heredoc 뒤 P-C 그룹은 마무리(WBXMAX 안)로 내고 overflow 는 맨 끝
assert_eq '예산: P-C 그룹 낮은 상한' \
"cmd<T>bash <<EOF<T>bash <<EOF
heredoc<T><heredoc><T>a b c
push<T><<<T><<
sub<T>a b c<T>a<NL>b<NL>c
pop<T>)<T>)
overflow<T><T>" "$(SP_WBMAX=2 segs "bash <<EOF${NL}a${NL}b${NL}c${NL}EOF")"
# 많은 P-B 그룹: push==pop, overflow 는 상한 넘을 때 맨 끝 한 번
assert_eq '예산: 많은 P-B 그룹 상한 아래 push==pop, overflow 없음' "0 0" \
"$(balance "cat <<EOF${NL}\$(a) \$(b) \$(c)${NL}EOF" | awk '{print $2, $3}')"
assert_eq '예산: P-B 그룹 상한 넘으면 overflow 1·push==pop' "0 1 overflow" \
"$(balance "cat <<EOF${NL}\$(a) \$(b) \$(c) \$(d)${NL}EOF" 5 | awk '{print $2, $3, $4}')"

t_section "통합: P-C 묶음 표시 · 서브셸/치환 안 소유권 · 줄을 넘는 순번 · 셸 옵션"
# P-C 묶음의 push 줄은 MASKED·RAW 가 << 다(위 기대값들) — 명령 치환 묶음(push ( )과 구분해 guard-destructive 가 본문 명령의 출력을 실행으로 보지 않는다
grp() {  # <name> <cmd> <1|0> — P-C 묶음(push <<) 이 있는가
  local o got=0; o=$(sp_segments "$2"); case $o in *$'push\t<<\t<<'*) got=1 ;; esac; assert_eq "P-C 묶음 유무: $1" "$3" "$got"; }
# 서브셸 ( … )·$( … )·백틱 안의 heredoc 도 그 깊이의 세그먼트·파이프로 소유권을 정한다(예전엔 깊이 0 만 — 치환 안 bash <<EOF 본문을 보지 않았다)
seg_case '( bash <<EOF ) 서브셸 안' "( cd /tmp && sudo bash <<'EOF'${NL}rm -rf /${NL}EOF${NL})" \
"push<T>(<T>(
cmd<T>cd /tmp<T>cd /tmp
cmd+sudo<T>bash <<EOF<T>bash <<'EOF'
heredoc<T><heredoc><T>rm -rf /
push<T><<<T><<
sub<T>rm -rf /<T>rm -rf /
pop<T>)<T>)
pop<T>)<T>)"
seg_case '백틱 안 cat <<EOF | bash' "echo \`cat <<EOF | bash${NL}cat .env${NL}EOF${NL}\`" \
"cmd<T>echo \$(…)<T>echo \$(…)
push<T>(<T>(
cmd<T>cat <<EOF<T>cat <<EOF
cmd<T>bash<T>bash
heredoc<T><heredoc><T>cat .env
push<T><<<T><<
sub<T>cat .env<T>cat .env
pop<T>)<T>)
pop<T>)<T>)"
# P-B 도 치환 안에서: x=$(cat <<EOF … $(rm -rf /) …) 의 본문 치환은 바깥 셸이 실행한다
seg_case 'P-B 치환 안 heredoc 본문 치환' "x=\$(cat <<EOF${NL}\$(rm -rf /)${NL}EOF${NL})" \
"assign<T>x=\$(…)<T>x=\$(…)
push<T>(<T>(
cmd<T>cat <<EOF<T>cat <<EOF
heredoc<T><heredoc><T>\$(rm -rf /)
push<T>(<T>(
sub<T>rm -rf /<T>rm -rf /
pop<T>)<T>)
pop<T>)<T>)"
# pass: 치환 안의 따옴표 구분자 heredoc(git commit -m "$(cat <<'EOF' …)" 꼴)은 묶음 없음
seg_case '치환 안 따옴표 구분자 cat (묶음 없음)' "x=\$(cat <<'EOF'${NL}\$(rm -rf /)${NL}EOF${NL})" \
"assign<T>x=\$(…)<T>x=\$(…)
push<T>(<T>(
cmd<T>cat <<EOF<T>cat <<'EOF'
heredoc<T><heredoc><T>\$(rm -rf /)
pop<T>)<T>)"
grp 'git commit -m "$(cat <<'"'"'EOF'"'"' …)" (묶음 없음)' "git commit -m \"\$(cat <<'EOF'${NL}fix: rm -rf handling${NL}EOF${NL})\"" 0
check_records '치환 안 P-C 형식' "x=\$(bash <<'EOF'${NL}a${TAB}b${NL}cat .env${NL}EOF${NL})"
assert_eq '예산: 치환 안 P-C 낮은 상한(push==pop, overflow 맨 끝)' "0 1 overflow" \
"$(balance "x=\$(bash <<EOF${NL}a${NL}b${NL}EOF${NL})" 3 | awk '{print $2, $3, $4}')"
# 세그먼트 순번은 줄마다 되돌리지 않는다: 줄 잇기(\) 뒤에 끝나는 cat > 파일 세그먼트가 앞 줄 bash 의 셸-읽기 값을 읽지 않는다(예전: 본문을 셸 스크립트로 봤다)
seg_case '줄 잇기 뒤 cat > 파일 (묶음 없음)' "true; bash${NL}echo hi; cat <<EOF \\${NL} > /tmp/x${NL}rm -rf /${NL}EOF" \
"cmd<T>true<T>true
cmd<T>bash<T>bash
cmd<T>echo hi<T>echo hi
cmd<T>cat <<EOF > /tmp/x<T>cat <<EOF > /tmp/x
heredoc<T><heredoc><T>rm -rf /"
grp 'cat <<EOF | 줄 잇기 bash' "cat <<EOF | \\${NL}bash${NL}rm -rf /${NL}EOF" 1
# 셸 옵션: -- · - 뒤 첫 인수는 스크립트 파일, 긴 옵션(--norc …)은 다음 단어를 먹지 않는다(--rcfile·--init-file 만), +x·+o 이름, -n·-o noexec 는 실행 안 함
grp 'bash -- <<EOF' "bash -- <<EOF${NL}rm -rf /${NL}EOF" 1
grp 'bash - <<EOF' "bash - <<EOF${NL}rm -rf /${NL}EOF" 1
grp 'bash -- s.sh <<EOF (스크립트 파일)' "bash -- s.sh <<EOF${NL}rm -rf /${NL}EOF" 0
grp 'bash --norc <<EOF' "bash --norc <<EOF${NL}rm -rf /${NL}EOF" 1
grp 'bash --norc s.sh <<EOF (스크립트 파일)' "bash --norc s.sh <<EOF${NL}rm -rf /${NL}EOF" 0
grp 'bash --posix s.sh <<EOF (스크립트 파일)' "bash --posix s.sh <<EOF${NL}rm -rf /${NL}EOF" 0
grp 'bash --rcfile rc <<EOF' "bash --rcfile rc <<EOF${NL}rm -rf /${NL}EOF" 1
grp 'bash --rcfile rc s.sh <<EOF (스크립트 파일)' "bash --rcfile rc s.sh <<EOF${NL}rm -rf /${NL}EOF" 0
grp 'bash +x <<EOF' "bash +x <<EOF${NL}rm -rf /${NL}EOF" 1
grp 'bash -euo pipefail <<EOF' "bash -euo pipefail <<EOF${NL}rm -rf /${NL}EOF" 1
grp 'bash -s s.sh <<EOF (-s 면 표준 입력)' "bash -s s.sh <<EOF${NL}rm -rf /${NL}EOF" 1
grp 'bash -n <<EOF (실행 안 함)' "bash -n <<EOF${NL}rm -rf /${NL}EOF" 0
grp 'bash -o noexec <<EOF (실행 안 함)' "bash -o noexec <<EOF${NL}rm -rf /${NL}EOF" 0
grp 'bash +o noexec <<EOF' "bash +o noexec <<EOF${NL}rm -rf /${NL}EOF" 1

t_section "R7: &>·&>> 뒤 셸 · 줄 잇기(\\) 뒤 구분자 · <<- 이어진 줄의 탭 · 2048자 창 경계 · P-B 상한 뒤에도 계속 읽기"
# 파서는 &>파일·&>>파일 을 한 단어로 둔다 — 예전엔 리디렉션으로 보지 않아 스크립트 파일 인수로 읽었다(본문이 데이터로)
grp 'bash &>/dev/null <<EOF' "bash &>/dev/null <<'EOF'${NL}cat .env${NL}EOF" 1
grp 'bash &> /dev/null <<EOF' "bash &> /dev/null <<'EOF'${NL}cat .env${NL}EOF" 1
grp 'bash &>>log <<EOF' "bash &>>/tmp/log <<'EOF'${NL}rm -rf /${NL}EOF" 1
grp 'source &>/dev/null /dev/stdin <<EOF' "source &>/dev/null /dev/stdin <<'EOF'${NL}rm -rf /${NL}EOF" 1
grp 'ssh host &>/dev/null <<EOF' "ssh host &>/dev/null <<'EOF'${NL}rm -rf /${NL}EOF" 1
grp 'bash &>/dev/null ./s.sh <<EOF (스크립트 파일)' "bash &>/dev/null ./s.sh <<'EOF'${NL}rm -rf /${NL}EOF" 0
grp 'bash &> /dev/null s.sh <<EOF (스크립트 파일)' "bash &> /dev/null s.sh <<'EOF'${NL}rm -rf /${NL}EOF" 0
# 따옴표 없는 구분자: 줄 끝 \(홀수 개)는 다음 줄과 한 줄이다(x\ 다음 줄 EOF 는 xEOF — bash·sh·zsh). 본문은 둘째 EOF 까지이고 뒤 명령이 최상위에 드러난다
seg_case 'x\ 다음 EOF 는 구분자가 아니다' "cat <<EOF${NL}x\\${NL}EOF${NL}'${NL}EOF${NL}rm -rf /" \
"cmd<T>cat <<EOF<T>cat <<EOF
heredoc<T><heredoc><T>x\\ EOF '
cmd<T>rm -rf /<T>rm -rf /"
seg_case '따옴표 구분자는 줄을 잇지 않는다' "cat <<'EOF'${NL}x\\${NL}EOF${NL}echo ok" \
"cmd<T>cat <<EOF<T>cat <<'EOF'
heredoc<T><heredoc><T>x\\
cmd<T>echo ok<T>echo ok"
seg_case '줄 끝 역슬래시 짝수 개는 잇지 않는다' "cat <<EOF${NL}x\\\\${NL}EOF${NL}echo ok" \
"cmd<T>cat <<EOF<T>cat <<EOF
heredoc<T><heredoc><T>x\\\\
cmd<T>echo ok<T>echo ok"
seg_case '\ 만 있는 줄 다음 EOF 는 이어서 EOF(구분자)' "cat <<EOF${NL}\\${NL}EOF${NL}echo ok" \
"cmd<T>cat <<EOF<T>cat <<EOF
heredoc<T><heredoc><T>\\
cmd<T>echo ok<T>echo ok"
seg_case 'bash <<EOF: echo a\ 와 EOF 는 한 줄(본문이 이어진다)' "bash <<EOF${NL}echo a\\${NL}EOF${NL}rm -rf /${NL}EOF" \
"cmd<T>bash <<EOF<T>bash <<EOF
heredoc<T><heredoc><T>echo a\\ EOF rm -rf /
push<T><<<T><<
sub<T>echo a\\ EOF rm -rf /<T>echo aEOF<NL>rm -rf /
pop<T>)<T>)"
seg_case '<<- 이은 줄은 논리 줄의 앞 탭만 지우고 견준다' "cat <<-EOF${NL}${TAB}x\\${NL}${TAB}EOF${NL}'${NL}${TAB}EOF${NL}rm -rf /" \
"cmd<T>cat <<-EOF<T>cat <<-EOF
heredoc<T><heredoc><T>x\\ EOF '
cmd<T>rm -rf /<T>rm -rf /"
seg_case '<<- 이어진 줄의 앞 탭은 남는다(셸과 같다 — 인수 구분)' "bash <<-EOF${NL}${TAB}rm -rf /tmp/x\\${NL}${TAB}/${NL}EOF" \
"cmd<T>bash <<-EOF<T>bash <<-EOF
heredoc<T><heredoc><T>rm -rf /tmp/x\\ /
push<T><<<T><<
sub<T>rm -rf /tmp/x\\ /<T>rm -rf /tmp/x<TB>/
pop<T>)<T>)"
# 이은 줄 끝의 $ 와 다음 줄의 ( 는 $( 다(셸이 \+개행을 먼저 지운다 — bash·zsh 가 치환을 실행한다). \$\ 는 리터럴
assert_eq '$\ 다음 줄 ( 는 치환' 1 "$(sp_segments "cat <<EOF${NL}\$\\${NL}(cat .env)${NL}EOF" | grep -c "^sub${TAB}cat .env")"
assert_eq '$\ 와 빈 이은 줄 다음 ( 도 치환' 1 "$(sp_segments "cat <<EOF${NL}\$\\${NL}\\${NL}(cat .env)${NL}EOF" | grep -c "^sub${TAB}cat .env")"
assert_eq '\$\ 다음 줄 ( 는 리터럴' 0 "$(sp_segments "cat <<EOF${NL}a \\\$\\${NL}(cat .env)${NL}EOF" | grep -c '^push')"
# 본문 스캐너는 줄을 2048자 창으로 나눠 본다 — 창 끝의 $ · \ 는 다음 창에서 다음 글자와 함께 본다
A2047=$(awk 'BEGIN{for(i=0;i<2047;i++) printf "a"}')
assert_eq '창 경계 $( 는 치환' 1 "$(sp_segments "cat <<EOF${NL}${A2047}\$(rm -rf /)${NL}EOF" | grep -c "^sub${TAB}rm -rf /")"
assert_eq '창 경계 \$( 는 리터럴' 0 "$(sp_segments "cat <<EOF${NL}${A2047}\\\$(rm -rf /)${NL}EOF" | grep -c '^push')"
assert_eq '창 경계 P-C 따옴표 제거(\$ → $)' "${A2047}\$(x)" "$(sp_segments "bash <<EOF${NL}${A2047}\\\$(x)${NL}EOF" | awk -F'\t' '$1=="sub"{print $3}')"
assert_eq '창 경계 P-C 줄 끝 \ 는 줄 잇기' "${A2047}b" "$(sp_segments "bash <<EOF${NL}${A2047}\\${NL}b${NL}EOF" | awk -F'\t' '$1=="sub"{print $3}')"
# P-B 치환 내부 상한(64 KB)을 넘어도 입력은 계속 읽는다 — 뒤 명령은 내고 overflow 는 맨 끝 한 번
A70K=$(awk 'BEGIN{for(i=0;i<70000;i++) printf "a"}')
o=$(sp_segments "cat > /tmp/o <<EOF${NL}\$(echo ${A70K})${NL}EOF${NL}rm -rf /")
assert_eq 'P-B 상한 넘은 치환 뒤 명령도 낸다' 1 "$(printf '%s\n' "$o" | grep -c "^cmd${TAB}rm -rf /")"
assert_eq 'P-B 상한 넘은 치환: overflow 는 맨 끝 한 번' "overflow 1" "$(printf '%s\n' "$o" | tail -n 1 | cut -f1) $(printf '%s\n' "$o" | grep -c '^overflow')"

t_report
