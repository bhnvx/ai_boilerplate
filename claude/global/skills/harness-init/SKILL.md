---
name: harness-init
description: 현재 프로젝트에 dev_settings 프로젝트 템플릿(CLAUDE.md, .claude/settings.json, rules, 선택형 언어 프로필)을 apply.sh로 적용한다. 스택을 감지해 프로필을 제안하고, 실행 전 명령을 보여주고 확인받는다.
argument-hint: "[python|django|fastapi|node|auto] [--force] [--with-format-hook] [--team] [--dry-run]"
disable-model-invocation: true
allowed-tools:
  - 'Bash("${CLAUDE_SKILL_DIR}/context.sh" *)'
  - "Bash(${CLAUDE_SKILL_DIR}/context.sh *)"
---

# /harness-init — 프로젝트 하네스 적용

인수: $ARGUMENTS

## 현재 상태(자동 수집)

!`"${CLAUDE_SKILL_DIR}/context.sh" "${CLAUDE_PROJECT_DIR}"`

## 절차

1. 저장소 확인
   - "dev_settings 저장소"가 `미설치`·`경로 없음`이거나 `apply.sh: 없음`이면 멈춘다.
   - 안내: dev_settings 저장소에서 `./install.sh`를 실행하고 Claude Code를 재시작한 뒤 다시 `/harness-init`.
2. 기존 파일 확인(위 "프로젝트 파일 현황")
   - `CLAUDE.md` 또는 `.claude/CLAUDE.md`가 있으면 apply.sh는 새로 만들지 않는다. 내용이 다르면 그 파일 옆에 후보(`CLAUDE.md.dev_settings.new` 또는 `.claude/CLAUDE.md.dev_settings.new`)를 만든다. `--force`는 백업 후 루트 `CLAUDE.md`를 덮어쓰므로 사용자가 원할 때만 붙인다. `.claude/CLAUDE.md`만 있으면 `--force`로도 루트 `CLAUDE.md`를 만들지 않는다.
   - `AGENTS.md`만 있으면 첫 줄이 `@AGENTS.md`인 `CLAUDE.md`가 만들어진다(AGENTS.md는 계속 로드됨).
   - `.claude/settings.json`이 있으면 덮어쓰지 않고 병합된다.
   - git 저장소가 아니거나 미커밋 변경이 많으면 그 사실을 먼저 알린다.
3. 프로필 결정
   - 프로필은 선택형 add-on이다. 공통 템플릿은 언어·프레임워크와 무관하게 항상 적용된다.
   - 인수에 프로필이 있으면 그것을 쓴다. 없으면 "auto 프로필(추정)"을 제안하고, 사용자가 받아들일 때만 `--profile auto`를 붙인다(apply.sh는 `--profile`을 생략하면 프로필을 적용하지 않는다).
   - 여러 개는 `--profile`을 반복한다(예: `--profile python --profile django`). 감지 결과가 없거나 사용자가 프로필을 원하지 않으면 `--profile` 없이 실행해 공통 템플릿만 적용한다.
   - `sandbox` 프로필(Bash 명령을 OS 샌드박스 안에서 실행)은 추정에 넣지 않는다. 사용자가 요청할 때만 `--profile sandbox`를 더한다.
   - `--with-format-hook`은 프로젝트에 포매터 설정(ruff·black·prettier·biome·gofmt 등)이 있으면 권한다. ECC quality-gate는 기본적으로 검사만 하므로 겹치지 않는다. `ECC_QUALITY_GATE_FIX=true`일 때만 포맷 훅이 ECC가 고치는 타입을 건너뛴다(위 "ECC 플러그인" 줄 참고).
   - 팀원도 같은 커밋 규칙을 쓰게 하려면 `--team`(전역 git.md를 `.claude/rules/git.md`로 복사)을 제안한다.
4. 미리보기 — 실행할 명령을 보여주고, 원하면 먼저 `--dry-run`으로 계획을 본다. 인수에 `--dry-run`이 있으면 미리보기만 하고 5단계로 넘어가지 않는다.

   ```bash
   bash '<저장소>/apply.sh' '<프로젝트>' --profile <프로필> --dry-run
   ```

   - 경로는 위 "미리보기 명령"처럼 작은따옴표로 감싼다(경로 안의 `'`는 `'\''`). 큰따옴표는 경로의 `$`·백틱이 확장되므로 쓰지 않는다.
   - 프로필 없이 적용하면 `--profile <프로필>`을 뺀다(위 "미리보기 명령"도 추정 프로필이 없으면 `--profile` 없이 나온다).

5. 사용자 확인 후 적용 — 일반 권한 프롬프트가 뜬다.

   ```bash
   bash '<저장소>/apply.sh' '<프로젝트>' --profile <프로필> [--force --yes] [--with-format-hook] [--team]
   ```

   - Bash 도구 실행은 비대화형이다. `--force`(백업 후 덮어쓰기)는 확인이 필요한 작업이라 `--yes`가 없으면 종료 코드 2로 멈춘다 → 사용자가 덮어쓰기를 승인했을 때만 `--force --yes`를 붙인다.
   - apply.sh 종료 코드: 0 · 1 거부/실패(롤백 없음 — 바뀐 파일만 백업) · 2 사용법 오류 · 3 적용됐지만 validate FAIL.
     - 0: 성공 → 6단계.
     - 1: 이미 생성된 파일이 남는다. 오류 원문, 생성된 파일 목록(`git status`), 백업 경로를 보고한다.
     - 2: 오류 원문(확인 필요 작업이면 `--yes` 안내 포함)을 보여주고 인수를 고친 명령을 다시 확인받는다.
     - 3: 사용자에게 `/harness-check` 실행을 제안한다.
6. 결과 요약
   - 생성 / 건너뜀(이미 있음) / `.dev_settings.new` 생성 / 백업 경로.
   - 커밋할 파일: `CLAUDE.md`, `.gitignore`, `.worktreeinclude`, `.claude/settings.json`, `.claude/rules/**`, `.claude/hooks/**`(포맷 훅을 넣은 경우).
   - 선택: 팀원용 예시(커밋 가능): `CLAUDE.local.md.example`, `.claude/settings.local.json.example`.
   - 커밋하지 않을 파일: `CLAUDE.local.md`, `.claude/settings.local.json`, `*.dev_settings.new` (`.gitignore`에 추가됨).
   - apply.sh가 출력한 TODO 목록(CLAUDE.md TODO 채우기, allow 목록 검토)을 그대로 전달한다.
7. TODO 채우기 제안
   - `CLAUDE.md`의 TODO(기술 스택, 명령어, 디렉터리 구조, 컨벤션, 중요 파일)를 프로젝트를 읽고 채워줄지 묻는다.
   - 승인하면 매니페스트(`pyproject.toml`, `package.json` 등), 디렉터리 구조, 린터·테스트 설정, CI 설정을 읽고 초안을 만든다. 확인하지 못한 값은 `미확인`으로 둔다.
   - `## 명령어` 블록은 실제 명령만 적는다(`/preflight`가 이 블록을 읽는다).
   - `.claude/rules/project.md`(서브에이전트 보충 규칙: 환경 함정, 메인 전용 파일, 검증 명령)도 같은 방식으로 제안한다.
   - 쓰기 전에 초안을 보여주고 확인받는다.
8. 마무리
   - 커밋은 하지 않는다. 원하면 사용자가 `/commit`(수동 스킬)으로 커밋할 파일만 지정해 커밋하도록 안내한다.
   - 적용 후 사용자에게 `/harness-check` 실행을 제안한다.
