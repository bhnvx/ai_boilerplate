#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dev_settings — Claude Code settings.json 병합 도구 (stdlib only, python3 >= 3.8, 결정적).

사용법:
  merge-settings.py --mode install|apply --base <path|NONE> --overlay <path> [--overlay <path>...]
                    [--manifest <prev-manifest.json>] [--write-manifest <path>] [--force]
                    [--drop-hooks] [--diff] [--home <dir>] --out <path|->
  merge-settings.py --selftest

- 엄격한 JSON만 허용(JSONC 불가). 잘못된 JSON은 `<file>: line X col Y` 와 함께 exit 1.
- 출력: 2칸 들여쓰기, ensure_ascii=False, 끝 개행, base 키 순서 유지 후 새 키 추가.
"""
import argparse
import copy
import difflib
import json
import os
import re
import sys

BASE_WINS_INSTALL = [
    "model", "effortLevel", "modelSettings", "enabledPlugins", "extraKnownMarketplaces",
    "env", "language", "statusLine", "attribution", "includeCoAuthoredBy", "worktree",
    "permissions.defaultMode", "permissions.additionalDirectories",
]
FORCE_OVERRIDABLE = ("language", "statusLine", "worktree")
PERM_LISTS = ("allow", "deny", "ask")
MANAGED_SCALARS = ("statusLine", "language", "worktree")
ATOMIC_PATHS = ("statusLine",)
SIMPLE_MATCHER_RE = re.compile(r"^[A-Za-z0-9_ ,|-]*$")
SCHEMA_URL = "https://json.schemastore.org/claude-code-settings.json"
DROP_HOOK_SUBSTR = "/.claude/hooks/run-hook.sh format-on-edit"
WARNINGS = []
QUIET = False


def warn(msg):
    WARNINGS.append(msg)
    if not QUIET:
        print(msg, file=sys.stderr)


def die(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def load_json(path, required=False):
    if path is None or path == "NONE":
        return {}, ""
    if not os.path.exists(path):
        if required:
            die("%s: 파일이 없다" % path)
        return {}, ""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        die("%s: line %d col %d: %s (엄격한 JSON만 허용 — 주석·후행 콤마(JSONC) 불가)"
            % (path, exc.lineno, exc.colno, exc.msg))
    if not isinstance(data, dict):
        die("%s: 최상위가 JSON 객체가 아니다" % path)
    return data, text


def canon_matcher(matcher):
    """단순 매처는 `|`/`,` 로 나눠 정렬·중복 제거; ''/'*'/없음 → '*'; 정규식 매처는 그대로."""
    if matcher is None:
        return "*"
    text = str(matcher).strip()
    if text in ("", "*"):
        return "*"
    if SIMPLE_MATCHER_RE.match(text):
        parts = sorted(set(p.strip() for p in re.split(r"[|,]", text) if p.strip()))
        return "|".join(parts) if parts else "*"
    return text


def norm_command(cmd, home):
    text = str(cmd)
    if home:
        for variant in (json.dumps(home), "'%s'" % home, home):
            text = text.replace(variant, "$HOME")
    for variant in ('"${HOME}"', "${HOME}", '"$HOME"'):
        text = text.replace(variant, "$HOME")
    text = re.sub(r"(^|[\s=])~(?=/|$)", r"\1$HOME", text)
    text = text.replace('"', "").replace("'", "")
    return " ".join(text.split())


def handler_key(handler, home):
    kind = handler.get("type", "command")
    if kind == "command":
        key = norm_command(handler.get("command", ""), home)
        args = handler.get("args")
        if isinstance(args, list) and args:
            key += " " + " ".join(str(a) for a in args)
        return "command:" + key
    if kind == "http":
        return "http:%s" % handler.get("url", "")
    if kind == "mcp_tool":
        return "mcp_tool:%s:%s" % (handler.get("server", ""), handler.get("tool", ""))
    return "%s:%s" % (kind, " ".join(str(handler.get("prompt", "")).split()))


def prune_hooks(settings, touched):
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return
    for event in list(hooks):
        groups = hooks[event]
        if isinstance(groups, list):
            hooks[event] = [g for g in groups if not (isinstance(g, dict) and g.get("hooks") == [])]
            if hooks[event] == [] and event in touched:
                del hooks[event]
    if hooks == {} and touched:
        del settings["hooks"]


def remove_handler(settings, event, canon, key, home):
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict) or not isinstance(hooks.get(event), list):
        return False
    found = False
    for group in hooks[event]:
        if not isinstance(group, dict) or canon_matcher(group.get("matcher")) != canon:
            continue
        handlers = group.get("hooks")
        if not isinstance(handlers, list):
            continue
        keep = [h for h in handlers if not (isinstance(h, dict) and handler_key(h, home) == key)]
        if len(keep) != len(handlers):
            group["hooks"] = keep
            found = True
    return found


def apply_manifest(base, manifest, home):
    """이전 설치가 기여한 항목을 base에서 제거한다. 사용자가 이미 지운 항목은 deleted 로 돌려준다."""
    deleted = {"perm": set(), "hook": set(), "scalar": set()}
    managed = manifest.get("settings", manifest) if isinstance(manifest, dict) else {}
    perms = base.get("permissions") if isinstance(base.get("permissions"), dict) else {}
    touched_lists = set()
    for lst in PERM_LISTS:
        for rule in (managed.get("permissions") or {}).get(lst) or []:
            cur = perms.get(lst)
            if isinstance(cur, list) and rule in cur:
                perms[lst] = [r for r in cur if r != rule]
                touched_lists.add(lst)
            else:
                deleted["perm"].add((lst, rule))
    for lst in touched_lists:
        if perms.get(lst) == []:
            del perms[lst]
    if perms == {} and touched_lists and "permissions" in base:
        del base["permissions"]
    touched_events = set()
    for item in managed.get("hooks") or []:
        event, canon, key = item.get("event"), canon_matcher(item.get("matcher")), item.get("key")
        if remove_handler(base, event, canon, key, home):
            touched_events.add(event)
        else:
            deleted["hook"].add((event, canon, key))
    prune_hooks(base, touched_events)
    values = managed.get("values") or {}
    for name in MANAGED_SCALARS:
        if not managed.get(name):
            continue
        if name in base:
            if name in values and base[name] != values[name]:
                warn("유지(사용자 편집): %s" % name)
            else:
                del base[name]
        else:
            deleted["scalar"].add(name)
    # 우리가 넣은 $schema 는 되돌린다(사용자가 다른 값으로 바꿨으면 유지). 없어진 경우는 사용자 의도로 보지 않는다(메타데이터).
    if managed.get("schema") and "$schema" in base:
        if base["$schema"] == values.get("$schema", SCHEMA_URL):
            del base["$schema"]
        else:
            warn("유지(사용자 편집): $schema")
    return deleted


def is_base_wins(path, base_wins):
    return any(path == bw or path.startswith(bw + ".") for bw in base_wins)


def merge_permissions(out_perm, ov_perm, ctx):
    for lst in PERM_LISTS:
        rules = ov_perm.get(lst)
        if not isinstance(rules, list):
            continue
        for rule in rules:
            cur = out_perm.get(lst) if isinstance(out_perm.get(lst), list) else []
            if rule in cur:
                continue
            other = [o for o in PERM_LISTS if o != lst and rule in (out_perm.get(o) or [])]
            if other:
                warn("WARN 충돌: %s base=%s overlay=%s" % (rule, other[0], lst))
                continue
            if (lst, rule) in ctx["deleted"]["perm"] and not ctx["force"]:
                warn("유지(사용자 삭제): %s" % rule)
                continue
            out_perm.setdefault(lst, []).append(rule)
            ctx["contrib"]["permissions"][lst].append(rule)


def merge_hooks(out_hooks, ov_hooks, ctx):
    for event, ov_groups in ov_hooks.items():
        if not isinstance(ov_groups, list):
            continue
        groups = out_hooks.setdefault(event, [])
        if not isinstance(groups, list):
            warn("WARN hooks.%s 가 배열이 아니어서 건너뜀" % event)
            continue
        for og in ov_groups:
            if not isinstance(og, dict):
                continue
            canon = canon_matcher(og.get("matcher"))
            group = None
            for g in groups:
                if isinstance(g, dict) and canon_matcher(g.get("matcher")) == canon:
                    group = g
                    break
            attached = group is not None
            if group is None:  # 새 그룹은 핸들러가 실제로 추가될 때만 붙인다(빈 그룹 방지)
                group = {k: copy.deepcopy(v) for k, v in og.items() if k != "hooks"}
                group["hooks"] = []
            handlers = group.setdefault("hooks", [])
            for oh in og.get("hooks") or []:
                if not isinstance(oh, dict):
                    continue
                key = handler_key(oh, ctx["home"])
                idx = next((i for i, h in enumerate(handlers)
                            if isinstance(h, dict) and handler_key(h, ctx["home"]) == key), None)
                if idx is None:
                    if (event, canon, key) in ctx["deleted"]["hook"] and not ctx["force"]:
                        warn("유지(사용자 삭제): hook %s" % key)
                        continue
                    if not attached:
                        groups.append(group)
                        attached = True
                    handlers.append(copy.deepcopy(oh))
                    ctx["contrib"]["hooks"].append(
                        {"event": event, "matcher": group.get("matcher"), "key": key, "handler": copy.deepcopy(oh)})
                elif handlers[idx] != oh:
                    handlers[idx] = copy.deepcopy(oh)


def merge_into(out, overlay, ctx, path=""):
    for key, ov in overlay.items():
        p = path + "." + key if path else key
        if p == "permissions" and isinstance(ov, dict):
            if not isinstance(out.get("permissions"), dict):
                if "permissions" in out:
                    warn("WARN permissions 가 객체가 아니어서 건너뜀")
                    continue
                out["permissions"] = {}
            merge_permissions(out["permissions"], ov, ctx)
            rest = {k: v for k, v in ov.items() if k not in PERM_LISTS}
            merge_into(out["permissions"], rest, ctx, p)
            continue
        if p == "hooks" and isinstance(ov, dict):
            if not isinstance(out.get("hooks"), dict):
                if "hooks" in out:
                    warn("WARN hooks 가 객체가 아니어서 건너뜀")
                    continue
                out["hooks"] = {}
            merge_hooks(out["hooks"], ov, ctx)
            continue
        if isinstance(ov, dict) and isinstance(out.get(key), dict) and p not in ATOMIC_PATHS:
            merge_into(out[key], ov, ctx, p)
            continue
        if key not in out:
            if p in ctx["deleted"]["scalar"] and not ctx["force"]:
                warn("유지(사용자 삭제): %s" % p)
                continue
            out[key] = copy.deepcopy(ov)
            if p in MANAGED_SCALARS:
                ctx["contrib"]["values"][p] = copy.deepcopy(ov)
            if p == "$schema":
                ctx["contrib"]["schema"] = True
                ctx["contrib"]["values"]["$schema"] = copy.deepcopy(ov)
            continue
        if is_base_wins(p, ctx["base_wins"]) and not (ctx["force"] and p in FORCE_OVERRIDABLE):
            continue
        if ctx["force"] and out[key] != ov:
            out[key] = copy.deepcopy(ov)
            if p in MANAGED_SCALARS:
                ctx["contrib"]["values"][p] = copy.deepcopy(ov)


def drop_format_hooks(settings):
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return
    touched = set()
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                continue
            keep = [h for h in group["hooks"]
                    if not (isinstance(h, dict) and DROP_HOOK_SUBSTR in str(h.get("command", "")))]
            if len(keep) != len(group["hooks"]):
                group["hooks"] = keep
                touched.add(event)
    prune_hooks(settings, touched)


def merge(base, overlays, mode="install", manifest=None, force=False, drop_hooks=False, home=None):
    """base(dict)와 overlay 목록을 병합한 (result, contrib) 를 돌려준다. 입력은 변경하지 않는다."""
    result = copy.deepcopy(base)
    overlay = {}
    for ov in overlays:
        merge_into(overlay, ov, {"deleted": {"perm": set(), "hook": set(), "scalar": set()},
                                 "force": True, "base_wins": [], "home": home,
                                 "contrib": new_contrib()})
    deleted = apply_manifest(result, manifest, home) if manifest else {"perm": set(), "hook": set(), "scalar": set()}
    ctx = {"deleted": deleted, "force": force, "home": home,
           "base_wins": BASE_WINS_INSTALL if mode == "install" else [], "contrib": new_contrib()}
    merge_into(result, overlay, ctx)
    if drop_hooks:
        drop_format_hooks(result)
    # $schema 는 무언가를 기여할 때만 보충한다. 빈 overlay(--uninstall)에서는 넣지 않아 설치 전 상태로 돌아간다.
    if overlay and "$schema" not in result:
        result["$schema"] = SCHEMA_URL
        ctx["contrib"]["schema"] = True
        ctx["contrib"]["values"]["$schema"] = SCHEMA_URL
    return result, ctx["contrib"]


def new_contrib():
    return {"permissions": {"allow": [], "deny": [], "ask": []}, "hooks": [], "values": {}, "schema": False}


def manifest_from_contrib(contrib):
    out = {"permissions": contrib["permissions"], "hooks": contrib["hooks"]}
    for name in MANAGED_SCALARS:
        out[name] = name in contrib["values"]
    out["schema"] = bool(contrib.get("schema"))
    out["values"] = contrib["values"]
    return {"settings": out}


def dumps(data):
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def main(argv):
    ap = argparse.ArgumentParser(prog="merge-settings.py", add_help=True)
    ap.add_argument("--mode", choices=("install", "apply"), default="install")
    ap.add_argument("--base", default="NONE")
    ap.add_argument("--overlay", action="append", default=[])
    ap.add_argument("--manifest")
    ap.add_argument("--write-manifest")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--drop-hooks", action="store_true")
    ap.add_argument("--diff", action="store_true")
    ap.add_argument("--home", default=os.environ.get("HOME"))
    ap.add_argument("--out")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    if not args.out:
        ap.error("--out <path|-> 가 필요하다")
    base, base_text = load_json(args.base)
    overlays = [load_json(p, required=True)[0] for p in args.overlay]
    manifest = load_json(args.manifest, required=True)[0] if args.manifest else None
    result, contrib = merge(base, overlays, args.mode, manifest, args.force, args.drop_hooks, args.home)
    # 내용이 그대로면 원문 그대로 출력한다(재직렬화로 포맷만 바뀌는 일을 막아 바이트 단위 멱등성을 지킨다).
    text = base_text if (base_text and result == base) else dumps(result)
    if args.diff:
        diff = difflib.unified_diff(base_text.splitlines(True), text.splitlines(True),
                                    fromfile=args.base, tofile="merged", n=2)
        sys.stderr.write("".join(diff))
    if args.write_manifest:
        with open(args.write_manifest, "w", encoding="utf-8") as fh:
            fh.write(dumps(manifest_from_contrib(contrib)))
    if args.out == "-":
        sys.stdout.write(text)
    else:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text)
    return 0


def _hook(cmd, timeout=10, **extra):
    h = {"type": "command", "command": cmd, "timeout": timeout}
    h.update(extra)
    return h


def _handlers(settings, event):
    out = []
    for group in (settings.get("hooks") or {}).get(event, []) or []:
        out.extend(group.get("hooks") or [])
    return out


def selftest():
    global QUIET
    QUIET = True
    home = "/Users/tester"
    ours = '"$HOME"/.claude/hooks/run-hook.sh guard-destructive'
    overlay = {
        "$schema": SCHEMA_URL, "language": "korean", "worktree": {"baseRef": "head"},
        "statusLine": {"type": "command", "command": '"$HOME"/.claude/hooks/statusline.sh'},
        "permissions": {"allow": ["Bash(jq *)", "Bash(gh pr view *)"], "deny": ["Read(//**/.env)"]},
        "hooks": {"PreToolUse": [
            {"matcher": "Bash", "hooks": [_hook(ours)]},
            {"matcher": "Edit|Write", "hooks": [_hook('"$HOME"/.claude/hooks/run-hook.sh guard-migrations')]},
            {"hooks": [_hook('"$HOME"/.claude/hooks/run-hook.sh everything')]},
        ]},
    }
    base = {
        "model": "fable", "language": "english", "effortLevel": "xhigh",
        "permissions": {"allow": ["Bash(ls *)", "Bash(jq *)"], "deny": ["Bash(gh pr view *)"]},
        "hooks": {"PreToolUse": [
            {"matcher": "Bash", "hooks": [_hook("~/.claude/hooks/run-hook.sh guard-destructive", 5),
                                          _hook("/opt/other/hook.sh")]},
            {"matcher": "Write, Edit", "hooks": [_hook("%s/.claude/hooks/run-hook.sh guard-migrations" % home, 3)]},
            {"matcher": "*", "hooks": [_hook("echo star")]},
        ]},
    }
    checks = []

    def check(name, cond):
        checks.append((name, bool(cond)))

    WARNINGS[:] = []
    result, contrib = merge(base, [overlay], "install", home=home)
    allow = result["permissions"]["allow"]
    check("union keeps base order and appends new", allow == ["Bash(ls *)", "Bash(jq *)", "Bash(gh pr view *)"] or allow == ["Bash(ls *)", "Bash(jq *)"])
    check("conflict: rule in base deny not added to allow", "Bash(gh pr view *)" not in allow
          and any(w.startswith("WARN 충돌: Bash(gh pr view *)") for w in WARNINGS))
    bash_handlers = [h for g in result["hooks"]["PreToolUse"] if canon_matcher(g.get("matcher")) == "Bash" for h in g["hooks"]]
    check("dedupe by command (~ vs \"$HOME\" variants)", len(bash_handlers) == 2)
    check("handler field update propagates (timeout 5 -> 10)", bash_handlers[0]["timeout"] == 10)
    check("other user hook kept", any(h["command"] == "/opt/other/hook.sh" for h in bash_handlers))
    groups = result["hooks"]["PreToolUse"]
    check("canonical matcher Edit|Write == Write, Edit (no new group, base string kept)",
          len(groups) == 3 and groups[1]["matcher"] == "Write, Edit" and len(groups[1]["hooks"]) == 1
          and groups[1]["hooks"][0]["timeout"] == 10)
    check("'*' equals absent matcher", len(groups[2]["hooks"]) == 2)
    check("base-wins key model untouched", result["model"] == "fable")
    check("base-wins language kept without --force", result["language"] == "english")
    check("overlay-if-absent adds worktree/statusLine", result["worktree"] == {"baseRef": "head"} and "statusLine" in result)
    check("key order: base keys first", list(result)[:3] == ["model", "language", "effortLevel"])
    again, _ = merge(result, [overlay], "install", home=home)
    check("idempotent merge(merge(b,o),o) == merge(b,o)", again == result)
    forced, _ = merge(base, [overlay], "install", force=True, home=home)
    check("--force makes overlay win for language but never model", forced["language"] == "korean" and forced["model"] == "fable")
    man = manifest_from_contrib(contrib)["settings"]
    check("manifest lists only contributed entries",
          man["permissions"]["allow"] == [] and man["permissions"]["deny"] == ["Read(//**/.env)"]
          and len(man["hooks"]) == 1 and man["statusLine"] and man["worktree"] and not man["language"])
    # 매니페스트 기반 제거: old-hook 삭제, 사용자 삭제 규칙 미복원, --force 복원
    old = {"type": "command", "command": '"$HOME"/.claude/hooks/run-hook.sh old-hook', "timeout": 10}
    prev = {"settings": {"permissions": {"allow": ["Bash(jq *)"], "deny": [], "ask": []},
                         "hooks": [{"event": "PreToolUse", "matcher": "Bash", "key": handler_key(old, home), "handler": old}],
                         "statusLine": False, "language": False, "worktree": False}}
    base2 = {"permissions": {"allow": ["Bash(ls *)"]},
             "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [old, _hook("/opt/other/hook.sh")]}]}}
    res2, _ = merge(base2, [overlay], "install", manifest=prev, home=home)
    cmds2 = [h["command"] for h in _handlers(res2, "PreToolUse")]
    check("manifest-driven removal of renamed hook", not any("old-hook" in c for c in cmds2) and ours in cmds2)
    check("user-deleted allow rule not re-added", "Bash(jq *)" not in res2["permissions"]["allow"]
          and "Bash(gh pr view *)" in res2["permissions"]["allow"])
    res3, _ = merge(base2, [overlay], "install", manifest=prev, force=True, home=home)
    check("--force re-adds user-deleted rule", "Bash(jq *)" in res3["permissions"]["allow"])
    fmt = {"hooks": {"PostToolUse": [{"matcher": "Edit|Write|MultiEdit",
                                      "hooks": [_hook('"${CLAUDE_PROJECT_DIR}"/.claude/hooks/run-hook.sh format-on-edit', 60)]}]}}
    res4, _ = merge({}, [overlay, fmt], "apply", drop_hooks=True)
    check("--drop-hooks removes format-on-edit handler and empty event", "PostToolUse" not in res4.get("hooks", {}))
    res5, _ = merge({}, [overlay, fmt], "apply")
    check("apply mode keeps format hook without --drop-hooks", len(_handlers(res5, "PostToolUse")) == 1)
    res6, c6 = merge({"model": "x"}, [{"language": "korean"}], "apply")
    check("$schema added when absent", res6["$schema"] == SCHEMA_URL)
    check("$schema recorded as ours in contrib/manifest", c6["schema"] and manifest_from_contrib(c6)["settings"]["schema"])
    check("pre-existing $schema not recorded as ours", not merge({"$schema": "mine"}, [overlay], "install")[1]["schema"])
    # 빈 overlay(--uninstall): 우리가 넣은 $schema 만 제거, 사용자의 $schema 는 유지
    prev_s = {"settings": {"permissions": {}, "hooks": [], "statusLine": False, "language": False, "worktree": False,
                           "schema": True, "values": {"$schema": SCHEMA_URL}}}
    res_u, _ = merge({"$schema": SCHEMA_URL, "model": "fable"}, [{}], "install", manifest=prev_s)
    check("uninstall (empty overlay) removes our $schema and adds nothing", res_u == {"model": "fable"})
    res_k, _ = merge({"$schema": "mine", "model": "fable"}, [{}], "install", manifest=prev_s)
    check("uninstall keeps a user-changed $schema", res_k["$schema"] == "mine")
    res_n, _ = merge({"$schema": SCHEMA_URL, "model": "fable"}, [{}], "install",
                     manifest={"settings": {"permissions": {}, "hooks": [], "schema": False}})
    check("uninstall keeps $schema when manifest does not claim it", res_n.get("$schema") == SCHEMA_URL)
    # 매니페스트가 기록한 값과 다른 statusLine 은 사용자 편집으로 유지
    prev2 = {"settings": {"permissions": {}, "hooks": [], "statusLine": True, "language": False, "worktree": False,
                          "values": {"statusLine": overlay["statusLine"]}}}
    res7, _ = merge({"statusLine": {"type": "command", "command": "mine"}}, [overlay], "install", manifest=prev2)
    check("user-edited managed scalar kept", res7["statusLine"]["command"] == "mine")
    res8, _ = merge({"statusLine": overlay["statusLine"]}, [{"statusLine": {"type": "command", "command": "new"}}],
                    "install", manifest=prev2)
    check("unmodified managed scalar upgraded", res8["statusLine"]["command"] == "new")
    # 사용자가 settings.json 을 통째로 바꿔 관리 훅이 모두 사라진 경우: 빈 그룹을 남기지 않는다
    prev3 = {"settings": {"permissions": {}, "hooks": [
        {"event": "PreToolUse", "matcher": "Bash", "key": handler_key(_hook(ours), home), "handler": _hook(ours)}],
        "statusLine": False, "language": False, "worktree": False}}
    res9, _ = merge({"model": "fable"}, [{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [_hook(ours)]}]}}],
                    "install", manifest=prev3, home=home)
    check("user-deleted hook leaves no empty group", "hooks" not in res9 or res9["hooks"].get("PreToolUse", []) == [])
    QUIET = False
    failed = [n for n, ok in checks if not ok]
    for name, ok in checks:
        print("%s %s" % ("PASS" if ok else "FAIL", name))
    print("selftest: %d/%d 통과" % (len(checks) - len(failed), len(checks)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
