# 프로젝트 보충 규칙 (서브에이전트 위임용)
<!-- TODO: 이 프로젝트에 맞게 채운다. 메인 에이전트는 위임 프롬프트에 관련 항목을 넣는다(dev_settings 전역 정책을 쓰는 경우 subagent-policy §2·§3·§4 참고). HTML 주석은 Claude에게 전달되지 않는다. -->
- 메인 에이전트는 위임할 때 아래 항목 중 관련된 것을 위임 프롬프트에 넣는다(서브에이전트는 이 파일을 직접 보지 못할 수 있다).

## 환경 함정
<!-- TODO: 병렬 실행 시 충돌하는 자원과 실행 전 준비. -->
- 테스트 DB·포트·캐시 공유 여부: <예: 테스트 DB 하나를 공유 → 테스트는 한 시점에 하나>
- 가상환경·런타임 경로: <예: `.venv/`(uv sync로 생성) / `node_modules/`>
- 실행 전 필요한 env: <예: `APP_ENV=local` — 키 목록은 `.env.example` 참조, 값은 적지 않는다>
- 느리거나 외부에 닿는 작업: <예: 전체 테스트 5분 이상, 일부 테스트가 외부 API 호출>

## 공유 핫스팟 (메인 전용)
<!-- TODO: 서브에이전트가 수정하지 않는 파일. 기본 목록에 이 프로젝트의 실제 경로를 채운다. -->
- 의존성 매니페스트·lock: <예: `pyproject.toml`, `uv.lock` / `package.json`, `pnpm-lock.yaml`>
- 마이그레이션: <예: `*/migrations/`, `alembic/versions/`, `prisma/migrations/`>
- 라우팅·전역 설정: <예: `config/urls.py`, `config/settings/`, `src/app.ts`>
- CI·배포: <예: `.github/workflows/`, `Dockerfile`, `compose*.yml`>
- 에이전트 규칙: `CLAUDE.md`, `.claude/**`
- 기타: <예: 코드에서 생성하는 문서·스키마 파일>

## 검증 명령 (소유 파일만)
<!-- TODO: 서브에이전트가 자기 소유 파일에만 실행하는 형식. <files>에 파일 경로를 넣는다. 저장소 전체 대상 명령은 쓰지 않는다. -->
- 린트: <예: `uv run ruff check <files>` / `pnpm eslint <files>`>
- 포맷 검사: <예: `uv run ruff format --check <files>` / `pnpm prettier --check <files>`>
- 타입체크: <예: `npx --no-install tsc --noEmit` — 프로젝트 단위 검사라면 메인만 실행>
- 테스트(위임 프롬프트가 허용한 경우만): <예: `uv run pytest <test-files> -x`>

## 금지 사항
<!-- TODO: 이 프로젝트에서 서브에이전트에게 특히 금지할 것. -->
- <예: 외부 API 실호출 금지 — 테스트는 mock>
- <예: `scripts/`의 운영 데이터 스크립트 실행 금지>
- <예: 생성 파일(빌드 산출물·자동 생성 클라이언트) 직접 수정 금지>
