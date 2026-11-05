---
paths:
  - "**/*.py"
---
# FastAPI 규칙

## 구조
- 라우터는 `routers/`(또는 프로젝트 관례)에 도메인별 `APIRouter`로 나누고 `prefix`·`tags`를 지정한다.
- 비즈니스 로직은 service 계층에 둔다. 엔드포인트는 검증된 입력으로 service를 호출하고 응답만 만든다.

## 스키마 (Pydantic v2)
- 요청·응답 모델을 분리한다(예: `OrderCreate`, `OrderUpdate`, `OrderRead`).
- `model_config = ConfigDict(...)`와 `Field(...)`로 제약(길이·범위·예시)을 둔다. v1 문법(`class Config`, `orm_mode`) 금지.
- 엔드포인트에 `response_model`과 `status_code`를 명시한다(생성 201, 삭제 204).
- 응답 모델에 민감 필드를 넣지 않는다.

## 의존성 주입
- DB 세션·인증 사용자·설정은 `Depends`로 주입한다. 모듈 전역 변수로 공유하지 않는다.
- 인증은 라우터 `dependencies=[...]`로 기본 적용한다. 공개 엔드포인트는 명시한 것만.
- DB 엔진·HTTP 클라이언트 같은 자원은 `lifespan`에서 한 번 만들고 닫는다(`@app.on_event` 금지).

## async 경계
- `async def` 안에서 블로킹 IO(동기 DB 드라이버·`requests`·`time.sleep`·큰 파일 IO) 금지.
- 블로킹 코드는 `def` 엔드포인트로 두거나 `run_in_threadpool`로 감싼다.
- 비동기 HTTP 호출은 `httpx.AsyncClient`를 쓴다.

## 에러·로깅
- 예상된 오류는 `HTTPException(status_code=..., detail=...)`로 낸다.
- 도메인 예외는 전역 예외 핸들러(`app.exception_handler`)에서 공통 에러 형식으로 바꾼다.
- 처리되지 않은 예외는 전역 핸들러에서 로깅하고 500으로 응답한다. 스택 트레이스를 응답에 넣지 않는다.

## 설정
- env는 `pydantic-settings`의 `BaseSettings` 한 곳에서 읽고, 캐시한 getter를 `Depends`로 주입한다.

## 마이그레이션 (Alembic)
- 적용된 revision은 수정하지 않는다. `alembic revision --autogenerate` 결과는 반드시 검토한다.
- 생성(`alembic revision`)·적용(`alembic upgrade`)은 메인 에이전트가 사용자 확인 후 한다(생성은 훅이 묻지 않는다 — 먼저 사용자에게 확인). 누락 검사는 `alembic check`.

## 테스트
- `httpx.AsyncClient`(`ASGITransport`) + `pytest-asyncio`, 또는 동기 `TestClient`를 쓴다.
- DB·인증·외부 API는 `app.dependency_overrides`로 교체한다.
- 엔드포인트마다 성공 · 검증 실패(422) · 권한(401/403) · 경계값.
