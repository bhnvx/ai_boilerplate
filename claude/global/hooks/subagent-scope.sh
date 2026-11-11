#!/usr/bin/env bash
# subagent-scope.sh — SubagentStop 훅: 서브에이전트가 위임 프롬프트의 '소유 파일' 밖을 고쳤는지 검사한다
#   (rules/subagent-policy.md 3·4절: "소유 파일(수정 허용)" · "한 파일은 한 에이전트만 수정한다").
# 방법: 서브에이전트 기록(agent_transcript_path)의 첫 사용자 입력(위임 프롬프트)에서 '소유 파일' 선언을 읽고,
#   같은 기록의 Edit·Write·MultiEdit·NotebookEdit 대상과 대조한다(lib/transcript.sh).
#   선언 형식: `소유 파일(수정 허용) a.py, src/b/ / 수정 금지 …` 한 줄(쉼표·공백·가운뎃점 구분) 또는 다음 줄부터의 목록(- a.py).
#   공백이 든 경로는 백틱으로 감싼다.
#   항목은 파일, 디렉터리(아래 전부), 글롭(src/*.py). '없음'이면 모든 수정이 범위 밖이다. 'owned files' 도 읽는다.
# 동작: 범위 밖 수정이 있으면 사용자에게 경고한다(systemMessage). CLAUDE_SUBAGENT_SCOPE=remind 면 서브에이전트에게 되돌려
#   (additionalContext) 보고의 '범위 밖 필요·발견'에 적게 한다(한 번만 — stop_hook_active 면 통과). 끄기: CLAUDE_SUBAGENT_SCOPE=off
# 선언이 없으면 검사하지 않는다(implementer 가 선언 없이 파일을 고쳤을 때만 알린다). 작업 디렉터리 밖 임시 디렉터리의 파일은 세지 않는다.
# 한계: Bash 로 고친 파일(sed -i·리디렉션·git)은 보지 못한다 — 통합 때 git status·git diff 확인을 대신하지 않는다. 막지 않고 알리기만 한다.

SS_DIR=$(cd -P -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) || exit 0
. "$SS_DIR/lib/common.sh" 2>/dev/null || exit 0
. "$SS_DIR/lib/transcript.sh" 2>/dev/null || exit 0
hook_off CLAUDE_SUBAGENT_SCOPE && exit 0

hook_read_input
H_ATP=""; H_CWD=""; H_ACTIVE=""; H_AGENT=""
hook_fields H_ATP=.agent_transcript_path H_CWD=.cwd H_ACTIVE=.stop_hook_active H_AGENT=.agent_type || exit 0
[ "$H_ACTIVE" = true ] && exit 0
[ -n "$H_ATP" ] || exit 0
hook_abspath_var "$H_ATP" "$PWD"; ss_atp=$HOOK_ABS
ss_cwd=${H_CWD:-$PWD}; ss_cwd=${ss_cwd%/}

# 1) 서브에이전트가 고친 파일(중복 제거, 임시 디렉터리 제외)
ss_ev=$(hook_tx_events "$ss_atp" 20971520) || exit 0
ss_abs=(); ss_rel=(); ss_seen=$'\n'
while IFS=$'\t' read -r ss_k ss_p; do
  [ "$ss_k" = E ] && [ -n "$ss_p" ] || continue
  hook_abspath_var "$ss_p" "$ss_cwd"; ss_p=$HOOK_ABS
  case $ss_p in
    "$ss_cwd"/*) ;;                                # 작업 디렉터리 안이면 임시 경로여도 센다
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*|/var/tmp/*|/private/var/tmp/*) continue ;;
  esac
  case $ss_seen in *$'\n'"$ss_p"$'\n'*) continue ;; esac
  ss_seen="$ss_seen$ss_p"$'\n'
  ss_abs[${#ss_abs[@]}]=$ss_p
  case $ss_p in "$ss_cwd"/*) ss_rel[${#ss_rel[@]}]=${ss_p#"$ss_cwd"/} ;; *) ss_rel[${#ss_rel[@]}]=$ss_p ;; esac
done <<SSEOF
$ss_ev
SSEOF
[ "${#ss_abs[@]}" -gt 0 ] || exit 0

# 2) 위임 프롬프트의 소유 파일 선언 → 첫 줄 DECL|NONE, 이후 줄마다 항목(경로처럼 생긴 ASCII 낱말만)
ss_decl=$(hook_tx_prompt "$ss_atp" | LC_ALL=C awk '
  function emit(t,  k, a, i, w, b, e, q) {
    while ((b = index(t, "`")) > 0) {                              # 백틱으로 감싼 항목은 통째로 한 경로(공백이 든 경로)
      q = substr(t, b + 1); e = index(q, "`"); if (e == 0) break
      w = substr(q, 1, e - 1); if (w != "") items[++ni] = w
      t = substr(t, 1, b - 1) " " substr(q, e + 1) }
    gsub(/[,`"\047]/, " ", t); gsub(/\302\267/, " ", t)        # 쉼표·남은 백틱·따옴표·가운뎃점(·)
    k = split(t, a, /[ \t]+/)
    for (i = 1; i <= k; i++) { w = a[i]
      if (w ~ /^\354\227\206\354\235\214/) { none = 1; continue }   # 없음
      sub(/[;:]+$/, "", w)
      if (w ~ PATHRE && w != "/" && w != "-") items[++ni] = w } }
  function cut(t,  j) {
    j = index(t, "\354\210\230\354\240\225 \352\270\210\354\247\200"); if (j > 0) t = substr(t, 1, j - 1)   # 수정 금지
    j = index(t, "\354\235\275\354\235\204 \352\263\263"); if (j > 0) t = substr(t, 1, j - 1)             # 읽을 곳
    sub(/[ \t\/]+$/, "", t); return t }
  BEGIN { PATHRE = "^[]A-Za-z0-9_.@~*?{}[/+-]+$" }
  found == 1 { next }
  found == 2 {                                    # 선언 줄이 비어 있었다 → 이어지는 목록(- a.py · 1. a.py)
    if ($0 ~ /^[ \t]*([-*]|[0-9]+[.)])[ \t]+/) { t = $0; sub(/^[ \t]*([-*]|[0-9]+[.)])[ \t]+/, "", t); emit(cut(t)); next }
    if ($0 ~ /^[ \t]*$/ && !ni && !none) next
    found = (ni || none) ? 1 : 0
    if (found) next }
  { key = "\354\206\214\354\234\240 \355\214\214\354\235\274"; i = index($0, key); kl = length(key)     # 소유 파일
    if (!i) { low = tolower($0); i = index(low, "owned files"); kl = 11 }
    if (!i) next
    rest = substr($0, i + kl)
    sub(/^[ \t]*\([^)]*\)/, "", rest); sub(/^[ \t]*:?[ \t]*/, "", rest)
    if (substr(rest, 1, 3) == "\357\274\232") rest = substr(rest, 4)                                      # 전각 콜론
    rest = cut(rest)
    if (rest ~ /^[ \t]*$/) { found = 2; next }
    emit(rest); if (ni || none) found = 1 }                 # 경로가 없는 문장("소유 파일 밖은 …")이면 다음 줄에서 계속 찾는다
  END { if (ni) print "DECL"; else if (none) print "NONE"; else exit
        for (i = 1; i <= ni; i++) print items[i] }')

ss_owned=(); ss_state=""
while IFS= read -r ss_l; do
  [ -n "$ss_l" ] || continue
  if [ -z "$ss_state" ]; then ss_state=$ss_l; continue; fi
  case $ss_l in
    */*|*.*|*'*'*) ss_owned[${#ss_owned[@]}]=$ss_l ;;
    *) [ -e "$ss_cwd/$ss_l" ] && ss_owned[${#ss_owned[@]}]=$ss_l ;;       # 구분자 없는 낱말은 실제로 있을 때만(README·src)
  esac
done <<SSEOF
$ss_decl
SSEOF
[ "$ss_state" = DECL ] && [ "${#ss_owned[@]}" -eq 0 ] && ss_state=""

ss_join() {  # <최대 개수> 항목… → SS_J ("a, b, c 외 N개")
  local max=$1 i=0 x; shift; SS_J=""
  for x in "$@"; do
    i=$((i + 1)); [ "$i" -le "$max" ] && SS_J="${SS_J:+$SS_J, }$x"
  done
  [ "$i" -gt "$max" ] && SS_J="$SS_J 외 $((i - max))개"
  return 0
}
ss_who=${H_AGENT:-서브에이전트}

if [ -z "$ss_state" ]; then
  # 선언 없음: 구현 담당만 알린다(탐색·리뷰 에이전트와 Claude Code 내부 에이전트는 조용히 통과)
  [ "$H_AGENT" = implementer ] || exit 0
  ss_join 3 "${ss_rel[@]}"
  hook_log "$HOOK_NAME" notify subagent:no-scope "$SS_J"
  hook_emit_system "소유 파일 선언 없음 [subagent:no-scope]: implementer 위임 프롬프트에서 '소유 파일' 선언을 찾지 못해 수정 범위를 검사하지 못했다(수정 파일 ${#ss_rel[@]}개: $SS_J) — git diff 로 직접 확인할 것"
  exit 0
fi

# 3) 대조: 같은 경로 · 디렉터리 아래 · 글롭(case 의 * 는 / 도 넘으므로 ** 와 같다)
ss_is_owned() {  # <절대 경로> <cwd 기준 경로>
  local o t
  for o in ${ss_owned[@]+"${ss_owned[@]}"}; do
    case $o in ./*) o=${o#./} ;; '~/'*) o=$HOME/${o#\~/} ;; esac
    case $o in /*) t=$1 ;; *) t=$2 ;; esac
    while case $o in ?*/) true ;; *) false ;; esac; do o=${o%/}; done
    [ "$t" = "$o" ] && return 0
    case $t in "$o"/*) return 0 ;; esac
    case $o in *[\*\?\[]*) case $t in $o|$o/*) return 0 ;; esac ;; esac
  done
  return 1
}
ss_out=(); ss_i=0
while [ "$ss_i" -lt "${#ss_abs[@]}" ]; do
  ss_is_owned "${ss_abs[$ss_i]}" "${ss_rel[$ss_i]}" || ss_out[${#ss_out[@]}]=${ss_rel[$ss_i]}
  ss_i=$((ss_i + 1))
done
[ "${#ss_out[@]}" -gt 0 ] || exit 0

ss_join 5 "${ss_out[@]}"; ss_files=$SS_J
if [ "$ss_state" = NONE ]; then ss_own="없음"; else ss_join 5 "${ss_owned[@]}"; ss_own=$SS_J; fi
ss_msg="소유 파일 밖 수정 [subagent:out-of-scope]: ${ss_who}가 위임 프롬프트의 소유 파일 밖을 수정했다: $ss_files (소유 파일: $ss_own)"
case ${CLAUDE_SUBAGENT_SCOPE:-} in
  [Rr][Ee][Mm][Ii][Nn][Dd])
    hook_log "$HOOK_NAME" remind subagent:out-of-scope "$ss_files"
    hook_emit_context SubagentStop "$ss_msg — 더 고치거나 되돌리지 말고, 보고의 '범위 밖 필요·발견'에 이 파일과 고친 이유를 적을 것" ;;
  *)
    hook_log "$HOOK_NAME" notify subagent:out-of-scope "$ss_files"
    hook_emit_system "$ss_msg — git diff 로 확인할 것" ;;
esac
exit 0
