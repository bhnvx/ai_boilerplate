#!/usr/bin/env bash
# session-context.sh — SessionStart(모든 source) 훅: 저장소 상태·스택·규칙 파일 현황을 additionalContext 로 주입.
# 끄기: CLAUDE_SESSION_CONTEXT=off. 보호 브랜치: CLAUDE_GUARD_PROTECTED_BRANCHES — guard-destructive 와 같은 해석
#   (쉼표/공백 구분, 항목은 글롭 가능 release/*, 빈 값 또는 none(대소문자 무관) = 경고 없음, 변수가 없을 때만 기본 "main master").
# git 호출: status 1회(--porcelain=v2 --branch) + log 1회. 실패하면 조용히 exit 0. 결정은 하지 않는다(컨텍스트만).
# 파서(jq/python3)가 없으면 같은 내용을 일반 stdout 으로 출력한다(SessionStart 는 일반 stdout 도 컨텍스트가 됨).

SC_DIR=$(cd -P -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) || exit 0
. "$SC_DIR/lib/common.sh" 2>/dev/null || exit 0
hook_off CLAUDE_SESSION_CONTEXT && exit 0

hook_read_input
H_CWD=""; H_SOURCE=""; sc_parser=1
hook_fields H_CWD=.cwd H_SOURCE=.source
[ $? -eq 1 ] && sc_parser=0
if [ "$sc_parser" = 0 ]; then
  # 파서 없음: 단순 문자열만 정규식으로 꺼낸다(이스케이프가 있는 값은 포기)
  sc_re='"source"[[:space:]]*:[[:space:]]*"([A-Za-z_-]+)"'
  [[ $HOOK_INPUT =~ $sc_re ]] && H_SOURCE=${BASH_REMATCH[1]}
  sc_re='"cwd"[[:space:]]*:[[:space:]]*"([^"\\]+)"'
  [[ $HOOK_INPUT =~ $sc_re ]] && H_CWD=${BASH_REMATCH[1]}
fi
cwd=${H_CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}
[ -d "$cwd" ] || cwd=${CLAUDE_PROJECT_DIR:-$PWD}
[ -d "$cwd" ] || exit 0
cwd=$(hook_abspath "$cwd" "$PWD")

sc_lines=()
sc_add() { sc_lines[${#sc_lines[@]}]=$1; }

sc_add "[세션 컨텍스트 · dev_settings 훅]"
sc_date=$(LC_ALL=C date '+%Y-%m-%d (%a)' 2>/dev/null)
if [ -n "$H_SOURCE" ]; then sc_add "날짜: $sc_date · 소스: $H_SOURCE"; else sc_add "날짜: $sc_date"; fi

# --- 저장소 상태(git status 1회) -------------------------------------------------
root=$cwd
st=$(git --no-optional-locks -C "$cwd" status --porcelain=v2 --branch -unormal 2>/dev/null) || st=""
head=""
if [ -n "$st" ]; then
  # 작업 트리 루트: cwd 에서 위로 .git(디렉터리 또는 worktree 파일)을 찾는다(fork 없음)
  d=$cwd
  while :; do
    if [ -e "$d/.git" ]; then root=$d; break; fi
    case $d in /|'') break ;; esac
    d=${d%/*}; [ -n "$d" ] || d=/
  done
  sum=$(printf '%s\n' "$st" | LC_ALL=C awk '
    $1 == "#" && $2 == "branch.oid" { oid = $3; next }
    $1 == "#" && $2 == "branch.head" { hd = $3; next }
    $1 == "#" && $2 == "branch.upstream" { up = $3; next }
    $1 == "#" && $2 == "branch.ab" { a = $3; b = $4; sub(/^\+/, "", a); sub(/^-/, "", b); ab = 1; next }
    $1 == "#" { next }
    $1 == "1" || $1 == "2" || $1 == "u" { n++; if (substr($2, 1, 1) != ".") s++; if (substr($2, 2, 1) != ".") w++; next }
    $1 == "?" { n++; t++; next }
    END {
      if (oid == "") oid = "-"; if (hd == "") hd = "-"; if (up == "") up = "-"
      if (!ab) { a = "-"; b = "-" }
      printf "%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\n", oid, hd, up, a, b, n, s, w, t
    }')
  set -f; sc_ifs=$IFS; IFS=$'\t'
  set -- $sum
  IFS=$sc_ifs; set +f
  oid=${1:--}; head=${2:--}; up=${3:--}; ahead=${4:--}; behind=${5:--}
  n=${6:-0}; staged=${7:-0}; unstaged=${8:-0}; untracked=${9:-0}

  if [ "$head" = "(detached)" ]; then
    br="HEAD 분리(${oid:0:7})"; head=""
  elif [ "$up" != "-" ] && [ "$ahead" != "-" ]; then
    br="$head ($up 대비 ahead $ahead / behind $behind)"
  elif [ "$up" != "-" ]; then
    br="$head ($up — 원격 브랜치 없음)"
  else
    br="$head (upstream 없음)"
  fi
  sc_add "저장소: ${root##*/} · 브랜치: $br · 변경: $n (staged $staged / unstaged $unstaged / untracked $untracked)"

  if [ "$oid" != "(initial)" ] && [ "$oid" != "-" ]; then
    lg=$(git --no-optional-locks -C "$cwd" log -3 --no-color '--format=%h%x09%<(60,trunc)%s' 2>/dev/null)
    commits=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      h=${line%%$'\t'*}; s=${line#*$'\t'}
      while case $s in *' ') true ;; *) false ;; esac; do s=${s%' '}; done
      commits="${commits:+$commits · }$h $s"
    done <<EOF
$lg
EOF
    [ -n "$commits" ] && sc_add "최근 커밋: $commits"
  fi
fi

# --- 스택 ---------------------------------------------------------------------
stack_txt=""
if . "$SC_DIR/lib/detect-stack.sh" 2>/dev/null; then
  detect_stack "$cwd"
  [ -z "$DETECT_STACK" ] && [ "$root" != "$cwd" ] && detect_stack "$root"
  last=""
  for t in $DETECT_STACK; do
    case $t in
      uv|poetry|pipenv|pip)
        if [ "$last" = python ]; then stack_txt="${stack_txt%python}python($t)"; last=done; continue; fi ;;
      pnpm|yarn|bun|npm)
        if [ "$last" = node ]; then stack_txt="${stack_txt%node}node($t)"; last=done; continue; fi ;;
    esac
    stack_txt="${stack_txt:+$stack_txt · }$t"; last=$t
  done
fi
sc_add "스택: ${stack_txt:-감지 안 됨}"

# --- 규칙 파일 -----------------------------------------------------------------
if [ -f "$root/CLAUDE.md" ]; then r1="CLAUDE.md ✓"
elif [ -f "$root/.claude/CLAUDE.md" ]; then r1=".claude/CLAUDE.md ✓"
else r1="CLAUDE.md ✗"; fi
nr=0
for f in "$root"/.claude/rules/*.md "$root"/.claude/rules/*/*.md; do [ -f "$f" ] && nr=$((nr + 1)); done
r3="CLAUDE.local.md ✗"; [ -f "$root/CLAUDE.local.md" ] && r3="CLAUDE.local.md ✓"
r4="AGENTS.md ✗"; [ -f "$root/AGENTS.md" ] && r4="AGENTS.md ✓"
sc_add "규칙 파일: $r1 · .claude/rules ${nr}개 · $r3 · $r4"

# --- 경고 -----------------------------------------------------------------------
# 보호 브랜치 판정은 lib/common.sh 의 hook_is_protected_branch 하나로 한다(guard-destructive 와 같은 해석:
# 변수가 없을 때만 기본 main master, 쉼표·공백 구분, 글롭 가능, none 또는 빈 값이면 끔)
if [ -n "$head" ] && [ "$head" != "-" ] && hook_is_protected_branch "$head"; then
  sc_add "⚠ 보호 브랜치($head)에서 작업 중 — 커밋 전 브랜치 생성 여부를 사용자와 확인"
fi
[ "$sc_parser" = 0 ] && sc_add "⚠ 가드 비활성: jq/python3 없음"

# --- 출력(최대 25줄) -------------------------------------------------------------
text=""
i=0
while [ $i -lt ${#sc_lines[@]} ] && [ $i -lt 25 ]; do
  text="${text:+$text
}${sc_lines[$i]}"
  i=$((i + 1))
done
if [ "$sc_parser" = 1 ]; then
  hook_emit_context SessionStart "$text"
else
  printf '%s\n' "$text"
fi
exit 0
