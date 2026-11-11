# 구성 요소: 규칙·에이전트·스킬·프로필

[← README](../README.md)

훅은 [hooks.md](hooks.md), 전역 `settings.json`·프로젝트 템플릿·플러그인 배포판은 [install.md](install.md)에 있다.

## 1. 규칙 6개 (`~/.claude/rules/`, 모두 항상 로드)

| 파일 | 내용 |
|---|---|
| `core.md` | 검증한 것만 완료 보고, 추측 금지, 요청 범위 준수, 복잡한 요청은 목표·요구사항·유의사항·완료 조건으로 재진술 후 플랜, 완료 보고 형식 |
| `git.md` | `<gitmoji> scope: subject` 커밋 형식(유니코드 gitmoji, 예 `✨ api: …`)과 gitmoji 표, 브랜치 모델, 보호 브랜치, force push·`--no-verify`·`git add -A` 금지, PR 체크리스트·본문 형식 |
| `security.md` | 비밀 파일·값 취급, 마스킹, 운영 접근 금지, 외부 전송 금지 항목, 차단 우회 금지 |
| `web.md` | 웹 솔루션 공통: API 설계, 인증·인가, 데이터·마이그레이션 안전, 관측, 설정, 테스트 계층, 프런트, 보안·성능, 문서 |
| `subagent-policy.md` | 메인 직접 vs 위임 기준, 분할·배정, 위임 프롬프트 7항목, 결과 검증, 모델 배정 |
| `plugins.md` | 작업별로 쓸 플러그인(코드 구현 superpowers, 프런트 화면 Impeccable), 기존 규칙과 부딪힐 때의 우선순위, 설치돼 있지 않을 때의 동작. 상세는 6절 |

우선순위: 사용자 지시 > 프로젝트 `CLAUDE.md`·`.claude/rules` > 전역 rules. 전역 `CLAUDE.md`는 이 규칙과 스킬 목록을 한 줄씩 안내하고, 프로젝트에 `CLAUDE.md`가 없으면 `/harness-init`을 제안하게 한다.

## 2. 에이전트 3개 (`~/.claude/agents/`)

| 에이전트 | 도구 | model · effort | 역할 |
|---|---|---|---|
| `explorer` | Read, Grep, Glob | sonnet · medium | 읽기 전용 조사, 결론과 근거(경로:라인)만 보고 |
| `implementer` | Read, Grep, Glob, Edit, Write, Bash | opus · high | 지정한 소유 파일 안에서만 구현. git·의존성·마이그레이션·운영 접근 금지 |
| `reviewer` | Read, Grep, Glob | opus · xhigh | 보고 전용 리뷰. 코드 수정 금지 |

- 세 에이전트 모두 `disallowedTools: mcp__*`, `omitClaudeMd: true`.
- **컨텍스트 비용**: 공식 문서(sub-agents "What loads at startup")에 따르면 서브에이전트는 메인 대화가 읽는 CLAUDE.md 계층 전체(`~/.claude/CLAUDE.md`, 프로젝트 rules, `CLAUDE.local.md` 포함)를 읽는다.
  - 빌트인 Explore·Plan은 읽지 않고(정책 §2), `omitClaudeMd`(2.1.271+)를 둔 에이전트는 관리 정책 파일만 읽는다.
  - 이들도 하위 디렉터리 `CLAUDE.md`와 맞는 경로 범위 규칙은 그 디렉터리 파일을 다룰 때 읽는다.
  - `~/.claude/rules/`가 서브에이전트에 실리는지는 문서에 명시되지 않았다(미문서화).
  - 실린다면 general-purpose·플러그인 에이전트를 띄울 때마다 `subagent-policy.md`(약 14KB, 4~5K 토큰) 비용이 든다.
  - 정책을 항상 적용하는 대가로 감수한 선택이다.

### 2.1 에이전트 memory 운용

서브에이전트 frontmatter의 `memory`는 그 에이전트가 실행 사이에 기억을 남기게 한다. **세 에이전트 정의에는 넣지 않았다**(기본 미사용, 정책 §4). 이유는 두 가지다.

- 켜면 Read·Write·Edit가 자동으로 켜진다(공식 문서). `explorer`·`reviewer`가 `tools: Read, Grep, Glob`으로 보장하던 읽기 전용이 규칙으로만 지켜진다. `tools` 제한과 자동 활성화 중 무엇이 우선하는지는 문서에 없다.
- `MEMORY.md`의 앞 200줄 또는 25KB가 실행할 때마다 시스템 프롬프트에 들어간다. 틀린 기억이나 "항상 ~한다" 같은 지시문이 한 번 들어가면 이후 실행을 계속 바꾼다.

| 값 | 위치 | 커밋 | 쓰는 경우 |
|---|---|---|---|
| `project` | `<프로젝트>/.claude/agent-memory/<에이전트>/` | 한다(팀 공유, PR에서 리뷰) | 권장. 이 저장소에만 해당하는 지식 |
| `local` | `<프로젝트>/.claude/agent-memory-local/<에이전트>/` | 하지 않는다(`gitignore.claude`가 제외) | 혼자 시험해 볼 때 |
| `user` | `~/.claude/agent-memory/<에이전트>/` | 해당 없음 | 비권장. 프로젝트 사이에 내용이 섞인다 |

켜는 방법(프로젝트 단위, 사용자 승인 후):

1. 전역 정의를 프로젝트로 복사한다: `~/.claude/agents/reviewer.md` → `<프로젝트>/.claude/agents/reviewer.md`. 같은 이름이면 프로젝트 정의가 전역 정의보다 우선한다.
2. frontmatter에 `memory: project`를 더한다.
3. 본문에 기억 관리 문단을 더한다. 예:

   ```text
   memory
   - 시작할 때 memory에서 이 저장소의 반복 지적·환경 함정을 확인한다.
   - 끝낼 때 다음 실행에도 쓸 사실만 한 줄씩 더한다: 저장소에서 바로 알 수 없는 것(반복되는 실수 유형, 모듈 사이의 숨은 의존, 느린 테스트).
   - 적지 않는다: 비밀 값·고객 정보·내부 호스트, 코드 원문, 이번 작업의 진행 상태, 작업 지시("항상 ~한다").
   - MEMORY.md는 200줄 안의 색인으로 유지하고 세부는 주제별 파일로 나눈다. 틀린 항목은 고치지 말고 지운다.
   - memory 디렉터리 밖의 파일은 수정하지 않는다.
   ```

운용 규칙:

- 기억에는 저장소에서 알 수 없는 사실만 둔다(`core.md`의 메모리 원칙과 같다). 코드·문서·git 이력으로 확인되는 내용은 적지 않는다.
- 기억은 근거가 아니다. 에이전트 보고의 근거는 계속 경로:라인으로 받는다.
- `.claude/agent-memory/**`는 커밋 대상이므로 PR에서 사람이 읽는다. 지시문 형태의 항목과 비밀 값·고객명·내부 호스트는 지운다.
- 읽기 전용 에이전트에 켰다면 위임 프롬프트에 `소유 파일 없음(읽기 전용)`을 적는다. `subagent-scope` 훅이 memory 디렉터리 밖의 수정을 알린다(memory 디렉터리의 파일은 세지 않는다).
- `implementer`에 켰다면 정의 본문의 "에이전트 규칙 파일(.claude/**)은 위임 프롬프트에 명시된 경우에만 수정" 항목에 자기 memory 디렉터리를 예외로 적는다.
- 메인 세션의 `autoMemoryEnabled: false`(또는 `CLAUDE_CODE_DISABLE_AUTO_MEMORY`)는 서브에이전트 memory도 끈다(공식 문서).
- `validate.sh --project`는 `agent-memory`·`agent-memory-local` 아래 파일을 개인 설정 참조 검사에서 뺀다.

## 3. 스킬 7개 (`~/.claude/skills/`)

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

## 4. 프로필 5개 (선택형 add-on, 기본 적용 없음)

언어 프로필 4개와 `sandbox` 프로필(4.1절)이다.

| 프로필 | 규칙 파일 | `paths` | 내용 |
|---|---|---|---|
| `python` | `python.md` | `**/*.py`, `**/pyproject.toml` | lockfile 기준 패키지 관리자(명령 예시는 uv), pyproject 포매터·린터 준수, 타입 힌트, Google 스타일 docstring(언어는 프로젝트 관례), 로깅, 예외, pytest |
| `django` | `django.md` | `**/*.py`, `**/templates/**` | 레이어 분리, Serializer 검증, 권한, N+1, DRF 예외, 마이그레이션, `extend_schema`, `APITestCase` |
| `fastapi` | `fastapi.md` | `**/*.py` | Pydantic v2, `response_model`, 라우터 분리, `Depends`, lifespan, async 경계, `pydantic-settings`, Alembic |
| `node` | `typescript.md` | `**/*.{ts,tsx,js,jsx,mjs,cjs}`, `**/package.json`, `**/tsconfig.json` | lockfile 기준 패키지 매니저, strict TS, async 에러 처리, 로거, 환경 변수 검증, 테스트 |

- 규칙은 `paths`에 맞는 파일을 읽거나 편집할 때만 로드된다.
- 각 프로필의 `settings.fragment.json`은 그 스택의 검사·테스트(·빌드, lockfile 동기화) 명령 allow를 프로젝트 `.claude/settings.json`에 병합한다. 포맷 적용·마이그레이션 생성처럼 소스를 바꾸는 명령 형태는 넣지 않는다:
  - python: `uv run pytest *`, `uv run ruff check *`, `uv run ruff format --check *`, `uv run mypy *`, `uv sync *`, `pytest *`; 소스를 고치는 `uv run ruff check --fix …`·`ruff check --fix …`는 ask 규칙으로 확인을 받는다. 포맷 적용은 일반 권한 프롬프트나 포맷 훅으로 한다. `poetry run …`·`pipenv run …` 형태는 맞는 allow가 없어 일반 프롬프트가 뜬다.
  - django: `uv run python manage.py check *`·`showmigrations *`·`test *`·`makemigrations --check --dry-run *`(Django 4.2 미만에서 `--check`만 쓰면 파일을 만든다).
  - fastapi: `uv run alembic history *`·`current *`·`check *`.
  - node: `npm run typecheck *` 등 스크립트 명령과 `npx --no-install tsc *`·`eslint`·`prettier --check`·`vitest run`·`jest`. `npx <도구>`는 로컬에 없으면 레지스트리에서 받아 실행하므로 `--no-install` 형태만 허용한다.
- `--profile auto` 매핑: `python`→python, `django`→python+django, `fastapi`→python+fastapi, `node`→node. 감지 결과가 없으면 프로필 없이 적용한다. `--profile`을 생략하면 공통 템플릿만 적용하고, 감지된 스택이 있으면 `--profile auto`가 적용할 프로필을 `힌트:` 줄로만 알린다(규칙 파일이 이미 있는 프로필은 따로 밝힌다).
- `--profile`은 여러 번 줄 수 있다(예: `--profile python --profile django`).

### 4.1 `sandbox` 프로필

`apply.sh <프로젝트> --profile sandbox`는 그 프로젝트에서 Bash 명령을 OS 샌드박스(macOS Seatbelt, Linux·WSL2 bubblewrap) 안에서 실행하게 한다. 훅은 명령을 어림으로 읽지만 샌드박스는 OS가 강제하므로, 훅이 놓친 명령도 경계 밖에는 닿지 못한다. 언어와 무관하고 `--profile auto`는 고르지 않는다. 언어 프로필과 함께 줄 수 있다(`--profile python,sandbox`).

프로젝트 `.claude/settings.json`에 병합하는 값(`profiles/sandbox/settings.fragment.json`):

| 키 | 값 | 뜻 |
|---|---|---|
| `sandbox.enabled` | `true` | Bash·Monitor와 그 자식 프로세스를 샌드박스 안에서 실행한다 |
| `sandbox.autoAllowBashIfSandboxed` | `false` | 승인 흐름을 바꾸지 않는다. 기본값 `true`는 샌드박스 안 명령을 프롬프트 없이 실행한다 |
| `sandbox.filesystem.denyRead` | `~/.ssh` `~/.aws` `~/.config/gcloud` `~/.azure` `~/.kube` `~/.gnupg` `~/.docker/config.json` | 샌드박스 안 명령이 운영 자격 증명을 읽지 못한다 |
| `permissions.ask` | `Bash(dangerouslyDisableSandbox:true)` | 샌드박스 밖 재실행은 `auto`·`bypassPermissions`에서도 확인받는다 |

- 샌드박스의 기본 경계(공식 문서): 쓰기는 작업 디렉터리와 사용자 임시 디렉터리, 읽기는 디스크 전체, 네트워크는 허용 도메인만이다. 기본값은 자격 증명 파일 읽기를 막지 않으므로 `denyRead`를 더했다.
- 권한 규칙도 샌드박스 경계에 합쳐진다(공식 문서): `Read(...)`·`Edit(...)` deny 규칙은 샌드박스 안 명령에도 적용되고, `Edit(...)` allow는 쓰기 허용, `WebFetch(domain:…)` allow는 허용 도메인이 된다. 전역 설정을 설치했다면 그 Read deny 목록(`.env`·키·토큰 등)이 샌드박스 안 `cat`·`grep`에도 적용된다.
- `autoAllowBashIfSandboxed`를 `false`로 둔 이유: `true`일 때 훅의 확인 요청(ask)이 유지되는지 공식 문서에 없다. 프롬프트를 줄이려면 `true`로 바꾼다. 이때도 `Bash(...)` deny 규칙과 내용이 있는 ask 규칙(`Bash(git push *)`)은 적용된다(공식 문서).
- 규칙 파일 `sandbox.md`(`paths` 없음, 항상 로드): 실패하면 오류 원문을 보고하고, 샌드박스 밖 재실행은 꼭 필요할 때만 요청하고, 경계를 넓히는 설정은 직접 고치지 않고 제안하게 한다.
- 프로젝트에 `sandbox` 값이 이미 있으면 그 값을 유지하고 없는 키만 더한다(다른 프로필 조각과 같은 병합 규칙).
- 경계를 넓히거나 좁히는 방법은 [customization.md](customization.md) 3절, 제한은 [limitations.md](limitations.md) 8절에 있다.

## 5. ECC 플러그인과의 관계

ECC(everything-claude-code)를 전역으로 켠 PC를 기준으로, 기능이 겹치지 않게 나눴다. 플러그인 훅과 settings 훅은 순서 없이 병렬로 실행된다.

| 영역 | ECC | ai_boilerplate |
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

## 6. 함께 쓰는 플러그인: superpowers · Impeccable

`rules/plugins.md`는 두 플러그인이 설치돼 있을 때 작업 종류에 맞춰 쓰게 하는 규칙이다. 이 저장소는 두 플러그인을 설치하거나 켜지 않는다. 둘 다 제3자가 만든 플러그인이고 자체 훅을 실행하므로 설치는 사용자가 정한다.

| 작업 | 플러그인 | 설치(Claude Code 세션에서) | 라이선스 · 훅 |
|---|---|---|---|
| 코드 구현(기능 추가·변경, 버그 수정, 리팩터링) | [superpowers](https://github.com/obra/superpowers) | `/plugin install superpowers@claude-plugins-official` | MIT · SessionStart |
| 프런트 화면(UI·스타일·레이아웃·문구) | [Impeccable](https://github.com/pbakaus/impeccable) | `/plugin marketplace add pbakaus/impeccable` 뒤에 `/plugin install impeccable@impeccable` | Apache-2.0 · SessionStart · PostToolUse · Stop |

- **superpowers**: 설계 문답 → 계획 → 구현(TDD) → 리뷰로 이어지는 구현 흐름이다. 스킬 이름에 `superpowers:`가 붙는다.
- **Impeccable**: 흔한 AI 생성 화면의 특징(Inter 일색, 보라색 그라디언트, 카드 중첩 등)을 피하게 하는 디자인 스킬이다. `critique`·`audit`·`polish` 같은 명령과 규칙 기반 검사기가 있고, 프레임워크와 무관하게 기존 화면·컴포넌트에 쓴다.
- 한 작업에 화면과 로직이 함께 있으면 화면은 Impeccable, 로직과 테스트는 superpowers 흐름을 따른다.

기존 규칙과의 우선순위:

| 부딪히는 지점 | 따르는 쪽 |
|---|---|
| superpowers가 테스트 통과마다 커밋하고 워크트리·브랜치를 만든다 | `git.md`. 사용자가 요청했거나 계획을 승인하면서 허락한 경우에만 한다 |
| superpowers가 서브에이전트를 띄운다 | `subagent-policy.md`의 위임 프롬프트 7항목과 결과 검증 |
| superpowers의 설계 문답 vs `core.md`의 '질문은 막혔을 때만' | 구현 작업에서는 superpowers의 문답 |
| 완료 보고 | `core.md` 형식 |
| ECC 등 다른 플러그인에 비슷한 스킬(계획·TDD)이 있다 | 구현에는 superpowers를 먼저 쓴다 |

- 설치돼 있지 않으면 세션에서 한 번만 설치 명령을 알리고 플러그인 없이 진행한다.
- 이 규칙을 쓰지 않으려면 `~/.claude/rules/plugins.md`를 지운다. `install.sh`는 사용자가 지운 관리 파일을 `--force` 없이는 다시 만들지 않는다.
- 플러그인 배포판에는 규칙이 실리지 않으므로 이 규칙도 없다.
- Impeccable의 Stop 훅과 이 저장소의 `stop-verify`가 모두 응답이 끝날 때 실행된다. 플러그인 훅과 settings 훅은 순서 없이 병렬로 실행된다.
- 스킬 이름과 설치 명령은 2026-11-11 기준이다(superpowers 7.0.2, Impeccable 4.8.2). 확인하지 못한 점은 [limitations.md](limitations.md) 8.4절에 있다.
