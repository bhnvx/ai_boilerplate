# 기여 방법

[← README](README.md)

버그 신고, 가드 오탐·미탐 제보, PR 모두 받는다. 저장소 구조와 테스트 구성은 [docs/development.md](docs/development.md), 작업 규칙 전체는 [CLAUDE.md](CLAUDE.md)에 있다.

## 1. 이슈

이슈를 열 때 템플릿을 고른다.

| 템플릿 | 쓰는 경우 |
|---|---|
| 버그 신고 | 설치·적용·훅·스킬이 문서와 다르게 동작한다 |
| 가드 오탐·미탐 | 훅이 정상 명령을 막았거나, 막아야 할 명령을 통과시켰다 |
| 기능 제안 | 새 규칙·프로필·훅·옵션 |

- 비밀 값·토큰·내부 호스트·개인 정보는 붙여 넣지 않는다.
- 가드 판정을 제보할 때는 훅이 낸 사유를 그대로 적는다. 사유에 규칙 ID가 붙어 있다(예: `차단 [secrets:print]: …`).
- 판정 과정을 더 보려면 `CLAUDE_HOOKS_LOG=<파일 경로>`를 설정해 훅 결정 로그를 남긴다([docs/customization.md](docs/customization.md) 1절).
- 보안 문제는 공개 이슈로 올리지 않는다. [SECURITY.md](SECURITY.md)를 따른다.

## 2. 개발 환경

필요한 도구는 `python3` 3.8+와 `git`이다. `jq`는 있으면 쓴다. 따로 설치할 의존성은 없다.

```bash
git clone https://github.com/bhnvx/ai_boilerplate.git
cd ai_boilerplate
bash tests/run-all.sh                       # 훅·스킬·설치 테스트 전체
bash scripts/validate.sh --repo --quiet     # 저장소 구성 검사
```

- 테스트는 실제 `~/.claude`를 건드리지 않는다. 직접 실행해 볼 때도 `./install.sh --home <임시 디렉터리>`와 임시 프로젝트 디렉터리를 쓴다.
- 일부만 돌리려면 `bash tests/run-all.sh --filter <부분문자열>`, 빠르게 보려면 `--quick`을 쓴다.

## 3. 지켜야 할 것

- **bash 3.2 호환**(macOS `/bin/bash`): 연관 배열, `${v,,}`, `mapfile`, `declare -g`, `local -n`을 쓰지 않는다. `[[ =~ ]]`의 정규식은 변수에 담는다.
- **GNU 전용 도구 금지**: `sed -i`, `readlink -f`, `realpath`, `stat`, `sha256sum`, `timeout`, `grep -P`, `date -d`.
- **awk는 POSIX 기능만**: macOS BWK awk·gawk·mawk에서 출력이 같아야 한다. CI가 셋 다 돌린다.
- **훅**: `set -u`를 쓰지 않는다. 결정은 stdout JSON과 exit 0으로만 내고(exit 2 금지), `jq`·`python3`가 없으면 막지 않고 통과한다.
- **템플릿 이름**: `claude/` 아래에 `CLAUDE.md` 파일이나 `.claude/` 디렉터리를 만들지 않는다. `CLAUDE.md.tmpl`·`dot-claude/`로 둔다.
- **언어**: 문서·규칙·훅 메시지는 한국어, 식별자는 영어.
- **공개 저장소**: 비밀·이메일·전화번호·고객명·내부 호스트를 넣지 않는다. CI가 키·이메일 패턴을 검사한다.

## 4. 변경할 때 함께 고칠 것

| 고친 것 | 함께 고칠 것 |
|---|---|
| 훅 판정 | `tests/hooks/`에 통과·차단 케이스, `docs/hooks.md`(한계는 `docs/limitations.md`) |
| 훅 등록(`claude/global/settings.json`의 `hooks`) | `claude/global/.claude-plugin/plugin.json`의 `hooks` |
| 비밀 패턴(`secret-patterns.txt`·`guard-secrets.sh`) | `claude/global/settings.json`의 Read deny |
| 설치·적용 동작 | `tests/install/`, `docs/install.md` |
| 사용자에게 보이는 변경 | `CHANGELOG.md`의 `Unreleased` |

## 5. 커밋과 PR

- 커밋 메시지는 [claude/global/rules/git.md](claude/global/rules/git.md)를 따른다: `<gitmoji> scope: subject`(subject는 영어 명령형), body는 한국어로 '왜'를 쓴다.
- PR을 열기 전에 2절의 두 명령이 통과하는지 확인한다.
- PR 본문은 템플릿(요약 · 변경 · 테스트 · 리스크)을 채운다.
- 한 PR에는 한 가지 변경만 담는다. 가드 규칙을 고칠 때는 재현 명령을 테스트 케이스로 넣는다.

## 6. 라이선스

기여한 내용은 이 저장소의 [MIT 라이선스](LICENSE)로 배포된다.
