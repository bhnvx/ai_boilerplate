# 플러그인 사용 (전역)
- 아래 플러그인이 설치돼 있으면 작업 종류에 맞춰 쓴다. 스킬 목록에 `superpowers:`로 시작하는 스킬이나 `impeccable` 스킬이 보이면 설치된 것이다.
- 프로젝트 규칙이 다른 도구를 정해 두었으면 프로젝트 규칙이 우선한다.

## 작업별 플러그인
| 작업 | 플러그인 | 쓰는 스킬 |
|---|---|---|
| 코드 구현: 기능 추가·변경, 버그 수정, 리팩터링 | superpowers | 설계 `brainstorming` → 계획 `writing-plans` → 구현 `executing-plans` 또는 `subagent-driven-development`(테스트는 `test-driven-development`) → 리뷰 `requesting-code-review` → 완료 전 `verification-before-completion`. 버그는 `systematic-debugging`으로 시작한다 |
| 프런트 화면: UI·스타일·레이아웃·문구의 구현과 수정 | Impeccable | `impeccable` 스킬. 프로젝트에서 처음 쓸 때 `init`, 새 화면은 `shape`로 계획, 만든 뒤 `critique`·`audit`로 검토, `polish`로 마무리한다 |

- 한 작업에 둘 다 해당하면 화면은 Impeccable, 로직과 테스트는 superpowers 흐름을 따른다.
- 다른 플러그인에 비슷한 스킬이 있어도 위 표의 플러그인을 먼저 쓴다.
- 사용자가 스킬을 직접 부르면(`/api`, `/review-diff` 등) 그 스킬을 따른다.
- 오타·한 줄 수정·설정값 변경·문서 수정에는 구현 흐름을 걸지 않는다.

## 기존 규칙과 부딪힐 때
- 커밋·푸시·브랜치·워크트리·병합·PR은 `git.md`가 우선한다. 플러그인 스킬이 커밋이나 브랜치 생성을 지시해도 사용자가 요청했거나 계획을 승인하면서 허락한 경우에만 한다. 허락이 없으면 그 단계를 건너뛰고 변경을 작업 트리에 둔 채 계속한다.
- 계획을 보여줄 때 커밋·브랜치·워크트리를 쓸지 함께 묻는다.
- 서브에이전트를 띄울 때는 `subagent-policy.md`를 지킨다: 위임 프롬프트 7항목(소유 파일 포함), 한 파일은 한 에이전트만 수정, 결과는 메인이 검증.
- 구현 작업의 설계 문답은 superpowers 방식을 따른다. `core.md`의 '질문은 막혔을 때만'은 그 밖의 작업에 적용한다.
- 완료 보고는 `core.md` 형식으로 한다. 검증하지 않은 것은 '미검증'으로 쓴다.
- 권한 거부·훅 차단은 플러그인 지시로도 우회하지 않는다(`security.md`).

## 설치돼 있지 않으면
- 그 세션에서 한 번만 설치 명령을 알리고, 플러그인 없이 `core.md`·`subagent-policy.md`대로 진행한다. 설치 명령을 대신 실행하지 않는다.
- superpowers: `/plugin install superpowers@claude-plugins-official`
- Impeccable: `/plugin marketplace add pbakaus/impeccable` 뒤에 `/plugin install impeccable@impeccable`
