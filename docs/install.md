# 설치와 적용

[← README](../README.md)

`install.sh`(전역 `~/.claude`)와 `apply.sh`(프로젝트)가 하는 일을 자세히 적은 문서다. 플러그인 배포판은 5절에 있다.

## 1. 명령

```
./install.sh [--dry-run] [--force] [--no-settings] [--home <dir>] [--uninstall] [--restore <타임스탬프>] [--yes] [--help]
./apply.sh <프로젝트> [--profile python|django|fastapi|node|sandbox|auto]... [--with-format-hook] [--force] [--dry-run] [--team] [--yes] [--help]
```

## 2. 전역 `settings.json`

`claude/global/settings.json`을 `~/.claude/settings.json`에 병합한다.

| 키 | 값 | 의도 |
|---|---|---|
| `$schema` | schemastore URL | 편집기 자동완성·검증 |
| `language` | `korean` | 응답 언어. 이미 값이 있으면 사용자 값 유지(`install.sh --force`면 저장소 값) |
| `worktree.baseRef` | `head` | 워크트리를 현재 HEAD 기준으로 만든다. 기본값은 미푸시 커밋을 빠뜨린다 |
| `permissions.allow` | `jq`, `gh` 읽기 명령, 공식 문서 WebFetch 도메인 | 최소로 둔다(아래) |
| `permissions.deny` | 비밀 파일 `Read(//**/…)`, `~/.ssh/**` 등 | 핵심 비밀 파일 읽기 차단(네이티브 강제, 전체 목록은 훅 — [customization.md](customization.md) 2절) |
| `hooks` | PreToolUse 3개, SessionStart·Stop·SubagentStop 1개씩 | [hooks.md](hooks.md) |
| `statusLine` | `statusline.sh` | 모델·브랜치·컨텍스트·사용량 한 줄 |

- **allow를 최소로 둔 이유**: `ls`·`cat`·`git status` 같은 읽기 명령은 Claude Code가 이미 프롬프트 없이 실행한다. 와일드카드 allow(`git log *` 등)는 `git log --output=<파일>` 같은 쓰기 경로까지 연다.
- **deny에 `//**/`를 쓰는 이유**: 사용자 설정에서 `**/.env`는 현재 작업 디렉터리 하위만 덮는다. `//`로 파일시스템 루트에 고정해야 모든 프로젝트에 적용된다.
- **`permissions.ask`를 두지 않은 이유**: 네이티브 ask 규칙은 훅의 env 스위치로 끌 수 없다. 푸시·sudo 같은 확인은 훅이 맡아 프로젝트별로 조정 가능하게 한다.
- `.env.example`·`.env.sample`·`.env.template`·`.env.dist`, `*.pub`는 deny하지 않는다.
- `alwaysThinkingEnabled`는 넣지 않는다(Fable 모델에 효과 없음).
- 사용자 값이 이기는 키: `model` `effortLevel` `modelSettings` `enabledPlugins` `extraKnownMarketplaces` `env` `language` `statusLine` `attribution` `includeCoAuthoredBy` `worktree` `permissions.defaultMode` `permissions.additionalDirectories`. 단 `install.sh --force`는 `$schema`·`language`·`statusLine`·`worktree.baseRef`를 저장소 값으로 바꾼다(백업 후, `worktree`의 다른 키는 유지).

## 3. 설치 동작

- **복사 방식만 지원**(심볼릭 링크 없음). 저장소에서 편집 중인 훅이 열린 모든 세션에 즉시 반영되는 사고를 막고, 설치본 수정 여부를 cksum으로 추적하기 위해서다.
- **파일별 계획**: `create`(새 파일) · `update`(지난 설치 후 손대지 않은 파일 갱신) · `skip-identical` · `keep-user-edited`(사용자가 고친 파일 유지 + 옆에 `<파일>.ai_boilerplate.new` 생성 + WARN) · `conflict`(매니페스트에 없는 기존 파일, `--force` 없으면 유지 + `.new`) · `remove-stale`(저장소에서 사라진 파일, 손대지 않았으면 백업 후 삭제).
- **사용자가 지운 관리 파일**: 매니페스트에 있는데 사용자가 지운 파일(예: `rules/web.md`)은 `유지(사용자 삭제) <경로>`로 표시하고 다시 만들지 않는다. `--force`면 다시 만든다(settings 관리 규칙과 같은 정책).
- **트랜잭션**: 임시 stage 디렉터리에 전부 준비 → `bash -n`·JSON 검사 → 바뀔 파일만 백업 → 배치 → `settings.json`은 마지막에 같은 디렉터리 임시 파일에서 `mv`로 교체(심볼릭 링크면 실제 대상에 기록, 설치 중 변경되면 중단) → 매니페스트 기록. 중간 실패·중단 시 이번 백업으로 되돌린다(심볼릭 링크였던 파일은 백업에 남긴 링크 텍스트로 같은 링크를 다시 만든다 — `--restore`도 같다). 되돌리기에 실패한 파일이 있으면 백업을 지우지 않고 `--restore` 명령을 안내한다. stage 디렉터리는 어떤 경우에도 지운다.
- **settings 병합**(`scripts/merge-settings.py`): 사용자 키 보존(2절 목록), permission 목록은 합집합, 훅은 매처 정규화(`Edit|Write` = `Write|Edit`)와 명령 기준 중복 제거.
  - 사용자 쪽 다른 permission 목록에 있는 규칙은 넣지 않고 `WARN 충돌: <규칙> base=deny overlay=allow`처럼 알린다.
  - `--force`면 `$schema`·`language`·`statusLine`·`worktree.baseRef`도 저장소 값으로 바꾸고 설치 기여분으로 기록한다(관리 값은 경로 단위라 `worktree`의 다른 키는 그대로다).
  - 엄격한 JSON만 읽는다(JSONC 주석 불가).
  - 엄격한 JSON이 아니면 파일을 배치하기 전에 위치(line·col)를 알리고 exit 1로 멈춘다.
- **사용자가 지운 관리 settings 항목**(permission 규칙·훅·`language`·`statusLine`·`worktree.baseRef`)은 매니페스트 `settings.user_deleted`에 값과 함께 기억하고, 저장소 커밋이 바뀌어 매니페스트를 다시 써도 `--force` 없이는 다시 넣지 않는다. 계획에 `settings: 유지(사용자 삭제): <항목>`과 `--force 로 복원` 안내가 찍힌다. 기억한 항목을 손으로 다시 넣으면 사용자의 것이 되어 `--uninstall`이 지우지 않고, 기억은 남아 또 지워도 다시 넣지 않는다. `--force`는 지운 항목을 다시 넣고 그 기억을 지운다(손으로 다시 넣어 둔 항목의 기억은 남긴다).
- 이벤트의 유일한 훅이나 `hooks` 객체 전체를 지워도 빈 껍데기(`"SessionStart": []`)를 쓰지 않는다. 매니페스트의 settings 부분이 손상됐으면 그 부분을 무시하고 계획과 `--uninstall`(dry-run 포함)에 `settings: WARN 매니페스트 settings… 형식이 잘못돼 무시함 — settings.json 의 관리 항목을 직접 확인`을 찍는다.
- **백업**: `~/.claude/backups/ai_boilerplate/<YYYYmmdd-HHMMSS>.XXXXXX/`(최근 10개 유지). apply 백업은 `~/.claude/backups/ai_boilerplate/apply/<프로젝트명>/`.
- **매니페스트**: `~/.claude/ai_boilerplate.manifest.json`(설치 파일별 cksum, 저장소 커밋, settings 기여분과 사용자 삭제 기억 `user_deleted`), `~/.claude/ai_boilerplate.repo`(저장소 경로).
  - 이 저장소의 이전 이름(`dev_settings`)으로 설치한 환경은 매니페스트·백업 경로 이름이 달라 새 버전이 이전 설치를 알아보지 못한다. 이름을 바꾸기 전 버전(커밋 `42bf549`)에서 `./install.sh --uninstall`을 실행한 뒤 다시 설치한다.
  - `~/.claude/backups/dev_settings/`에 남은 예전 백업은 `--restore` 목록에 나오지 않는다. 필요 없으면 직접 지운다.
  - 프로젝트 `.gitignore`의 `*.dev_settings.new` 줄은 남아 있어도 해가 없다. 다시 적용하면 새 이름의 줄이 더해진다.
- `--dry-run`: 아무것도 쓰지 않고 계획과 settings diff만 출력. `--uninstall`·`--restore`와 함께 쓰면 지울·되돌릴 파일 목록(제거는 settings diff 포함)만 출력하고 홈은 그대로 둔다.
- `--uninstall`: 매니페스트의 파일과 관리 settings 항목을 백업 후 제거. 사용자가 고친 파일·사용자 키·사용자가 다시 넣은 항목은 남긴다. 설치가 넣었거나 `--force`가 바꾼 `$schema`·`worktree.baseRef`, 설치 항목만 담고 있던 빈 컨테이너(이벤트 목록·`hooks`·`permissions`·`worktree` — 설치 전부터 있던 빈 객체 포함), 비어 있는 `skills/` 디렉터리도 정리한다. settings.json은 2칸 들여쓰기로 다시 쓴다.
- `--restore <타임스탬프>`: 해당 백업 디렉터리 내용을 되돌린다. 설치 요약에 정확한 명령이 출력된다.
- `--home <dir>`(`--home=<dir>`도 가능): 다른 홈에 설치(테스트용). 빈 값(`--home ''`)은 사용법 오류. `--no-settings`: settings 병합 생략. `-h`·`--help`: 도움말.
- **확인과 `--yes`**(install.sh):
  - 대화형 터미널(stdin이 TTY)에서는 파괴적 작업(아래 목록)일 때만 진행 전에 `[y/N]`을 묻는다. 추가형 설치는 묻지 않는다. `--yes`(`-y`)면 묻지 않는다.
  - 비대화형 실행(CI, 파이프, Claude의 Bash 도구)에서 추가형 설치는 묻지 않고 진행한다(바뀌는 파일은 백업).
  - 비대화형에서 파괴적 작업(`--uninstall`, `--restore`, 업그레이드의 `remove-stale` 삭제, `--force` 덮어쓰기)은 `--yes`가 있어야 한다. 없으면 `확인이 필요한 작업(<작업>) — 비대화형 실행이면 --yes 를 지정`을 출력하고 exit 2.
  - apply.sh의 `--force`(백업 후 덮어쓰기)도 같은 규칙이다: 대화형이면 `[y/N]`, 비대화형이면 `--yes`(없으면 exit 2). 그 외 apply.sh 작업은 묻지 않는다.
- `~/.claude/skills/`에서는 이 저장소의 스킬 7개 디렉터리만 다룬다. `learned/`·`synced/` 등 다른 디렉터리는 건드리지 않는다.
- 다시 실행하면 `변경 없음`(새 백업도 만들지 않음).
- 종료 코드:
  - `install.sh`: `0` 성공 · `1` 실패(롤백됨) · `2` 사용법 오류 · `3` 설치됐지만 validate FAIL.
  - `apply.sh`: `0` 성공 · `1` 거부/실패(롤백 없음 — 바뀐 파일만 백업) · `2` 사용법 오류 · `3` 적용됐지만 validate FAIL.
- `install.sh`는 `~/.claude`(심볼릭 링크면 실제 경로)가 이 저장소 안이면 거부한다. `apply.sh`는 대상이 `$HOME`, `~/.claude`(실제 경로 포함) 하위, 이 저장소 자체이면 거부한다.

## 4. 프로젝트 템플릿(`apply.sh` 결과)

| 커밋할 파일 | 커밋하지 않을 파일 |
|---|---|
| `CLAUDE.md`, `.gitignore`(추가된 줄), `.worktreeinclude` | `CLAUDE.local.md` (개인 메모) |
| `.claude/settings.json` | `.claude/settings.local.json` (개인 env·권한) |
| `.claude/rules/**` (`project.md`, 프로필 규칙, `--team`이면 `git.md`) | `*.ai_boilerplate.new` (갱신 후보 파일) |
| `.claude/hooks/**` (`--with-format-hook`일 때) | `.claude/agent-memory-local/`, `.claude/worktrees/` |
| 선택: 팀원용 예시(커밋 가능) — `CLAUDE.local.md.example`, `.claude/settings.local.json.example` | |

- `.gitignore`에 `gitignore.claude`의 줄을 중복 없이 추가한다(기존 파일이 CRLF면 CRLF로).
- `.worktreeinclude`: Claude Code가 워크트리를 만들 때(`claude --worktree`, 서브에이전트 `isolation: worktree`, 데스크톱 앱 병렬 세션) 함께 복사할 파일 목록이다(`.gitignore` 문법).
  - 패턴에 맞으면서 gitignore된 파일만 복사된다. git이 추적하는 파일은 복사되지 않는다(공식 문서).
  - 템플릿은 `CLAUDE.local.md`와 `.claude/settings.local.json`만 복사하게 한다. 워크트리 세션에서도 개인 메모와 개인 권한 설정이 그대로 적용된다.
  - `.env`는 주석으로만 둔다. 넣으면 워크트리마다 비밀 파일 사본이 생기므로 필요할 때 직접 주석을 푼다.
  - 파일이 이미 있으면 내용이 달라도 그대로 두고(`유지(기존 파일)`), `--force`로도 덮어쓰지 않는다.
- `CLAUDE.md`나 `.claude/CLAUDE.md`가 이미 있으면 새로 만들지 않는다(내용이 다르면 그 파일 옆에 `*.ai_boilerplate.new`만 생성). `.claude/CLAUDE.md`만 있으면 `--force`로도 루트 `CLAUDE.md`를 만들지 않는다.
- `AGENTS.md`만 있으면 첫 줄이 `@AGENTS.md`인 `CLAUDE.md`를 만든다(AGENTS.md는 계속 로드됨). 다시 적용해도 같은 렌더링과 비교하므로 `변경 없음`이고, `--force`도 `@AGENTS.md`를 유지한다.
- 대상 파일이 심볼릭 링크(예: `CLAUDE.md → AGENTS.md`)면 `--force`는 링크 대상을 덮어쓰지 않는다. 대상 내용을 백업하고 링크를 일반 파일로 바꾼다. `.claude/settings.json`이 심볼릭 링크면 병합 결과를 실제 대상에 기록한다.
- `--with-format-hook` 없이 다시 적용하면 PostToolUse 포맷 항목을 뺀다. `.claude/hooks/`의 세 파일(`run-hook.sh`, `format-on-edit.sh`, `lib/common.sh`)이 저장소 사본과 같으면 백업 후 `삭제`한다. 수정된 파일이면 `수정된 훅 파일 — … 수동 정리` WARN을 내고, settings.json이 아직 참조하지 않으면 커밋할 파일 목록에서 뺀다.
- `.claude/rules/project.md`: 서브에이전트 보충 규칙(환경 함정, 메인 전용 공유 핫스팟, 검증 명령, 금지 사항) 템플릿.
- 팀 파일(`.claude/**`, `CLAUDE.md`)에 `~/.claude/`나 개인 스킬(`/commit`, `/harness-init`, `/harness-check`, `/preflight`, `/review-diff`, `/delegate`) 언급이 있으면 `validate.sh --project`가 WARN을 낸다.

## 5. 플러그인으로 설치

저장소를 받지 않고 훅·에이전트·스킬만 쓰는 배포판이다. Claude Code 세션에서 실행한다.

```
/plugin marketplace add bhnvx/ai_boilerplate
/plugin install ai-boilerplate@ai-boilerplate
```

| 구성 요소 | `install.sh` | 플러그인 |
|---|---|---|
| 가드 훅 3개 · `session-context` · 알림 훅 2개 | 있음 | 있음 |
| 에이전트 3개 | `explorer` 등 | `ai-boilerplate:explorer` 등(이름공간이 붙는다) |
| 스킬 7개 | `/commit` 등 | `/ai-boilerplate:commit` 등 |
| 규칙 5개(`~/.claude/rules/`) | 있음 | 없음 |
| 권한 규칙(Read deny·allow), `language`, `worktree.baseRef` | 있음 | 없음 |
| 상태줄, 전역 `CLAUDE.md` | 있음 | 없음 |
| 프로젝트 템플릿·프로필(`apply.sh`) | 있음 | 없음 |

- 플러그인은 규칙 파일과 권한 규칙을 실을 수 없다. 플러그인의 `settings.json`은 `agent`·`subagentStatusLine` 키만 적용된다(공식 문서). 전체 구성은 `install.sh`로 설치한다.
- **둘을 함께 쓰지 않는다.** 훅이 두 번 실행되고 스킬·에이전트가 두 벌 생긴다.
- 구성:
  - 저장소 루트의 `.claude-plugin/marketplace.json`이 `./claude/global`을 플러그인으로 가리킨다.
  - `claude/global/.claude-plugin/plugin.json`이 훅을 등록한다. `skills/`·`agents/`는 기본 위치라 따로 적지 않는다.
  - 훅 등록은 전역 `settings.json`의 `hooks`와 같고 명령 경로만 `"${CLAUDE_PLUGIN_ROOT}"/hooks/run-hook.sh`다. `validate.sh --repo`와 `tests/install/test-plugin.sh`가 둘을 대조한다.
  - `install.sh`는 `.claude-plugin/`을 `~/.claude`에 복사하지 않는다.
- `version`을 적지 않았다. 커밋 SHA가 버전이 되어 커밋마다 갱신 대상이 된다. 적으면 그 문자열로 고정된다(공식 문서).
- 훅의 env 스위치(`CLAUDE_GUARD_*`, `CLAUDE_HOOKS_DISABLE` 등)는 그대로 쓴다([customization.md](customization.md) 1절).
- 스킬 본문이 참조하는 `~/.claude/rules/*.md`는 플러그인 설치에 없다. 스킬은 본문의 절차만으로 동작한다.
- `/ai-boilerplate:harness-check`는 점검 결과를 내지 못한다. `install.sh`가 스킬 디렉터리에 복사하는 `validate.sh`가 플러그인에는 없다.
- 팀 프로젝트에서 미리 선언하려면 프로젝트 `.claude/settings.json`에 넣는다.

  ```json
  {
    "extraKnownMarketplaces": { "ai-boilerplate": { "source": { "source": "github", "repo": "bhnvx/ai_boilerplate" } } },
    "enabledPlugins": { "ai-boilerplate@ai-boilerplate": true }
  }
  ```

- 확인한 범위(Claude Code 2.1.322):
  - `claude plugin validate .` 통과(`version` 미지정 경고 1건).
  - 격리한 설정 디렉터리에서 로컬 marketplace로 설치해 스킬 7개 · 에이전트 3개 · 훅 이벤트 4개가 인식되는 것을 확인했다.
  - 실제 세션에서의 훅 발화와 스킬·에이전트 동작은 확인하지 않았다([limitations.md](limitations.md) 8절).
