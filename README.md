# dev_settings

Claude Code 전역 하네스(설정·훅·규칙·에이전트·스킬)와 프로젝트 템플릿을 한 저장소에서 관리하는 보일러플레이트.

## 1. 목적

- **언어·프레임워크 무관 핵심**: 전역 `settings.json`, 가드 훅 3개(비밀 파일·위험 명령·마이그레이션), 세션 컨텍스트 훅, 상태줄, 규칙 5개, 에이전트 3개, 스킬 7개. 어떤 스택의 프로젝트에서도 그대로 동작한다.
- **선택형 프로필**: `python` · `django` · `fastapi` · `node`. 기본으로는 아무것도 적용하지 않는다. `apply.sh --profile <이름>` 또는 `--profile auto`(스택 감지)로 프로젝트에만 추가한다.
- **웹 솔루션 공통 기능**(백엔드 API·프런트·DB, 언어 무관):
  - `rules/web.md` — API 설계·인증/인가·데이터·관측·테스트 계층 원칙(항상 로드)
  - `/api` — 엔드포인트 추가·변경 워크플로(요구사항 재진술 → 명세 표 → 구현 → 테스트 → 보고)
  - `/preflight` — PR 전 점검(마이그레이션 누락, env 동기화, 시크릿 스캔, lockfile, OpenAPI)
  - `guard-migrations` 훅 — 기존 마이그레이션 수정·삭제 확인(적용 여부는 판단하지 않음), 서브에이전트의 마이그레이션 작업 차단

### 검증 기준

| 항목 | 기준 |
|---|---|
| Claude Code | 2.1.318 (VS Code 확장, macOS) |
| 공식 문서 확인일 | 2026-11-05 (code.claude.com) |
| 설정 스키마 스냅샷 | 2026-11-05 (`schemas/claude-code-settings.schema.json`, json.schemastore.org) |
| 셸 | `/bin/bash` 3.2 호환(bash 5에서도 테스트), BSD/GNU 도구 공통 |
| 필수 도구 | `python3` 3.8+ (install·apply·validate), `git` |
| 선택 도구 | `jq`(훅 JSON 파싱, 없으면 `python3`로 대체. 둘 다 없으면 훅은 통과(fail-open)) |
| CI | ubuntu-latest, macos-latest |

## 2. 디렉터리 구조

```
dev_settings/
├── README.md
├── CLAUDE.md                       이 저장소 작업용 지침
├── install.sh                      claude/global → ~/.claude 설치
├── apply.sh                        project-template·profiles → <프로젝트> 적용
├── claude/
│   ├── global/                     → ~/.claude/
│   │   ├── CLAUDE.md.tmpl          → ~/.claude/CLAUDE.md
│   │   ├── settings.json           ~/.claude/settings.json에 병합
│   │   ├── rules/                  core · git · security · web · subagent-policy
│   │   ├── agents/                 explorer · implementer · reviewer
│   │   ├── hooks/                  run-hook.sh(런처) · guard-* · session-context · format-on-edit · statusline
│   │   │   └── lib/                common.sh · shellparse.sh · detect-stack.sh · secret-patterns.txt
│   │   └── skills/                 commit · review-diff · delegate · harness-check · harness-init · api · preflight
│   └── project-template/           → <프로젝트>/
│       ├── CLAUDE.md.tmpl          → CLAUDE.md
│       ├── CLAUDE.local.md.example 개인 메모 예시
│       ├── gitignore.claude        .gitignore에 추가할 줄
│       └── dot-claude/             → .claude/
│           ├── settings.json · settings.local.json.example
│           ├── fragments/format-hook.json   --with-format-hook일 때만 병합
│           └── rules/project.md    서브에이전트 보충 규칙 템플릿
├── profiles/                       선택형: python · django · fastapi · node
│   └── <이름>/rules/<규칙>.md · settings.fragment.json
├── schemas/claude-code-settings.schema.json
├── scripts/                        merge-settings.py · validate.sh · update-schema.sh
├── tests/                          run-all.sh · lib/ · hooks/ · install/
├── .github/workflows/ci.yml
├── vscode/settings.json            VS Code 사용자 설정 참고본(설치 대상 아님, 수동 복사)
└── copilot/copilot-instructions.md  GitHub Copilot 지침 참고본(설치 대상 아님)
```

`CLAUDE.md.tmpl`·`dot-claude/`로 이름을 바꿔 둔 이유:

- Claude Code는 하위 디렉터리의 `CLAUDE.md`와 `.claude/rules/*.md`를 그 디렉터리 파일을 건드릴 때 자동으로 읽는다.
- 템플릿이 실제 이름이면 이 저장소를 작업하는 세션에 템플릿 내용이 지침으로 섞인다.
- `install.sh`·`apply.sh`가 복사하면서 실제 이름(`CLAUDE.md`, `.claude/`)으로 바꾼다.

## 3. 빠른 시작

```bash
git clone https://github.com/bhnvx/dev_settings.git ~/vsc/dev_settings
cd ~/vsc/dev_settings
./install.sh --dry-run   # 파일별 계획과 settings diff만 출력(아무것도 쓰지 않음)
./install.sh             # ~/.claude 에 설치(백업·매니페스트 포함)
```

1. Claude Code를 재시작한다(훅·규칙·스킬은 세션 시작 때 로드).
2. 아무 세션에서 `/harness-check` → FAIL이 없는지 확인한다.
3. 프로젝트에 적용한다. 둘 중 하나:
   - 터미널: `./apply.sh ~/vsc/<프로젝트> --profile auto`
   - 해당 프로젝트 세션: `/harness-init` (스택 감지 → 실행할 명령 확인 → `apply.sh` 실행)
4. 생성된 `CLAUDE.md`의 TODO를 채우고 `.claude/settings.json`의 allow 목록을 검토한다.
5. 커밋할 파일만 커밋한다(4.8 참고).

- `--with-format-hook`(편집 후 자동 포맷)은 프로젝트에 포매터 설정이 있으면 권장한다. ECC quality-gate는 기본적으로 검사만 하므로 겹치지 않는다. `ECC_QUALITY_GATE_FIX=true`일 때만 ECC가 고치는 타입을 건너뛴다(5절).
- 설치를 되돌리려면 `./install.sh --uninstall` 또는 `./install.sh --restore <타임스탬프>`(7절).

## 4. 구성 요소

### 4.1 하네스: `claude/global/settings.json`

| 키 | 값 | 의도 |
|---|---|---|
| `$schema` | schemastore URL | 편집기 자동완성·검증 |
| `language` | `korean` | 응답 언어. 이미 값이 있으면 사용자 값 유지 |
| `worktree.baseRef` | `head` | 워크트리를 현재 HEAD 기준으로 만든다. 기본값은 미푸시 커밋을 빠뜨린다 |
| `permissions.allow` | `jq`, `gh` 읽기 명령, 공식 문서 WebFetch 도메인 | 최소로 둔다(아래) |
| `permissions.deny` | 비밀 파일 `Read(//**/…)`, `~/.ssh/**` 등 | 핵심 비밀 파일 읽기 차단(네이티브 강제, 전체 목록은 훅 — 6.2) |
| `hooks` | PreToolUse 3개, SessionStart 1개 | 4.2 표 |
| `statusLine` | `statusline.sh` | 모델·브랜치·컨텍스트·사용량 한 줄 |

- **allow를 최소로 둔 이유**: `ls`·`cat`·`git status` 같은 읽기 명령은 Claude Code가 이미 프롬프트 없이 실행한다. 와일드카드 allow(`git log *` 등)는 `git log --output=<파일>` 같은 쓰기 경로까지 연다.
- **deny에 `//**/`를 쓰는 이유**: 사용자 설정에서 `**/.env`는 현재 작업 디렉터리 하위만 덮는다. `//`로 파일시스템 루트에 고정해야 모든 프로젝트에 적용된다.
- **`permissions.ask`를 두지 않은 이유**: 네이티브 ask 규칙은 훅의 env 스위치로 끌 수 없다. 푸시·sudo 같은 확인은 훅이 맡아 프로젝트별로 조정 가능하게 한다.
- `.env.example`·`.env.sample`·`.env.template`·`.env.dist`, `*.pub`는 deny하지 않는다.
- `alwaysThinkingEnabled`는 넣지 않는다(Fable 모델에 효과 없음).
- 사용자 값이 이기는 키: `model` `effortLevel` `modelSettings` `enabledPlugins` `extraKnownMarketplaces` `env` `language` `statusLine` `attribution` `includeCoAuthoredBy` `worktree` `permissions.defaultMode` `permissions.additionalDirectories`.

### 4.2 훅

모든 훅은 런처 `run-hook.sh <이름>`을 거친다.

- 런처는 훅의 종료 코드와 무관하게 항상 `exit 0`. 문법 오류가 난 훅이 exit 2로 모든 도구를 막는 사고를 방지한다.
- 훅은 stdout JSON(`permissionDecision`)으로만 결정한다. exit 2를 쓰지 않는다.
- `jq`가 없으면 `python3`, 둘 다 없으면 아무 결정 없이 통과한다(fail-open).
- 차단·확인 사유에 규칙 ID가 붙는다. 예: `차단 [secrets:print]: cat .env — 비밀 파일 내용 출력`.
- 훅 입력 JSON을 해석할 수 없으면(`tool_name`이 보이는데 깨진 입력) `ask [hook:parse-error]`로 확인을 요청한다. 빈 입력은 결정 없이 통과한다.

| 훅 | 이벤트 · 매처 | 동작 | 끄기 | 설정 env |
|---|---|---|---|---|
| `guard-secrets` | PreToolUse · `Read\|Edit\|Write\|MultiEdit\|NotebookEdit\|Grep\|Bash\|Monitor` | 비밀 파일 읽기·출력·전송 deny. 복사·`source`·쓰기·`git add`·env 덤프·비밀 변수 출력 ask | `CLAUDE_GUARD_SECRETS=off` | `CLAUDE_GUARD_SECRET_EXTRA`, `CLAUDE_GUARD_SECRET_ALLOW` |
| `guard-destructive` | PreToolUse · `Bash\|Monitor` | 루트·홈 `rm -rf`, `.git` 삭제, 보호 브랜치 force push·삭제, `--no-verify`, 디스크·시스템 명령 deny. 보호 브랜치 푸시·커밋, DB 파괴 SQL·마이그레이션 롤백·리셋, 인프라·클라우드 쓰기, 배포·publish, sudo, `curl \| sh`, `git config core.hooksPath` ask | `CLAUDE_GUARD_DESTRUCTIVE=off` | `CLAUDE_GUARD_PROTECTED_BRANCHES`, `CLAUDE_GUARD_ASK_ON_PUSH`, `CLAUDE_GUARD_ALLOW_PATTERNS` |
| `guard-migrations` | PreToolUse · `Edit\|Write\|MultiEdit\|Bash\|Monitor` | 서브에이전트(훅 입력에 `agent_id`가 있을 때)의 마이그레이션 생성·적용·수정·삭제·롤백 deny. 기존 마이그레이션 수정·삭제, 파괴적 스키마 변경 ask(high). 적용 명령(`migrate`, `alembic upgrade`, `prisma migrate dev` 등) ask(low) | `CLAUDE_GUARD_MIGRATIONS=off` | — |
| `session-context` | SessionStart · 전체 | 날짜, 브랜치·ahead/behind·변경 수, 최근 커밋 3개, 스택, 규칙 파일 현황, 보호 브랜치 경고를 컨텍스트로 주입 | `CLAUDE_SESSION_CONTEXT=off` | `CLAUDE_GUARD_PROTECTED_BRANCHES` |
| `statusline.sh` | statusLine | `모델 │ ⎇ 브랜치* │ ctx % │ 5h %(또는 $비용) │ 디렉터리` | settings의 `statusLine` 제거 | `CLAUDE_STATUSLINE_COLOR=0`, `NO_COLOR` |
| `format-on-edit` | PostToolUse · `Edit\|Write\|MultiEdit` (프로젝트 opt-in) | 프로젝트가 설정한 포매터만 실행(ruff/black/isort, prettier/biome, gofmt, rustfmt, shfmt, terraform fmt, taplo). `.sh`는 `bash -n`(shebang이 bash·sh이거나 없을 때). 결과를 컨텍스트로 알림. ECC와의 관계는 5절 | `CLAUDE_FORMAT_ON_EDIT=off` | `CLAUDE_FORMAT_ON_EDIT=force`, `CLAUDE_FORMAT_TIMEOUT`(기본 20초) |

- `Monitor` 도구는 Bash와 같은 권한 규칙으로 명령을 실행하므로 가드 3개가 Bash와 똑같이 검사한다. 명령 없이 `ws` 입력만 있는 감시는 통과한다.
- 서브에이전트 판단은 `agent_id`로 한다. `agent_type`은 `--agent`로 띄운 메인 세션에도 들어오므로 쓰지 않는다.
- 명령 치환(`$(…)`·백틱·`<(…)`)은 바깥 명령에 자리표시자로 남기고 안쪽 명령을 별도 세그먼트로 검사한다. 그래서 `env $(cat .env) node app.js`는 안쪽 `cat .env` 때문에 deny이고, `rm -rf "$(mktemp -d)"`처럼 삭제 대상이 치환 결과인 재귀 삭제도 deny다(의도된 동작 — `"${TMPDIR:?}/…"`처럼 `:?`로 보호한 변수 경로는 통과). `git push origin $BRANCH`·`$(git branch --show-current)`처럼 펼쳐지지 않은 refspec은 현재 브랜치로 본다.
- 명령 머리의 따옴표·백슬래시·대소문자 변형(`"rm" -rf`, `r\m`, `RM`, `SUDO rm`)은 같은 규칙으로 판정한다. heredoc 본문은 1 MB까지 검사하고(코드 heredoc은 비밀 파일 경로만), 200 KB heredoc 처리에 약 0.3초가 든다.
- `uv run --env-file .env …`·`docker compose --env-file .env …`는 실행 자체는 통과하지만, 그 명령이 환경을 출력·덤프하면(`env`, `printenv`, `python -c 'print(os.environ)'` 등) deny다.
- `git config [--global] core.hooksPath <경로>`는 ask(훅 우회)다. `.husky`·`.githooks`·`.git/hooks`·`.hooks`·`.lefthook*` 같은 저장소 안의 관례적 경로는 통과한다.
- DB 마이그레이션 롤백·리셋·초기화(`flyway clean`, `rails db:rollback`, `artisan migrate:fresh`, `supabase db reset` 등)의 ask(high)는 `guard-destructive`가, 서브에이전트일 때의 deny는 `guard-migrations`가 담당한다. `makemigrations --check`·`--dry-run`은 생성으로, `alembic`·`flask db`의 `upgrade`·`downgrade --sql`(SQL만 출력하는 오프라인 모드)은 적용·롤백으로 보지 않는다.

공통 스위치:

- `CLAUDE_HOOKS_DISABLE=1` — 모든 훅을 즉시 통과(전역 킬 스위치).
- `CLAUDE_HOOKS_LOG=<파일>` — 결정 로그. 한 줄 형식: `날짜<TAB>훅<TAB>결정<TAB>규칙<TAB>명령 발췌(200자 이하)`.
- `CLAUDE_HOOKS_DEBUG=1` — 디버그 메시지를 stderr로 출력.
- 훅별 끄기 스위치(`CLAUDE_GUARD_SECRETS`·`CLAUDE_GUARD_DESTRUCTIVE`·`CLAUDE_GUARD_MIGRATIONS`, `CLAUDE_SESSION_CONTEXT`, `CLAUDE_FORMAT_ON_EDIT`)는 `off` `0` `false` `no`(대소문자 무관)를 인식한다. `CLAUDE_HOOKS_DISABLE`은 `1`만, `CLAUDE_STATUSLINE_COLOR`는 `0`만 인식한다.

마이그레이션 경로로 보는 디렉터리: `migrations/` `migration/` `alembic/versions/` `db/migrate/` `db/migrations/` `prisma/migrations/` `supabase/migrations/` `drizzle/` `knex/migrations/` `sequelize/migrations/` `typeorm/migrations/` `flyway/` `liquibase/` `sql/migrations/` `atlas/migrations/` `goose/` `dbmate/`. `__init__.py`·`env.py`·`README*`·`*.md`·lock 파일은 제외한다.

### 4.3 확인(ask) 2단계와 `permission_mode`

| 단계 | 동작 | 예 |
|---|---|---|
| deny | 항상 차단 | `cat .env`, `rm -rf ~`, `git push --force origin main`, `git commit --no-verify` |
| ask-high | 모든 모드에서 확인 요청(`bypassPermissions`에서 실제로 프롬프트가 뜨는지는 미검증) | `git push origin main`, 보호 브랜치 커밋, `psql -c "DROP TABLE …"`, `kubectl delete`, `make deploy`, `sudo`, `echo $AWS_SECRET_ACCESS_KEY`, 기존 마이그레이션 수정 |
| ask-low | `default` `acceptEdits` `dontAsk` `plan`에서 확인, `auto` `bypassPermissions`에서는 결정 없이 통과(모드·분류기에 맡김) | `rm -rf ./src`, 비보호 브랜치 `git reset --hard`, `git stash drop`, `printenv`, `manage.py migrate` |

- 모드는 훅 입력의 `permission_mode`로 판단한다. `dontAsk` 모드는 확인 요청을 자동 거부한다.
- 재생성 가능한 디렉터리(`node_modules` `.venv` `dist` `build` `.next` `__pycache__` `coverage` 등)와 임시 디렉터리 `rm -rf`는 조용히 허용한다.

### 4.4 규칙 5개 (`~/.claude/rules/`, 모두 항상 로드)

| 파일 | 내용 |
|---|---|
| `core.md` | 검증한 것만 완료 보고, 추측 금지, 요청 범위 준수, 복잡한 요청은 목표·요구사항·유의사항·완료 조건으로 재진술 후 플랜, 완료 보고 형식 |
| `git.md` | `<gitmoji> scope: subject` 커밋 형식(유니코드 gitmoji, 예 `✨ api: …`)과 gitmoji 표, 브랜치 모델, 보호 브랜치, force push·`--no-verify`·`git add -A` 금지, PR 체크리스트·본문 형식 |
| `security.md` | 비밀 파일·값 취급, 마스킹, 운영 접근 금지, 외부 전송 금지 항목, 차단 우회 금지 |
| `web.md` | 웹 솔루션 공통: API 설계, 인증·인가, 데이터·마이그레이션 안전, 관측, 설정, 테스트 계층, 프런트, 보안·성능, 문서 |
| `subagent-policy.md` | 메인 직접 vs 위임 기준, 분할·배정, 위임 프롬프트 7항목, 결과 검증, 모델 배정 |

우선순위: 사용자 지시 > 프로젝트 `CLAUDE.md`·`.claude/rules` > 전역 rules. 전역 `CLAUDE.md`는 이 규칙과 스킬 목록을 한 줄씩 안내하고, 프로젝트에 `CLAUDE.md`가 없으면 `/harness-init`을 제안하게 한다.

### 4.5 에이전트 3개 (`~/.claude/agents/`)

| 에이전트 | 도구 | model · effort | 역할 |
|---|---|---|---|
| `explorer` | Read, Grep, Glob | sonnet · medium | 읽기 전용 조사, 결론과 근거(경로:라인)만 보고 |
| `implementer` | Read, Grep, Glob, Edit, Write, Bash | opus · high | 지정한 소유 파일 안에서만 구현. git·의존성·마이그레이션·운영 접근 금지 |
| `reviewer` | Read, Grep, Glob | opus · xhigh | 보고 전용 리뷰. 코드 수정 금지 |

- 세 에이전트 모두 `disallowedTools: mcp__*`, `omitClaudeMd: true`.
- **컨텍스트 비용**: 전역 rules는 general-purpose·플러그인 에이전트 등 `omitClaudeMd`를 쓰지 않는 서브에이전트에도 실릴 수 있다(빌트인 Explore·Plan은 CLAUDE.md를 읽지 않는다 — 정책 §2. 서브에이전트의 rules 로드 여부와 `omitClaudeMd`가 rules에도 적용되는지는 미검증). 특히 `subagent-policy.md`는 약 14KB(4~5K 토큰)로, 그런 에이전트를 띄울 때마다 이 비용이 든다. 정책을 항상 적용하는 대가로 감수한 선택이다.

### 4.6 스킬 7개 (`~/.claude/skills/`)

| 명령 | 인수 | 자동 호출 | 동작 |
|---|---|---|---|
| `/commit` | `[파일... \| 커밋 범위 설명]` | 수동 | 보호 브랜치 확인 → 파일 지정 스테이징 → staged diff 점검(비밀·디버그·임시·대용량) → `git.md` 형식 커밋. 푸시·`--amend`·`--no-verify` 안 함 |
| `/review-diff` | `[base-ref \| 파일...]` | 수동 | diff 수집 → 고위험 영역이면 opus, 아니면 sonnet `reviewer` 실행 → Critical/High는 직접 열어 확정 → 심각도순 보고. 수정 안 함 |
| `/delegate` | `[explorer\|implementer\|reviewer] [목표]` | 가능 | 위임 판단 체크리스트, 위임표 양식, 7항목 프롬프트 템플릿, 실행 후 점검 |
| `/harness-check` | — | 수동 | 설치본 `validate.sh` 결과 해석(FAIL 수정 / WARN 판단), 설치본이 저장소보다 오래되면 재설치 안내 |
| `/harness-init` | `[python\|django\|fastapi\|node\|auto] [--force] [--with-format-hook] [--team] [--dry-run]` | 수동 | 스택 감지 → `apply.sh` 명령 확인 후 실행 → 커밋할/안 할 파일 요약 → `CLAUDE.md` TODO 채우기 제안 |
| `/api` | `[요구사항 또는 요구사항 파일 경로]` | 가능 | 웹: 요구사항 재진술 → 기존 패턴 확인 → 엔드포인트 명세 표 → 플랜 승인 → 구현 → 테스트(성공·검증 실패·401/403·경계값) → 보고 |
| `/preflight` | `[base-ref]` | 수동 | 웹: PR 전 점검. 변경 분류, 마이그레이션 누락, env 키와 `.env.example` 비교, 시크릿 스캔, lockfile 동기화, OpenAPI 갱신 → PR 체크리스트 결과 + PR 본문 초안 |

- `review-diff`로 이름 지은 이유: `/review`는 내장 `/code-review`의 별칭이라 겹친다.
- 수동 스킬은 `disable-model-invocation: true`. 모델이 임의로 커밋·설치하지 않는다. 규칙·스킬 본문도 모델에게 수동 스킬(`/commit`, `/review-diff`, `/preflight`, `/harness-*`) 실행을 지시하지 않고, 사용자에게 실행을 제안하거나 절차를 직접 적는다.
- 스킬 본문이 미리 실행하는 셸 주입 명령(예: `"${CLAUDE_SKILL_DIR}/context.sh"`)은 `allowed-tools`에 같은 따옴표 형태(`'Bash("${CLAUDE_SKILL_DIR}/context.sh" *)'`, YAML 작은따옴표)와 따옴표 없는 형태를 함께 둔다. 홈 경로에 공백이 있어도 권한 검사에서 막히지 않게 하려는 것이다.
- `allowed-tools`는 스킬을 부른 턴에만 유효하다. 사용자 응답 뒤에 실행하는 `git add`·`git commit`·`apply.sh`에는 일반 권한 프롬프트가 뜰 수 있다.

### 4.7 프로필 4개 (선택형 add-on, 기본 적용 없음)

| 프로필 | 규칙 파일 | `paths` | 내용 |
|---|---|---|---|
| `python` | `python.md` | `**/*.py`, `**/pyproject.toml` | lockfile 기준 패키지 관리자(명령 예시는 uv), pyproject 포매터·린터 준수, 타입 힌트, Google 스타일 docstring(언어는 프로젝트 관례), 로깅, 예외, pytest |
| `django` | `django.md` | `**/*.py`, `**/templates/**` | 레이어 분리, Serializer 검증, 권한, N+1, DRF 예외, 마이그레이션, `extend_schema`, `APITestCase` |
| `fastapi` | `fastapi.md` | `**/*.py` | Pydantic v2, `response_model`, 라우터 분리, `Depends`, lifespan, async 경계, `pydantic-settings`, Alembic |
| `node` | `typescript.md` | `**/*.{ts,tsx,js,jsx,mjs,cjs}`, `package.json`, `tsconfig.json` | lockfile 기준 패키지 매니저, strict TS, async 에러 처리, 로거, 환경 변수 검증, 테스트 |

- 규칙은 `paths`에 맞는 파일을 읽거나 편집할 때만 로드된다.
- 각 프로필의 `settings.fragment.json`은 그 스택의 검사·테스트(·빌드, lockfile 동기화) 명령 allow를 프로젝트 `.claude/settings.json`에 병합한다. 포맷 적용·마이그레이션 생성처럼 소스를 바꾸는 명령 형태는 넣지 않는다:
  - python: `uv run pytest *`, `uv run ruff check *`, `uv run ruff format --check *`, `uv run mypy *`, `uv sync *`; 소스를 고치는 `uv run ruff check --fix …`는 ask 규칙으로 확인을 받는다. 포맷 적용은 일반 권한 프롬프트나 포맷 훅으로 한다. 규칙은 uv 전용이라 poetry·pipenv 프로젝트에서는 맞는 allow가 없어 일반 프롬프트가 뜬다.
  - django: `uv run python manage.py makemigrations --check --dry-run *`(Django 4.2 미만에서 `--check`만 쓰면 파일을 만든다).
  - node: `npm run typecheck *` 등 스크립트 명령과 `npx --no-install tsc *`·`eslint`·`prettier --check`·`vitest run`·`jest`. `npx <도구>`는 로컬에 없으면 레지스트리에서 받아 실행하므로 `--no-install` 형태만 허용한다.
- `--profile auto` 매핑: `python`→python, `django`→python+django, `fastapi`→python+fastapi, `node`→node. 감지 결과가 없으면 프로필 없이 적용한다.
- `--profile`은 여러 번 줄 수 있다(예: `--profile python --profile django`).

### 4.8 프로젝트 템플릿 (`apply.sh` 결과)

| 커밋할 파일 | 커밋하지 않을 파일 |
|---|---|
| `CLAUDE.md` | `CLAUDE.local.md` (개인 메모) |
| `.claude/settings.json` | `.claude/settings.local.json` (개인 env·권한) |
| `.claude/rules/**` (`project.md`, 프로필 규칙, `--team`이면 `git.md`) | `*.dev_settings.new` (갱신 후보 파일) |
| `.claude/hooks/**` (`--with-format-hook`일 때) | `.claude/agent-memory-local/`, `.claude/worktrees/` |
| 선택: 팀원용 예시(커밋 가능) — `CLAUDE.local.md.example`, `.claude/settings.local.json.example` | |

- `.gitignore`에 `gitignore.claude`의 줄을 중복 없이 추가한다(기존 파일이 CRLF면 CRLF로).
- `CLAUDE.md`나 `.claude/CLAUDE.md`가 이미 있으면 새로 만들지 않는다(내용이 다르면 `CLAUDE.md.dev_settings.new`만 생성).
- `AGENTS.md`만 있으면 첫 줄이 `@AGENTS.md`인 `CLAUDE.md`를 만든다(AGENTS.md는 계속 로드됨). 다시 적용해도 같은 렌더링과 비교하므로 `변경 없음`이고, `--force`도 `@AGENTS.md`를 유지한다.
- 대상 파일이 심볼릭 링크(예: `CLAUDE.md → AGENTS.md`)면 `--force`는 링크 대상을 덮어쓰지 않는다. 대상 내용을 백업하고 링크를 일반 파일로 바꾼다. `.claude/settings.json`이 심볼릭 링크면 병합 결과를 실제 대상에 기록한다.
- `--with-format-hook` 없이 다시 적용하면 PostToolUse 포맷 항목을 뺀다. `.claude/hooks/`의 세 파일(`run-hook.sh`, `format-on-edit.sh`, `lib/common.sh`)이 저장소 사본과 같으면 백업 후 `삭제`한다. 수정된 파일이면 `수정된 훅 파일 — 수동 정리` WARN을 내고, settings.json이 아직 참조하지 않으면 커밋할 파일 목록에서 뺀다.
- `.claude/rules/project.md`: 서브에이전트 보충 규칙(환경 함정, 메인 전용 공유 핫스팟, 검증 명령, 금지 사항) 템플릿.
- 팀 파일(`.claude/**`, `CLAUDE.md`)에 `~/.claude/`나 개인 스킬(`/commit`, `/harness-init`, `/harness-check`, `/preflight`, `/review-diff`, `/delegate`) 언급이 있으면 `validate.sh --project`가 WARN을 낸다.

## 5. ECC 플러그인과의 관계

ECC(everything-claude-code)를 전역으로 켠 PC를 기준으로, 기능이 겹치지 않게 나눴다. 플러그인 훅과 settings 훅은 순서 없이 병렬로 실행된다.

| 영역 | ECC | dev_settings |
|---|---|---|
| 사실 확인 게이트 | GateGuard | — |
| `--no-verify` 차단 | 있음 | `guard-destructive`(ECC 없는 PC용 대비책) |
| 설정 파일 보호 | config-protection | — |
| 편집 후 포맷·린트 | quality-gate(기본은 검사만) | `format-on-edit`(opt-in, ECC가 고치는 모드일 때 그 타입만 건너뜀) |
| `console.log` 검사 | 있음 | — (`typescript.md` 규칙으로 안내) |
| 세션 시작 컨텍스트 | session-start | `session-context`(저장소 상태·스택·보호 브랜치) |
| 비밀 파일·위험 명령·마이그레이션 | — | `guard-secrets` · `guard-destructive` · `guard-migrations` |
| 상태줄 | — | `statusline.sh` |
| 비용 추적·알림·MCP 상태·compact 전 저장 | 있음 | — |

- `--no-verify`는 양쪽이 모두 막으므로 차단 메시지가 두 개 뜰 수 있다.
- GateGuard 끄기: `ECC_GATEGUARD=off`. ECC 개별 훅 끄기: `ECC_DISABLED_HOOKS`(예: `post:quality-gate`).
- 포맷 훅과 ECC: ECC quality-gate는 기본적으로 검사만 하므로 겹치지 않는다. `ECC_QUALITY_GATE_FIX=true`일 때만 해당 타입을 건너뛴다. 정확한 조건은 아래가 모두 맞을 때다:
  - `~/.claude/settings.json`에서 ECC가 켜져 있다(`enabledPlugins`의 `"ecc@ecc": true`).
  - `ECC_QUALITY_GATE_FIX`가 `true`(대소문자 무관)이고, `ECC_HOOK_PROFILE`이 `minimal`이 아니고, `ECC_DISABLED_HOOKS`에 `post:quality-gate`가 없다.
  - 그래도 건너뛰는 것은 ECC가 고치는 타입뿐이다: `.py`(ruff/black), `.go`, prettier/biome 대상 `.ts` `.tsx` `.js` `.jsx` `.json` `.md`. `bash -n`·shfmt·rustfmt·terraform fmt·taplo는 항상 실행한다.
  - `CLAUDE_FORMAT_ON_EDIT=force`면 이 판단 없이 실행한다.

## 6. 커스터마이즈

### 6.1 env 변수

| 변수 | 기본값 | 값과 효과 |
|---|---|---|
| `CLAUDE_HOOKS_DISABLE` | — | `1`: 모든 훅 통과 |
| `CLAUDE_HOOKS_LOG` | — | 파일 경로: 결정 로그 기록 |
| `CLAUDE_HOOKS_DEBUG` | — | `1`: stderr 디버그 |
| `CLAUDE_GUARD_SECRETS` | 켜짐 | `off`: 비밀 파일 가드 끄기 |
| `CLAUDE_GUARD_SECRET_EXTRA` | — | 콜론 구분 glob. hard(차단) 비밀로 추가 |
| `CLAUDE_GUARD_SECRET_ALLOW` | — | 콜론 구분 glob. 파일명·전체 경로가 맞으면 검사 제외. 네이티브 Read deny는 풀지 못한다 |
| `CLAUDE_GUARD_DESTRUCTIVE` | 켜짐 | `off`: 위험 명령 가드 끄기 |
| `CLAUDE_GUARD_PROTECTED_BRANCHES` | `main master`(변수가 없을 때만) | 공백·쉼표 구분 목록, glob 가능(`release/*`). `none`(대소문자 무관)이나 빈 값: 브랜치 규칙 전체 해제. `guard-destructive`·`session-context`·`/commit`이 같은 규칙으로 읽는다(훅은 `hooks/lib/common.sh`의 `hook_is_protected_branch`를 공유) |
| `CLAUDE_GUARD_ASK_ON_PUSH` | `protected` | `protected`: 보호 브랜치 대상·force 푸시만 확인. `1`: 모든 푸시 확인. `0`: force가 아닌 푸시는 보호 브랜치 대상이어도 확인 안 함(force·보호 브랜치 삭제 규칙은 유지) |
| `CLAUDE_GUARD_ALLOW_PATTERNS` | — | `\|`로 이은 ERE. 각각 `^(…)$`로 고정해 세그먼트에 대조. 맞으면 그 세그먼트의 훅 ask를 없앤다(결정 없음 → 일반 권한 규칙이 판단, deny는 그대로). `.*` 주의: refspec·플래그까지 맞는다 |
| `CLAUDE_GUARD_MIGRATIONS` | 켜짐 | `off`: 마이그레이션 가드 끄기 |
| `CLAUDE_SESSION_CONTEXT` | 켜짐 | `off`: 세션 컨텍스트 끄기 |
| `CLAUDE_FORMAT_ON_EDIT` | 켜짐(opt-in 프로젝트) | `off` 끄기, `force` ECC 판단 무시(5절) |
| `CLAUDE_FORMAT_TIMEOUT` | `20` | 포매터 제한 시간(초) |
| `CLAUDE_STATUSLINE_COLOR` | 켜짐 | `0`: ANSI 색 끄기. `NO_COLOR`도 인식. UTF-8 로케일이 아니면 구분자 `\|`·`git:` ASCII 표시 |

- 설정 위치: 개인 전역은 `~/.claude/settings.json`의 `env`, 프로젝트 개인용은 `.claude/settings.local.json`의 `env`, 팀 공통은 `.claude/settings.json`의 `env`.
- `env` 블록은 변수를 확장하지 않는다(`~`, `$HOME`이 글자 그대로 들어감). 프로젝트 `env`는 워크스페이스 신뢰 후 적용된다.

개인 저장소에서 보호 브랜치 규칙을 끄는 예(`.claude/settings.local.json`, `apply.sh`가 복사한 `settings.local.json.example`에서 시작):

```json
{
  "env": {
    "CLAUDE_GUARD_PROTECTED_BRANCHES": "none"
  }
}
```

모든 푸시를 확인하되 feature 브랜치 푸시만 훅 확인에서 빼는 예:

```json
{
  "env": {
    "CLAUDE_GUARD_ASK_ON_PUSH": "1",
    "CLAUDE_GUARD_ALLOW_PATTERNS": "git push origin feature/[A-Za-z0-9._/-]+"
  }
}
```

- 패턴의 `.*`는 refspec(`feature/x:main`, `feature/x main`)과 `--force`까지 허용한다. 공백·콜론·`+`가 들어가지 않는 문자 클래스로 쓴다.
- 패턴이 맞아도 훅 확인만 없어진다. `git push`가 allow 규칙에 없으면 `default` 모드에서는 일반 권한 프롬프트가 뜬다.

### 6.2 규칙·프로필·비밀 패턴

- **프로젝트 규칙 추가**: `<프로젝트>/.claude/rules/<이름>.md`. 특정 파일에만 적용하려면 frontmatter에 `paths`를 둔다(Claude Code가 읽는 유일한 필드).
- **전역 규칙 추가**: `claude/global/rules/`에 파일을 만들고 `./install.sh` 재실행. `~/.claude/rules/`를 직접 고치지 않는다.
- **프로필 추가**: `profiles/<이름>/rules/<규칙>.md`(`paths` 필수, 60줄 이내)와 `profiles/<이름>/settings.fragment.json`을 만든다. `apply.sh`의 프로필 목록과 `--profile auto` 매핑(`claude/global/hooks/lib/detect-stack.sh`)에도 추가한다.
- **비밀 패턴**: 훅이 전체 목록을, Read deny가 그 핵심 부분집합을 강제한다.
  - 훅: `claude/global/hooks/lib/secret-patterns.txt` + `guard-secrets.sh`의 경로 규칙.
  - 네이티브: `claude/global/settings.json`의 Read deny — .env 주요 변형·키·인증서·SSH·클라우드 자격 증명·CLI 도구 토큰(gh, Vault, cargo, Terraform, Hugging Face, Azure). `.env.*` 전체를 deny하면 `.env.example`까지 막히므로 나눠 둔다. `*.env`(`prod.env` 류)도 `sample.env` 같은 예제가 막히지 않게 훅에만 둔다(`CLAUDE_GUARD_SECRET_ALLOW`로 제외 가능).
  - 훅을 끄거나(`CLAUDE_GUARD_SECRETS=off`) 훅이 fail-open이면 훅 전용 패턴(`.env.test`, `*.env`, `.env~`, `.env_*`, `*.ppk`, `.pgpass` 등)은 보호받지 못한다.
  - `.env.*`에서 제외하는 것은 `.example`·`.sample`·`.template`·`.dist`다. 한쪽을 바꾸면 다른 쪽도 검토한다.

## 7. 설치 동작

```
./install.sh [--dry-run] [--force] [--no-settings] [--home <dir>] [--uninstall] [--restore <타임스탬프>] [--yes]
./apply.sh <프로젝트> [--profile python|django|fastapi|node|auto]... [--with-format-hook] [--force] [--dry-run] [--team] [--yes]
```

- **복사 방식만 지원**(심볼릭 링크 없음). 저장소에서 편집 중인 훅이 열린 모든 세션에 즉시 반영되는 사고를 막고, 설치본 수정 여부를 cksum으로 추적하기 위해서다.
- **파일별 계획**: `create`(새 파일) · `update`(지난 설치 후 손대지 않은 파일 갱신) · `skip-identical` · `keep-user-edited`(사용자가 고친 파일 유지 + 옆에 `<파일>.dev_settings.new` 생성 + WARN) · `conflict`(매니페스트에 없는 기존 파일, `--force` 없으면 유지 + `.new`) · `remove-stale`(저장소에서 사라진 파일, 손대지 않았으면 백업 후 삭제).
- **사용자가 지운 관리 파일**: 매니페스트에 있는데 사용자가 지운 파일(예: `rules/web.md`)은 `유지(사용자 삭제) <경로>`로 표시하고 다시 만들지 않는다. `--force`면 다시 만든다(settings 관리 규칙과 같은 정책).
- **트랜잭션**: 임시 stage 디렉터리에 전부 준비 → `bash -n`·JSON 검사 → 바뀔 파일만 백업 → 배치 → `settings.json`은 마지막에 같은 디렉터리 임시 파일에서 `mv`로 교체(심볼릭 링크면 실제 대상에 기록, 설치 중 변경되면 중단) → 매니페스트 기록. 중간 실패·중단 시 이번 백업으로 되돌린다(심볼릭 링크였던 파일은 백업에 남긴 링크 텍스트로 같은 링크를 다시 만든다 — `--restore`도 같다). 되돌리기에 실패한 파일이 있으면 백업을 지우지 않고 `--restore` 명령을 안내한다. stage 디렉터리는 어떤 경우에도 지운다.
- **settings 병합**(`scripts/merge-settings.py`): 사용자 키 보존(4.1 목록), permission 목록은 합집합, 훅은 매처 정규화(`Edit|Write` = `Write|Edit`)와 명령 기준 중복 제거, 사용자가 지운 관리 규칙은 `--force` 없이는 다시 넣지 않는다. 엄격한 JSON만 읽는다(JSONC 주석 불가). 엄격한 JSON이 아니면 파일을 배치하기 전에 위치(line·col)를 알리고 exit 1로 멈춘다.
- **백업**: `~/.claude/backups/dev_settings/<YYYYmmdd-HHMMSS>.XXXXXX/`(최근 10개 유지). apply 백업은 `~/.claude/backups/dev_settings/apply/<프로젝트명>/`.
- **매니페스트**: `~/.claude/dev_settings.manifest.json`(설치 파일별 cksum, 저장소 커밋, settings 기여분), `~/.claude/dev_settings.repo`(저장소 경로).
- `--dry-run`: 아무것도 쓰지 않고 계획과 settings diff만 출력. `--uninstall`·`--restore`와 함께 쓰면 지울·되돌릴 파일 목록(제거는 settings diff 포함)만 출력하고 홈은 그대로 둔다.
- `--uninstall`: 매니페스트의 파일과 관리 settings 항목을 백업 후 제거. 사용자가 고친 파일과 사용자 키는 남긴다. 설치가 추가한 `$schema`와 비어 있는 `skills/` 디렉터리도 정리한다.
- `--restore <타임스탬프>`: 해당 백업 디렉터리 내용을 되돌린다. 설치 요약에 정확한 명령이 출력된다.
- `--home <dir>`: 다른 홈에 설치(테스트용). 빈 값(`--home ''`)은 사용법 오류. `--no-settings`: settings 병합 생략.
- **확인과 `--yes`**(install.sh):
  - 대화형 터미널(stdin이 TTY)에서는 진행 전에 `[y/N]`을 묻는다. `--yes`(`-y`)면 묻지 않는다.
  - 비대화형 실행(CI, 파이프, Claude의 Bash 도구)에서 추가형 설치는 묻지 않고 진행한다(바뀌는 파일은 백업).
  - 비대화형에서 파괴적 작업(`--uninstall`, `--restore`, 업그레이드의 `remove-stale` 삭제, `--force` 덮어쓰기)은 `--yes`가 있어야 한다. 없으면 `확인이 필요한 작업(<작업>) — 비대화형 실행이면 --yes 를 지정`을 출력하고 exit 2.
  - apply.sh의 `--force`(백업 후 덮어쓰기)도 같은 규칙이다: 대화형이면 `[y/N]`, 비대화형이면 `--yes`(없으면 exit 2). 그 외 apply.sh 작업은 묻지 않는다.
- `~/.claude/skills/`에서는 이 저장소의 스킬 7개 디렉터리만 다룬다. `learned/`·`synced/` 등 다른 디렉터리는 건드리지 않는다.
- 다시 실행하면 `변경 없음`(새 백업도 만들지 않음).
- 종료 코드:
  - `install.sh`: `0` 성공 · `1` 실패(롤백됨) · `2` 사용법 오류 · `3` 설치됐지만 validate FAIL.
  - `apply.sh`: `0` 성공 · `1` 거부/실패(롤백 없음 — 바뀐 파일만 백업) · `2` 사용법 오류 · `3` 적용됐지만 validate FAIL.
- `install.sh`는 `~/.claude`(심볼릭 링크면 실제 경로)가 이 저장소 안이면 거부한다. `apply.sh`는 대상이 `$HOME`, `~/.claude`(실제 경로 포함) 하위, 이 저장소 자체이면 거부한다.

## 8. 검증

- `scripts/validate.sh --repo | --installed [--home <dir>] | --project <dir>` (`--exit-zero`, `--max-lines N`, `--quiet`)
  - 출력: `OK|WARN|FAIL|INFO <검사>: <내용>`, 요약 `OK n · WARN n · FAIL n`. FAIL이 있으면 exit 1.
  - 검사: JSON 파싱, 스키마에 없는 키(WARN), 훅 이벤트·타입, 훅 스크립트 존재·실행 권한, `statusLine` 형식, 권한 규칙 문법(`Write(...)`·`Bash(x:*)`·공백 없는 와일드카드 `Bash(ls*)` 등 WARN)과 목록 간 중복, Read deny와 `secret-patterns.txt` 동기화, `bash -n`, 에이전트·스킬 frontmatter, 스킬 셸 주입 명령과 `allowed-tools` 규칙 일치(이 저장소 스킬은 FAIL), 규칙 `paths`, 깨진 심볼릭 링크, 템플릿 이름(`claude/` 아래 `CLAUDE.md`·`.claude/` 금지), 설치본과 저장소 커밋 차이.
  - `--project`는 팀 공유 파일의 개인 설정 참조(`CLAUDE.local.md`로 옮길 것)와 공유 설정·훅이 gitignore에 걸리는지도 본다.
  - `--repo`는 `merge-settings.py --selftest`와 `tests/run-all.sh`도 실행한다(`--quiet`면 생략).
- `tests/run-all.sh [--quick] [--filter <부분문자열>] [--verbose]`: 훅 스위트를 `/bin/bash`(3.2)와 PATH의 다른 bash(있으면)로, 설치 스위트와 `merge-settings.py --selftest`를 한 번 실행한다. 실제 `~/.claude` 대신 공백이 들어간 임시 HOME을 쓴다.
  - 훅(`tests/hooks/`): `test-lib-common.sh` · `test-lib-common-2.sh` · `test-lib-parse.sh` · `test-lib-parse-2.sh` · `test-guards-secrets.sh` · `test-guards-secrets-2.sh` · `test-guards-destructive.sh` · `test-guards-destructive-2.sh` · `test-guards-migrations.sh` · `test-guards-migrations-2.sh` · `test-aux-format.sh` · `test-aux-session.sh` · `test-aux-statusline.sh`. `-2` 파일은 검증 라운드에서 추가한 회귀·성능(200 KB heredoc 2초 이내 등) 케이스다. 픽스처는 `tests/hooks/fixtures/`, 공용 함수는 `tests/lib/testlib.sh`.
  - 설치(`tests/install/`): `run.sh`가 `test-install.sh` · `test-install-upgrade.sh` · `test-install-edge.sh` · `test-install-safety.sh` · `test-apply.sh` · `test-apply-edge.sh`를 실행한다(공용 `helpers.sh`). `-edge`·`-safety`는 경계 조건과 실패·롤백·백업 보존 케이스다.
  - 스킬: `tests/skills/test-skills.sh`(context.sh, allowed-tools와 주입 명령 일치, 프로필 fragment). `tests/run-all.sh`가 함께 실행한다.
- 테스트 전용 env(평소에는 설정하지 않는다): `HOOK_FORCE_PARSER=jq|python3|none`(훅 파서 강제), `DEV_SETTINGS_FAIL_AT=<지점>[,<지점>…]`(설치 실패 주입. 지점: `place` `settings` `manifest` `restore`), `DEV_SETTINGS_IN_TESTS=1`(run-all.sh가 설정, `validate.sh --repo`의 재귀 실행 방지), `DEV_SETTINGS_TEST_REPO=<dir>`(설치 스위트를 저장소 사본에 실행).
- CI(`.github/workflows/ci.yml`): push·PR마다 세 작업에서 `tests/run-all.sh`, `validate.sh --repo --quiet`, 비밀·이메일 패턴 검사를 실행한다.
  - ubuntu-latest 두 작업: bash 5와 GNU 도구에 awk를 gawk·mawk로 하나씩 고정한다.
  - macos-latest: `/bin/bash` 3.2와 Homebrew bash 5(run-all.sh가 둘 다 실행), BSD awk.
- `scripts/update-schema.sh`: schemastore에서 스키마를 받아 추가·삭제된 키와 훅 이벤트를 보여주고 스냅샷을 교체한다. 실행 후 이 README의 검증 기준 날짜를 갱신한다.

## 9. 파일 이력

| 이전 경로 | 현재 위치 | 사유 |
|---|---|---|
| `settings.json` | `vscode/settings.json` | VS Code 설정임을 명확히(끝 쉼표 오류 수정) |
| `copilot-instructions.md.example` | `copilot/copilot-instructions.md` | 도구별 디렉터리로 정리 |
| `agents/explorer.md` · `implementer.md` · `reviewer.md` | `claude/global/agents/` | 설치 구조(`~/.claude/agents/`)와 일치 |
| `agents/subagent-policy.md` | `claude/global/rules/subagent-policy.md` | 에이전트 정의가 아니라 항상 로드되는 규칙 |
| `CLAUDE.md.example` | `claude/project-template/CLAUDE.md.tmpl` + `profiles/python`·`profiles/django` 규칙 + `claude/global/rules/git.md`로 증류 후 삭제 | 특정 프로젝트 가이드를 범용 템플릿·선택형 프로필로 분리 |
| `request.md.example` | `claude/global/rules/core.md`(요청 재진술)와 `/api` 스킬로 흡수 후 삭제 | 요청 양식을 규칙과 워크플로로 일반화 |

## 10. 알려진 제한

- **Bash 권한 규칙과 훅은 보안 경계가 아니다.** 네이티브 `Bash(...)` 접두사 규칙은 `/bin/rm`, `bash -c '…'`, `git -C . push`로 우회된다. 가드 훅은 이를 보완하는 휴리스틱 파서(따옴표·heredoc·`sh -c` 1단계)라 변수 조합·스크립트 내부·인코딩으로 우회할 수 있다. 확실한 경계가 필요하면 sandbox를 쓴다.
- **fail-open**: 파서(`jq`/`python3`)가 없거나 훅이 실패하면 통과한다. 핸들러에 `"onFailure": "block"`(2.1.295+)을 추가하면 런처를 시작하지 못할 때, 훅이 timeout(10초)을 넘길 때, 출력 JSON이 깨졌을 때 도구 호출이 막힌다. 런처가 항상 exit 0이므로 훅 내부 오류는 여전히 통과하고, `jq`/`python3`가 없을 때도 결정 없이 통과(fail-open)한다.
- PreToolUse 훅은 `@파일` 멘션과 IDE 컨텍스트(열린 파일·선택 영역)에는 실행되지 않는다. 이 경로에는 Read deny만 적용된다(best-effort).
- Read deny는 `cat`·`head`·`tail`·`sed`·리디렉션 등 Claude Code가 인식하는 Bash 명령에만 적용된다. `grep -r`이나 스크립트 내부 읽기는 `guard-secrets`가 일부만 잡는다.
- Read deny가 Write·Edit도 막으므로 Claude가 `.env`를 직접 만들 수 없다. `cp .env.example .env`(확인 후 실행)를 쓰거나 사용자가 만든다.
- `statusLine`은 CLI와 VS Code 통합 터미널에서 확인했다. 확장 패널 UI에서는 표시되지 않을 수 있다.
- 사용자(전역) 규칙과 프로젝트 규칙이 충돌하면 Claude가 어느 쪽을 따를지 보장되지 않는다. 프로젝트 `CLAUDE.md`에 명시적으로 적는다.
- 스키마 스냅샷에 문서화된 키 일부(`modelSettings` 등 약 48개)가 없다. 스키마가 `additionalProperties: true`라 오류는 아니며, `validate.sh`는 알려진 키를 예외로 두고 나머지를 WARN으로 알린다.
- `--link`(심볼릭 링크 설치) 모드는 없다. 저장소를 고친 뒤 `./install.sh`를 다시 실행한다.
- Windows는 검증하지 않았다.

## 11. 다음 단계

- Stop 훅: 검증하지 않고 완료를 보고하면 알림
- SubagentStop 훅: 서브에이전트가 소유 파일 밖을 바꿨는지 검사
- sandbox 프로필(파일·네트워크 경계)
- 에이전트 memory(`memory: project`) 운용 지침
- 플러그인 패키징(마켓플레이스 배포)
- `.worktreeinclude` 지원 검토(워크트리 생성 시 gitignore된 로컬 파일 복사)
