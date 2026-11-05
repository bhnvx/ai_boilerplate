#!/usr/bin/env bash
# format-on-edit.sh — PostToolUse(Edit|Write|MultiEdit) 훅. 프로젝트 opt-in(apply.sh --with-format-hook), 전역 설정에는 없음.
# 프로젝트가 설정한(증거가 있는) 로컬 포매터만 실행하고, 결과를 additionalContext 로 알린다. 항상 exit 0.
# 끄기: CLAUDE_FORMAT_ON_EDIT=off. ECC quality-gate 는 기본적으로 검사만 하므로 겹치지 않는다;
#   ECC_QUALITY_GATE_FIX=true 일 때만 ECC 가 고치는 타입(.py .go .ts .tsx .js .jsx .json .md)을 건너뛴다(=force 로 무시).
# black: [tool.black] 에 exclude/extend-exclude 만 있고 force-exclude 가 없으면 건너뛴다(black 은 명시 경로에 force-exclude 만 적용).
# 시간 제한: CLAUDE_FORMAT_TIMEOUT(초, 기본 20) — GNU timeout 대신 백그라운드 watchdog.
# 의존: lib/common.sh 만(apply.sh 가 run-hook.sh·format-on-edit.sh·lib/common.sh 만 복사한다).

FMT_DIR=$(cd -P -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) || exit 0
. "$FMT_DIR/lib/common.sh" 2>/dev/null || exit 0
hook_off CLAUDE_FORMAT_ON_EDIT && exit 0
hook_read_input
hook_load_pretooluse || exit 0
case $H_TOOL in Edit|Write|MultiEdit) ;; *) exit 0 ;; esac
[ -n "$H_PATH" ] || exit 0

# --- 대상 파일 검사 ---------------------------------------------------------------
# root = CLAUDE_PROJECT_DIR, 파일이 그 밖이면 H_CWD(워크트리에서는 cwd 만 따라간다). 둘 다 밖이면 종료.
# 항상 물리 경로로 비교한다: `..` 이나 root 밖을 가리키는 디렉터리 심볼릭 링크를 거친 파일은 밖으로 본다.
f=$(hook_abspath "$H_PATH" "${H_CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}")
base=${f##*/}
case $base in ''|.|..) exit 0 ;; esac
pdir=$(cd -P -- "${f%/*}/" 2>/dev/null && pwd -P) || exit 0
pdir=${pdir%/}
f="$pdir/$base"
root=""; prev=""
for cand in "${CLAUDE_PROJECT_DIR:-}" "${H_CWD:-}"; do
  [ -n "$cand" ] && [ -d "$cand" ] && [ "$cand" != "$prev" ] || continue
  prev=$cand
  proot=$(cd -P -- "$cand" 2>/dev/null && pwd -P) || continue
  proot=${proot%/}
  [ -n "$proot" ] || continue
  case "$pdir/" in "$proot"/*) root=$proot; break ;; esac
done
[ -n "$root" ] || exit 0
rel=${f#"$root"/}
fdir=$pdir
case "/$rel" in
  */node_modules/*|*/.venv/*|*/venv/*|*/dist/*|*/build/*|*/.git/*|*/migrations/*|*/vendor/*|*/.next/*|\
  */__pycache__/*|*/.tox/*|*/target/*) exit 0 ;;
esac
case $base in
  *.min.*|package-lock.json|pnpm-lock.yaml|yarn.lock|bun.lockb|uv.lock|poetry.lock|Cargo.lock|Gemfile.lock|composer.lock) exit 0 ;;
esac
[ -f "$f" ] && [ ! -L "$f" ] || exit 0
size=$(wc -c <"$f" 2>/dev/null); size=${size//[!0-9]/}
[ -n "$size" ] && [ "$size" -le 2097152 ] || exit 0

# --- ECC quality-gate 겹침 방지(settings 확인 결과는 60초 캐시) ------------------------------
# ECC quality-gate 가 파일을 고치는 경우(= 우리가 건너뛸 경우)는 모두 만족할 때뿐이다:
#   ECC_QUALITY_GATE_FIX=true(대소문자 무관) · ECC_HOOK_PROFILE≠minimal · ECC_DISABLED_HOOKS 에 post:quality-gate 없음
#   · ~/.claude/settings.json 의 enabledPlugins["ecc@ecc"] 가 true. 환경 변수 검사를 먼저 해서 보통은 fork 가 없다.
fmt_trim() { FMT_T=${1#"${1%%[![:space:]]*}"}; FMT_T=${FMT_T%"${FMT_T##*[![:space:]]}"}; }
fmt_ecc_active() {
  local s="$HOME/.claude/settings.json" c t a p now v tmp e o=$IFS
  case ${ECC_QUALITY_GATE_FIX:-} in [Tt][Rr][Uu][Ee]) ;; *) return 1 ;; esac
  fmt_trim "${ECC_HOOK_PROFILE:-}"
  case $FMT_T in [Mm][Ii][Nn][Ii][Mm][Aa][Ll]) return 1 ;; esac
  set -f; IFS=,
  for e in ${ECC_DISABLED_HOOKS:-}; do
    fmt_trim "$e"
    case $FMT_T in [Pp][Oo][Ss][Tt]:[Qq][Uu][Aa][Ll][Ii][Tt][Yy]-[Gg][Aa][Tt][Ee]) IFS=$o; set +f; return 1 ;; esac
  done
  IFS=$o; set +f
  [ -f "$s" ] || return 1
  c=${TMPDIR:-/tmp}; c="${c%/}/claude-format-ecc.${UID:-0}"
  now=$(date +%s)
  # 캐시가 settings.json 보다 엄밀히 새로울 때만 사용(mtime 이 같은 초면 다시 확인)
  if [ -f "$c" ] && [ ! -L "$c" ] && [ "$c" -nt "$s" ]; then
    { IFS= read -r t; IFS= read -r a; IFS= read -r p; } <"$c"
    case $t in
      ''|*[!0-9]*) ;;
      *) if [ "$p" = "$s" ] && [ $((now - t)) -ge 0 ] && [ $((now - t)) -lt 60 ]; then [ "$a" = 1 ]; return; fi ;;
    esac
  fi
  if [ "$HOOK_JSON_TOOL" = jq ]; then
    v=$(jq -r '(.enabledPlugins["ecc@ecc"] // false) | tostring' "$s" 2>/dev/null)
  else
    v=$(python3 -I -S -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
    p=d.get("enabledPlugins") if isinstance(d,dict) else None
    print("true" if isinstance(p,dict) and p.get("ecc@ecc") is True else "false")
except Exception:
    print("false")' "$s" 2>/dev/null)
  fi
  a=0; [ "$v" = true ] && a=1
  if tmp=$(mktemp "$c.XXXXXX" 2>/dev/null); then
    { printf '%s\n%s\n%s\n' "$now" "$a" "$s" >"$tmp" && mv -f "$tmp" "$c"; } 2>/dev/null || rm -f "$tmp"
  fi
  [ "$a" = 1 ]
}
case ${CLAUDE_FORMAT_ON_EDIT:-} in
  [Ff][Oo][Rr][Cc][Ee]) ;;
  *) case $base in *.py|*.go|*.ts|*.tsx|*.js|*.jsx|*.json|*.md) fmt_ecc_active && exit 0 ;; esac ;;
esac

# --- 보조 함수 ------------------------------------------------------------------
# fmt_up <glob>... → 파일 디렉터리에서 root 까지 올라가며 가장 가까운 일치. FMT_UP=디렉터리, FMT_HIT=경로
fmt_up() {
  local d=$fdir n p
  FMT_UP=""; FMT_HIT=""
  while :; do
    for n in "$@"; do
      for p in "$d"/$n; do
        if [ -e "$p" ]; then FMT_UP=$d; FMT_HIT=$p; return 0; fi
      done
    done
    [ "$d" = "$root" ] && return 1
    case $d in "$root"/*) d=${d%/*} ;; *) return 1 ;; esac
  done
}
# fmt_bin <name> <local-dir> → FMT_BIN: 가장 가까운 <local-dir>/<name>(실행 가능), local-dir 이 .venv/bin 이면 PATH 도 허용
fmt_bin() {
  FMT_BIN=""
  if fmt_up "$2/$1" && [ -x "$FMT_HIT" ]; then FMT_BIN=$FMT_HIT; return 0; fi
  [ "$2" = ".venv/bin" ] || return 1
  FMT_BIN=$(command -v "$1" 2>/dev/null)
  [ -n "$FMT_BIN" ]
}
fmt_have() { command -v "$1" >/dev/null 2>&1; }

FMT_TIMEOUT=${CLAUDE_FORMAT_TIMEOUT:-20}
case $FMT_TIMEOUT in ''|*[!0-9]*|0) FMT_TIMEOUT=20 ;; esac
FMT_TMP=""
fmt_cwd=$root
FMT_MSGS=""; FMT_TOOLS=""; FMT_LINT=""
fmt_msg() { FMT_MSGS="${FMT_MSGS:+$FMT_MSGS
}$1"; }

# fmt_exec <cmd> [args...] — watchdog 로 시간 제한. FMT_RC, FMT_TO(1=시간 초과), $FMT_TMP/out, $FMT_TMP/err
fmt_exec() {
  local p w
  if [ -z "$FMT_TMP" ]; then
    FMT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/claude-fmt.XXXXXX") || { FMT_RC=1; FMT_TO=0; return 1; }
    trap 'rm -rf "$FMT_TMP"' EXIT
  fi
  rm -f "$FMT_TMP/timeout"
  ( cd "$fmt_cwd" 2>/dev/null; exec "$@" ) </dev/null >"$FMT_TMP/out" 2>"$FMT_TMP/err" &
  p=$!
  (
    trap 'kill "$s" 2>/dev/null; exit 0' TERM
    sleep "$FMT_TIMEOUT" &
    s=$!
    wait "$s"
    : >"$FMT_TMP/timeout"
    kill "$p" 2>/dev/null
    # TERM 을 무시하는 포매터: 2초 더 기다린 뒤 KILL
    sleep 2 &
    s=$!
    wait "$s"
    kill -KILL "$p" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
  w=$!
  wait "$p" 2>/dev/null; FMT_RC=$?   # 2>/dev/null: 종료된 작업의 "Terminated" 알림 숨김
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  FMT_TO=0; [ -e "$FMT_TMP/timeout" ] && FMT_TO=1
  return 0
}
# fmt_head <file> <n> [<strip-prefix>] → 앞 n 줄(빈 줄 제외, 절대 경로는 상대 경로로)
fmt_head() {
  local out="" line k=0
  while { IFS= read -r line || [ -n "$line" ]; } && [ $k -lt "$2" ]; do
    [ -n "$line" ] || continue
    line=${line//"$f"/"$rel"}
    out="${out:+$out
}$line"; k=$((k + 1))
  done <"$1"
  printf '%s' "$out"
}
# fmt_sh_shebang → 0 이면 bash -n 대상: 셔뱅이 없거나 bash/sh 계열(env 경유 포함). zsh·fish·ksh 등은 건너뛴다.
fmt_sh_shebang() {
  local l="" w i=""
  { IFS= read -r l || :; } <"$f" 2>/dev/null
  l=${l%$'\r'}
  case $l in '#!'*) ;; *) return 0 ;; esac
  set -f
  for w in ${l#??}; do
    case $w in -*|*=*) [ "$i" = env ] && continue ;; esac
    i=${w##*/}
    [ "$i" = env ] || break
  done
  set +f
  case $i in ''|bash|sh|dash|ash) return 0 ;; esac
  return 1
}
# fmt_run <tool-label> <cmd> [args...] — 실행 후 실패/시간 초과를 메시지로 기록. 성공이면 0
fmt_run() {
  local label=$1; shift
  fmt_exec "$@" || return 1
  if [ "$FMT_TO" = 1 ]; then fmt_msg "포매터 실패($label): 시간 초과(${FMT_TIMEOUT}초) — 중단함"; return 1; fi
  if [ "$FMT_RC" -ne 0 ]; then
    local e; e=$(fmt_head "$FMT_TMP/err" 5)
    [ -n "$e" ] || e=$(fmt_head "$FMT_TMP/out" 5)
    fmt_msg "포매터 실패($label): ${e:-종료 코드 $FMT_RC}"
    return 1
  fi
  FMT_TOOLS="${FMT_TOOLS:+$FMT_TOOLS+}$label"
  return 0
}

# --- 포매터 선택·실행 --------------------------------------------------------------
sum_before=$(cksum <"$f" 2>/dev/null)
case $base in
  *.py|*.pyi)
    pyp=""; sect=""; ruffcfg=0; blackcfg=0; isortcfg=0; bexcl=0; bfexcl=0; cur=""
    if fmt_up pyproject.toml; then pyp=$FMT_HIT; fmt_cwd=$FMT_UP; fi
    # grep 1회: 섹션 머리글 + exclude 계열 키(어느 섹션의 키인지는 순서로 판단)
    [ -n "$pyp" ] && sect=$(LC_ALL=C grep -Eo '^[[:space:]]*(\[[^]]*|(extend-exclude|force-exclude|exclude)[[:space:]]*=)' "$pyp" 2>/dev/null)
    while IFS= read -r l; do
      fmt_trim "$l"
      case $FMT_T in
        '[tool.ruff') cur=ruff; ruffcfg=1 ;;
        '[tool.ruff.'*) cur=ruff; ruffcfg=1 ;;
        '[tool.black') cur=black; blackcfg=1 ;;
        '[tool.isort') cur=isort; isortcfg=1 ;;
        '['*) cur="" ;;
        force-exclude*) [ "$cur" = black ] && bfexcl=1 ;;
        exclude*|extend-exclude*) [ "$cur" = black ] && bexcl=1 ;;
      esac
    done <<SECT_EOF
$sect
SECT_EOF
    [ "$ruffcfg" = 1 ] || { fmt_up ruff.toml .ruff.toml && ruffcfg=1; }
    if [ "$ruffcfg" = 1 ]; then
      if fmt_bin ruff .venv/bin; then
        ruff=$FMT_BIN
        # --force-exclude: 명시한 파일에도 프로젝트의 exclude/extend-exclude 를 적용(제외 파일이면 아무것도 안 함, rc 0)
        fmt_run ruff "$ruff" format --force-exclude "$f"
        if [ "$FMT_TO" != 1 ]; then
          fmt_exec "$ruff" check --force-exclude "$f" --output-format concise
          cr=${f#"$fmt_cwd"/}   # ruff 는 경로를 자기 cwd(가장 가까운 pyproject 디렉터리) 기준으로 출력
          if [ "$FMT_TO" = 1 ]; then fmt_msg "포매터 실패(ruff check): 시간 초과(${FMT_TIMEOUT}초) — 중단함"
          elif [ "$FMT_RC" -eq 1 ]; then
            lre=':[0-9]+:[0-9]+: '; n=0; lines=""
            while IFS= read -r line; do
              [[ $line =~ $lre ]] || continue
              n=$((n + 1))
              line=${line//"$f"/"$rel"}   # 대입 문맥에서만 따옴표 사용(bash 3.2/5.2 공통, & 치환 방지)
              case $line in "$cr":*) line="$rel${line#"$cr"}" ;; esac
              [ $n -le 20 ] && lines="${lines:+$lines
}$line"
            done <"$FMT_TMP/out"
            [ $n -gt 0 ] && FMT_LINT="ruff: $rel 린트 이슈 ${n}개:
$lines"
          elif [ "$FMT_RC" -ne 0 ]; then
            e=$(fmt_head "$FMT_TMP/err" 5); fmt_msg "포매터 실패(ruff check): ${e:-종료 코드 $FMT_RC}"
          fi
        fi
      fi
    else
      # isort --filter-files: 명시한 파일에도 skip/extend_skip 설정 적용
      if [ "$blackcfg" = 1 ]; then
        if [ "$bexcl" = 0 ] || [ "$bfexcl" = 1 ]; then
          fmt_bin black .venv/bin && fmt_run black "$FMT_BIN" -q "$f"
        fi
        [ "$isortcfg" = 1 ] && fmt_bin isort .venv/bin && fmt_run isort "$FMT_BIN" -q --filter-files --profile black "$f"
      elif [ "$isortcfg" = 1 ]; then
        fmt_bin isort .venv/bin && fmt_run isort "$FMT_BIN" -q --filter-files "$f"
      fi
    fi ;;
  *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.json|*.jsonc|*.css|*.scss|*.md|*.mdx|*.yml|*.yaml|*.vue|*.svelte|*.graphql|*.html)
    fmt_up package.json && fmt_cwd=$FMT_UP
    pcfg=0
    if fmt_up '.prettierrc*' 'prettier.config.*'; then pcfg=1
    elif fmt_up package.json; then
      if [ "$HOOK_JSON_TOOL" = jq ]; then
        [ "$(jq -r 'has("prettier")' "$FMT_HIT" 2>/dev/null)" = true ] && pcfg=1
      else
        [ "$(python3 -I -S -c 'import json,sys
try: print("prettier" in json.load(open(sys.argv[1])))
except Exception: print(False)' "$FMT_HIT" 2>/dev/null)" = True ] && pcfg=1
      fi
    fi
    if [ "$pcfg" = 1 ] && fmt_bin prettier node_modules/.bin; then
      case $base in *.html) [ -e "$root/manage.py" ] && FMT_BIN="" ;; esac
      [ -n "$FMT_BIN" ] && fmt_run prettier "$FMT_BIN" --write --log-level warn "$f"
    elif fmt_up biome.json biome.jsonc && fmt_bin biome node_modules/.bin; then
      case $base in
        *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.json|*.jsonc|*.css)
          fmt_run biome "$FMT_BIN" format --write --no-errors-on-unmatched "$f" ;;
      esac
    fi ;;
  *.go) fmt_have gofmt && fmt_run gofmt gofmt -w "$f" ;;
  *.rs) fmt_up Cargo.toml && fmt_have rustfmt && { fmt_cwd=$FMT_UP; fmt_run rustfmt rustfmt --edition 2021 "$f"; } ;;
  *.sh|*.bash)
    fmt_sh_shebang || exit 0
    fmt_exec "${BASH:-bash}" -n "$f"
    if [ "$FMT_TO" != 1 ] && [ "$FMT_RC" -ne 0 ]; then
      e=$(fmt_head "$FMT_TMP/err" 10)
      fmt_msg "bash -n: $rel 문법 오류:
${e:-종료 코드 $FMT_RC}"
    elif [ "$FMT_TO" != 1 ] && fmt_have shfmt && fmt_up .editorconfig &&
         LC_ALL=C grep -Eq '^\[\*\.sh\]|^\[[^]]*\{[^}]*sh[,}]|shfmt' "$FMT_HIT" 2>/dev/null; then
      fmt_run shfmt shfmt -w -i 2 -ci "$f"
    fi ;;
  *.tf) fmt_have terraform && fmt_run terraform terraform fmt "$f" ;;
  *.toml) fmt_up taplo.toml .taplo.toml && fmt_have taplo && fmt_run taplo taplo fmt "$f" ;;
esac

# --- 결과 보고 -------------------------------------------------------------------
sum_after=$(cksum <"$f" 2>/dev/null)
out=""
if [ -n "$sum_before" ] && [ "$sum_before" != "$sum_after" ]; then
  out="포매터(${FMT_TOOLS:-?})가 ${rel}를 수정했다 — 다음 편집 전에 파일을 다시 읽을 것."
fi
[ -n "$FMT_LINT" ] && out="${out:+$out
}$FMT_LINT"
[ -n "$FMT_MSGS" ] && out="${out:+$out
}$FMT_MSGS"
[ -n "$out" ] && hook_emit_context PostToolUse "$out"
exit 0
