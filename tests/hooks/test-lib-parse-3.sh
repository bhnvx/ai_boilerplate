#!/usr/bin/env bash
# tests/hooks/test-lib-parse-3.sh — lib/shellparse.sh 옵트인 기능(sp_tokens_lines keep-empty, sp_varrefs). 기본 출력은 그대로인지도 본다.
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
. "$T_HOOKS/lib/shellparse.sh"
t_setup

tl() { if [ $# -gt 1 ]; then sp_tokens_lines "$1" "$2"; else sp_tokens_lines "$1"; fi | tr '\n' '|'; }
vr() { sp_varrefs "$1" | tr '\t\n' '/|'; }   # NAME/OP/CTX| (OP: $ = $NAME, CTX: e 펼쳐짐 · s 글자 그대로)

t_section "sp_tokens_lines keep-empty (guard-secrets only)"
assert_eq 'default drops empty quoted args' 'grep|.env|__SP_SEG__|' "$(tl "grep '' .env")"
assert_eq 'keep-empty keeps them' 'grep|__SP_EMPTY__|.env|__SP_SEG__|' "$(tl "grep '' .env" keep-empty)"
assert_eq 'keep-empty: "" and $'"''"' too' 'sed|__SP_EMPTY__|-e|__SP_EMPTY__|f|__SP_SEG__|' "$(tl "sed \"\" -e \$'' f" keep-empty)"
assert_eq 'keep-empty: empty KEY= value' 'tar|--exclude=|__SP_EMPTY__|.env|__SP_SEG__|' "$(tl 'tar --exclude= .env' keep-empty)"
assert_eq 'keep-empty: KEY=value unchanged' 'tar|--exclude=|.env|__SP_SEG__|' "$(tl 'tar --exclude=.env' keep-empty)"
assert_eq 'default: empty KEY= value' 'tar|--exclude=|.env|__SP_SEG__|' "$(tl 'tar --exclude= .env')"
assert_eq 'keep-empty: per line' 'a|__SP_EMPTY__|__SP_SEG__|b|__SP_SEG__|' "$(tl $'a ""\nb' keep-empty)"
assert_eq 'unknown option value behaves as default' 'grep|.env|__SP_SEG__|' "$(tl "grep '' .env" other)"
assert_eq 'sp_tokens unchanged' 'grep|.env|' "$(sp_tokens "grep '' .env" | tr '\n' '|')"

t_section "sp_varrefs: name / operator / quote context"
assert_eq 'plain, double-quoted, single-quoted' 'A/$/e|B/$/e|C/$/s|' "$(vr "echo \$A \"\$B\" '\$C'")"
assert_eq 'braced forms' 'D/}/e|E/len/e|F/:+/e|G/+/e|H/:-/e|I/-/e|J/:0/e|K/#/e|L/%/e|M///e|' \
  "$(vr 'echo ${D} ${#E} ${F:+x} ${G+x} ${H:-x} ${I-x} ${J:0:4} ${K#p} ${L%s} ${M/a/b}')"
assert_eq 'nested reference in the word part' 'N/:+/e|N/$/e|O/:-/e|P/$/e|' "$(vr 'echo "${N:+$N}" ${O:-$P}')"
assert_eq 'single quotes inside ${…:+…} unquoted' 'Q/:+/e|Q/$/s|' "$(vr "echo \${Q:+'\$Q'}")"
assert_eq 'escaped dollar and ANSI-C' 'T/$/s|' "$(vr "echo \\\$R \"\\\$S\" \$'\$T'")"
assert_eq "apostrophe inside double quotes is literal" 'U/$/e|' "$(vr "echo \"it's \$U\"")"
assert_eq 'specials and substitutions ignored' '' "$(vr 'echo $1 $? $$ $@ $(cmd) $((1+2))')"
assert_eq 'unterminated single quote' 'V/$/s|' "$(vr "echo 'a \$V")"
t_report
