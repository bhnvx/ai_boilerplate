#!/usr/bin/env bash
# lib/shellparse.sh — 셸 명령 경량 파서 (POSIX awk 1개; macOS BWK awk / gawk / mawk 공통, gawk 확장 없음)
# API (모두 awk 1회 fork):
#   sp_segments "<command>"    → 줄마다 KIND<TAB>MASKED<TAB>RAW
#       KIND: cmd | cmd+sudo | cmd+xargs | cmd+sudo+xargs | sub | heredoc | assign | envfile | push | pop  (case 는 cmd* 로 받을 것)
#       assign 줄은 같은 세그먼트의 선두 대입(HUSKY=0 등)을 담고 cmd 줄 바로 앞에 온다.
#       envfile 줄은 벗겨 낸 러너 접두(uv run / docker compose run|exec …)의 --env-file 값으로, cmd 줄 바로 앞에 온다(G3).
#       sub 줄은 sh -c / eval / ssh / su -c 의 내부 문자열(따옴표 1단계 제거)로 cmd 줄 뒤에 온다(깊이 1).
#       heredoc 줄: MASKED=<heredoc>, RAW=본문(개행→공백, 64KB 에서 절단). << 를 가진 줄의 마지막 세그먼트 뒤에 온다.
#       push/pop 줄은 서브셸 ( … ) 과 명령 치환 $( … ) · `…` · <( … ) 의 경계다(G10). 명령 치환은 부모 세그먼트를
#       끊지 않고 그 자리에 자리표시 단어 $(…) 를 남기며, 내부 명령은 부모 줄 뒤에 push … pop 으로 이어 나온다(G1).
#       kubectl exec 는 원본 세그먼트와 내부 명령 세그먼트를 둘 다 cmd 로 낸다.
#       머리 단어는 따옴표·역슬래시를 벗긴 RAW 기준이며, 위험 명령·출력 명령 이름은 소문자로 정규화한다(G7; macOS 는 대소문자 무시).
#   sp_tokens "<raw>"          → 줄마다 토큰(따옴표 제거, KEY=VALUE → KEY= 와 VALUE, 선두 @ 제거, host:path → path 도 추가;
#                                 따옴표 밖의 < > 에서 단어를 끊되 2> &> >> << <<< >& 는 다음 단어의 접두로 둔다; G15)
#   sp_tokens_lines "<text>"   → 입력 줄마다 그 줄의 토큰들 뒤에 __SP_SEG__ 한 줄(따옴표 상태가 줄을 넘지 않음; C1)
#   sp_words "<raw>"           → 줄마다 단어(따옴표만 제거, 추가 규칙 없음)
#   sp_head "<masked>"         → 첫 단어
#   sp_git_subcmd "<raw>"      → git_dir<TAB>subcommand<TAB>rest(원문, 따옴표 유지); git 이 아니면 출력 없음·반환 1
# 성능: 문자 단위 substr/연결은 긴 입력에서 2차 비용이므로(BWK awk 의 substr 은 매번 strlen) 줄 단위로 처리하고
#       따옴표 구간·일반 단어는 index/match 로 한 번에 복사한다(G6). 200KB heredoc 도 선형에 가깝다.

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
function splitwords(s,W,  i,n,c,w,cnt,e) { n=length(s); w=""; cnt=0; i=1
  while (i<=n) { c=substr(s,i,1)
    if (c==" " || c=="\t" || c=="\n" || c=="\r") { if (w!="") W[++cnt]=w; w=""; i++; continue }
    if (c=="'") { e=index(substr(s,i+1),"'"); if (e==0) { w=w substr(s,i); break } w=w substr(s,i,e+1); i+=e+1; continue }
    if (c=="$" && substr(s,i+1,1)=="'") { e=i; i+=2; while (i<=n) { c=substr(s,i,1); i++; if (c=="\\") i++; else if (c=="'") break } w=w substr(s,e,i-e); continue }
    if (c=="\"") { e=i; i++; while (i<=n) { if (!match(substr(s,i),/["\\]/)) { i=n+1; break } i+=RSTART-1; c=substr(s,i,1); i++; if (c=="\"") break; i++ } w=w substr(s,e,i-e); continue }
    if (c=="\\") { w=w substr(s,i,2); i+=2; continue }
    if (c=="<" || c==">") { if (w!="" && w !~ /^[0-9]*$/ && w !~ /^[<>&|]+$/) { W[++cnt]=w; w="" } w=w c; i++; continue }
    if (!match(substr(s,i),/[ \t\n\r'"\\<>$]/)) { w=w substr(s,i); break }
    if (RSTART==1) { w=w c; i++; continue }
    w=w substr(s,i,RSTART-1); i+=RSTART-1 }
  if (w!="") W[++cnt]=w; return cnt }
function join(A,a,b,  s,i) { s=""; for (i=a;i<=b;i++) if (A[i]!="") s=s (s==""?"":" ") A[i]; gsub(/[\t\n\r]/," ",s); return s }
function flat(s) { gsub(/[\t\n\r]/," ",s); return s }
function tokens(s,  W,n,i,t,k,p) { n=splitwords(s,W)
  for (i=1;i<=n;i++) { t=unq(W[i]); if (t=="") continue
    if (match(t,/^-*[A-Za-z_][A-Za-z0-9_-]*=/)) { print substr(t,1,RLENGTH); t=substr(t,RLENGTH+1); if (t=="") continue }
    if (substr(t,1,1)=="@") t=substr(t,2)
    print t; k=index(t,":")
    if (k>1 && index(substr(t,1,k-1),"/")==0 && substr(t,k+1,2)!="//") { p=substr(t,k+1); if (p ~ "^[~/.]") print p } } }
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
  POS["timeout"]=1; PH="$(\342\200\246)"
  RE_SQ="'"; RE_AN="['\\\\]"; RE_DQ="[\"\\\\$`]"; RE_RUN="[ \t\r;&|()<>`\"'\\\\$#{}]" }
mode=="tokseg" { tokens($0); print "__SP_SEG__"; next }
mode!="" { S=S (NR>1?"\n":"") $0; next }
{ LN[NR]=$0; nl=NR }
function out(s) { if (depth>0) PEND[depth]=PEND[depth] s "\n"; else printf "%s\n", s }
function outblk(b) { if (depth>0) PEND[depth]=PEND[depth] b; else printf "%s", b }
function skipopts(name,k) { while (k<=nw && M[k] ~ /^-/) { if (M[k]=="--") return k+1
    if ((name,M[k]) in VAL) { if (M[k] ~ /^--env[-_]?file$/) ENVF[++nenvf]=unq(R[k+1]); k+=2 }
    else { if (M[k] ~ /^--env[-_]?file=./) ENVF[++nenvf]=unq(substr(R[k],index(R[k],"=")+1)); k++ } }
  return k }
function containerexec(w,k,  j) { j=skipopts(w,k+1)
  if (w=="kubectl") { if (M[j]!="exec") return k; j=skipopts("kexec",j+1); j=skipopts("kexec",j+1); return j }
  if (M[j]=="compose") { j=skipopts("compose",j+1); if (M[j]!="run" && M[j]!="exec") return k; return skipopts("dexec",j+1)+1 }
  if (M[j]=="exec") return skipopts("dexec",j+1)+1
  return k }
function subcmd(k,  h,j,s) { h=M[k]; s=""
  if (h=="sh" || h=="bash" || h=="zsh" || h=="dash" || h=="ksh" || h=="mksh") {
    for (j=k+1;j<nw;j++) if (M[j] ~ /^-[A-Za-z]*c[A-Za-z]*$/) { s=unq(R[j+1]); break } }
  else if (h=="su") { for (j=k+1;j<nw;j++) if (M[j]=="-c") { s=unq(R[j+1]); break } }
  else if (h=="eval") { for (j=k+1;j<=nw;j++) s=s (s==""?"":" ") unq(R[j]) }
  else if (h=="ssh") { j=skipopts("ssh",k+1); for (j++;j<=nw;j++) s=s (s==""?"":" ") unq(R[j]) }
  return flat(s) }
function process(  k,k2,w,w2,h,sudo,xargs,asg,kind,sc,dup,j) { sudo=0; xargs=0; asg=""; k=1; dup=0; nenvf=0
  while (k<=nw) { w=M[k]
    if (w in KW) { k++; continue }
    if (w ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) { asg=asg (asg==""?"":" ") R[k]; k++; continue }
    h=unq(R[k]); if (h=="") { k++; continue }
    if (h!=w) { M[k]=h; R[k]=h; w=h }
    w2=tolower(w); if (w2!=w && ((w2 in LOWH) || w2 ~ /^mkfs\./)) { M[k]=w2; R[k]=w2; w=w2 }
    if (match(w,/^(\/usr\/local\/bin|\/opt\/homebrew\/bin|\/usr\/bin|\/usr\/sbin|\/bin|\/sbin)\//) && RLENGTH<length(w)) { M[k]=substr(w,RLENGTH+1); R[k]=substr(R[k],RLENGTH+1); continue }
    if (match(w,/^\/.*\/libexec\/gnubin\//) && RLENGTH<length(w)) { M[k]=substr(w,RLENGTH+1); R[k]=substr(R[k],RLENGTH+1); continue }
    if (w=="command" && (M[k+1]=="-v" || M[k+1]=="-V")) break
    if (w=="sudo" || w=="doas") sudo=1
    if (w=="xargs") xargs=1
    if (w in W1) { k2=skipopts(w,k+1); if (w in POS) k2+=POS[w]; if (k2>nw) break; k=k2; continue }
    w2=w " " M[k+1]
    if (w2 in W2) { k2=skipopts(w2,k+2); if (k2>nw) break; k=k2; continue }
    if (w=="docker" || w=="kubectl") { j=nenvf; k2=containerexec(w,k); if (k2<=k || k2>nw) { nenvf=j; break } if (w=="kubectl") dup=k; k=k2; continue }
    break }
  if (asg!="") out("assign\t" flat(asg) "\t" flat(asg))
  if (k>nw) return
  for (j=1;j<=nenvf;j++) out("envfile\t" flat(ENVF[j]) "\t" flat(ENVF[j]))
  kind="cmd" (sudo?"+sudo":"") (xargs?"+xargs":"")
  if (dup) out(kind "\t" join(M,dup,nw) "\t" join(R,dup,nw))
  out(kind "\t" join(M,k,nw) "\t" join(R,k,nw))
  sc=subcmd(k); if (sc!="") out("sub\t" maskstr(sc) "\t" sc) }
function addc(a,b) { wr=wr a; wm=wm b; inw=1 }
function endword() { if (inw) { R[++nw]=wr; M[nw]=wm } wr=""; wm=""; inw=0 }
function endseg() { endword(); if (nw>0) process(); split("",R); split("",M); nw=0; if (DEF[depth]!="") { outblk(DEF[depth]); DEF[depth]="" } }
function isws(c) { return c=="" || c==" " || c=="\t" || c=="\n" || c=="\r" || c==";" || c=="&" || c=="|" || c==")" }
function fnd(re,  p,w) { p=I; while (p<=n) { w=substr(L,p,512); if (match(w,re)) return p+RSTART-1; p+=512 } return 0 }
function redirstart() { if (inw && wr !~ /^[0-9]*$/ && wr !~ /^[<>&|]+$/) endword() }
function push(ty,ph,  j) { if (ph!="") { wr=wr ph; if (q=="") wm=wm ph; inw=1 }
  depth++; STY[depth]=ty; SQ[depth]=q; SNW[depth]=nw; SWR[depth]=wr; SWM[depth]=wm; SINW[depth]=inw
  for (j=1;j<=nw;j++) { SR[depth,j]=R[j]; SM[depth,j]=M[j] }
  split("",R); split("",M); nw=0; wr=""; wm=""; inw=0; q=""; PEND[depth]=""; DEF[depth]="" }
function pop(  d,b,j) { endseg(); d=depth; b=PEND[d]; depth--
  split("",R); split("",M); nw=SNW[d]; for (j=1;j<=nw;j++) { R[j]=SR[d,j]; M[j]=SM[d,j] }
  wr=SWR[d]; wm=SWM[d]; inw=SINW[d]; q=SQ[d]
  b="push\t(\t(\n" b "pop\t)\t)\n"
  if (nw==0 && !inw) outblk(b); else DEF[depth]=DEF[depth] b }
function hdoc(  t,c,dash) { redirstart(); I+=2; dash=0; if (substr(L,I,1)=="-") { dash=1; I++ }
  while (substr(L,I,1)==" " || substr(L,I,1)=="\t") I++
  t=""; while (I<=n) { c=substr(L,I,1); if (isws(c) || c=="<" || c==">") break; t=t c; I++ }
  hd[++nh]=unq(t); hds[nh]=dash; addc("<<" (dash?"-":"") t,"<<" (dash?"-":"") unq(t)) }
function readheredocs(  j,line,t,body,ch,cl) {   # 본문은 64줄 단위로 모아 붙인다(줄마다 붙이면 2차 비용; 1MB 에서 절단)
  for (j=1;j<=nh;j++) { body=""; ch=""; cl=0
    while (li<nl) { li++; line=LN[li]; t=line; if (hds[j]) sub(/^\t+/,"",t); if (t==hd[j]) break
      if (length(body)<1048576) { ch=ch " " line; if (++cl>=64) { body=body ch; ch=""; cl=0 } } }
    body=body ch
    gsub(/[\t\r]/," ",body); gsub(/  +/," ",body); sub(/^ /,"",body); sub(/ $/,"",body)
    out("heredoc\t<heredoc>\t" body) }
  nh=0 }
END { if (mode=="tokseg") exit
  if (mode=="tokens") { tokens(S); exit }
  if (mode=="words") { n=splitwords(S,W); for (i=1;i<=n;i++) print unq(W[i]); exit }
  if (mode=="git") { gitcmd(S); exit }
  q=""; depth=0; nh=0; nw=0; wr=""; wm=""; inw=0; cont=0
  for (li=1;li<=nl;li++) { L=LN[li]; n=length(L); I=1
    if (q!="" && li>1 && !cont) wr=wr "\n"
    cont=0
    while (I<=n) { c=substr(L,I,1)
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
      if (c=="|") { endseg(); I+=(c2=="|" || c2=="&")?2:1; continue }
      if (c=="&") { if (c2=="&") { endseg(); I+=2; continue }
        pc=substr(L,I-1,1)
        if (c2==">" || c2=="<") { redirstart(); addc(c,c); I++; continue }
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
      if (c=="<" || c==">") { redirstart(); addc(c,c); I++; continue }
      if (c=="'" || c=="\"") { q=c; addc(c,c "Q"); I++; continue }
      e=fnd(RE_RUN)
      if (!e) { addc(substr(L,I),substr(L,I)); I=n+1; continue }
      if (e==I) { addc(c,c); I++; continue }
      addc(substr(L,I,e-I),substr(L,I,e-I)); I=e }
    if (cont || q!="") continue
    endseg(); if (nh) readheredocs() }
  while (depth>0) pop()
  endseg(); if (nh) readheredocs() }
AWK

sp_segments()     { printf '%s\n' "$1" | LC_ALL=C awk "$SP_AWK"; }
sp_tokens()       { printf '%s\n' "$1" | LC_ALL=C awk -v mode=tokens "$SP_AWK"; }
sp_tokens_lines() { printf '%s\n' "$1" | LC_ALL=C awk -v mode=tokseg "$SP_AWK"; }
sp_words()        { printf '%s\n' "$1" | LC_ALL=C awk -v mode=words "$SP_AWK"; }
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
