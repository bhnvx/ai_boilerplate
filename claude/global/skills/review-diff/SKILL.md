---
name: review-diff
description: 현재 변경(또는 지정한 base-ref·파일)의 diff를 모아 reviewer 서브에이전트로 독립 리뷰하고, Critical·High 지적은 직접 열어 확정한 뒤 심각도순으로 보고한다. 코드는 수정하지 않는다.
argument-hint: "[base-ref | 파일...]"
disable-model-invocation: true
allowed-tools:
  - 'Bash("${CLAUDE_SKILL_DIR}/context.sh" *)'
  - "Bash(${CLAUDE_SKILL_DIR}/context.sh *)"
  - "Bash(git diff *)"
  - "Bash(git status *)"
  - "Bash(git log *)"
  - "Bash(git rev-parse *)"
---

# /review-diff — 독립 diff 리뷰

인수: $ARGUMENTS

## 현재 상태(자동 수집)

!`"${CLAUDE_SKILL_DIR}/context.sh" "${CLAUDE_PROJECT_DIR}"`

## 따를 규칙

- 위임 원칙·프롬프트 7항목·고위험 영역·모델 표: `~/.claude/rules/subagent-policy.md` §2·§3·§5·§8 (여기에 다시 적지 않는다)
- 프로젝트 CLAUDE.md·`.claude/rules/`의 컨벤션을 리뷰 기준에 넣는다. 웹 프로젝트는 `~/.claude/rules/web.md`도 기준이다.

## 절차

1. 범위 결정
   - 인수 없음: `git diff HEAD`(스테이징 포함). 첫 커밋 전이면 `git diff --staged`.
   - 인수가 ref(`git rev-parse --verify <ref>`로 확인): `git diff <ref>...HEAD`. 미커밋 변경도 있으면 포함할지 묻는다.
   - 인수가 파일: `git diff HEAD -- <파일...>`.
   - untracked 파일이 리뷰 대상이면 내용을 직접 읽어 diff와 함께 넣는다.
   - 변경이 없으면 그렇게 보고하고 끝낸다.
2. diff 수집
   - reviewer에는 Bash가 없다 → diff 원문을 프롬프트에 그대로 넣는다(정책 §3-6).
   - diff가 4,000줄을 넘으면 파일(또는 모듈) 단위로 나눠 여러 reviewer에 위임한다. 동시 실행은 읽기 5개 이하.
   - 생성 파일·lockfile·스냅샷은 통계만 넣고 원문은 뺀다(뺀 목록은 보고에 적는다).
   - diff에 비밀 값이 보이면 위임하지 않고 멈춰서 사용자에게 알린다.
3. 모델 결정
   - 고위험 영역(정책 §5: 권한·인증, 캐시 무효화, 결제·금액·지표, 마이그레이션·스키마, 운영 설정, 동시성, 외부 데이터 스키마 매핑, 보안 경계)에 닿으면 `model: opus`.
   - 그 밖에는 `model: sonnet`. 큰 diff·복잡한 변경은 opus(정책 §2 표).
   - 사용자가 모델을 지정하면 그것을 따른다.
4. reviewer 실행 — Agent 도구, `subagent_type: reviewer`, 위 model 명시. 프롬프트는 정책 §3 7항목을 채운다.

   ```text
   목표: 아래 diff를 독립 리뷰한다. 사용자 요청: "<원문 인용>"
   범위: 읽을 곳 <변경 파일과 참조처> / 소유 파일 없음(수정 금지) / 보고만 한다
   확인한 사실: <경로:라인 — 이미 확인한 것>
   따를 규칙: <프로젝트 CLAUDE.md, .claude/rules/*, 관련 SKILL.md 경로>
   완료 조건: 지적마다 심각도(Critical/High/Medium/Low), 경로:라인, 근거, 수정 제안
   중점: 정확성, 보안 경계, 권한, 데이터 무결성, 테스트 누락, 컨벤션 위반
   diff:
   <diff 원문>
   ```

   - reviewer는 정의가 있는 에이전트이므로 보안 문장은 정의 본문을 따른다. 정의 없는 에이전트로 대체하면 정책 §7 보안 문장을 직접 넣는다.
5. 보고 검증 — reviewer 보고는 주장으로 취급한다(정책 §5).
   - Critical·High는 경로:라인을 직접 열어 확인하고 `확정` 또는 `추정`으로 다시 분류한다.
   - 근거가 틀린 지적은 `기각`으로 표시하고 이유를 한 줄로 적는다.
   - 근거가 불확실한 Critical·High는 opus reviewer로 재검증한다(정책 §2 표).
6. 결과 보고(심각도순)

   | 심각도 | 판정 | 위치 | 내용 | 수정 제안 |
   |---|---|---|---|---|

   - 마지막에 검토하지 못한 부분(제외한 파일, 분할로 놓친 교차 영향, 실행하지 않은 테스트)을 적는다.
   - 코드는 수정하지 않는다. 수정은 사용자가 요청하면 별도로 진행한다.

## 참고

- `/review`는 번들 `/code-review`의 별칭이라 이 스킬 이름은 `review-diff`다.
- reviewer 실패·API 오류는 정책 §9 대체 순서를 따른다.
