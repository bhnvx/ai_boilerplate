---
name: commit
description: 스테이징 변경을 점검하고 git.md 컨벤션으로 커밋한다. 보호 브랜치·비밀 값·디버그 출력·임시 파일을 먼저 확인하고, 파일은 지정해서만 올리며 푸시는 하지 않는다. 인수로 커밋할 파일이나 범위 설명을 받는다.
argument-hint: "[파일... | 커밋 범위 설명]"
disable-model-invocation: true
allowed-tools:
  - 'Bash("${CLAUDE_SKILL_DIR}/context.sh" *)'
  - "Bash(${CLAUDE_SKILL_DIR}/context.sh *)"
  - "Bash(git status *)"
  - "Bash(git diff *)"
  - "Bash(git log *)"
  - "Bash(git add *)"
  - "Bash(git commit *)"
---

# /commit — 점검 후 커밋

인수: $ARGUMENTS

## 현재 상태(자동 수집)

!`"${CLAUDE_SKILL_DIR}/context.sh" "${CLAUDE_PROJECT_DIR}"`

## 따를 규칙

- 메시지 형식·gitmoji 표·브랜치 규칙: `~/.claude/rules/git.md` (여기에 다시 적지 않는다)
- 비밀 값 처리: `~/.claude/rules/security.md`
- 이 저장소의 CLAUDE.md·`.claude/rules/`에 커밋 규칙이 있으면 그것이 우선한다.

## 절차

1. 보호 브랜치 확인
   - 위 "현재 브랜치"가 보호 브랜치이면 멈추고 사용자에게 묻는다: 새 브랜치(`feature/*` 등)를 만들지, 그대로 커밋할지.
   - 사용자가 명시적으로 허락한 경우에만 보호 브랜치에 커밋한다.
   - 보호 브랜치 목록이 `none`이거나 빈 값이면 통과한다. detached HEAD도 멈추고 확인한다.
2. 스테이징 범위 결정
   - 스테이징이 비었고 인수에 파일이 있으면 그 파일만 올린다: `git add -- <파일...>`.
   - 스테이징이 비었고 인수가 없으면 변경 파일 목록을 보여주고 무엇을 올릴지 확인한다.
   - 인수가 범위 설명이면 그 설명에 맞는 파일 목록을 제안하고 확인받는다.
   - `git add -A`, `git add .`, `git add -u`, 디렉터리 통째 추가는 쓰지 않는다.
   - 이미 스테이징된 것이 있으면 그 범위로 진행하되, 인수와 어긋나면 먼저 묻는다.
3. 스테이징 diff 점검: `git diff --staged` (크면 `git diff --staged --stat` 후 파일별로)
   - 비밀 값: 키·토큰·비밀번호·접속 문자열·`.env` 계열 파일 → 발견 시 커밋하지 않고 중단·보고한다(값은 보고에 쓰지 않는다).
   - 디버그 출력: `print(`, `console.log`, `debugger`, `breakpoint()`, `pdb`, 임시 로그.
   - 임시·생성 파일: `*.orig`, `*.rej`, `*.tmp`, `.DS_Store`, `*.dev_settings.new`, 빌드 산출물.
   - 대용량·바이너리: `git diff --staged --numstat`에서 `-`로 표시되는 파일, 수 MB 이상 파일.
   - 의도와 무관한 변경(포매터가 건드린 다른 파일 등)이 섞였으면 분리를 제안한다.
   - 비밀 값 외의 항목은 목록으로 보여주고 계속할지 묻는다.
4. 커밋 메시지 작성(git.md 형식)
   - subject: 영어, 소문자 명령형, 72자 이하, 마침표 없음. scope는 변경 모듈.
   - body: 한국어 bullet로 '왜'와 영향. 사소한 변경은 생략 가능.
   - 변경이 성격이 다른 여러 덩어리면 커밋을 나누자고 제안한다.
   - attribution 트레일러는 세션 지침(하네스 attribution 설정)이 정한 대로만 붙인다. 임의로 추가하거나 빼지 않는다.
   - 작성한 메시지를 사용자에게 보여준다.
5. 커밋 실행 — HEREDOC으로 전달한다.

   ```bash
   git commit -m "$(cat <<'EOF'
   ✨ scope: subject

   - 변경 이유
   - 영향 범위
   EOF
   )"
   ```

   - `--no-verify`, `--amend`는 쓰지 않는다(amend는 사용자가 지시한 미푸시 커밋에만).
   - pre-commit 등 훅이 실패하면 원인을 고치고 다시 스테이징한 뒤 새로 커밋한다. 훅을 끄거나 우회하지 않는다.
   - 훅이 파일을 고쳤으면(포매터) 바뀐 파일을 확인하고 다시 `git add -- <파일>` 후 커밋한다.
6. 결과 보고
   - `git log -1 --stat` 요지: 해시, subject, 변경 파일 수.
   - 남은 미커밋 변경이 있으면 한 줄로 알린다.
   - 푸시는 하지 않는다. 푸시·PR은 사용자가 따로 요청할 때만.

## 참고

- `allowed-tools`는 이 스킬을 호출한 턴에만 적용된다. 사용자 답변을 받은 뒤 실행하는 `git add`·`git commit`에는 일반 권한 프롬프트가 뜰 수 있다.
- 보호 브랜치 목록의 단일 정의는 `CLAUDE_GUARD_PROTECTED_BRANCHES`다. 쉼표·공백으로 구분하고 `release/*` 같은 glob을 쓸 수 있다. 변수가 없을 때만 기본값 `main master`를 쓴다. 개인 저장소에서 끄려면 `.claude/settings.local.json`의 `env`에 `none`(또는 빈 값)을 둔다.
