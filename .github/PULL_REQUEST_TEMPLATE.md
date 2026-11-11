## 요약

<!-- 무엇을 왜 바꿨는지 한두 문장 -->

## 변경

-

## 테스트

- [ ] `bash tests/run-all.sh`
- [ ] `bash scripts/validate.sh --repo --quiet`

<!-- 직접 확인한 것이 더 있으면 적는다. 확인하지 못한 것은 '미검증'으로 적는다. -->

## 리스크

<!-- 기존 설치·기존 프로젝트에 미치는 영향, 되돌리는 방법 -->

## 체크리스트

- [ ] 훅 판정을 고쳤으면 `tests/hooks/`에 통과·차단 케이스를 추가했다
- [ ] 동작이 바뀌었으면 `docs/`를 고쳤다(훅은 `docs/hooks.md`, 한계는 `docs/limitations.md`)
- [ ] 훅 등록을 바꿨으면 `plugin.json`의 `hooks`도 같이 바꿨다
- [ ] 사용자에게 보이는 변경이면 `CHANGELOG.md`의 `Unreleased`에 적었다
- [ ] 비밀·이메일·내부 호스트가 들어가지 않았다
