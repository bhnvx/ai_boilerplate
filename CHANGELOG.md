# 변경 이력

[← README](README.md)

사용자에게 보이는 변경을 적는다. 버전 태그가 아직 없어 날짜로 묶는다. 커밋 단위 이력은 `git log`에 있다.

## Unreleased

### 추가
- MIT 라이선스(`LICENSE`, 플러그인 매니페스트의 `license`).
- `CONTRIBUTING.md`, `SECURITY.md`, 이 파일, 이슈 템플릿(버그 신고 · 가드 오탐·미탐 · 기능 제안)과 PR 템플릿.
- README: 배지, 목차, 훅 판정 출력 예시, 업데이트 방법, 자주 묻는 질문.
- 전역 규칙 `plugins.md`: 설치돼 있으면 코드 구현에 superpowers, 프런트 화면에 Impeccable 플러그인을 쓰게 한다. 커밋·위임은 기존 규칙이 우선하고, 이 저장소는 두 플러그인을 설치하지 않는다([docs/components.md](docs/components.md) 6절).

### 변경
- README의 설치 예시에서 clone 경로를 고정하지 않는다. 저장소는 어느 경로에 받아도 된다.

### 수정
- `install.sh`: 저장소를 다른 경로로 옮긴 뒤 다시 실행하면 저장소 경로 기록을 새 경로로 고친다. 전에는 커밋이 같으면 고치지 않아 `/harness-init`이 `apply.sh`를 찾지 못했다.

## 2026-11-11

### 추가
- 알림 훅 `stop-verify`(검증 없는 완료 보고)와 `subagent-scope`(서브에이전트의 범위 밖 수정).
- `sandbox` 프로필과 `.worktreeinclude` 템플릿.
- 플러그인 배포판: 훅·에이전트·스킬을 marketplace 플러그인으로 설치할 수 있다.
- 에이전트 memory 운용 규칙. `subagent-scope`는 에이전트 memory 디렉터리를 범위 밖 수정으로 보지 않는다.

### 변경
- 저장소 이름을 `dev_settings`에서 `ai_boilerplate`로 바꿨다. 이전 이름으로 설치한 환경은 이전 버전에서 제거한 뒤 다시 설치한다([docs/install.md](docs/install.md) 3절).
- README를 개요로 줄이고 세부를 `docs/`로 옮겼다.

## 2026-11-09

### 변경
- `apply.sh`는 `--profile`을 주지 않으면 언어 프로필을 적용하지 않는다.
- `install.sh`는 `worktree.baseRef`를 키 단위로 추적하고, 사용자가 지운 관리 항목을 다시 넣지 않는다.
- 공용 파서가 중첩 문자열과 heredoc 본문을 선형 시간에 다시 분석한다.

### 수정
- `guard-secrets`: 오탐을 줄이고 비밀 유출 경로를 더 잡는다.
- `guard-destructive`: `rm`·git·배포·pipe-to-shell 판정을 다듬었다.
- `guard-migrations`: 여러 마이그레이션 도구의 적용·롤백을 확인한다.

## 2026-11-06

### 변경
- CI가 gawk·mawk와 macOS의 bash 5로도 테스트한다.

### 수정
- alembic·`flask db`의 `--sql` 오프라인 모드를 읽기 전용으로 판정한다.
- 설치 롤백과 `--restore`가 심볼릭 링크를 다시 만든다.

## 2026-11-05

### 추가
- 언어·프레임워크와 무관한 Claude Code 보일러플레이트: 전역 하네스(설정·훅·규칙·에이전트·스킬), 프로젝트 템플릿, 선택형 프로필.
