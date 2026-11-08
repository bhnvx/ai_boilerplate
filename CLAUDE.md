# dev_settings — 저장소 작업 가이드

Claude Code 보일러플레이트 저장소다. 언어·프레임워크 무관한 전역 하네스와 프로젝트 템플릿이 핵심이고, 언어 프로필은 `apply.sh --profile <이름>|auto`를 줄 때만 적용하는 선택형 add-on이다(생략하면 적용하지 않는다).

## 구조
- `claude/global/` → `~/.claude/`에 설치(install.sh): settings.json, rules/, agents/, hooks/, skills/, CLAUDE.md.tmpl
- `claude/project-template/` → 프로젝트에 적용(apply.sh): CLAUDE.md.tmpl, CLAUDE.local.md.example, gitignore.claude, dot-claude/
- `profiles/<name>/` — 선택형 프로필(rules/*.md + settings.fragment.json)
- `scripts/` — merge-settings.py, validate.sh, update-schema.sh, lib/(install.sh·apply.sh 공용 install-*.sh)
- `tests/` — run-all.sh, lib/, hooks/, skills/, install/
- `schemas/` — settings JSON 스키마 스냅샷
- `vscode/`, `copilot/` — 에디터·Copilot 설정(Claude Code와 별개)
- 상세 설명은 README.md.

## 규칙
- 이 PC의 실제 `~/.claude`를 수정하지 않는다. install.sh 테스트는 `--home <임시 디렉터리>`, apply.sh 테스트는 임시 프로젝트 디렉터리로만 한다.
- 셸 스크립트는 bash 3.2 호환(macOS `/bin/bash`)으로 쓴다:
  - 금지: 연관 배열, `${v,,}`·`${v^^}`, `mapfile`, `declare -g`, `local -n`, `[[ =~ ]]`에 정규식 직접 쓰기(변수에 담는다)
  - GNU 전용 금지: `sed -i`, `readlink -f`, `realpath`, `stat`, `sha256sum`, `timeout`, `grep -P`, `date -d`
  - 훅: `set -u` 금지, 결정은 stdout JSON + exit 0으로만(exit 2 금지), jq·python3가 없으면 fail-open
  - 모든 `.sh`는 `/bin/bash -n` 통과
- awk는 POSIX 기능만 쓰고 macOS `/usr/bin/awk`(BWK)·gawk·mawk에서 출력이 같아야 한다(CI가 셋 다 돌린다): `gensub`·`asort`·`strftime`·`systime`·`PROCINFO`·`IGNORECASE`·`FPAT`·`nextfile` 금지
- 변경 후 실행한다: `bash tests/run-all.sh`, `bash scripts/validate.sh --repo --quiet`(`--quiet` 없이는 run-all.sh를 한 번 더 돌린다)
- 훅을 고치면 `tests/hooks/`에 통과·차단 케이스를 함께 추가한다.
- 템플릿 명명은 `CLAUDE.md.tmpl`, `dot-claude/`로 한다:
  - 이유: 이 저장소에서 작업할 때 Claude Code가 하위 `CLAUDE.md`·`.claude/rules/`를 불러오지 않게 하려는 것
  - install.sh·apply.sh가 복사할 때 이름을 바꾼다
  - `claude/` 아래에 `CLAUDE.md` 파일이나 `.claude/` 디렉터리를 만들지 않는다
- 비밀 패턴: 훅(`claude/global/hooks/lib/secret-patterns.txt` + `guard-secrets.sh`의 경로 규칙)이 전체 목록을, `claude/global/settings.json`의 Read deny가 그 핵심 부분집합(.env 주요 변형·키·인증서·SSH·클라우드 자격 증명·CLI 도구 토큰)을 강제한다. 한쪽을 바꾸면 다른 쪽도 검토한다. `.env.*`에서 제외하는 것은 `.example`·`.sample`·`.template`·`.dist`다.
- 문서·규칙·훅 메시지는 한국어, 식별자는 영어로 쓴다.
- 공개 저장소다: 비밀·이메일·전화번호·고객명·내부 호스트를 넣지 않는다.
- 커밋 컨벤션은 `claude/global/rules/git.md`와 같다.
