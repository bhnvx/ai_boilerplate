# 저장소 구조와 검증

[← README](../README.md)

이 저장소를 고치는 사람을 위한 문서다. 작업 규칙은 [CLAUDE.md](../CLAUDE.md)에 있다.

## 1. 디렉터리 구조

```
ai_boilerplate/
├── README.md                       개요
├── docs/                           상세 문서(훅 · 설치 · 구성 요소 · 커스터마이즈 · 제한 · 저장소 구조)
├── CLAUDE.md                       이 저장소 작업용 지침
├── install.sh                      claude/global → ~/.claude 설치
├── apply.sh                        project-template·profiles → <프로젝트> 적용
├── .claude-plugin/marketplace.json 플러그인 marketplace(claude/global을 플러그인으로 가리킨다)
├── claude/
│   ├── global/                     → ~/.claude/ (플러그인 루트이기도 하다)
│   │   ├── .claude-plugin/plugin.json  플러그인 매니페스트(훅 등록, 설치 대상 아님)
│   │   ├── CLAUDE.md.tmpl          → ~/.claude/CLAUDE.md
│   │   ├── settings.json           ~/.claude/settings.json에 병합
│   │   ├── rules/                  core · git · security · web · subagent-policy
│   │   ├── agents/                 explorer · implementer · reviewer
│   │   ├── hooks/                  run-hook.sh(런처) · guard-* · session-context · stop-verify · subagent-scope · format-on-edit · statusline
│   │   │   └── lib/                common.sh · shellparse.sh · guard-rules.sh · transcript.sh · detect-stack.sh · secret-patterns.txt
│   │   └── skills/                 commit · review-diff · delegate · harness-check · harness-init · api · preflight
│   └── project-template/           → <프로젝트>/
│       ├── CLAUDE.md.tmpl          → CLAUDE.md
│       ├── CLAUDE.local.md.example 개인 메모 예시
│       ├── gitignore.claude        .gitignore에 추가할 줄
│       ├── dot-worktreeinclude     → .worktreeinclude(없을 때만 생성)
│       └── dot-claude/             → .claude/
│           ├── settings.json · settings.local.json.example
│           ├── fragments/format-hook.json   --with-format-hook일 때만 병합
│           └── rules/project.md    서브에이전트 보충 규칙 템플릿
├── profiles/                       선택형: python · django · fastapi · node · sandbox
│   └── <이름>/rules/<규칙>.md · settings.fragment.json
├── schemas/claude-code-settings.schema.json
├── scripts/                        merge-settings.py · validate.sh · update-schema.sh · lib/(install·apply 공용)
├── tests/                          run-all.sh · lib/ · hooks/ · skills/ · install/
├── .github/workflows/ci.yml
├── vscode/settings.json            VS Code 사용자 설정 참고본(설치 대상 아님, 수동 복사)
└── copilot/copilot-instructions.md  GitHub Copilot 지침 참고본(설치 대상 아님)
```

`CLAUDE.md.tmpl`·`dot-claude/`로 이름을 바꿔 둔 이유:

- Claude Code는 하위 디렉터리의 `CLAUDE.md`와 `.claude/rules/*.md`를 그 디렉터리 파일을 건드릴 때 자동으로 읽는다.
- 템플릿이 실제 이름이면 이 저장소를 작업하는 세션에 템플릿 내용이 지침으로 섞인다.
- `install.sh`·`apply.sh`가 복사하면서 실제 이름(`CLAUDE.md`, `.claude/`)으로 바꾼다.

## 2. 검증

- `scripts/validate.sh --repo [path] | --installed [--home <dir>] | --project <dir>` (`--installed`·`--project`는 함께 사용 가능, `--exit-zero`, `--max-lines N`, `--quiet`)
  - 출력: `OK|WARN|FAIL|INFO <검사>: <내용>`, 요약 `OK n · WARN n · FAIL n`. FAIL이 있으면 exit 1.
  - 검사: JSON 파싱, 스키마에 없는 키(WARN), 훅 이벤트·타입, 훅 스크립트 존재·실행 권한, `statusLine` 형식, 권한 규칙 문법(`Write(...)`·`Bash(x:*)`·공백 없는 와일드카드 `Bash(ls*)` 등 WARN)과 목록 간 중복, Read deny와 `secret-patterns.txt` 동기화, 플러그인 매니페스트(`marketplace.json`·`plugin.json`의 이름 일치, `hooks`가 전역 `settings.json`과 같은지), `bash -n`, 에이전트·스킬 frontmatter, 스킬 셸 주입 명령과 `allowed-tools` 규칙 일치(이 저장소 스킬은 FAIL), 규칙 `paths`, 깨진 심볼릭 링크, 템플릿 이름(`claude/` 아래 `CLAUDE.md`·`.claude/` 금지), 설치본과 저장소 커밋 차이.
  - `--project`는 팀 공유 파일의 개인 설정 참조(`CLAUDE.local.md`로 옮길 것)와 공유 설정·훅이 gitignore에 걸리는지도 본다.
  - `--repo`는 `merge-settings.py --selftest`와 `tests/run-all.sh`도 실행한다(`--quiet`면 생략).
- `tests/run-all.sh [--quick] [--filter <부분문자열>] [--verbose]`: 훅·스킬 스위트를 `/bin/bash`(3.2)와 PATH의 다른 bash(있으면)로, 설치 스위트(`validate.sh --repo --quiet` 포함)와 `merge-settings.py --selftest`를 한 번 실행한다. 실제 `~/.claude` 대신 공백이 들어간 임시 HOME을 쓴다.
  - 훅(`tests/hooks/`): `test-lib-*.sh`(공용 파서·`common.sh`), `test-guards-secrets*.sh`·`test-guards-destructive*.sh`·`test-guards-migrations*.sh`(가드별), `test-guards-cross.sh`(같은 입력을 세 가드에 넣어 함께 확인), `test-guards-nested*.sh`(문자열 안의 문자열·`find -exec` 프로그램 인수와 그 상한·지연), `test-guards-heredoc.sh`(셸이 읽는 heredoc 본문과 본문 속 명령 치환 — 우회 재현·무해 케이스를 세 가드를 합친 판정으로 확인), `test-aux-*.sh`(포맷·세션·상태줄·알림 훅). 번호 붙은 파일은 검증 라운드마다 추가한 회귀·성능 케이스다(200 KB heredoc 3.5초 이내, 큰 입력 3~8초 이내 등). 픽스처는 `tests/hooks/fixtures/`, 공용 함수는 `tests/lib/testlib.sh`.
  - 설치(`tests/install/`): `run.sh`가 `test-install.sh` · `test-install-upgrade.sh` · `test-install-edge.sh` · `test-install-safety.sh` · `test-apply.sh` · `test-apply-edge.sh` · `test-plugin.sh`를 실행한다(공용 `helpers.sh`). `-edge`·`-safety`는 경계 조건과 실패·롤백·백업 보존 케이스다. `test-plugin.sh`는 플러그인 매니페스트의 훅 등록이 전역 `settings.json`과 같은지, 플러그인 경로(공백이 든 경로, `~/.claude` 없는 HOME)에서 훅이 동작하는지 본다.
  - 스킬: `tests/skills/test-skills.sh`(context.sh, allowed-tools와 주입 명령 일치, 프로필 fragment). `tests/run-all.sh`가 함께 실행한다.
- 테스트 전용 env(평소에는 설정하지 않는다): `HOOK_FORCE_PARSER=jq|python3|none`(훅 파서 강제), `AI_BOILERPLATE_FAIL_AT=<지점>[,<지점>…]`(설치 실패 주입. 지점: `place` `settings` `manifest` `restore`), `AI_BOILERPLATE_IN_TESTS=1`(run-all.sh가 설정, `validate.sh --repo`의 재귀 실행 방지), `AI_BOILERPLATE_TEST_REPO=<dir>`(설치 스위트를 저장소 사본에 실행), `VALIDATE_NO_PYTHON=1`(validate.sh의 python3 없는 경로 흉내), `SP_WBMAX=<n>`(공용 파서의 줄 수 상한, 기본 5000. 가드가 다시 나누는 셸 문자열에는 남은 몫과 이것 중 작은 값), `HOOK_TLIM=<초>`(가드 작업 시간 상한, 기본 6. 숫자가 아니면 상한 없음), `KEEP_TMP=1`·`T_KEEP=1`(설치·훅 테스트 임시 디렉터리 보존).
- CI(`.github/workflows/ci.yml`): push·PR마다 세 작업에서 `tests/run-all.sh`, `validate.sh --repo --quiet`, 비밀·이메일 패턴 검사를 실행한다.
  - ubuntu-latest 두 작업: bash 5와 GNU 도구에 awk를 gawk·mawk로 하나씩 고정한다.
  - macos-latest: `/bin/bash` 3.2와 Homebrew bash 5(run-all.sh가 둘 다 실행), BSD awk.
- `scripts/update-schema.sh`: schemastore에서 스키마를 받아 추가·삭제된 키와 훅 이벤트를 보여주고 스냅샷을 교체한다. 실행 후 README의 검증 기준 날짜를 갱신한다.

## 3. 파일 이력

| 이전 경로 | 현재 위치 | 사유 |
|---|---|---|
| `settings.json` | `vscode/settings.json` | VS Code 설정임을 명확히(끝 쉼표 오류 수정) |
| `copilot-instructions.md.example` | `copilot/copilot-instructions.md` | 도구별 디렉터리로 정리 |
| `agents/explorer.md` · `implementer.md` · `reviewer.md` | `claude/global/agents/` | 설치 구조(`~/.claude/agents/`)와 일치 |
| `agents/subagent-policy.md` | `claude/global/rules/subagent-policy.md` | 에이전트 정의가 아니라 항상 로드되는 규칙 |
| `CLAUDE.md.example` | `claude/project-template/CLAUDE.md.tmpl` + `profiles/python`·`profiles/django` 규칙 + `claude/global/rules/git.md`로 증류 후 삭제 | 특정 프로젝트 가이드를 범용 템플릿·선택형 프로필로 분리 |
| `request.md.example` | `claude/global/rules/core.md`(요청 재진술)와 `/api` 스킬로 흡수 후 삭제 | 요청 양식을 규칙과 워크플로로 일반화 |
| 이름 `dev_settings` | `ai_boilerplate` | 저장소 이름 변경. 매니페스트·백업 경로·`*.ai_boilerplate.new`·테스트 env(`AI_BOILERPLATE_*`)·플러그인 이름(`ai-boilerplate`)까지 함께 바꿨다. 이전 설치의 처리는 [install.md](install.md) 3절 |
