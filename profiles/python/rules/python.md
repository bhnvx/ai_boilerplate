---
paths:
  - "**/*.py"
  - "**/pyproject.toml"
---
# Python 규칙

## 도구
- 패키지 관리자는 lockfile·pyproject로 정한다: `uv.lock`·`[tool.uv]` → uv(`uv sync`, `uv run …`), `poetry.lock` → poetry(`poetry install`, `poetry run …`), `Pipfile` → pipenv, 그 밖(requirements.txt 등)은 프로젝트 문서의 방법. 섞어 쓰지 않는다. 아래 명령 예시는 uv 기준이다.
- 의존성 변경(`uv add`·`poetry add`·requirements 수정 등)은 사용자 확인 후 한다. 패키지 관리자를 거치지 않고 `pip install`로 직접 설치하지 않는다.
- 포매터·린터는 `pyproject.toml` 설정(ruff/black line-length·규칙)을 따른다. 설정을 완화하지 않는다.
- 검사: `uv run ruff check <파일>`, `uv run ruff format --check <파일>`(black 프로젝트는 `uv run black --check <파일>`).

## 스타일
- 네이밍: 함수·변수 `snake_case`, 클래스 `PascalCase`, 상수 `UPPER_SNAKE_CASE`.
- public 함수·메서드는 타입 힌트 필수(인자·반환).
- public 함수·클래스는 docstring 필수 — Google 스타일(`Args:` / `Returns:` / `Raises:`). 언어는 프로젝트 관례(없으면 한국어).
- import는 절대 경로. 순서: 표준 라이브러리 → 서드파티 → 로컬(그룹 사이 빈 줄).
- 함수는 50줄 이하, 단일 책임.
- 경로는 `pathlib.Path`로 다룬다.
- 구조화된 데이터는 `dataclass`나 pydantic 모델로 정의한다. 형태가 정해진 dict를 여기저기 넘기지 않는다.
- 환경 변수는 설정 모듈 한 곳에서 읽는다. 코드 곳곳에서 `os.environ`을 읽지 않는다.

```python
def get_user_by_email(email: str) -> User:
    """이메일로 사용자를 조회한다.

    Args:
        email: 조회할 이메일.

    Returns:
        조회된 사용자.

    Raises:
        UserNotFoundError: 사용자가 없을 때.
    """
```

## 로깅
- `logger = logging.getLogger(__name__)`. `print` 금지(CLI 출력 제외).
- lazy `%s` 포맷: `logger.info("로그인 완료: user_id=%s", user_id)` — f-string·`{}` 포맷 금지.
- 예외 로깅은 `logger.exception(...)` 또는 `exc_info=True`.
- 비밀·PII를 로그에 남기지 않는다.

## 예외
- 구체적인 예외를 잡는다. bare `except:`·`except Exception: pass` 금지.
- 처리할 수 없으면 로깅 후 다시 `raise`한다. 예외를 삼키지 않는다.
- try 블록은 실패할 수 있는 최소 구간만 감싼다.

## 테스트 (pytest)
- 신규·수정 기능마다 테스트: 성공 · 실패 · 경계값(None·빈 값·최대).
- 공통 데이터는 fixture(`conftest.py`)로 둔다.
- 외부 API는 `unittest.mock.patch`·`monkeypatch`로 mock한다.
- 실행: `uv run pytest <경로> -x`(빠른 실패). 전체 실행은 한 시점에 하나.
