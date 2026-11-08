#!/usr/bin/env bash
# lib/shellparse.sh — 셸 명령 경량 파서 (POSIX awk 1개; macOS BWK awk / gawk / mawk 공통, gawk 확장 없음)
# API (모두 awk 1회 fork):
#   sp_segments "<command>"    → 줄마다 KIND<TAB>MASKED<TAB>RAW
#       KIND: cmd | cmd+sudo | cmd+xargs | cmd+sudo+xargs | sub | heredoc | assign | envfile | push | pop | overflow  (case 는 cmd* 로 받을 것)
#       overflow 줄(MASKED·RAW 비어 있음)은 낸 줄 수가 작업 상한(기본 5000, 테스트는 SP_WBMAX)을 넘었다는 뜻이고 맨 끝에 한 번만 온다(P-B 치환 상한도 — 아래).
#       상한은 내는 줄을 모두 센다(레코드, 치환·서브셸의 push/pop 두 줄은 push 때, env -S 묶음 세 줄). 넘으면 입력을 더 읽지 않고, 읽은
#       부분은 입력이 거기서 끝난 것처럼 마무리해 낸다(열린 치환·서브셸 안에 모인 줄과 그 바깥 세그먼트, 미룬 묶음, env -S 묶음, 그 줄의
#       heredoc — 마무리에서 새로 생기는 줄은 64줄까지, push/pop 짝은 맞춘다). 소비자는 받은 줄을 모두 판정하고, 명령을 다 분석하지
#       못한 것으로 처리한다(R4·R5).
#       R5: 호출 하나의 단어가 24000개를 넘거나 단어 하나의 조각(이스케이프·따옴표·$)이 8192개를 넘어도 같은 식으로 멈추고 overflow 다(BWK awk 의 문자열 잇기가 제곱 비용).
#       assign 줄은 같은 세그먼트의 선두 대입(HUSKY=0 등)을 담고 cmd 줄 바로 앞에 온다.
#       envfile 줄은 벗겨 낸 러너 접두(uv run / docker compose run|exec …)의 --env-file 값으로, cmd 줄 바로 앞에 온다(G3).
#       sub 줄은 sh -c / eval / ssh / su -c 의 내부 문자열(따옴표 1단계 제거)로 cmd 줄 뒤에 온다(깊이 1). 문자열 안의 개행은 RAW 에서
#       0x1E, 탭은 0x1F 로 바꿔 담고 MASKED 에서는 공백이다(R4·R6) — RAW 를 sp_segments 로 다시 파싱하면 0x1E 가 줄로, 0x1F 가 탭으로 되살아나
#       줄마다 명령·heredoc(<<- 탭 종료 토큰 포함)·주석·줄 잇기가 최상위처럼 동작하고, 단어·토큰 함수(sp_tokens* · sp_words)는 0x1E·0x1F 를
#       공백처럼 나눈다. 명령에 든 리터럴 0x1E·0x1F 는 가드가 넘기기 전 보통 글자 0x1D 로 바꾸므로(lib/common.sh) 최상위에서 개행·탭 구실을 하지 않는다.
#       env SP_SUBFLAT=1 이면 sub RAW 가 R4 이전처럼 평탄하다(개행·탭·CR 모두 공백 = flat). 미설정·다른 값은 위의 0x1E/0x1F 인코딩(P-D).
#       가드는 가장 깊은 전개 수준에서 한 세그먼트로 둘 문자열을 파싱할 때만 켜서 [[:space:]] 정규식이 그대로 맞게 한다.
#       셸 이름은 경로·대소문자와 무관하고(/opt/homebrew/opt/bash/bin/bash · DASH), 문자열은 -c 뒤 옵션(-x -e +x -o 이름 -- -)을
#       건너뛴 첫 인수다(POSIX sh -c [옵션] 문자열). 따옴표·역슬래시 친 옵션("-c" '-n' \-exec "-S")도 옵션으로 본다.
#       셸 문자열 실행기 find -exec|-execdir|-ok|-okdir <셸> -c · watch(인수 전체를 sh -c 로 실행) · env -S|--split-string ·
#       podman exec|run … <셸> -c · nsenter … <셸> -c 의 문자열도 sub 줄로 내되 push … pop 으로 감싼다(안의 cd 가 밖에 새지 않게).
#       이때 원래 cmd 줄은 바꾸지 않고 줄을 더하기만 한다(B): 묶음 뒤에 그 cmd 줄을 한 번 더 내서 다음 세그먼트의 이웃
#       (echo … | xargs rm, … | tee 새 마이그레이션 등 앞 세그먼트를 보는 규칙)이 그대로다. env -S 는 env 를 벗긴 cmd 줄의
#       머리가 임의 명령이라 묶음을 출력 맨 끝에 둔다.
#       heredoc 줄: MASKED=<heredoc>, RAW=본문(개행→공백, 1MB 에서 절단). << 를 가진 줄의 마지막 세그먼트 뒤에 온다.
#       R6 heredoc 본문 그룹(heredoc 줄 뒤, 같은 heredoc 의 것은 P-C 가 P-B 앞):
#        P-C 본문을 셸이 스크립트로 읽으면(소유 세그먼트의 머리가 셸(isshell)이고 -c 문자열이 없으며 -s 이거나 피연산자가 없거나 /dev/stdin 류;
#         -- · - 뒤 첫 인수는 스크립트 파일, 긴 옵션은 --rcfile·--init-file 만 값을 받고, -n·-o noexec 는 실행하지 않는다; source/. 가 /dev/stdin 류;
#         ssh/su 가 명령 없음; 또는 소유 세그먼트가 같은 깊이의 파이프라인에서 그런 셸로 이어짐 — cat <<EOF | bash) push/sub/pop 을 낸다.
#         이 묶음의 push 줄은 MASKED·RAW 가 << 다(push\t<<\t<< — 명령 치환 묶음과 달리 본문 명령의 출력을 앞 명령이 실행하지 않는다).
#         sub RAW 는 inner 셸이 보는 본문(줄 유지, <<- 는 논리 줄마다 선두 탭 제거, 따옴표 없는 구분자는 바깥 셸의 따옴표 제거 1회).
#         소유권은 heredoc 마다(그 << 를 가진 세그먼트와 그 파이프라인; '줄의 마지막 세그먼트'가 아니다). 서브셸 ( … )·$( … )·백틱 안의 heredoc 도
#         그 깊이에서 같다(P-B 도). 세그먼트 순번은 깊이마다 줄을 넘어 늘기만 한다. MASKED 는 평탄 본문 앞 8192자(maskstr 제곱 비용).
#        P-B 구분자에 따옴표·역슬래시가 없으면 본문의 치환($(…)·`…`; \$(·\` 는 리터럴)을 각각 push/sub/pop 으로 낸다(최상위 $() 처럼 재파싱).
#         본문의 << 는 안의 치환 안에서 재귀 heredoc 으로 읽지 않고 리디렉션 단어로 둔다. 치환 없는 본문은 줄마다 index() 검사만(추가 비용 없음).
#         치환이 상한(내부 64 KB·본문당 4096개)을 넘으면 잘라 내고 overflow 를 맨 끝에 내되 입력은 계속 읽는다(R7: 뒤 명령도 낸다).
#        따옴표 없는 구분자는 줄 끝 \(홀수 개)로 이은 줄을 한 줄로 구분자와 견주고(셸과 같다), <<- 의 탭 제거도 논리 줄 머리에서만이다(R7).
#        본문이 1MB heredoc 상한에 걸리면 잘린 본문으로 그룹을 낸다(가드 상한이 96KB 넘는 본문에 too-complex 바닥을 준다).
#       push/pop 줄은 서브셸 ( … ) 과 명령 치환 $( … ) · `…` · <( … ) 의 경계다(G10). 명령 치환은 부모 세그먼트를
#       끊지 않고 그 자리에 자리표시 단어 $(…) 를 남기며, 내부 명령은 부모 줄 뒤에 push … pop 으로 이어 나온다(G1).
#       kubectl exec 는 원본 세그먼트와 내부 명령 세그먼트를 둘 다 cmd 로 낸다.
#       라운드 3(B 묶음): 컨테이너 런타임(docker run·docker container exec|run·podman·nerdctl [container] exec|run·docker-compose
#       exec|run)과 접두 래퍼(flock 파일·mise exec|x … --·caffeinate·chrt·ionice·taskset·setsid·unbuffer·chroot 새루트·script(BSD) 파일·
#       unshare·systemd-run·runuser -u)는 그 cmd 줄을 그대로 낸 뒤 push · 벗긴 안쪽 명령(sh -c 면 sub 줄도) · pop · 같은 cmd 줄을 더한다.
#       런타임 줄을 보는 규칙과 앞뒤 세그먼트의 이웃은 그대로이고, 안쪽 cd 는 밖에 새지 않는다. --entrypoint X 는 안쪽 명령의 머리다.
#       옵션 표(SP_R3_TBL)에 없는 옵션·따옴표 없는 $변수·명령이 없는 형태는 벗기지 않는다(라운드 2 출력 그대로). 묶음은 한 겹만 만들고
#       안쪽의 래퍼·런타임은 그냥 벗긴다. docker exec·docker compose run|exec·kubectl exec 의 모양은 바뀌지 않는다.
#       flock 파일 -c · mise exec -c · script -c · runuser -c · su -lc/--command 의 문자열은 실행기 묶음(push/sub/pop)으로 낸다.
#       머리 단어는 따옴표·역슬래시를 벗긴 RAW 기준이며, 위험 명령·출력 명령 이름은 소문자로 정규화한다(G7; macOS 는 대소문자 무시).
#   sp_tokens "<raw>"          → 줄마다 토큰(따옴표 제거, KEY=VALUE → KEY= 와 VALUE, 선두 @ 제거, host:path → path 도 추가;
#                                 따옴표 밖의 < > 에서 단어를 끊되 2> &> >> << <<< >& 는 다음 단어의 접두로 둔다; G15).
#                                 fd 번호·연산자로만 된 앞부분은 한 연산자 단어다(2>> 2>&1 &>> >| 1>|; A). >| 는 파이프가 아니다.
#   sp_tokens_lines "<text>" [keep-empty]
#                              → 입력 줄마다 그 줄의 토큰들 뒤에 __SP_SEG__ 한 줄(따옴표 상태가 줄을 넘지 않음; C1).
#                                keep-empty(guard-secrets 전용 옵트인)면 빈 따옴표 인수('' "" $'')와 빈 KEY= 값 자리에
#                                __SP_EMPTY__ 를 낸다(grep '' .env 의 빈 패턴이 사라지지 않게; F15). 없으면 기존 출력 그대로.
#   sp_words "<raw>"           → 줄마다 단어(따옴표만 제거, 추가 규칙 없음)
#   sp_varrefs "<raw>"         → 줄마다 NAME<TAB>OP<TAB>CTX: 변수 참조. OP 는 $ ($NAME) · } (${NAME}) · len (${#NAME}) ·
#                                이름 뒤 연산자(:+ + :- - := :? :0 # % / …). CTX 는 e(펼쳐짐: 따옴표 밖·큰따옴표 안) ·
#                                s(작은따옴표·$'…' 안 = 글자 그대로). guard-secrets 의 env-secret 판정용(F6).
#   sp_head "<masked>"         → 첫 단어
#   sp_git_subcmd "<raw>"      → git_dir<TAB>subcommand<TAB>rest(원문, 따옴표 유지); git 이 아니면 출력 없음·반환 1
# 성능: 문자 단위 substr/연결은 긴 입력에서 2차 비용이므로(BWK awk 의 substr 은 매번 strlen, 함수 인수는 호출마다 복사) 줄 단위로 처리하고
#       따옴표 구간·일반 단어는 index/match 로 한 번에 복사한다(G6). heredoc 본문 스캐너는 2048자 창 안에서만 본다(R7). 200KB heredoc 도 선형에 가깝다.

IFS= read -r -d '' SP_AWK <<'AWK' || :
function unq(s,  i,n,o,c,c2) { n=length(s); o=""; i=1
  while (i<=n) { c=substr(s,i,1)
    if (c=="'") { c2=index(substr(s,i+1),"'"); if (c2==0) return o substr(s,i+1); o=o substr(s,i+1,c2-1); i+=c2+1; continue }
    if (c=="$" && substr(s,i+1,1)=="'") { i+=2
      while (i<=n) { c=substr(s,i,1); i++; if (c=="\\") { o=o substr(s,i,1); i++ } else if (c=="'") break; else o=o c }
      continue }
    if (c=="\"") { i++
      while (i<=n) { if (!match(substr(s,i),/["\\]/)) return o substr(s,i)
        o=o substr(s,i,RSTART-1); i+=RSTART-1; c=substr(s,i,1); i++
        if (c=="\"") break
        c2=substr(s,i,1); if (c2!="" && index("\"\\$`",c2)) { o=o c2; i++ } else o=o c }
      continue }
    if (c=="\\") { o=o substr(s,i+1,1); i+=2; continue }
    if (!match(substr(s,i),/['"\\$]/)) return o substr(s,i)
    if (RSTART==1) { o=o c; i++; continue }
    o=o substr(s,i,RSTART-1); i+=RSTART-1 }
  return o }
function maskstr(s,  i,n,o,c,c2) { n=length(s); o=""; i=1
  while (i<=n) { c=substr(s,i,1)
    if (c=="'") { c2=index(substr(s,i+1),"'"); o=o "'Q'"; if (c2==0) break; i+=c2+1; continue }
    if (c=="$" && substr(s,i+1,1)=="'") { o=o "$'Q'"; i+=2; while (i<=n) { c=substr(s,i,1); i++; if (c=="\\") i++; else if (c=="'") break } continue }
    if (c=="\"") { o=o "\"Q\""; i++; while (i<=n) { if (!match(substr(s,i),/["\\]/)) { i=n+1; break } i+=RSTART-1; c=substr(s,i,1); i++; if (c=="\"") break; i++ } continue }
    if (c=="\\") { o=o c substr(s,i+1,1); i+=2; continue }
    if (!match(substr(s,i),/['"\\$]/)) return o substr(s,i)
    if (RSTART==1) { o=o c; i++; continue }
    o=o substr(s,i,RSTART-1); i+=RSTART-1 }
  return o }
function splitwords(s,W,  i,n,c,w,cnt,e) { if (index(s,RSB)) gsub(RSB," ",s); if (index(s,USB)) gsub(USB," ",s)   # sub 줄의 개행·탭 바이트(0x1E·0x1F)는 공백처럼 나눈다(R4 task1·R6 P-A): 재파싱하지 않고 한 세그먼트로 두는 2단계 sub 를 예전처럼 토큰화
  n=length(s); w=""; cnt=0; i=1
  while (i<=n) { c=substr(s,i,1)
    if (c==" " || c=="\t" || c=="\n" || c=="\r") { if (w!="") W[++cnt]=w; w=""; i++; continue }
    if (c=="'") { e=index(substr(s,i+1),"'"); if (e==0) { w=w substr(s,i); break } w=w substr(s,i,e+1); i+=e+1; continue }
    if (c=="$" && substr(s,i+1,1)=="'") { e=i; i+=2; while (i<=n) { c=substr(s,i,1); i++; if (c=="\\") i++; else if (c=="'") break } w=w substr(s,e,i-e); continue }
    if (c=="\"") { e=i; i++; while (i<=n) { if (!match(substr(s,i),/["\\]/)) { i=n+1; break } i+=RSTART-1; c=substr(s,i,1); i++; if (c=="\"") break; i++ } w=w substr(s,e,i-e); continue }
    if (c=="\\") { w=w substr(s,i,2); i+=2; continue }
    if (c=="<" || c==">") { if (w!="" && w !~ RE_OPW) { W[++cnt]=w; w="" } w=w c; i++; continue }   # 2>> 3<> 는 한 단어(A)
    if (!match(substr(s,i),/[ \t\n\r'"\\<>$]/)) { w=w substr(s,i); break }
    if (RSTART==1) { w=w c; i++; continue }
    w=w substr(s,i,RSTART-1); i+=RSTART-1 }
  if (w!="") W[++cnt]=w; return cnt }
function join(A,a,b,  s,i) { s=""; for (i=a;i<=b;i++) if (A[i]!="") s=s (s==""?"":" ") A[i]; gsub(/[\t\n\r]/," ",s); return s }
function flat(s) { gsub(/[\t\n\r]/," ",s); return s }
function flatn(s) { if (SUBFLAT) { gsub(/[\t\n\r]/," ",s); return s }   # SP_SUBFLAT=1: R4 이전처럼 개행·탭·CR 모두 공백(P-D) — 가드가 가장 깊은 전개에서만 켠다
  gsub(/\r/," ",s); gsub(/\t/,USB,s); gsub(/\n/,RSB,s); return s }   # sub 의 RAW 전용: 개행→0x1E, 탭→0x1F 로 보존(재파싱 때 줄·탭으로 되살린다; R4 task1·R6 P-A). CR 은 공백
function subrec(s) { return "sub\t" maskstr(flat(s)) "\t" flatn(s) }   # sub 레코드: MASKED 는 예전처럼 공백(머리·패턴 판정이 그대로), RAW 만 0x1E — 레코드에 생개행이 없고 탭은 정확히 2개
function subrecb(s) { return "sub\t" maskstr(substr(flat(s),1,8192)) "\t" flatn(s) }   # R6: 큰 heredoc 본문 그룹용 sub — MASKED 는 앞 8192자만(maskstr 는 따옴표·$가 많으면 제곱 비용; 소비자는 RAW 를 재파싱하므로 MASKED 는 길이·표시용). RAW 는 flatn(선형)
# R6 P-C·P-B 본문 스캐너(R7: 선형). 줄을 QW 자 창 LW 로 한 번씩만 잘라 창 안에서만 substr·match 하고, 조각은 창마다 모아 붙인다(BWK awk 는
# substr 마다 원본을 strlen 하고 함수 인수를 호출마다 복사하므로 줄 전체로 하면 특수 글자 수 × 줄 길이). 다음 글자를 보는 특수 글자가 창 끝이면 다음 창을 그 글자부터 연다
function wfind(i,re,  w) { while (i<=LWN) { w=substr(LW,i,512); if (match(w,re)) return i+RSTART-1; i+=512 } return 0 }   # 창 LW 안에서 i 부터 다음 특수 글자 위치(512자 조각 — fnd 와 같은 꼴)
# R6 P-C: heredoc 본문을 inner 셸이 보는 꼴로 인코딩(줄은 호출부가 0x1E 로 잇는다). 탭→0x1F, CR→공백은 공통
function encp(L2,  n2,b,o,ob,i3,e) { if (!index(L2,"\t") && !index(L2,"\r")) return L2; n2=length(L2); o=""; b=1   # 따옴표 있는 구분자: 본문 그대로(따옴표 제거 없음). 탭·CR 없는 줄은 그대로
  while (b<=n2) { LW=substr(L2,b,QW); LWN=length(LW); ob=""; i3=1
    while (i3<=LWN) { e=wfind(i3,RE_TC); if (!e) { ob=ob substr(LW,i3); break }
      ob=ob substr(LW,i3,e-i3) (substr(LW,e,1)=="\t"?USB:" "); i3=e+1 }
    o=o ob; b+=LWN }
  return o }
function qrem(L2,  n2,b,o,ob,i3,e,c,nx,last) { QRCONT=0; if (!index(L2,"\\") && !index(L2,"\t") && !index(L2,"\r")) return L2; n2=length(L2); o=""; b=1   # 따옴표 없는 구분자: 바깥 셸의 따옴표 제거 1회(\$→$ · \`→` · \\→\ · 줄 끝 \→줄 잇기 · 그 밖 \ 유지). QRCONT=1 이면 다음 줄과 이어 붙인다
  while (b<=n2) { LW=substr(L2,b,QW); LWN=length(LW); last=(b+LWN>n2); ob=""; i3=1
    while (i3<=LWN) { e=wfind(i3,RE_QR); if (!e) { ob=ob substr(LW,i3); i3=LWN+1; break }
      ob=ob substr(LW,i3,e-i3); c=substr(LW,e,1)
      if (c=="\t") { ob=ob USB; i3=e+1; continue }
      if (c=="\r") { ob=ob " "; i3=e+1; continue }
      if (e==LWN) { if (last) { QRCONT=1; return o ob } i3=e; break }   # 줄 끝 \ = 줄 잇기. 창 끝이면 다음 창에서 본다
      nx=substr(LW,e+1,1)
      if (nx=="$" || nx=="`" || nx=="\\") { ob=ob nx; i3=e+2; continue }
      if (nx=="\t") { ob=ob "\\" USB; i3=e+2; continue }
      ob=ob "\\" nx; i3=e+2 }
    o=o ob; b+=i3-1 }
  return o }
# R6 P-C/P-D: 세그먼트가 표준 입력을 스크립트로 읽는 셸인가(gd_prog/gd_prog_stdin 의 셸 부분을 거울). sc = subcmd(k)(셸 -c 문자열이면 아님)
function segshellread(k,sc,  h,j,w,op,sdash,noex,dd) { h=M[k]
  if (isshell(h)) { if (sc!="") return 0
    sdash=0; noex=0; dd=0; op=""
    for (j=k+1;j<=nw;j++) { w=uqt(j)
      if (w ~ /^([0-9]*[<>]|&>)/) { if (w ~ /^([0-9]*[<>]+[|&]?|&>>?[|]?)$/) j++; continue }   # 리디렉션(순수 연산자면 대상 단어도 건너뛴다) — -- 뒤에서도. &>·&>>(R7: 파서는 &>파일 을 한 단어로 둔다)
      if (dd) { op=w; break }                                    # -- · - 뒤 첫 인수는 스크립트 파일
      if (w=="--" || w=="-") { dd=1; continue }
      if (w ~ /^--./) { if (w=="--rcfile" || w=="--init-file") j++; continue }   # 긴 옵션(--norc·--posix·--login …): 값을 받는 것은 --rcfile·--init-file 뿐
      if (w ~ /^[-+][A-Za-z]+$/) { if (substr(w,1,1)=="-") { if (index(w,"s")) sdash=1; if (index(w,"n")) noex=1 }   # -s: 표준 입력에서 읽는다. -n: 읽기만 하고 실행하지 않는다
        if (w ~ /[oO]/) { j++; if (j<=nw && uqt(j)=="noexec" && substr(w,1,1)=="-") noex=1 }   # -o 이름·+O 이름
        continue }
      op=w; break }
    if (noex) return 0
    if (sdash || op=="" || op=="-") return 1
    return (op=="/dev/stdin" || op=="/dev/fd/0" || op=="/proc/self/fd/0" || op=="/proc/thread-self/fd/0") }
  if (h=="source" || h==".") {
    for (j=k+1;j<=nw;j++) { w=uqt(j)
      if (w ~ /^([0-9]*[<>]|&>)/) { if (w ~ /^([0-9]*[<>]+[|&]?|&>>?[|]?)$/) j++; continue }
      return (w=="-" || w=="/dev/stdin" || w=="/dev/fd/0" || w=="/proc/self/fd/0" || w=="/proc/thread-self/fd/0") }
    return 0 }
  if (h=="ssh" || h=="su") return (sc=="" || sc ~ /^([0-9]*[<>]|&>)/)
  return 0 }
function segsr_owner(d,o,  s) { s=o; if (SEGSR[d,s]) return 1   # heredoc 소유 세그먼트(깊이 d 의 o 번째)와 같은 깊이의 파이프라인 중 하나라도 표준 입력을 읽는 셸이면 본문은 셸이 읽는다(cat <<EOF | bash)
  while (SEGPIP[d,s] && s<SGC[d]) { s++; if (SEGSR[d,s]) return 1 }
  return 0 }
# R6 P-B: 따옴표 없는 heredoc 본문의 치환($(…)·`…`)을 한 줄씩 상태를 이어 스캔해 PBG 에 담는다(순서 유지 — heredoc 레코드 뒤에 낸다)
function pb_add(x,  lx) { if (x=="") return; if (PBLEN>=PBCAP) { PBTR=1; return }   # 치환 내부 길이 상한(병적 치환) — 넘으면 자르고 overflow. 빈 조각은 무시(R7: 창 경계의 빈 조각)
  lx=length(x); if (PBLEN+lx>PBCAP) { x=substr(x,1,PBCAP-PBLEN); PBTR=1; lx=length(x) }
  PBCH=PBCH x; PBLEN+=lx; if (++PBCL>=64) { PBACC=PBACC PBCH; PBCH=""; PBCL=0 } }   # 64조각마다 모아 붙인다(조각마다 붙이면 제곱 비용)
function pb_push() { PBACC=PBACC PBCH; PBCH=""; PBCL=0
  if (NPB>=PBCAPN) PBOV=1; else PBG[++NPB]=PBACC
  if (PBTR) PBOV=1
  PBACC=""; PBLEN=0; PBTR=0 }
function pb_line(L2,cn,  n2,b,i3,e,c,last) {   # cn=1: 줄 끝 \ 를 뗀 줄(다음 줄과 한 논리 줄 — 셸이 \+개행을 지운다)
  if (PBDL) { if (L2=="" && cn) return; PBDL=0; if (PBST==0 && substr(L2,1,1)=="(") { PBST=1; PBDEP=1; PBQ=""; PBBT=0; L2=substr(L2,2) } }   # 앞 줄 끝의 $ + 이 줄의 ( = $( (R7)
  n2=length(L2)
  if (PBST==0 && !(cn && substr(L2,n2,1)=="$") && index(L2,"$(")==0 && index(L2,"`")==0) return   # 싼 경로: 본문 레벨이고 $( 도 ` 도 없으면 건너뛴다
  b=1
  while (b<=n2) { LW=substr(L2,b,QW); LWN=length(LW); last=(b+LWN>n2); i3=1   # 창 스캔(위 qrem 과 같다). 창 끝의 \ · $ 는 다음 글자를 보므로 다음 창에서
    while (i3<=LWN) {
      if (PBST==0) { e=wfind(i3,RE_PBB); if (!e) { i3=LWN+1; break }   # 본문 레벨: \ $ ` 만 의미
        if (e==LWN && !last) { i3=e; break }
        c=substr(LW,e,1)
        if (c=="\\") { i3=e+2; continue }                         # \$ \` \\ 는 리터럴(치환 아님)
        if (c=="`") { PBST=2; i3=e+1; continue }
        if (substr(LW,e+1,1)=="(") { PBST=1; PBDEP=1; PBQ=""; PBBT=0; i3=e+2; continue }
        if (e==LWN && last && cn) PBDL=1                          # 이은 줄 끝의 $ 는 다음 줄 첫 글자와 본다
        i3=e+1; continue }                                        # 홀로 있는 $
      if (PBST==2) { e=wfind(i3,RE_BT); if (!e) { pb_add(substr(LW,i3)); i3=LWN+1; break }   # 본문 레벨 백틱 치환
        pb_add(substr(LW,i3,e-i3)); c=substr(LW,e,1)
        if (c=="\\") { if (e==LWN && !last) { i3=e; break } pb_add(substr(LW,e,2)); i3=e+2; continue }
        pb_push(); PBST=0; i3=e+1; continue }
      e=wfind(i3,RE_PBS); if (!e) { pb_add(substr(LW,i3)); i3=LWN+1; break }   # $( … ) 내부: 따옴표·괄호 깊이로 끝을 찾는다(최상위 $() 와 같은 규칙)
      pb_add(substr(LW,i3,e-i3)); c=substr(LW,e,1)
      if (PBQ=="'") { pb_add(c); if (c=="'") PBQ=""; i3=e+1; continue }   # 작은따옴표 안: \ 도 리터럴
      if (c=="\\" && e==LWN && !last) { i3=e; break }
      if (PBBT) { if (c=="\\") { pb_add(substr(LW,e,2)); i3=e+2 } else { pb_add(c); if (c=="`") PBBT=0; i3=e+1 } continue }
      if (c=="\\") { pb_add(substr(LW,e,2)); i3=e+2; continue }
      if (PBQ=="\"") { pb_add(c); if (c=="\"") PBQ=""; i3=e+1; continue }
      if (c=="'" || c=="\"") { PBQ=c; pb_add(c); i3=e+1; continue }
      if (c=="`") { PBBT=1; pb_add(c); i3=e+1; continue }
      if (c=="(") { PBDEP++; pb_add(c); i3=e+1; continue }
      PBDEP--; if (PBDEP<=0) { pb_push(); PBST=0; i3=e+1; continue }
      pb_add(c); i3=e+1 }
    b+=i3-1 }
}
function oddbs(s,  n,k,w,b) { n=length(s); b=0   # R7(C6): 줄 끝 역슬래시가 홀수 개인가(셸의 줄 잇기). 끝에서 512자 창으로 센다(긴 줄에서도 선형)
  while (n>0) { w=substr(s,(n>512)?n-511:1,(n>512)?512:n); k=length(w)
    while (k>0 && substr(w,k,1)=="\\") { k--; b++ }
    if (k>0) break; n-=length(w) }
  return b%2 }
function tp(x) { if (TKM && TK >= TKM) { TRUNC=1; return } print x; TK++ }   # 토큰 한 줄(R5: tokseg 토큰 상한)
function tokens(s,  W,n,i,t,k,p) { n=splitwords(s,W)
  for (i=1;i<=n;i++) { t=unq(W[i]); if (t=="") { if (keepempty) tp("__SP_EMPTY__"); continue }
    if (match(t,/^-*[A-Za-z_][A-Za-z0-9_-]*=/)) { tp(substr(t,1,RLENGTH)); t=substr(t,RLENGTH+1); if (t=="") { if (keepempty) tp("__SP_EMPTY__"); continue } }
    if (substr(t,1,1)=="@") t=substr(t,2)
    tp(t); k=index(t,":")
    if (k>1 && index(substr(t,1,k-1),"/")==0 && substr(t,k+1,2)!="//") { p=substr(t,k+1); if (p ~ "^[~/.]") tp(p) } } }
function joinpath(a,b) { if (a=="" || substr(b,1,1)=="/") return b; return a "/" b }
function gitcmd(s,  W,n,i,w,dir,sc,rest) { n=splitwords(s,W); if (n<1 || unq(W[1])!="git") return
  dir=""; sc=""; rest=""
  for (i=2;i<=n;i++) { w=unq(W[i])
    if (w=="-C" || w=="-c" || w=="--git-dir" || w=="--work-tree" || w=="--namespace" || w=="--exec-path" || w=="--config-env" || w=="--attr-source" || w=="--super-prefix") {
      if (w=="-C" && i<n) dir=joinpath(dir,unq(W[i+1])); i++; continue }
    if (w ~ /^-C./) { dir=joinpath(dir,substr(w,3)); continue }
    if (w ~ /^(--git-dir=|--work-tree=|--namespace=|--exec-path=|--config-env=|--attr-source=|-c.)/ || w=="--no-pager" || w=="-P" || w=="-p" || w=="--paginate" || w=="--bare" || w=="--no-replace-objects" || w=="--no-optional-locks" || w=="--literal-pathspecs" || w=="--glob-pathspecs" || w=="--noglob-pathspecs" || w=="--icase-pathspecs" || w=="--no-lazy-fetch" || w=="--no-advice") continue
    sc=w; break }
  for (i++;i<=n;i++) rest=rest (rest==""?"":" ") W[i]
  print dir "\t" sc "\t" flat(rest) }
BEGIN { split("then do else elif fi done esac in",a," "); for (i in a) KW[a[i]]=1
  split("! if while until nohup time nice timeout stdbuf command builtin noglob exec xargs env sudo doas npx bunx uvx",a," "); for (i in a) W1[a[i]]=1
  split("pnpm exec|pnpm dlx|yarn dlx|yarn exec|npm exec|npm x|uv run|poetry run|pipenv run|pdm run|hatch run|rye run|bundle exec",a,"|"); for (i in a) W2[a[i]]=1
  split("rm git dd mkfs shutdown reboot halt poweroff crontab launchctl diskutil chmod chown chgrp sudo doas su cat head tail less more grep egrep fgrep rg sed awk cut sort uniq strings xxd hexdump od base64 scp rsync curl wget nc tar zip python python3 node ruby perl php jq yq openssl cp mv install source rimraf grm gfind find shred truncate kill killall5 history csrutil nvram psql mysql sqlite3 docker docker-compose kubectl helm terraform terragrunt npm pnpm yarn make exec eval sh bash zsh env xargs nohup time nice timeout command printenv",a," "); for (i in a) LOWH[a[i]]=1
  split("podman nerdctl flock mise caffeinate chrt ionice taskset setsid unbuffer script chroot unshare systemd-run runuser",a," "); for (i in a) LOWH[a[i]]=1
  vt["sudo"]="-u -g -U -C -D -h -p -r -t -T --user --group --host --prompt --role --type --chdir --close-from"
  vt["doas"]="-u -C"; vt["env"]="-u -C -S --unset --chdir --split-string"; vt["nice"]="-n --adjustment"
  vt["timeout"]="-k -s --kill-after --signal"; vt["stdbuf"]="-i -o -e --input --output --error"; vt["exec"]="-a"
  vt["xargs"]="-n -P -I -L -s -E -d -J -R -S -a -i --max-args --max-procs --replace --delimiter --max-lines --max-chars --eof --arg-file"
  vt["npx"]="-p --package -c --call"; vt["npm exec"]="--package -p -c --call"; vt["yarn dlx"]="-p --package"; vt["pnpm dlx"]="--package -p"
  vt["uvx"]="--from --with --python -p --index --with-editable --with-requirements --constraints -c"
  vt["uv run"]="--env-file --with --with-editable --with-requirements --python -p --directory --project --package --extra --group --only-group --index --default-index --find-links -f --config-file --cache-dir --refresh-package --exclude-newer --link-mode --resolution --prerelease --fork-strategy --python-preference --python-platform --color --upgrade-package -P --reinstall-package --no-binary-package --no-build-package --script -m --module --constraints -c --build-constraints -b"
  vt["ssh"]="-b -c -D -E -e -F -I -i -J -L -l -m -O -o -p -Q -R -S -W -w -B"
  vt["docker"]="--context -c -H --host -l --log-level --config"; vt["compose"]="-f --file -p --project-name --profile --env-file --project-directory --progress --ansi"
  vt["dexec"]="-u --user -w --workdir -e --env --env-file --detach-keys --index --entrypoint -v --volume -p --publish --name -l --label"
  vt["kubectl"]="-n --namespace --context --kubeconfig --cluster --user -v --request-timeout --as --as-group -s --server --token --certificate-authority --client-certificate --client-key"
  vt["kexec"]=vt["kubectl"] " -c --container -f --filename --pod-running-timeout"
  for (k in vt) { n=split(vt[k],a," "); for (i=1;i<=n;i++) VAL[k,a[i]]=1 }
  POS["timeout"]=1; PH="$(\342\200\246)"; RSB=sprintf("%c",30)   # 0x1E(RS): sub 레코드의 개행 인코딩(R4 task1). 레코드 사이·필드 안에 생개행이 남지 않게
  USB=sprintf("%c",31); SUBFLAT=(subflat=="1")   # 0x1F(US): sub RAW 의 탭 인코딩(R6 P-A) — 재파싱 때 탭으로 되살려 <<- 종료 토큰이 어긋나지 않게. SUBFLAT(SP_SUBFLAT=1): sub RAW 를 R4 이전처럼 평탄화(개행·탭·CR 모두 공백; P-D)
  RE_SQ="'"; RE_AN="['\\\\]"; RE_DQ="[\"\\\\$`]"; RE_RUN="[ \t\r;&|()<>`\"'\\\\$#{}]"
  RE_QR="[\\\\\t\r]"; RE_TC="[\t\r]"; RE_PBB="[\\\\$`]"; RE_PBS="[\\\\'\"()`]"; RE_BT="[\\\\`]"   # R6 heredoc 본문 스캐너: RE_QR(역슬래시·탭·CR, P-C 따옴표 제거), RE_TC(탭·CR, 따옴표 구분자 본문 인코딩), RE_PBB(역슬래시·$·백틱, P-B 본문 레벨), RE_PBS(치환 내부 끝 찾기), RE_BT(백틱 치환 끝: 역슬래시·백틱)
  QW=2048   # R7: 본문 스캐너의 창 크기(위 wfind 주석)
  PBCAP=65536; PBCAPN=4096   # R6 P-B: 치환 하나의 내부 글자 상한·본문당 치환 수 상한(병적 본문) — 넘으면 자르고 overflow
  RE_OPW="^([0-9]*|[<>&|]+|[0-9]+[<>][<>&|]*)$"   # 리디렉션 연산자에 이어 붙는 단어: fd 번호, 연산자, fd 번호+연산자(1& 은 아님: 1&>f 의 1 은 인수)
  WBMAX=(wbmax=="" ? 5000 : wbmax+0); WBXMAX=64   # R4 task2 백스톱: sp_segments 가 내는 레코드 수 상한. 기존의 큰 명령 테스트(최대 ~3000 레코드: 1500개 sh -c)와 가드 자체 상한(GM_FKMAX·FORKCAP)보다 넉넉히 위, 병적인 입력(rm+subs 64KB ~14000 레코드)은 아래. 테스트는 -v wbmax 로 바꾼다. WBXMAX: 상한을 넘은 뒤 마무리에서 새로 생기는 줄의 상한(R5)
  WPMAX=8192    # R5: 단어 하나를 이루는 조각(이스케이프·따옴표·$ 마다 하나) 상한 — BWK awk 는 조각을 붙일 때마다 단어 전체를 복사해(\\ 10만 개 200 KB 에 파싱 3초 + 토큰화 3.6초) 넘으면 overflow
  WWMAX=24000   # R5: 호출 하나의 단어 수 상한 — 한 세그먼트의 단어를 잇는 join 과 토큰화가 단어 수의 제곱이라(BWK awk: 10만 단어 200 KB 에 파싱 5.9초 + 토큰화 2.6초) 넘으면 overflow 로 멈춘다. 테스트 최대는 2만 단어 한 줄
  TKM=(tokmax=="" ? 0 : tokmax+0) }   # R5: tokseg 토큰 상한(가드의 토큰 상한) — 넘으면 그 줄까지만(__SP_SEG__ 도 거기까지) 내고 끝에 __SP_TRUNC__ 한 줄(가드는 그 뒤 세그먼트를 보지 않고 too-complex). 0 = 상한 없음
mode=="tokseg" { if (!TKM || TK < TKM) { tokens($0); print "__SP_SEG__" } else TRUNC=1; next }
mode!="" { S=S (NR>1?"\n":"") $0; next }
{ _l=$0; if (index(_l,USB)) gsub(USB,"\t",_l)   # 0x1F(sub 의 탭)를 탭으로 되살린다(R6 P-A) — <<- 종료 토큰이 재파싱 때도 어긋나지 않게. 0x1E 와 다른 바이트라 분리 전에 풀어도 안전
  if (index(_l,RSB)) { _nf=split(_l,LA,RSB); for (_i=1;_i<=_nf;_i++) LN[++nl]=LA[_i] } else LN[++nl]=_l }   # 0x1E(sub 의 개행)를 줄로 되살린다 — 소비자가 sub RAW 를 sp_segments 로 다시 파싱할 때 heredoc·줄 잇기·주석이 top-level 과 같게 동작(R4 task1). 명령에 든 0x1E·0x1F 는 가드가 파서에 넘기기 전에 보통 글자 0x1D 로 바꾼다(lib/common.sh — 줄 구분으로 읽으면 heredoc 본문이 일찍 끝날 수 있다)
function out(s) { if (!WOV && ++WB>WBMAX) WOV=1   # 작업 상한(R4 task2 백스톱): 낸 줄 수가 WBMAX 를 넘으면 입력을 더 읽지 않는다 — 본문 루프가 멈추고 END 가 읽은 부분만 마무리한 뒤 overflow 를 맨 끝에 낸다(소비자는 '다 분석하지 못함'; 과도한 세그먼트·sub 재파싱·fork 가 10초 제한을 넘겨 fail-open 되지 않게). 코퍼스 최대 레코드 수는 15 이라 정상 명령은 걸리지 않는다
  if (WOV && !wbx(s)) return
  if (depth>0) PEND[depth]=PEND[depth] s "\n"; else printf "%s\n", s }
function wbx(s) {   # 상한을 넘은 뒤 마무리에서 새로 생기는 줄(R5): WBXMAX 줄까지만 낸다. push/pop 은 짝을 맞춘다 — 버린 push 의 pop 만 버린다(한 세그먼트의 묶음은 겹쳐 열리고 닫힌다)
  if (substr(s,1,5)=="push\t") { if (WBX>=WBXMAX) { WDP++; return 0 } WBX++; return 1 }
  if (substr(s,1,4)=="pop\t") { if (WDP>0) { WDP--; return 0 } return 1 }
  return (++WBX<=WBXMAX) }
function outblk(b) { if (depth>0) PEND[depth]=PEND[depth] b; else printf "%s", b }   # 묶음 줄은 만들 때(out·push·xsubend) 이미 셌다 — 상한을 넘은 뒤에도 옮긴다(상한 앞에서 만든 줄을 버리지 않게; R5)
function skipopts(name,k,  w) { while (k<=nw && (w=uqt(k)) ~ /^-/) { if (w=="--") return k+1   # 따옴표 친 옵션("-n" '-u')도 옵션으로(R3b 검증)
    if ((name,w) in VAL) { if (w ~ /^--env[-_]?file$/) ENVF[++nenvf]=unq(R[k+1]); k+=2 }
    else { if (w ~ /^--env[-_]?file=./) ENVF[++nenvf]=unq(substr(R[k],index(R[k],"=")+1)); k++ } }
  return k }
function containerexec(w,k,  j) { j=skipopts(w,k+1)
  if (w=="kubectl") { if (M[j]!="exec") return k; j=skipopts("kexec",j+1); j=skipopts("kexec",j+1); return j }
  if (M[j]=="compose") { j=skipopts("compose",j+1); if (M[j]!="run" && M[j]!="exec") return k; return skipopts("dexec",j+1)+1 }
  if (M[j]=="exec") return skipopts("dexec",j+1)+1
  return k }
function uqt(i) { if (M[i] ~ /['"\\]/) return unq(R[i]); return M[i] }   # 따옴표·역슬래시가 있을 때만 벗긴 토큰(없으면 MASKED 그대로 — 깨끗한 토큰은 regex 1번). "-c" '-c' \-c -"c" 같은 따옴표 친 플래그도 -c 로 본다
function shstr(j,b,  x,w) {   # 셸 -c 묶음(j) 뒤 명령 문자열의 위치(b 까지, 없으면 0). POSIX sh -c [옵션] 문자열: -c 뒤 옵션(-x -e +x, o·O 는 이름 1개 더)과 -- · - 는 건너뛴다
  w=uqt(j); x=j+1+gsub(/[oO]/,"",w)
  while (x<=b) { w=uqt(x)
    if (w=="--" || w=="-") return (x<b)?x+1:0
    if (w !~ /^[-+][A-Za-z]+$/) return x
    x+=1+gsub(/[oO]/,"",w) }
  return 0 }
function subcmd(k,  h,j,s) { h=M[k]; s=""
  if (isshell(h)) {   # 경로·대문자 셸(/opt/homebrew/opt/bash/bin/bash, DASH, KSH)도 셸로(macOS 는 대소문자 무시; R3b 검증)
    for (j=k+1;j<nw;j++) if (uqt(j) ~ /^-[A-Za-z]*c[A-Za-z]*$/) { j=shstr(j,nw); if (j) s=unq(R[j]); break } }
  else if (h=="su") { for (j=k+1;j<nw;j++) if (uqt(j)=="-c") { s=unq(R[j+1]); break } }
  else if (h=="eval") { for (j=k+1;j<=nw;j++) s=s (s==""?"":" ") unq(R[j]) }
  else if (h=="ssh") { j=skipopts("ssh",k+1); for (j++;j<=nw;j++) s=s (s==""?"":" ") unq(R[j]) }
  return s }   # 개행은 호출부(subrec)가 0x1E 로 인코딩한다 — 여기서 뭉개면 재파싱 때 줄이 사라진다(R4 task1)
function isshell(w,  n,P) { w=tolower(w); n=split(w,P,"/"); w=(n>0 ? P[n] : ""); return (w=="sh" || w=="bash" || w=="zsh" || w=="dash" || w=="ksh" || w=="mksh") }   # R5: 마지막 / 뒤(sub(/.*\//) 는 / 가 없는 긴 단어에서 시작 위치마다 끝까지 훑어 길이의 제곱 — 30 KB 머리에 3초)
function shc(a,b,  j,x) {   # [a,b] 에서 처음 나오는 셸 단어 뒤의 -c 문자열(없으면 "")
  for (j=a;j<=b;j++) if (isshell(unq(R[j]))) { for (x=j+1;x<b;x++) if (uqt(x) ~ /^-[A-Za-z]*c[A-Za-z]*$/) { x=shstr(x,b); return x?unq(R[x]):"" } return "" }
  return "" }
function xsub(s) { if (s=="") return 0; out("push\t(\t("); out(subrec(s)); out("pop\t)\t)"); return 1 }
function xsubend(s) { if (s=="") return   # 출력 맨 끝(env -S). 묶음 3줄도 작업 상한에 센다(R5: 세지 않으면 env -S 가 많은 명령의 출력이 상한의 4배까지 컸다)
  if (!WOV && (WB+=3)>WBMAX) WOV=1
  if (WOV && (WBX+=3)>WBXMAX) return
  XEND=XEND "push\t(\t(\n" subrec(s) "\npop\t)\t)\n" }
function envsplit(k,  j,w,s) { s=""   # env -S|--split-string 문자열 + 뒤 단어(env 가 쪼개 실행하는 명령; B)
  for (j=k+1;j<=nw && (w=uqt(j)) ~ /^-/;j++) {   # 따옴표 친 "-S" 도(R3b 검증)
    if (w=="--") break
    if (w=="-S" || w=="--split-string" || w ~ /^-[0iv]+S$/) { s=unq(R[j+1]); j++; break }
    if (w ~ /^--split-string=/) { s=unq(substr(R[j],index(R[j],"=")+1)); break }
    if (w ~ /^-[0iv]*S./) { s=unq(R[j]); sub(/^-[0iv]*S/,"",s); break }
    if (w=="-u" || w=="-C" || w=="-P" || w=="--unset" || w=="--chdir") j++ }
  if (s=="") return ""
  for (j++;j<=nw;j++) s=s " " unq(R[j])
  return s }
function xsubs(k,  h,j,e,x,n) { h=tolower(M[k]); n=0   # 셸 문자열 실행기의 문자열을 sub 줄로(B). 낸 묶음 수를 돌려준다
  if (h=="find" || h=="gfind") {
    for (j=k+1;j<nw;j++) { x=uqt(j); if (x=="-exec" || x=="-execdir" || x=="-ok" || x=="-okdir") {   # 따옴표 친 "-exec" 도(guard-destructive 의 sp_words 와 같은 수; R3b 검증)
      for (e=j+1;e<=nw;e++) { x=unq(R[e]); if (x==";" || (x=="+" && unq(R[e-1])=="{}")) break }
      if (isshell(unq(R[j+1]))) n+=xsub(shc(j+1,e-1))
      j=e } } }
  else if (h=="watch") {
    for (j=k+1;j<=nw && (e=uqt(j)) ~ /^-/;j++) { if (e=="--") { j++; break }
      if (e=="--interval" || e=="--equexit" || e=="--shotsdir" || e ~ /^-[A-Za-z]*[nqs]$/) j++ }
    x=""; for (;j<=nw;j++) x=x (x==""?"":" ") unq(R[j])
    n=xsub(x) }
  else if (h=="podman") { for (j=k+1;j<=nw;j++) if (M[j]=="exec" || M[j]=="run") { n=xsub(shc(j+1,nw)); break } }
  else if (h=="nsenter") n=xsub(shc(k+1,nw))
  else n=xsubs3(k,h)
  return n }
function process(  k,k2,w,w2,h,sudo,xargs,asg,kind,sc,dup,j,es,er,em,ctr,nx,ns) { sudo=0; xargs=0; asg=""; k=1; dup=0; nenvf=0; es=""; bk=0; basg=""; ctr=0
  SGC[depth]++; SEGSR[depth,SGC[depth]]=0; SEGPIP[depth,SGC[depth]]=GPIPE   # R6 P-C: 깊이마다 세그먼트 순번(hdoc 의 SGC[depth]+1 과 짝 — 일찍 끝나는 세그먼트도 센다)·파이프 연결. 셸-읽기 여부는 아래에서
  while (k<=nw) { w=M[k]
    if (w in KW) { k++; continue }
    if (w ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) { asg=asg (asg==""?"":" ") R[k]; k++; continue }
    h=unq(R[k]); if (h=="") { k++; continue }
    if (h!=w) { M[k]=h; R[k]=h; w=h }
    w2=tolower(w); if (w2!=w && ((w2 in LOWH) || w2 ~ /^mkfs\./)) { M[k]=w2; R[k]=w2; w=w2 }
    if (match(w,/^(\/usr\/local\/bin|\/opt\/homebrew\/bin|\/usr\/bin|\/usr\/sbin|\/bin|\/sbin)\//) && RLENGTH<length(w)) { M[k]=substr(w,RLENGTH+1); R[k]=substr(R[k],RLENGTH+1); continue }
    if (match(w,/^\/.*\/libexec\/gnubin\//) && RLENGTH<length(w)) { M[k]=substr(w,RLENGTH+1); R[k]=substr(R[k],RLENGTH+1); continue }
    if (w=="command" && (uqt(k+1)=="-v" || uqt(k+1)=="-V")) break
    if (w=="sudo" || w=="doas") sudo=1
    if (w=="xargs") xargs=1
    if (w=="env" && es=="") es=envsplit(k)
    if (w in W1) { k2=skipopts(w,k+1); if (w in POS) k2+=POS[w]; if (k2>nw) break; k=k2; continue }
    w2=w " " M[k+1]
    if (w2 in W2) { k2=skipopts(w2,k+2); if (k2>nw) break; k=k2; continue }
    if (w=="docker" || w=="kubectl") { j=nenvf; k2=containerexec(w,k); if (k2>k && k2<=nw) { if (w=="kubectl") dup=k; k=k2; continue } nenvf=j }
    if (w=="docker" || w=="podman" || w=="nerdctl" || w=="docker-compose") { j=ctrrun(w,k)   # 라운드 3 B 묶음
      if (j>0) { k2=j+1; er=""
        if (EPW && !dup) { if (index(M[EPW],"=")) { er=substr(R[EPW],index(R[EPW],"=")+1); em=substr(M[EPW],index(M[EPW],"=")+1) } else { er=R[EPW+1]; em=M[EPW+1] }
          if (unq(er)!="") k2=j; else er="" }   # --entrypoint X = 안쪽 명령의 머리
        if (k2<=nw) { if (!bk && !dup) { bopen(k,sudo,xargs,asg); asg="" } if (er!="") { M[j]=em; R[j]=er } ctr=1; k=k2; continue } } }
    k2=bwrap(w,k); if (k2>0) { if (!bk && !dup) { bopen(k,sudo,xargs,asg); asg="" } k=k2; continue }
    break }
  if (bk) { if (basg!="") out("assign\t" flat(basg) "\t" flat(basg)); out(bkind "\t" BKM "\t" BKR); if (k>nw) return; out("push\t(\t(") }
  if (asg!="") out("assign\t" flat(asg) "\t" flat(asg))
  if (k>nw) return
  for (j=1;j<=nenvf;j++) out("envfile\t" flat(ENVF[j]) "\t" flat(ENVF[j]))
  kind="cmd" (sudo?"+sudo":"") (xargs?"+xargs":"")
  if (dup) out(kind "\t" join(M,dup,nw) "\t" join(R,dup,nw))
  out(kind "\t" join(M,k,nw) "\t" join(R,k,nw))
  sc=subcmd(k); if (sc!="") out(subrec(sc))
  SEGSR[depth,SGC[depth]]=segshellread(k,sc)   # R6 P-C: 이 세그먼트가 표준 입력을 스크립트로 읽는 셸인가(heredoc 소유권 판정용; 서브셸·치환 안도 그 깊이에서)
  xsubend(es); nx=xsubs(k); if (nx) out(kind "\t" join(M,k,nw) "\t" join(R,k,nw))
  if (ctr && sc=="" && !nx) { ns=shc(k,nw); if (ns!="") out(subrec(ns)) }   # 벗긴 컨테이너 안쪽이 prefix(busybox·tini·gosu) 뒤 중첩 sh -c 면 그 문자열도 검사(r2b podman 동작 복원; R3b)
  if (bk) { out("pop\t)\t)"); out(bkind "\t" BKM "\t" BKR) } }
function addc(a,b) { wr=wr a; wm=wm b; inw=1 }
function endword() { if (inw) { R[++nw]=wr; M[nw]=wm; if (++WW>WWMAX) { WOV=1; WCUT=1 } } wr=""; wm=""; inw=0; WPC=0 }   # R5: 단어 수 상한(WWMAX) — 넘으면 입력을 더 읽지 않는다. 읽다 만 그 세그먼트는 END 가 버리고(잇는 비용이 상한의 이유) 나머지는 마무리한 뒤 overflow 를 맨 끝에 낸다
function endseg(  j,sv) { endword(); sv=SSV[depth+1]
  if (nw>0) { for (j=1;j<=sv;j++) { R[j]=SR[depth+1,j]; M[j]=SM[depth+1,j] } process() }   # 세그먼트의 앞 단어는 push 가 SR[depth+1,*] 에 모았다 — process() 직전에 한 번만 되돌린다(I/R4 task2: pop 이 매번 복사하지 않는다)
  split("",R); split("",M); nw=0; SSV[depth+1]=0                                           # 다음 세그먼트의 저장 칸을 비운다
  if (DEFN[depth]>0) { for (j=1;j<=DEFN[depth];j++) outblk(DEFL[depth,j]); DEFN[depth]=0 } }   # 뒤로 미룬 치환 블록(순서대로) — 문자열 이어붙이기(2차 비용) 대신 목록
function isws(c) { return c=="" || c==" " || c=="\t" || c=="\n" || c=="\r" || c==";" || c=="&" || c=="|" || c==")" }
function fnd(re,  p,w) { p=I; while (p<=n) { w=substr(L,p,512); if (match(w,re)) return p+RSTART-1; p+=512 } return 0 }
function redirstart() { if (inw && wr !~ RE_OPW) endword() }   # fd 번호·연산자 앞부분(2 2> &> 3<)에는 붙인다(A)
function push(ty,ph,  j,d) { if (!WOV && (WB+=2)>WBMAX) WOV=1   # push·pop 래퍼 두 줄은 여기서 센다(R5: pop 에서만 세고 out() 에서만 견주면 빈 ()·$() 만 많은 명령은 상한에 걸리지 않아 출력·시간이 유계가 아니었다). 열린 채 끝나도 END 의 pop 이 닫는다
  if (ph!="") { wr=wr ph; if (q=="") wm=wm ph; inw=1 }
  d=depth+1                                                     # 나가는(바깥) 세그먼트의 저장 칸. 지난 push 이후 늘어난 단어만 복사한다(R4 task2: O(치환 수) → O(1) 평균). 앞 단어는 이미 SR[d,*] 에 있고 바뀌지 않았다
  for (j=SSV[d]+1;j<=nw;j++) { SR[d,j]=R[j]; SM[d,j]=M[j] }
  SSV[d]=nw
  depth=d; STY[depth]=ty; SQ[depth]=q; SNW[depth]=nw; SWR[depth]=wr; SWM[depth]=wm; SINW[depth]=inw
  split("",R); split("",M); nw=0; wr=""; wm=""; inw=0; q=""; PEND[depth]=""; DEFN[depth]=0; SSV[depth+1]=0 }   # 새 안쪽 세그먼트: 저장 칸·미룬 블록 비움
function pop(  d,b) { endseg(); d=depth; b=PEND[d]; depth--    # endseg 가 R 을 비웠다 — 바깥 단어는 SR[d,*] 에 그대로 두고 복사하지 않는다(바깥 endseg 가 한 번에 되돌린다)
  nw=SNW[d]; wr=SWR[d]; wm=SWM[d]; inw=SINW[d]; q=SQ[d]
  b="push\t(\t(\n" b "pop\t)\t)\n"
  if (nw==0 && !inw) outblk(b); else { DEFN[depth]++; DEFL[depth,DEFN[depth]]=b } }
function hdoc(  t,c,dash) { redirstart(); I+=2; dash=0; if (substr(L,I,1)=="-") { dash=1; I++ }
  while (substr(L,I,1)==" " || substr(L,I,1)=="\t") I++
  t=""; while (I<=n) { c=substr(L,I,1); if (isws(c) || c=="<" || c==">") break; t=t c; I++ }
  hd[++nh]=unq(t); hds[nh]=dash; hdq[nh]=(t ~ /['"\\]/)?1:0; hddep[nh]=depth; hdseg[nh]=SGC[depth]+1   # R6: 구분자에 따옴표·역슬래시가 있으면 본문 전개 안 함(hdq). hddep·hdseg: 이 heredoc 을 가진 (낼) 세그먼트의 깊이·그 깊이의 순번(서브셸 ( … )·$( … )·백틱 안도 — 순번은 줄을 넘어 늘기만 한다)
  addc("<<" (dash?"-":"") t,"<<" (dash?"-":"") unq(t)) }
function readheredocs(  j,line,t,body,ch,cl,sr,pb,pc,pch,pcl,cont,first,piece,m2,i2,bl,chl,pl,jc,jl,jx,bm,bml,pm,pml) {   # 본문은 64줄씩, 그 묶음은 다시 64개씩 모아 붙인다(줄마다 붙이면 2차 비용;
  # 1MB 에서 절단). 길이는 세어 둔다(R7: length() 는 BWK awk 에서 strlen 이라 모은 본문에 줄마다 부르면 줄 수 × 크기)
  for (j=1;j<=nh;j++) { body=""; ch=""; cl=0; bl=0; chl=0; bm=""; bml=0; pm=""; pml=0
    sr=segsr_owner(hddep[j],hdseg[j])   # P-C: 본문을 셸이 스크립트로 읽는가(소유 세그먼트·같은 깊이의 파이프)
    pb=(hdq[j]==0) ? 1 : 0              # P-B: 따옴표 없는 구분자면 본문 치환을 펼친다
    pc=""; pch=""; pcl=0; pl=0; cont=0; first=1; jc=0; jl=""; jx=0   # P-C 그룹 sub RAW 누적(0x1E/0x1F 인코딩)과 그 길이. jc·jl·jx: 줄 잇기(아래)
    if (pb) { PBST=0; NPB=0; PBCH=""; PBACC=""; PBCL=0; PBLEN=0; PBTR=0; PBOV=0; PBDL=0 }
    while (li<nl) { li++; line=LN[li]; t=line; if (jc) t=jl t; if (hds[j]) sub(/^\t+/,"",t); if (!jx && t==hd[j]) break
      # R7(C6): 따옴표 없는 구분자는 줄 끝 \(홀수 개)로 이은 줄을 한 줄로 구분자와 견준다(x\ 다음 줄의 EOF 는 xEOF 라 본문이 이어진다 — bash·sh·zsh).
      # jl 은 이은 줄의 앞부분(<<- 는 탭 제거 뒤)이고 구분자보다 길면 버린다(jx: 이 논리 줄은 구분자일 수 없다). 따옴표 친 구분자는 줄을 잇지 않는다
      if (pb && substr(line,length(line),1)=="\\" && oddbs(line)) { if (!jx) { jl=substr(t,1,length(t)-1); if (length(jl)>length(hd[j])) { jx=1; jl="" } } jc=1 } else { jc=0; jl=""; jx=0 }
      if (bl<1048576) { ch=ch " " line; chl+=length(line)+1; if (++cl>=64) { bm=bm ch; bl+=chl; ch=""; chl=0; cl=0; if (++bml>=64) { body=body bm; bm=""; bml=0 } } }
      if (sr && pl<1048576) {   # inner 셸이 보는 본문: 줄 유지, <<- 선두 탭 제거(이어진 줄은 논리 줄 머리에서만 — 셸과 같다), 따옴표 없으면 따옴표 제거
        m2=line; if (hds[j] && !cont) sub(/^\t+/,"",m2)
        if (hdq[j]) { piece=encp(m2) } else { piece=qrem(m2) }
        if (!first && !cont) { pch=pch RSB; pl++ }
        pch=pch piece; pl+=length(piece); first=0; if (++pcl>=64) { pm=pm pch; pch=""; pcl=0; if (++pml>=64) { pc=pc pm; pm=""; pml=0 } }
        cont=(hdq[j])?0:QRCONT }
      if (pb) { if (jc) { pb_line(substr(line,1,length(line)-1),1); if (PBST!=0) pb_add("\\\n") } else { pb_line(line,0); if (PBST!=0) pb_add("\n") } } }   # 치환이 줄을 넘으면 개행으로 잇는다(subrec 이 0x1E 로 인코딩). 이은 줄은 끝 \ 를 떼고 보되(R7: $\ 다음 줄 ( 도 치환) 치환 안에는 \+개행을 그대로 담는다
    body=body bm ch
    gsub(/[\t\r]/," ",body); gsub(/  +/," ",body); sub(/^ /,"",body); sub(/ $/,"",body)
    out("heredoc\t<heredoc>\t" body)
    if (sr) { pc=pc pm pch; if (SUBFLAT) { gsub(RSB," ",pc); gsub(USB," ",pc) }   # P-C 그룹: heredoc 레코드 뒤, P-B 앞. MASKED 는 평탄 body 앞 8192자(maskstr 제곱 비용 회피)
      out("push\t<<\t<<"); out("sub\t" maskstr(substr(body,1,8192)) "\t" pc); out("pop\t)\t)") }   # push 줄의 MASKED·RAW 가 << = 본문 스크립트 묶음(명령 치환과 달리 그 출력을 앞 명령이 실행하지 않는다 — guard-destructive gd_pipe_shell)
    if (pb) { if (PBST!=0) pb_push()   # 끝까지 안 닫힌 치환도 담는다(종료 토큰이 열린 치환을 이긴다)
      for (i2=1;i2<=NPB;i2++) { out("push\t(\t("); out(subrecb(PBG[i2])); out("pop\t)\t)") }   # P-B 그룹: 각 치환을 최상위 $() 처럼 재파싱하도록 sub 로(소비자가 재파싱)
      if (PBOV) PBX=1   # 병적으로 크거나 많은 치환: 다 분석하지 못함 — overflow 는 맨 끝에 내되 입력은 계속 읽는다(R7: 뒤 명령도 판정)
      NPB=0 } }
  nh=0 }
END { if (mode=="tokseg") { if (TRUNC) print "__SP_TRUNC__"; exit }
  if (mode=="tokens") { tokens(S); exit }
  if (mode=="words") { n=splitwords(S,W); for (i=1;i<=n;i++) print unq(W[i]); exit }
  if (mode=="git") { gitcmd(S); exit }
  q=""; depth=0; nh=0; nw=0; wr=""; wm=""; inw=0; cont=0; SSV[1]=0; DEFN[0]=0; WB=0; WOV=0; WBX=0; WDP=0; WW=0; WPC=0; WCUT=0; GPIPE=0; PBX=0
  for (li=1;li<=nl && !WOV;li++) { L=LN[li]; n=length(L); I=1   # R6: 세그먼트 순번(SGC)은 줄마다 되돌리지 않는다 — 줄 잇기(\)·여러 줄 따옴표 뒤에 끝나는 세그먼트가 앞 줄의 값을 읽지 않게
    if (q!="" && li>1 && !cont) wr=wr "\n"
    cont=0
    while (I<=n) { if (WOV) break; c=substr(L,I,1)
      if ((inw || q!="") && ++WPC>WPMAX) { WOV=1; WCUT=1; break }   # R5: 단어 조각 상한(WPMAX) — 단어 수 상한과 같다(그 세그먼트는 버리고 나머지는 END 가 마무리, overflow 는 맨 끝)
      if (q=="'") { e=fnd(RE_SQ); if (!e) { wr=wr substr(L,I); I=n+1; continue } wr=wr substr(L,I,e-I+1); wm=wm "'"; q=""; I=e+1; continue }
      if (q=="A") { e=fnd(RE_AN); if (!e) { wr=wr substr(L,I); I=n+1; continue } wr=wr substr(L,I,e-I); I=e; c=substr(L,I,1)
        if (c=="\\") { if (I==n) { cont=1; I++ } else { wr=wr substr(L,I,2); I+=2 } continue }
        wr=wr c; wm=wm "'"; q=""; I++; continue }
      if (q=="\"") { e=fnd(RE_DQ); if (!e) { wr=wr substr(L,I); I=n+1; continue } wr=wr substr(L,I,e-I); I=e; c=substr(L,I,1); c2=substr(L,I+1,1)
        if (c=="\\") { if (I==n) { cont=1; I++ } else { wr=wr c c2; I+=2 } continue }
        if (c=="\"") { wr=wr c; wm=wm c; q=""; I++; continue }
        if (c=="$" && c2=="(") { push("sub",PH); I+=2; continue }
        if (c=="`") { push("bt",PH); I++; continue }
        wr=wr c; I++; continue }
      c2=substr(L,I+1,1)
      if (c==" " || c=="\t" || c=="\r") { endword(); I++; continue }
      if (c=="\\") { if (I==n) { cont=1; I++ } else { addc(c c2,c c2); I+=2 } continue }
      if (c=="#" && !inw) { I=n+1; continue }
      if (c==";") { endseg(); I+=(c2==";")?2:1; continue }
      if (c=="|") { GPIPE=(c2=="|")?0:1; endseg(); GPIPE=0; I+=(c2=="|" || c2=="&")?2:1; continue }   # R6: | · |& 는 다음 세그먼트로 파이프(SEGPIP), || 는 아님
      if (c=="&") { if (c2=="&") { endseg(); I+=2; continue }
        pc=substr(L,I-1,1)
        if (c2==">" || c2=="<") { redirstart(); addc(c,c); I++; continue }
        if (pc==">" && c2=="|") { addc("&|","&|"); I+=2; continue }   # zsh 의 >&|(덮어쓰기 강제 >&)는 파이프가 아니다
        if (pc==">" || pc=="<") { addc(c,c); I++; continue }
        endseg(); I++; continue }
      if (c=="$" && c2=="(") { push("sub",PH); I+=2; continue }
      if ((c=="<" || c==">") && c2=="(") { redirstart(); push("sub",c "(\342\200\246)"); I+=2; continue }
      if (c=="$" && c2=="'") { q="A"; addc("$'","$'Q"); I+=2; continue }
      if (c=="`") { if (depth>0 && STY[depth]=="bt") pop(); else push("bt",PH); I++; continue }
      if (c=="(") { endseg(); push("par",""); I++; continue }
      if (c==")") { if (depth>0 && STY[depth]!="bt") pop(); else endseg(); I++; continue }
      if ((c=="{" || c=="}") && !inw && isws(c2)) { endseg(); I++; continue }
      if (c=="<" && c2=="<") { if (substr(L,I+2,1)=="<") { redirstart(); addc("<<<","<<<"); I+=3 } else hdoc(); continue }
      if (c==">" && c2=="|") { redirstart(); addc(">|",">|"); I+=2; continue }   # >|(noclobber 무시 쓰기)는 리디렉션이다(A)
      if (c=="<" || c==">") { redirstart(); addc(c,c); I++; continue }
      if (c=="'" || c=="\"") { q=c; addc(c,c "Q"); I++; continue }
      e=fnd(RE_RUN)
      if (!e) { addc(substr(L,I),substr(L,I)); I=n+1; continue }
      if (e==I) { addc(c,c); I++; continue }
      addc(substr(L,I,e-I),substr(L,I,e-I)); I=e }
    if (WOV) break
    if (cont || q!="") continue
    endseg(); if (nh) readheredocs() }
  if (WCUT) { nw=0; inw=0; wr=""; wm=""; SSV[depth+1]=0 }   # R5: 단어·조각 상한에 걸려 읽다 만 세그먼트는 내지 않는다(R·M 과 push 가 모은 앞 단어를 버린다 — 그 세그먼트를 잇는 join 이 BWK 에서 제곱 비용). 그 안에서 이미 닫힌 치환 묶음은 endseg 가 낸다
  while (depth>0) pop()               # 상한을 넘었어도(WOV) 읽은 부분은 입력이 여기서 끝난 것처럼 마무리한다(R5: 열린 치환·서브셸 안의 줄, 그 바깥 세그먼트, 미룬 묶음, env -S 묶음을 버리지 않는다)
  endseg(); if (nh) readheredocs()
  printf "%s", XEND
  if (WOV || PBX) printf "overflow\t\t\n" }   # overflow 는 맨 끝에 한 번(R5: 예전엔 END 마무리에서 상한을 넘으면 env -S 묶음이 overflow 뒤에 나왔다)
AWK

# 라운드 3 awk 함수(컨테이너 런타임·접두 래퍼·셸 문자열 실행기). heredoc 을 read 로 읽는 것보다 빠르도록 작은따옴표 문자열로
# 덧붙이고(bash 3.2 의 read -d 는 한 바이트씩 읽는다) 안에는 작은따옴표·주석을 쓰지 않는다(awk 가 호출마다 프로그램을 읽으므로 짧게).
#   segbegin            처음 필요할 때 한 번(sp_segments 전용): -v sptbl(이름|값 옵션|불리언 옵션|…)을 " 옵션 " 문자열 표 SVS·SBS 로(index 로 찾는다).
#                       pmrun·ncrun 은 dkrun(docker run) 에, pmexec·ncexec 는 dkexec 에 더한다.
#   sskip(t,k)          엄격한 옵션 건너뛰기: 첫 위치 인수의 위치(없으면 nw+1). 표에 없는 옵션, 따옴표 없는 $변수(옵션 여러 개로
#                       펼쳐질 수 있다), 공백이 든 옵션 이름이면 0(벗기지 않음). 묶음(-it -eA=1 -itv x)의 값 글자는 뒤 글자나 다음
#                       단어를 값으로 먹는다. SEEN 에 본 옵션, EPW 에 --entrypoint 단어 위치.
#   ctrrun(w,k)         docker run·docker container exec|run·podman·nerdctl [container] exec|run·docker-compose exec|run →
#                       이미지·컨테이너·서비스 단어 위치(0 = 벗기지 않음; docker exec 는 containerexec 가 맡는다).
#   bwrap(w,k)          접두 래퍼 → 안쪽 명령 첫 단어 위치(0 = 벗기지 않음): mise exec|x … -- 명령, runuser -u 사용자 [--] 명령,
#                       flock·chrt(숫자 우선순위)·taskset(CPU 마스크)·chroot·script 는 명령 앞 위치 인수 1개. flock 파일 -c 는 0.
#                       따옴표·역슬래시 친 "--" · "-c" · "--command" 도 같다(uqt).
#   bopen               래퍼·런타임 줄을 그대로 기억(B 묶음의 앞뒤 줄).
#   xsubs3(k,h)         flock 파일 -c · mise exec -c · script -c · runuser -c · su -lc/--command(맨 -c 는 subcmd)의 문자열 묶음 수.
#   getoptc(k,bl,vl,dd) getopt 식 -c 문자열(-c x · -lc x · -cx · --command x · --command=x). bl 불리언 글자, vl 값 글자.
#                       dd(su·runuser)면 -- 뒤 인수는 사용자의 셸이 받으므로(su -- app -lc x) 거기서 셸 -c 묶음을 찾는다.
SP_AWK=$SP_AWK'
function segbegin(  P,n,i) { TB=1
  n=split(sptbl,P,"|"); for (i=1;i+2<=n;i+=3) { SVS[P[i]]=" " P[i+1] " "; SBS[P[i]]=" " P[i+2] " " }
  SVS["pmrun"]=SVS["dkrun"] SVS["pmrun"]; SBS["pmrun"]=SBS["dkrun"] SBS["pmrun"]; SVS["ncrun"]=SVS["dkrun"] SVS["ncrun"]; SBS["ncrun"]=SBS["dkrun"] SBS["ncrun"]
  SVS["pmexec"]=SVS["dkexec"] SVS["pmexec"]; SBS["pmexec"]=SBS["dkexec"]; SVS["ncexec"]=SVS["dkexec"]; SBS["ncexec"]=SBS["dkexec"] }
function sskip(t,k,  w,x,n,i,c) { SEEN=" "; EPW=0
  while (k<=nw) { w=M[k]
    if (w ~ /^[$][A-Za-z_{0-9@*#?!-]/) return 0
    if (w ~ /["\\]/ || index(w,RE_SQ)) w=unq(R[k])
    if (w=="--") return k+1
    if (w !~ /^-./) return k
    if (w ~ /^--/) { x=w; sub(/=.*/,"",x); if (x ~ /[ \t]/) return 0
      SEEN=SEEN x " "; if (x=="--entrypoint") EPW=k
      if (index(SVS[t]," " x " ")) { k+=(index(w,"=")?1:2); continue }
      if (index(SBS[t]," " x " ")) { k++; continue }
      return 0 }
    n=length(w)
    for (i=2;i<=n;i++) { c="-" substr(w,i,1); SEEN=SEEN c " "
      if (index(SBS[t]," " c " ")) continue
      if (index(SVS[t]," " c " ")) { if (i==n) k++; break }
      return 0 }
    k++ }
  return k }
function ctrrun(w,k,  t,j,v) {
  if (w=="docker") t="dk"; else if (w=="podman") t="pm"; else if (w=="nerdctl") t="nc"; else if (w=="docker-compose") t="dc"; else return 0
  if (!TB) segbegin()
  j=sskip(t "g",k+1); if (j<1 || j>nw) return 0
  v=M[j]
  if (v=="container" && t!="dc") { j++; v=M[j] } else if (t=="dk" && v=="exec") return 0
  if (v!="exec" && v!="run") return 0
  j=sskip(t v,j+1); if (j<1 || j>nw) return 0
  return j }
function bwrap(w,k,  p,j) {
  if (w=="mise") { if (M[k+1]!="exec" && M[k+1]!="x") return 0
    for (j=k+2;j<nw;j++) { if (uqt(j)=="--") return j+1; if (uqt(j) ~ /^(-c|--command)/) return 0 }
    return 0 }
  if (w ~ /[ \t]/ || !index(" flock caffeinate chrt ionice taskset setsid unbuffer chroot script unshare systemd-run runuser "," " w " ")) return 0
  if (!TB) segbegin()
  p=sskip(w,k+1); if (p<1 || p>nw) return 0
  if (w=="runuser" && !index(SEEN," -u ") && !index(SEEN," --user ")) return 0
  if (index(" flock chrt taskset chroot script "," " w " ")) {
    if ((w=="chrt" && M[p] !~ /^[0-9]+$/) || (w=="taskset" && M[p] !~ /^(0[xX])?[0-9A-Fa-f,-]+$/)) return 0; p++ }
  if (p>nw) return 0
  if (w=="flock" && (uqt(p)=="-c" || uqt(p)=="--command")) return 0
  return p }
function bopen(k,s,x,a) { bk=k; BKM=join(M,k,nw); BKR=join(R,k,nw); bkind="cmd" (s?"+sudo":"") (x?"+xargs":""); basg=a }
function xsubs3(k,h,  j) {
  if (h=="flock") { if (!TB) segbegin(); j=sskip("flock",k+1); if (j>0 && j+2<=nw && (uqt(j+1)=="-c" || uqt(j+1)=="--command")) return xsub(unq(R[j+2])); return 0 }
  if (h=="mise") { if (M[k+1]=="exec" || M[k+1]=="x") return xsub(getoptc(k+2,"qvy","jCE")); return 0 }
  if (h=="script") return xsub(getoptc(k+1,"adeFfkqr","EIOBTmo"))
  if (h=="runuser") return xsub(getoptc(k+1,"flmpP","gGsuw",1))
  if (h=="su") { for (j=k+1;j<nw;j++) if (uqt(j)=="-c") return 0; return xsub(getoptc(k+1,"flmpP","gGsw",1)) }
  return 0 }
function getoptc(k,bl,vl,dd,  j,w,i,n,c) {
  for (j=k;j<=nw;j++) { w=uqt(j)
    if (w=="--") { if (!dd) return ""
      for (j++;j<nw;j++) if (uqt(j) ~ /^-[A-Za-z]*c[A-Za-z]*$/) { j=shstr(j,nw); return j?unq(R[j]):"" }
      return "" }
    if (w=="--command" || w=="-c") return (j<nw)?unq(R[j+1]):""
    if (w ~ /^--command=/) return unq(substr(R[j],index(R[j],"=")+1))
    if (w !~ /^-[^-]/) continue
    n=length(w)
    for (i=2;i<=n;i++) { c=substr(w,i,1)
      if (c=="c") { if (i<n) return (w==M[j])?unq(substr(R[j],i+1)):substr(w,i+1); return (j<nw)?unq(R[j+1]):"" }
      if (index(vl,c)) { if (i==n) j++; break }
      if (!index(bl,c)) break } }
  return "" }
'
# 라운드 3 옵션 표: 이름|값을 받는 옵션|불리언 옵션|… (표에 없는 옵션이 나오면 벗기지 않는다 — 인수 개수를 모르면 오늘 출력 그대로).
# dkrun 은 docker run·docker container run 이고 pmrun·ncrun 은 그 위에 더한다(segbegin). exec 표도 같다.
SP_R3_TBL='dkg|--config -c --context -H --host -l --log-level --tlscacert --tlscert --tlskey|-D --debug --tls --tlsverify'\
'|dkrun|--add-host --annotation -a --attach --blkio-weight --blkio-weight-device --cap-add --cap-drop --cgroup-parent --cgroupns --cidfile --cpu-count --cpu-percent --cpu-period --cpu-quota --cpu-rt-period --cpu-rt-runtime -c --cpu-shares --cpus --cpuset-cpus --cpuset-mems --detach-keys --device --device-cgroup-rule --device-read-bps --device-read-iops --device-write-bps --device-write-iops --dns --dns-opt --dns-option --dns-search --domainname --entrypoint -e --env --env-file --expose --gpus --group-add --health-cmd --health-interval --health-retries --health-start-interval --health-start-period --health-timeout -h --hostname --io-maxbandwidth --io-maxiops --ip --ip6 --ipc --isolation --kernel-memory -l --label --label-file --link --link-local-ip --log-driver --log-opt --mac-address -m --memory --memory-reservation --memory-swap --memory-swappiness --mount --name --network --net --network-alias --net-alias --oom-score-adj --pid --pids-limit --platform -p --publish --pull --restart --runtime --security-opt --shm-size --stop-signal --stop-timeout --storage-opt --sysctl --tmpfs --ulimit -u --user --userns --uts -v --volume --volume-driver --volumes-from -w --workdir'\
'|-d --detach --disable-content-trust --init -i --interactive --no-healthcheck --oom-kill-disable -P --publish-all --privileged -q --quiet --read-only --rm --sig-proxy -t --tty --use-api-socket'\
'|dkexec|--detach-keys -e --env --env-file -u --user -w --workdir|-d --detach -i --interactive --privileged -t --tty'\
'|pmg|--cdi-spec-dir --cgroup-manager --config --conmon -c --connection --events-backend --hooks-dir --identity --imagestore --log-level --module --network-cmd-path --network-config-dir --out --root --runroot --runtime --runtime-flag --ssh --storage-driver --storage-opt --tmpdir --url --volumepath|-r --remote --syslog --transient-store --noout'\
'|pmrun|--arch --authfile --cert-dir --cgroup-conf --cgroups --chrootdirs --conmon-pidfile --creds --decryption-key --env-merge --gidmap --group-entry --health-log-destination --health-max-log-count --health-max-log-size --health-on-failure --health-startup-cmd --health-startup-interval --health-startup-retries --health-startup-success --health-startup-timeout --hostuser --image-volume --init-path --os --passwd-entry --personality --pidfile --pod --pod-id-file --preserve-fd --preserve-fds --rdt-class --requires --retry --retry-delay --sdnotify --seccomp-policy --secret --shm-size-systemd --subgidname --subuidname --systemd --timeout --timezone --uidmap --umask --unsetenv --variant'\
'|--env-host --http-proxy --no-hosts --passwd --read-only-tmpfs --replace --rmi --rootfs --tls-verify --unsetenv-all'\
'|pmexec|--preserve-fd --preserve-fds|'\
'|ncg|-a --address -H --host -n --namespace --snapshotter --storage-driver --cni-path --cni-netconfpath --data-root --cgroup-manager --hosts-dir --host-gateway-ip --bridge-ip|--debug --debug-full --insecure-registry --experimental --kube-hide-dupe'\
'|ncrun|--pidfile --umask --verify --cosign-key --ipfs-address|--rootfs'\
'|dcg|-f --file -p --project-name --profile -c --context --env-file --project-directory --ansi -H --host --log-level --tlscacert --tlscert --tlskey --parallel --progress|--verbose --no-ansi --tls --tlsverify --skip-hostname-check --compatibility --dry-run --all-resources'\
'|dcexec|-u --user --index -e --env -w --workdir|-d --detach --privileged -T --no-TTY --no-tty -i --interactive -t --tty --dry-run'\
'|dcrun|--name --entrypoint -e --env --env-from-file -l --label -u --user -p --publish -v --volume -w --workdir --cap-add --cap-drop --pull|-d --detach --no-deps --rm --service-ports --use-aliases -T --no-TTY --no-tty -i --interactive -t --tty --build --remove-orphans --quiet-pull --quiet-build --dry-run'\
'|flock|-w --wait --timeout -E --conflict-exit-code|-s --shared -x -e --exclusive -u --unlock -n --nb --nonblock -o --close -F --no-fork --verbose'\
'|caffeinate|-t -w|-d -i -m -s -u'\
'|chrt|-T -P -D --sched-runtime --sched-period --sched-deadline|-a -b -d -f -i -o -r -R -v --all-tasks --batch --deadline --fifo --idle --other --rr --reset-on-fork --verbose'\
'|ionice|-c -n --class --classdata|-t --ignore'\
'|taskset||-a -c --all-tasks --cpu-list'\
'|setsid||-c -f -w --ctty --fork --wait'\
'|unbuffer||-p'\
'|chroot|-G -g -u --groups --userspec|--skip-chdir'\
'|script|-E -B -I -O -T -m -o --echo --log-io --log-in --log-out --log-timing --logging-format --output-limit|-a -d -e -F -f -k -q -r --append --return --flush --force --quiet'\
'|unshare|-R -w -S -G --propagation --setgroups --root --wd --setuid --setgid --monotonic --boottime --map-user --map-group --map-users --map-groups|-m -u -i -n -p -U -C -T -f -r -c --mount --uts --ipc --net --pid --user --cgroup --time --fork --map-root-user --map-current-user --map-auto --kill-child --mount-proc --keep-caps'\
'|systemd-run|-u --unit -p --property --description --slice --uid --gid --nice --working-directory -E --setenv --on-active --on-boot --on-startup --on-unit-active --on-unit-inactive --on-calendar --timer-property --path-property --socket-property --service-type -H --host -M --machine|--user --system --scope -r --remain-after-exit --send-sighup -t --pty -P --pipe -q --quiet --wait -G --collect --no-block --no-ask-password -d --same-dir'\
'|runuser|-u --user -g --group -G --supp-group -s --shell -w --whitelist-environment|-f --fast -l --login -m -p --preserve-environment -P --pty'

# sp_varrefs 전용 awk(guard-secrets 의 env-secret 판정; F6). 공용 SP_AWK 와 분리해 다른 가드의 awk 호출에는 영향이 없다.
# 다음 특수 문자는 512자 창의 match 로 찾는다(문자 단위 substr 은 BWK awk 에서 2차 비용).
IFS= read -r -d '' SP_AWK_VARS <<'AWK' || :
function vfind(s,i,n,re,  w) { while (i<=n) { w=substr(s,i,512); if (match(w,re)) return i+RSTART-1; i+=512 } return 0 }
function vref(s,i,cx,  r,op) { r=substr(s,i+1,512)
  if (match(r,/^[A-Za-z_][A-Za-z0-9_]*/)) { print substr(r,1,RLENGTH) "\t$\t" cx; return i+1+RLENGTH }
  if (match(r,/^[{]#[A-Za-z_][A-Za-z0-9_]*/)) { print substr(r,3,RLENGTH-2) "\tlen\t" cx; return i+1+RLENGTH }
  if (match(r,/^[{][A-Za-z_][A-Za-z0-9_]*/)) { op=substr(r,RLENGTH+1,1); if (op==":") op=op substr(r,RLENGTH+2,1)
    print substr(r,2,RLENGTH-1) "\t" op "\t" cx; return i+1+RLENGTH }
  return i+1 }
function varrefs(s,  i,n,c,q,e) { n=length(s); i=1; q=""
  while (i<=n) {
    if (q=="'") { e=vfind(s,i,n,RE_VS); if (!e) return; if (substr(s,e,1)=="'") { q=""; i=e+1 } else i=vref(s,e,"s"); continue }
    if (q=="A") { e=vfind(s,i,n,RE_VA); if (!e) return; c=substr(s,e,1)
      if (c=="\\") i=e+2; else if (c=="'") { q=""; i=e+1 } else i=vref(s,e,"s"); continue }
    e=vfind(s,i,n,RE_VQ); if (!e) return; c=substr(s,e,1)
    if (c=="\\") { i=e+2; continue }
    if (c=="\"") { q=(q=="\"")?"":"\""; i=e+1; continue }
    if (c=="'") { if (q=="") q="'"; i=e+1; continue }
    if (q=="" && substr(s,e+1,1)=="'") { q="A"; i=e+2; continue }
    i=vref(s,e,"e") } }
BEGIN { RE_VS="['$]"; RE_VA="['$\\\\]"; RE_VQ="[$\\\\\"']" }
{ S=S (NR>1?"\n":"") $0 }
END { varrefs(S) }
AWK

sp_segments()     { printf '%s\n' "$1" | LC_ALL=C awk -v sptbl="$SP_R3_TBL" -v wbmax="${SP_WBMAX:-}" -v subflat="${SP_SUBFLAT:-}" "$SP_AWK"; }
sp_tokens()       { printf '%s\n' "$1" | LC_ALL=C awk -v mode=tokens "$SP_AWK"; }
sp_tokens_lines() {  # <text> [keep-empty] [tokmax] — keep-empty 가 아니면 awk 호출도 출력도 기존과 같다(다른 가드 영향 없음).
  # tokmax(R5): 토큰 수 상한 — 넘으면 상한에 닿은 줄까지만(그 줄의 __SP_SEG__ 까지) 내고 마지막 줄에 __SP_TRUNC__(가드는 그 뒤 세그먼트를 버리고 too-complex). 비우면 상한 없음
  if [ "${2:-}" = keep-empty ]; then printf '%s\n' "$1" | LC_ALL=C awk -v mode=tokseg -v keepempty=1 -v tokmax="${3:-}" "$SP_AWK"
  else printf '%s\n' "$1" | LC_ALL=C awk -v mode=tokseg -v tokmax="${3:-}" "$SP_AWK"; fi
}
sp_words()        { printf '%s\n' "$1" | LC_ALL=C awk -v mode=words "$SP_AWK"; }
sp_varrefs()      { printf '%s\n' "$1" | LC_ALL=C awk "$SP_AWK_VARS"; }
sp_head() {
  local __o=$-
  set -f; set -- $1
  case $__o in *f*) ;; *) set +f ;; esac
  printf '%s\n' "${1:-}"
}
sp_git_subcmd() {
  local __o
  __o=$(printf '%s\n' "$1" | LC_ALL=C awk -v mode=git "$SP_AWK")
  [ -n "$__o" ] || return 1
  printf '%s\n' "$__o"
}
