---
name: harness-check
description: 설치된 dev_settings 하네스(전역 settings·훅·스킬·에이전트·rules)와 현재 프로젝트의 .claude 설정을 validate.sh로 점검하고, FAIL·WARN 항목별로 고칠 파일과 방법을 안내한다. 수정은 사용자 확인 후에만 한다.
disable-model-invocation: true
allowed-tools:
  - 'Bash("${CLAUDE_SKILL_DIR}/validate.sh" *)'
  - "Bash(${CLAUDE_SKILL_DIR}/validate.sh *)"
---

# /harness-check — 하네스 점검

## 점검 결과(자동 실행)

!`"${CLAUDE_SKILL_DIR}/validate.sh" --installed --project "${CLAUDE_PROJECT_DIR}" --exit-zero --max-lines 80`

`validate.sh`와 스키마 사본은 `install.sh`가 이 스킬 디렉터리에 복사한다. 위 결과가 비었거나 "No such file" 오류면 설치가 불완전하다 → 6단계의 재설치를 안내한다.

## 절차

1. 결과 해석 — 줄 형식은 `OK|WARN|FAIL|INFO <check>: <detail>`, 마지막 줄은 `OK n · WARN n · FAIL n`.
   - FAIL: 반드시 고친다. 훅·설정이 동작하지 않거나 모든 세션에 영향을 준다.
   - WARN: 영향과 의도를 설명하고 고칠지 사용자와 판단한다(예: 스키마 스냅샷에 없는 키는 정상일 수 있다).
   - INFO·OK: 요약에 개수만 적는다.
   - 출력이 80줄에서 잘렸으면 `"${CLAUDE_SKILL_DIR}/validate.sh" --installed --project "${CLAUDE_PROJECT_DIR}" --exit-zero`로 전체를 다시 본다.
2. FAIL·WARN 항목별로 고칠 파일을 찾는다(설치본 ← 저장소 원본).

   | 점검 영역 | 설치본·프로젝트 파일 | 저장소 원본 |
   |---|---|---|
   | 전역 settings(JSON·키·훅 이벤트·권한 규칙·statusLine) | `~/.claude/settings.json` | `claude/global/settings.json` |
   | 훅 경로·실행 권한·`bash -n` | `~/.claude/hooks/` | `claude/global/hooks/` |
   | 스킬(name·description·본문) | `~/.claude/skills/<이름>/SKILL.md` | `claude/global/skills/<이름>/` |
   | 에이전트(frontmatter·model) | `~/.claude/agents/*.md` | `claude/global/agents/` |
   | rules(frontmatter·`paths`) | `~/.claude/rules/*.md` | `claude/global/rules/` |
   | 전역 CLAUDE.md의 TODO | `~/.claude/CLAUDE.md` | `claude/global/CLAUDE.md.tmpl` |
   | 매니페스트·설치본이 오래됨 | `~/.claude/dev_settings.manifest.json` | 저장소 HEAD |
   | 프로젝트 settings·훅 | `<프로젝트>/.claude/settings.json`, `.claude/hooks/` | `claude/project-template/dot-claude/`, `profiles/*/` |
   | 프로젝트 rules·CLAUDE.md | `<프로젝트>/.claude/rules/`, `CLAUDE.md` | `claude/project-template/` |

   - 저장소 경로는 `~/.claude/dev_settings.repo`에 한 줄로 있다.
3. 원인 설명 — 항목마다 "무엇이 / 왜 문제인지 / 고칠 방법"을 한두 줄로 적는다. 추측한 원인은 '추정'으로 표시한다.
4. 수정 범위 확인 — 고칠 목록을 보여주고 사용자 확인을 받은 뒤에만 수정한다.
   - 전역 설정(`~/.claude/**`)은 직접 고치지 않는다. 저장소 원본을 고치고 재설치한다. 설치본을 직접 고치면 다음 설치 때 사용자 편집으로 취급되어 갱신되지 않는다.
   - 사용자가 직접 넣은 값(`model`, `enabledPlugins` 등)은 건드리지 않는다.
   - 프로젝트 파일은 그 프로젝트에서 고친다. 팀 공유 파일(`CLAUDE.md`, `.claude/settings.json`, `.claude/rules/`)에 `~/.claude/` 같은 개인 경로가 있다는 WARN이면 그 내용을 `CLAUDE.local.md`로 옮긴다.
5. 사용자 편집 보존본 — `~/.claude` 아래 `*.dev_settings.new` 파일이 있으면 기존 파일과 차이를 보여주고 병합할지 묻는다.
6. 설치본이 오래됨(`설치본이 저장소보다 오래됨`: 매니페스트 commit ≠ 저장소 HEAD) 또는 설치 누락
   - 먼저 변경 계획을 본다: `bash "<저장소>/install.sh" --dry-run`
   - 사용자 확인 후 재설치: `bash "<저장소>/install.sh" --yes` (일반 권한 프롬프트가 뜬다. Bash 도구는 비대화형이라 구버전 파일 삭제·덮어쓰기 확인을 `--yes`로 건너뛴다 — 계획은 위 `--dry-run`으로 먼저 확인했다)
   - 재설치 후 Claude Code를 재시작하고 `/harness-check`를 다시 실행하라고 안내한다.
7. 보고 — FAIL·WARN·OK 개수, 고친 항목, 남긴 WARN과 이유, 사용자가 할 일(재시작·재설치)을 적는다.

## 참고

- 프로젝트에 하네스가 아직 없으면(`.claude/settings.json`·CLAUDE.md 없음) 사용자에게 `/harness-init` 실행을 제안한다.
- 스키마 스냅샷 갱신은 저장소의 `scripts/update-schema.sh`로 한다.
