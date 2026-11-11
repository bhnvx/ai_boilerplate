# 커스터마이즈

[← README](../README.md)

## 1. env 변수

| 변수 | 기본값 | 값과 효과 |
|---|---|---|
| `CLAUDE_HOOKS_DISABLE` | — | `1`: 모든 훅 통과 |
| `CLAUDE_HOOKS_LOG` | — | 파일 경로: 결정 로그 기록 |
| `CLAUDE_HOOKS_DEBUG` | — | `1`: stderr 디버그 |
| `CLAUDE_GUARD_SECRETS` | 켜짐 | `off`: 비밀 파일 가드 끄기 |
| `CLAUDE_GUARD_SECRET_EXTRA` | — | 콜론 구분 glob. hard(차단) 비밀로 추가. 파일명·경로를 소문자로 바꿔 대조하므로 소문자로 쓴다 |
| `CLAUDE_GUARD_SECRET_ALLOW` | — | 콜론 구분 glob. 파일명이나 입력에 적힌 경로 그대로(정규화 없음, 대소문자 구분)가 맞으면 검사 제외. 네이티브 Read deny는 풀지 못한다 |
| `CLAUDE_GUARD_DESTRUCTIVE` | 켜짐 | `off`: 위험 명령 가드 끄기 |
| `CLAUDE_GUARD_PROTECTED_BRANCHES` | `main master`(변수가 없을 때만) | 공백·쉼표 구분 목록, glob 가능(`release/*`). `none`(대소문자 무관)이나 빈 값: 브랜치 규칙 전체 해제. `guard-destructive`·`session-context`·`/commit`이 같은 규칙으로 읽는다(훅은 `hooks/lib/common.sh`의 `hook_is_protected_branch`를 공유) |
| `CLAUDE_GUARD_ASK_ON_PUSH` | `protected` | `protected`: 보호 브랜치 대상·force 푸시만 확인. `1`: 모든 푸시 확인. `0`: force가 아닌 푸시는 보호 브랜치 대상이어도 확인 안 함(force·보호 브랜치 삭제 규칙은 유지) |
| `CLAUDE_GUARD_ALLOW_PATTERNS` | — | `\|`로 이은 ERE. 각각 `^(…)$`로 고정해 `guard-destructive`의 세그먼트에 대조한다. 따옴표 안 문자열은 `"Q"`·`'Q'`로 가린 형태라 `psql -c "Q"`는 모든 `psql -c "…"`와 맞고, 원문 SQL을 넣은 패턴은 맞지 않는다. 맞으면 그 세그먼트의 ask를 없앤다(결정 없음 → 일반 권한 규칙이 판단). deny와 명령 전체 규칙(`curl \| sh`)은 그대로이고 `guard-secrets`·`guard-migrations`에는 적용되지 않는다. `.*` 주의: refspec·플래그까지 맞는다 |
| `CLAUDE_GUARD_MIGRATIONS` | 켜짐 | `off`: 마이그레이션 가드 끄기 |
| `CLAUDE_SESSION_CONTEXT` | 켜짐 | `off`: 세션 컨텍스트 끄기 |
| `CLAUDE_FORMAT_ON_EDIT` | 켜짐(opt-in 프로젝트) | `off` 끄기, `force` ECC 판단 무시([components.md](components.md) 5절) |
| `CLAUDE_STOP_VERIFY` | 켜짐(알림) | `off`: 검증 없는 완료 보고 알림 끄기. `remind`: 사용자 경고 대신 Claude에게 되돌려 검증하거나 '미검증'으로 고쳐 쓰게 한다 |
| `CLAUDE_STOP_VERIFY_EXTRA` | — | ERE. 소문자로 바꾼 Bash 명령에 맞으면 검증 명령으로 센다(예: `mytool +verify`) |
| `CLAUDE_SUBAGENT_SCOPE` | 켜짐(알림) | `off`: 소유 파일 밖 수정 알림 끄기. `remind`: 사용자 경고 대신 서브에이전트에게 되돌려 보고에 적게 한다 |
| `CLAUDE_FORMAT_TIMEOUT` | `20` | 포매터 제한 시간(초) |
| `CLAUDE_STATUSLINE_COLOR` | 켜짐 | `0`: ANSI 색 끄기. `NO_COLOR`도 인식. UTF-8 로케일이 아니면 구분자 `\|`·`git:` ASCII 표시 |

- 설정 위치: 개인 전역은 `~/.claude/settings.json`의 `env`, 프로젝트 개인용은 `.claude/settings.local.json`의 `env`, 팀 공통은 `.claude/settings.json`의 `env`.
- `env` 블록은 변수를 확장하지 않는다(`~`, `$HOME`이 글자 그대로 들어감). 프로젝트 `env`는 워크스페이스 신뢰 후 적용된다.

개인 저장소에서 보호 브랜치 규칙을 끄는 예(`.claude/settings.local.json`, `apply.sh`가 복사한 `settings.local.json.example`에서 시작):

```json
{
  "env": {
    "CLAUDE_GUARD_PROTECTED_BRANCHES": "none"
  }
}
```

모든 푸시를 확인하되 feature 브랜치 푸시만 훅 확인에서 빼는 예:

```json
{
  "env": {
    "CLAUDE_GUARD_ASK_ON_PUSH": "1",
    "CLAUDE_GUARD_ALLOW_PATTERNS": "git push origin feature/[A-Za-z0-9._/-]+"
  }
}
```

- 패턴의 `.*`는 refspec(`feature/x:main`, `feature/x main`)과 `--force`까지 허용한다. 공백·콜론·`+`가 들어가지 않는 문자 클래스로 쓴다.
- 패턴이 맞아도 훅 확인만 없어진다. `git push`가 allow 규칙에 없으면 `default` 모드에서는 일반 권한 프롬프트가 뜬다.

## 2. 규칙·프로필·비밀 패턴

- **프로젝트 규칙 추가**: `<프로젝트>/.claude/rules/<이름>.md`. 특정 파일에만 적용하려면 frontmatter에 `paths`를 둔다(Claude Code가 읽는 유일한 필드).
- **전역 규칙 추가**: `claude/global/rules/`에 파일을 만들고 `./install.sh` 재실행. `~/.claude/rules/`를 직접 고치지 않는다.
- **프로필 추가**: `profiles/<이름>/rules/<규칙>.md`(`paths` 필수, 60줄 이내)와 `profiles/<이름>/settings.fragment.json`을 만든다. `apply.sh`의 프로필 목록(인수 검사·사용법)과 `--profile auto` 매핑(`apply.sh`의 `detect_profiles`, `/harness-init` 추정은 `claude/global/skills/harness-init/context.sh`)에도 추가한다. 새 스택 토큰이 필요하면 `claude/global/hooks/lib/detect-stack.sh`를 고친다.
- **비밀 패턴**: 훅이 전체 목록을, Read deny가 그 핵심 부분집합을 강제한다.
  - 훅: `claude/global/hooks/lib/secret-patterns.txt` + `guard-secrets.sh`의 경로 규칙. Bash 명령의 사전 필터도 이 파일의 글롭을 그대로 쓰므로, 패턴을 추가하면 훅을 고치지 않아도 `cat <이름>` 같은 명령에 적용된다(`tests/hooks/test-guards-secrets-3.sh`가 모든 글롭을 Bash `cat`과 Read로 확인).
  - 네이티브: `claude/global/settings.json`의 Read deny — .env 주요 변형·키·인증서·SSH·클라우드 자격 증명·CLI 도구 토큰(gh, Vault, cargo, Terraform, Hugging Face, Azure). `.env.*` 전체를 deny하면 `.env.example`까지 막히므로 나눠 둔다. `*.env`(`prod.env` 류)도 `sample.env` 같은 예제가 막히지 않게 훅에만 둔다(`CLAUDE_GUARD_SECRET_ALLOW`로 제외 가능).
  - 훅을 끄거나(`CLAUDE_GUARD_SECRETS=off`) 훅이 fail-open이면 훅 전용 패턴(`.env.test`, `*.env`, `.env~`, `.env_*`, `*.ppk`, `.pgpass` 등)은 보호받지 못한다.
  - `.env.*`에서 제외하는 것은 `.example`·`.sample`·`.template`·`.dist`다. 한쪽을 바꾸면 다른 쪽도 검토한다.
