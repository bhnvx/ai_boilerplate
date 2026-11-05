---
name: preflight
description: PR·배포 전 점검. 베이스 대비 변경을 모아 린트·타입체크·테스트, 마이그레이션 누락, 환경 변수 동기화, 시크릿 후보, lockfile 동기화, API 문서 갱신을 확인하고 PR 체크리스트와 PR 본문 초안으로 보고한다. 수정은 사용자 확인 후.
argument-hint: "[base-ref]"
disable-model-invocation: true
allowed-tools:
  - 'Bash("${CLAUDE_SKILL_DIR}/context.sh" *)'
  - "Bash(${CLAUDE_SKILL_DIR}/context.sh *)"
---

# /preflight — PR 전 점검

인수: $ARGUMENTS

## 현재 상태(자동 수집)

!`"${CLAUDE_SKILL_DIR}/context.sh" "${CLAUDE_PROJECT_DIR}" "$ARGUMENTS"`

## 따를 규칙

- PR 체크리스트·PR 본문 형식: `~/.claude/rules/git.md`
- 마이그레이션 안전·env·테스트 계층: `~/.claude/rules/web.md`
- 비밀 값 처리: `~/.claude/rules/security.md`
- 명령은 프로젝트 CLAUDE.md의 `## 명령어`가 우선한다.

## 절차

1. 컨텍스트 해석과 명령 목록
   - 위 "프로젝트 명령"에서 린트, 포맷 검사, 타입체크, 테스트 명령을 고른다.
   - 블록이 없으면 "감지된 스택"과 명령 힌트로 기본값을 제안하고 확인받는다. 예시:

     | 스택 | 린트·포맷 검사 | 타입체크 | 테스트 |
     |---|---|---|---|
     | python(uv) | `uv run ruff check .` · `uv run ruff format --check .` | `uv run mypy .`(설정이 있을 때) | `uv run pytest -x` |
     | node | `npm run lint` · `npx --no-install prettier --check .`(설정이 있을 때) | `npx --no-install tsc --noEmit` | `npm test` |
     | go | `gofmt -l .` · `go vet ./...` | (빌드에 포함) | `go test ./...` |
     | rust | `cargo fmt --check` · `cargo clippy` | (빌드에 포함) | `cargo test` |

   - 실행할 명령 목록을 먼저 보여준다. 포맷은 검사 모드(`--check`)만 쓰고 파일을 고치는 모드는 쓰지 않는다.
   - 읽기 전용 검사(린트·포맷 검사·타입체크)는 바로 실행한다. 테스트는 한 번에 하나씩(DB·포트 공유).
   - 이 명령들은 `allowed-tools`에 없으므로 일반 권한 프롬프트가 뜰 수 있다.
2. 마이그레이션 누락
   - "신호"에 모델·스키마 변경이 있고 마이그레이션 변경이 없으면 경고한다.
   - 프로젝트의 `--check` 류 명령을 실행한다(예: Django `uv run python manage.py makemigrations --check --dry-run`). DB 접속이 필요한 명령은 대상 DB가 로컬인지 먼저 확인한다.
   - 마이그레이션 변경이 있으면 이미 적용된 파일을 고쳤는지, 파괴적 변경이 2단계로 나뉘었는지 본다. 생성·적용은 하지 않는다.
3. 환경 변수 동기화
   - "환경 변수"에 예시 파일(`.env.example`, `.env.production.example` 등 `.env*.example|.sample|.template|.dist`)에 없는 키가 있으면 목록으로 보고하고, 예시 파일·문서에 추가할지 묻는다.
   - settings 참조 키는 실제 환경 변수인지 코드에서 확인한 뒤에만 보고한다.
4. 시크릿 스캔
   - "시크릿 스캔"에 후보가 있거나 "비밀 파일 의심" 경로가 있으면 즉시 중단하고 위치(경로:줄)만 보고한다. 값은 읽거나 출력하지 않는다.
   - 사용자가 오탐이라고 확인하면 계속한다.
5. 의존성
   - 매니페스트가 바뀌었는데 lockfile이 그대로면 동기화를 확인한다(예: `uv lock --check`). 의존성 추가 자체는 사용자 확인 사항이다.
6. API·문서
   - 라우트·스키마·직렬화가 바뀌었으면 OpenAPI(스키마 파일·데코레이터)와 README·API 문서가 갱신됐는지 확인한다.
   - 클라이언트에 영향을 주는 변경(필드 제거·이름 변경·상태 코드 변경)은 리스크로 적는다.
7. 결과 보고 — git.md의 PR 체크리스트 양식으로, 항목마다 `통과` / `실패` / `미확인`.

   | 항목 | 결과 | 근거(명령·요지) |
   |---|---|---|
   | 테스트 | | |
   | 포맷·린트 | | |
   | 문서 | | |
   | 마이그레이션 | | |
   | 미사용 코드 | | |
   | 시크릿 없음 | | |

   이어서 PR 본문 초안:

   ```markdown
   ## 요약
   ## 변경
   ## 테스트
   ## 리스크
   ```

   - 실패 항목의 수정은 목록만 제시하고, 사용자 확인 후에 고친다.
   - 커밋·푸시·PR 생성은 하지 않는다. 커밋은 사용자가 `/commit`(수동 스킬)을 실행하도록 안내한다.
