# Python + DRF Copilot Code Review Guide

## 1. 코드 리뷰 목적

* 코드의 정확성 검증
* 유지보수성 향상
* 스타일 일관성 확보
* 보안 및 성능 이슈 조기 발견
* 팀 컨벤션 및 아키텍처 준수 확인

---

## 2. 주요 리뷰 체크리스트

### 2.1 구조 & 설계

* View / Serializer / Model / Service 레이어가 적절히 분리되어 있는가?
* 비즈니스 로직을 View에 과도하게 넣지 않았는가?
* 재사용 가능한 로직이 서비스/유틸로 분리되어 있는가?

---

### 2.2 API View 검토 포인트

* 클래스 기반 View 사용 시 적절한 GenericAPIView 계층을 타고 있는가?
* 불필요한 `get_object`, `get_queryset` 오버라이드가 있는가?
* Queryset 평가 시점이 적절한가?
* Response 포맷이 프로젝트 공통 규칙을 따르고 있는가?

#### 예시

```python
class UserView(APIView):
    def get(self, request):
        users = User.objects.all()
        return Response(UserSerializer(users, many=True).data)
```

---

### 2.3 Serializer 검토 포인트

* `validated_data` 사용이 올바른가?
* `create` / `update` 오버라이드 내용이 Model 메서드로 옮겨야 하는 수준은 아닌가?
* 중첩 Serializer 사용이 불필요하게 비대하지 않은가?

---

### 2.4 Model 검토 포인트

* 비즈니스 로직이 Model 또는 Manager로 적절히 이동되어 있는가?
* `auto_now`, `auto_now_add` 등 필드 동작이 의도된 대로인가?
* 과도한 DB 쿼리를 유발하는 관계 필드는 없는가?

---

### 2.5 퍼포먼스 체크

* N+1 쿼리를 유발하는지 (`select_related`, `prefetch_related` 검토)
* 반복문 내에서 DB 호출이 있는지
* 필요 없는 annotate/count가 있는지

---

### 2.6 보안 측면

* 인증/인가가 제대로 적용되어 있는가?
* 사용자 입력 검증이 확실한가?
* Serializer에 unexpected field injection 위험은 없는가?
* 민감 데이터가 Response에 노출되지 않는가?

---

### 2.7 예외 처리

* `try/except`가 광범위하게 잡고 있지 않은가?
* DRF 예외(`ValidationError`, `NotFound`, `PermissionDenied`)를 적절히 활용했는가?
* 의도치 않은 500이 발생할 가능성은 없는가?

---

### 2.8 스타일 & 컨벤션

* PEP8 + ruff + black + isort 규칙 준수
* 함수/클래스 docstring 작성
* 타입 힌트 누락 여부
* 네이밍 일관성

---

## 3. 자동 리뷰 프롬프트 (Copilot 입력용)

```
You are a senior Python/Django REST Framework reviewer.
Review the following code with focus on:

1. API design consistency
2. View/Serializer/Model layer separation
3. Query optimization (N+1, select_related, queryset evaluation)
4. Security checks (permissions, validation, data leakage)
5. Error handling (DRF exceptions)
6. Code maintainability and reusability
7. PEP8, naming, type hints, file structure

Return a structured review with:
- Major issues
- Minor issues
- Suggested improvements
- Performance risks
- Security risks
- Refactor recommendations
- Use Korean for all responses
```

---

## 4. 리뷰 코멘트 템플릿

### Major Issue Template

```
### 🔴 Major Issue: [Title]
- 설명: 문제점 요약
- 이유: 왜 문제인지
- 제안 사항: 해결책
```

### Minor Issue Template

```
### 🟡 Minor Issue: [Title]
- 설명
- 제안 사항
```

### Refactor Template

```
### 🟢 Refactor Suggestion
- 문제되는 코드
- 개선된 코드 예시
```

---

## 5. 테스트 리뷰 기준

* DRF APITestCase 사용 여부
* Mock/Stubbing 적절성
* status code 검증 범위
* edge case 테스트 포함 여부
* serializer validation 테스트 포함 여부
