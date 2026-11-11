#!/usr/bin/env bash
# lib/transcript.sh — 세션 기록(JSONL)에서 도구 호출을 뽑는 공용 함수 (stop-verify · subagent-scope 훅용; bash 3.2 호환)
# 사용법: lib/common.sh 를 먼저 읽은 뒤 . "$DIR/lib/transcript.sh"
# 기록 형식은 공식 문서에 없다(Claude Code 2.1.318 실측): 한 줄에 JSON 하나, type 이 user·assistant 인 줄의
# message.content 가 글(문자열) 또는 항목 배열(text · tool_use{name,input} · tool_result)이다. 형식이 바뀌면 이 함수들은
# 아무것도 내지 않고, 부르는 훅은 조용히 통과한다(fail-open). 기록은 비동기로 쓰여 가장 최근 호출이 빠져 있을 수 있다.
#
# hook_tx_events <file> [<max-bytes>=4194304] → 줄마다 다음 중 하나(기록 순서 그대로)
#     U              사용자 입력(도구 결과와 isMeta 줄은 제외) — 턴의 시작
#     E<TAB>경로     Edit · Write · MultiEdit · NotebookEdit 의 대상 파일
#     B<TAB>명령     Bash · Monitor 의 명령(탭·개행은 공백, 앞 2000자)
#   파일이 max-bytes 보다 크면 끝부분만 읽는다(잘린 첫 줄은 JSON 이 아니라 건너뛴다). 깨진 줄도 건너뛴다.
#   반환 1: 파일을 읽을 수 없거나 파서(jq/python3)가 없다.
# hook_tx_prompt <file> → 첫 사용자 입력의 글(서브에이전트 기록에서는 위임 프롬프트). 파일 앞 1 MB 안에서만 찾는다.

HOOK_TX_JQ_EVENTS='def flat: split("\n")|join(" ")|split("\t")|join(" ")|split("\r")|join(" ");
fromjson? | select(type=="object")
| if .type=="user" and (.isMeta != true) then
    (.message.content) as $c
    | if ($c|type)=="string" then "U"
      elif ($c|type)=="array" and ([$c[]|select(type=="object" and .type=="text")]|length)>0 then "U"
      else empty end
  elif .type=="assistant" and ((.message.content|type)=="array") then
    .message.content[] | select(type=="object" and .type=="tool_use") | (.name) as $n | (.input) as $i
    | if ($i|type)!="object" then empty
      elif $n=="Edit" or $n=="Write" or $n=="MultiEdit" or $n=="NotebookEdit" then
        (($i.file_path // $i.notebook_path // "")|tostring|flat) as $p | if $p=="" then empty else "E\t"+$p end
      elif $n=="Bash" or $n=="Monitor" then
        (($i.command // "")|tostring|flat) as $s | if $s=="" then empty else "B\t"+$s[0:2000] end
      else empty end
  else empty end'

HOOK_TX_PY_EVENTS='import json,sys
def flat(s): return s.replace("\n"," ").replace("\t"," ").replace("\r"," ")
w=sys.stdout.buffer.write
for raw in sys.stdin.buffer:
    try: d=json.loads(raw.decode("utf-8","replace"))
    except Exception: continue
    if not isinstance(d,dict): continue
    m=d.get("message"); c=m.get("content") if isinstance(m,dict) else None
    t=d.get("type")
    if t=="user" and d.get("isMeta") is not True:
        if isinstance(c,str) or (isinstance(c,list) and any(isinstance(x,dict) and x.get("type")=="text" for x in c)): w(b"U\n")
    elif t=="assistant" and isinstance(c,list):
        for x in c:
            if not (isinstance(x,dict) and x.get("type")=="tool_use"): continue
            n=x.get("name"); i=x.get("input")
            if not isinstance(i,dict): continue
            if n in ("Edit","Write","MultiEdit","NotebookEdit"):
                p=i.get("file_path") or i.get("notebook_path") or ""
                if p: w(("E\t"+flat(str(p))+"\n").encode("utf-8","replace"))
            elif n in ("Bash","Monitor"):
                s=i.get("command") or ""
                if s: w(("B\t"+flat(str(s))[:2000]+"\n").encode("utf-8","replace"))'

HOOK_TX_JQ_PROMPT='first(inputs | fromjson? | select(type=="object" and .type=="user" and .isMeta != true) | .message.content
  | if type=="string" then . elif type=="array" then ([.[]|select(type=="object" and .type=="text")|.text|tostring]|join("\n")) else empty end
  | select(length>0))'

HOOK_TX_PY_PROMPT='import json,sys
for raw in sys.stdin.buffer:
    try: d=json.loads(raw.decode("utf-8","replace"))
    except Exception: continue
    if not isinstance(d,dict) or d.get("type")!="user" or d.get("isMeta") is True: continue
    m=d.get("message"); c=m.get("content") if isinstance(m,dict) else None
    if isinstance(c,list): c="\n".join(str(x.get("text","")) for x in c if isinstance(x,dict) and x.get("type")=="text")
    if isinstance(c,str) and c:
        sys.stdout.buffer.write((c+"\n").encode("utf-8","replace")); break'

hook_tx_events() {
  local __f=$1 __max=${2:-4194304} __sz
  [ -f "$__f" ] && [ -r "$__f" ] || return 1
  hook_detect_parser || return 1
  __sz=$(wc -c <"$__f" 2>/dev/null); __sz=${__sz//[!0-9]/}
  [ -n "$__sz" ] || return 1
  if [ "$__sz" -gt "$__max" ]; then tail -c "$__max" "$__f"; else cat "$__f"; fi 2>/dev/null |
    if [ "$HOOK_JSON_TOOL" = jq ]; then jq -Rr "$HOOK_TX_JQ_EVENTS" 2>/dev/null
    else python3 -I -S -c "$HOOK_TX_PY_EVENTS" 2>/dev/null; fi
  return 0
}

hook_tx_prompt() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  hook_detect_parser || return 1
  head -c 1048576 "$1" 2>/dev/null |
    if [ "$HOOK_JSON_TOOL" = jq ]; then jq -Rrn "$HOOK_TX_JQ_PROMPT" 2>/dev/null
    else python3 -I -S -c "$HOOK_TX_PY_PROMPT" 2>/dev/null; fi
  return 0
}
