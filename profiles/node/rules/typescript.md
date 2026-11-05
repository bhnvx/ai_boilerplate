---
paths:
  - "**/*.{ts,tsx,js,jsx,mjs,cjs}"
  - "**/package.json"
  - "**/tsconfig.json"
---
# TypeScript · Node 규칙

## 패키지 매니저
- lockfile로 정한다: `pnpm-lock.yaml` → pnpm, `yarn.lock` → yarn, `package-lock.json` → npm, `bun.lock`·`bun.lockb` → bun. 섞어 쓰지 않는다.
- 전역 설치(`-g`) 금지. 로컬 의존성 도구는 `npx --no-install <도구>`(레지스트리에서 받지 않음)로, 일회성 외부 도구는 사용자 확인 후 `npx`·`pnpm dlx`로 실행한다.
- 의존성 추가·제거는 사용자 확인 후 한다. lockfile을 손으로 고치지 않는다.

## 타입
- `strict`를 유지한다. `any` 금지 → `unknown`으로 받고 타입 가드로 좁힌다.
- `@ts-ignore` 금지. 불가피하면 `@ts-expect-error` + 이유 주석.
- 모듈 경계의 타입은 명시적으로 export한다(`export type`).
- 외부 입력(API 응답·요청 본문·env)은 런타임 검증(zod 등) 후 쓴다.

## 비동기·에러
- `async`/`await`를 쓴다. 모든 Promise는 `await`하거나 반환하거나 명시적으로 처리한다(unhandled rejection 금지).
- `catch`에서 에러를 삼키지 않는다. 로깅 후 다시 던지거나 의미 있는 에러로 바꾼다.
- `catch (e)`의 `e`는 `unknown`으로 다룬다.

## 로깅·출력
- `console.log` 대신 프로젝트 로거를 쓴다. 테스트·CLI 출력은 예외.
- 비밀·PII를 로그에 남기지 않는다.

## 스타일
- ESLint·Prettier는 저장소 설정을 따른다. 규칙을 끄거나 완화하지 않는다.
- import 순서: 내장(`node:` 접두사) → 외부 패키지 → 내부 별칭(`@/`) → 상대 경로.
- 환경 변수는 한 모듈에서 읽고 검증해 export한다. 곳곳에서 `process.env`를 읽지 않는다.
- 프런트 공개 env(`NEXT_PUBLIC_*`·`VITE_*` 등)에 비밀을 넣지 않는다.

## 테스트
- 저장소의 러너를 따른다(vitest 또는 jest).
- React는 Testing Library로 사용자 동작 중심으로 쓴다(`getByRole` 우선). 내부 state·구현 세부를 테스트하지 않는다.
- 외부 API는 mock(msw 등). 성공 · 실패 · 경계값.

## 검사 명령
- 타입체크: `npm run typecheck`(스크립트가 있으면) 또는 `npx --no-install tsc --noEmit`.
- 린트·테스트: `npm run lint`, `npm test -- <파일>`. 패키지 매니저에 맞게 `pnpm`·`yarn`·`bun`으로 바꾼다.
