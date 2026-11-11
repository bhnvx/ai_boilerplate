# 샌드박스 규칙

이 프로젝트는 Bash 명령을 OS 샌드박스 안에서 실행한다(`.claude/settings.json`의 `sandbox`).

## 경계
- 쓰기: 프로젝트 디렉터리와 임시 디렉터리만 된다. 그 밖에 쓰는 명령은 실패한다.
- 읽기: SSH·클라우드·쿠버네티스·GPG·도커 자격 증명 경로와 Read deny 규칙의 경로는 읽지 못한다.
- 네트워크: 허용된 도메인만 된다. 처음 접속하는 도메인은 사용자 승인이 필요하다.
- 샌드박스는 Bash와 그 자식 프로세스에만 적용된다. Read·Edit·Write 도구는 권한 규칙을 따른다.

## 샌드박스 때문에 실패했을 때
- 실패한 명령과 오류 원문(`Operation not permitted`, 연결 거부 등)을 그대로 보고한다.
- 샌드박스 밖 재실행(`dangerouslyDisableSandbox`)은 그 명령이 꼭 필요할 때만 요청하고 이유를 함께 말한다. 사용자 승인 프롬프트가 뜬다.
- 같은 목적을 다른 명령·경로·인코딩으로 우회하지 않는다.
- 경계를 넓히는 설정(`sandbox.excludedCommands`, `sandbox.filesystem.allowWrite`·`allowRead`, `sandbox.network.allowedDomains`)은 직접 고치지 않는다. 필요한 항목과 이유를 사용자에게 제안한다.

## 샌드박스와 맞지 않을 수 있는 도구
- docker, SSH 원격을 쓰는 git, `gh`·`gcloud`·`terraform` 같은 Go CLI(macOS), watchman은 샌드박스 안에서 실패할 수 있다.
- 이런 명령이 필요하면 사용자에게 알리고 `sandbox.excludedCommands` 추가를 제안한다.
