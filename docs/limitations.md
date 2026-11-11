# 알려진 제한

[← README](../README.md)

현재 동작 기준이다. 훅의 판정 규칙은 [hooks.md](hooks.md)에 있다.

## 1. 훅과 권한 규칙은 보안 경계가 아니다

- **Bash 권한 규칙과 훅은 보안 경계가 아니다.** 네이티브 `Bash(...)` 접두사 규칙은 `/bin/rm`, `bash -c '…'`, `git -C . push`로 우회된다.
- 가드 훅은 이를 보완하는 휴리스틱 파서(따옴표·heredoc·셸 문자열을 정해진 깊이까지만 푼다)라 변수 조합·스크립트 내부·인코딩으로 우회할 수 있다.
- 확실한 경계가 필요하면 sandbox를 쓴다.
- **fail-open**: 파서(`jq`/`python3`)가 없거나 훅이 실패하면 통과한다.
  - 핸들러에 `"onFailure": "block"`(2.1.295+)을 추가하면 런처를 시작하지 못할 때, 훅이 timeout(10초)을 넘길 때, 출력 JSON이 깨졌을 때 도구 호출이 막힌다.
  - 런처가 항상 exit 0이므로 훅 내부 오류는 여전히 통과하고, `jq`/`python3`가 없을 때도 결정 없이 통과(fail-open)한다.
- PreToolUse 훅은 `@파일` 멘션과 IDE 컨텍스트(열린 파일·선택 영역)에는 실행되지 않는다. 이 경로에는 Read deny만 적용된다(best-effort).
- Read deny는 `cat`·`head`·`tail`·`sed`·리디렉션 등 Claude Code가 인식하는 Bash 명령에만 적용된다. `grep -r`이나 스크립트 내부 읽기는 `guard-secrets`가 일부만 잡는다.
- Read deny가 Write·Edit도 막으므로 Claude가 `.env`를 직접 만들 수 없다. `cp .env.example .env`(확인 후 실행)를 쓰거나 사용자가 만든다.

## 2. 공용 파서

### 2.1 안쪽 명령을 따로 보지 않는 형태

- 공용 파서가 안쪽 명령을 따로 보지 않는 형태:
  - 옵션 표에 없는 옵션·따옴표 없는 `$OPTS`가 든 컨테이너 명령
  - `podman-compose`·`podman compose`·`nerdctl compose`
  - 그 밖의 원격 실행기(`lxc exec`·`multipass exec`·`limactl shell`·`vagrant ssh -c`)
  - 벗기지 않는 래퍼(`gosu`·`su-exec`·`tini`·`dumb-init`·`xvfb-run`·`direnv exec`·`asdf exec`·`aws-vault exec`·`op run`·`nix develop -c`·`nix-shell --run`·`conda run`·`micromamba run`·`parallel`·`tmux`·`screen`)
  - `docker exec`·`docker compose exec|run`·`kubectl exec` 안에서 접두(`gosu` 등) 뒤에 오는 `sh -c`
  - `docker compose run|exec --entrypoint sh 서비스 -c '…'`의 문자열(`guard-migrations`만 찾는다)
  - `npx -c`·`npm exec -c`·`fd -x <셸> -c` 문자열
  - `env "A=1" 명령`
  - 셸 이름 `ash`·`$SHELL`
  - 스크립트를 쓴 뒤 실행(`cat > i.sh <<EOF … EOF` 후 `bash i.sh`)
- 셸이 heredoc 본문을 읽는지 가리지 못하는 다음 형태의 본문은 데이터로 본다: 본문 다음 줄에서 이어지는 파이프(`cat <<EOF |` … `EOF` 다음 줄의 `bash`), 묶음을 거치는 파이프(`(cat <<EOF) | bash`·`{ cat <<EOF; } | bash`·`cat <<EOF | (bash)`), 표준 입력을 스크립트로 실행하는 `-c` 문자열(`bash -c "$(cat)" <<EOF`·`sh -c 'sh' <<EOF`), 원격·권한 쪽 셸이 표준 입력을 읽는 `ssh host bash -s <<EOF`·`sudo -s|-i <<EOF`, `{ bash; } <<EOF`.
- 셸에 here-string으로 넘긴 명령(`bash <<< 'rm -rf /'`)도 펼치지 않는다(`bash <<< "$(curl …)"`의 pipe-to-shell만 본다).
- `source /dev/stdin <<EOF` 본문은 같은 셸에서 돌지만 자식 셸처럼 격리하므로 본문 안의 `cd`가 뒤 명령에 이어지지 않는다.

### 2.2 래퍼·이스케이프·큰 명령

- 래퍼·런타임 줄을 그대로 두므로 앞 세그먼트를 보는 규칙은 래퍼를 건너뛰지 않고(`echo / | caffeinate -i xargs rm -rf`는 ask-low, 래퍼 없이는 deny), 런타임·래퍼 뒤의 SQL heredoc(`podman exec -i db psql <<EOF`)은 SQL로 검사하지 않는다(셸 본문은 검사한다).
- `$'…'` 안의 이스케이프는 풀지 않으므로 `sh -c $'echo a\ngit push …'`의 `\n`은 줄바꿈이 아니다.
- 상한 근처의 큰 명령(셸 문자열 200개, 세그먼트 수천 개, `cd`·`pushd` 수천 개)은 macOS `/bin/bash` 3.2에서 훅마다 약 1~5초가 걸린다(부하 약 2).
- 작업 시간 상한(약 6초)은 세그먼트·토큰 사이에서만 확인하므로 한 번에 하는 큰 단계(1 MB 가까운 명령의 파싱·토큰화, 수만 자 문자열의 bash 글롭 비교, gawk 5.4에서 탭이 수만 개인 heredoc 본문의 공백 정리)는 멈추지 못한다: 단어 2만여 개인 1 MB 명령은 약 6.5초(부하 약 2), 부하 7~9에서 7~9초가 걸리고, 부하가 더 높으면 10초 제한을 넘겨 판정 없이 통과할 수 있다.
- 제한 안에 끝나도 앞 세그먼트(`cat .env; echo …`의 `cat .env`)를 판정하지 못해 `too-complex`(메인 ask-high)다.

### 2.3 작업 상한을 다 쓰는 명령

- 작업 상한([hooks.md](hooks.md) 4.6절)을 다 쓰는 셸 문자열 안의 문자열·셸이 읽는 본문·본문 치환 뒤의 위험 명령은 메인에서 deny가 아니라 `too-complex`(ask-high)다(`sh -c 'sh -c "true; …(2000개)"'; cat .env`, 짧은 명령 2000줄인 `bash <<'EOF'` 본문 다음 줄의 `rm -rf /`).
- 따옴표 없는 heredoc 본문(커밋·PR 본문)은 셸이 펼치는 대로 본다: `$(…)`·백틱 코드 스팬이 200개를 넘으면 무해해도 `too-complex`이고, 닫히지 않은 백틱 뒤 글(셸은 본문 전체를 거부한다)과 `cat <<EOF | sed … | sh`처럼 중간 단계가 고쳐 쓰는 본문도 명령으로 판정한다.
- 산문 본문은 `<<'EOF'`로 쓴다.

## 3. `guard-secrets`

- `guard-secrets`: 코드가 `.env`를 문자열로만 언급해도 deny다(`python3 -c "print('.env' in open('.gitignore').read())"`, `python3 - <<EOF` 본문).
- 이름에 secret·password 등이 든 파일은 내용과 무관하게 soft 단계 ask다(Django `password_reset_subject.txt` 템플릿 포함).
- `curl -H 'X-Api-Key: …'` 헤더 값도 ask다.
- 이름에 token만 든 파일(`token.txt`)은 soft가 아니다(`tokenizer.json`·`design-tokens.json` 오탐 회피, `*.token`·`token.json`은 hard).
- `find`·`fd -exec`로 따로 판정하는 프로그램은 따옴표를 뗀 단어로 보므로 `find . -exec echo '$GITHUB_TOKEN' \;`도 ask-high다.
- `docker inspect`는 `Env`로 걸러 출력할 때만 ask이고, `while read …; done < .env`와 `gawk`·`mawk`·`gsed`의 비밀 인수는 deny가 아닌 ask-high다.
- 이름과 출력이 다른 세그먼트·문자열로 나뉜 `find -name .env -print0 | xargs -0 cat`·`find -name .env -exec sh -c 'cat "$1"' _ {} \;`은 잇지 않고, `-exec` 안의 래퍼(`-exec sudo cat .env \;`)는 머리를 벗기지 않아 deny가 아니라 ask-high이며, zsh `>>&` 뒤의 대상(`echo x >>& .env`)은 쓰기로 보지 않는다.
- Bash 사전 필터는 소문자 명령 문자열에서 키워드·패턴을 찾으므로 따옴표·백슬래시로 쪼갠 이름(`cat .e"nv"`)은 통과한다.

## 4. `guard-destructive`

- `guard-destructive`: SQL 문자열 리터럴 안의 키워드도 ask-high다(`psql -c "SELECT … ILIKE '%drop table%'"`).
- `runuser`·`chroot`·`unshare`·`systemd-run` 자체는 `sudo`처럼 권한 확인을 하지 않고 안쪽 명령만 판정한다.
- 전체 텍스트 검사(fork bomb `:(){ :|:& };:`, 블록 디바이스 리디렉션)는 커밋 메시지·heredoc 본문까지 보므로 그 문구가 든 커밋도 deny다.
- 태그만 푸시(`git push --tags`)는 릴리스 CI를 시작할 수 있어도 확인하지 않는다.
- `rm -rf node_modules package-lock.json`은 일반 파일이 섞여 ask-low다.
- 서브셸 `( … )`·셸이 읽는 heredoc 본문 안 `git checkout`의 브랜치 가정은 바깥으로 이어지지 않는다.
- find -exec 위치 매개변수는 `-name` 같은 거름 조건을 평가하지 않아 `find /tmp -name 'build-*' -exec sh -c 'rm -rf "$1"' _ {} \;`도 deny이고, 시작 디렉터리를 `/.`처럼 `.`으로 끝나게 쓰면 깊이 0을 판단하지 않아 ask-high다.
- `-exec /usr/bin/env sh -c`·`-exec sudo sh -c`·`-exec command sh -c`는 셸 문자열로 보지 않는다.
- `find -exec`·`fd -x`가 실행하는 프로그램은 `rm`과 파서가 펼친 셸 `-c` 문자열만 보므로 `fd -x rm -rf /`·`find . -exec git push --force origin main \;`는 통과하고 `find . -exec rm -rf / \;`도 ask-high다.
- 셸 문자열·셸이 읽는 본문 안의 대입은 보지 않아 `sh -c 'HUSKY=0 git commit -m x'`는 훅 우회 확인이 없다.

### 4.1 pipe-to-shell

- pipe-to-shell은 파서가 `|`와 `;`·`&&`를 구분하지 않아 근사한다: `curl …; bash -s`·`curl … && bash`·`curl … | xargs bash`도 ask-high다.
- 코드 안에서 표준 입력을 읽는 형태(`python3 -c "exec(sys.stdin.read())"`), `sudo -i`·`su`로 넘기는 표준 입력, 목록 밖 인터프리터(`php`·`deno`·`bun`), 다른 fd를 거치는 형태(`bash /dev/fd/3 3<&0`), 셸이 읽는 본문의 출력을 다시 셸로 넘기는 `bash <<'EOF' | sh`는 잡지 않는다.
- 본문 치환의 실행 여부는 그 줄의 마지막 명령으로 가린다(`cat > f <<EOF; bash x.sh` 본문의 `$(curl …)`도 ask-high, `bash <<EOF; echo done`의 것은 놓친다).
- SQL 미리 보기를 DB 클라이언트로 넘겼는지도 세그먼트 순서로 어림하므로 관계없는 DB 클라이언트가 뒤에 와도 ask-high이고, 미리 보기가 서브셸 안에 있거나 클라이언트가 셸 문자열 안에 있으면(`( alembic downgrade -1 --sql ) | psql`, `… --sql | sh -c 'psql'`) 메인의 롤백 ask-high가 없다(서브에이전트는 `guard-migrations`가 deny).
- DB 클라이언트 heredoc의 본문 치환(`psql <<EOF` … `$(alembic downgrade base --sql)`)은 서브에이전트도 판정이 없다.

### 4.2 deploy-runner

- deploy-runner는 이름만 본다: 경계 없이 붙은 단어(`predeploy`)는 통과하고, 경계로 나뉜 배포 단어는 읽기 작업이어도 ask-high다(`generate-release-notes.js`).
- TypeScript 러너(`tsx`·`ts-node`·`deno run`·`bun <경로>`), `source <스크립트>`, `python -m <패키지.deploy>`, PATH의 `deploy.sh`, 대소문자가 다른 이름(`Deploy.sh`)은 보지 않는다.
- golang-migrate `goto <버전>`은 버전을 비교하지 않아 롤백이어도 적용(ask-low)으로 본다.

## 5. `guard-migrations`

### 5.1 보지 않는 쓰기

- `guard-migrations`가 보지 않는 쓰기:
  - 패치 내용이 파일을 정하는 `patch -p1 < x.diff`
  - `git apply`·`git stash pop`·`git reset --hard`
  - `curl -O`·`-D`·`-c`
  - `wget -o`
  - `ln -sf`
  - 압축 해제
  - 스크립트(`python -c …`)가 쓰는 파일
  - 환경으로 내보낸 `CDPATH`·`GIT_WORK_TREE`
  - 위치를 모르는 cwd 변경 뒤 경로에 마이그레이션 디렉터리가 드러나지 않는 쓰기(`cd "$DIR"; echo x > 0001_initial.py`)
  - 이름이 `migrations`인 저장소 루트 파일을 Bash에서 상대 경로로 고치는 것(Edit·Write와 절대 경로는 잡힌다)
  - 따옴표 친 비머리 동사(`python manage.py "migrate"`)
  - 미리 보기가 따옴표 셸 문자열 안에 있거나(`sh -c 'liquibase update-sql' | psql`) DB 클라이언트가 묶음 안에 있거나(`| (cd /tmp && psql)`) 명령이 여럿인 묶음에서 나오거나(`{ liquibase update-sql; echo; } | psql`) 변수·파일을 거치는 형태(`SQL=$(…); psql -c "$SQL"`, `> x.sql && psql -f x.sql`)

### 5.2 보수적으로 묻는 경우

- `guard-migrations`가 보수적으로 묻는 경우:
  - `source` 뒤 상대 경로로 만드는 새 마이그레이션
  - 같은 명령에 `ssh`·`docker exec`가 글자로만 있어도 로컬에 새로 만드는 마이그레이션
  - `&&`를 구분하지 않는 돌지 않은 `cd` 후보(세션 cwd `db/`에서 `cd /tmp/x && cd migrate && echo x > notes.txt`)
  - 셸 문자열·서브셸 안에서 마이그레이션 디렉터리로 들어간 `cd` 뒤 바깥의 상대 경로(`sh -c 'cd migrations'; echo x > 0009_new.py`는 서브에이전트 deny)
- git 저장소가 아닌 곳에서는 도구 이름의 상위 디렉터리(`…/goose/`) 때문에 모든 편집이 마이그레이션으로 잡힐 수 있다.

## 6. 알림 훅(`stop-verify` · `subagent-scope`)

- 두 훅은 Edit·Write·MultiEdit·NotebookEdit 호출만 본다. Bash로 고친 파일(`sed -i`, 리디렉션, `git checkout`)은 보지 못한다. 서브에이전트 통합 때의 `git status`·`git diff` 확인을 대신하지 않는다.
- 세션 기록(JSONL) 형식은 공식 문서에 없다(2.1.318 실측). 형식이 바뀌면 두 훅은 아무것도 알리지 않는다.
- 기록은 비동기로 쓰여 가장 최근 도구 호출이 빠져 있을 수 있다(공식 문서). 그때는 검증을 실행했는데도 `stop-verify` 알림이 뜰 수 있다.
- `stop-verify`의 검증 명령 판별은 이름 기준 어림이다. `grep pytest`·`sh -c 'cat tests/x'`도 검증으로 세고, 목록에 없는 프로젝트 고유 명령은 놓친다(`CLAUDE_STOP_VERIFY_EXTRA`로 더한다). 실패한 검증도 실행으로 센다.
- `stop-verify`는 세션 기록의 끝 4 MB만 읽는다. 한 턴의 도구 출력이 그보다 크면 앞쪽 수정은 세지 않는다.
- `subagent-scope`는 선언의 중괄호 글롭(`{a,b}`)을 펼치지 않고 `..`가 든 경로를 정규화하지 않는다.
- Stop 훅은 사용자가 중단한 턴에는 실행되지 않는다(공식 문서).

## 7. 설치·설정·환경

- `install.sh --force`가 다시 넣지 못한 항목(저장소가 더 이상 넣지 않는 항목, 다른 permission 목록과 충돌한 항목)의 삭제 기억은 `--force`가 매니페스트를 다시 쓸 때 지워진다. 그 뒤 충돌을 풀거나 저장소가 다시 넣으면 다음 설치가 그 항목을 넣는다.
- `statusLine`은 CLI와 VS Code 통합 터미널에서 확인했다. VS Code 확장 채팅 패널에서 표시되는지는 공식 문서(statusline·vs-code 페이지)에 나오지 않는다(미검증).
- 사용자(전역) 규칙과 프로젝트 규칙이 충돌하면 Claude가 어느 쪽을 따를지 보장되지 않는다. 프로젝트 `CLAUDE.md`에 명시적으로 적는다.
- 스키마 스냅샷에 문서화된 키 일부(`modelSettings` 등 약 48개)가 없다. 스키마가 `additionalProperties: true`라 오류는 아니며, `validate.sh`는 알려진 키를 예외로 두고 나머지를 WARN으로 알린다.
- `--link`(심볼릭 링크 설치) 모드는 없다. 저장소를 고친 뒤 `./install.sh`를 다시 실행한다.
- Windows는 검증하지 않았다.
