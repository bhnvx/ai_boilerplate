#!/usr/bin/env bash
# statusline.sh — Claude Code statusLine 명령. stdin JSON → 상태 한 줄. 항상 exit 0, 출력은 최대 1줄.
# 형식: <모델> │ ⎇ <브랜치><*> │ ctx <n>% │ 5h <n>% [7d <n>%] (없으면 $<비용>) │ <디렉터리> [│ eff <level>] [│ PR #<n>]
# 색: CLAUDE_STATUSLINE_COLOR=0 또는 NO_COLOR 로 끔(ctx ≥70 노랑, ≥85 빨강; 5h ≥80 빨강).
# LANG/LC_ALL/LC_CTYPE 에 UTF-8 이 없으면 ASCII 구분자(|) 사용.
# git: status --porcelain=v2 1회, 결과는 ${TMPDIR:-/tmp}/claude-statusline-<dir cksum> 에 2초 캐시.
[ "${CLAUDE_HOOKS_DEBUG:-}" = "1" ] || exec 2>/dev/null
SL_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P) || exit 0
. "$SL_DIR/lib/common.sh" || exit 0

hook_read_input
hook_fields SL_MODEL='.model.display_name|.model.id' SL_CWD='.workspace.current_dir|.cwd' \
  SL_COST=.cost.total_cost_usd SL_PCT=.context_window.used_percentage \
  SL_TIN=.context_window.total_input_tokens SL_CSIZE=.context_window.context_window_size \
  SL_EFF=.effort.level SL_R5=.rate_limits.five_hour.used_percentage \
  SL_R7=.rate_limits.seven_day.used_percentage SL_WTB=.worktree.branch SL_PR=.pr.number
sl_rc=$?
if [ "$sl_rc" -eq 1 ]; then printf '%s\n' 'dev_settings: jq/python3 없음 — 훅 비활성'; exit 0; fi
[ "$sl_rc" -eq 0 ] || exit 0

# sl_num <json-number> [scale] → SL_R = round_half_up(value * scale) (정수). 숫자가 아니면 1 반환.
sl_num() {
  local v=$1 sc=${2:-1} i f d
  SL_R=""
  case $v in ''|*[!0-9.eE+-]*) return 1 ;; esac
  case $v in
    -*) SL_R=0; return 0 ;;
    *[eE]-*) SL_R=0; return 0 ;;          # 1e-05 같은 아주 작은 값
    *[eE]*) return 1 ;;
  esac
  i=${v%%.*}; f=""
  case $v in *.*) f=${v#*.} ;; esac
  [ -n "$i" ] || i=0
  case $i$f in *[!0-9]*) return 1 ;; esac
  f="${f}000"
  if [ "$sc" = 100 ]; then
    i=$((10#$i * 100 + 10#${f:0:2})); d=${f:2:1}
  else
    i=$((10#$i)); d=${f:0:1}
  fi
  [ "$d" -ge 5 ] && i=$((i + 1))
  SL_R=$i
  return 0
}

# 표시 문자열 정리: 제어 문자 제거(한 줄 보장, 터미널 이스케이프 주입 방지)
sl_clean() {
  local s=$1
  s=${s//$'\n'/ }; s=${s//$'\r'/ }; s=${s//$'\t'/ }; s=${s//$'\033'/}; s=${s//$'\a'/}
  SL_S=$s
}

dir=${SL_CWD:-$PWD}

# --- git 브랜치/변경 여부(2초 캐시) -------------------------------------------------
key=$(printf '%s' "$dir" | cksum); key=${key%% *}
cache=${TMPDIR:-/tmp}; cache="${cache%/}/claude-statusline-$key"
now=$(date +%s)
br=""; dirty=""; hit=0
if [ -f "$cache" ] && [ ! -L "$cache" ]; then
  { IFS= read -r c_t; IFS= read -r c_dir; IFS= read -r br; IFS= read -r dirty; } <"$cache"
  case $c_t in
    ''|*[!0-9]*) ;;
    *) [ "$c_dir" = "$dir" ] && [ $((now - c_t)) -ge 0 ] && [ $((now - c_t)) -lt 2 ] && hit=1 ;;
  esac
  [ "$hit" = 1 ] || { br=""; dirty=""; }
fi
if [ "$hit" = 0 ]; then
  gs=$(git --no-optional-locks -C "$dir" status --porcelain=v2 --branch -uno 2>/dev/null | head -5)
  oid=""
  while IFS= read -r l; do
    case $l in
      '# branch.oid '*) oid=${l#'# branch.oid '} ;;
      '# branch.head '*) br=${l#'# branch.head '} ;;
      '#'*|'') ;;
      *) dirty='*' ;;
    esac
  done <<EOF
$gs
EOF
  [ "$br" = "(detached)" ] && br="HEAD@${oid:0:7}"
  if [ -n "$gs" ]; then
    tmp=$(mktemp "$cache.XXXXXX") &&
      printf '%s\n%s\n%s\n%s\n' "$now" "$dir" "$br" "$dirty" >"$tmp" &&
      mv -f "$tmp" "$cache" || rm -f "$tmp"
  fi
fi
[ -n "$br" ] || { br=$SL_WTB; dirty=""; }

# --- 표시 형식 --------------------------------------------------------------------
loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
case $loc in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) sep=' │ '; brsym='⎇ ' ;;
  *) sep=' | '; brsym='git:' ;;
esac
color=1
[ "${CLAUDE_STATUSLINE_COLOR:-}" = "0" ] && color=0
[ -n "${NO_COLOR:-}" ] && color=0
if [ "$color" = 1 ]; then c_y=$'\033[33m'; c_r=$'\033[31m'; c_0=$'\033[0m'; else c_y=""; c_r=""; c_0=""; fi

line=""
sl_seg() { line="${line:+$line$sep}$1"; }

sl_clean "$SL_MODEL"; [ -n "$SL_S" ] && sl_seg "$SL_S"
sl_clean "$br"; [ -n "$SL_S" ] && sl_seg "$brsym$SL_S$dirty"

pct=""
if sl_num "$SL_PCT" && [ "$SL_R" -gt 0 ]; then
  pct=$SL_R
elif sl_num "$SL_CSIZE" && [ "$SL_R" -gt 0 ]; then
  cs=$SL_R
  if sl_num "$SL_TIN" && [ "$SL_R" -gt 0 ]; then pct=$(( (SL_R * 100 + cs / 2) / cs )); fi
fi
if [ -n "$pct" ] && [ "$pct" -gt 0 ]; then
  if [ "$pct" -ge 85 ]; then sl_seg "${c_r}ctx $pct%$c_0"
  elif [ "$pct" -ge 70 ]; then sl_seg "${c_y}ctx $pct%$c_0"
  else sl_seg "ctx $pct%"; fi
fi

rl=""
if sl_num "$SL_R5"; then
  if [ "$SL_R" -ge 80 ]; then rl="${c_r}5h $SL_R%$c_0"; else rl="5h $SL_R%"; fi
fi
if sl_num "$SL_R7" && [ "$SL_R" -ge 50 ]; then rl="${rl:+$rl }7d $SL_R%"; fi
if [ -n "$rl" ]; then
  sl_seg "$rl"
elif sl_num "$SL_COST" 100; then
  printf -v cost '$%d.%02d' $((SL_R / 100)) $((SL_R % 100))
  sl_seg "$cost"
fi

base=${dir%/}; base=${base##*/}; [ -n "$base" ] || base=/
sl_clean "$base"; sl_seg "$SL_S"
sl_clean "$SL_EFF"; [ -n "$SL_S" ] && sl_seg "eff $SL_S"
sl_clean "$SL_PR"; [ -n "$SL_S" ] && sl_seg "PR #$SL_S"

printf '%s\n' "$line"
exit 0
