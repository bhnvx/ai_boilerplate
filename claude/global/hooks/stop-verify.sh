#!/usr/bin/env bash
# stop-verify.sh — Stop 훅: 검증하지 않고 완료를 보고하면 알린다(rules/core.md "검증한 것만 완료로 보고").
# 조건(모두 맞을 때만): 이번 턴(마지막 사용자 입력 뒤)에 Edit·Write·MultiEdit·NotebookEdit 로 코드 파일을 고쳤고,
#   마지막 수정 뒤에 검증 명령(테스트·린트·타입 검사·빌드)을 Bash 로 실행하지 않았고, 마지막 응답에 '미검증' 같은 표기도 없다.
# 동작: 기본은 사용자에게 경고만 한다(systemMessage — 턴은 그대로 끝난다). CLAUDE_STOP_VERIFY=remind 면 Claude 에게 되돌려
#   (additionalContext) 검증하거나 '미검증'으로 고쳐 쓰게 한다. 이미 Stop 훅 때문에 이어 가는 중(stop_hook_active)이면 통과한다.
# 끄기: CLAUDE_STOP_VERIFY=off. 검증 명령 추가: CLAUDE_STOP_VERIFY_EXTRA=<ERE>(소문자로 바꾼 명령에 대조).
# 판단 재료는 훅 입력의 last_assistant_message 와 세션 기록 끝 4 MB 의 도구 호출이다(lib/transcript.sh). 어림 판단이다:
#   문서(.md·.txt·.rst·.adoc)·작업 디렉터리 밖의 임시 디렉터리·.claude/ 아래 파일의 수정은 세지 않고, Bash 로 고친 파일(sed -i·리디렉션)은 보지 못하며,
#   검증 명령은 이름으로만 가린다(grep pytest 도 검증으로 센다). 결정은 하지 않는다 — 막지 않고 알리기만 한다.

SV_DIR=$(cd -P -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) || exit 0
. "$SV_DIR/lib/common.sh" 2>/dev/null || exit 0
. "$SV_DIR/lib/transcript.sh" 2>/dev/null || exit 0
hook_off CLAUDE_STOP_VERIFY && exit 0

hook_read_input
H_TP=""; H_ACTIVE=""; H_LAST=""; H_CWD=""
hook_fields H_TP=.transcript_path H_ACTIVE=.stop_hook_active H_LAST=.last_assistant_message H_CWD=.cwd || exit 0
[ "$H_ACTIVE" = true ] && exit 0
[ -n "$H_TP" ] || exit 0
hook_abspath_var "$H_TP" "$PWD"; sv_tp=$HOOK_ABS
sv_cwd=${H_CWD%/}

# 마지막 응답이 검증하지 않았음을 밝혔으면 알릴 것이 없다
sv_low=$(hook_lower "${H_LAST:0:20000}")
case $sv_low in
  *미검증*|*검증하지*|*테스트하지*|*미실행*|*'실행하지 않'*|*'실행하지 못'*) exit 0 ;;
  *'not verified'*|*unverified*|*untested*|*'not tested'*|*'did not run'*|*"didn't run"*|*'not run'*) exit 0 ;;
esac

# 이번 턴의 수정 파일 수(n) · 마지막 수정 뒤 검증 여부(v) · 파일 이름 예(최대 3개)
sv_res=$(hook_tx_events "$sv_tp" | SV_CWD=$sv_cwd LC_ALL=C awk -F '\t' -v extra="${CLAUDE_STOP_VERIFY_EXTRA:-}" '
  function isdoc(p) { return (tolower(p) ~ /\.(md|mdx|markdown|txt|rst|adoc)$/) }
  function isskip(p) { if (p ~ /\/\.claude\//) return 1
    if (cwd != "" && index(p, cwd "/") == 1) return 0            # 세션 작업 디렉터리 안이면 임시 경로여도 센다
    return (p ~ /^\/(private\/)?tmp\// || p ~ /^\/(private\/)?var\/(folders|tmp)\//) }
  function base(p,  a, k) { k = split(p, a, "/"); return a[k] }
  function isverify(c,  l) { l = tolower(c)
    if (l ~ RE1 || l ~ RE2 || l ~ RE3 || l ~ RE4 || l ~ RE5) return 1
    return (extra != "" && l ~ extra) }
  BEGIN {
    B1 = "(^|[^a-z0-9_.-])"; B2 = "([^a-z0-9_./-]|$)"
    # 도구 이름
    RE1 = B1 "(pytest|py\\.test|unittest|py_compile|compileall|tox|nox|ruff|mypy|pyright|flake8|pylint|vitest|jest|mocha|playwright|cypress|tsc|eslint|biome|rspec|phpunit|shellcheck|clippy|golangci-lint|ctest|run-all\\.sh|validate\\.sh)" B2
    # 러너 + 동사(npm run test:unit · make check · go vet · cargo build · manage.py test)
    RE2 = B1 "(npm|pnpm|yarn|bun|deno|make|gmake|just|task|rake|go|cargo|gradle|gradlew|mvn|mvnw|dotnet|composer|swift|mix|bazel|turbo|nx|rails|artisan|manage\\.py|terraform|tofu|helm)([ \t][^|;&]*)?[ \t:](test|tests|lint|check|typecheck|type-check|vet|build|verify|validate|spec|e2e)" B2
    # 인터프리터로 실행하는 검사 스크립트(bash scripts/check.sh · python tests/run.py)
    RE3 = B1 "(bash|sh|zsh|python[0-9.]*|node|deno|ruby|php|perl)[ \t]([^|;&]*[ \t/_.-])?(test|tests|check|checks|lint|verify|validate|spec|specs)([^a-z]|$)"
    # 문법 검사
    RE4 = B1 "((bash|sh|zsh)[ \t]+-n|node[ \t]+(--check|--test))" B2
    # 직접 실행하는 검사 스크립트(./scripts/test.sh)
    RE5 = "(^|[ \t;&|(])\\./([^ \t|;&]*[/_.-])?(test|tests|check|checks|lint|verify|validate|spec|specs)([^a-z]|$)"
    n = 0; v = 0; s = ""; cwd = ENVIRON["SV_CWD"]
  }
  $1 == "U" { n = 0; v = 0; s = ""; split("", S); next }
  $1 == "E" { p = $2; if (isdoc(p) || isskip(p)) next
              v = 0
              if (!(p in S)) { S[p] = 1; n++; if (n <= 3) s = s (s == "" ? "" : ", ") base(p) }
              next }
  $1 == "B" { if (n > 0 && isverify($2)) v = 1; next }
  END { printf "%d\t%d\t%s\n", n, v, s }')
sv_n=0; sv_v=1; sv_s=""
IFS=$'\t' read -r sv_n sv_v sv_s <<SVEOF
$sv_res
SVEOF
case $sv_n in ''|*[!0-9]*) exit 0 ;; esac
[ "$sv_n" -gt 0 ] && [ "$sv_v" = 0 ] || exit 0

[ "$sv_n" -gt 3 ] && sv_s="$sv_s 외 $((sv_n - 3))개"
sv_msg="검증 없이 완료 보고 [stop:unverified]: 이번 턴에 파일 ${sv_n}개를 수정했지만($sv_s) 마지막 수정 뒤에 테스트·린트·빌드 같은 검증 명령을 실행하지 않았고, 응답에 '미검증' 표기도 없다"
case ${CLAUDE_STOP_VERIFY:-} in
  [Rr][Ee][Mm][Ii][Nn][Dd])
    hook_log "$HOOK_NAME" remind stop:unverified "$sv_s"
    hook_emit_context Stop "$sv_msg — 검증 명령을 실행해 결과를 보고하거나, 실행하지 못한 검증을 '미검증'으로 보고에 적을 것" ;;
  *)
    hook_log "$HOOK_NAME" notify stop:unverified "$sv_s"
    hook_emit_system "$sv_msg" ;;
esac
exit 0
