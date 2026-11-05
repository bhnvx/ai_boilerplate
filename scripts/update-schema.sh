#!/usr/bin/env bash
# Claude Code 설정 JSON 스키마 스냅샷(schemas/claude-code-settings.schema.json) 갱신.
# 새 스키마를 받아 JSON 검증 → 현재 스냅샷과 상위 키·훅 이벤트·권한 규칙 도구를 비교 → 교체.
#
# usage: scripts/update-schema.sh [--check] [--from <file>] [--url <url>]
#   --check   비교만 하고 교체하지 않음(다르면 exit 1)
#   --from    내려받지 않고 로컬 파일 사용(오프라인·테스트)
#   --url     받을 주소(기본 https://json.schemastore.org/claude-code-settings.json)
# 종료 코드: 0 성공·변경 없음, 1 다름(--check) 또는 실패, 2 사용법 오류.

ROOT=$(cd -P -- "$(dirname -- "$0")/.." && pwd -P) || exit 1
SNAP="$ROOT/schemas/claude-code-settings.schema.json"
URL=https://json.schemastore.org/claude-code-settings.json
check=0 from=''

while [ $# -gt 0 ]; do
  case $1 in
    --check) check=1 ;;
    --from) [ $# -gt 1 ] || { echo 'update-schema.sh: --from 값 없음' >&2; exit 2; }; from=$2; shift ;;
    --url) [ $# -gt 1 ] || { echo 'update-schema.sh: --url 값 없음' >&2; exit 2; }; URL=$2; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) printf 'update-schema.sh: 알 수 없는 인수: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

if ! command -v python3 >/dev/null 2>&1; then
  echo 'update-schema.sh: python3 필요(JSON 검증·비교)' >&2
  exit 1
fi
mkdir -p "$ROOT/schemas" || exit 1
tmp=$(mktemp "$ROOT/schemas/.claude-code-settings.schema.json.XXXXXX") || exit 1
trap 'rm -f "$tmp"' EXIT
trap 'exit 130' INT TERM

if [ -n "$from" ]; then
  [ -f "$from" ] || { printf 'update-schema.sh: 파일 없음: %s\n' "$from" >&2; exit 1; }
  cp "$from" "$tmp" || exit 1
  src=$from
else
  if ! command -v curl >/dev/null 2>&1; then
    echo 'update-schema.sh: curl 필요(또는 --from <file>)' >&2
    exit 1
  fi
  if ! curl -fsSL --max-time 60 "$URL" -o "$tmp"; then
    printf 'update-schema.sh: 다운로드 실패: %s\n' "$URL" >&2
    exit 1
  fi
  src=$URL
fi

python3 -I - "$SNAP" "$tmp" <<'PYEOF'
import json, re, sys

old_path, new_path = sys.argv[1], sys.argv[2]


def load(path, required):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except FileNotFoundError:
        if required:
            raise
        return {}
    except ValueError as e:
        sys.stderr.write('JSON 오류: %s: %s\n' % (path, e))
        sys.exit(1)


def facts(d):
    props = d.get('properties') or {}
    events = ((props.get('hooks') or {}).get('properties') or {}).keys()
    pat = ((d.get('$defs') or {}).get('permissionRule') or {}).get('pattern') or ''
    m = re.search(r'\^\(\(([^)]*)\)', pat)
    tools = set(m.group(1).split('|')) if m else set()
    return set(props.keys()), set(events), tools


new = load(new_path, True)
if not isinstance(new, dict) or not isinstance(new.get('properties'), dict) or 'hooks' not in new['properties']:
    sys.stderr.write('새 스키마가 Claude Code 설정 스키마로 보이지 않음(properties.hooks 없음)\n')
    sys.exit(1)
old = load(old_path, False)
ok_, oe, ot = facts(old if isinstance(old, dict) else {})
nk, ne, nt = facts(new)


def show(title, a, b):
    add, rem = sorted(b - a), sorted(a - b)
    print('%s: %d개 (+%d -%d)' % (title, len(b), len(add), len(rem)))
    for k in add:
        print('  + ' + k)
    for k in rem:
        print('  - ' + k)


show('상위 키', ok_, nk)
show('훅 이벤트', oe, ne)
show('권한 규칙 도구', ot, nt)
extra = sorted({'modelSettings', 'modelPicker', 'additionalMarketplaces', 'autoCompactWindow', 'ultracode'} & nk)
if extra:
    print('참고: 이제 스키마에 있는 키 — scripts/validate.sh KNOWN_EXTRA_KEYS에서 빼도 됨: ' + ', '.join(extra))
PYEOF
rc=$?
[ "$rc" -eq 0 ] || exit 1

if [ -f "$SNAP" ] && cmp -s "$tmp" "$SNAP"; then
  echo "변경 없음: schemas/claude-code-settings.schema.json ($src)"
  exit 0
fi
if [ "$check" = 1 ]; then
  echo "스냅샷과 다름(--check, 교체 안 함): $src"
  exit 1
fi
chmod 644 "$tmp" 2>/dev/null
mv -f "$tmp" "$SNAP" || exit 1
echo "갱신됨: schemas/claude-code-settings.schema.json ← $src"
echo "- README의 스키마 스냅샷 날짜를 $(date +%Y-%m-%d)로 갱신할 것"
echo "- scripts/validate.sh --repo 로 새 스키마 기준 검사를 다시 돌릴 것"
exit 0
