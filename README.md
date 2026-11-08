# dev_settings

Claude Code 전역 하네스(설정·훅·규칙·에이전트·스킬)와 프로젝트 템플릿을 한 저장소에서 관리하는 보일러플레이트.

## 1. 목적

- **언어·프레임워크 무관 핵심**: 전역 `settings.json`, 가드 훅 3개(비밀 파일·위험 명령·마이그레이션), 세션 컨텍스트 훅, 상태줄, 규칙 5개, 에이전트 3개, 스킬 7개. 어떤 스택의 프로젝트에서도 그대로 동작한다.
- **선택형 프로필**: `python` · `django` · `fastapi` · `node`. 기본으로는 아무것도 적용하지 않는다(`--profile`을 빼면 감지한 스택에 맞는 프로필을 힌트로만 알린다). `apply.sh --profile <이름>` 또는 `--profile auto`(스택 감지)로 프로젝트에만 추가한다.
- **웹 솔루션 공통 기능**(백엔드 API·프런트·DB, 언어 무관):
  - `rules/web.md` — API 설계·인증/인가·데이터·관측·테스트 계층 원칙(항상 로드)
  - `/api` — 엔드포인트 추가·변경 워크플로(요구사항 재진술 → 명세 표 → 구현 → 테스트 → 보고)
  - `/preflight` — PR 전 점검(마이그레이션 누락, env 동기화, 시크릿 스캔, lockfile, OpenAPI)
  - `guard-migrations` 훅 — 기존 마이그레이션 수정·삭제 확인(적용 여부는 판단하지 않음), 서브에이전트의 마이그레이션 작업 차단

### 검증 기준

| 항목 | 기준 |
|---|---|
| Claude Code | 2.1.318 (VS Code 확장, macOS) |
| 공식 문서 확인일 | 2026-11-05 (code.claude.com) |
| 설정 스키마 스냅샷 | 2026-11-05 (`schemas/claude-code-settings.schema.json`, json.schemastore.org) |
| 셸 | `/bin/bash` 3.2 호환(bash 5에서도 테스트), BSD/GNU 도구 공통 |
| 필수 도구 | `python3` 3.8+ (install·apply·validate), `git` |
| 선택 도구 | `jq`(훅 JSON 파싱, 없으면 `python3`로 대체. 둘 다 없으면 훅은 통과(fail-open)) |
| CI | ubuntu-latest, macos-latest |

## 2. 디렉터리 구조

```
dev_settings/
├── README.md
├── CLAUDE.md                       이 저장소 작업용 지침
├── install.sh                      claude/global → ~/.claude 설치
├── apply.sh                        project-template·profiles → <프로젝트> 적용
├── claude/
│   ├── global/                     → ~/.claude/
│   │   ├── CLAUDE.md.tmpl          → ~/.claude/CLAUDE.md
│   │   ├── settings.json           ~/.claude/settings.json에 병합
│   │   ├── rules/                  core · git · security · web · subagent-policy
│   │   ├── agents/                 explorer · implementer · reviewer
│   │   ├── hooks/                  run-hook.sh(런처) · guard-* · session-context · format-on-edit · statusline
│   │   │   └── lib/                common.sh · shellparse.sh · guard-rules.sh · detect-stack.sh · secret-patterns.txt
│   │   └── skills/                 commit · review-diff · delegate · harness-check · harness-init · api · preflight
│   └── project-template/           → <프로젝트>/
│       ├── CLAUDE.md.tmpl          → CLAUDE.md
│       ├── CLAUDE.local.md.example 개인 메모 예시
│       ├── gitignore.claude        .gitignore에 추가할 줄
│       └── dot-claude/             → .claude/
│           ├── settings.json · settings.local.json.example
│           ├── fragments/format-hook.json   --with-format-hook일 때만 병합
│           └── rules/project.md    서브에이전트 보충 규칙 템플릿
├── profiles/                       선택형: python · django · fastapi · node
│   └── <이름>/rules/<규칙>.md · settings.fragment.json
├── schemas/claude-code-settings.schema.json
├── scripts/                        merge-settings.py · validate.sh · update-schema.sh · lib/(install·apply 공용)
├── tests/                          run-all.sh · lib/ · hooks/ · skills/ · install/
├── .github/workflows/ci.yml
├── vscode/settings.json            VS Code 사용자 설정 참고본(설치 대상 아님, 수동 복사)
└── copilot/copilot-instructions.md  GitHub Copilot 지침 참고본(설치 대상 아님)
```

`CLAUDE.md.tmpl`·`dot-claude/`로 이름을 바꿔 둔 이유:

- Claude Code는 하위 디렉터리의 `CLAUDE.md`와 `.claude/rules/*.md`를 그 디렉터리 파일을 건드릴 때 자동으로 읽는다.
- 템플릿이 실제 이름이면 이 저장소를 작업하는 세션에 템플릿 내용이 지침으로 섞인다.
- `install.sh`·`apply.sh`가 복사하면서 실제 이름(`CLAUDE.md`, `.claude/`)으로 바꾼다.

## 3. 빠른 시작

```bash
git clone https://github.com/bhnvx/dev_settings.git ~/vsc/dev_settings
cd ~/vsc/dev_settings
./install.sh --dry-run   # 파일별 계획과 settings diff만 출력(아무것도 쓰지 않음)
./install.sh             # ~/.claude 에 설치(백업·매니페스트 포함)
```

1. Claude Code를 재시작한다(훅·규칙·스킬은 세션 시작 때 로드).
2. 아무 세션에서 `/harness-check` → FAIL이 없는지 확인한다.
3. 프로젝트에 적용한다. 둘 중 하나:
   - 터미널: `./apply.sh ~/vsc/<프로젝트> --profile auto`
   - 해당 프로젝트 세션: `/harness-init` (스택 감지 → 실행할 명령 확인 → `apply.sh` 실행)
4. 생성된 `CLAUDE.md`의 TODO를 채우고 `.claude/settings.json`의 allow 목록을 검토한다.
5. 커밋할 파일만 커밋한다(4.8 참고).

- `--with-format-hook`(편집 후 자동 포맷)은 프로젝트에 포매터 설정이 있으면 권장한다. ECC quality-gate는 기본적으로 검사만 하므로 겹치지 않는다. `ECC_QUALITY_GATE_FIX=true`일 때만 ECC가 고치는 타입을 건너뛴다(5절).
- 설치를 되돌리려면 `./install.sh --uninstall` 또는 `./install.sh --restore <타임스탬프>`(7절).

## 4. 구성 요소

### 4.1 하네스: `claude/global/settings.json`

| 키 | 값 | 의도 |
|---|---|---|
| `$schema` | schemastore URL | 편집기 자동완성·검증 |
| `language` | `korean` | 응답 언어. 이미 값이 있으면 사용자 값 유지(`install.sh --force`면 저장소 값) |
| `worktree.baseRef` | `head` | 워크트리를 현재 HEAD 기준으로 만든다. 기본값은 미푸시 커밋을 빠뜨린다 |
| `permissions.allow` | `jq`, `gh` 읽기 명령, 공식 문서 WebFetch 도메인 | 최소로 둔다(아래) |
| `permissions.deny` | 비밀 파일 `Read(//**/…)`, `~/.ssh/**` 등 | 핵심 비밀 파일 읽기 차단(네이티브 강제, 전체 목록은 훅 — 6.2) |
| `hooks` | PreToolUse 3개, SessionStart 1개 | 4.2 표 |
| `statusLine` | `statusline.sh` | 모델·브랜치·컨텍스트·사용량 한 줄 |

- **allow를 최소로 둔 이유**: `ls`·`cat`·`git status` 같은 읽기 명령은 Claude Code가 이미 프롬프트 없이 실행한다. 와일드카드 allow(`git log *` 등)는 `git log --output=<파일>` 같은 쓰기 경로까지 연다.
- **deny에 `//**/`를 쓰는 이유**: 사용자 설정에서 `**/.env`는 현재 작업 디렉터리 하위만 덮는다. `//`로 파일시스템 루트에 고정해야 모든 프로젝트에 적용된다.
- **`permissions.ask`를 두지 않은 이유**: 네이티브 ask 규칙은 훅의 env 스위치로 끌 수 없다. 푸시·sudo 같은 확인은 훅이 맡아 프로젝트별로 조정 가능하게 한다.
- `.env.example`·`.env.sample`·`.env.template`·`.env.dist`, `*.pub`는 deny하지 않는다.
- `alwaysThinkingEnabled`는 넣지 않는다(Fable 모델에 효과 없음).
- 사용자 값이 이기는 키: `model` `effortLevel` `modelSettings` `enabledPlugins` `extraKnownMarketplaces` `env` `language` `statusLine` `attribution` `includeCoAuthoredBy` `worktree` `permissions.defaultMode` `permissions.additionalDirectories`. 단 `install.sh --force`는 `$schema`·`language`·`statusLine`·`worktree.baseRef`를 저장소 값으로 바꾼다(백업 후, `worktree`의 다른 키는 유지).

### 4.2 훅

모든 훅은 런처 `run-hook.sh <이름>`을 거친다. 상태줄 `statusline.sh`만 `statusLine`이 직접 실행하므로 런처·`CLAUDE_HOOKS_DISABLE`과 무관하다.

- 런처는 훅의 종료 코드와 무관하게 항상 `exit 0`. 문법 오류가 난 훅이 exit 2로 모든 도구를 막는 사고를 방지한다.
- 훅은 stdout JSON(`permissionDecision`)으로만 결정한다. exit 2를 쓰지 않는다.
- `jq`가 없으면 `python3`, 둘 다 없으면 아무 결정 없이 통과한다(fail-open).
- 차단·확인 사유에 규칙 ID가 붙는다. 예: `차단 [secrets:print]: cat .env — 비밀 파일 내용 출력`.
- 훅 입력 JSON을 해석할 수 없으면(`tool_name`이 보이는데 깨진 입력) `ask [hook:parse-error]`로 확인을 요청한다. 빈 입력은 결정 없이 통과한다.

| 훅 | 이벤트 · 매처 | 동작 | 끄기 | 설정 env |
|---|---|---|---|---|
| `guard-secrets` | PreToolUse · `Read\|Edit\|Write\|MultiEdit\|NotebookEdit\|Grep\|Bash\|Monitor` | 비밀 파일 읽기·출력·전송 deny(`git show`·`diff`·`log -p`·`blame`·`grep`이 내용을 출력할 때 포함). 복사·삭제·`source`·쓰기(`> 파일`, `openssl -out`·`-keyout`)·`git add`·env 덤프·비밀 변수 출력·비밀 값 출력 명령(`gh auth token`·`kubectl get secret -o yaml` 등)·내용 없는 검색(`grep -q`·`-l`·`-c`)·패턴·스크립트 파일(`grep -f`·`sed -f`)·비밀 의심 파일(`*secret*.yaml` 등) ask | `CLAUDE_GUARD_SECRETS=off` | `CLAUDE_GUARD_SECRET_EXTRA`, `CLAUDE_GUARD_SECRET_ALLOW` |
| `guard-destructive` | PreToolUse · `Bash\|Monitor` | 루트·홈 `rm -rf`, `.git` 삭제, 보호 브랜치 force push(`--force`·`-f`·`+refspec`·`--mirror`)·삭제, `--no-verify`(`git commit -nm` 같은 묶음 플래그·`--no-veri` 같은 접두 약어 포함), 디스크·시스템 명령 deny. 보호 브랜치 푸시·커밋, 그 밖의 force push(보호 브랜치 `--force-with-lease` 포함), DB 파괴 SQL·마이그레이션 롤백·리셋, 인프라·클라우드 쓰기, 배포·publish, sudo, `curl \| sh`, `git config core.hooksPath` ask | `CLAUDE_GUARD_DESTRUCTIVE=off` | `CLAUDE_GUARD_PROTECTED_BRANCHES`, `CLAUDE_GUARD_ASK_ON_PUSH`, `CLAUDE_GUARD_ALLOW_PATTERNS` |
| `guard-migrations` | PreToolUse · `Edit\|Write\|MultiEdit\|Bash\|Monitor` | 서브에이전트(훅 입력에 `agent_id`가 있을 때)의 마이그레이션 생성·적용·수정·삭제·롤백 deny. 기존 마이그레이션 수정·삭제, 파괴적 스키마 변경 ask(high). 적용 명령(`migrate`, `alembic upgrade`, `prisma migrate dev` 등) ask(low) | `CLAUDE_GUARD_MIGRATIONS=off` | — |
| `session-context` | SessionStart · 전체 | 날짜, 브랜치·ahead/behind·변경 수, 최근 커밋 3개, 스택, 규칙 파일 현황, 보호 브랜치 경고를 컨텍스트로 주입 | `CLAUDE_SESSION_CONTEXT=off` | `CLAUDE_GUARD_PROTECTED_BRANCHES` |
| `statusline.sh` | statusLine | `모델 │ ⎇ 브랜치* │ ctx % │ 5h %[ 7d %](없으면 $비용) │ 디렉터리[ │ eff 수준][ │ PR #번호]`(7d는 50% 이상일 때만) | settings의 `statusLine` 제거 | `CLAUDE_STATUSLINE_COLOR=0`, `NO_COLOR` |
| `format-on-edit` | PostToolUse · `Edit\|Write\|MultiEdit` (프로젝트 opt-in) | 프로젝트가 설정한 포매터만 실행(ruff/black/isort, prettier/biome, gofmt, rustfmt, shfmt, terraform fmt, taplo). `.sh`는 `bash -n`(shebang이 없거나 bash·sh·dash·ash일 때, `env` 경유 포함). 결과를 컨텍스트로 알림. ECC와의 관계는 5절 | `CLAUDE_FORMAT_ON_EDIT=off` | `CLAUDE_FORMAT_ON_EDIT=force`, `CLAUDE_FORMAT_TIMEOUT`(기본 20초) |

- `Monitor` 도구는 Bash와 같은 권한 규칙으로 명령을 실행하므로 가드 3개가 Bash와 똑같이 검사한다. 명령 없이 `ws` 입력만 있는 감시는 통과한다.
- 서브에이전트 판단은 `agent_id`로 한다. `agent_type`은 `--agent`로 띄운 메인 세션에도 들어오므로 쓰지 않는다.
- 공용 파서(`hooks/lib/shellparse.sh`)가 명령을 세그먼트로 나누고, 세 가드가 같은 결과를 본다:
  - 명령 치환(`$(…)`·백틱·`<(…)`)은 바깥 명령에 자리표시자로 남기고 안쪽 명령을 별도 세그먼트로 검사한다(`env $(cat .env) node app.js`는 안쪽 `cat .env` 때문에 deny). 셸 문자열도 같다: `sh`·`bash`·`zsh -c`, `su -c`·`-lc`·`--command`, `runuser … -c`, `ssh host '…'`, `eval`, 실행기 `find -exec|-execdir|-ok|-okdir <셸> -c`·`watch`·`env -S`·`nsenter … <셸> -c`·`flock 파일 -c`·`mise exec -c`·`script -c`. `-c` 뒤의 옵션(`--` `-x` `-o 이름`)은 건너뛰고, 경로·대문자 셸 이름(`/opt/homebrew/opt/bash/bin/bash`, `DASH`)도 셸로 본다. 문자열 안의 `cd`는 바깥 작업 디렉터리를 바꾸지 않는다(같은 셸에서 도는 `eval`은 바꾼다). `git push origin $BRANCH`·`$(git branch --show-current)`처럼 펼쳐지지 않은 refspec은 현재 브랜치로 본다.
  - 셸 문자열(`sh -c`·`bash -c`·`su -c`·`find -exec sh -c`·컨테이너·래퍼 안 `sh -c`·`ssh`·`eval`) 안의 줄바꿈은 최상위처럼 명령을 나누고(주석·줄 잇기도 같다), 문자열 안의 heredoc도 최상위처럼 본다: DB 클라이언트 SQL(`sh -c 'psql <<EOF …'`), 셸이 읽는 본문(`bash <<EOF`·`cat <<EOF | bash` — 아래 heredoc 항목처럼 세 가드가 본문의 명령을 판정한다), 코드 본문(`python3 <<EOF`). 문자열 안의 문자열(`sh -c 'sh -c "…"'`·`sh -c "bash -c '…'"`·`sh -c 'eval "…"'`·`ssh host 'sh -c "…"'`·문자열 안의 `find -exec sh -c`)도 세 가드가 같은 규칙으로 다시 나눈다: 최상위의 문자열을 깊이 1로 세어 깊이 3까지 펼치고(깊이마다 `cd` 격리 — `eval`만 같은 셸, `find -exec` 위치 매개변수, `guard-secrets`의 이웃 규칙은 펼친 문자열마다 따로), 깊이 3 문자열 안의 문자열은 한 명령으로 머리만 판정한다: 줄바꿈·탭을 공백으로 읽으므로 `;`·줄바꿈 뒤 명령은 따로 보지 않고(`echo a; rm -rf /`는 통과, `.env` 같은 이름 언급은 ask-high), 4096자를 넘으면 앞 4096자만 보고 `too-complex` 바닥이다.
  - 컨테이너 런타임(`docker run`·`docker container exec|run`·`podman`·`nerdctl` `[container] exec|run`·`docker-compose exec|run`)과 접두 래퍼(`flock 파일`·`mise exec|x … --`·`caffeinate`·`chrt`·`ionice`·`taskset`·`setsid`·`unbuffer`·`chroot 새루트`·`script -q 파일 명령`·`unshare`·`systemd-run`·`runuser -u 사용자 --`)는 원래 줄을 그대로 판정하고, 벗긴 안쪽 명령을 한 번 더 판정한다(`--entrypoint X`는 안쪽 명령의 머리). 컨테이너 안쪽 머리가 `busybox`·`tini --`·`gosu`·`dumb-init`이어도 그 뒤의 `sh -c '…'`를 찾는다. 그래서 `docker run --rm img cat .env`·`podman run img busybox sh -c 'cat .env'`·`caffeinate -i rm -rf /`는 deny다. 옵션 표에 없는 옵션·따옴표 없는 `$OPTS`·실행할 명령이 없는 형태는 벗기지 않는다.
  - 명령 머리와 옵션의 따옴표·백슬래시·대소문자 변형(`"rm" -rf`, `r\m`, `RM`, `SUDO rm`, `sh "-c"`, `nice "-n" 5 …`, `find … "-exec"`, `runuser -u 사용자 "--" …`)은 같은 규칙으로 판정한다.
  - 리디렉션 연산자는 한 단어로 읽는다. `>|`는 파이프가 아니라 쓰기이고(`echo x >| rm -rf /`는 `rm`이라는 파일에 쓰기), fd 번호가 붙은 연산자(`2>>`·`100>>`), `>&파일`(= `>파일 2>&1`), zsh의 덮어쓰기 강제 `>!`·`>>!`·`&>!`·`>&!`·`>&|`도 쓰기다(Bash 도구가 zsh로 돌 수 있다). `2>&1`·`>&2`·`>&-`는 fd 복제·닫기다. zsh `>>&`·`>>&|`·`>>&!`(표준 출력·오류 덧붙이기)는 `guard-migrations`와 블록 디바이스 검사만 쓰기로 읽는다.
  - 셸이 스크립트로 읽는 heredoc 본문(`bash <<EOF`·`bash -s`·`sudo bash`·`docker exec -i …`·`kubectl exec -i … --`·`docker run -i 이미지` 뒤의 `sh`, `ssh host <<EOF`, `su - <<EOF`, `cat <<EOF | bash`)은 세 가드가 최상위 명령처럼 판정한다. 셸처럼 본문의 줄 나눔과 줄 잇기(`\`), `<<-`의 줄 앞 탭 제거, 따옴표 없는 구분자의 `\$` 풀기를 반영하고, 서브셸·명령 치환 안의 heredoc도 같다. 본문을 읽는 명령은 heredoc마다 `<<`를 가진 명령과 그 파이프라인으로 정한다 — `bash -c '…' <<EOF`·`bash script.sh <<EOF`·`bash -n <<EOF`의 본문과 `cat <<EOF > f; bash`처럼 다른 명령으로 가는 본문은 데이터다. 본문은 셸 문자열과 작업 상한(아래)을 함께 쓴다: 상한을 다 쓰는 본문(짧은 명령 약 2000줄, 토큰이 많으면 대략 20~40 KB)은 남은 본문과 뒤 명령을 판정하지 못하고, 96 KB를 넘는 본문은 다시 나누지 않고 앞 4096자만 본다(뒤 명령은 판정한다). 둘 다 `too-complex` 바닥이다. 따옴표 없는 구분자의 본문 속 명령 치환(`$(…)`·백틱)은 바깥 셸이 실행하므로 안쪽 명령을 판정한다(`cat <<EOF … $(cat .env) … EOF`는 deny, `\$(…)`와 `<<'EOF'` 본문은 바깥 셸에서는 글자 그대로).
  - heredoc 본문은 1 MB까지 검사하고(코드 heredoc은 비밀 파일 경로만), 200 KB heredoc은 훅마다 약 0.2~0.8초, 셸이 읽는 200 KB 본문은 1초 안팎이 든다(macOS `/bin/bash` 3.2 측정, 테스트 기준 3.5초 이내). 셸 문자열이 250개를 넘는 명령도 판정한다.
  - 작업 상한: 파서는 명령 치환이 수천 개여도 선형 시간에 나누되, 내는 줄(세그먼트·치환 경계·셸 문자열)이 5000개를 넘으면 그 뒤를 읽지 않고, 이미 읽은 부분(열린 서브셸·치환 안의 명령과 그 바깥 세그먼트, `env -S` 문자열, 그 줄의 heredoc)은 입력이 거기서 끝난 것처럼 마무리해 낸다(줄이 5000개를 넘는 `( rm -rf /; … )`·치환이 1700개인 `rm -rf / $(…) …`도 deny). 단어가 24000개를 넘거나 단어 하나의 조각(이스케이프·따옴표)이 8192개를 넘어도 같게 멈추되 읽다 만 그 세그먼트는 버린다. `guard-secrets`·`guard-destructive`는 최상위와 다시 나눈 셸 문자열을 합쳐 세그먼트 2000개까지 판정하고, 셸 문자열은 명령마다 모든 깊이를 합쳐 200개(글자 수 합 96 KB)까지만 다시 나누며 그 뒤 문자열은 앞 4096자만 한 세그먼트로 판정한다(이 세그먼트는 줄바꿈을 공백으로 읽지 않으므로 여러 줄에 걸친 SQL·`curl | sh`는 `too-complex` 바닥이 맡는다). 토큰 수(`guard-destructive` 8000·`guard-secrets` 4000, `find`·`fd -exec` 프로그램 256), `guard-secrets`가 분류하는 글롭 `{a,b}` 대안(256), 세그먼트 분석용 fork(가드마다 100회), `rm` 대상 수(1000), 4096자를 넘는 명령 이름(`guard-secrets`는 단어·경로도), `guard-migrations`가 보는 파서 줄 수 합(5000), 가드마다의 작업 시간(약 6초)에도 상한이 있다. 상한을 넘으면 이미 나온 줄의 판정(deny 포함)은 그대로 두고 `too-complex`(메인 ask-high, 서브에이전트 deny)를 바닥으로 둔다(가드마다 사전 필터를 통과한 명령만). 그래서 보통 부하에서는 10초 제한을 넘겨 판정 없이 통과하지 않지만(10절), 보지 못한 부분에만 있는 위험 명령은 메인에서 deny가 아니라 ask-high다.
- `uv run --env-file .env …`·`docker compose --env-file .env …`는 실행 자체는 통과하지만, 그 명령이 환경을 출력·덤프하면(`env`, `printenv`, `python -c 'print(os.environ)'` 등) deny다.
- `git config [--global] core.hooksPath <경로>`는 ask(훅 우회)다. `.husky`·`.githooks`·`.git/hooks`·`.hooks`·`.lefthook*` 같은 저장소 안의 관례적 경로는 통과한다.
- DB 마이그레이션 롤백·리셋·초기화(`flyway clean`, `rails db:rollback`, `artisan migrate:fresh`, `supabase db reset` 등)의 ask(high)는 `guard-destructive`가, 서브에이전트일 때의 deny는 `guard-migrations`가 담당한다. 도구와 동사 사이에 옵션이 있어도 같다(`alembic -c alembic.ini downgrade -1`, `flask --app wsgi db downgrade`, golang-migrate `down`·`drop`, `liquibase … dropAll`, `django-admin flush`). `makemigrations --check`·`--dry-run`은 생성으로, SQL만 출력하는 미리 보기(`alembic`·`flask db`의 `--sql`, liquibase `update-sql`·`rollback-sql` 같은 `*-sql`·`*SQL`)는 적용·롤백으로 보지 않는다. 미리 보기를 DB 클라이언트(`psql`·`mysql`·`sqlite3` 등)로 넘기면(`| psql`, `psql -f <(…)`, `psql -c "$(…)"`) 실제로 실행되므로 원래 명령처럼 본다(롤백 ask-high, 적용 ask-low, 서브에이전트 deny).
- `guard-secrets` 판정 세부:
  - 파일로 보지 않는 인수: `tar`·`rsync`·`grep`의 `--exclude`·`--exclude-dir`, `zip -x` 목록, `rg -g '!…'`, `grep`·`rg`의 `--regexp=` 패턴, 인라인 메시지(`git commit`·`tag`·`notes`·`stash`의 `-m`, `gh`·`glab`의 `--title`·`--body`·`--notes`·`--description`). `--exclude-from`·`tar -X`·`grep --include`·`zip -x @목록`과 `-F`·`--file`·`--body-file`은 파일로 본다. 비밀 파일을 패턴·스크립트 파일로 쓰면(`grep`·`rg`·`git grep`의 `-f`, `sed`·`awk`·`jq`의 `-f`·`--file`) 일치한 줄이나 오류 메시지로 값이 샐 수 있어 ask(high)이고, 처리 대상이면 deny다(`sed -f x.sed .env`).
  - 이름만 쓰는 git 명령(`git check-ignore`·`ls-files`·`status`(`-v` 제외)·패치 옵션 없는 `log -- .env`·`rm --cached`)은 통과한다. `git add`·`rm`·`mv`와 내용을 내지 않는 `git show --stat`·`diff --name-only`·`grep -l`은 ask(high)다.
  - `echo '$TOKEN'`(작은따옴표)·`${TOKEN:+x}`·`${#TOKEN}`은 값을 내지 않아 통과한다. 같은 명령에 셸 실행(`-c` 없는 `sh`·`bash`, `xargs` 아래 셸)·`eval`·`source`·`ssh`·`su`·`envsubst`가 있으면 작은따옴표도 ask이고, `${TOKEN:-x}`·`${TOKEN:0:4}`·`${TOKEN#…}`는 ask다.
  - 예제·템플릿 제외(`.example`·`.sample`·`.template`·`.dist`)는 중간 확장자(`secrets.example.yml`, `.env.example.json`)에도 적용한다. 다만 `.local`로 끝나는 이름(`.env.example.local`), 끝 확장자가 키·인증서·키스토어·`.env`·`.token`인 이름(`api.example.com.key`), 자격 증명 디렉터리(`~/.ssh` 등) 안의 중간 확장자 이름(`~/.ssh/id_rsa.example.txt`)은 제외하지 않는다(`~/.ssh/id_rsa.example`처럼 끝 확장자가 예제면 훅도 제외한다 — `~/.ssh/**`는 Read deny 대상).
  - soft 단계(이름에 secret·password·apikey 등)는 경로 모양 인수에만 적용한다. URL, JSON 본문, `curl -d`·`--data`·`-F`·`wget --post-data` 본문, `pytest -k`·`-m` 식은 보지 않고, `@파일` 업로드는 본다.
  - `find`의 이름 조건(`-name`·`-path` 등, 없으면 시작 경로)이 비밀 파일이면 `-exec`로 넘기는 프로그램으로 판정한다: 출력기 deny(`grep -l`·`-q`·`-c`는 ask), `cp`·`mv`·`install` ask(high), `scp`·`rsync`·`curl -T` deny. `find`·`gfind`의 `-exec`·`-execdir`·`-ok`·`-okdir` … `;`|`+`와 `fd`의 `-x`·`--exec`·`-X`·`--exec-batch`가 실행하는 프로그램과 인수는 따로 한 명령으로도 판정한다(`find . -exec cat .env \;`·`fd -x cat .env`는 deny, `find . -exec cat README.md \;`·`find . -name '*.py' -exec grep -n TODO {} +`는 통과). `find`의 셸 `-c` 문자열은 파서가 펼친 것으로만 본다. heredoc 연산자에 구분자가 붙으면(`<<EOF`) 다음 단어는 인수다: `cat <<EOF .env`는 deny, `cat <<EOF > .env`는 쓰기라 ask(high)다.
- `guard-destructive` 판정 세부:
  - `git commit`의 짧은 플래그는 git처럼 왼쪽부터 읽는다: `-nm x`·`-anm x`는 `--no-verify`(deny)이고 `-m"fix: null"`·`-uno`·`-Sn`은 통과한다. `--no-veri` 같은 고유 접두도 `--no-verify`로 본다. `-n`이 `--no-verify`인 것은 commit뿐이다(push는 `--dry-run`, cherry-pick·revert는 `--no-commit`, merge는 `--no-stat`).
  - refspec 없는 `git push [원격] --tags`는 태그만 푸시하므로 보호 브랜치 규칙을 적용하지 않는다(`--follow-tags`, `git push origin main --tags`는 브랜치 푸시). `git checkout <경로>`(커밋이 아닌 기존 경로·글롭)와 `git checkout <rev> <경로…>`는 `git checkout -- <경로>`처럼 ask-low이고, 브랜치이면서 경로인 이름은 브랜치 전환으로 본다. 보호 브랜치로의 `--force-with-lease`는 deny가 아니라 ask(high)다(`git.md`가 허용하는 강제 푸시 형태라 `auto`에서도 확인만 받는다).
  - `curl | sh`는 실제로 실행되는 것만 본다: 앞선 `curl`·`wget` 출력을 표준 입력으로 읽는 셸·인터프리터(`sh`, `bash -s`, `bash -eo pipefail`, `python3 -`·`-u`), 표준 입력 장치를 스크립트로 받는 형태(`bash /dev/stdin`·`zsh /dev/fd/0`, `source /dev/stdin`, `bash -c "$(cat)"`), `sh -c "$(curl …)"`·`eval "$(curl …)"`·`bash <(curl …)`·`python3 <(curl …)`·`bash <<< "$(curl …)"`, 셸 문자열·`ssh host`·컨테이너가 실행하는 문자열, 셸이 읽는 heredoc(`bash <<EOF`, `cat <<EOF | bash`). 파일로 쓰는 heredoc, 커밋 메시지, `gh`·`echo` 인수, 주석, 다운로드 후 실행(`curl -o i.sh … && sh i.sh`), 스크립트 인수(`| bash setup.sh`)·명령 문자열(`| bash -c '…'`), `|| bash x.sh`는 보지 않는다.
  - 배포 스크립트·타깃(deploy-runner)은 이름으로 판단한다. 스크립트는 파일 이름에서 확장자를 뗀 것, 타깃은 `make`·`just`·`rake`·`task`·`npm run` 등의 타깃이다. `deploy` `release` `publish` `rollback` `destroy` `promote` `ship`이 경계(`.` `_` `-`, 타깃은 `:`도)로 나뉜 단어이거나 이름이 `prod`·`production`으로 시작하면 ask-high다(`staging-deploy.sh`·`prod-db-reset.sh`·`deploy_and_test.sh`·`npm run app:deploy`·`make deploy`는 ask, `seed_products.py`·`update-prod-config.sh`·`sync_to_prod.py`·`npm run build:prod`는 통과). 테스트 파일(`test_*`·`*.test`·`*.spec`, 앞부분이 한 단어인 `*_test`·`*_spec`), 첫 구성 요소가 `test`·`lint`·`check` 등인 타깃, 실행하지 않는 `bash -n`·`node --check|--test`·`python -m py_compile|compileall|pytest`는 제외한다. 셸·python·node는 옵션 값을 인터프리터마다 읽어 스크립트를 찾고(`bash -e deploy.sh`, `python3 -W ignore deploy.py`, `node -r dotenv/config deploy.js`, `bash < deploy.sh`, 경로가 붙은 `.venv/bin/python`도 같다), `make`·`just` 등은 `KEY=VALUE` 대입과 값을 받는 옵션을 건너뛴다(`make ENV=production deploy`·`make -e deploy`는 ask).
  - `make`의 `-j`·`--jobs`·`-l`·`--load-average`는 GNU make처럼 뒤 단어가 숫자일 때만 그 값으로 본다(`$(nproc)`·`$JOBS`처럼 `$`로 시작하는 펼침도 값). 그래서 `make -j deploy`·`make -j $(nproc) deploy`는 ask-high다.
  - `gh api`는 메서드로 판단한다: `-X`·`--method`가 우선이고 `-f`·`-F`·`--input`은 기본값만 POST로 바꾼다. GET·HEAD는 통과, 그 밖은 ask-high다. `gh api graphql`은 `query=` 값이 모두 `query`·`{`·`fragment`로 시작하고 `mutation`이 없는 인라인 문서일 때만 읽기로 본다(`query=@파일`·명령 치환·값 없음은 ask-high).
  - 인프라·배포 CLI는 첫 인수가 버전·도움말 플래그(`--version` `-version` `--help` `-help` `-h`)이고 나머지도 플래그뿐이면 통과한다. `aws logs tail`·`gcloud logging read`·`helm diff`·`brew services [list|info]`도 통과한다. 배포 하위 명령은 ask-high다: `vercel`, `netlify`·`fly`·`wrangler`·`sls`·`sam`·`cdk`·`eb`·`firebase`·`kamal deploy`, `gcloud app|run|functions deploy`, `supabase functions deploy`, `railway up|redeploy`, `amplify publish|push`, `cf push`, `zappa deploy|update|rollback`. publish는 전역 옵션 뒤의 하위 명령으로 본다(`npm -w <ws> publish`, `pnpm -r publish`, `yarn workspace x npm publish`, `npm publish --dry-run`도 ask-high).
  - 블록 디바이스(`/dev/disk*`·`/dev/rdisk*`·`/dev/sd*`·`/dev/nvme*`·`/dev/hd*`)로 쓰는 리디렉션은 연산자(`>|`·`>!`·`>&` 등)·붙여 쓴 대상·따옴표 친 경로와 관계없이 deny다(`/dev/null`·`/dev/tty` 등은 통과).
  - `find … -exec|-execdir|-ok|-okdir sh -c '…' 인수… \;|+` 안의 위치 매개변수(`$0`…`$9`·`${N}`·`$@`·`$*`)는 find가 넘기는 인수로 바꿔 판단한다(빈 인수도 한 자리, `-c` 뒤 옵션 `--`·`-x`·`-o 이름`은 건너뛴다). `{}`는 시작 디렉터리 아래 경로로, `-mindepth 1` 이상이 없으면 시작 디렉터리 자체(깊이 0)로도 판단한다(마지막 구성 요소가 `.`·`..`인 경로와 `-r` 없는 rm의 시작 디렉터리 자체는 뺀다). 그래서 `find . -name '*.pyc' -exec sh -c 'rm -rf "$1"' _ {} \;`는 `find -exec rm`과 같은 ask-high이고, `find / …`·`find ~ …`·`find /tmp …`는 deny다. 풀 수 없는 형태(`for f; do rm -rf "$f"; done`, 인수에 없는 매개변수, 대문자 셸 이름)는 위치 매개변수를 풀지 않는 원래 규칙(재귀 rm이면 deny)을 쓰고, 판단 작업량 상한(명령마다 200회, find 단어 4000개)을 넘는 입력도 원래 규칙을 쓰되 적어도 `find -exec rm`과 같은 ask-high를 남긴다.
- `guard-migrations` 판정 세부:
  - 셸 명령은 실제로 쓰는 경로로만 판단한다: 리디렉션 대상(fd 복제·닫기 제외), `tee` 출력 파일, `cp`·`mv`·`install`·`rsync`·`scp`의 목적지(마지막 인수나 `-t`), 제자리 편집(`sed -i`·`perl -i`·`ruby -i`, `git checkout|restore <경로>`(`--staged`만이면 제외), `dd of=`, `curl -o`, `wget -O`, `truncate`, `patch <파일>`). 그래서 `ls migrations/*.py 2>/dev/null`, `grep … migrations/0001_initial.py > /tmp/out.txt`, `cp migrations/0001_initial.py /tmp/`는 통과한다. `mv`·`git mv`의 원본과 `rm`·`git rm`의 대상이 마이그레이션이면 삭제(ask-high)다.
  - 쓰는 파일이 이미 있으면 기존 마이그레이션 수정(ask-high), 없으면 생성이다. 생성은 Write 도구와 같다: 메인은 통과하되 명령 어디에든(heredoc 본문·다른 파이프 단계 포함) 파괴적 스키마 변경이 보이면 ask-high(`migrations:destructive-schema`), 서브에이전트는 deny.
  - 상대 경로는 세션 cwd와 명령 안 `cd`·`pushd`가 닿을 수 있는 모든 디렉터리(돌지 않았을 수 있는 `cd` 포함)에서 판정하고, 경로에 마이그레이션 디렉터리가 드러나지 않아도 cwd 기준으로 본다(`cd migrations && echo x > 0001_initial.py`). 따라갈 수 없는 이동(`eval`·`source`, `cd -`·변수 경로, `z`·`zoxide`, `HOME=…` 변경, `$c app`처럼 `$`로 시작하는 명령 단어, 명령 안 `CDPATH=`·zsh `cdpath=(…)`) 뒤의 상대 경로와 글롭·중괄호·변수가 든 경로는 이미 있는 파일로 본다. 셸 문자열(`sh -c` 등) 안의 `cd`는 뒤 명령의 cwd로 따라가지 않는다(예외는 10절). 판정은 저장소 루트 기준 경로라 저장소를 `…/goose/` 같은 디렉터리 아래에 클론해도 모든 쓰기가 걸리지는 않는다(Edit·Write도 세션 cwd 아래 파일은 같다). 세션 cwd가 `migrations/` 안이면 상대 경로(`sed -i … 0001_initial.py`, Edit의 `0001_initial.py`)도 본다.
  - `ssh`·컨테이너(`docker`·`podman`·`nerdctl` `exec|run`, `docker compose exec|run`, `kubectl exec`) 안의 쓰기와 `scp`·`rsync`·`docker cp`·`docker compose cp`·`kubectl cp`의 원격 목적지(`host:경로`·`컨테이너:경로`)는 이미 있는 파일로 본다(ask-high). `--entrypoint sh img -c '…'`처럼 공용 파서가 벗기지 못한 컨테이너 셸도 찾는다. git 작업 트리(`--work-tree`·`-c core.worktree=`·명령 안 `GIT_WORK_TREE=`)는 따라가거나 이미 있는 파일로 보고, 따옴표로 나뉜 이름·도구 단어(`mig"rations"/…`, `alem"bic" upgrade`)도 본다(64 KB 이하 명령).
  - 도구(`alembic`·`flask db`·`goose`·`dbmate`·`migrate`(golang-migrate)·`flyway`·`liquibase`·`knex`·`artisan` 등)는 도구 이름 뒤 첫 하위 명령으로 판단하므로 사이에 옵션·위치 인수가 와도 된다(`goose -dir db/migrations postgres "$DATABASE_URL" up`, `alembic -c alembic.ini upgrade head`). 도구 이름은 명령의 어느 단어든 되고 뒤에 나온 것을 먼저 본다(`docker run --name goose flyway/flyway migrate`, `pnpm run db:goose up`). `status`·`version`·`current`·`history` 같은 조회는 통과한다. 미리 보기를 DB 클라이언트로 넘기는 판정에는 `sh -c`·`ssh`·`eval` 중간 단계, `( … ) | psql`·`{ …; } | psql`, `psql -c "$(…)"`·`psql < <(…)`도 들어간다.
  - 큰 명령은 비용 상한이 있다: 마이그레이션 이름·명령 어휘가 없는 세그먼트는 건너뛰고, 상대 경로 대조 2048회·awk 호출 150회·미리 보기 파이프 판정 64회(64 KB)를 넘으면 남은 부분을 이미 있는 마이그레이션 수정(미리 보기는 파이프)으로 본다. 10초 제한을 넘겨 판정 없이 통과하지 않게 하려는 것이다.

공통 스위치:

- `CLAUDE_HOOKS_DISABLE=1` — 런처를 거치는 모든 훅을 즉시 통과(전역 킬 스위치, 상태줄 제외).
- `CLAUDE_HOOKS_LOG=<파일>` — 결정 로그. 한 줄 형식: `날짜<TAB>훅<TAB>결정<TAB>규칙<TAB>사유(명령 발췌 포함, 200바이트 이하)`. `auto`·`bypassPermissions`에서 넘긴 ask-low는 결정 `allow`, 사유 `silenced(<모드>): …`로 남는다.
- `CLAUDE_HOOKS_DEBUG=1` — 디버그 메시지를 stderr로 출력.
- 훅별 끄기 스위치(`CLAUDE_GUARD_SECRETS`·`CLAUDE_GUARD_DESTRUCTIVE`·`CLAUDE_GUARD_MIGRATIONS`, `CLAUDE_SESSION_CONTEXT`, `CLAUDE_FORMAT_ON_EDIT`)는 `off` `0` `false` `no`(대소문자 무관)를 인식한다. `CLAUDE_HOOKS_DISABLE`은 `1`만, `CLAUDE_STATUSLINE_COLOR`는 `0`만 인식한다.

마이그레이션 경로로 보는 디렉터리: `migrations/` `migration/` `alembic/versions/` `db/migrate/` `db/migrations/` `prisma/migrations/` `supabase/migrations/` `drizzle/` `knex/migrations/` `sequelize/migrations/` `typeorm/migrations/` `flyway/` `liquibase/` `sql/migrations/` `atlas/migrations/` `goose/` `dbmate/`. `__init__.py`·`env.py`·`script.py.mako`·`alembic.ini`·`README*`·`*.md`·lock 파일(`*.lock`·`migration_lock.toml`)과 `__pycache__/` 아래 파일·`*.pyc`·`*.pyo`는 제외한다. `migrations/__pycache__/../0001_initial.py`처럼 `..`로 빠져나오는 경로에는 이 제외를 적용하지 않는다.

### 4.3 확인(ask) 2단계와 `permission_mode`

| 단계 | 동작 | 예 |
|---|---|---|
| deny | 항상 차단 | `cat .env`, `rm -rf ~`, `git push --force origin main`, `git commit --no-verify` |
| ask-high | 모든 모드에서 확인 요청(`bypassPermissions`는 아래 참고) | `git push origin main`, 보호 브랜치 커밋, 보호 브랜치 `git push --force-with-lease`, `psql -c "DROP TABLE …"`, `kubectl delete`, `make deploy`, `sudo`, `echo $AWS_SECRET_ACCESS_KEY`, `grep -q KEY .env`, 기존 마이그레이션 수정 |
| ask-low | `default` `acceptEdits` `dontAsk` `plan`에서 확인, `auto` `bypassPermissions`에서는 결정 없이 통과(모드·분류기에 맡김) | `rm -rf ./src`, 비보호 브랜치 `git reset --hard`, `git checkout <파일>`, `git stash drop`, `printenv`, `manage.py migrate` |

- 모드는 훅 입력의 `permission_mode`로 판단한다. 공식 문서 기준(permission-modes·hooks 문서): `dontAsk`는 프롬프트가 뜰 호출을 모두 자동 거부하므로 ask도 거부되고, `auto`에서 훅의 ask는 분류기가 아니라 권한 프롬프트로 간다("PreToolUse `ask` decisions in auto mode"). `bypassPermissions`에서는 자동 승인하지 않는 목록("Actions no mode auto-approves")에 훅 ask가 없어 ask-high도 확인 없이 실행될 수 있으므로, 이 모드에서 확실한 차단은 deny뿐이다(deny 규칙은 모든 모드에서 막고, 훅의 `deny`는 도구 호출을 막는다).
- 재생성 가능한 디렉터리(`node_modules` `.venv` `dist` `build` `.next` `__pycache__` `coverage` 등)와 임시 디렉터리 `rm -rf`는 조용히 허용한다. 임시 디렉터리는 정규화한 경로로 판단한다: `/tmp` `/private/tmp` `/var/folders` `/var/tmp` 아래면 통과(`cd /tmp && rm -rf x` 포함), `/tmp/../etc`처럼 벗어나면 정규화한 경로의 규칙(시스템 경로 deny 등)을 따른다. 임시 루트 자체(`rm -rf /tmp/*`, 하위 경로 없는 `"$TMPDIR"`·`"$TMPDIR"/*`)는 deny이고, 임시 경로에 있는 세션 작업 디렉터리 안은 일반 규칙을 따른다.
- 삭제 대상이 변수·명령 치환이면: `"$TMPDIR/…"`·`"${TMPDIR:?}/…"`(`$TMP`·`$TEMP`도 같음)는 `..`가 없으면 통과하고, 기본값 연산자는 기본값이 글자 그대로의 임시 경로일 때만 통과한다(`"${TMPDIR:-/tmp}/x"`; `"${TMPDIR:-$HOME}/x"`는 ask-low, `"${TMPDIR:=$HOME}/x"`는 deny). 값을 바꾸는 연산자(`:+`·`#`·`%/*` 등), 이름이 다른 변수(`$TMPDIR_BUILD`), 치환 결과(`rm -rf "$(mktemp -d)"`)는 펼쳐지지 않은 경로로 보아 deny이고(의도된 동작), `"${BUILD_DIR:?}/stuff"`처럼 `:?`·`:-`로 보호한 일반 변수 경로는 ask-low다.

### 4.4 규칙 5개 (`~/.claude/rules/`, 모두 항상 로드)

| 파일 | 내용 |
|---|---|
| `core.md` | 검증한 것만 완료 보고, 추측 금지, 요청 범위 준수, 복잡한 요청은 목표·요구사항·유의사항·완료 조건으로 재진술 후 플랜, 완료 보고 형식 |
| `git.md` | `<gitmoji> scope: subject` 커밋 형식(유니코드 gitmoji, 예 `✨ api: …`)과 gitmoji 표, 브랜치 모델, 보호 브랜치, force push·`--no-verify`·`git add -A` 금지, PR 체크리스트·본문 형식 |
| `security.md` | 비밀 파일·값 취급, 마스킹, 운영 접근 금지, 외부 전송 금지 항목, 차단 우회 금지 |
| `web.md` | 웹 솔루션 공통: API 설계, 인증·인가, 데이터·마이그레이션 안전, 관측, 설정, 테스트 계층, 프런트, 보안·성능, 문서 |
| `subagent-policy.md` | 메인 직접 vs 위임 기준, 분할·배정, 위임 프롬프트 7항목, 결과 검증, 모델 배정 |

우선순위: 사용자 지시 > 프로젝트 `CLAUDE.md`·`.claude/rules` > 전역 rules. 전역 `CLAUDE.md`는 이 규칙과 스킬 목록을 한 줄씩 안내하고, 프로젝트에 `CLAUDE.md`가 없으면 `/harness-init`을 제안하게 한다.

### 4.5 에이전트 3개 (`~/.claude/agents/`)

| 에이전트 | 도구 | model · effort | 역할 |
|---|---|---|---|
| `explorer` | Read, Grep, Glob | sonnet · medium | 읽기 전용 조사, 결론과 근거(경로:라인)만 보고 |
| `implementer` | Read, Grep, Glob, Edit, Write, Bash | opus · high | 지정한 소유 파일 안에서만 구현. git·의존성·마이그레이션·운영 접근 금지 |
| `reviewer` | Read, Grep, Glob | opus · xhigh | 보고 전용 리뷰. 코드 수정 금지 |

- 세 에이전트 모두 `disallowedTools: mcp__*`, `omitClaudeMd: true`.
- **컨텍스트 비용**: 공식 문서(sub-agents "What loads at startup")에 따르면 서브에이전트는 메인 대화가 읽는 CLAUDE.md 계층 전체(`~/.claude/CLAUDE.md`, 프로젝트 rules, `CLAUDE.local.md` 포함)를 읽는다. 빌트인 Explore·Plan은 읽지 않고(정책 §2), `omitClaudeMd`(2.1.271+)를 둔 에이전트는 관리 정책 파일만 읽는다. 이들도 하위 디렉터리 `CLAUDE.md`와 맞는 경로 범위 규칙은 그 디렉터리 파일을 다룰 때 읽는다. `~/.claude/rules/`가 서브에이전트에 실리는지는 문서에 명시되지 않았다(미문서화). 실린다면 general-purpose·플러그인 에이전트를 띄울 때마다 `subagent-policy.md`(약 14KB, 4~5K 토큰) 비용이 든다. 정책을 항상 적용하는 대가로 감수한 선택이다.

### 4.6 스킬 7개 (`~/.claude/skills/`)

| 명령 | 인수 | 자동 호출 | 동작 |
|---|---|---|---|
| `/commit` | `[파일... \| 커밋 범위 설명]` | 수동 | 보호 브랜치 확인 → 파일 지정 스테이징 → staged diff 점검(비밀·디버그·임시·대용량) → `git.md` 형식 커밋. 푸시·`--amend`·`--no-verify` 안 함 |
| `/review-diff` | `[base-ref \| 파일...]` | 수동 | diff 수집 → 고위험 영역이면 opus, 아니면 sonnet `reviewer` 실행 → Critical/High는 직접 열어 확정 → 심각도순 보고. 수정 안 함 |
| `/delegate` | `[explorer\|implementer\|reviewer] [목표]` | 가능 | 위임 판단 체크리스트, 위임표 양식, 7항목 프롬프트 템플릿, 실행 후 점검 |
| `/harness-check` | — | 수동 | 설치본 `validate.sh` 결과 해석(FAIL 수정 / WARN 판단), 설치본이 저장소보다 오래되면 재설치 안내 |
| `/harness-init` | `[python\|django\|fastapi\|node\|auto] [--force] [--with-format-hook] [--team] [--dry-run]` | 수동 | 스택 감지 → `apply.sh` 명령 확인 후 실행 → 커밋할/안 할 파일 요약 → `CLAUDE.md` TODO 채우기 제안 |
| `/api` | `[요구사항 또는 요구사항 파일 경로]` | 가능 | 웹: 요구사항 재진술 → 기존 패턴 확인 → 엔드포인트 명세 표 → 플랜 승인 → 구현 → 테스트(성공·검증 실패·401/403·경계값) → 보고 |
| `/preflight` | `[base-ref]` | 수동 | 웹: PR 전 점검. 변경 분류, 마이그레이션 누락, env 키와 `.env.example` 비교, 시크릿 스캔, lockfile 동기화, OpenAPI 갱신 → PR 체크리스트 결과 + PR 본문 초안 |

- `review-diff`로 이름 지은 이유: `/review`는 내장 `/code-review`의 별칭이라 겹친다.
- 수동 스킬은 `disable-model-invocation: true`. 모델이 임의로 커밋·설치하지 않는다. 규칙·스킬 본문도 모델에게 수동 스킬(`/commit`, `/review-diff`, `/preflight`, `/harness-*`) 실행을 지시하지 않고, 사용자에게 실행을 제안하거나 절차를 직접 적는다.
- 스킬 본문이 미리 실행하는 셸 주입 명령(예: `"${CLAUDE_SKILL_DIR}/context.sh"`)은 `allowed-tools`에 같은 따옴표 형태(`'Bash("${CLAUDE_SKILL_DIR}/context.sh" *)'`, YAML 작은따옴표)와 따옴표 없는 형태를 함께 둔다. 홈 경로에 공백이 있어도 권한 검사에서 막히지 않게 하려는 것이다.
- `allowed-tools`는 스킬을 부른 턴에만 유효하다. 사용자 응답 뒤에 실행하는 `git add`·`git commit`·`apply.sh`에는 일반 권한 프롬프트가 뜰 수 있다.

### 4.7 프로필 4개 (선택형 add-on, 기본 적용 없음)

| 프로필 | 규칙 파일 | `paths` | 내용 |
|---|---|---|---|
| `python` | `python.md` | `**/*.py`, `**/pyproject.toml` | lockfile 기준 패키지 관리자(명령 예시는 uv), pyproject 포매터·린터 준수, 타입 힌트, Google 스타일 docstring(언어는 프로젝트 관례), 로깅, 예외, pytest |
| `django` | `django.md` | `**/*.py`, `**/templates/**` | 레이어 분리, Serializer 검증, 권한, N+1, DRF 예외, 마이그레이션, `extend_schema`, `APITestCase` |
| `fastapi` | `fastapi.md` | `**/*.py` | Pydantic v2, `response_model`, 라우터 분리, `Depends`, lifespan, async 경계, `pydantic-settings`, Alembic |
| `node` | `typescript.md` | `**/*.{ts,tsx,js,jsx,mjs,cjs}`, `**/package.json`, `**/tsconfig.json` | lockfile 기준 패키지 매니저, strict TS, async 에러 처리, 로거, 환경 변수 검증, 테스트 |

- 규칙은 `paths`에 맞는 파일을 읽거나 편집할 때만 로드된다.
- 각 프로필의 `settings.fragment.json`은 그 스택의 검사·테스트(·빌드, lockfile 동기화) 명령 allow를 프로젝트 `.claude/settings.json`에 병합한다. 포맷 적용·마이그레이션 생성처럼 소스를 바꾸는 명령 형태는 넣지 않는다:
  - python: `uv run pytest *`, `uv run ruff check *`, `uv run ruff format --check *`, `uv run mypy *`, `uv sync *`, `pytest *`; 소스를 고치는 `uv run ruff check --fix …`·`ruff check --fix …`는 ask 규칙으로 확인을 받는다. 포맷 적용은 일반 권한 프롬프트나 포맷 훅으로 한다. `poetry run …`·`pipenv run …` 형태는 맞는 allow가 없어 일반 프롬프트가 뜬다.
  - django: `uv run python manage.py check *`·`showmigrations *`·`test *`·`makemigrations --check --dry-run *`(Django 4.2 미만에서 `--check`만 쓰면 파일을 만든다).
  - fastapi: `uv run alembic history *`·`current *`·`check *`.
  - node: `npm run typecheck *` 등 스크립트 명령과 `npx --no-install tsc *`·`eslint`·`prettier --check`·`vitest run`·`jest`. `npx <도구>`는 로컬에 없으면 레지스트리에서 받아 실행하므로 `--no-install` 형태만 허용한다.
- `--profile auto` 매핑: `python`→python, `django`→python+django, `fastapi`→python+fastapi, `node`→node. 감지 결과가 없으면 프로필 없이 적용한다. `--profile`을 생략하면 공통 템플릿만 적용하고, 감지된 스택이 있으면 `--profile auto`가 적용할 프로필을 `힌트:` 줄로만 알린다(규칙 파일이 이미 있는 프로필은 따로 밝힌다).
- `--profile`은 여러 번 줄 수 있다(예: `--profile python --profile django`).

### 4.8 프로젝트 템플릿 (`apply.sh` 결과)

| 커밋할 파일 | 커밋하지 않을 파일 |
|---|---|
| `CLAUDE.md`, `.gitignore`(추가된 줄) | `CLAUDE.local.md` (개인 메모) |
| `.claude/settings.json` | `.claude/settings.local.json` (개인 env·권한) |
| `.claude/rules/**` (`project.md`, 프로필 규칙, `--team`이면 `git.md`) | `*.dev_settings.new` (갱신 후보 파일) |
| `.claude/hooks/**` (`--with-format-hook`일 때) | `.claude/agent-memory-local/`, `.claude/worktrees/` |
| 선택: 팀원용 예시(커밋 가능) — `CLAUDE.local.md.example`, `.claude/settings.local.json.example` | |

- `.gitignore`에 `gitignore.claude`의 줄을 중복 없이 추가한다(기존 파일이 CRLF면 CRLF로).
- `CLAUDE.md`나 `.claude/CLAUDE.md`가 이미 있으면 새로 만들지 않는다(내용이 다르면 그 파일 옆에 `*.dev_settings.new`만 생성). `.claude/CLAUDE.md`만 있으면 `--force`로도 루트 `CLAUDE.md`를 만들지 않는다.
- `AGENTS.md`만 있으면 첫 줄이 `@AGENTS.md`인 `CLAUDE.md`를 만든다(AGENTS.md는 계속 로드됨). 다시 적용해도 같은 렌더링과 비교하므로 `변경 없음`이고, `--force`도 `@AGENTS.md`를 유지한다.
- 대상 파일이 심볼릭 링크(예: `CLAUDE.md → AGENTS.md`)면 `--force`는 링크 대상을 덮어쓰지 않는다. 대상 내용을 백업하고 링크를 일반 파일로 바꾼다. `.claude/settings.json`이 심볼릭 링크면 병합 결과를 실제 대상에 기록한다.
- `--with-format-hook` 없이 다시 적용하면 PostToolUse 포맷 항목을 뺀다. `.claude/hooks/`의 세 파일(`run-hook.sh`, `format-on-edit.sh`, `lib/common.sh`)이 저장소 사본과 같으면 백업 후 `삭제`한다. 수정된 파일이면 `수정된 훅 파일 — … 수동 정리` WARN을 내고, settings.json이 아직 참조하지 않으면 커밋할 파일 목록에서 뺀다.
- `.claude/rules/project.md`: 서브에이전트 보충 규칙(환경 함정, 메인 전용 공유 핫스팟, 검증 명령, 금지 사항) 템플릿.
- 팀 파일(`.claude/**`, `CLAUDE.md`)에 `~/.claude/`나 개인 스킬(`/commit`, `/harness-init`, `/harness-check`, `/preflight`, `/review-diff`, `/delegate`) 언급이 있으면 `validate.sh --project`가 WARN을 낸다.

## 5. ECC 플러그인과의 관계

ECC(everything-claude-code)를 전역으로 켠 PC를 기준으로, 기능이 겹치지 않게 나눴다. 플러그인 훅과 settings 훅은 순서 없이 병렬로 실행된다.

| 영역 | ECC | dev_settings |
|---|---|---|
| 사실 확인 게이트 | GateGuard | — |
| `--no-verify` 차단 | 있음 | `guard-destructive`(ECC 없는 PC용 대비책) |
| 설정 파일 보호 | config-protection | — |
| 편집 후 포맷·린트 | quality-gate(기본은 검사만) | `format-on-edit`(opt-in, ECC가 고치는 모드일 때 그 타입만 건너뜀) |
| `console.log` 검사 | 있음 | — (`typescript.md` 규칙으로 안내) |
| 세션 시작 컨텍스트 | session-start | `session-context`(저장소 상태·스택·보호 브랜치) |
| 비밀 파일·위험 명령·마이그레이션 | — | `guard-secrets` · `guard-destructive` · `guard-migrations` |
| 상태줄 | — | `statusline.sh` |
| 비용 추적·알림·MCP 상태·compact 전 저장 | 있음 | — |

- `--no-verify`는 양쪽이 모두 막으므로 차단 메시지가 두 개 뜰 수 있다.
- GateGuard 끄기: `ECC_GATEGUARD=off`. ECC 개별 훅 끄기: `ECC_DISABLED_HOOKS`(예: `post:quality-gate`).
- 포맷 훅과 ECC: ECC quality-gate는 기본적으로 검사만 하므로 겹치지 않는다. `ECC_QUALITY_GATE_FIX=true`일 때만 해당 타입을 건너뛴다. 정확한 조건은 아래가 모두 맞을 때다:
  - `~/.claude/settings.json`에서 ECC가 켜져 있다(`enabledPlugins`의 `"ecc@ecc": true`).
  - `ECC_QUALITY_GATE_FIX`가 `true`(대소문자 무관)이고, `ECC_HOOK_PROFILE`이 `minimal`이 아니고, `ECC_DISABLED_HOOKS`에 `post:quality-gate`가 없다.
  - 그래도 건너뛰는 것은 ECC가 고치는 타입뿐이다: `.py`(ruff/black), `.go`, prettier/biome 대상 `.ts` `.tsx` `.js` `.jsx` `.json` `.md`. `bash -n`·shfmt·rustfmt·terraform fmt·taplo는 항상 실행한다.
  - `CLAUDE_FORMAT_ON_EDIT=force`면 이 판단 없이 실행한다.

## 6. 커스터마이즈

### 6.1 env 변수

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
| `CLAUDE_FORMAT_ON_EDIT` | 켜짐(opt-in 프로젝트) | `off` 끄기, `force` ECC 판단 무시(5절) |
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

### 6.2 규칙·프로필·비밀 패턴

- **프로젝트 규칙 추가**: `<프로젝트>/.claude/rules/<이름>.md`. 특정 파일에만 적용하려면 frontmatter에 `paths`를 둔다(Claude Code가 읽는 유일한 필드).
- **전역 규칙 추가**: `claude/global/rules/`에 파일을 만들고 `./install.sh` 재실행. `~/.claude/rules/`를 직접 고치지 않는다.
- **프로필 추가**: `profiles/<이름>/rules/<규칙>.md`(`paths` 필수, 60줄 이내)와 `profiles/<이름>/settings.fragment.json`을 만든다. `apply.sh`의 프로필 목록(인수 검사·사용법)과 `--profile auto` 매핑(`apply.sh`의 `detect_profiles`, `/harness-init` 추정은 `claude/global/skills/harness-init/context.sh`)에도 추가한다. 새 스택 토큰이 필요하면 `claude/global/hooks/lib/detect-stack.sh`를 고친다.
- **비밀 패턴**: 훅이 전체 목록을, Read deny가 그 핵심 부분집합을 강제한다.
  - 훅: `claude/global/hooks/lib/secret-patterns.txt` + `guard-secrets.sh`의 경로 규칙. Bash 명령의 사전 필터도 이 파일의 글롭을 그대로 쓰므로, 패턴을 추가하면 훅을 고치지 않아도 `cat <이름>` 같은 명령에 적용된다(`tests/hooks/test-guards-secrets-3.sh`가 모든 글롭을 Bash `cat`과 Read로 확인).
  - 네이티브: `claude/global/settings.json`의 Read deny — .env 주요 변형·키·인증서·SSH·클라우드 자격 증명·CLI 도구 토큰(gh, Vault, cargo, Terraform, Hugging Face, Azure). `.env.*` 전체를 deny하면 `.env.example`까지 막히므로 나눠 둔다. `*.env`(`prod.env` 류)도 `sample.env` 같은 예제가 막히지 않게 훅에만 둔다(`CLAUDE_GUARD_SECRET_ALLOW`로 제외 가능).
  - 훅을 끄거나(`CLAUDE_GUARD_SECRETS=off`) 훅이 fail-open이면 훅 전용 패턴(`.env.test`, `*.env`, `.env~`, `.env_*`, `*.ppk`, `.pgpass` 등)은 보호받지 못한다.
  - `.env.*`에서 제외하는 것은 `.example`·`.sample`·`.template`·`.dist`다. 한쪽을 바꾸면 다른 쪽도 검토한다.

## 7. 설치 동작

```
./install.sh [--dry-run] [--force] [--no-settings] [--home <dir>] [--uninstall] [--restore <타임스탬프>] [--yes] [--help]
./apply.sh <프로젝트> [--profile python|django|fastapi|node|auto]... [--with-format-hook] [--force] [--dry-run] [--team] [--yes] [--help]
```

- **복사 방식만 지원**(심볼릭 링크 없음). 저장소에서 편집 중인 훅이 열린 모든 세션에 즉시 반영되는 사고를 막고, 설치본 수정 여부를 cksum으로 추적하기 위해서다.
- **파일별 계획**: `create`(새 파일) · `update`(지난 설치 후 손대지 않은 파일 갱신) · `skip-identical` · `keep-user-edited`(사용자가 고친 파일 유지 + 옆에 `<파일>.dev_settings.new` 생성 + WARN) · `conflict`(매니페스트에 없는 기존 파일, `--force` 없으면 유지 + `.new`) · `remove-stale`(저장소에서 사라진 파일, 손대지 않았으면 백업 후 삭제).
- **사용자가 지운 관리 파일**: 매니페스트에 있는데 사용자가 지운 파일(예: `rules/web.md`)은 `유지(사용자 삭제) <경로>`로 표시하고 다시 만들지 않는다. `--force`면 다시 만든다(settings 관리 규칙과 같은 정책).
- **트랜잭션**: 임시 stage 디렉터리에 전부 준비 → `bash -n`·JSON 검사 → 바뀔 파일만 백업 → 배치 → `settings.json`은 마지막에 같은 디렉터리 임시 파일에서 `mv`로 교체(심볼릭 링크면 실제 대상에 기록, 설치 중 변경되면 중단) → 매니페스트 기록. 중간 실패·중단 시 이번 백업으로 되돌린다(심볼릭 링크였던 파일은 백업에 남긴 링크 텍스트로 같은 링크를 다시 만든다 — `--restore`도 같다). 되돌리기에 실패한 파일이 있으면 백업을 지우지 않고 `--restore` 명령을 안내한다. stage 디렉터리는 어떤 경우에도 지운다.
- **settings 병합**(`scripts/merge-settings.py`): 사용자 키 보존(4.1 목록), permission 목록은 합집합, 훅은 매처 정규화(`Edit|Write` = `Write|Edit`)와 명령 기준 중복 제거. 사용자 쪽 다른 permission 목록에 있는 규칙은 넣지 않고 `WARN 충돌: <규칙> base=deny overlay=allow`처럼 알린다. `--force`면 `$schema`·`language`·`statusLine`·`worktree.baseRef`도 저장소 값으로 바꾸고 설치 기여분으로 기록한다(관리 값은 경로 단위라 `worktree`의 다른 키는 그대로다). 엄격한 JSON만 읽는다(JSONC 주석 불가). 엄격한 JSON이 아니면 파일을 배치하기 전에 위치(line·col)를 알리고 exit 1로 멈춘다.
- **사용자가 지운 관리 settings 항목**(permission 규칙·훅·`language`·`statusLine`·`worktree.baseRef`)은 매니페스트 `settings.user_deleted`에 값과 함께 기억하고, 저장소 커밋이 바뀌어 매니페스트를 다시 써도 `--force` 없이는 다시 넣지 않는다. 계획에 `settings: 유지(사용자 삭제): <항목>`과 `--force 로 복원` 안내가 찍힌다. 기억한 항목을 손으로 다시 넣으면 사용자의 것이 되어 `--uninstall`이 지우지 않고, 기억은 남아 또 지워도 다시 넣지 않는다. `--force`는 지운 항목을 다시 넣고 그 기억을 지운다(손으로 다시 넣어 둔 항목의 기억은 남긴다).
- 이벤트의 유일한 훅이나 `hooks` 객체 전체를 지워도 빈 껍데기(`"SessionStart": []`)를 쓰지 않는다. 매니페스트의 settings 부분이 손상됐으면 그 부분을 무시하고 계획과 `--uninstall`(dry-run 포함)에 `settings: WARN 매니페스트 settings… 형식이 잘못돼 무시함 — settings.json 의 관리 항목을 직접 확인`을 찍는다.
- **백업**: `~/.claude/backups/dev_settings/<YYYYmmdd-HHMMSS>.XXXXXX/`(최근 10개 유지). apply 백업은 `~/.claude/backups/dev_settings/apply/<프로젝트명>/`.
- **매니페스트**: `~/.claude/dev_settings.manifest.json`(설치 파일별 cksum, 저장소 커밋, settings 기여분과 사용자 삭제 기억 `user_deleted`), `~/.claude/dev_settings.repo`(저장소 경로).
- `--dry-run`: 아무것도 쓰지 않고 계획과 settings diff만 출력. `--uninstall`·`--restore`와 함께 쓰면 지울·되돌릴 파일 목록(제거는 settings diff 포함)만 출력하고 홈은 그대로 둔다.
- `--uninstall`: 매니페스트의 파일과 관리 settings 항목을 백업 후 제거. 사용자가 고친 파일·사용자 키·사용자가 다시 넣은 항목은 남긴다. 설치가 넣었거나 `--force`가 바꾼 `$schema`·`worktree.baseRef`, 설치 항목만 담고 있던 빈 컨테이너(이벤트 목록·`hooks`·`permissions`·`worktree` — 설치 전부터 있던 빈 객체 포함), 비어 있는 `skills/` 디렉터리도 정리한다. settings.json은 2칸 들여쓰기로 다시 쓴다.
- `--restore <타임스탬프>`: 해당 백업 디렉터리 내용을 되돌린다. 설치 요약에 정확한 명령이 출력된다.
- `--home <dir>`(`--home=<dir>`도 가능): 다른 홈에 설치(테스트용). 빈 값(`--home ''`)은 사용법 오류. `--no-settings`: settings 병합 생략. `-h`·`--help`: 도움말.
- **확인과 `--yes`**(install.sh):
  - 대화형 터미널(stdin이 TTY)에서는 파괴적 작업(아래 목록)일 때만 진행 전에 `[y/N]`을 묻는다. 추가형 설치는 묻지 않는다. `--yes`(`-y`)면 묻지 않는다.
  - 비대화형 실행(CI, 파이프, Claude의 Bash 도구)에서 추가형 설치는 묻지 않고 진행한다(바뀌는 파일은 백업).
  - 비대화형에서 파괴적 작업(`--uninstall`, `--restore`, 업그레이드의 `remove-stale` 삭제, `--force` 덮어쓰기)은 `--yes`가 있어야 한다. 없으면 `확인이 필요한 작업(<작업>) — 비대화형 실행이면 --yes 를 지정`을 출력하고 exit 2.
  - apply.sh의 `--force`(백업 후 덮어쓰기)도 같은 규칙이다: 대화형이면 `[y/N]`, 비대화형이면 `--yes`(없으면 exit 2). 그 외 apply.sh 작업은 묻지 않는다.
- `~/.claude/skills/`에서는 이 저장소의 스킬 7개 디렉터리만 다룬다. `learned/`·`synced/` 등 다른 디렉터리는 건드리지 않는다.
- 다시 실행하면 `변경 없음`(새 백업도 만들지 않음).
- 종료 코드:
  - `install.sh`: `0` 성공 · `1` 실패(롤백됨) · `2` 사용법 오류 · `3` 설치됐지만 validate FAIL.
  - `apply.sh`: `0` 성공 · `1` 거부/실패(롤백 없음 — 바뀐 파일만 백업) · `2` 사용법 오류 · `3` 적용됐지만 validate FAIL.
- `install.sh`는 `~/.claude`(심볼릭 링크면 실제 경로)가 이 저장소 안이면 거부한다. `apply.sh`는 대상이 `$HOME`, `~/.claude`(실제 경로 포함) 하위, 이 저장소 자체이면 거부한다.

## 8. 검증

- `scripts/validate.sh --repo [path] | --installed [--home <dir>] | --project <dir>` (`--installed`·`--project`는 함께 사용 가능, `--exit-zero`, `--max-lines N`, `--quiet`)
  - 출력: `OK|WARN|FAIL|INFO <검사>: <내용>`, 요약 `OK n · WARN n · FAIL n`. FAIL이 있으면 exit 1.
  - 검사: JSON 파싱, 스키마에 없는 키(WARN), 훅 이벤트·타입, 훅 스크립트 존재·실행 권한, `statusLine` 형식, 권한 규칙 문법(`Write(...)`·`Bash(x:*)`·공백 없는 와일드카드 `Bash(ls*)` 등 WARN)과 목록 간 중복, Read deny와 `secret-patterns.txt` 동기화, `bash -n`, 에이전트·스킬 frontmatter, 스킬 셸 주입 명령과 `allowed-tools` 규칙 일치(이 저장소 스킬은 FAIL), 규칙 `paths`, 깨진 심볼릭 링크, 템플릿 이름(`claude/` 아래 `CLAUDE.md`·`.claude/` 금지), 설치본과 저장소 커밋 차이.
  - `--project`는 팀 공유 파일의 개인 설정 참조(`CLAUDE.local.md`로 옮길 것)와 공유 설정·훅이 gitignore에 걸리는지도 본다.
  - `--repo`는 `merge-settings.py --selftest`와 `tests/run-all.sh`도 실행한다(`--quiet`면 생략).
- `tests/run-all.sh [--quick] [--filter <부분문자열>] [--verbose]`: 훅·스킬 스위트를 `/bin/bash`(3.2)와 PATH의 다른 bash(있으면)로, 설치 스위트(`validate.sh --repo --quiet` 포함)와 `merge-settings.py --selftest`를 한 번 실행한다. 실제 `~/.claude` 대신 공백이 들어간 임시 HOME을 쓴다.
  - 훅(`tests/hooks/`): `test-lib-*.sh`(공용 파서·`common.sh`), `test-guards-secrets*.sh`·`test-guards-destructive*.sh`·`test-guards-migrations*.sh`(가드별), `test-guards-cross.sh`(같은 입력을 세 가드에 넣어 함께 확인), `test-guards-nested*.sh`(문자열 안의 문자열·`find -exec` 프로그램 인수와 그 상한·지연), `test-guards-heredoc.sh`(셸이 읽는 heredoc 본문과 본문 속 명령 치환 — 우회 재현·무해 케이스를 세 가드를 합친 판정으로 확인), `test-aux-*.sh`(포맷·세션·상태줄). 번호 붙은 파일은 검증 라운드마다 추가한 회귀·성능 케이스다(200 KB heredoc 3.5초 이내, 큰 입력 3~8초 이내 등). 픽스처는 `tests/hooks/fixtures/`, 공용 함수는 `tests/lib/testlib.sh`.
  - 설치(`tests/install/`): `run.sh`가 `test-install.sh` · `test-install-upgrade.sh` · `test-install-edge.sh` · `test-install-safety.sh` · `test-apply.sh` · `test-apply-edge.sh`를 실행한다(공용 `helpers.sh`). `-edge`·`-safety`는 경계 조건과 실패·롤백·백업 보존 케이스다.
  - 스킬: `tests/skills/test-skills.sh`(context.sh, allowed-tools와 주입 명령 일치, 프로필 fragment). `tests/run-all.sh`가 함께 실행한다.
- 테스트 전용 env(평소에는 설정하지 않는다): `HOOK_FORCE_PARSER=jq|python3|none`(훅 파서 강제), `DEV_SETTINGS_FAIL_AT=<지점>[,<지점>…]`(설치 실패 주입. 지점: `place` `settings` `manifest` `restore`), `DEV_SETTINGS_IN_TESTS=1`(run-all.sh가 설정, `validate.sh --repo`의 재귀 실행 방지), `DEV_SETTINGS_TEST_REPO=<dir>`(설치 스위트를 저장소 사본에 실행), `VALIDATE_NO_PYTHON=1`(validate.sh의 python3 없는 경로 흉내), `SP_WBMAX=<n>`(공용 파서의 줄 수 상한, 기본 5000. 가드가 다시 나누는 셸 문자열에는 남은 몫과 이것 중 작은 값), `HOOK_TLIM=<초>`(가드 작업 시간 상한, 기본 6. 숫자가 아니면 상한 없음), `KEEP_TMP=1`·`T_KEEP=1`(설치·훅 테스트 임시 디렉터리 보존).
- CI(`.github/workflows/ci.yml`): push·PR마다 세 작업에서 `tests/run-all.sh`, `validate.sh --repo --quiet`, 비밀·이메일 패턴 검사를 실행한다.
  - ubuntu-latest 두 작업: bash 5와 GNU 도구에 awk를 gawk·mawk로 하나씩 고정한다.
  - macos-latest: `/bin/bash` 3.2와 Homebrew bash 5(run-all.sh가 둘 다 실행), BSD awk.
- `scripts/update-schema.sh`: schemastore에서 스키마를 받아 추가·삭제된 키와 훅 이벤트를 보여주고 스냅샷을 교체한다. 실행 후 이 README의 검증 기준 날짜를 갱신한다.

## 9. 파일 이력

| 이전 경로 | 현재 위치 | 사유 |
|---|---|---|
| `settings.json` | `vscode/settings.json` | VS Code 설정임을 명확히(끝 쉼표 오류 수정) |
| `copilot-instructions.md.example` | `copilot/copilot-instructions.md` | 도구별 디렉터리로 정리 |
| `agents/explorer.md` · `implementer.md` · `reviewer.md` | `claude/global/agents/` | 설치 구조(`~/.claude/agents/`)와 일치 |
| `agents/subagent-policy.md` | `claude/global/rules/subagent-policy.md` | 에이전트 정의가 아니라 항상 로드되는 규칙 |
| `CLAUDE.md.example` | `claude/project-template/CLAUDE.md.tmpl` + `profiles/python`·`profiles/django` 규칙 + `claude/global/rules/git.md`로 증류 후 삭제 | 특정 프로젝트 가이드를 범용 템플릿·선택형 프로필로 분리 |
| `request.md.example` | `claude/global/rules/core.md`(요청 재진술)와 `/api` 스킬로 흡수 후 삭제 | 요청 양식을 규칙과 워크플로로 일반화 |

## 10. 알려진 제한

- **Bash 권한 규칙과 훅은 보안 경계가 아니다.** 네이티브 `Bash(...)` 접두사 규칙은 `/bin/rm`, `bash -c '…'`, `git -C . push`로 우회된다. 가드 훅은 이를 보완하는 휴리스틱 파서(따옴표·heredoc·셸 문자열을 정해진 깊이까지만 푼다)라 변수 조합·스크립트 내부·인코딩으로 우회할 수 있다. 확실한 경계가 필요하면 sandbox를 쓴다.
- **가드 훅의 알려진 한계**(현재 동작):
  - 공용 파서가 안쪽 명령을 따로 보지 않는 형태: 옵션 표에 없는 옵션·따옴표 없는 `$OPTS`가 든 컨테이너 명령, `podman-compose`·`podman compose`·`nerdctl compose`, 그 밖의 원격 실행기(`lxc exec`·`multipass exec`·`limactl shell`·`vagrant ssh -c`), 벗기지 않는 래퍼(`gosu`·`su-exec`·`tini`·`dumb-init`·`xvfb-run`·`direnv exec`·`asdf exec`·`aws-vault exec`·`op run`·`nix develop -c`·`nix-shell --run`·`conda run`·`micromamba run`·`parallel`·`tmux`·`screen`), `docker exec`·`docker compose exec|run`·`kubectl exec` 안에서 접두(`gosu` 등) 뒤에 오는 `sh -c`, `docker compose run|exec --entrypoint sh 서비스 -c '…'`의 문자열(`guard-migrations`만 찾는다), `npx -c`·`npm exec -c`·`fd -x <셸> -c` 문자열, `env "A=1" 명령`, 셸 이름 `ash`·`$SHELL`, 스크립트를 쓴 뒤 실행(`cat > i.sh <<EOF … EOF` 후 `bash i.sh`). 셸이 heredoc 본문을 읽는지 가리지 못하는 다음 형태의 본문은 데이터로 본다: 본문 다음 줄에서 이어지는 파이프(`cat <<EOF |` … `EOF` 다음 줄의 `bash`), 묶음을 거치는 파이프(`(cat <<EOF) | bash`·`{ cat <<EOF; } | bash`·`cat <<EOF | (bash)`), 표준 입력을 스크립트로 실행하는 `-c` 문자열(`bash -c "$(cat)" <<EOF`·`sh -c 'sh' <<EOF`), 원격·권한 쪽 셸이 표준 입력을 읽는 `ssh host bash -s <<EOF`·`sudo -s|-i <<EOF`, `{ bash; } <<EOF`. 셸에 here-string으로 넘긴 명령(`bash <<< 'rm -rf /'`)도 펼치지 않는다(`bash <<< "$(curl …)"`의 pipe-to-shell만 본다). `source /dev/stdin <<EOF` 본문은 같은 셸에서 돌지만 자식 셸처럼 격리하므로 본문 안의 `cd`가 뒤 명령에 이어지지 않는다.
  - 래퍼·런타임 줄을 그대로 두므로 앞 세그먼트를 보는 규칙은 래퍼를 건너뛰지 않고(`echo / | caffeinate -i xargs rm -rf`는 ask-low, 래퍼 없이는 deny), 런타임·래퍼 뒤의 SQL heredoc(`podman exec -i db psql <<EOF`)은 SQL로 검사하지 않는다(셸 본문은 검사한다). `$'…'` 안의 이스케이프는 풀지 않으므로 `sh -c $'echo a\ngit push …'`의 `\n`은 줄바꿈이 아니다. 상한 근처의 큰 명령(셸 문자열 200개, 세그먼트 수천 개, `cd`·`pushd` 수천 개)은 macOS `/bin/bash` 3.2에서 훅마다 약 1~5초가 걸린다(부하 약 2). 작업 시간 상한(약 6초)은 세그먼트·토큰 사이에서만 확인하므로 한 번에 하는 큰 단계(1 MB 가까운 명령의 파싱·토큰화, 수만 자 문자열의 bash 글롭 비교, gawk 5.4에서 탭이 수만 개인 heredoc 본문의 공백 정리)는 멈추지 못한다: 단어 2만여 개인 1 MB 명령은 약 6.5초(부하 약 2), 부하 7~9에서 7~9초가 걸리고, 부하가 더 높으면 10초 제한을 넘겨 판정 없이 통과할 수 있다. 제한 안에 끝나도 앞 세그먼트(`cat .env; echo …`의 `cat .env`)를 판정하지 못해 `too-complex`(메인 ask-high)다.
  - 작업 상한(4.2)을 다 쓰는 셸 문자열 안의 문자열·셸이 읽는 본문·본문 치환 뒤의 위험 명령은 메인에서 deny가 아니라 `too-complex`(ask-high)다(`sh -c 'sh -c "true; …(2000개)"'; cat .env`, 짧은 명령 2000줄인 `bash <<'EOF'` 본문 다음 줄의 `rm -rf /`). 따옴표 없는 heredoc 본문(커밋·PR 본문)은 셸이 펼치는 대로 본다: `$(…)`·백틱 코드 스팬이 200개를 넘으면 무해해도 `too-complex`이고, 닫히지 않은 백틱 뒤 글(셸은 본문 전체를 거부한다)과 `cat <<EOF | sed … | sh`처럼 중간 단계가 고쳐 쓰는 본문도 명령으로 판정한다. 산문 본문은 `<<'EOF'`로 쓴다.
  - `guard-secrets`: 코드가 `.env`를 문자열로만 언급해도 deny다(`python3 -c "print('.env' in open('.gitignore').read())"`, `python3 - <<EOF` 본문). 이름에 secret·password 등이 든 파일은 내용과 무관하게 soft 단계 ask다(Django `password_reset_subject.txt` 템플릿 포함). `curl -H 'X-Api-Key: …'` 헤더 값도 ask다. 이름에 token만 든 파일(`token.txt`)은 soft가 아니다(`tokenizer.json`·`design-tokens.json` 오탐 회피, `*.token`·`token.json`은 hard). `find`·`fd -exec`로 따로 판정하는 프로그램은 따옴표를 뗀 단어로 보므로 `find . -exec echo '$GITHUB_TOKEN' \;`도 ask-high다.
  - `docker inspect`는 `Env`로 걸러 출력할 때만 ask이고, `while read …; done < .env`와 `gawk`·`mawk`·`gsed`의 비밀 인수는 deny가 아닌 ask-high다. 이름과 출력이 다른 세그먼트·문자열로 나뉜 `find -name .env -print0 | xargs -0 cat`·`find -name .env -exec sh -c 'cat "$1"' _ {} \;`은 잇지 않고, `-exec` 안의 래퍼(`-exec sudo cat .env \;`)는 머리를 벗기지 않아 deny가 아니라 ask-high이며, zsh `>>&` 뒤의 대상(`echo x >>& .env`)은 쓰기로 보지 않는다. Bash 사전 필터는 소문자 명령 문자열에서 키워드·패턴을 찾으므로 따옴표·백슬래시로 쪼갠 이름(`cat .e"nv"`)은 통과한다.
  - `guard-destructive`: SQL 문자열 리터럴 안의 키워드도 ask-high다(`psql -c "SELECT … ILIKE '%drop table%'"`). `runuser`·`chroot`·`unshare`·`systemd-run` 자체는 `sudo`처럼 권한 확인을 하지 않고 안쪽 명령만 판정한다. 전체 텍스트 검사(fork bomb `:(){ :|:& };:`, 블록 디바이스 리디렉션)는 커밋 메시지·heredoc 본문까지 보므로 그 문구가 든 커밋도 deny다. 태그만 푸시(`git push --tags`)는 릴리스 CI를 시작할 수 있어도 확인하지 않는다. `rm -rf node_modules package-lock.json`은 일반 파일이 섞여 ask-low다. 서브셸 `( … )`·셸이 읽는 heredoc 본문 안 `git checkout`의 브랜치 가정은 바깥으로 이어지지 않는다. find -exec 위치 매개변수는 `-name` 같은 거름 조건을 평가하지 않아 `find /tmp -name 'build-*' -exec sh -c 'rm -rf "$1"' _ {} \;`도 deny이고, 시작 디렉터리를 `/.`처럼 `.`으로 끝나게 쓰면 깊이 0을 판단하지 않아 ask-high다. `-exec /usr/bin/env sh -c`·`-exec sudo sh -c`·`-exec command sh -c`는 셸 문자열로 보지 않는다. `find -exec`·`fd -x`가 실행하는 프로그램은 `rm`과 파서가 펼친 셸 `-c` 문자열만 보므로 `fd -x rm -rf /`·`find . -exec git push --force origin main \;`는 통과하고 `find . -exec rm -rf / \;`도 ask-high다. 셸 문자열·셸이 읽는 본문 안의 대입은 보지 않아 `sh -c 'HUSKY=0 git commit -m x'`는 훅 우회 확인이 없다.
  - pipe-to-shell은 파서가 `|`와 `;`·`&&`를 구분하지 않아 근사한다: `curl …; bash -s`·`curl … && bash`·`curl … | xargs bash`도 ask-high다. 코드 안에서 표준 입력을 읽는 형태(`python3 -c "exec(sys.stdin.read())"`), `sudo -i`·`su`로 넘기는 표준 입력, 목록 밖 인터프리터(`php`·`deno`·`bun`), 다른 fd를 거치는 형태(`bash /dev/fd/3 3<&0`), 셸이 읽는 본문의 출력을 다시 셸로 넘기는 `bash <<'EOF' | sh`는 잡지 않는다. 본문 치환의 실행 여부는 그 줄의 마지막 명령으로 가린다(`cat > f <<EOF; bash x.sh` 본문의 `$(curl …)`도 ask-high, `bash <<EOF; echo done`의 것은 놓친다). SQL 미리 보기를 DB 클라이언트로 넘겼는지도 세그먼트 순서로 어림하므로 관계없는 DB 클라이언트가 뒤에 와도 ask-high이고, 미리 보기가 서브셸 안에 있거나 클라이언트가 셸 문자열 안에 있으면(`( alembic downgrade -1 --sql ) | psql`, `… --sql | sh -c 'psql'`) 메인의 롤백 ask-high가 없다(서브에이전트는 `guard-migrations`가 deny). DB 클라이언트 heredoc의 본문 치환(`psql <<EOF` … `$(alembic downgrade base --sql)`)은 서브에이전트도 판정이 없다.
  - deploy-runner는 이름만 본다: 경계 없이 붙은 단어(`predeploy`)는 통과하고, 경계로 나뉜 배포 단어는 읽기 작업이어도 ask-high다(`generate-release-notes.js`). TypeScript 러너(`tsx`·`ts-node`·`deno run`·`bun <경로>`), `source <스크립트>`, `python -m <패키지.deploy>`, PATH의 `deploy.sh`, 대소문자가 다른 이름(`Deploy.sh`)은 보지 않는다. golang-migrate `goto <버전>`은 버전을 비교하지 않아 롤백이어도 적용(ask-low)으로 본다.
  - `guard-migrations`가 보지 않는 쓰기: 패치 내용이 파일을 정하는 `patch -p1 < x.diff`, `git apply`·`git stash pop`·`git reset --hard`, `curl -O`·`-D`·`-c`, `wget -o`, `ln -sf`, 압축 해제, 스크립트(`python -c …`)가 쓰는 파일, 환경으로 내보낸 `CDPATH`·`GIT_WORK_TREE`, 위치를 모르는 cwd 변경 뒤 경로에 마이그레이션 디렉터리가 드러나지 않는 쓰기(`cd "$DIR"; echo x > 0001_initial.py`), 이름이 `migrations`인 저장소 루트 파일을 Bash에서 상대 경로로 고치는 것(Edit·Write와 절대 경로는 잡힌다), 따옴표 친 비머리 동사(`python manage.py "migrate"`), 미리 보기가 따옴표 셸 문자열 안에 있거나(`sh -c 'liquibase update-sql' | psql`) DB 클라이언트가 묶음 안에 있거나(`| (cd /tmp && psql)`) 명령이 여럿인 묶음에서 나오거나(`{ liquibase update-sql; echo; } | psql`) 변수·파일을 거치는 형태(`SQL=$(…); psql -c "$SQL"`, `> x.sql && psql -f x.sql`).
  - `guard-migrations`가 보수적으로 묻는 경우: `source` 뒤 상대 경로로 만드는 새 마이그레이션, 같은 명령에 `ssh`·`docker exec`가 글자로만 있어도 로컬에 새로 만드는 마이그레이션, `&&`를 구분하지 않는 돌지 않은 `cd` 후보(세션 cwd `db/`에서 `cd /tmp/x && cd migrate && echo x > notes.txt`), 셸 문자열·서브셸 안에서 마이그레이션 디렉터리로 들어간 `cd` 뒤 바깥의 상대 경로(`sh -c 'cd migrations'; echo x > 0009_new.py`는 서브에이전트 deny). git 저장소가 아닌 곳에서는 도구 이름의 상위 디렉터리(`…/goose/`) 때문에 모든 편집이 마이그레이션으로 잡힐 수 있다.
- `install.sh --force`가 다시 넣지 못한 항목(저장소가 더 이상 넣지 않는 항목, 다른 permission 목록과 충돌한 항목)의 삭제 기억은 `--force`가 매니페스트를 다시 쓸 때 지워진다. 그 뒤 충돌을 풀거나 저장소가 다시 넣으면 다음 설치가 그 항목을 넣는다.
- **fail-open**: 파서(`jq`/`python3`)가 없거나 훅이 실패하면 통과한다. 핸들러에 `"onFailure": "block"`(2.1.295+)을 추가하면 런처를 시작하지 못할 때, 훅이 timeout(10초)을 넘길 때, 출력 JSON이 깨졌을 때 도구 호출이 막힌다. 런처가 항상 exit 0이므로 훅 내부 오류는 여전히 통과하고, `jq`/`python3`가 없을 때도 결정 없이 통과(fail-open)한다.
- PreToolUse 훅은 `@파일` 멘션과 IDE 컨텍스트(열린 파일·선택 영역)에는 실행되지 않는다. 이 경로에는 Read deny만 적용된다(best-effort).
- Read deny는 `cat`·`head`·`tail`·`sed`·리디렉션 등 Claude Code가 인식하는 Bash 명령에만 적용된다. `grep -r`이나 스크립트 내부 읽기는 `guard-secrets`가 일부만 잡는다.
- Read deny가 Write·Edit도 막으므로 Claude가 `.env`를 직접 만들 수 없다. `cp .env.example .env`(확인 후 실행)를 쓰거나 사용자가 만든다.
- `statusLine`은 CLI와 VS Code 통합 터미널에서 확인했다. VS Code 확장 채팅 패널에서 표시되는지는 공식 문서(statusline·vs-code 페이지)에 나오지 않는다(미검증).
- 사용자(전역) 규칙과 프로젝트 규칙이 충돌하면 Claude가 어느 쪽을 따를지 보장되지 않는다. 프로젝트 `CLAUDE.md`에 명시적으로 적는다.
- 스키마 스냅샷에 문서화된 키 일부(`modelSettings` 등 약 48개)가 없다. 스키마가 `additionalProperties: true`라 오류는 아니며, `validate.sh`는 알려진 키를 예외로 두고 나머지를 WARN으로 알린다.
- `--link`(심볼릭 링크 설치) 모드는 없다. 저장소를 고친 뒤 `./install.sh`를 다시 실행한다.
- Windows는 검증하지 않았다.

## 11. 다음 단계

- Stop 훅: 검증하지 않고 완료를 보고하면 알림
- SubagentStop 훅: 서브에이전트가 소유 파일 밖을 바꿨는지 검사
- sandbox 프로필(파일·네트워크 경계)
- 에이전트 memory(`memory: project`) 운용 지침
- 플러그인 패키징(마켓플레이스 배포)
- `.worktreeinclude` 지원 검토(워크트리 생성 시 gitignore된 로컬 파일 복사)
