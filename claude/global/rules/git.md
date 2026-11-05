# Git 규칙 (전역)

## 커밋 메시지
- 형식: `<gitmoji> scope: subject` — gitmoji는 아래 표의 유니코드 문자다(`:sparkles:` 같은 단축 코드 아님). 예: `✨ api: add order list endpoint`
- scope: 변경한 모듈·영역(예: `api`, `auth`). 마땅한 것이 없으면 아래 표의 종류를 쓴다.
- subject: 영어, 소문자 시작, 명령형, 72자 이하, 마침표 없음.
- body: 한국어 bullet로 '왜'와 영향을 쓴다. 무엇을 바꿨는지는 diff가 보여준다.
- 트레일러(Co-Authored-By 등)는 하네스 attribution 설정에 맡긴다. 임의로 추가·삭제하지 않는다.

| gitmoji | 종류 | 의미 |
|---|---|---|
| ✨ | feat | 새 기능 |
| 🐛 | fix | 버그 수정 |
| ♻️ | refactor | 동작 변화 없는 구조 개선 |
| 📝 | docs | 문서 |
| ✅ | test | 테스트 |
| ⚙️ | chore | 설정·의존성 |
| 🔐 | security | 보안 |
| 🚑 | hotfix | 긴급 수정 |
| ⚡ | perf | 성능 |
| 🔥 | remove | 코드·파일 삭제 |
| 🚚 | move | 이동·이름 변경 |
| 🎨 | style | 포맷·스타일(동작 무관) |

## 브랜치
- 보호 브랜치는 `CLAUDE_GUARD_PROTECTED_BRANCHES` 하나로 정의한다: 쉼표·공백 구분, glob 가능(`release/*`), 변수가 없을 때만 기본 `main master`.
- 개인 저장소는 `.claude/settings.local.json`의 `env`에서 `none`(또는 빈 값)으로 끈다.
- 보호 브랜치에 직접 커밋·푸시하지 않는다. 사용자가 명시적으로 지시한 경우만 예외.
- 기본 브랜치 모델(프로젝트 규칙이 우선): `main`(배포) ← `dev`(개발) ← `feature/*`·`fix/*`·`chore/*`·`hotfix/*`·`docs/*`
- 브랜치 이름은 영어 소문자·하이픈 — 예: `feature/add-order-api`

## 금지·제한
- 커밋·푸시·PR 생성은 사용자가 요청할 때만 한다.
- force push는 사용자 지시가 있을 때 `--force-with-lease`로만 한다.
- `--no-verify` 금지. 훅 실패는 원인을 고친다.
- amend는 푸시하지 않은 커밋에 사용자가 지시한 경우만 한다.
- `git add -A`·`git add .` 금지. 파일을 지정해 스테이징한다.

## 커밋 전 점검
- `git diff --staged`로 확인한다: 비밀 값, 디버그 출력(print·console.log), 임시 파일, 대용량 바이너리.
- 비밀 값을 발견하면 커밋하지 말고 보고한다. 그 밖의 항목은 목록으로 보여주고 계속할지 사용자에게 확인한다.

## PR
- 병합은 Squash merge를 권장한다.
- 체크리스트:
  - [ ] 테스트 추가·통과
  - [ ] 포맷·린트 통과
  - [ ] 문서(API 문서·README) 갱신
  - [ ] 마이그레이션 포함·누락 검사(필요 시)
  - [ ] 미사용 코드 제거
  - [ ] 시크릿 없음
- 본문 형식:

```
## 요약
## 변경
## 테스트
## 리스크
```
