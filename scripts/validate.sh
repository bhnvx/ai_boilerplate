#!/usr/bin/env bash
# dev_settings 하네스 검증 — 저장소(--repo) · 설치본(--installed) · 프로젝트(--project).
# 출력: "OK|WARN|FAIL|INFO <check>: <detail>" 줄들 + 마지막 줄 "요약: OK n · WARN n · FAIL n".
# 종료 코드: FAIL이 하나라도 있으면 1(--exit-zero면 0), 사용법 오류 2.
# python3 필요(JSON·스키마·훅·권한·스킬 검사). 없으면 jq로 JSON 파싱만 하고 bash -n은 항상 수행.
#
# usage: validate.sh [--repo [path] | --installed [--home <dir>] | --project <dir>]
#                    [--exit-zero] [--max-lines N] [--quiet]
#   인수 없음: 저장소의 scripts/validate.sh면 --repo, 설치본(skills/harness-check/)이면 --installed.
#   --installed와 --project는 함께 쓸 수 있다.
#   --quiet: OK 줄 숨김, --repo에서 merge-settings selftest·tests/run-all.sh 실행 생략.
#   DEV_SETTINGS_IN_TESTS=1: tests/run-all.sh 재귀 실행 방지(run-all.sh가 설정).
#   VALIDATE_NO_PYTHON=1: python3 없는 환경 흉내(대체 경로 테스트용).

VALIDATE_SCRIPT_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
VALIDATE_BASH=${BASH:-/bin/bash}
export VALIDATE_SCRIPT_DIR VALIDATE_BASH

if [ "${VALIDATE_NO_PYTHON:-0}" != 1 ] && command -v python3 >/dev/null 2>&1 \
   && python3 -c 'import json, sys' >/dev/null 2>&1; then
  exec python3 -I - "$@" <<'PYEOF'
import io, json, os, re, shlex, subprocess, sys
from fnmatch import fnmatchcase

if (getattr(sys.stdout, 'encoding', '') or '').lower().replace('-', '') != 'utf8':
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

SCRIPT_DIR = os.environ.get('VALIDATE_SCRIPT_DIR') or os.getcwd()
RUN_BASH = os.environ.get('VALIDATE_BASH') or '/bin/bash'
SYNTAX_BASH = '/bin/bash' if os.access('/bin/bash', os.X_OK) else RUN_BASH
DEVNULL = subprocess.DEVNULL
PIPE = subprocess.PIPE

SCHEMA_NAME = 'claude-code-settings.schema.json'
KNOWN_EXTRA_KEYS = {'modelSettings', 'modelPicker', 'additionalMarketplaces', 'autoCompactWindow', 'ultracode'}
EXTRA_EVENTS = {'PreModelSwitch', 'PostModelSwitch'}
FALLBACK_EVENTS = {
    'SessionStart', 'Setup', 'SessionEnd', 'InstructionsLoaded', 'UserPromptSubmit', 'UserPromptExpansion',
    'MessageDisplay', 'PreToolUse', 'PermissionRequest', 'PermissionDenied', 'PostToolUse', 'PostToolUseFailure',
    'PostToolBatch', 'Stop', 'StopFailure', 'TeammateIdle', 'SubagentStart', 'SubagentStop', 'TaskCreated',
    'TaskCompleted', 'Notification', 'ConfigChange', 'CwdChanged', 'DirectoryAdded', 'FileChanged',
    'WorktreeCreate', 'WorktreeRemove', 'PreCompact', 'PostCompact', 'Elicitation', 'ElicitationResult'}
PROMPT_EVENTS = {'PermissionDenied', 'PostToolBatch', 'PostToolUse', 'PostToolUseFailure', 'PreToolUse', 'Stop',
                 'SubagentStop', 'TaskCompleted', 'TaskCreated', 'TeammateIdle', 'UserPromptExpansion',
                 'UserPromptSubmit', 'PermissionRequest'}
HOOK_TYPES = ('command', 'http', 'mcp_tool', 'prompt', 'agent')
SESSION_TYPES = ('command', 'mcp_tool')
OUR_SKILLS = ('commit', 'review-diff', 'delegate', 'harness-check', 'harness-init', 'api', 'preflight')
OUR_AGENTS = ('explorer', 'implementer', 'reviewer')
OUR_RULES = ('core', 'git', 'security', 'web', 'subagent-policy')
RESERVED_SKILLS = {'synced', 'anthropic-skills', 'review', 'code-review', 'doctor', 'checkup', 'simplify',
                   'verify', 'loop', 'debug', 'batch', 'claude-api', 'init'}
AGENT_MODELS = {'sonnet', 'opus', 'haiku', 'fable', 'inherit'}
# install.sh가 설치 시 스킬 디렉터리에 넣는 파일(저장소에서는 원본 위치로 확인)
INSTALL_PROVIDED = {'harness-check': {'validate.sh': 'scripts/validate.sh',
                                      SCHEMA_NAME: 'schemas/' + SCHEMA_NAME}}
FALLBACK_RULE_RE = r'^(([A-Z][A-Za-z]+)(\([^)]+\))?|mcp__.*)$'
PERSONAL_RE = re.compile(r'(?:~|\$HOME|\$\{HOME\}|"\$HOME"|\\"\$HOME\\")/\.claude/'
                         r'|(?:^|[^A-Za-z0-9_./-])/(?:harness-init|harness-check|commit|preflight|review-diff|delegate)'
                         r'(?:[^A-Za-z0-9_-]|$)')
# 스킬 본문의 동적 컨텍스트 주입: 인라인 !`명령` 과 ```! 펜스 블록
INJECT_RE = re.compile(r'(?<![`\\])!`([^`\n]+)`')
FENCE_INJECT_RE = re.compile(r'^[ \t]*```!\s*\n(.*?)^[ \t]*```', re.M | re.S)
ASSIGN_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')
SKIP_DIRS = {'.git', 'node_modules', '.venv', '__pycache__'}

CTX = {'mode': None, 'root': None, 'home': None, 'claude_dir': None, 'project': None,
       'props': None, 'events': FALLBACK_EVENTS | EXTRA_EVENTS, 'rule_re': re.compile(FALLBACK_RULE_RE)}
EXEC_TARGETS = set()
ITEMS = []
DISP = []


def add(level, check, detail):
    ITEMS.append((level, check, ' | '.join(str(detail).splitlines())))


def ok(c, d): add('OK', c, d)
def warn(c, d): add('WARN', c, d)
def fail(c, d): add('FAIL', c, d)
def info(c, d): add('INFO', c, d)


def count(level):
    return sum(1 for i in ITEMS if i[0] == level)


def issues_since(mark):
    return sum(1 for i in ITEMS[mark:] if i[0] in ('WARN', 'FAIL'))


USAGE = ('usage: validate.sh [--repo [path] | --installed [--home <dir>] | --project <dir>] '
         '[--exit-zero] [--max-lines N] [--quiet]')


def die_usage(msg):
    sys.stderr.write('validate.sh: %s\n%s\n' % (msg, USAGE))
    sys.exit(2)


def parse_args(argv):
    o = {'repo': None, 'installed': False, 'home': None, 'project': None, 'project_empty': False,
         'exit_zero': False, 'max_lines': 0, 'quiet': False}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--repo':
            o['repo'] = ''
            if i + 1 < len(argv) and not argv[i + 1].startswith('--'):
                o['repo'] = argv[i + 1]
                i += 1
        elif a == '--installed':
            o['installed'] = True
        elif a in ('--home', '--project', '--max-lines'):
            if i + 1 >= len(argv):
                die_usage(a + ' 값 없음')
            v = argv[i + 1]
            i += 1
            if a == '--home':
                o['home'] = v
            elif a == '--project':
                if v == '':
                    o['project_empty'] = True
                else:
                    o['project'] = v
            else:
                if not v.isdigit():
                    die_usage('--max-lines 값은 숫자여야 함')
                o['max_lines'] = int(v)
        elif a == '--exit-zero':
            o['exit_zero'] = True
        elif a == '--quiet':
            o['quiet'] = True
        elif a in ('-h', '--help'):
            print(USAGE)
            sys.exit(0)
        else:
            die_usage('알 수 없는 인수: ' + a)
        i += 1
    if o['repo'] is not None and (o['installed'] or o['project'] or o['project_empty']):
        die_usage('--repo는 --installed/--project와 함께 쓸 수 없음')
    if o['repo'] is None and not o['installed'] and o['project'] is None:
        cand = os.path.normpath(os.path.join(SCRIPT_DIR, '..'))
        if os.path.isfile(os.path.join(cand, 'claude', 'global', 'settings.json')):
            o['repo'] = cand
        else:
            o['installed'] = True
    if o['repo'] == '':
        o['repo'] = os.path.normpath(os.path.join(SCRIPT_DIR, '..'))
    if o['repo']:
        o['repo'] = os.path.realpath(o['repo'])
    if o['home'] is None:
        o['home'] = os.environ.get('HOME') or os.path.expanduser('~')
    o['home'] = os.path.abspath(o['home'])
    if o['project']:
        o['project'] = os.path.realpath(o['project'])
    return o


def set_disp(pairs):
    DISP[:] = sorted(pairs, key=lambda p: -len(p[0]))


def disp(p):
    for pre, lab in DISP:
        if p == pre:
            return lab or '.'
        if p.startswith(pre + os.sep):
            rest = p[len(pre) + 1:]
            return lab + '/' + rest if lab else rest
    return p


def read_text(path, check):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return f.read()
    except (OSError, ValueError) as e:
        fail(check, '%s: 읽기 실패 (%s)' % (disp(path), getattr(e, 'strerror', None) or e))
        return None


def load_json(path):
    txt = read_text(path, 'json')
    if txt is None:
        return None
    dups = []

    def pairs_hook(pairs):
        d = {}
        for k, v in pairs:
            if k in d:
                dups.append(k)
            d[k] = v
        return d
    try:
        data = json.loads(txt, object_pairs_hook=pairs_hook)
    except ValueError as e:
        fail('json', '%s: line %s col %s — JSON 오류: %s (주석·끝 쉼표 불가, 엄격한 JSON만)'
             % (disp(path), getattr(e, 'lineno', '?'), getattr(e, 'colno', '?'), getattr(e, 'msg', e)))
        return None
    if dups:
        warn('json', '%s: 중복 키 %s (마지막 값만 적용)' % (disp(path), ', '.join(sorted(set(dups)))))
    return data


def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'':
        if v[0] == '"':
            try:
                return json.loads(v)
            except ValueError:
                pass
            return v[1:-1]
        return v[1:-1].replace("''", "'")
    m = re.match(r'^(.*?)\s+#.*$', v)
    return m.group(1) if m else v


def parse_flow_list(v):
    try:
        x = json.loads(v)
        if isinstance(x, list):
            return x
    except ValueError:
        pass
    inner = v.strip()[1:]
    inner = inner[:-1] if inner.endswith(']') else inner
    return [unquote(p) for p in inner.split(',') if p.strip()]


def parse_yaml_lite(lines):
    out = {}
    i = 0
    key_re = re.compile(r'^([A-Za-z_][A-Za-z0-9_-]*)\s*:(?:\s+(.*))?$')
    while i < len(lines):
        ln = lines[i]
        m = key_re.match(ln.rstrip())
        if not m:
            i += 1
            continue
        key, val = m.group(1), (m.group(2) or '').strip()
        if val in ('', '|', '>', '|-', '>-', '|+', '>+'):
            block = []
            j = i + 1
            while j < len(lines) and (lines[j][:1] in (' ', '\t') or not lines[j].strip()):
                block.append(lines[j])
                j += 1
            nonempty = [b.strip() for b in block if b.strip()]
            if val == '' and nonempty and all(b.startswith('- ') or b == '-' for b in nonempty):
                out[key] = [unquote(b[1:]) for b in nonempty]
            elif not nonempty:
                out[key] = None
            elif val.startswith('|'):
                out[key] = '\n'.join(nonempty)
            else:
                out[key] = ' '.join(nonempty)
            i = j
            continue
        out[key] = parse_flow_list(val) if val.startswith('[') else unquote(val)
        i += 1
    return out


def frontmatter(text):
    """(dict|None, body, error) — 첫 줄이 '---'일 때만 frontmatter로 본다."""
    lines = text.split('\n')
    if not lines or lines[0].strip() != '---':
        return None, text, None
    for i in range(1, len(lines)):
        if lines[i].strip() == '---':
            return parse_yaml_lite(lines[1:i]), '\n'.join(lines[i + 1:]), None
    return None, text, 'frontmatter 닫는 --- 없음'


def walk_files(top, pred):
    out = []
    if not os.path.isdir(top):
        return out
    for root, dirs, files in os.walk(top):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for n in sorted(files):
            p = os.path.join(root, n)
            if pred(p):
                out.append(p)
    return out


def run(cmd, timeout=60, env=None, cwd=None):
    try:
        r = subprocess.run(cmd, stdin=DEVNULL, stdout=PIPE, stderr=PIPE, timeout=timeout,
                           universal_newlines=True, env=env, cwd=cwd)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return 124, '', '시간 초과(%ss)' % timeout
    except OSError as e:
        return 127, '', str(e)

# ---------- 설정(settings.json) 검사 ----------

def expand_token(tok):
    for var in ('${CLAUDE_PROJECT_DIR}', '$CLAUDE_PROJECT_DIR'):
        if tok.startswith(var):
            return 'PROJ', tok[len(var):]
    for var in ('${HOME}', '$HOME'):
        if tok.startswith(var):
            return 'HOME', tok[len(var):]
    if tok == '~' or tok.startswith('~/'):
        return 'HOME', tok[1:]
    if tok.startswith('/'):
        return 'ABS', tok
    return 'REL', tok


def resolve_path(tok):
    """명령의 경로 토큰 → 검사할 실제 경로(해석 불가면 None). --repo는 저장소 원본으로 매핑."""
    kind, rest = expand_token(tok)
    if kind == 'ABS':
        return rest
    if kind == 'REL':
        return None
    if CTX['mode'] == 'repo':
        root = CTX['root']
        if kind == 'HOME':
            if rest.startswith('/.claude/'):
                return os.path.join(root, 'claude', 'global', rest[len('/.claude/'):])
            return None
        if rest.startswith('/.claude/hooks/'):
            sub = rest[len('/.claude/hooks/'):]
            t = os.path.join(root, 'claude', 'project-template', 'dot-claude', 'hooks', sub)
            return t if os.path.exists(t) else os.path.join(root, 'claude', 'global', 'hooks', sub)
        if rest.startswith('/.claude/'):
            return os.path.join(root, 'claude', 'project-template', 'dot-claude', rest[len('/.claude/'):])
        return None
    if kind == 'HOME':
        return CTX['home'] + rest
    return CTX['project'] + rest if CTX.get('project') else None


def command_target(cmd):
    """(첫 실행 토큰, 나머지 인수, bash/sh로 실행되는지, 파싱 오류 여부)"""
    try:
        toks = shlex.split(cmd, posix=True)
    except ValueError:
        return None, [], False, True
    i = 0
    while i < len(toks) and ASSIGN_RE.match(toks[i]):
        i += 1
    interp = False
    if i < len(toks) and os.path.basename(toks[i]) in ('bash', 'sh', 'zsh', 'dash'):
        interp = True
        i += 1
        while i < len(toks) and toks[i].startswith('-') and toks[i] != '-c':
            i += 1
        if i < len(toks) and toks[i] == '-c':
            return None, [], True, False
    if i >= len(toks):
        return None, [], interp, False
    return toks[i], toks[i + 1:], interp, False


def check_hook_command(cmd, where, refs):
    tok, args, interp, bad = command_target(cmd)
    if bad:
        warn('hook-path', '%s: 명령을 해석할 수 없음(따옴표 짝 확인)' % where)
        return
    if not tok or '/' not in tok:
        return
    path = resolve_path(tok)
    if not path:
        return
    if not os.path.isfile(path):
        fail('hook-path', '%s: 파일 없음 %s' % (where, disp(path)))
        return
    refs.append(path)
    if not interp:
        EXEC_TARGETS.add(path)
        if not os.access(path, os.X_OK):
            fail('hook-path', '%s: 실행 권한 없음 %s — chmod +x' % (where, disp(path)))
    if os.path.basename(path) == 'run-hook.sh':
        if not args:
            fail('hook-path', '%s: 런처에 훅 이름 인수 없음' % where)
            return
        hp = os.path.join(os.path.dirname(path), args[0] + '.sh')
        if not os.path.isfile(hp):
            fail('hook-path', '%s: 훅 스크립트 없음 %s' % (where, disp(hp)))
        else:
            refs.append(hp)


def check_hooks(hooks, where, refs):
    if not isinstance(hooks, dict):
        fail('hooks', '%s: "hooks"가 객체가 아님' % where)
        return 0
    n = 0
    for ev in hooks:
        groups = hooks[ev]
        if ev not in CTX['events']:
            warn('hooks', '%s: 스키마 스냅샷에 없는 이벤트 %s — scripts/update-schema.sh' % (where, ev))
        if not isinstance(groups, list):
            fail('hooks', '%s: hooks.%s 값이 배열이 아님' % (where, ev))
            continue
        for gi, g in enumerate(groups):
            gw = '%s hooks.%s[%d]' % (where, ev, gi)
            if not isinstance(g, dict):
                fail('hooks', '%s: 객체가 아님' % gw)
                continue
            extra = [k for k in g if k not in ('matcher', 'hooks')]
            if extra:
                warn('hooks', '%s: 알 수 없는 필드 %s (matcher·hooks만 허용)' % (gw, ', '.join(extra)))
            if 'matcher' in g and not isinstance(g['matcher'], str):
                fail('hooks', '%s: matcher가 문자열이 아님' % gw)
            hs = g.get('hooks')
            if not isinstance(hs, list) or not hs:
                fail('hooks', '%s: "hooks" 배열 없음' % gw)
                continue
            for hi, h in enumerate(hs):
                hw = '%s.hooks[%d]' % (gw, hi)
                if not isinstance(h, dict):
                    fail('hooks', '%s: 객체가 아님' % hw)
                    continue
                t = h.get('type')
                if t not in HOOK_TYPES:
                    fail('hooks', '%s: type %s 지원 안 됨 (command|http|mcp_tool|prompt|agent)'
                         % (hw, json.dumps(t, ensure_ascii=False)))
                    continue
                n += 1
                if ev in ('SessionStart', 'Setup') and t not in SESSION_TYPES:
                    fail('hooks', '%s: %s 이벤트는 command/mcp_tool만 가능 (현재 %s)' % (hw, ev, t))
                elif t in ('prompt', 'agent') and ev in CTX['events'] and ev not in PROMPT_EVENTS:
                    warn('hooks', '%s: %s 이벤트는 %s 핸들러를 지원하지 않음' % (hw, ev, t))
                if 'suppressOutput' in h:
                    warn('hooks', '%s: suppressOutput은 핸들러 필드가 아님(훅 출력 JSON 필드)' % hw)
                to = h.get('timeout')
                if to is not None and (isinstance(to, bool) or not isinstance(to, (int, float)) or to <= 0):
                    warn('hooks', '%s: timeout은 0보다 큰 숫자(초)여야 함' % hw)
                need = {'command': ('command',), 'http': ('url',), 'mcp_tool': ('server', 'tool'),
                        'prompt': ('prompt',), 'agent': ('prompt',)}[t]
                missing = [k for k in need if not (isinstance(h.get(k), str) and h.get(k).strip())]
                if missing:
                    fail('hooks', '%s: %s 핸들러에 %s 없음' % (hw, t, ', '.join(missing)))
                    continue
                if t == 'command':
                    check_hook_command(h['command'], hw, refs)
    return n


def rule_problem(r):
    if r == '*' or r.startswith('mcp__') or r == 'Task' or r.startswith('Task('):
        return None
    m = re.match(r'^(Write|NotebookEdit|Glob|MultiEdit)\(', r)
    if m:
        return '%s(경로) 규칙은 매칭되지 않음 — Edit(...) 또는 Read(...) 사용' % m.group(1)
    if re.match(r'^Bash\(.*:\*\)$', r, re.S):
        return '구식 :* 형식 — "Bash(명령 *)" 공백 형식 사용'
    m = re.match(r'^Bash\((.*)\)$', r, re.S)
    if m:
        inner = m.group(1)
        # 첫 와일드카드가 명령어에 붙어 있으면("ls*") 경고. 공백 뒤의 중간 와일드카드("check *--fix*")는 의도된 형태.
        if re.match(r'^[^ ]*\*', inner):
            return '공백 없는 와일드카드 — "Bash(ls*)"는 lsof도 허용, "Bash(명령 *)" 사용'
    rx = CTX['rule_re']
    if rx is not None and not rx.search(r):
        return '스키마 permissionRule 형식과 불일치'
    return None


def check_permissions(p, where):
    if not isinstance(p, dict):
        fail('permissions', '%s: permissions가 객체가 아님' % where)
        return 0
    n = 0
    seen = {}
    for lst in ('allow', 'deny', 'ask'):
        if lst not in p:
            continue
        v = p[lst]
        if not isinstance(v, list):
            fail('permissions', '%s: permissions.%s가 배열이 아님' % (where, lst))
            continue
        for r in v:
            if not isinstance(r, str) or not r.strip():
                fail('permissions', '%s: permissions.%s에 문자열이 아닌 규칙' % (where, lst))
                continue
            n += 1
            msg = rule_problem(r)
            if msg:
                warn('permissions', '%s: %s %s — %s' % (where, lst, r, msg))
            seen.setdefault(r, []).append(lst)
    for r in seen:
        ls = seen[r]
        if len(set(ls)) > 1:
            warn('permissions', '%s: 같은 규칙이 여러 목록에 있음 %s (%s) — deny > ask > allow 순 적용'
                 % (where, r, '/'.join(ls)))
        elif len(ls) > 1:
            warn('permissions', '%s: 중복 규칙 %s (%s)' % (where, r, ls[0]))
    return n


def check_statusline(sl, where):
    if not isinstance(sl, dict):
        fail('statusline', '%s: statusLine이 객체가 아님' % where)
        return
    if sl.get('type') != 'command':
        warn('statusline', '%s: statusLine.type은 "command"여야 함' % where)
    cmd = sl.get('command')
    if not isinstance(cmd, str) or not cmd.strip():
        fail('statusline', '%s: statusLine.command 없음' % where)
        return
    tok, _args, interp, bad = command_target(cmd)
    if bad or not tok or '/' not in tok:
        return
    path = resolve_path(tok)
    if not path:
        return
    if not os.path.isfile(path):
        warn('statusline', '%s: 스크립트 없음 %s' % (where, disp(path)))
    elif not interp and not os.access(path, os.X_OK):
        warn('statusline', '%s: 실행 권한 없음 %s — chmod +x' % (where, disp(path)))
    else:
        EXEC_TARGETS.add(path)


def check_settings_file(path, refs=None):
    """settings JSON(설정·조각·예시) 검사. 파싱된 dict 또는 None."""
    mark = len(ITEMS)
    d = load_json(path)
    if d is None:
        return None
    where = disp(path)
    if not isinstance(d, dict):
        fail('json', '%s: 최상위가 객체가 아님' % where)
        return None
    if CTX['props'] is not None:
        unknown = [k for k in d if k not in CTX['props'] and k not in KNOWN_EXTRA_KEYS]
        if unknown:
            warn('settings-keys', '%s: 스키마 스냅샷에 없는 키 %s — scripts/update-schema.sh'
                 % (where, ', '.join(unknown)))
    refs = refs if refs is not None else []
    nr = check_permissions(d['permissions'], where) if 'permissions' in d else 0
    nh = check_hooks(d['hooks'], where, refs) if 'hooks' in d else 0
    if 'statusLine' in d:
        check_statusline(d['statusLine'], where)
    if 'env' in d and not (isinstance(d['env'], dict) and all(isinstance(v, str) for v in d['env'].values())):
        warn('settings', '%s: env 값은 모두 문자열이어야 함' % where)
    if not issues_since(mark):
        ok('settings', '%s (권한 규칙 %d · 훅 핸들러 %d)' % (where, nr, nh))
    return d


def check_secret_sync(settings, patterns_path, required):
    """Read deny(//**/<이름>)가 hooks/lib/secret-patterns.txt에 모두 들어 있는지(단일 원본 동기화)."""
    if not isinstance(settings, dict):
        return
    deny = (settings.get('permissions') or {}).get('deny') or []
    globs = []
    for r in deny:
        m = re.match(r'^Read\(//\*\*/([^/()]+)\)$', r) if isinstance(r, str) else None
        if m:
            globs.append(m.group(1))
    if not globs:
        return
    if not os.path.isfile(patterns_path):
        if required:
            warn('secret-sync', '%s 없음 — 비밀 패턴 동기화 확인 불가' % disp(patterns_path))
        return
    txt = read_text(patterns_path, 'secret-sync') or ''
    pats = [ln.strip() for ln in txt.splitlines() if ln.strip() and not ln.strip().startswith('#')]
    missing = [g for g in globs if not any(fnmatchcase(g.replace('*', 'x').lower(), p) for p in pats)]
    if missing:
        warn('secret-sync', 'Read deny에 있으나 %s에 없음: %s — 두 목록을 함께 갱신'
             % (disp(patterns_path), ', '.join(missing)))
    else:
        ok('secret-sync', 'Read deny %d개가 모두 %s에 포함' % (len(globs), disp(patterns_path)))

# ---------- 에이전트 · 스킬 · 규칙 ----------

def check_agent(path):
    txt = read_text(path, 'agents')
    if txt is None:
        return False
    where = disp(path)
    fm, _body, err = frontmatter(txt)
    if fm is None:
        warn('agents', '%s: %s — 에이전트로 로드되지 않음(문서로 취급)' % (where, err or 'frontmatter 없음'))
        return False
    mark = len(ITEMS)
    stem = os.path.basename(path)[:-3]
    if fm.get('name') != stem:
        warn('agents', '%s: name(%s) ≠ 파일명(%s)' % (where, fm.get('name'), stem))
    desc = fm.get('description')
    if not isinstance(desc, str) or not desc.strip():
        fail('agents', '%s: description 없음(필수)' % where)
    model = fm.get('model')
    if model is not None and not (isinstance(model, str) and (model in AGENT_MODELS or model.startswith('claude-'))):
        warn('agents', '%s: model %s — sonnet|opus|haiku|fable|inherit|claude-* 중 하나 권장' % (where, model))
    return not issues_since(mark)


def check_skill(sdir):
    dname = os.path.basename(sdir)
    sk = os.path.join(sdir, 'SKILL.md')
    if not os.path.isfile(sk):
        fail('skills', '%s: SKILL.md 없음' % disp(sdir))
        return False
    txt = read_text(sk, 'skills')
    if txt is None:
        return False
    where = disp(sk)
    mark = len(ITEMS)
    fm, body, err = frontmatter(txt)
    if fm is None:
        warn('skills', '%s: %s' % (where, err or 'frontmatter 없음'))
        fm = {}
    name = fm.get('name') or dname
    if not isinstance(name, str):
        name = str(name)
    if name != dname:
        warn('skills', '%s: name(%s) ≠ 디렉터리(%s)' % (where, name, dname))
    if name in RESERVED_SKILLS or dname in RESERVED_SKILLS:
        fail('skills', '%s: 예약·번들 스킬 이름 %s 사용 불가' % (where, name))
    if re.search(r'[<>]', name) or name != name.strip() or '  ' in name:
        fail('skills', '%s: 이름에 < > 또는 앞뒤·이중 공백 사용 불가' % where)
    desc = fm.get('description') if isinstance(fm.get('description'), str) else ''
    wtu = fm.get('when_to_use') if isinstance(fm.get('when_to_use'), str) else ''
    if not desc.strip():
        warn('skills', '%s: description 없음 — 본문 첫 문단이 목록에 쓰임' % where)
    elif len(desc) > 250:
        warn('skills', '%s: description %d자 > 250' % (where, len(desc)))
    if re.search(r'[<>]', desc):
        warn('skills', '%s: description에 < > 사용 — [args] 형식 권장' % where)
    if len(desc) + len(wtu) > 1536:
        fail('skills', '%s: description+when_to_use %d자 > 1,536 (목록에서 잘림)' % (where, len(desc) + len(wtu)))
    if not body.strip():
        fail('skills', '%s: 본문 비어 있음' % where)
    for ref in sorted(set(re.findall(r'\$\{CLAUDE_SKILL_DIR\}/([A-Za-z0-9._/-]+)', txt))):
        ref = ref.rstrip('.')
        target = os.path.join(sdir, ref)
        if not os.path.exists(target) and CTX['mode'] == 'repo':
            src = INSTALL_PROVIDED.get(dname, {}).get(ref)
            if src:
                target = os.path.join(CTX['root'], src)
        if not os.path.isfile(target):
            fail('skills', '%s: 참조 파일 없음 ${CLAUDE_SKILL_DIR}/%s' % (where, ref))
        elif ref.endswith('.sh'):
            EXEC_TARGETS.add(target)
            if not os.access(target, os.X_OK):
                fail('skills', '%s: 실행 권한 없음 %s — chmod +x' % (where, disp(target)))
    check_skill_injections(where, dname, fm, body)
    return not issues_since(mark)


def split_tools(v):
    """allowed-tools(YAML 목록 또는 문자열) → 규칙 목록. 문자열은 괄호 밖의 공백·쉼표로 나눈다."""
    if isinstance(v, list):
        return [x.strip() for x in v if isinstance(x, str) and x.strip()]
    if not isinstance(v, str):
        return []
    out, cur, depth = [], '', 0
    for ch in v:
        if ch == '(':
            depth += 1
        elif ch == ')' and depth:
            depth -= 1
        if depth == 0 and (ch.isspace() or ch == ','):
            if cur.strip():
                out.append(cur.strip())
            cur = ''
            continue
        cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def leading_token(cmd):
    """명령의 첫 토큰을 따옴표째 돌려준다(예: "${CLAUDE_SKILL_DIR}/context.sh")."""
    cmd = cmd.strip()
    if cmd[:1] in ('"', "'"):
        end = cmd.find(cmd[0], 1)
        return cmd[:end + 1] if end > 0 else cmd
    return cmd.split(None, 1)[0] if cmd else ''


def bash_rule_matches(rule, cmd):
    """Bash 권한 규칙이 명령 원문(치환 전)과 글자 그대로 맞는지. *는 아무 문자열, 끝의 ' *'는 인수 없음도 허용."""
    rule = rule.strip()
    if rule == 'Bash':
        return True
    m = re.match(r'^Bash\((.*)\)$', rule, re.S)
    if not m:
        return False
    pat = m.group(1)
    if pat.endswith(':*'):
        pat = pat[:-2] + ' *'
    tail = ''
    if pat.endswith(' *'):
        pat, tail = pat[:-2], '(?: .*)?'
    rx = '.*'.join(re.escape(part) for part in pat.split('*')) + tail
    return re.match('(?:%s)\\Z' % rx, cmd.strip(), re.S) is not None


def check_skill_injections(where, dname, fm, body):
    """주입 명령마다 allowed-tools에 글자 그대로 맞는 Bash 규칙이 있는지 본다.
    경로를 따옴표로 감싼 주입 명령은 규칙도 같은 따옴표 형태여야 한다(HOME에 공백이 있을 때 매칭 실패 → 스킬 중단)."""
    cmds = [c.strip() for c in INJECT_RE.findall(body or '') if c.strip()]
    cmds += [b.strip() for b in FENCE_INJECT_RE.findall(body or '') if b.strip()]
    if not cmds:
        return
    rules = split_tools(fm.get('allowed-tools'))
    for c in cmds:
        if any(bash_rule_matches(r, c) for r in rules):
            continue
        lead = leading_token(c)
        msg = ('%s: 주입 명령 %s — allowed-tools에 맞는 Bash 규칙 없음(앞 토큰 %s를 따옴표까지 같게: '
               "'Bash(%s *)')" % (where, ' '.join(c.split()), lead, lead))
        if dname in OUR_SKILLS:
            fail('skills', msg)
        else:
            warn('skills', msg + ' — settings allow 규칙이 없으면 스킬이 중단됨')


def check_rule(path):
    txt = read_text(path, 'rules')
    if txt is None:
        return False
    where = disp(path)
    mark = len(ITEMS)
    fm, body, err = frontmatter(txt)
    if err:
        warn('rules', '%s: %s' % (where, err))
    if fm is not None:
        extra = [k for k in fm if k != 'paths']
        if extra:
            warn('rules', '%s: paths 외 frontmatter 키는 무시됨: %s' % (where, ', '.join(extra)))
        if 'paths' in fm:
            v = fm['paths']
            good = (isinstance(v, list) and v and all(isinstance(x, str) and x.strip() for x in v)) \
                or (isinstance(v, str) and v.strip())
            if not good:
                fail('rules', '%s: paths는 문자열 또는 문자열 목록이어야 함' % where)
    if not body.strip():
        warn('rules', '%s: 본문 비어 있음' % where)
    return not issues_since(mark)


def check_md_group(check, paths, fn, label):
    n = 0
    good = 0
    for p in paths:
        n += 1
        if fn(p):
            good += 1
    if n and good == n:
        ok(check, '%s %d개 — 이상 없음' % (label, n))
    return n

# ---------- 셸 스크립트 · 심볼릭 링크 · 개인 참조 ----------

def is_sh(p):
    return p.endswith('.sh') and os.path.isfile(p)


def in_lib(p):
    return (os.sep + 'lib' + os.sep) in p


def check_shell(files, strict_exec):
    files = sorted(set(files))
    bad = 0
    for f in files:
        rc, _out, err = run([SYNTAX_BASH, '-n', f], timeout=30)
        if rc != 0:
            bad += 1
            first = (err.strip().splitlines() or ['문법 오류'])[0]
            if first.startswith(f + ':'):
                first = first[len(f) + 1:].strip()
            fail('bash-n', '%s: %s' % (disp(f), first))
    if files and not bad:
        ok('bash-n', '%d개 스크립트 문법 이상 없음 (%s)' % (len(files), SYNTAX_BASH))
    nx = 0
    for f in files:
        if os.access(f, os.X_OK):
            continue
        if f in EXEC_TARGETS or (strict_exec and not in_lib(f)):
            nx += 1
            fail('exec', '%s: 실행 권한 없음 — chmod +x' % disp(f))
    if files and not nx:
        ok('exec', '실행 권한 이상 없음')


def check_symlinks(tops, skip=()):
    bad = 0
    for top in tops:
        if os.path.islink(top) and not os.path.exists(top):
            bad += 1
            fail('symlink', '%s: 깨진 심볼릭 링크' % disp(top))
            continue
        if not os.path.isdir(top):
            continue
        for root, dirs, files in os.walk(top):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS and d not in skip]
            for n in dirs + files:
                p = os.path.join(root, n)
                if os.path.islink(p) and not os.path.exists(p):
                    bad += 1
                    fail('symlink', '%s: 깨진 심볼릭 링크' % disp(p))
    return bad


def check_personal_refs(paths, local_skills=()):
    """팀 공유 파일의 개인 설정 참조. 프로젝트 .claude/skills/에 같은 이름 스킬이 있으면 /<이름>은 제외."""
    n = 0
    own = set('/' + s for s in local_skills)
    for p in paths:
        txt = read_text(p, 'project-refs')
        if txt is None:
            continue
        hits = sorted(set(m.group(0).replace('\\"', '"').strip(' `"\'()[]') for m in PERSONAL_RE.finditer(txt)))
        hits = [h for h in hits if h not in own]
        if hits:
            n += 1
            warn('project-refs', '%s: 개인 설정 참조 %s — 팀이 공유하는 파일에서는 피할 것(CLAUDE.local.md로)'
                 % (disp(p), ', '.join(hits)))
    return n

# ---------- 스키마 ----------

def load_schema(candidates):
    seen = set()
    for c in candidates:
        if not c or c in seen or not os.path.isfile(c):
            continue
        seen.add(c)
        d = load_json(c)
        if not isinstance(d, dict):
            continue
        props = d.get('properties') or {}
        CTX['props'] = set(props.keys())
        events = set(((props.get('hooks') or {}).get('properties') or {}).keys())
        if events:
            CTX['events'] = events | EXTRA_EVENTS
        pat = ((d.get('$defs') or {}).get('permissionRule') or {}).get('pattern')
        if isinstance(pat, str):
            try:
                CTX['rule_re'] = re.compile(pat)
            except re.error:
                warn('schema', '%s: permissionRule 정규식 해석 불가 — 내장 형식 사용' % disp(c))
        ok('schema', '%s (키 %d · 훅 이벤트 %d)' % (disp(c), len(CTX['props']), len(events)))
        return
    warn('schema', '스키마 스냅샷 없음 — 키 검사 생략, 훅 이벤트·권한 규칙은 내장 목록으로 검사')

# ---------- --repo ----------

def run_tests_in_repo(root, opts):
    if opts['quiet']:
        info('tests', 'selftest·tests/run-all.sh 생략(--quiet)')
        return
    ms = os.path.join(root, 'scripts', 'merge-settings.py')
    if not os.path.isfile(ms):
        fail('selftest', 'scripts/merge-settings.py 없음')
    else:
        rc, out, err = run([sys.executable, ms, '--selftest'], timeout=300)
        tail = ' / '.join((out + err).strip().splitlines()[-3:])
        (ok if rc == 0 else fail)('selftest', 'merge-settings.py --selftest 종료 %d — %s' % (rc, tail or '출력 없음'))
    if os.environ.get('DEV_SETTINGS_IN_TESTS') == '1':
        info('tests', 'tests/run-all.sh 생략(테스트 스위트 안에서 실행 중)')
        return
    ra = os.path.join(root, 'tests', 'run-all.sh')
    if not os.path.isfile(ra):
        fail('tests', 'tests/run-all.sh 없음')
        return
    env = dict(os.environ)
    env['DEV_SETTINGS_IN_TESTS'] = '1'
    rc, out, err = run([RUN_BASH, ra], timeout=1800, env=env, cwd=root)
    lines = [re.sub(r'\s{2,}', ' ', ln).strip() for ln in (out + err).strip().splitlines() if ln.strip()]
    if rc == 0:
        ok('tests', 'tests/run-all.sh 통과 — %s' % (lines[-1] if lines else ''))
    else:
        fail('tests', 'tests/run-all.sh 종료 %d — %s' % (rc, ' / '.join(lines[-8:])))


PLUGIN_HOOK_HOME = '"$HOME"/.claude/hooks/'
PLUGIN_HOOK_ROOT = '"${CLAUDE_PLUGIN_ROOT}"/hooks/'
PLUGIN_NAME_RE = re.compile(r'^[a-z0-9]+(-[a-z0-9]+)*$')


def plugin_hooks_expected(hooks):
    """전역 settings 의 hooks 를 플러그인 경로로 옮긴 값(명령의 훅 디렉터리만 바꾼다)."""
    if isinstance(hooks, dict):
        return {k: plugin_hooks_expected(v) for k, v in hooks.items()}
    if isinstance(hooks, list):
        return [plugin_hooks_expected(v) for v in hooks]
    if isinstance(hooks, str):
        return hooks.replace(PLUGIN_HOOK_HOME, PLUGIN_HOOK_ROOT)
    return hooks


def check_plugin(root, gs):
    """플러그인 배포판 검사: .claude-plugin/marketplace.json → claude/global/.claude-plugin/plugin.json.
    훅 등록은 전역 settings.json 과 같아야 한다(경로만 ${CLAUDE_PLUGIN_ROOT} 기준). 둘 다 없으면 검사하지 않는다."""
    mk = os.path.join(root, '.claude-plugin', 'marketplace.json')
    pj = os.path.join(root, 'claude', 'global', '.claude-plugin', 'plugin.json')
    if not os.path.isfile(mk) and not os.path.isfile(pj):
        return
    mark = len(ITEMS)
    docs = {}
    for f in (mk, pj):
        if not os.path.isfile(f):
            fail('plugin', '%s 없음 — marketplace.json 과 plugin.json 은 함께 둔다' % disp(f))
            continue
        d = load_json(f)
        if d is not None and not isinstance(d, dict):
            fail('plugin', '%s: 최상위가 객체가 아님' % disp(f))
            d = None
        docs[f] = d
    m, p = docs.get(mk), docs.get(pj)
    for f, d, who in ((mk, m, 'owner'), (pj, p, 'author')):
        if d is None:
            continue
        if not (isinstance(d.get('name'), str) and PLUGIN_NAME_RE.match(d['name'])):
            fail('plugin', '%s: name 은 kebab-case 문자열이어야 함' % disp(f))
        person = d.get(who)
        if who == 'owner' and not (isinstance(person, dict) and isinstance(person.get('name'), str)
                                   and person['name'].strip()):
            fail('plugin', '%s: owner.name 이 필요함' % disp(f))
        if isinstance(person, dict) and 'email' in person:
            fail('plugin', '%s: %s.email 을 넣지 않는다(공개 저장소)' % (disp(f), who))
    if p is not None and isinstance(gs, dict) and p.get('hooks') != plugin_hooks_expected(gs.get('hooks')):
        fail('plugin', '%s: hooks 가 claude/global/settings.json 의 hooks 와 다름 — 훅 등록을 바꾸면 양쪽을 함께 고친다'
             '(명령 경로만 %s → %s)' % (disp(pj), PLUGIN_HOOK_HOME, PLUGIN_HOOK_ROOT))
    if m is not None:
        plugins = m.get('plugins')
        entry = None
        for e in plugins if isinstance(plugins, list) else []:
            if isinstance(e, dict) and e.get('source') == './claude/global':
                entry = e
        if entry is None:
            fail('plugin', '%s: plugins 에 source 가 "./claude/global" 인 항목이 없음' % disp(mk))
        elif p is not None and entry.get('name') != p.get('name'):
            fail('plugin', '%s: plugins 항목의 name 이 plugin.json 의 name 과 다름' % disp(mk))
    if not issues_since(mark):
        ok('plugin', 'marketplace.json·plugin.json 일치, hooks 가 전역 settings.json 과 같음')


def run_repo(root, opts):
    if not os.path.isdir(os.path.join(root, 'claude', 'global')):
        fail('repo', '%s: dev_settings 저장소 구조가 아님(claude/global 없음)' % root)
        return
    g = os.path.join(root, 'claude', 'global')
    tpl = os.path.join(root, 'claude', 'project-template', 'dot-claude')
    gset = os.path.join(g, 'settings.json')
    if not os.path.isfile(gset):
        fail('settings', 'claude/global/settings.json 없음')
    gs = check_settings_file(gset) if os.path.isfile(gset) else None
    checked = {gset}
    tfiles = [os.path.join(tpl, 'settings.json'), os.path.join(tpl, 'settings.local.json.example')]
    tfiles += walk_files(os.path.join(tpl, 'fragments'), lambda p: p.endswith('.json'))
    prof = os.path.join(root, 'profiles')
    if os.path.isdir(prof):
        for name in sorted(os.listdir(prof)):
            tfiles.append(os.path.join(prof, name, 'settings.fragment.json'))
    for f in tfiles:
        if os.path.isfile(f):
            checked.add(f)
            check_settings_file(f)
        elif f.endswith('dot-claude' + os.sep + 'settings.json'):
            fail('settings', '%s 없음' % disp(f))
    for f in walk_files(os.path.join(root, 'claude'), lambda p: p.endswith(('.json', '.json.example'))) \
            + walk_files(prof, lambda p: p.endswith('.json')):
        if f not in checked and load_json(f) is not None:
            ok('json', disp(f))
    check_secret_sync(gs, os.path.join(g, 'hooks', 'lib', 'secret-patterns.txt'), True)
    check_plugin(root, gs)
    bad_names = [p for p in walk_files(os.path.join(root, 'claude'), lambda p: os.path.basename(p) in
                                       ('CLAUDE.md', 'CLAUDE.local.md'))]
    bad_names += walk_files(prof, lambda p: os.path.basename(p) in ('CLAUDE.md', 'CLAUDE.local.md'))
    for top in (os.path.join(root, 'claude'), prof):
        for r_, dirs, _f in os.walk(top):
            bad_names += [os.path.join(r_, d) for d in dirs if d == '.claude']
    for p in bad_names:
        warn('template-names', '%s: 템플릿은 CLAUDE.md.tmpl·dot-claude/로 둘 것(저장소 작업 중 로드됨)' % disp(p))
    check_md_group('agents', walk_files(os.path.join(g, 'agents'), lambda p: p.endswith('.md')), check_agent, '에이전트')
    sk = os.path.join(g, 'skills')
    sdirs = [os.path.join(sk, d) for d in sorted(os.listdir(sk))
             if os.path.isdir(os.path.join(sk, d))] if os.path.isdir(sk) else []
    check_md_group('skills', sdirs, check_skill, '스킬')
    rules = walk_files(os.path.join(g, 'rules'), lambda p: p.endswith('.md'))
    rules += walk_files(prof, lambda p: p.endswith('.md') and (os.sep + 'rules' + os.sep) in p)
    rules += walk_files(os.path.join(tpl, 'rules'), lambda p: p.endswith('.md'))
    check_md_group('rules', rules, check_rule, '규칙')
    for n in ('install.sh', 'apply.sh', os.path.join('scripts', 'validate.sh'), os.path.join('scripts', 'update-schema.sh')):
        if os.path.isfile(os.path.join(root, n)):
            EXEC_TARGETS.add(os.path.join(root, n))
    shs = [p for p in walk_files(root, is_sh) if (os.sep + os.path.join('tests', '.tmp') + os.sep) not in p]
    check_shell(shs, strict_exec=False)
    if not check_symlinks([os.path.join(root, d) for d in ('claude', 'profiles', 'scripts', 'tests', 'schemas')],
                          skip=('.tmp',)):
        ok('symlink', '깨진 심볼릭 링크 없음')
    run_tests_in_repo(root, opts)

# ---------- --installed ----------

def manifest_paths(man, cdir, home):
    files = man.get('files') if isinstance(man, dict) else None
    out = []
    if isinstance(files, dict):
        keys = list(files.keys())
    elif isinstance(files, list):
        keys = [x for x in files if isinstance(x, str)]
    else:
        return out
    for k in keys:
        if k.startswith('~/'):
            out.append(os.path.join(home, k[2:]))
        elif os.path.isabs(k):
            out.append(k)
        else:
            out.append(os.path.join(cdir, k))
    return out


def check_install_freshness(cdir, man):
    repo = None
    rp = os.path.join(cdir, 'dev_settings.repo')
    if os.path.isfile(rp):
        repo = ((read_text(rp, 'repo') or '').strip().splitlines() or [''])[0].strip()
    elif isinstance(man, dict) and isinstance(man.get('repo'), str):
        repo = man['repo']
    if not repo:
        if man is not None:
            warn('repo', 'dev_settings.repo 없음 — 저장소 위치를 알 수 없음(install.sh 재실행)')
        return
    if not os.path.isdir(repo):
        warn('repo', '저장소 경로 없음: %s (dev_settings.repo) — 저장소를 옮겼으면 install.sh 재실행' % repo)
        return
    commit = man.get('commit') if isinstance(man, dict) else None
    if not isinstance(commit, str) or commit in ('', 'unknown'):
        info('repo', '설치 커밋 정보 없음 — 최신 여부 확인 생략')
        return
    rc, out, _e = run(['git', '-C', repo, '--no-optional-locks', 'rev-parse', 'HEAD'], timeout=10)
    head = out.strip()
    if rc != 0 or not head:
        info('repo', '%s: git HEAD 확인 불가' % repo)
    elif head != commit:
        warn('repo', '설치본이 저장소보다 오래됨 (설치 %s · 저장소 %s) — %s/install.sh 재실행'
             % (commit[:7], head[:7], repo))
    else:
        ok('repo', '설치본 = 저장소 HEAD %s' % head[:7])


def run_installed(home, opts):
    cdir = os.path.join(home, '.claude')
    if not os.path.isdir(cdir):
        fail('installed', '%s 없음 — install.sh 실행' % cdir)
        return
    mf = os.path.join(cdir, 'dev_settings.manifest.json')
    man = None
    if os.path.isfile(mf):
        man = load_json(mf)
        if isinstance(man, dict):
            ok('manifest', '%s (파일 %d개)' % (disp(mf), len(manifest_paths(man, cdir, home))))
        elif man is not None:
            fail('manifest', '%s: 최상위가 객체가 아님' % disp(mf))
            man = None
    else:
        info('manifest', '설치 매니페스트 없음 — 알려진 이름으로만 검사(install.sh로 설치하면 생성됨)')
    mpaths = manifest_paths(man, cdir, home) if man else []
    missing = [p for p in mpaths if not os.path.lexists(p)]
    for p in missing[:10]:
        warn('manifest', '설치 목록의 파일 없음: %s' % disp(p))
    if len(missing) > 10:
        warn('manifest', '설치 목록의 파일 없음: 그 밖에 %d개' % (len(missing) - 10))
    check_install_freshness(cdir, man)
    sp = os.path.join(cdir, 'settings.json')
    st = None
    if os.path.isfile(sp):
        st = check_settings_file(sp)
    else:
        warn('settings', '%s 없음' % disp(sp))
    check_secret_sync(st, os.path.join(cdir, 'hooks', 'lib', 'secret-patterns.txt'), man is not None)
    for p in mpaths:
        if p != sp and p != mf and p.endswith('.json') and os.path.isfile(p) and load_json(p) is not None:
            ok('json', disp(p))
    cm = os.path.join(cdir, 'CLAUDE.md')
    if os.path.isfile(cm):
        t = read_text(cm, 'claude-md') or ''
        n = len(re.findall(r'TODO', t))
        if n:
            warn('claude-md', '%s: TODO %d개 남음 — 채우거나 지울 것' % (disp(cm), n))
        else:
            ok('claude-md', '%s' % disp(cm))
    elif man is not None:
        warn('claude-md', '%s 없음' % disp(cm))
    mset = set(mpaths)
    agents = [os.path.join(cdir, 'agents', a + '.md') for a in OUR_AGENTS]
    agents += [p for p in mpaths if os.path.dirname(p) == os.path.join(cdir, 'agents') and p.endswith('.md')]
    check_md_group('agents', sorted(set(p for p in agents if os.path.isfile(p))), check_agent, '에이전트')
    rules = [os.path.join(cdir, 'rules', r + '.md') for r in OUR_RULES]
    rules += [p for p in mpaths if p.startswith(os.path.join(cdir, 'rules') + os.sep) and p.endswith('.md')]
    check_md_group('rules', sorted(set(p for p in rules if os.path.isfile(p))), check_rule, '규칙')
    sk = os.path.join(cdir, 'skills')
    ours, others = [], []
    if os.path.isdir(sk):
        man_skills = set()
        for p in mset:
            if p.startswith(sk + os.sep):
                man_skills.add(p[len(sk) + 1:].split(os.sep)[0])
        for d in sorted(os.listdir(sk)):
            if not os.path.isdir(os.path.join(sk, d)):
                continue
            (ours if (d in OUR_SKILLS or d in man_skills) else others).append(os.path.join(sk, d))
    check_md_group('skills', ours, check_skill, '스킬')
    if others:
        info('skills', '관리 대상 아님(건너뜀): %s' % ', '.join(os.path.basename(o) for o in others))
    shs = walk_files(os.path.join(cdir, 'hooks'), is_sh)
    for d in ours:
        shs += walk_files(d, is_sh)
    shs += [p for p in mpaths if is_sh(p)]
    check_shell(shs, strict_exec=True)
    tops = [os.path.join(cdir, 'hooks')] + ours + [p for p in agents + rules if os.path.lexists(p)]
    if not check_symlinks(tops):
        ok('symlink', '깨진 심볼릭 링크 없음')

# ---------- --project ----------

def run_project(proj, opts):
    if not os.path.isdir(proj):
        fail('project', '디렉터리 아님: %s' % proj)
        return
    d = os.path.join(proj, '.claude')
    refs = []
    sp = os.path.join(d, 'settings.json')
    if os.path.isfile(sp):
        check_settings_file(sp, refs)
    else:
        warn('project', '.claude/settings.json 없음 — apply.sh 또는 /harness-init으로 생성')
    for n in ('settings.local.json', 'settings.local.json.example'):
        if os.path.isfile(os.path.join(d, n)):
            check_settings_file(os.path.join(d, n), [])
    shs = walk_files(os.path.join(d, 'hooks'), is_sh)
    if shs:
        check_shell(shs, strict_exec=True)
    check_md_group('rules', walk_files(os.path.join(d, 'rules'), lambda p: p.endswith('.md')), check_rule, '규칙')
    check_md_group('agents', walk_files(os.path.join(d, 'agents'), lambda p: p.endswith('.md')), check_agent, '에이전트')
    sk = os.path.join(d, 'skills')
    if os.path.isdir(sk):
        check_md_group('skills', [os.path.join(sk, x) for x in sorted(os.listdir(sk))
                                  if os.path.isdir(os.path.join(sk, x))], check_skill, '스킬')
    team = [p for p in (os.path.join(proj, 'CLAUDE.md'), os.path.join(d, 'CLAUDE.md')) if os.path.isfile(p)]
    skip = ('agent-memory-local', 'worktrees', 'agent-memory', 'hooks')
    team += [p for p in walk_files(d, lambda p: p.endswith('.md')) if not any(
        (os.sep + s + os.sep) in p for s in skip)]
    if os.path.isfile(sp):
        team.append(sp)
    local_sk = [x for x in os.listdir(sk) if os.path.isdir(os.path.join(sk, x))] if os.path.isdir(sk) else []
    if team and not check_personal_refs(sorted(set(team)), local_sk):
        ok('project-refs', '팀 공유 파일에 개인 설정 참조 없음')
    rc, out, _e = run(['git', '-C', proj, 'rev-parse', '--is-inside-work-tree'], timeout=10)
    if rc == 0 and out.strip() == 'true':
        targets = ([sp] if os.path.isfile(sp) else []) + [r for r in refs if r.startswith(proj + os.sep)]
        ignored = []
        for t in sorted(set(targets)):
            rc2, _o, _e2 = run(['git', '-C', proj, 'check-ignore', '-q', t[len(proj) + 1:]], timeout=10)
            if rc2 == 0:
                ignored.append(t)
        for t in ignored:
            warn('gitignore', '%s: .gitignore에 걸려 커밋되지 않음 — 팀 공유가 필요하면 제외 규칙 수정' % disp(t))
        if targets and not ignored:
            ok('gitignore', '공유 설정·훅이 gitignore되지 않음')
    cm = os.path.join(proj, 'CLAUDE.md')
    if os.path.isfile(cm):
        n = len(re.findall(r'TODO', read_text(cm, 'claude-md') or ''))
        if n:
            info('claude-md', 'CLAUDE.md: TODO %d개 남음 — 프로젝트에 맞게 채울 것(/harness-init)' % n)
    if not check_symlinks([d], skip=('worktrees',)):
        ok('symlink', '.claude 안에 깨진 심볼릭 링크 없음')

# ---------- 출력 · main ----------

def emit(opts):
    shown = [i for i in ITEMS if not (opts['quiet'] and i[0] == 'OK')]
    limit = opts['max_lines']
    if limit and len(shown) > limit:
        order = {'FAIL': 0, 'WARN': 1, 'INFO': 2, 'OK': 3}
        idx = sorted(range(len(shown)), key=lambda k: (order.get(shown[k][0], 9), k))
        keep = sorted(idx[:max(limit - 1, 0)])
        omitted = len(shown) - len(keep)
        shown = [shown[k] for k in keep] + [('INFO', 'output', '%d줄 생략 (--max-lines %d)' % (omitted, limit))]
    for lv, c, d in shown:
        print('%s %s: %s' % (lv, c, d))
    print('요약: OK %d · WARN %d · FAIL %d' % (count('OK'), count('WARN'), count('FAIL')))


def main(argv):
    opts = parse_args(argv)
    home = opts['home']
    cdir = os.path.join(home, '.claude')
    pairs = []
    if opts['repo']:
        CTX.update(mode='repo', root=opts['repo'])
        pairs.append((opts['repo'], ''))
        cands = [os.path.join(opts['repo'], 'schemas', SCHEMA_NAME), os.path.join(SCRIPT_DIR, SCHEMA_NAME)]
    else:
        CTX.update(mode='installed' if opts['installed'] else 'project', home=home, claude_dir=cdir,
                   project=opts['project'])
        if opts['installed']:
            pairs.append((cdir, '~/.claude'))
        if opts['project']:
            pairs.append((opts['project'], ''))
        cands = [os.path.join(SCRIPT_DIR, SCHEMA_NAME),
                 os.path.join(SCRIPT_DIR, '..', 'schemas', SCHEMA_NAME),
                 os.path.join(cdir, 'skills', 'harness-check', SCHEMA_NAME)]
    set_disp(pairs)
    load_schema([os.path.normpath(c) for c in cands])
    if opts['repo']:
        run_repo(opts['repo'], opts)
    else:
        if opts['installed']:
            run_installed(home, opts)
        if opts['project']:
            run_project(opts['project'], opts)
        elif opts['project_empty']:
            info('project', '프로젝트 경로가 비어 있음(CLAUDE_PROJECT_DIR) — 프로젝트 검사 생략')
    emit(opts)
    return 1 if count('FAIL') and not opts['exit_zero'] else 0


sys.exit(main(sys.argv[1:]))
PYEOF
fi

# ---- python3 없음: 최소 검사(bash -n, jq 파싱) ----
vf_ok=0 vf_warn=0 vf_fail=0
vf() {
  case $1 in
    OK) vf_ok=$((vf_ok + 1)) ;;
    WARN) vf_warn=$((vf_warn + 1)) ;;
    FAIL) vf_fail=$((vf_fail + 1)) ;;
  esac
  printf '%s %s: %s\n' "$1" "$2" "$3"
}
vf_repo=0 vf_inst=0 vf_root='' vf_home=${HOME:-} vf_proj='' vf_exit_zero=0
while [ $# -gt 0 ]; do
  case $1 in
    --repo) vf_repo=1
      if [ $# -gt 1 ] && [ "${2#--}" = "$2" ]; then vf_root=$2; shift; fi ;;
    --installed) vf_inst=1 ;;
    --home) [ $# -gt 1 ] || { echo 'validate.sh: --home 값 없음' >&2; exit 2; }; vf_home=$2; shift ;;
    --project) [ $# -gt 1 ] || { echo 'validate.sh: --project 값 없음' >&2; exit 2; }; vf_proj=$2; shift ;;
    --max-lines) [ $# -gt 1 ] || { echo 'validate.sh: --max-lines 값 없음' >&2; exit 2; }; shift ;;
    --exit-zero) vf_exit_zero=1 ;;
    --quiet) ;;
    -h|--help) echo 'usage: validate.sh [--repo [path] | --installed [--home <dir>] | --project <dir>] [--exit-zero] [--max-lines N] [--quiet]'; exit 0 ;;
    *) printf 'validate.sh: 알 수 없는 인수: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
if [ "$vf_repo" = 0 ] && [ "$vf_inst" = 0 ] && [ -z "$vf_proj" ]; then
  if [ -f "$VALIDATE_SCRIPT_DIR/../claude/global/settings.json" ]; then vf_repo=1; else vf_inst=1; fi
fi
vf_json='' vf_sh=''
if [ "$vf_repo" = 1 ]; then
  [ -n "$vf_root" ] || vf_root=$(cd -P -- "$VALIDATE_SCRIPT_DIR/.." && pwd -P)
  vf_json=$(find "$vf_root/claude" "$vf_root/profiles" "$vf_root/schemas" -type f \( -name '*.json' -o -name '*.json.example' \) 2>/dev/null)
  vf_sh=$(find "$vf_root" -type f -name '*.sh' ! -path '*/.git/*' ! -path '*/tests/.tmp/*' 2>/dev/null)
fi
if [ "$vf_inst" = 1 ]; then
  vf_c="$vf_home/.claude"
  vf_json="$vf_json
$vf_c/settings.json
$vf_c/dev_settings.manifest.json"
  for vf_d in hooks skills/commit skills/review-diff skills/delegate skills/harness-check skills/harness-init skills/api skills/preflight; do
    [ -d "$vf_c/$vf_d" ] || continue
    vf_sh="$vf_sh
$(find "$vf_c/$vf_d" -type f -name '*.sh' 2>/dev/null)"
  done
fi
if [ -n "$vf_proj" ]; then
  vf_json="$vf_json
$vf_proj/.claude/settings.json
$vf_proj/.claude/settings.local.json"
  [ -d "$vf_proj/.claude/hooks" ] && vf_sh="$vf_sh
$(find "$vf_proj/.claude/hooks" -type f -name '*.sh' 2>/dev/null)"
fi
vf WARN python3 'python3 없음 — 스키마·훅·권한·스킬·규칙 검사 생략 (설치: brew install python3 / apt install python3)'
if command -v jq >/dev/null 2>&1; then
  while IFS= read -r vf_f; do
    [ -n "$vf_f" ] && [ -f "$vf_f" ] || continue
    if jq empty "$vf_f" >/dev/null 2>&1; then vf OK json "$vf_f"; else vf FAIL json "$vf_f: JSON 오류"; fi
  done <<EOF
$vf_json
EOF
else
  vf WARN json 'python3·jq 모두 없음 — JSON 검사 생략'
fi
vf_bash=/bin/bash
[ -x "$vf_bash" ] || vf_bash=$VALIDATE_BASH
vf_n=0 vf_bad=0
while IFS= read -r vf_f; do
  [ -n "$vf_f" ] && [ -f "$vf_f" ] || continue
  vf_n=$((vf_n + 1))
  if ! "$vf_bash" -n "$vf_f" 2>/dev/null; then vf FAIL bash-n "$vf_f: 문법 오류"; vf_bad=1; fi
done <<EOF
$vf_sh
EOF
[ "$vf_bad" = 0 ] && vf OK bash-n "${vf_n}개 스크립트 ($vf_bash)"
printf '요약: OK %s · WARN %s · FAIL %s\n' "$vf_ok" "$vf_warn" "$vf_fail"
if [ "$vf_fail" -gt 0 ] && [ "$vf_exit_zero" != 1 ]; then exit 1; fi
exit 0
