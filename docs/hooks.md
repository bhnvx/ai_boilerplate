# 훅 레퍼런스

[← README](../README.md)

훅이 무엇을 어떻게 판정하는지 자세히 적은 문서다. 요약은 README, 알려진 한계는 [limitations.md](limitations.md), env 변수 전체 표는 [customization.md](customization.md)에 있다.

## 1. 공통 원칙

모든 훅은 런처 `run-hook.sh <이름>`을 거친다. 상태줄 `statusline.sh`만 `statusLine`이 직접 실행하므로 런처·`CLAUDE_HOOKS_DISABLE`과 무관하다.

- 런처는 훅의 종료 코드와 무관하게 항상 `exit 0`. 문법 오류가 난 훅이 exit 2로 모든 도구를 막는 사고를 방지한다.
- 훅은 stdout JSON(`permissionDecision`)으로만 결정한다. exit 2를 쓰지 않는다.
- `jq`가 없으면 `python3`, 둘 다 없으면 아무 결정 없이 통과한다(fail-open).
- 차단·확인 사유에 규칙 ID가 붙는다. 예: `차단 [secrets:print]: cat .env — 비밀 파일 내용 출력`.
- 훅 입력 JSON을 해석할 수 없으면(`tool_name`이 보이는데 깨진 입력) `ask [hook:parse-error]`로 확인을 요청한다. 빈 입력은 결정 없이 통과한다.
- `Monitor` 도구는 Bash와 같은 권한 규칙으로 명령을 실행하므로 가드 3개가 Bash와 똑같이 검사한다. 명령 없이 `ws` 입력만 있는 감시는 통과한다.
- 서브에이전트 판단은 `agent_id`로 한다. `agent_type`은 `--agent`로 띄운 메인 세션에도 들어오므로 쓰지 않는다.

## 2. 훅 목록

| 훅 | 이벤트 · 매처 | 동작 | 끄기 | 설정 env |
|---|---|---|---|---|
| `guard-secrets` | PreToolUse · `Read\|Edit\|Write\|MultiEdit\|NotebookEdit\|Grep\|Bash\|Monitor` | 비밀 파일 읽기·출력·전송 deny(`git show`·`diff`·`log -p`·`blame`·`grep`이 내용을 출력할 때 포함). 복사·삭제·`source`·쓰기(`> 파일`, `openssl -out`·`-keyout`)·`git add`·env 덤프·비밀 변수 출력·비밀 값 출력 명령(`gh auth token`·`kubectl get secret -o yaml` 등)·내용 없는 검색(`grep -q`·`-l`·`-c`)·패턴·스크립트 파일(`grep -f`·`sed -f`)·비밀 의심 파일(`*secret*.yaml` 등) ask | `CLAUDE_GUARD_SECRETS=off` | `CLAUDE_GUARD_SECRET_EXTRA`, `CLAUDE_GUARD_SECRET_ALLOW` |
| `guard-destructive` | PreToolUse · `Bash\|Monitor` | 루트·홈 `rm -rf`, `.git` 삭제, 보호 브랜치 force push(`--force`·`-f`·`+refspec`·`--mirror`)·삭제, `--no-verify`(`git commit -nm` 같은 묶음 플래그·`--no-veri` 같은 접두 약어 포함), 디스크·시스템 명령 deny. 보호 브랜치 푸시·커밋, 그 밖의 force push(보호 브랜치 `--force-with-lease` 포함), DB 파괴 SQL·마이그레이션 롤백·리셋, 인프라·클라우드 쓰기, 배포·publish, sudo, `curl \| sh`, `git config core.hooksPath` ask | `CLAUDE_GUARD_DESTRUCTIVE=off` | `CLAUDE_GUARD_PROTECTED_BRANCHES`, `CLAUDE_GUARD_ASK_ON_PUSH`, `CLAUDE_GUARD_ALLOW_PATTERNS` |
| `guard-migrations` | PreToolUse · `Edit\|Write\|MultiEdit\|Bash\|Monitor` | 서브에이전트(훅 입력에 `agent_id`가 있을 때)의 마이그레이션 생성·적용·수정·삭제·롤백 deny. 기존 마이그레이션 수정·삭제, 파괴적 스키마 변경 ask(high). 적용 명령(`migrate`, `alembic upgrade`, `prisma migrate dev` 등) ask(low) | `CLAUDE_GUARD_MIGRATIONS=off` | — |
| `session-context` | SessionStart · 전체 | 날짜, 브랜치·ahead/behind·변경 수, 최근 커밋 3개, 스택, 규칙 파일 현황, 보호 브랜치 경고를 컨텍스트로 주입 | `CLAUDE_SESSION_CONTEXT=off` | `CLAUDE_GUARD_PROTECTED_BRANCHES` |
| `statusline.sh` | statusLine | `모델 │ ⎇ 브랜치* │ ctx % │ 5h %[ 7d %](없으면 $비용) │ 디렉터리[ │ eff 수준][ │ PR #번호]`(7d는 50% 이상일 때만) | settings의 `statusLine` 제거 | `CLAUDE_STATUSLINE_COLOR=0`, `NO_COLOR` |
| `format-on-edit` | PostToolUse · `Edit\|Write\|MultiEdit` (프로젝트 opt-in) | 프로젝트가 설정한 포매터만 실행(ruff/black/isort, prettier/biome, gofmt, rustfmt, shfmt, terraform fmt, taplo). `.sh`는 `bash -n`(shebang이 없거나 bash·sh·dash·ash일 때, `env` 경유 포함). 결과를 컨텍스트로 알림. ECC와의 관계는 [components.md](components.md) 5절 | `CLAUDE_FORMAT_ON_EDIT=off` | `CLAUDE_FORMAT_ON_EDIT=force`, `CLAUDE_FORMAT_TIMEOUT`(기본 20초) |
| `stop-verify` | Stop | 이번 턴에 파일을 고치고도 마지막 수정 뒤에 검증 명령(테스트·린트·타입 검사·빌드)을 실행하지 않았고 응답에 '미검증' 표기도 없으면 사용자에게 알린다. 막지 않는다(8절) | `CLAUDE_STOP_VERIFY=off` | `CLAUDE_STOP_VERIFY=remind`, `CLAUDE_STOP_VERIFY_EXTRA` |
| `subagent-scope` | SubagentStop · 전체 | 서브에이전트가 위임 프롬프트의 '소유 파일' 밖을 고쳤으면 사용자에게 알린다. 막지 않는다(8절) | `CLAUDE_SUBAGENT_SCOPE=off` | `CLAUDE_SUBAGENT_SCOPE=remind` |

## 3. 판정 단계와 `permission_mode`

| 단계 | 동작 | 예 |
|---|---|---|
| deny | 항상 차단 | `cat .env`, `rm -rf ~`, `git push --force origin main`, `git commit --no-verify` |
| ask-high | 모든 모드에서 확인 요청(`bypassPermissions`는 아래 참고) | `git push origin main`, 보호 브랜치 커밋, 보호 브랜치 `git push --force-with-lease`, `psql -c "DROP TABLE …"`, `kubectl delete`, `make deploy`, `sudo`, `echo $AWS_SECRET_ACCESS_KEY`, `grep -q KEY .env`, 기존 마이그레이션 수정 |
| ask-low | `default` `acceptEdits` `dontAsk` `plan`에서 확인, `auto` `bypassPermissions`에서는 결정 없이 통과(모드·분류기에 맡김) | `rm -rf ./src`, 비보호 브랜치 `git reset --hard`, `git checkout <파일>`, `git stash drop`, `printenv`, `manage.py migrate` |

- 모드는 훅 입력의 `permission_mode`로 판단한다.
  - 공식 문서 기준(permission-modes·hooks 문서): `dontAsk`는 프롬프트가 뜰 호출을 모두 자동 거부하므로 ask도 거부되고, `auto`에서 훅의 ask는 분류기가 아니라 권한 프롬프트로 간다("PreToolUse `ask` decisions in auto mode").
  - `bypassPermissions`에서는 자동 승인하지 않는 목록("Actions no mode auto-approves")에 훅 ask가 없어 ask-high도 확인 없이 실행될 수 있으므로, 이 모드에서 확실한 차단은 deny뿐이다(deny 규칙은 모든 모드에서 막고, 훅의 `deny`는 도구 호출을 막는다).
- 재생성 가능한 디렉터리(`node_modules` `.venv` `dist` `build` `.next` `__pycache__` `coverage` 등)와 임시 디렉터리 `rm -rf`는 조용히 허용한다.
  - 임시 디렉터리는 정규화한 경로로 판단한다: `/tmp` `/private/tmp` `/var/folders` `/var/tmp` 아래면 통과(`cd /tmp && rm -rf x` 포함), `/tmp/../etc`처럼 벗어나면 정규화한 경로의 규칙(시스템 경로 deny 등)을 따른다.
  - 임시 루트 자체(`rm -rf /tmp/*`, 하위 경로 없는 `"$TMPDIR"`·`"$TMPDIR"/*`)는 deny이고, 임시 경로에 있는 세션 작업 디렉터리 안은 일반 규칙을 따른다.
- 삭제 대상이 변수·명령 치환이면: `"$TMPDIR/…"`·`"${TMPDIR:?}/…"`(`$TMP`·`$TEMP`도 같음)는 `..`가 없으면 통과하고, 기본값 연산자는 기본값이 글자 그대로의 임시 경로일 때만 통과한다(`"${TMPDIR:-/tmp}/x"`; `"${TMPDIR:-$HOME}/x"`는 ask-low, `"${TMPDIR:=$HOME}/x"`는 deny).
  - 값을 바꾸는 연산자(`:+`·`#`·`%/*` 등), 이름이 다른 변수(`$TMPDIR_BUILD`), 치환 결과(`rm -rf "$(mktemp -d)"`)는 펼쳐지지 않은 경로로 보아 deny이고(의도된 동작), `"${BUILD_DIR:?}/stuff"`처럼 `:?`·`:-`로 보호한 일반 변수 경로는 ask-low다.

## 4. 공용 파서: 명령을 읽는 방법

공용 파서(`hooks/lib/shellparse.sh`)가 명령을 세그먼트로 나누고, 세 가드가 같은 결과를 본다.

### 4.1 명령 치환과 셸 문자열

- 명령 치환(`$(…)`·백틱·`<(…)`)은 바깥 명령에 자리표시자로 남기고 안쪽 명령을 별도 세그먼트로 검사한다(`env $(cat .env) node app.js`는 안쪽 `cat .env` 때문에 deny).
- 셸 문자열도 같다: `sh`·`bash`·`zsh -c`, `su -c`·`-lc`·`--command`, `runuser … -c`, `ssh host '…'`, `eval`, 실행기 `find -exec|-execdir|-ok|-okdir <셸> -c`·`watch`·`env -S`·`nsenter … <셸> -c`·`flock 파일 -c`·`mise exec -c`·`script -c`.
- `-c` 뒤의 옵션(`--` `-x` `-o 이름`)은 건너뛰고, 경로·대문자 셸 이름(`/opt/homebrew/opt/bash/bin/bash`, `DASH`)도 셸로 본다.
- 문자열 안의 `cd`는 바깥 작업 디렉터리를 바꾸지 않는다(같은 셸에서 도는 `eval`은 바꾼다).
- `git push origin $BRANCH`·`$(git branch --show-current)`처럼 펼쳐지지 않은 refspec은 현재 브랜치로 본다.

### 4.2 문자열 안의 줄바꿈·heredoc·문자열

- 셸 문자열(`sh -c`·`bash -c`·`su -c`·`find -exec sh -c`·컨테이너·래퍼 안 `sh -c`·`ssh`·`eval`) 안의 줄바꿈은 최상위처럼 명령을 나누고(주석·줄 잇기도 같다), 문자열 안의 heredoc도 최상위처럼 본다: DB 클라이언트 SQL(`sh -c 'psql <<EOF …'`), 셸이 읽는 본문(`bash <<EOF`·`cat <<EOF | bash` — 아래 heredoc 항목처럼 세 가드가 본문의 명령을 판정한다), 코드 본문(`python3 <<EOF`).
- 문자열 안의 문자열(`sh -c 'sh -c "…"'`·`sh -c "bash -c '…'"`·`sh -c 'eval "…"'`·`ssh host 'sh -c "…"'`·문자열 안의 `find -exec sh -c`)도 세 가드가 같은 규칙으로 다시 나눈다: 최상위의 문자열을 깊이 1로 세어 깊이 3까지 펼치고(깊이마다 `cd` 격리 — `eval`만 같은 셸, `find -exec` 위치 매개변수, `guard-secrets`의 이웃 규칙은 펼친 문자열마다 따로), 깊이 3 문자열 안의 문자열은 한 명령으로 머리만 판정한다: 줄바꿈·탭을 공백으로 읽으므로 `;`·줄바꿈 뒤 명령은 따로 보지 않고(`echo a; rm -rf /`는 통과, `.env` 같은 이름 언급은 ask-high), 4096자를 넘으면 앞 4096자만 보고 `too-complex` 바닥이다.

### 4.3 컨테이너 런타임과 접두 래퍼

- 컨테이너 런타임(`docker run`·`docker container exec|run`·`podman`·`nerdctl` `[container] exec|run`·`docker-compose exec|run`)과 접두 래퍼(`flock 파일`·`mise exec|x … --`·`caffeinate`·`chrt`·`ionice`·`taskset`·`setsid`·`unbuffer`·`chroot 새루트`·`script -q 파일 명령`·`unshare`·`systemd-run`·`runuser -u 사용자 --`)는 원래 줄을 그대로 판정하고, 벗긴 안쪽 명령을 한 번 더 판정한다(`--entrypoint X`는 안쪽 명령의 머리).
- 컨테이너 안쪽 머리가 `busybox`·`tini --`·`gosu`·`dumb-init`이어도 그 뒤의 `sh -c '…'`를 찾는다.
- 그래서 `docker run --rm img cat .env`·`podman run img busybox sh -c 'cat .env'`·`caffeinate -i rm -rf /`는 deny다.
- 옵션 표에 없는 옵션·따옴표 없는 `$OPTS`·실행할 명령이 없는 형태는 벗기지 않는다.

### 4.4 따옴표·대소문자 변형과 리디렉션

- 명령 머리와 옵션의 따옴표·백슬래시·대소문자 변형(`"rm" -rf`, `r\m`, `RM`, `SUDO rm`, `sh "-c"`, `nice "-n" 5 …`, `find … "-exec"`, `runuser -u 사용자 "--" …`)은 같은 규칙으로 판정한다.
- 리디렉션 연산자는 한 단어로 읽는다.
  - `>|`는 파이프가 아니라 쓰기이고(`echo x >| rm -rf /`는 `rm`이라는 파일에 쓰기), fd 번호가 붙은 연산자(`2>>`·`100>>`), `>&파일`(= `>파일 2>&1`), zsh의 덮어쓰기 강제 `>!`·`>>!`·`&>!`·`>&!`·`>&|`도 쓰기다(Bash 도구가 zsh로 돌 수 있다).
  - `2>&1`·`>&2`·`>&-`는 fd 복제·닫기다.
  - zsh `>>&`·`>>&|`·`>>&!`(표준 출력·오류 덧붙이기)는 `guard-migrations`와 블록 디바이스 검사만 쓰기로 읽는다.

### 4.5 셸이 읽는 heredoc 본문

- 셸이 스크립트로 읽는 heredoc 본문(`bash <<EOF`·`bash -s`·`sudo bash`·`docker exec -i …`·`kubectl exec -i … --`·`docker run -i 이미지` 뒤의 `sh`, `ssh host <<EOF`, `su - <<EOF`, `cat <<EOF | bash`)은 세 가드가 최상위 명령처럼 판정한다.
- 셸처럼 본문의 줄 나눔과 줄 잇기(`\`), `<<-`의 줄 앞 탭 제거, 따옴표 없는 구분자의 `\$` 풀기를 반영하고, 서브셸·명령 치환 안의 heredoc도 같다.
- 본문을 읽는 명령은 heredoc마다 `<<`를 가진 명령과 그 파이프라인으로 정한다 — `bash -c '…' <<EOF`·`bash script.sh <<EOF`·`bash -n <<EOF`의 본문과 `cat <<EOF > f; bash`처럼 다른 명령으로 가는 본문은 데이터다.
- 본문은 셸 문자열과 작업 상한(아래)을 함께 쓴다: 상한을 다 쓰는 본문(짧은 명령 약 2000줄, 토큰이 많으면 대략 20~40 KB)은 남은 본문과 뒤 명령을 판정하지 못하고, 96 KB를 넘는 본문은 다시 나누지 않고 앞 4096자만 본다(뒤 명령은 판정한다).
- 둘 다 `too-complex` 바닥이다.
- 따옴표 없는 구분자의 본문 속 명령 치환(`$(…)`·백틱)은 바깥 셸이 실행하므로 안쪽 명령을 판정한다(`cat <<EOF … $(cat .env) … EOF`는 deny, `\$(…)`와 `<<'EOF'` 본문은 바깥 셸에서는 글자 그대로).
- heredoc 본문은 1 MB까지 검사하고(코드 heredoc은 비밀 파일 경로만), 200 KB heredoc은 훅마다 약 0.2~0.8초, 셸이 읽는 200 KB 본문은 1초 안팎이 든다(macOS `/bin/bash` 3.2 측정, 테스트 기준 3.5초 이내).
- 셸 문자열이 250개를 넘는 명령도 판정한다.

### 4.6 작업 상한

- 작업 상한: 파서는 명령 치환이 수천 개여도 선형 시간에 나누되, 내는 줄(세그먼트·치환 경계·셸 문자열)이 5000개를 넘으면 그 뒤를 읽지 않고, 이미 읽은 부분(열린 서브셸·치환 안의 명령과 그 바깥 세그먼트, `env -S` 문자열, 그 줄의 heredoc)은 입력이 거기서 끝난 것처럼 마무리해 낸다(줄이 5000개를 넘는 `( rm -rf /; … )`·치환이 1700개인 `rm -rf / $(…) …`도 deny).
- 단어가 24000개를 넘거나 단어 하나의 조각(이스케이프·따옴표)이 8192개를 넘어도 같게 멈추되 읽다 만 그 세그먼트는 버린다.
- `guard-secrets`·`guard-destructive`는 최상위와 다시 나눈 셸 문자열을 합쳐 세그먼트 2000개까지 판정하고, 셸 문자열은 명령마다 모든 깊이를 합쳐 200개(글자 수 합 96 KB)까지만 다시 나누며 그 뒤 문자열은 앞 4096자만 한 세그먼트로 판정한다(이 세그먼트는 줄바꿈을 공백으로 읽지 않으므로 여러 줄에 걸친 SQL·`curl | sh`는 `too-complex` 바닥이 맡는다).
- 토큰 수(`guard-destructive` 8000·`guard-secrets` 4000, `find`·`fd -exec` 프로그램 256), `guard-secrets`가 분류하는 글롭 `{a,b}` 대안(256), 세그먼트 분석용 fork(가드마다 100회), `rm` 대상 수(1000), 4096자를 넘는 명령 이름(`guard-secrets`는 단어·경로도), `guard-migrations`가 보는 파서 줄 수 합(5000), 가드마다의 작업 시간(약 6초)에도 상한이 있다.
- 상한을 넘으면 이미 나온 줄의 판정(deny 포함)은 그대로 두고 `too-complex`(메인 ask-high, 서브에이전트 deny)를 바닥으로 둔다(가드마다 사전 필터를 통과한 명령만).
- 그래서 보통 부하에서는 10초 제한을 넘겨 판정 없이 통과하지 않지만([limitations.md](limitations.md) 2.2절), 보지 못한 부분에만 있는 위험 명령은 메인에서 deny가 아니라 ask-high다.

## 5. `guard-secrets` 판정 세부

- `uv run --env-file .env …`·`docker compose --env-file .env …`는 실행 자체는 통과하지만, 그 명령이 환경을 출력·덤프하면(`env`, `printenv`, `python -c 'print(os.environ)'` 등) deny다.
- 파일로 보지 않는 인수: `tar`·`rsync`·`grep`의 `--exclude`·`--exclude-dir`, `zip -x` 목록, `rg -g '!…'`, `grep`·`rg`의 `--regexp=` 패턴, 인라인 메시지(`git commit`·`tag`·`notes`·`stash`의 `-m`, `gh`·`glab`의 `--title`·`--body`·`--notes`·`--description`).
  - `--exclude-from`·`tar -X`·`grep --include`·`zip -x @목록`과 `-F`·`--file`·`--body-file`은 파일로 본다.
  - 비밀 파일을 패턴·스크립트 파일로 쓰면(`grep`·`rg`·`git grep`의 `-f`, `sed`·`awk`·`jq`의 `-f`·`--file`) 일치한 줄이나 오류 메시지로 값이 샐 수 있어 ask(high)이고, 처리 대상이면 deny다(`sed -f x.sed .env`).
- 이름만 쓰는 git 명령(`git check-ignore`·`ls-files`·`status`(`-v` 제외)·패치 옵션 없는 `log -- .env`·`rm --cached`)은 통과한다.
  - `git add`·`rm`·`mv`와 내용을 내지 않는 `git show --stat`·`diff --name-only`·`grep -l`은 ask(high)다.
- `echo '$TOKEN'`(작은따옴표)·`${TOKEN:+x}`·`${#TOKEN}`은 값을 내지 않아 통과한다.
  - 같은 명령에 셸 실행(`-c` 없는 `sh`·`bash`, `xargs` 아래 셸)·`eval`·`source`·`ssh`·`su`·`envsubst`가 있으면 작은따옴표도 ask이고, `${TOKEN:-x}`·`${TOKEN:0:4}`·`${TOKEN#…}`는 ask다.
- 예제·템플릿 제외(`.example`·`.sample`·`.template`·`.dist`)는 중간 확장자(`secrets.example.yml`, `.env.example.json`)에도 적용한다.
  - 다만 `.local`로 끝나는 이름(`.env.example.local`), 끝 확장자가 키·인증서·키스토어·`.env`·`.token`인 이름(`api.example.com.key`), 자격 증명 디렉터리(`~/.ssh` 등) 안의 중간 확장자 이름(`~/.ssh/id_rsa.example.txt`)은 제외하지 않는다(`~/.ssh/id_rsa.example`처럼 끝 확장자가 예제면 훅도 제외한다 — `~/.ssh/**`는 Read deny 대상).
- soft 단계(이름에 secret·password·apikey 등)는 경로 모양 인수에만 적용한다.
  - URL, JSON 본문, `curl -d`·`--data`·`-F`·`wget --post-data` 본문, `pytest -k`·`-m` 식은 보지 않고, `@파일` 업로드는 본다.
- `find`의 이름 조건(`-name`·`-path` 등, 없으면 시작 경로)이 비밀 파일이면 `-exec`로 넘기는 프로그램으로 판정한다: 출력기 deny(`grep -l`·`-q`·`-c`는 ask), `cp`·`mv`·`install` ask(high), `scp`·`rsync`·`curl -T` deny.
  - `find`·`gfind`의 `-exec`·`-execdir`·`-ok`·`-okdir` … `;`|`+`와 `fd`의 `-x`·`--exec`·`-X`·`--exec-batch`가 실행하는 프로그램과 인수는 따로 한 명령으로도 판정한다(`find . -exec cat .env \;`·`fd -x cat .env`는 deny, `find . -exec cat README.md \;`·`find . -name '*.py' -exec grep -n TODO {} +`는 통과).
  - `find`의 셸 `-c` 문자열은 파서가 펼친 것으로만 본다.
  - heredoc 연산자에 구분자가 붙으면(`<<EOF`) 다음 단어는 인수다: `cat <<EOF .env`는 deny, `cat <<EOF > .env`는 쓰기라 ask(high)다.

## 6. `guard-destructive` 판정 세부

- `git config [--global] core.hooksPath <경로>`는 ask(훅 우회)다. `.husky`·`.githooks`·`.git/hooks`·`.hooks`·`.lefthook*` 같은 저장소 안의 관례적 경로는 통과한다.
- `git commit`의 짧은 플래그는 git처럼 왼쪽부터 읽는다: `-nm x`·`-anm x`는 `--no-verify`(deny)이고 `-m"fix: null"`·`-uno`·`-Sn`은 통과한다.
  - `--no-veri` 같은 고유 접두도 `--no-verify`로 본다.
  - `-n`이 `--no-verify`인 것은 commit뿐이다(push는 `--dry-run`, cherry-pick·revert는 `--no-commit`, merge는 `--no-stat`).
- refspec 없는 `git push [원격] --tags`는 태그만 푸시하므로 보호 브랜치 규칙을 적용하지 않는다(`--follow-tags`, `git push origin main --tags`는 브랜치 푸시).
- `git checkout <경로>`(커밋이 아닌 기존 경로·글롭)와 `git checkout <rev> <경로…>`는 `git checkout -- <경로>`처럼 ask-low이고, 브랜치이면서 경로인 이름은 브랜치 전환으로 본다.
- 보호 브랜치로의 `--force-with-lease`는 deny가 아니라 ask(high)다(`git.md`가 허용하는 강제 푸시 형태라 `auto`에서도 확인만 받는다).
- `curl | sh`는 실제로 실행되는 것만 본다: 앞선 `curl`·`wget` 출력을 표준 입력으로 읽는 셸·인터프리터(`sh`, `bash -s`, `bash -eo pipefail`, `python3 -`·`-u`), 표준 입력 장치를 스크립트로 받는 형태(`bash /dev/stdin`·`zsh /dev/fd/0`, `source /dev/stdin`, `bash -c "$(cat)"`), `sh -c "$(curl …)"`·`eval "$(curl …)"`·`bash <(curl …)`·`python3 <(curl …)`·`bash <<< "$(curl …)"`, 셸 문자열·`ssh host`·컨테이너가 실행하는 문자열, 셸이 읽는 heredoc(`bash <<EOF`, `cat <<EOF | bash`).
  - 파일로 쓰는 heredoc, 커밋 메시지, `gh`·`echo` 인수, 주석, 다운로드 후 실행(`curl -o i.sh … && sh i.sh`), 스크립트 인수(`| bash setup.sh`)·명령 문자열(`| bash -c '…'`), `|| bash x.sh`는 보지 않는다.
- 배포 스크립트·타깃(deploy-runner)은 이름으로 판단한다.
  - 스크립트는 파일 이름에서 확장자를 뗀 것, 타깃은 `make`·`just`·`rake`·`task`·`npm run` 등의 타깃이다.
  - `deploy` `release` `publish` `rollback` `destroy` `promote` `ship`이 경계(`.` `_` `-`, 타깃은 `:`도)로 나뉜 단어이거나 이름이 `prod`·`production`으로 시작하면 ask-high다(`staging-deploy.sh`·`prod-db-reset.sh`·`deploy_and_test.sh`·`npm run app:deploy`·`make deploy`는 ask, `seed_products.py`·`update-prod-config.sh`·`sync_to_prod.py`·`npm run build:prod`는 통과).
  - 테스트 파일(`test_*`·`*.test`·`*.spec`, 앞부분이 한 단어인 `*_test`·`*_spec`), 첫 구성 요소가 `test`·`lint`·`check` 등인 타깃, 실행하지 않는 `bash -n`·`node --check|--test`·`python -m py_compile|compileall|pytest`는 제외한다.
  - 셸·python·node는 옵션 값을 인터프리터마다 읽어 스크립트를 찾고(`bash -e deploy.sh`, `python3 -W ignore deploy.py`, `node -r dotenv/config deploy.js`, `bash < deploy.sh`, 경로가 붙은 `.venv/bin/python`도 같다), `make`·`just` 등은 `KEY=VALUE` 대입과 값을 받는 옵션을 건너뛴다(`make ENV=production deploy`·`make -e deploy`는 ask).
- `make`의 `-j`·`--jobs`·`-l`·`--load-average`는 GNU make처럼 뒤 단어가 숫자일 때만 그 값으로 본다(`$(nproc)`·`$JOBS`처럼 `$`로 시작하는 펼침도 값).
  - 그래서 `make -j deploy`·`make -j $(nproc) deploy`는 ask-high다.
- `gh api`는 메서드로 판단한다: `-X`·`--method`가 우선이고 `-f`·`-F`·`--input`은 기본값만 POST로 바꾼다.
  - GET·HEAD는 통과, 그 밖은 ask-high다.
  - `gh api graphql`은 `query=` 값이 모두 `query`·`{`·`fragment`로 시작하고 `mutation`이 없는 인라인 문서일 때만 읽기로 본다(`query=@파일`·명령 치환·값 없음은 ask-high).
- 인프라·배포 CLI는 첫 인수가 버전·도움말 플래그(`--version` `-version` `--help` `-help` `-h`)이고 나머지도 플래그뿐이면 통과한다.
  - `aws logs tail`·`gcloud logging read`·`helm diff`·`brew services [list|info]`도 통과한다.
  - 배포 하위 명령은 ask-high다: `vercel`, `netlify`·`fly`·`wrangler`·`sls`·`sam`·`cdk`·`eb`·`firebase`·`kamal deploy`, `gcloud app|run|functions deploy`, `supabase functions deploy`, `railway up|redeploy`, `amplify publish|push`, `cf push`, `zappa deploy|update|rollback`.
  - publish는 전역 옵션 뒤의 하위 명령으로 본다(`npm -w <ws> publish`, `pnpm -r publish`, `yarn workspace x npm publish`, `npm publish --dry-run`도 ask-high).
- 블록 디바이스(`/dev/disk*`·`/dev/rdisk*`·`/dev/sd*`·`/dev/nvme*`·`/dev/hd*`)로 쓰는 리디렉션은 연산자(`>|`·`>!`·`>&` 등)·붙여 쓴 대상·따옴표 친 경로와 관계없이 deny다(`/dev/null`·`/dev/tty` 등은 통과).
- `find … -exec|-execdir|-ok|-okdir sh -c '…' 인수… \;|+` 안의 위치 매개변수(`$0`…`$9`·`${N}`·`$@`·`$*`)는 find가 넘기는 인수로 바꿔 판단한다(빈 인수도 한 자리, `-c` 뒤 옵션 `--`·`-x`·`-o 이름`은 건너뛴다).
  - `{}`는 시작 디렉터리 아래 경로로, `-mindepth 1` 이상이 없으면 시작 디렉터리 자체(깊이 0)로도 판단한다(마지막 구성 요소가 `.`·`..`인 경로와 `-r` 없는 rm의 시작 디렉터리 자체는 뺀다).
  - 그래서 `find . -name '*.pyc' -exec sh -c 'rm -rf "$1"' _ {} \;`는 `find -exec rm`과 같은 ask-high이고, `find / …`·`find ~ …`·`find /tmp …`는 deny다.
  - 풀 수 없는 형태(`for f; do rm -rf "$f"; done`, 인수에 없는 매개변수, 대문자 셸 이름)는 위치 매개변수를 풀지 않는 원래 규칙(재귀 rm이면 deny)을 쓰고, 판단 작업량 상한(명령마다 200회, find 단어 4000개)을 넘는 입력도 원래 규칙을 쓰되 적어도 `find -exec rm`과 같은 ask-high를 남긴다.

## 7. `guard-migrations` 판정 세부

- DB 마이그레이션 롤백·리셋·초기화(`flyway clean`, `rails db:rollback`, `artisan migrate:fresh`, `supabase db reset` 등)의 ask(high)는 `guard-destructive`가, 서브에이전트일 때의 deny는 `guard-migrations`가 담당한다.
  - 도구와 동사 사이에 옵션이 있어도 같다(`alembic -c alembic.ini downgrade -1`, `flask --app wsgi db downgrade`, golang-migrate `down`·`drop`, `liquibase … dropAll`, `django-admin flush`).
  - `makemigrations --check`·`--dry-run`은 생성으로, SQL만 출력하는 미리 보기(`alembic`·`flask db`의 `--sql`, liquibase `update-sql`·`rollback-sql` 같은 `*-sql`·`*SQL`)는 적용·롤백으로 보지 않는다.
  - 미리 보기를 DB 클라이언트(`psql`·`mysql`·`sqlite3` 등)로 넘기면(`| psql`, `psql -f <(…)`, `psql -c "$(…)"`) 실제로 실행되므로 원래 명령처럼 본다(롤백 ask-high, 적용 ask-low, 서브에이전트 deny).
- 셸 명령은 실제로 쓰는 경로로만 판단한다: 리디렉션 대상(fd 복제·닫기 제외), `tee` 출력 파일, `cp`·`mv`·`install`·`rsync`·`scp`의 목적지(마지막 인수나 `-t`), 제자리 편집(`sed -i`·`perl -i`·`ruby -i`, `git checkout|restore <경로>`(`--staged`만이면 제외), `dd of=`, `curl -o`, `wget -O`, `truncate`, `patch <파일>`).
  - 그래서 `ls migrations/*.py 2>/dev/null`, `grep … migrations/0001_initial.py > /tmp/out.txt`, `cp migrations/0001_initial.py /tmp/`는 통과한다.
  - `mv`·`git mv`의 원본과 `rm`·`git rm`의 대상이 마이그레이션이면 삭제(ask-high)다.
- 쓰는 파일이 이미 있으면 기존 마이그레이션 수정(ask-high), 없으면 생성이다.
  - 생성은 Write 도구와 같다: 메인은 통과하되 명령 어디에든(heredoc 본문·다른 파이프 단계 포함) 파괴적 스키마 변경이 보이면 ask-high(`migrations:destructive-schema`), 서브에이전트는 deny.
- 상대 경로는 세션 cwd와 명령 안 `cd`·`pushd`가 닿을 수 있는 모든 디렉터리(돌지 않았을 수 있는 `cd` 포함)에서 판정하고, 경로에 마이그레이션 디렉터리가 드러나지 않아도 cwd 기준으로 본다(`cd migrations && echo x > 0001_initial.py`).
  - 따라갈 수 없는 이동(`eval`·`source`, `cd -`·변수 경로, `z`·`zoxide`, `HOME=…` 변경, `$c app`처럼 `$`로 시작하는 명령 단어, 명령 안 `CDPATH=`·zsh `cdpath=(…)`) 뒤의 상대 경로와 글롭·중괄호·변수가 든 경로는 이미 있는 파일로 본다.
  - 셸 문자열(`sh -c` 등) 안의 `cd`는 뒤 명령의 cwd로 따라가지 않는다(예외는 [limitations.md](limitations.md) 5.2절).
  - 판정은 저장소 루트 기준 경로라 저장소를 `…/goose/` 같은 디렉터리 아래에 클론해도 모든 쓰기가 걸리지는 않는다(Edit·Write도 세션 cwd 아래 파일은 같다).
  - 세션 cwd가 `migrations/` 안이면 상대 경로(`sed -i … 0001_initial.py`, Edit의 `0001_initial.py`)도 본다.
- `ssh`·컨테이너(`docker`·`podman`·`nerdctl` `exec|run`, `docker compose exec|run`, `kubectl exec`) 안의 쓰기와 `scp`·`rsync`·`docker cp`·`docker compose cp`·`kubectl cp`의 원격 목적지(`host:경로`·`컨테이너:경로`)는 이미 있는 파일로 본다(ask-high).
  - `--entrypoint sh img -c '…'`처럼 공용 파서가 벗기지 못한 컨테이너 셸도 찾는다.
  - git 작업 트리(`--work-tree`·`-c core.worktree=`·명령 안 `GIT_WORK_TREE=`)는 따라가거나 이미 있는 파일로 보고, 따옴표로 나뉜 이름·도구 단어(`mig"rations"/…`, `alem"bic" upgrade`)도 본다(64 KB 이하 명령).
- 도구(`alembic`·`flask db`·`goose`·`dbmate`·`migrate`(golang-migrate)·`flyway`·`liquibase`·`knex`·`artisan` 등)는 도구 이름 뒤 첫 하위 명령으로 판단하므로 사이에 옵션·위치 인수가 와도 된다(`goose -dir db/migrations postgres "$DATABASE_URL" up`, `alembic -c alembic.ini upgrade head`).
  - 도구 이름은 명령의 어느 단어든 되고 뒤에 나온 것을 먼저 본다(`docker run --name goose flyway/flyway migrate`, `pnpm run db:goose up`).
  - `status`·`version`·`current`·`history` 같은 조회는 통과한다.
  - 미리 보기를 DB 클라이언트로 넘기는 판정에는 `sh -c`·`ssh`·`eval` 중간 단계, `( … ) | psql`·`{ …; } | psql`, `psql -c "$(…)"`·`psql < <(…)`도 들어간다.
- 큰 명령은 비용 상한이 있다: 마이그레이션 이름·명령 어휘가 없는 세그먼트는 건너뛰고, 상대 경로 대조 2048회·awk 호출 150회·미리 보기 파이프 판정 64회(64 KB)를 넘으면 남은 부분을 이미 있는 마이그레이션 수정(미리 보기는 파이프)으로 본다.
  - 10초 제한을 넘겨 판정 없이 통과하지 않게 하려는 것이다.

마이그레이션 경로와 제외:

- 마이그레이션 경로로 보는 디렉터리: `migrations/` `migration/` `alembic/versions/` `db/migrate/` `db/migrations/` `prisma/migrations/` `supabase/migrations/` `drizzle/` `knex/migrations/` `sequelize/migrations/` `typeorm/migrations/` `flyway/` `liquibase/` `sql/migrations/` `atlas/migrations/` `goose/` `dbmate/`.
- `__init__.py`·`env.py`·`script.py.mako`·`alembic.ini`·`README*`·`*.md`·lock 파일(`*.lock`·`migration_lock.toml`)과 `__pycache__/` 아래 파일·`*.pyc`·`*.pyo`는 제외한다.
- `migrations/__pycache__/../0001_initial.py`처럼 `..`로 빠져나오는 경로에는 이 제외를 적용하지 않는다.

## 8. 알림 훅: `stop-verify` · `subagent-scope`

두 훅은 아무것도 막지 않는다. 세션 기록(JSONL)의 도구 호출을 읽어 규칙에 어긋나 보이는 상황을 알리기만 한다. 한계는 [limitations.md](limitations.md) 6절에 있다.

### 8.1 `stop-verify` (Stop)

`rules/core.md`의 "검증한 것만 완료로 보고"를 돕는다. 아래가 모두 맞을 때 알린다.

- 이번 턴(마지막 사용자 입력 뒤)에 Edit·Write·MultiEdit·NotebookEdit로 파일을 고쳤다.
- 마지막 수정 뒤에 검증 명령을 Bash로 실행하지 않았다.
- 마지막 응답에 `미검증`·`검증하지 …`·`테스트하지 …`·`미실행`·`not run`·`unverified` 같은 표기가 없다.

세부:

- 세지 않는 수정: 문서(`.md` `.mdx` `.txt` `.rst` `.adoc`), `.claude/` 아래 파일, 세션 작업 디렉터리 밖의 임시 디렉터리(`/tmp` `/var/folders` 등) 파일.
- 검증 명령은 이름으로 가린다.
  - 도구: `pytest` `ruff` `mypy` `pyright` `tsc` `eslint` `jest` `vitest` `shellcheck` 등
  - 러너와 동사: `npm run test:unit`, `make check`, `go vet`, `cargo build`, `manage.py test`, `terraform validate`
  - 검사 스크립트: `bash tests/run-all.sh`, `./scripts/test.sh`
  - 문법 검사: `bash -n`, `node --check`
  - 프로젝트 고유 명령은 `CLAUDE_STOP_VERIFY_EXTRA`(ERE, 소문자로 바꾼 명령에 대조)로 더한다.
- 기본은 사용자에게 경고(`systemMessage`)만 하고 턴은 그대로 끝난다. 예: `검증 없이 완료 보고 [stop:unverified]: 이번 턴에 파일 2개를 수정했지만(app.py, views.py) …`.
- `CLAUDE_STOP_VERIFY=remind`면 Claude에게 되돌려(`additionalContext`) 검증하거나 `미검증`으로 고쳐 쓰게 한다. 한 번만 되돌린다(`stop_hook_active`면 통과).

### 8.2 `subagent-scope` (SubagentStop)

`rules/subagent-policy.md`의 "한 파일은 한 에이전트만 수정한다"를 돕는다. 서브에이전트 기록의 첫 입력(위임 프롬프트)에서 '소유 파일' 선언을 읽고, 그 서브에이전트의 Edit·Write·MultiEdit·NotebookEdit 대상과 대조한다.

- 선언 형식은 `/delegate` 템플릿 그대로다: `소유 파일(수정 허용) src/api/views.py, tests/test_views.py / 수정 금지 …`. 다음 줄부터의 목록(`- src/a.py`)과 `owned files:`도 읽는다.
- 항목은 파일, 디렉터리(아래 전부), 글롭(`tests/*.py`)이다. 공백이 든 경로는 백틱으로 감싼다. `없음`이면 모든 수정이 범위 밖이다.
- 선언이 없으면 검사하지 않는다. `implementer`(플러그인으로 설치한 `dev-settings:implementer` 포함)가 선언 없이 파일을 고쳤을 때만 `[subagent:no-scope]`로 알린다.
- 세션 작업 디렉터리 밖의 임시 디렉터리 파일은 세지 않는다.
- 에이전트 memory 디렉터리(`.claude/agent-memory/`·`.claude/agent-memory-local/`, 홈의 `~/.claude/agent-memory/` 포함)의 파일도 세지 않는다. `memory`를 켠 에이전트가 자기 기록을 쓰는 곳이다([components.md](components.md) 2.1절).
- 기본은 사용자에게 경고만 한다. 예: `소유 파일 밖 수정 [subagent:out-of-scope]: implementer가 … 수정했다: src/settings.py (소유 파일: src/api/views.py)`.
- `CLAUDE_SUBAGENT_SCOPE=remind`면 서브에이전트에게 되돌려 보고의 '범위 밖 필요·발견'에 적게 한다. 되돌리기나 추가 수정은 시키지 않는다.

## 9. 공통 스위치와 로그

- `CLAUDE_HOOKS_DISABLE=1` — 런처를 거치는 모든 훅을 즉시 통과(전역 킬 스위치, 상태줄 제외).
- `CLAUDE_HOOKS_LOG=<파일>` — 결정 로그. 한 줄 형식: `날짜<TAB>훅<TAB>결정<TAB>규칙<TAB>사유(명령 발췌 포함, 200바이트 이하)`. `auto`·`bypassPermissions`에서 넘긴 ask-low는 결정 `allow`, 사유 `silenced(<모드>): …`로 남는다.
- `CLAUDE_HOOKS_DEBUG=1` — 디버그 메시지를 stderr로 출력.
- 훅별 끄기 스위치(`CLAUDE_GUARD_SECRETS`·`CLAUDE_GUARD_DESTRUCTIVE`·`CLAUDE_GUARD_MIGRATIONS`, `CLAUDE_SESSION_CONTEXT`, `CLAUDE_FORMAT_ON_EDIT`)는 `off` `0` `false` `no`(대소문자 무관)를 인식한다. `CLAUDE_HOOKS_DISABLE`은 `1`만, `CLAUDE_STATUSLINE_COLOR`는 `0`만 인식한다.
