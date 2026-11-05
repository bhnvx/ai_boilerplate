#!/usr/bin/env bash
# preflight/lib.sh — context.sh 보조 함수(source 전용). bash 3.2 호환, set -e/-u 없음, 읽기 전용.
# 전역 입력: PF_DIR(프로젝트 경로), PF_HAS_HEAD(1|0), PF_BASE(베이스 커밋-ish 또는 빈 값).

# 오래된 git(< 2.15)은 --no-optional-locks 옵션이 없다 → 환경 변수로 같은 효과(모르는 git은 무시).
GIT_OPTIONAL_LOCKS=0
export GIT_OPTIONAL_LOCKS
pf_git() { git -c core.quotePath=false -C "$PF_DIR" "$@" 2>/dev/null; }

# pf_join: stdin의 비어 있지 않은 줄을 공백 하나로 잇는다(끝 공백 없음).
pf_join() { awk 'NF { printf "%s%s", (n++ ? " " : ""), $0 } END { if (n) print "" }'; }

# pf_cap <text> [<empty-label>] [<max>]: 처음 max줄만 출력하고 생략 줄 수를 알린다.
pf_cap() {
  local max=${3:-40} total
  if [ -z "$1" ]; then
    printf '%s\n' "${2:-(없음)}"
    return 0
  fi
  total=$(printf '%s\n' "$1" | wc -l | tr -d ' ')
  printf '%s\n' "$1" | head -n "$max"
  if [ "${total:-0}" -gt "$max" ] 2>/dev/null; then
    printf '… (%s줄 중 %s줄만 표시)\n' "$total" "$max"
  fi
  return 0
}

# pf_pick_base <arg>: PF_BASE, PF_BASE_HOW, PF_BASE_NOTE를 정한다.
# 순서: 인수(유효한 커밋) → 현재 브랜치 upstream → main/master(현재 브랜치 제외) → HEAD~1 → 없음.
pf_pick_base() {
  local arg=$1 ref_re='^[A-Za-z0-9._/@{}~^-]+$' up cur cand
  PF_BASE=""; PF_BASE_HOW="없음"; PF_BASE_NOTE=""
  [ "$PF_HAS_HEAD" = 1 ] || return 0
  set -f
  set -- $arg
  set +f
  arg=${1:-}
  if [ -n "$arg" ]; then
    case $arg in
      -*) ;;
      *)
        if [[ $arg =~ $ref_re ]] && pf_git rev-parse --verify --quiet "$arg^{commit}" >/dev/null; then
          PF_BASE=$arg; PF_BASE_HOW="인수"; return 0
        fi ;;
    esac
    PF_BASE_NOTE="인수 '$arg'를 커밋으로 확인할 수 없어 자동 선택함"
  fi
  up=$(pf_git rev-parse --abbrev-ref --symbolic-full-name '@{u}')
  if [ -n "$up" ] && pf_git rev-parse --verify --quiet "$up^{commit}" >/dev/null; then
    PF_BASE=$up; PF_BASE_HOW="upstream"; return 0
  fi
  cur=$(pf_git symbolic-ref --short -q HEAD)   # branch --show-current는 git 2.22+
  for cand in main master origin/main origin/master; do
    [ "$cand" = "$cur" ] && continue
    if pf_git rev-parse --verify --quiet "$cand^{commit}" >/dev/null; then
      PF_BASE=$cand; PF_BASE_HOW="기본 브랜치"; return 0
    fi
  done
  if pf_git rev-parse --verify --quiet 'HEAD~1^{commit}' >/dev/null; then
    PF_BASE='HEAD~1'; PF_BASE_HOW="직전 커밋"
  fi
  return 0
}

# pf_cat <path>: PF_CAT(MIG MODEL DEPS ENV SECRET CI DOCS TEST OTHER)와 PF_SUB(manifest|lock)를 정한다. 포크 없음.
pf_cat() {
  local p="/$1" b=${1##*/}
  PF_SUB=""
  case $p in
    */migrations/*|*/migration/*|*/alembic/versions/*|*/db/migrate/*|*/prisma/migrations/*|\
    */supabase/migrations/*|*/drizzle/*|*/knex/migrations/*|*/sequelize/migrations/*|\
    */typeorm/migrations/*|*/flyway/*|*/liquibase/*|*/sql/migrations/*|*/db/migrations/*|\
    */atlas/migrations/*|*/goose/*|*/dbmate/*)
      case $b in
        __init__.py|README*|*.md|env.py|script.py.mako|alembic.ini|migration_lock.toml|*.lock) PF_CAT=OTHER ;;
        *) PF_CAT=MIG ;;
      esac
      return 0 ;;
  esac
  case $b in
    # 예시·템플릿 파일은 비밀이 아니다(guard-secrets 규칙 1과 같음): .env.production.example 등도 ENV.
    .env.example|.env.sample|.env.template|.env.dist|*.example|*.sample|*.template|*.dist) PF_CAT=ENV; return 0 ;;
    .env|.env.*|.envrc|*.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|id_rsa|id_ed25519|id_ecdsa|id_dsa|\
    credentials|credentials.json|service-account*.json|.git-credentials|.netrc|.pgpass|*.tfvars|*.tfstate)
      PF_CAT=SECRET; return 0 ;;
    pyproject.toml|Pipfile|package.json|Cargo.toml|go.mod|Gemfile|composer.json)
      PF_CAT=DEPS; PF_SUB=manifest; return 0 ;;
    uv.lock|poetry.lock|Pipfile.lock|requirements*.txt|pnpm-lock.yaml|yarn.lock|package-lock.json|\
    bun.lock|bun.lockb|Cargo.lock|go.sum|Gemfile.lock|composer.lock)
      PF_CAT=DEPS; PF_SUB=lock; return 0 ;;
  esac
  case $p in
    */.github/*|*/.gitlab-ci.yml|*/.circleci/*|*/Jenkinsfile|*/Dockerfile*|*/compose*.yml|*/compose*.yaml|\
    */docker-compose*.yml|*/docker-compose*.yaml|*.tf|*/k8s/*|*/helm/*|*/deploy/*)
      PF_CAT=CI; return 0 ;;
    */tests/*|*/test/*|*/__tests__/*|*/spec/*|*/test_*|*_test.*|*.test.*|*.spec.*|*/conftest.py)
      PF_CAT=TEST; return 0 ;;
    */openapi*|*/swagger*|*/docs/*|*.md|*.rst|*.adoc)
      PF_CAT=DOCS; return 0 ;;
    */prisma/schema.prisma|*[Mm]odel*|*[Ss]chema*|*[Ee]ntit[yi]*)
      # 코드·스키마 정의 확장자만 모델로 본다(스크립트·JSON 문서는 기타).
      case $b in
        *.py|*.ts|*.tsx|*.js|*.mjs|*.cjs|*.rb|*.go|*.java|*.kt|*.cs|*.php|*.ex|*.exs|*.rs|\
        *.prisma|*.sql|*.graphql|*.gql|*.scala|*.dart|*.swift)
          PF_CAT=MODEL; return 0 ;;
      esac ;;
  esac
  PF_CAT=OTHER
  return 0
}

# pf_cls_report <max>: stdin "CAT<TAB>path" 줄을 분류별 목록으로 출력한다(한 번의 awk).
pf_cls_report() {
  awk -F '\t' -v max="${1:-15}" '
    BEGIN {
      n = split("MIG MODEL DEPS ENV SECRET CI DOCS TEST OTHER", order, " ")
      lb["MIG"] = "마이그레이션"; lb["MODEL"] = "모델·스키마"; lb["DEPS"] = "의존성 매니페스트·lockfile"
      lb["ENV"] = "환경·설정 예시 파일"; lb["SECRET"] = "비밀 파일 의심(내용은 읽지 않음)"; lb["CI"] = "CI·배포 설정"
      lb["DOCS"] = "문서·OpenAPI"; lb["TEST"] = "테스트"; lb["OTHER"] = "기타"
    }
    NF >= 2 { c[$1]++; if (c[$1] <= max) it[$1] = it[$1] "  - " $2 "\n" }
    END {
      for (i = 1; i <= n; i++) {
        k = order[i]
        if (!c[k]) continue
        printf "- %s (%d)\n%s", lb[k], c[k], it[k]
        if (c[k] > max) printf "  - … 외 %d개\n", c[k] - max
      }
    }'
}

# pf_added_lines: 추가된 줄을 "path<TAB>line<TAB>content"로 출력한다(베이스 이후 커밋 + 작업 트리 + untracked 텍스트).
# lockfile·min 파일은 건너뛰고, 20000줄을 넘으면 __PF_TRUNCATED__ 표지를 남긴다.
pf_added_lines() {
  local f t files tl i=0
  local dopt="-U0 --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/"
  {
    # shellcheck disable=SC2086
    [ -n "$PF_BASE" ] && pf_git diff $dopt "$PF_BASE...HEAD"
    if [ "$PF_HAS_HEAD" = 1 ]; then
      pf_git diff $dopt HEAD
    else
      pf_git diff $dopt --cached
    fi
  } | awk '
    /^diff --git / { hdr = 1; next }
    hdr && /^\+\+\+ / { f = substr($0, 5); sub(/\t$/, "", f); sub(/^b\//, "", f); next }
    /^@@ / { hdr = 0; s = $0; sub(/^@@ -[0-9,]+ \+/, "", s); sub(/[ ,].*$/, "", s); ln = s + 0; next }
    !hdr && /^\+/ {
      if (("/" f) ~ /\/(package-lock\.json|pnpm-lock\.yaml|[A-Za-z]+\.lock|go\.sum|bun\.lockb)$/ || f ~ /\.min\.(js|css)$/) { ln++; next }
      if (++total > 20000) { trunc = 1; exit }
      print f "\t" ln "\t" substr($0, 2); ln++
    }
    END { if (trunc) print "__PF_TRUNCATED__\t0\t" }'
  files=()
  while IFS= read -r -d '' f; do
    pf_cat "$f"
    [ "$PF_CAT" = SECRET ] && continue
    [ "$PF_SUB" = lock ] && continue
    case $f in *.min.js|*.min.css) continue ;; esac
    files[${#files[@]}]="./$f"
    i=$((i + 1)); [ "$i" -ge 200 ] && break
  done < <(pf_git ls-files -z --others --exclude-standard)
  [ "${#files[@]}" -gt 0 ] || return 0
  tl=()
  while IFS= read -r t; do
    [ -n "$t" ] && tl[${#tl[@]}]=$t
  done < <(cd "$PF_DIR" 2>/dev/null && grep -Il -e '' "${files[@]}" 2>/dev/null)
  [ "${#tl[@]}" -gt 0 ] || return 0
  ( cd "$PF_DIR" 2>/dev/null &&
    awk 'FNR <= 5000 { fn = FILENAME; sub(/^\.\//, "", fn); print fn "\t" FNR "\t" $0 }' "${tl[@]}" 2>/dev/null )
  return 0
}

# pf_triage: stdin(추가된 줄 스트림)을 한 번만 읽어 후보만 태그를 붙여 출력한다.
#   T = 잘림 표지, E<TAB>content = 환경 변수 참조 후보, S<TAB>path<TAB>line<TAB>content = 시크릿 후보.
pf_triage() {
  awk '
    $0 == "__PF_TRUNCATED__\t0\t" { print "T"; next }
    { c = $0; sub(/^[^\t]*\t[^\t]*\t/, "", c) }
    c ~ /env|environ|[Gg]etenv|ENV|settings\./ { print "E\t" c }
    tolower(c) ~ /akia|private key|key|secret|token|password|ghp_|github_pat_|sk-|xox/ { print "S\t" $0 }'
}
# pf_tag <tag> <triaged>: 해당 태그 줄의 본문만 출력한다.
pf_tag() { printf '%s\n' "$2" | awk -v t="$1" 'index($0, t "\t") == 1 { print substr($0, length(t) + 2) }'; }

# pf_env_refs: stdin(추가된 줄)에서 환경 변수 키를 뽑는다. pf_settings_refs: settings.X 참조 키.
pf_env_refs() {
  local q="[\"']"
  grep -oE "process\.env\.[A-Z0-9_]+|process\.env\[$q[A-Z0-9_]+|import\.meta\.env\.[A-Z0-9_]+|os\.environ(\.get)?\($q[A-Z0-9_]+|os\.environ\[$q[A-Z0-9_]+|[Gg]etenv\($q[A-Z0-9_]+|(^|[^A-Za-z0-9_.])env\($q[A-Z0-9_]+|ENV(\.fetch\(|\[)$q[A-Z0-9_]+" 2>/dev/null |
    sed -E 's/.*[^A-Z0-9_]([A-Z0-9_]+)$/\1/' | LC_ALL=C sort -u
}
pf_settings_refs() {
  grep -oE 'settings\.[A-Z][A-Z0-9_]{2,}' 2>/dev/null | sed 's/^settings\.//' | LC_ALL=C sort -u
}

# pf_example_files: 프로젝트 루트의 환경 예시 파일(.env*.example|.sample|.template|.dist) 이름을
# PF_EXAMPLE_FILES(공백 구분)에 넣는다(서브셸 밖에서 호출). 공백이 든 이름은 건너뛴다.
pf_example_files() {
  local f b
  PF_EXAMPLE_FILES=""
  set +f
  for f in "$PF_DIR"/.env*.example "$PF_DIR"/.env*.sample "$PF_DIR"/.env*.template "$PF_DIR"/.env*.dist; do
    [ -f "$f" ] || continue
    b=${f##*/}
    case $b in *[[:space:]]*) continue ;; esac
    case " $PF_EXAMPLE_FILES " in *" $b "*) continue ;; esac
    PF_EXAMPLE_FILES="${PF_EXAMPLE_FILES:+$PF_EXAMPLE_FILES }$b"
  done
  return 0
}
# pf_example_keys: PF_EXAMPLE_FILES의 키 목록(정렬·중복 제거).
pf_example_keys() {
  local f
  set -f
  for f in $PF_EXAMPLE_FILES; do
    sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\2/p' "$PF_DIR/$f" 2>/dev/null
  done | LC_ALL=C sort -u
  set +f
}

# pf_secret_scan <stream>: 추가된 줄에서 비밀 값 후보를 찾아 "path:line [종류]"만 출력한다(값은 출력하지 않음).
pf_secret_scan() {
  local s q="[\"']" nq="[^\"']"
  [ -n "$1" ] || return 0
  # 한 번의 넓은 사전 필터로 후보 줄만 남긴 뒤 종류별 패턴을 적용한다(대용량 diff에서 속도 유지).
  s=$(printf '%s\n' "$1" | grep -iE 'akia|private key|key|secret|token|password|ghp_|github_pat_|sk-|xox' 2>/dev/null)
  [ -n "$s" ] || return 0
  pf_scan_one "$s" "AWS 액세스 키" -E 'AKIA[0-9A-Z]{16}'
  pf_scan_one "$s" "개인 키" -E '-----BEGIN [A-Z ]*PRIVATE KEY'
  pf_scan_one "$s" "하드코딩 자격 증명" -iE "(api[_-]?key|secret|token|password)[[:space:]]*[:=][[:space:]]*$q$nq{8,}"
  pf_scan_one "$s" "GitHub 토큰" -E 'ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}'
  pf_scan_one "$s" "API 키(sk-)" -E 'sk-[A-Za-z0-9]{20,}|sk-ant-[A-Za-z0-9_-]{20,}'
  pf_scan_one "$s" "Slack 토큰" -E 'xox[abprs]-[A-Za-z0-9-]{10,}'
  return 0
}
pf_scan_one() {
  printf '%s\n' "$1" | grep "$3" -e "$4" 2>/dev/null |
    awk -F '\t' -v k="$2" '$1 != "__PF_TRUNCATED__" { print "- " $1 ":" $2 " [" k "]" }'
}

# pf_claude_commands: 프로젝트 CLAUDE.md의 "## 명령어" 절에 있는 코드블록(최대 40줄).
pf_claude_commands() {
  local f
  for f in "$PF_DIR/CLAUDE.md" "$PF_DIR/.claude/CLAUDE.md"; do
    [ -f "$f" ] || continue
    awk '
      !fence && /^##[[:space:]]/ { if (sec) exit; if ($0 ~ /^##[[:space:]]+명령어/) sec = 1; next }
      sec && /^[[:space:]]*```/ { fence = !fence; if (++n <= 40) print; next }
      sec && fence { if (++n <= 40) print }
      END { if (n > 40) printf "… (%d줄 중 40줄만 표시)\n", n }' "$f"
    return 0
  done
  return 0
}

# pf_cmd_hints: package.json scripts, Makefile 타깃, pyproject [tool.*] 섹션.
pf_cmd_hints() {
  local s=""
  if [ -f "$PF_DIR/package.json" ]; then
    if command -v jq >/dev/null 2>&1; then
      s=$(jq -r '(.scripts // {}) | keys | join(" ")' "$PF_DIR/package.json" 2>/dev/null)
    elif command -v python3 >/dev/null 2>&1; then
      s=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(sorted((d.get("scripts") or {}).keys())))' "$PF_DIR/package.json" 2>/dev/null)
    fi
    [ -n "$s" ] && printf -- '- package.json scripts: %s\n' "$s"
  fi
  if [ -f "$PF_DIR/Makefile" ]; then
    s=$(grep -E '^[A-Za-z][A-Za-z0-9_.-]*:([^=]|$)' "$PF_DIR/Makefile" 2>/dev/null | sed 's/:.*//' | LC_ALL=C sort -u | head -n 20 | pf_join)
    [ -n "$s" ] && printf -- '- Makefile 타깃: %s\n' "$s"
  fi
  if [ -f "$PF_DIR/pyproject.toml" ]; then
    s=$(grep -oE '^\[tool\.[A-Za-z0-9_-]+' "$PF_DIR/pyproject.toml" 2>/dev/null | sed 's/^\[tool\.//' | LC_ALL=C sort -u | pf_join)
    [ -n "$s" ] && printf -- '- pyproject [tool.*]: %s\n' "$s"
  fi
  return 0
}
