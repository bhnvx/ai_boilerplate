#!/usr/bin/env bash
# tests/hooks/test-guards-nested-2.sh — 라운드 6 G-A 의 무거운 상한 케이스(test-guards-nested.sh 에서 나눴다 — 스위트마다 BWK 에서 1분 안):
#   다시 파싱하는 셸 문자열 200개(GD_/GS_FORKCAP)는 모든 깊이가 함께 쓴다 — 넘은 문자열은 한 세그먼트, 앞의 deny 는 그대로, too-complex 바닥.
#   지연: 상한 근처의 중첩 문자열(문자열 220개, 깊이 1·2)도 훅 하나가 수 초 안.
# tg 는 단계(none|ask-low|ask-high|deny)를 확인한다: ask 이면 auto 모드로 다시 돌려 low(침묵)·high 를 가른다.
# 명령 문자열은 훅의 stdin JSON 으로만 전달되며 실행되지 않는다.
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
t_setup
unset CLAUDE_GUARD_PROTECTED_BRANCHES CLAUDE_GUARD_ASK_ON_PUSH CLAUDE_GUARD_ALLOW_PATTERNS CLAUDE_GUARD_SECRET_EXTRA CLAUDE_GUARD_SECRET_ALLOW SP_WBMAX HOOK_TLIM
AGENT_ID='{"agent_id":"agent-1","agent_type":"implementer"}'
NL=$'\n'
SUBD="$T_PROJ/sub dir"; mkdir -p "$SUBD"   # 저장소 최상위가 아닌 디렉터리(rm -rf * 가 ask-low)

tier() {  # <guard> <cmd> [agent-json] [cwd] → 단계[규칙]
  local h="$T_HOOKS/$1.sh" d a r
  t_run_hook "$h" "$(t_bash_json "$2" "${4:-}" default "${3:-}")"; d=$(t_decision "$T_OUT")
  r=$(t_reason "$T_OUT" | grep -o '\[[a-z]*:[A-Za-z0-9_-]*\]' | head -n 1)
  if [ "$d" = ask ]; then
    t_run_hook "$h" "$(t_bash_json "$2" "${4:-}" auto "${3:-}")"; a=$(t_decision "$T_OUT")
    if [ "$a" = ask ]; then d=ask-high; else d=ask-low; fi
  fi
  printf '%s%s\n' "$d" "$r"
}
tname() { local n=${1:0:110}; n=${n//$'\n'/⏎}; printf '%s' "$n"; }   # 테스트 이름(앞 110자, 개행 표시)
tg() {  # <guard> <expect: 단계 또는 단계[규칙]> <cmd> [sub|-] [cwd] — sub 이면 서브에이전트(agent_id)
  local got want=$2 ag=""
  [ "${4:-}" = sub ] && ag=$AGENT_ID
  got=$(tier "$1" "$3" "$ag" "${5:-}")
  case $want in *'['*) ;; *) got=${got%%\[*} ;; esac
  assert_eq "${1#guard-}${4:+/$4}: $(tname "$3")" "$want" "$got"
}
same() {  # <guard> <cmd> <기준 cmd> [sub|-] [cwd] — 두 명령의 단계가 같다(문자열 안에서 = 최상위에서)
  local a b ag=""
  [ "${4:-}" = sub ] && ag=$AGENT_ID
  a=$(tier "$1" "$2" "$ag" "${5:-}"); b=$(tier "$1" "$3" "$ag" "${5:-}")
  assert_eq "${1#guard-}${4:+/$4}: $(tname "$2") == $(tname "$3")" "${b%%\[*}" "${a%%\[*}"
}
none2() {  # <cmd>... — guard-destructive·guard-secrets 모두(서브에이전트도) 결정 없음
  local c
  for c in "$@"; do tg guard-destructive none "$c"; tg guard-destructive none "$c" sub; tg guard-secrets none "$c"; tg guard-secrets none "$c" sub; done
}
rep() {  # <조각> <횟수> <끝> [구분자] — "조각<구분자>" 를 횟수만큼 잇고 끝을 붙인다(기본 "; ". printf 한 번 — 문자열 덧붙이기 반복은 2차 비용)
  local a=() k=0 s f="%s${4-; }"
  while [ "$k" -lt "$2" ]; do a[$k]=$1; k=$((k + 1)); done
  printf -v s "$f" "${a[@]}"; printf '%s%s' "$s" "$3"
}

t_section "G-A 상한: 다시 파싱하는 문자열 200개는 모든 깊이 합 — 넘은 문자열은 한 세그먼트, 앞의 deny 는 그대로, too-complex 바닥"
C2=$(rep $'sh -c \'sh -c "echo x"\'' 110 'true')            # 문자열 220개(깊이 1·2)
C3=$(rep $'sh -c \'bash -c "sh -c \\"echo x\\""\'' 70 'true')   # 문자열 210개(깊이 1·2·3)
for C in "$C2" "$C3"; do
  tg guard-destructive 'deny[destructive:rm-root]' $'sh -c \'sh -c "echo a; rm -rf /"\'; '"$C"
  tg guard-destructive deny $'sh -c \'sh -c "echo a; rm -rf /"\'; '"$C" sub
  tg guard-destructive 'ask-high[destructive:too-complex]' "$C"$'; sh -c \'sh -c "echo a; rm -rf /"\''   # 상한 뒤 문자열은 한 세그먼트(머리 sh)
  tg guard-destructive 'deny[destructive:too-complex]' "$C"$'; sh -c \'sh -c "echo a; rm -rf /"\'' sub
  tg guard-destructive 'deny[destructive:rm-root]' "$C; sh -c 'rm -rf /'"                              # 한 세그먼트도 머리로 판정(rm)
  tg guard-destructive 'deny[destructive:rm-root]' "$C; rm -rf /"
  tg guard-secrets 'deny[secrets:print]' $'sh -c \'sh -c "echo a; cat .env"\'; '"$C"
  tg guard-secrets ask-high "$C"$'; sh -c \'sh -c "echo a; cat .env"\''
  tg guard-secrets 'deny[secrets:too-complex]' "$C"$'; sh -c \'sh -c "echo a; cat .env"\'' sub
  tg guard-secrets 'deny[secrets:print]' "$C; cat .env"
done
tg guard-destructive 'ask-high[destructive:too-complex]' "$C2"; tg guard-destructive 'deny[destructive:too-complex]' "$C2" sub
tg guard-secrets 'ask-high[secrets:too-complex]' "$C2 .env.example"; tg guard-secrets 'deny[secrets:too-complex]' "$C2 .env.example" sub
C=$(rep $'sh -c \'sh -c "echo x"\'' 40 'true')   # 상한 아래(문자열 80개)는 끝까지 판정
tg guard-destructive 'deny[destructive:rm-root]' "$C"$'; sh -c \'sh -c "echo a; rm -rf /"\''
tg guard-secrets 'deny[secrets:print]' "$C"$'; sh -c \'sh -c "echo a; cat .env"\''
tg guard-destructive none "$C"; tg guard-secrets none "$C .env.example"
t_section "지연: 상한 근처의 중첩 문자열(문자열 220개, 깊이 1·2)도 훅 하나가 수 초 안"
rep $'sh -c \'sh -c "echo x; ls"\'' 110 'git push --force origin main; cat .env' >"$T_TMP/nested-big.txt"
for g in guard-destructive guard-secrets; do
  t0=$(t_ms); t_run_hook "$g" "$(t_bash_json_file "$T_TMP/nested-big.txt")"; t1=$(t_ms)
  assert_eq "R6 ${g#guard-}: 문자열 220개(깊이 1·2) 뒤 위험 명령 → deny" deny "$(t_decision "$T_OUT")"
  t_under "R6 ${g#guard-}: 문자열 220개(깊이 1·2) 시간" $((t1 - t0)) 8000
done

t_report
