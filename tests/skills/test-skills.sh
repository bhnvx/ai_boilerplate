#!/usr/bin/env bash
# tests/skills/test-skills.sh — 스킬 context.sh(항상 exit 0, 공백·특수문자 경로, git 안/밖),
# allowed-tools ↔ 주입 명령 일치, validate.sh 스킬 검사, 프로필 fragment·전역 matcher 회귀 테스트.
# 실행: /bin/bash tests/skills/test-skills.sh   (bash 3.2 호환, 실제 ~/.claude는 건드리지 않음)
. "$(cd -P -- "$(dirname -- "$0")/../lib" && pwd -P)/testlib.sh"
t_setup
# 아래는 $T_HOME/.claude 에 쓰고 지운다. context.sh 가 같은 곳을 읽도록 HOME 이 픽스처 홈인지 먼저 확인한다(실제 ~/.claude 보호).
[ -n "$T_HOME" ] && [ "$HOME" = "$T_HOME" ] || { echo "HOME 이 테스트 홈($T_HOME)이 아니다 — 중단" >&2; exit 1; }
unset CLAUDE_GUARD_PROTECTED_BRANCHES ECC_QUALITY_GATE_FIX ECC_HOOK_PROFILE ECC_DISABLED_HOOKS
SK="$T_REPO_ROOT/claude/global/skills"
NOGIT="$T_TMP/no git dir"; mkdir -p "$NOGIT"

# run_ctx <script> [args...] — 공백 있는 비-git cwd에서 실행 → T_RC T_OUT T_ERR
run_ctx() {
  T_OUT=$(cd "$NOGIT" && "$BASH" "$@" 2>"$T_TMP/ctx.err" </dev/null); T_RC=$?
  T_ERR=$(cat "$T_TMP/ctx.err" 2>/dev/null)
}

t_section "모든 context.sh: git 안/밖, 빈 인수, 없는 경로 → exit 0"
for s in commit review-diff harness-init preflight; do
  for a in "$T_PROJ" "$T_WT" "$NOGIT" "" "$T_TMP/없는 경로"; do
    run_ctx "$SK/$s/context.sh" "$a" "garbage \"; rm -rf x"
    assert_rc "$s context.sh [$a]" 0
    assert_contains "$s 프로젝트 줄 [$a]" "$T_OUT" "프로젝트: "
  done
done

t_section "commit/context.sh: 보호 브랜치(D11)"
run_ctx "$SK/commit/context.sh" "$T_PROJ"
assert_contains "commit: 미설정 → 기본값" "$T_OUT" "보호 브랜치: main master (기본값"
assert_contains "commit: main 경고" "$T_OUT" "현재 브랜치: main — 보호 브랜치: 커밋 전에 멈추고"
CLAUDE_GUARD_PROTECTED_BRANCHES='' run_ctx "$SK/commit/context.sh" "$T_PROJ"
assert_contains "commit: 빈 값 → 비활성" "$T_OUT" "보호 브랜치: none"
assert_contains "commit: 빈 값 → 경고 없음" "$T_OUT" "현재 브랜치: main
"
CLAUDE_GUARD_PROTECTED_BRANCHES='NONE' run_ctx "$SK/commit/context.sh" "$T_PROJ"
assert_contains "commit: NONE(대소문자) → 비활성" "$T_OUT" "보호 브랜치: none"
assert_not_contains "commit: NONE → 경고 없음" "$T_OUT" "커밋 전에 멈추고"
mkdir -p "$NOGIT/release" && : >"$NOGIT/release/a"
CLAUDE_GUARD_PROTECTED_BRANCHES='develop, release/*' run_ctx "$SK/commit/context.sh" "$T_WT"
assert_contains "commit: glob 목록은 확장하지 않음" "$T_OUT" "보호 브랜치: develop release/* (CLAUDE_GUARD_PROTECTED_BRANCHES)"
assert_contains "commit: feature/x는 보호 아님" "$T_OUT" "현재 브랜치: feature/x — 보호 브랜치 아님"
( cd "$T_WT" && t_git checkout -q -b release/1.0 ) >/dev/null 2>&1
CLAUDE_GUARD_PROTECTED_BRANCHES='develop,release/*' run_ctx "$SK/commit/context.sh" "$T_WT"
assert_contains "commit: release/* glob 일치 → 경고" "$T_OUT" "현재 브랜치: release/1.0 — 보호 브랜치: 커밋 전에"
( cd "$T_WT" && t_git checkout -q feature/x ) >/dev/null 2>&1
run_ctx "$SK/commit/context.sh" "$NOGIT"
assert_contains "commit: 비-git" "$T_OUT" "현재 브랜치: (git 저장소 아님)"
( cd "$T_WT" && t_git checkout -q --detach ) >/dev/null 2>&1
run_ctx "$SK/commit/context.sh" "$T_WT"
assert_contains "commit: detached" "$T_OUT" "(detached HEAD)"
run_ctx "$SK/review-diff/context.sh" "$T_WT"
assert_contains "review-diff: detached" "$T_OUT" "브랜치: (detached HEAD)"
( cd "$T_WT" && t_git checkout -q feature/x ) >/dev/null 2>&1
run_ctx "$SK/review-diff/context.sh" "$T_WT"
assert_contains "review-diff: symbolic-ref 브랜치" "$T_OUT" "브랜치: feature/x · upstream:"
run_ctx "$SK/review-diff/context.sh" "$NOGIT"
assert_contains "review-diff: 비-git" "$T_OUT" "(git 저장소 아님"

t_section "harness-init/context.sh: 미설치·특수문자 경로(C13)·브랜치(C12)·ECC(D1)"
run_ctx "$SK/harness-init/context.sh" "$T_PROJ"
assert_contains "init: 저장소 미설치" "$T_OUT" "(미설치: install.sh 실행 필요)"
assert_contains "init: symbolic-ref 브랜치" "$T_OUT" "- git: 저장소 (브랜치 main,"
REPO_X="$T_TMP/re'po \"x\" \$Z \`id\`"; PROJ_X="$T_TMP/pr'o\"j \$Y & 한"
mkdir -p "$REPO_X" "$PROJ_X" && : >"$REPO_X/apply.sh"
printf '%s\n' "$REPO_X" >"$T_HOME/.claude/dev_settings.repo"
run_ctx "$SK/harness-init/context.sh" "$PROJ_X"
assert_rc "init: 특수문자 경로 rc" 0
line=$(printf '%s\n' "$T_OUT" | sed -n 's/^미리보기 명령: //p')
assert_contains "init: 미리보기 명령 출력" "$line" "--dry-run"
set -f; eval "set -- $line" 2>/dev/null; set +f
assert_eq "init: 미리보기 argv[0]" "bash" "${1:-}"
assert_eq "init: 미리보기 apply.sh 경로 왕복" "$REPO_X/apply.sh" "${2:-}"
assert_eq "init: 미리보기 프로젝트 경로 왕복" "$PROJ_X" "${3:-}"
assert_eq "init: 감지 없음 → 미리보기에 --profile 없음(D01)" "--dry-run" "${4:-}${5:+ $5}"
# 스택이 감지되면 미리보기는 --profile auto 를 명시한다(apply.sh 는 --profile 을 생략하면 프로필을 적용하지 않는다)
mkdir -p "$T_HOME/.claude/hooks/lib" && cp "$T_HOOKS/lib/detect-stack.sh" "$T_HOME/.claude/hooks/lib/"
: >"$PROJ_X/pyproject.toml"
run_ctx "$SK/harness-init/context.sh" "$PROJ_X"
assert_contains "init: auto 프로필 추정" "$T_OUT" "auto 프로필(추정): python"
line=$(printf '%s\n' "$T_OUT" | sed -n 's/^미리보기 명령: //p')
set -f; eval "set -- $line" 2>/dev/null; set +f
assert_eq "init: 감지됨 → 미리보기 --profile auto --dry-run(D01)" "--profile auto --dry-run" "${4:-} ${5:-} ${6:-}"
rm -f "$PROJ_X/pyproject.toml"; rm -rf "$T_HOME/.claude/hooks"
run_ctx "$SK/harness-init/context.sh" "$T_WT"
assert_contains "init: 워크트리 브랜치" "$T_OUT" "(브랜치 feature/x,"
run_ctx "$SK/harness-init/context.sh" "$NOGIT"
assert_contains "init: 비-git" "$T_OUT" "- git: 저장소 아님"
assert_contains "init: ECC 없음" "$T_OUT" "ECC 플러그인: 비활성 또는 확인 불가"
printf '{"enabledPlugins": {"ecc@ecc": true}}\n' >"$T_HOME/.claude/settings.json"
run_ctx "$SK/harness-init/context.sh" "$T_PROJ"
assert_contains "init: ECC 기본 → 검사만" "$T_OUT" "quality-gate는 기본적으로 검사만 하므로"
assert_not_contains "init: 옛 주장 제거" "$T_OUT" "불필요"
ECC_QUALITY_GATE_FIX=TRUE run_ctx "$SK/harness-init/context.sh" "$T_PROJ"
assert_contains "init: ECC FIX=TRUE → 해당 타입 건너뜀" "$T_OUT" "ECC_QUALITY_GATE_FIX=true — 포맷 훅은 ECC가 고치는 타입"
# 건너뛰는 타입 목록은 format-on-edit.sh 의 실제 목록과 같아야 하고, 그 밖의 타입은 그대로 포맷한다고 말해야 한다(D10)
ecc_types=$(sed -n 's/.*case \$base in \([^)]*\)) fmt_ecc_active.*/\1/p' "$T_HOOKS/format-on-edit.sh" | sed 's/\*//g; s/|/ /g')
assert_eq "init: format-on-edit.sh 에서 ECC 타입 목록 추출" ".py .go .ts .tsx .js .jsx .json .md" "$ecc_types"
assert_contains "init: ECC 타입 목록 = format-on-edit.sh" "$T_OUT" "ECC가 고치는 타입($ecc_types)만 건너뛰고"
assert_contains "init: 그 밖의 타입은 그대로 포맷" "$T_OUT" "그 밖의 타입"
assert_not_contains "init: '나머지는 bash -n 등만' 옛 주장 제거" "$T_OUT" "나머지(bash -n"
ECC_QUALITY_GATE_FIX=true ECC_HOOK_PROFILE=Minimal run_ctx "$SK/harness-init/context.sh" "$T_PROJ"
assert_contains "init: minimal 프로필 → 검사만" "$T_OUT" "검사만 하므로"
ECC_QUALITY_GATE_FIX=true ECC_DISABLED_HOOKS='pre:x,POST:Quality-Gate' run_ctx "$SK/harness-init/context.sh" "$T_PROJ"
assert_contains "init: quality-gate 꺼짐 → 검사만" "$T_OUT" "검사만 하므로"
rm -f "$T_HOME/.claude/settings.json" "$T_HOME/.claude/dev_settings.repo"

t_section "harness-init/SKILL.md: apply.sh 동작과 일치(D01·D16·D17)"
HI=$(cat "$SK/harness-init/SKILL.md")
assert_not_contains "SKILL.md: '프로필 없이(--profile auto)' 표현 없음" "$HI" '프로필 없이(`--profile auto`)'
assert_contains "SKILL.md: .claude/CLAUDE.md 만 있으면 후보는 그 옆" "$HI" '`.claude/CLAUDE.md.dev_settings.new`'
# 커밋할 파일 목록은 apply.sh 가 출력하는 목록(apply.sh 의 `for f in ...; do [ -f "$TARGET/$f" ] && info` 줄)을 모두 담는다
commit_files=$(sed -n 's/^for f in \(.*\); do \[ -f "\$TARGET\/\$f" ] && info .*/\1/p' "$T_REPO_ROOT/apply.sh")
assert_contains "apply.sh 커밋할 파일 목록 추출" "$commit_files" ".gitignore"
commit_line=$(printf '%s\n' "$HI" | grep -F -- '- 커밋할 파일:')
for f in $commit_files; do assert_contains "SKILL.md 커밋할 파일: $f" "$commit_line" "\`$f\`"; done

t_section "preflight/context.sh: .env*.example 분류·키 동기화(D14), 베이스 선택(C12)"
PF="$T_TMP/pf proj"; mkdir -p "$PF/src"
( cd "$PF" && t_git init -q . && t_git symbolic-ref HEAD refs/heads/main &&
  printf 'a\n' >a.txt && t_git add a.txt && t_git commit -q -m one &&
  printf 'b\n' >>a.txt && t_git commit -q -am two ) >/dev/null 2>&1
printf 'FOO=1\n' >"$PF/.env.example"
printf 'API_URL=\n' >"$PF/.env.production.example"
printf 'export BAR=\n' >"$PF/.env.local.example"
printf 'const u = process.env.API_URL;\nconst b = process.env.BAR;\n' >"$PF/src/a.ts"
run_ctx "$SK/preflight/context.sh" "$PF" ""
assert_rc "preflight: rc" 0
assert_contains "preflight: 베이스는 현재 브랜치가 아님" "$T_OUT" "베이스: HEAD~1 (직전 커밋)"
assert_contains "preflight: 브랜치(symbolic-ref)" "$T_OUT" "브랜치: main ·"
assert_not_contains "preflight: .env.*.example은 비밀 아님" "$T_OUT" "비밀 파일 의심"
assert_not_contains "preflight: [중단] 없음" "$T_OUT" "[중단]"
assert_contains "preflight: 예시 파일 3개 분류" "$T_OUT" "환경·설정 예시 파일 (3)"
assert_not_contains "preflight: 다른 예시 파일의 키도 읽음" "$T_OUT" "없는 키:"
assert_contains "preflight: 동기화됨" "$T_OUT" "와 동기화됨"
printf 'SECRET=x\n' >"$PF/.env.local"
run_ctx "$SK/preflight/context.sh" "$PF" "main"
assert_contains "preflight: 실제 .env.local은 비밀" "$T_OUT" "[중단] 비밀 파일 의심 경로"
printf 'const z = process.env.ZED_KEY;\n' >>"$PF/src/a.ts"
run_ctx "$SK/preflight/context.sh" "$PF" ""
assert_contains "preflight: 없는 키 보고" "$T_OUT" "없는 키: ZED_KEY"
run_ctx "$SK/preflight/context.sh" "$NOGIT" ""
assert_contains "preflight: 비-git" "$T_OUT" "(git 저장소 아님"

t_section "SKILL.md: 주입 명령 앞 토큰 = allowed-tools 접두(D7)"
if command -v python3 >/dev/null 2>&1; then
  # bash 3.2는 $( ) 안의 heredoc 따옴표를 잘못 파싱한다 → 파일로 받는다.
  python3 -I - "$SK" >"$T_TMP/inject.txt" 2>&1 <<'PYEOF'
import os, re, sys
root = sys.argv[1]
for d in sorted(os.listdir(root)):
    p = os.path.join(root, d, 'SKILL.md')
    if not os.path.isfile(p):
        continue
    txt = open(p, encoding='utf-8').read()
    fm, body = txt.split('\n---\n', 1) if txt.startswith('---\n') else ('', txt)
    rules = [m.strip()[1:-1] if m.strip()[:1] in '"\'' else m.strip()
             for m in re.findall(r'^\s+-\s+(.+)$', fm, re.M)]
    for cmd in re.findall(r'!`([^`\n]+)`', body):
        lead = re.match(r'("[^"]*"|\'[^\']*\'|\S+)', cmd.strip()).group(1)
        quoted = 'Bash(%s *)' % lead
        print('%s %s %s' % (d, 'OK' if quoted in rules else 'MISSING', lead))
PYEOF
  res=$(cat "$T_TMP/inject.txt")
  n=$(printf '%s\n' "$res" | grep -c ' OK ')
  assert_eq "주입 명령 5개 모두 따옴표 규칙 있음" "5" "$n"
  assert_not_contains "누락 규칙 없음" "$res" "MISSING"
else
  t_pass "python3 없음 — 정적 검사 생략"
fi

t_section "validate.sh: 주입 명령 검사·개인 참조 확장(B11)·OK 문구(B20)"
VP="$T_TMP/val proj"; mkdir -p "$VP/.claude/skills/commit" "$VP/.claude/skills/mine"
cp "$SK/commit/SKILL.md" "$SK/commit/context.sh" "$VP/.claude/skills/commit/"
chmod +x "$VP/.claude/skills/commit/context.sh"
vrun() { T_OUT=$("$BASH" "$T_REPO_ROOT/scripts/validate.sh" --project "$VP" --exit-zero 2>&1); T_RC=$?; }
printf -- '---\nname: mine\ndescription: test\n---\n본문\n' >"$VP/.claude/skills/mine/SKILL.md"
vrun
assert_rc "validate: rc" 0
assert_not_contains "validate: 정상 스킬 FAIL 없음" "$T_OUT" "FAIL skills"
assert_contains "validate: OK 문구" "$T_OUT" "스킬 2개 — 이상 없음"
sed '/Bash("\${CLAUDE_SKILL_DIR}\/context.sh" \*)/d' "$SK/commit/SKILL.md" >"$VP/.claude/skills/commit/SKILL.md"
vrun
assert_contains "validate: 따옴표 규칙 없음 → FAIL" "$T_OUT" "FAIL skills: "
assert_contains "validate: 주입 명령 메시지" "$T_OUT" "주입 명령 \"\${CLAUDE_SKILL_DIR}/context.sh\""
cp "$SK/commit/SKILL.md" "$VP/.claude/skills/commit/SKILL.md"
printf -- '---\nname: mine\nallowed-tools: Bash(git status *) Bash("${CLAUDE_SKILL_DIR}/x.sh" *)\n---\n!`"${CLAUDE_SKILL_DIR}/x.sh" a`\n' \
  >"$VP/.claude/skills/mine/SKILL.md"
: >"$VP/.claude/skills/mine/x.sh"; chmod +x "$VP/.claude/skills/mine/x.sh"
vrun
assert_not_contains "validate: 문자열 allowed-tools 일치" "$T_OUT" "주입 명령"
printf -- '---\nname: mine\n---\n!`git status --short`\n' >"$VP/.claude/skills/mine/SKILL.md"
vrun
assert_contains "validate: 우리 것 아닌 스킬은 WARN" "$T_OUT" "WARN skills: "
assert_not_contains "validate: 우리 것 아닌 스킬은 FAIL 아님" "$T_OUT" "FAIL skills"
printf '# t\n/preflight 와 /review-diff, /delegate, /harness-check 를 쓴다. skills/delegate 는 경로.\n' >"$VP/CLAUDE.md"
vrun
for s in /preflight /review-diff /delegate /harness-check; do
  assert_contains "validate: 개인 참조 $s" "$T_OUT" "$s"
done
assert_contains "validate: project-refs WARN" "$T_OUT" "WARN project-refs:"
assert_not_contains "validate: 프로젝트에 있는 스킬 이름은 개인 참조 아님" "$T_OUT" "참조 /commit"

t_section "settings·fragments 회귀(D5·D8·D9·D10)"
G="$T_REPO_ROOT/claude/global/settings.json"; P="$T_REPO_ROOT/profiles"
for m in 'Read|Edit|Write|MultiEdit|NotebookEdit|Grep|Bash|Monitor' 'Bash|Monitor' 'Edit|Write|MultiEdit|Bash|Monitor'; do
  assert_eq "matcher $m" 1 "$(grep -c "\"matcher\": \"$m\"" "$G")"
done
assert_eq "node: npx --no-install 5개" 5 "$(grep -c '"Bash(npx --no-install ' "$P/node/settings.fragment.json")"
assert_eq "node: 설치형 npx 없음" 0 "$(grep -c '"Bash(npx [^-]' "$P/node/settings.fragment.json")"
assert_eq "django: --check --dry-run" 1 "$(grep -c 'makemigrations --check --dry-run \*)' "$P/django/settings.fragment.json")"
assert_eq "django: --check 단독 없음" 0 "$(grep -c 'makemigrations --check \*)' "$P/django/settings.fragment.json")"
assert_eq "python: ruff format --check" 1 "$(grep -c '"Bash(uv run ruff format --check \*)"' "$P/python/settings.fragment.json")"
assert_eq "python: ruff format 쓰기 없음" 0 "$(grep -c '"Bash(uv run ruff format \*)"' "$P/python/settings.fragment.json")"
if command -v python3 >/dev/null 2>&1; then
  for f in "$G" "$P"/*/settings.fragment.json; do
    if python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null; then t_pass "json $f"; else t_fail "json $f"; fi
  done
fi
t_report
