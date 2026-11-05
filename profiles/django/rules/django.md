---
paths:
  - "**/*.py"
  - "**/templates/**"
---
# Django · DRF 규칙

## 레이어
- View는 얇게: 요청 파싱·권한·응답만 다룬다. 비즈니스 로직은 service 모듈이나 model·manager 메서드에 둔다.
- `GenericAPIView`·ViewSet 계층을 쓰고, 불필요한 `get_object`·`get_queryset` 오버라이드를 피한다.
- 응답 형식은 프로젝트 공통 규칙을 따른다.

## Serializer
- 입력은 Serializer로 검증하고 `validated_data`만 쓴다. `request.data`를 모델에 바로 넣지 않는다.
- `fields`는 명시 목록으로 쓴다. `"__all__"` 금지(예상치 못한 필드 주입·민감 필드 노출 방지).
- 수정 불가 필드는 `read_only_fields`, 비밀번호 같은 필드는 `write_only`.
- `create`·`update`가 커지면 model·service 메서드로 옮긴다. 중첩 Serializer는 필요한 만큼만.

## 권한
- `permission_classes`를 명시한다. 기본은 `IsAuthenticated`, 공개는 `AllowAny`를 명시한 것만.
- 객체 단위 권한은 `get_queryset`의 소유 범위 필터나 `has_object_permission`으로 검사한다.

## 쿼리
- FK·OneToOne은 `select_related`, M2M·역참조는 `prefetch_related`.
- 반복문 안에서 쿼리 금지(N+1). 불필요한 `annotate`·`count`를 제거한다.
- queryset 평가 시점(`len()`·`list()`·슬라이싱·반복)을 의식한다.

## 예외
- DRF 예외를 쓴다: `ValidationError`(400), `PermissionDenied`(403), `NotFound`(404).
- `Model.DoesNotExist`는 잡아서 `NotFound`로 바꾼다. 의도치 않은 500이 나지 않게 한다.

## 마이그레이션
- 적용된 마이그레이션은 수정하지 않는다. 새 마이그레이션을 만든다.
- 스키마 변경과 데이터 마이그레이션(`RunPython`)은 분리한다.
- 누락 검사: `uv run python manage.py makemigrations --check --dry-run`.
- 생성(`makemigrations`)·적용(`migrate`)은 메인 에이전트가 사용자 확인 후 한다(생성은 훅이 묻지 않는다 — 먼저 사용자에게 확인).

## 문서·설정
- API 문서는 drf-spectacular `@extend_schema`(summary·description·tags·요청/응답 예시)로 쓴다.
- 설정은 env에서 읽는다. `SECRET_KEY`·DB 비밀번호 하드코딩 금지. 환경별 설정 모듈 구조는 프로젝트를 따른다.

## 테스트
- `APITestCase`(또는 pytest-django)로 status code·권한(401/403)·validation 실패 케이스를 함께 쓴다.
- serializer validation 테스트를 둔다. 외부 API는 mock한다.

## 명령 (uv 기준 — 다른 패키지 관리자면 `uv run`을 바꾼다)
| 작업 | 명령 |
|---|---|
| 개발 서버 | `uv run python manage.py runserver` |
| 시스템 검사 | `uv run python manage.py check` |
| 마이그레이션 누락 검사 | `uv run python manage.py makemigrations --check --dry-run` |
| 적용 계획 확인 | `uv run python manage.py migrate --plan` |
| 테스트 | `uv run pytest <경로> -x` |
| 셸 | `uv run python manage.py shell` |
