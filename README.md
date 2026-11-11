# AI BOILERPLATE

Claude Code 전역 하네스(설정·훅·규칙·에이전트·스킬)와 프로젝트 템플릿을 한 저장소에서 관리하는 보일러플레이트다. 언어·프레임워크와 무관하게 동작하고, 언어별 규칙은 원할 때만 프로필로 얹는다.

## 1. 무엇을 해 주나

| 하는 일 | 수단 |
|---|---|
| 위험한 동작을 막거나 실행 전에 확인받는다 | 가드 훅 3개: 비밀 파일 · 위험 명령 · 마이그레이션 |
| 놓치기 쉬운 것을 알려 준다 | 알림 훅 2개(검증 없는 완료 보고 · 서브에이전트의 범위 밖 수정), 세션 시작 컨텍스트, 상태줄 |
| 작업 방식을 맞춘다 | 규칙 5개, 에이전트 3개, 스킬 7개 |
| 프로젝트마다 같은 틀을 적용한다 | 프로젝트 템플릿과 선택형 프로필(`python` · `django` · `fastapi` · `node` · `sandbox`) |

설치하면 이렇게 달라진다.

| 명령 | 결과 |
|---|---|
| `cat .env`, `rm -rf ~`, `git push --force origin main`, `git commit --no-verify` | 차단 |
| `git push origin main`, `kubectl delete …`, `make deploy`, `sudo …`, 기존 마이그레이션 수정 | 실행 전 확인 |
| 서브에이전트의 마이그레이션 생성·적용·수정 | 차단 |
| 파일을 고치고 테스트 없이 "완료"라고 보고 | 사용자에게 알림 |

## 2. 빠른 시작

```bash
git clone https://github.com/bhnvx/ai_boilerplate.git ~/vsc/ai_boilerplate
cd ~/vsc/ai_boilerplate
./install.sh --dry-run   # 파일별 계획과 settings diff만 출력(아무것도 쓰지 않음)
./install.sh             # ~/.claude 에 설치(백업·매니페스트 포함)
```

1. Claude Code를 재시작한다(훅·규칙·스킬은 세션 시작 때 로드).
2. 아무 세션에서 `/harness-check` → FAIL이 없는지 확인한다.
3. 프로젝트에 적용한다. 둘 중 하나:
   - 터미널: `./apply.sh ~/vsc/<프로젝트> --profile auto`
   - 해당 프로젝트 세션: `/harness-init` (스택 감지 → 실행할 명령 확인 → `apply.sh` 실행)
4. 생성된 `CLAUDE.md`의 TODO를 채우고 `.claude/settings.json`의 allow 목록을 검토한다.
5. 커밋할 파일만 커밋한다([install.md](docs/install.md) 4절).

필요한 도구는 `python3` 3.8+와 `git`이다. `jq`는 있으면 쓰고 없으면 `python3`로 대신한다.

저장소를 받지 않고 훅·에이전트·스킬만 쓰려면 Claude Code 세션에서 플러그인으로 설치한다. 규칙·권한 규칙·상태줄은 들어가지 않고, `install.sh`와 함께 쓰지 않는다([install.md](docs/install.md) 5절).

```
/plugin marketplace add bhnvx/ai_boilerplate
/plugin install ai-boilerplate@ai-boilerplate
```

## 3. 구성 요소

### 3.1 훅

| 훅 | 실행 시점 | 하는 일 | 끄기 |
|---|---|---|---|
| `guard-secrets` | 도구 실행 전(Read·Edit·Write·Grep·Bash 등) | 비밀 파일(`.env`·키·인증서 등)의 읽기·출력·전송을 차단한다. 복사·쓰기·`git add`·비밀 변수 출력은 확인받는다 | `CLAUDE_GUARD_SECRETS=off` |
| `guard-destructive` | Bash 실행 전 | 루트·홈 `rm -rf`, 보호 브랜치 강제 푸시, `--no-verify`를 차단한다. 보호 브랜치 푸시·커밋, DB 파괴 SQL, 인프라·배포 명령, `sudo`, `curl \| sh`는 확인받는다 | `CLAUDE_GUARD_DESTRUCTIVE=off` |
| `guard-migrations` | Edit·Write·Bash 실행 전 | 기존 마이그레이션 수정·삭제와 파괴적 스키마 변경을 확인받는다. 서브에이전트의 마이그레이션 작업은 차단한다 | `CLAUDE_GUARD_MIGRATIONS=off` |
| `session-context` | 세션 시작 | 날짜, 브랜치 상태, 최근 커밋, 스택, 규칙 파일 현황을 컨텍스트로 넣는다 | `CLAUDE_SESSION_CONTEXT=off` |
| `stop-verify` | 응답이 끝날 때 | 파일을 고치고도 검증 명령(테스트·린트·빌드) 없이 끝내고 '미검증' 표기도 없으면 알린다 | `CLAUDE_STOP_VERIFY=off` |
| `subagent-scope` | 서브에이전트가 끝날 때 | 서브에이전트가 위임받은 '소유 파일' 밖을 고쳤으면 알린다 | `CLAUDE_SUBAGENT_SCOPE=off` |
| `statusline.sh` | 상태줄 | 모델·브랜치·컨텍스트·사용량을 한 줄로 보여 준다 | settings의 `statusLine` 제거 |
| `format-on-edit` | 편집 후(프로젝트가 켠 경우만) | 프로젝트가 설정한 포매터만 실행한다 | `CLAUDE_FORMAT_ON_EDIT=off` |

- 가드 훅은 차단·확인 사유에 규칙 ID를 붙인다. 예: `차단 [secrets:print]: cat .env — 비밀 파일 내용 출력`.
- 알림 훅 2개는 아무것도 막지 않는다.
- 모든 훅을 한 번에 끄려면 `CLAUDE_HOOKS_DISABLE=1`(상태줄 제외).
- 훅이 실패하거나 `jq`·`python3`가 둘 다 없으면 막지 않고 통과한다(fail-open).
- 판정 규칙 전체는 [docs/hooks.md](docs/hooks.md)에 있다.

### 3.2 판정 3단계

| 단계 | 동작 | 예 |
|---|---|---|
| deny | 항상 차단 | `cat .env`, `rm -rf ~`, `git push --force origin main` |
| ask-high | 모든 권한 모드에서 확인 요청 | `git push origin main`, `psql -c "DROP TABLE …"`, `make deploy`, `sudo` |
| ask-low | `default`·`acceptEdits`·`plan`·`dontAsk`에서는 확인, `auto`·`bypassPermissions`에서는 훅이 판단하지 않고 넘긴다 | `rm -rf ./src`, `git reset --hard`, `manage.py migrate` |

`bypassPermissions`에서는 ask-high도 확인 없이 실행될 수 있다. 이 모드에서 확실한 차단은 deny뿐이다.

### 3.3 규칙 · 에이전트 · 스킬

**규칙**(`~/.claude/rules/`, 항상 로드)

| 파일 | 내용 |
|---|---|
| `core.md` | 검증한 것만 완료 보고, 추측 금지, 요청 범위 준수, 완료 보고 형식 |
| `git.md` | 커밋 메시지 형식, 브랜치 모델, 금지 사항(force push·`--no-verify`·`git add -A`) |
| `security.md` | 비밀 파일·값 취급, 운영 접근 금지, 차단 우회 금지 |
| `web.md` | 웹 솔루션 공통: API 설계, 인증·인가, 데이터, 테스트 계층 |
| `subagent-policy.md` | 직접 할 일과 위임할 일의 기준, 위임 프롬프트 7항목, 결과 검증 |

**에이전트**(`~/.claude/agents/`)

| 에이전트 | 역할 |
|---|---|
| `explorer` | 읽기 전용 조사. 결론과 근거(경로:라인)만 보고한다 |
| `implementer` | 지정한 소유 파일 안에서만 구현한다 |
| `reviewer` | 보고 전용 리뷰. 코드를 고치지 않는다 |

**스킬**(`~/.claude/skills/`)

| 명령 | 하는 일 |
|---|---|
| `/commit` | 스테이징할 파일을 지정하고 diff를 점검한 뒤 규칙에 맞는 메시지로 커밋 |
| `/review-diff` | 변경분을 `reviewer`로 리뷰하고 심각도순으로 보고 |
| `/delegate` | 위임 판단 체크리스트와 위임 프롬프트 템플릿 |
| `/harness-check` | 설치 상태 점검 |
| `/harness-init` | 현재 프로젝트에 템플릿 적용(스택 감지 → `apply.sh`) |
| `/api` | 엔드포인트 추가·변경 워크플로(명세 표 → 구현 → 테스트) |
| `/preflight` | PR 전 점검(마이그레이션 누락, env 동기화, 시크릿 스캔 등) |

도구·모델 배정, 스킬 인수, ECC 플러그인과의 역할 분담은 [docs/components.md](docs/components.md)에 있다.

### 3.4 프로필과 프로젝트 템플릿

- `apply.sh`는 프로젝트에 `CLAUDE.md`, `.claude/settings.json`, `.claude/rules/project.md`, `.worktreeinclude`를 만들고 `.gitignore`에 필요한 줄을 더한다. 이미 있는 `CLAUDE.md`는 그대로 두고 `settings.json`은 병합한다.
- 프로필은 기본으로 적용하지 않는다. `--profile <이름>`이나 `--profile auto`(스택 감지)를 줄 때만 그 언어의 규칙 파일과 검사·테스트 명령 allow를 더한다.
- 언어 프로필 규칙은 해당 파일(`**/*.py` 등)을 읽거나 고칠 때만 로드된다.
- `--profile sandbox`는 그 프로젝트의 Bash 명령을 OS 샌드박스 안에서 실행하게 한다. 쓰기는 프로젝트 디렉터리로 한정되고, SSH·클라우드 자격 증명 경로를 읽지 못하고, 샌드박스 밖 재실행은 확인받는다. 언어 프로필과 함께 줄 수 있고 `auto`는 고르지 않는다.
- `.worktreeinclude`는 Claude Code가 워크트리를 만들 때 `CLAUDE.local.md`와 `.claude/settings.local.json`을 함께 복사하게 한다. `.env`는 기본으로 넣지 않는다.
- 에이전트 `memory`는 기본으로 켜지 않는다. 켜는 방법과 운용 규칙은 [docs/components.md](docs/components.md) 2.1절에 있다.

## 4. 자주 쓰는 설정

env 변수로 조정한다. 개인 전역은 `~/.claude/settings.json`의 `env`, 프로젝트 개인용은 `.claude/settings.local.json`의 `env`에 둔다.

| 변수 | 기본값 | 효과 |
|---|---|---|
| `CLAUDE_GUARD_PROTECTED_BRANCHES` | `main master` | 보호 브랜치 목록(쉼표·공백 구분, `release/*` 같은 glob 가능). `none`이면 브랜치 규칙을 끈다 |
| `CLAUDE_GUARD_ASK_ON_PUSH` | `protected` | `1`: 모든 푸시 확인. `0`: 강제 푸시가 아니면 확인 안 함 |
| `CLAUDE_GUARD_SECRET_ALLOW` | — | 비밀 파일 검사에서 제외할 glob(콜론 구분) |
| `CLAUDE_GUARD_SECRET_EXTRA` | — | 비밀 파일로 추가할 glob(콜론 구분) |
| `CLAUDE_STOP_VERIFY` | 알림 | `remind`: 사용자 경고 대신 Claude가 이어서 검증하거나 '미검증'으로 고쳐 쓰게 한다 |
| `CLAUDE_HOOKS_LOG` | — | 훅 결정 로그를 남길 파일 경로 |

개인 저장소에서 보호 브랜치 규칙을 끄는 예(`.claude/settings.local.json`):

```json
{
  "env": {
    "CLAUDE_GUARD_PROTECTED_BRANCHES": "none"
  }
}
```

전체 표와 규칙·프로필·비밀 패턴을 추가하는 방법은 [docs/customization.md](docs/customization.md)에 있다.

## 5. 설치 · 되돌리기

```bash
./install.sh --dry-run               # 계획만 출력
./install.sh                         # 설치(바뀌는 파일은 백업)
./install.sh --uninstall             # 제거(사용자가 고친 파일·설정은 남긴다)
./install.sh --restore <타임스탬프>   # 백업으로 되돌리기
./apply.sh <프로젝트> [--profile auto] [--with-format-hook] [--dry-run]
```

- 파일은 복사한다(심볼릭 링크 아님). 저장소를 고친 뒤에는 `./install.sh`를 다시 실행한다.
- 사용자가 고친 설치 파일은 덮어쓰지 않고 옆에 `<파일>.ai_boilerplate.new`를 둔다.
- `settings.json`은 병합한다. `model`·`env`·`enabledPlugins` 같은 사용자 값은 그대로 둔다.
- 사용자가 지운 관리 항목은 `--force` 없이는 다시 넣지 않는다.
- 다시 실행해서 바뀔 것이 없으면 `변경 없음`이다.

자세한 동작(트랜잭션·백업·종료 코드·`--yes`)은 [docs/install.md](docs/install.md)에 있다.

## 6. 검증

```bash
bash tests/run-all.sh                       # 훅·스킬·설치 테스트 전체
bash scripts/validate.sh --repo --quiet     # 저장소 구성 검사
```

설치된 환경은 세션에서 `/harness-check`로 점검한다. 테스트 구성과 CI는 [docs/development.md](docs/development.md)에 있다.

## 7. 알아 둘 제한

- **훅은 보안 경계가 아니다.** 명령을 어림으로 읽는 파서라 변수 조합·스크립트 내부·인코딩으로 우회할 수 있다. 확실한 경계가 필요하면 sandbox 프로필(`apply.sh --profile sandbox`)을 쓴다.
- sandbox 프로필과 플러그인 배포판은 설정 검증까지만 했고 실제 세션에서 실행해 보지 않았다.
- 훅이 실패하거나 제한 시간(10초)을 넘기면 막지 않고 통과한다.
- 아주 큰 명령은 끝까지 분석하지 않고 `too-complex`로 확인을 요청한다(서브에이전트는 차단).
- Read deny가 Write·Edit도 막으므로 Claude가 `.env`를 직접 만들 수 없다. `cp .env.example .env`를 쓰거나 사용자가 만든다.
- 알림 훅은 Edit·Write 도구 호출만 본다. Bash로 고친 파일은 보지 못한다.
- Windows는 검증하지 않았다.

전체 목록은 [docs/limitations.md](docs/limitations.md)에 있다.

## 8. 문서

| 문서 | 내용 |
|---|---|
| [docs/hooks.md](docs/hooks.md) | 훅 목록, 판정 단계, 명령을 읽는 방법, 가드별 판정 세부, 알림 훅 |
| [docs/components.md](docs/components.md) | 규칙·에이전트(memory 운용 포함)·스킬·프로필(sandbox 포함) 상세, ECC 플러그인과의 관계 |
| [docs/install.md](docs/install.md) | `install.sh`·`apply.sh` 동작, 전역 `settings.json`, 프로젝트 템플릿, 플러그인 배포판 |
| [docs/customization.md](docs/customization.md) | env 변수 전체, 규칙·프로필·비밀 패턴 추가, sandbox 조정 |
| [docs/limitations.md](docs/limitations.md) | 알려진 제한 전체 |
| [docs/development.md](docs/development.md) | 저장소 구조, 테스트·검증·CI, 파일 이력 |

## 9. 검증 기준

| 항목 | 기준 |
|---|---|
| Claude Code | 2.1.318 (VS Code 확장, macOS). 플러그인 매니페스트는 2.1.322의 `claude plugin validate` |
| 공식 문서 확인일 | 2026-11-05 (code.claude.com). Stop·SubagentStop 훅, sandbox, 플러그인, 서브에이전트 memory, `.worktreeinclude`는 2026-11-11 |
| 설정 스키마 스냅샷 | 2026-11-05 (`schemas/claude-code-settings.schema.json`, json.schemastore.org) |
| 셸 | `/bin/bash` 3.2 호환(bash 5에서도 테스트), BSD/GNU 도구 공통 |
| 필수 도구 | `python3` 3.8+ (install·apply·validate), `git` |
| 선택 도구 | `jq`(훅 JSON 파싱, 없으면 `python3`로 대체. 둘 다 없으면 훅은 통과(fail-open)) |
| CI | ubuntu-latest(gawk · mawk), macos-latest |

## 10. 다음 단계

- sandbox 프로필 실측: macOS(Seatbelt)와 Linux(bubblewrap)의 실제 세션에서 경계와 승인 흐름 확인
- 플러그인 배포판 실측: 실제 세션에서 훅 발화와 이름공간이 붙은 스킬·에이전트 동작 확인
- 플러그인 배포판에 규칙을 싣는 방법(플러그인은 `rules/`를 실을 수 없다)
- LICENSE 추가(없으면 공식 플러그인 디렉터리에 제출할 수 없다)
