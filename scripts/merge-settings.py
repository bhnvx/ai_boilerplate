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
# 관리 값은 경로 단위다: worktree 는 객체라 그 안의 baseRef 만 관리한다(사용자의 다른 worktree 키는 건드리지 않음).
FORCE_OVERRIDABLE = ("language", "statusLine", "worktree.baseRef")
PERM_LISTS = ("allow", "deny", "ask")
MANAGED_SCALARS = ("statusLine", "language", "worktree.baseRef")
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


def _rule_lists(perms, where, bad):
    """{"allow": [...], "deny": [...], "ask": [...]} 로 정규화(문자열 규칙만). 버린 부분은 bad 에 경로로 남긴다."""
    if perms is not None and not isinstance(perms, dict):
        bad.append(where)
    perms = perms if isinstance(perms, dict) else {}
    out = {}
    for lst in PERM_LISTS:
        rules = perms.get(lst)
        out[lst] = [r for r in rules if isinstance(r, str)] if isinstance(rules, list) else []
        if rules is not None and (not isinstance(rules, list) or len(out[lst]) != len(rules)):
            bad.append("%s.%s" % (where, lst))
    return out


def _hook_items(items, where, bad):
    """훅 기록 [{"event", "matcher", "key", "handler"}] 중 event·key 가 문자열인 것만. 버린 부분은 bad 에 남긴다."""
    good = [i for i in (items if isinstance(items, list) else [])
            if isinstance(i, dict) and isinstance(i.get("event"), str) and isinstance(i.get("key"), str)]
    if items is not None and (not isinstance(items, list) or len(good) != len(items)):
        bad.append(where)
    return good


def managed_settings(manifest):
    """매니페스트의 settings 부분을 형식을 맞춰 돌려준다. 손으로 고쳤거나 깨진 값은 빈 것으로 본다(예외 없음).
    이전 형식은 worktree 객체 전체를 "worktree" 로 기록했다 → worktree.baseRef 로 읽는다.
    user_deleted: 이전 설치가 넣었지만 사용자가 지운 관리 항목(값 포함). 기여분이 아니라 기억이다(제거 대상 아님)."""
    bad = []  # 형식이 틀려 무시한 부분(경로). 기여분·기억이 빠지므로 알린다(계획·--uninstall 출력의 WARN).
    raw = manifest.get("settings", manifest) if isinstance(manifest, dict) else {}
    if not isinstance(raw, dict):
        bad.append("")
        raw = {}
    if raw.get("values") is not None and not isinstance(raw["values"], dict):
        bad.append(".values")
    values = dict(raw["values"]) if isinstance(raw.get("values"), dict) else {}
    managed = {"permissions": _rule_lists(raw.get("permissions"), ".permissions", bad),
               "hooks": _hook_items(raw.get("hooks"), ".hooks", bad),
               "schema": bool(raw.get("schema")), "values": values}
    for name in MANAGED_SCALARS:
        managed[name] = bool(raw.get(name))
    old = values.get("worktree")
    if raw.get("worktree") and "worktree.baseRef" not in raw and isinstance(old, dict) and "baseRef" in old:
        managed["worktree.baseRef"] = True
        values["worktree.baseRef"] = old["baseRef"]
    mem = raw.get("user_deleted")
    if mem is not None and not isinstance(mem, dict):
        bad.append(".user_deleted")
    mem = mem if isinstance(mem, dict) else {}
    if mem.get("values") is not None and not isinstance(mem["values"], dict):
        bad.append(".user_deleted.values")
    mem_values = mem.get("values") if isinstance(mem.get("values"), dict) else {}
    managed["user_deleted"] = {"permissions": _rule_lists(mem.get("permissions"), ".user_deleted.permissions", bad),
                               "hooks": _hook_items(mem.get("hooks"), ".user_deleted.hooks", bad),
                               "values": {k: v for k, v in mem_values.items() if k in MANAGED_SCALARS}}
    for where in bad:
        warn("WARN 매니페스트 settings%s 형식이 잘못돼 무시함 — settings.json 의 관리 항목을 직접 확인" % where)
    return managed


def path_parent(data, path):
    """'a.b' → (data['a'], 'b'). 중간 값이 객체가 아니면 (None, 'b')."""
    keys = path.split(".")
    for key in keys[:-1]:
        data = data.get(key) if isinstance(data, dict) else None
    return (data if isinstance(data, dict) else None), keys[-1]


MISSING = object()


def path_get(data, path):
    parent, leaf = path_parent(data, path)
    return parent[leaf] if parent is not None and leaf in parent else MISSING


def has_managed_child(path):
    return any(m.startswith(path + ".") for m in MANAGED_SCALARS)


def has_handler(settings, event, canon, key, home):
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict) or not isinstance(hooks.get(event), list):
        return False
    return any(isinstance(h, dict) and handler_key(h, home) == key
               for g in hooks[event] if isinstance(g, dict) and canon_matcher(g.get("matcher")) == canon
               for h in (g.get("hooks") if isinstance(g.get("hooks"), list) else []))


def new_memory():
    return {"permissions": {"allow": [], "deny": [], "ask": []}, "hooks": [], "values": {}}


def new_gone():
    """apply_manifest 결과. perm/hook/scalar: 사용자가 지운 관리 항목(병합이 다시 넣지 않음),
    hook_keys/hook_kept: (이벤트, 명령) 단위의 지운 훅/아직 설치된 우리 훅, edited: 사용자가 고친 관리 값 이름,
    memory: 다음 매니페스트에 남길 사용자 삭제 기억(값 포함), kept: memory 중 사용자가 다시 넣어 지금 있는 항목."""
    return {"perm": set(), "hook": set(), "hook_keys": set(), "hook_kept": set(), "scalar": set(),
            "edited": [], "memory": new_memory(), "kept": new_memory()}


def remember_perm(gone, lst, rule):
    if (lst, rule) not in gone["perm"]:
        gone["perm"].add((lst, rule))
        gone["memory"]["permissions"][lst].append(rule)


def remember_hook(gone, item):
    ident = (item["event"], canon_matcher(item.get("matcher")), item["key"])
    if ident not in gone["hook"]:
        gone["hook"].add(ident)
        gone["hook_keys"].add((item["event"], item["key"]))
        gone["memory"]["hooks"].append(copy.deepcopy(item))


def remember_scalar(gone, name, value):
    if name not in gone["scalar"]:
        gone["scalar"].add(name)
        gone["memory"]["values"][name] = copy.deepcopy(value)


def keep_memory(gone, part, item, lst=None):
    """사용자가 다시 넣은 기억 항목: 사용자의 것(기여분 아님)이지만 기억은 남긴다 — 다시 지우면 계속 다시 넣지 않는다.
    kept 에도 담는다: --force 는 다시 넣은 항목의 기억만 지우고 이 항목의 기억은 남긴다."""
    for mem in (gone["memory"], gone["kept"]):
        items = mem[part][lst] if lst else mem[part]
        if item not in items:
            items.append(copy.deepcopy(item))


def unclaimed(memory, contrib):
    """기억 중 이번 병합이 기여분으로 기록한 항목을 뺀 사본(기억과 기여분이 겹치지 않게). 훅은 (이벤트, 매처, 명령) 단위로 본다:
    저장소가 같은 명령을 두 매처로 넣으면 다른 매처 쪽이 기여분이어도 사용자가 다시 넣은 쪽의 기억은 남긴다."""
    out = new_memory()
    for lst in PERM_LISTS:
        claimed = set(contrib["permissions"][lst])
        out["permissions"][lst] = [r for r in memory["permissions"][lst] if r not in claimed]
    claimed_hooks = set((h["event"], canon_matcher(h.get("matcher")), h["key"]) for h in contrib["hooks"])
    out["hooks"] = [copy.deepcopy(h) for h in memory["hooks"]
                    if (h["event"], canon_matcher(h.get("matcher")), h["key"]) not in claimed_hooks]
    out["values"] = {k: copy.deepcopy(v) for k, v in memory["values"].items() if k not in contrib["values"]}
    return out


def hook_deleted(gone, event, canon, key):
    """사용자가 지운 관리 훅인가. 저장소가 매처만 바꿔도(같은 이벤트·같은 명령) 지운 것으로 본다.
    단 같은 명령이 다른 매처로 아직 설치돼 있으면(사용자가 지우지 않은 우리 훅) 매처가 정확히 같을 때만 지운 것이다."""
    if (event, canon, key) in gone["hook"]:
        return True
    return (event, key) in gone["hook_keys"] and (event, key) not in gone["hook_kept"]


def apply_manifest(base, manifest, home):
    """이전 설치가 기여한 항목을 base에서 제거한다(병합이 저장소 값으로 다시 넣는다).
    사용자가 지운 항목(이번에 없어진 기여분과 매니페스트가 기억하는 사용자 삭제)은 gone 에 담아 돌려준다."""
    gone = new_gone()
    managed = managed_settings(manifest)
    perms = base.get("permissions") if isinstance(base.get("permissions"), dict) else {}
    # 기억된 사용자 삭제: 지금도 없으면 계속 지운 것으로 본다. 사용자가 다시 넣었으면 사용자의 것(기여분이 아니라
    # 제거하지 않는다)이고 기억은 남긴다(또 지우면 다시 넣지 않는다). 기여분을 빼기 전의 base 로 판단한다.
    mem = managed["user_deleted"]
    for lst in PERM_LISTS:
        for rule in mem["permissions"][lst]:
            if isinstance(perms.get(lst), list) and rule in perms[lst]:
                keep_memory(gone, "permissions", rule, lst)
            else:
                remember_perm(gone, lst, rule)
    for item in mem["hooks"]:
        if has_handler(base, item["event"], canon_matcher(item.get("matcher")), item["key"], home):
            keep_memory(gone, "hooks", item)
        else:
            remember_hook(gone, item)
    for name, value in mem["values"].items():
        if path_get(base, name) is MISSING:
            remember_scalar(gone, name, value)
        else:
            for target in (gone["memory"], gone["kept"]):
                target["values"].setdefault(name, copy.deepcopy(value))
    touched_lists = set()
    for lst in PERM_LISTS:
        for rule in managed["permissions"][lst]:
            cur = perms.get(lst)
            if isinstance(cur, list) and rule in cur:
                perms[lst] = [r for r in cur if r != rule]
                touched_lists.add(lst)
            else:
                remember_perm(gone, lst, rule)
    for lst in touched_lists:
        if perms.get(lst) == []:
            del perms[lst]
    if perms == {} and touched_lists and "permissions" in base:
        del base["permissions"]
    touched_events = set()
    for item in managed["hooks"]:
        event, canon, key = item["event"], canon_matcher(item.get("matcher")), item["key"]
        if remove_handler(base, event, canon, key, home):
            touched_events.add(event)
            gone["hook_kept"].add((event, key))
        else:
            remember_hook(gone, item)
    prune_hooks(base, touched_events)
    values = managed["values"]
    for name in MANAGED_SCALARS:
        if not managed[name]:
            continue
        parent, leaf = path_parent(base, name)
        if parent is not None and leaf in parent:
            if name in values and parent[leaf] != values[name]:
                gone["edited"].append(name)  # 사용자 편집: 유지(알림은 병합 뒤 — --force 가 바꾸면 알리지 않는다)
            else:
                del parent[leaf]
                top = name.split(".")[0]
                if top != name and base.get(top) == {}:
                    del base[top]  # 우리 값을 빼서 비게 된 객체(worktree)는 남기지 않는다
        else:
            remember_scalar(gone, name, values.get(name))
    # 우리가 넣은 $schema 는 되돌린다(사용자가 다른 값으로 바꿨으면 유지). 없어진 경우는 사용자 의도로 보지 않는다(메타데이터).
    if managed["schema"] and "$schema" in base:
        if base["$schema"] == values.get("$schema", SCHEMA_URL):
            del base["$schema"]
        else:
            gone["edited"].append("$schema")
    return gone


def is_base_wins(path, base_wins):
    return any(path == bw or path.startswith(bw + ".") for bw in base_wins)


def skip_deleted(ctx, what):
    """사용자가 지운 관리 항목은 다시 넣지 않는다. 건너뛴 수를 세어, 그 때문에 비게 된 새 컨테이너를 남기지 않게 한다."""
    warn("유지(사용자 삭제): %s" % what)
    ctx["skipped"] = ctx.get("skipped", 0) + 1


def drop_if_emptied(out, key, created, ctx, skipped):
    """이번 병합이 새로 만든 out[key] 가 사용자 삭제만 건너뛰어 비었으면 지운다(빈 hooks·이벤트 목록·permissions 방지)."""
    if created and out.get(key) in ({}, []) and ctx.get("skipped", 0) > skipped:
        del out[key]


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
                skip_deleted(ctx, rule)
                continue
            out_perm.setdefault(lst, []).append(rule)
            ctx["contrib"]["permissions"][lst].append(rule)


def merge_hooks(out_hooks, ov_hooks, ctx):
    for event, ov_groups in ov_hooks.items():
        if not isinstance(ov_groups, list):
            continue
        created, skipped = event not in out_hooks, ctx.get("skipped", 0)
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
                    if hook_deleted(ctx["deleted"], event, canon, key) and not ctx["force"]:
                        skip_deleted(ctx, "hook %s" % key)
                        continue
                    if not attached:
                        groups.append(group)
                        attached = True
                    handlers.append(copy.deepcopy(oh))
                    ctx["contrib"]["hooks"].append(
                        {"event": event, "matcher": group.get("matcher"), "key": key, "handler": copy.deepcopy(oh)})
                elif handlers[idx] != oh:
                    handlers[idx] = copy.deepcopy(oh)
        drop_if_emptied(out_hooks, event, created, ctx, skipped)


def merge_into(out, overlay, ctx, path=""):
    for key, ov in overlay.items():
        p = path + "." + key if path else key
        if p in ("permissions", "hooks") and isinstance(ov, dict):
            created, skipped = key not in out, ctx.get("skipped", 0)
            if not isinstance(out.get(key), dict):
                if not created:
                    warn("WARN %s 가 객체가 아니어서 건너뜀" % key)
                    continue
                out[key] = {}
            if p == "hooks":
                merge_hooks(out[key], ov, ctx)
            else:
                merge_permissions(out[key], ov, ctx)
                merge_into(out[key], {k: v for k, v in ov.items() if k not in PERM_LISTS}, ctx, p)
            drop_if_emptied(out, key, created, ctx, skipped)
            continue
        if isinstance(ov, dict) and isinstance(out.get(key), dict) and p not in ATOMIC_PATHS:
            merge_into(out[key], ov, ctx, p)
            continue
        if isinstance(ov, dict) and key not in out and has_managed_child(p):
            # 관리 값(worktree.baseRef)을 품은 객체는 새로 만들 때도 한 단계 내려가 경로 단위로 기록·판단한다.
            out[key] = {}
            merge_into(out[key], ov, ctx, p)
            if not out[key]:
                del out[key]  # 하위 값이 모두 사용자 삭제로 빠졌으면 빈 객체를 남기지 않는다
            continue
        if key not in out:
            if p in ctx["deleted"]["scalar"] and not ctx["force"]:
                skip_deleted(ctx, p)
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
            if p == "$schema":  # --force 가 바꾼 $schema 도 우리 값으로 기록한다(--uninstall 이 저장소 URL 을 남기지 않는다)
                ctx["contrib"]["schema"] = True
                ctx["contrib"]["values"]["$schema"] = copy.deepcopy(ov)


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
        merge_into(overlay, ov, {"deleted": new_gone(), "force": True, "base_wins": [], "home": home,
                                 "contrib": new_contrib()})
    gone = apply_manifest(result, manifest, home) if manifest else new_gone()
    ctx = {"deleted": gone, "force": force, "home": home,
           "base_wins": BASE_WINS_INSTALL if mode == "install" else [], "contrib": new_contrib()}
    merge_into(result, overlay, ctx)
    if drop_hooks:
        drop_format_hooks(result)
    # $schema 는 무언가를 기여할 때만 보충한다. 빈 overlay(--uninstall)에서는 넣지 않아 설치 전 상태로 돌아간다.
    if overlay and "$schema" not in result:
        result["$schema"] = SCHEMA_URL
        ctx["contrib"]["schema"] = True
        ctx["contrib"]["values"]["$schema"] = SCHEMA_URL
    # 사용자가 고친 관리 값은 결과에 그대로 남았을 때만 '유지'라고 알린다(--force 가 저장소 값으로 바꿨으면 알리지 않는다).
    for name in gone["edited"]:
        if path_get(result, name) == path_get(base, name):
            warn("유지(사용자 편집): %s" % name)
    # 사용자가 지운 관리 항목은 값과 함께 다음 매니페스트에 기억한다. 매니페스트를 다시 써도(커밋 변경, 다른 변경이 있는
    # 설치) 다음 설치가 다시 넣지 않는다. --force 는 지운 항목을 다시 넣어 기여분으로 기록하므로 그 기억을 비운다.
    # 사용자가 직접 다시 넣어 둔 항목은 --force 가 넣은 것이 아니므로 기억을 남긴다: 매니페스트를 다시 쓰는 --force 뒤에도
    # 또 지우면 다시 넣지 않는다(매니페스트를 다시 쓰지 않는 --force 와 같은 결과). 이번 기여분(--force 가 바꾼 값)은 뺀다.
    ctx["contrib"]["user_deleted"] = unclaimed(gone["kept"], ctx["contrib"]) if force else gone["memory"]
    return result, ctx["contrib"]


def new_contrib():
    return {"permissions": {"allow": [], "deny": [], "ask": []}, "hooks": [], "values": {}, "schema": False,
            "user_deleted": new_memory()}


def manifest_from_contrib(contrib):
    out = {"permissions": contrib["permissions"], "hooks": contrib["hooks"]}
    for name in MANAGED_SCALARS:
        out[name] = name in contrib["values"]
    out["schema"] = bool(contrib.get("schema"))
    out["values"] = contrib["values"]
    gone = contrib.get("user_deleted") or {}
    if any((gone.get("permissions") or {}).values()) or gone.get("hooks") or gone.get("values"):
        out["user_deleted"] = gone  # 사용자가 지운 관리 항목(기여분 아님): 다시 넣지 않고 --uninstall 도 건드리지 않는다
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
          and len(man["hooks"]) == 1 and man["statusLine"] and man["worktree.baseRef"] and not man["language"])
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
    # worktree 는 객체라 그 안의 baseRef 만 관리 값이다(경로 단위): 일반 설치는 사용자 값 유지, --force 는 저장소 값,
    # 매니페스트는 설치가 넣은 worktree.baseRef 만 기록하고 --uninstall 은 그것만 지운다(비게 된 worktree 객체도 정리).
    wt_user = {"worktree": {"baseRef": "fresh", "symlinkDirectories": ["node_modules"]}}
    res_w, c_w = merge(wt_user, [overlay], "install", home=home)
    check("plain install keeps the user's worktree.baseRef", res_w["worktree"] == wt_user["worktree"])
    check("user's own worktree.baseRef not recorded as ours", not manifest_from_contrib(c_w)["settings"]["worktree.baseRef"])
    res_wf, _ = merge(wt_user, [overlay], "install", force=True, home=home)
    check("--force replaces worktree.baseRef and keeps other worktree keys",
          res_wf["worktree"] == {"baseRef": "head", "symlinkDirectories": ["node_modules"]})
    res_ws, c_ws = merge({"worktree": {"symlinkDirectories": ["node_modules"]}}, [overlay], "install", home=home)
    man_ws = manifest_from_contrib(c_ws)
    check("baseRef added into an existing worktree object is recorded",
          res_ws["worktree"]["baseRef"] == "head" and man_ws["settings"]["worktree.baseRef"]
          and man_ws["settings"]["values"]["worktree.baseRef"] == "head")
    un_ws, _ = merge(res_ws, [{}], "install", manifest=man_ws, home=home)
    check("uninstall removes only our worktree.baseRef", un_ws.get("worktree") == {"symlinkDirectories": ["node_modules"]})
    man_c = manifest_from_contrib(contrib)
    un_c, _ = merge(result, [{}], "install", manifest=man_c, home=home)
    check("uninstall leaves no empty worktree object", "worktree" not in un_c)
    edited = copy.deepcopy(result)
    edited["worktree"]["baseRef"] = "fresh"
    WARNINGS[:] = []
    un_e, _ = merge(edited, [{}], "install", manifest=man_c, home=home)
    check("uninstall keeps a user-changed worktree.baseRef",
          un_e.get("worktree") == {"baseRef": "fresh"} and "유지(사용자 편집): worktree.baseRef" in WARNINGS)
    gone = copy.deepcopy(result)
    del gone["worktree"]
    re_g, _ = merge(gone, [overlay], "install", manifest=man_c, home=home)
    check("user-deleted worktree.baseRef not re-added (no empty object)", "worktree" not in re_g)
    re_gf, _ = merge(gone, [overlay], "install", manifest=man_c, force=True, home=home)
    check("--force re-adds a user-deleted worktree.baseRef", re_gf.get("worktree") == {"baseRef": "head"})
    legacy = {"settings": {"permissions": {}, "hooks": [], "statusLine": False, "language": False, "worktree": True,
                           "values": {"worktree": {"baseRef": "head"}}}}
    un_l, _ = merge({"worktree": {"baseRef": "head", "symlinkDirectories": ["x"]}}, [{}], "install", manifest=legacy)
    check("legacy manifest (whole worktree object) is read as worktree.baseRef",
          un_l == {"worktree": {"symlinkDirectories": ["x"]}})
    # 사용자가 지운 관리 항목(규칙·훅·statusLine·worktree.baseRef)은 매니페스트를 다시 써도 기억한다:
    # 설치 → 사용자 삭제 → 재설치(매니페스트 재작성) → 재설치, 세 번 병합해도 다시 넣지 않는다.
    r_1, c_1 = merge({}, [overlay], "install", home=home)
    m_1 = manifest_from_contrib(c_1)
    cut = copy.deepcopy(r_1)
    cut["permissions"]["allow"].remove("Bash(jq *)")
    del cut["statusLine"], cut["worktree"]
    cut["hooks"]["PreToolUse"] = [g for g in cut["hooks"]["PreToolUse"] if g.get("matcher") != "Bash"]
    r_2, c_2 = merge(cut, [overlay], "install", manifest=m_1, home=home)
    m_2 = manifest_from_contrib(c_2)
    r_3, c_3 = merge(r_2, [overlay], "install", manifest=m_2, home=home)
    m_3 = manifest_from_contrib(c_3)
    gone_2 = m_2["settings"].get("user_deleted") or {}
    check("user deletions survive a manifest rewrite (3 merges, nothing re-added)", r_2 == cut and r_3 == cut)
    check("rewritten manifest remembers the deleted rule, hook and values",
          (gone_2.get("permissions") or {}).get("allow") == ["Bash(jq *)"]
          and [h.get("key") for h in gone_2.get("hooks") or []] == [handler_key(_hook(ours), home)]
          and gone_2.get("values") == {"statusLine": overlay["statusLine"], "worktree.baseRef": "head"})
    check("remembered deletions are not claims",
          "Bash(jq *)" not in m_2["settings"]["permissions"]["allow"] and not m_2["settings"]["statusLine"]
          and not m_2["settings"]["worktree.baseRef"] and len(m_2["settings"]["hooks"]) == 2)
    check("memory is stable across rewrites", m_3 == m_2)
    r_f, c_f = merge(r_3, [overlay], "install", manifest=m_3, force=True, home=home)
    m_f = manifest_from_contrib(c_f)
    check("--force re-adds remembered deletions and clears the memory",
          r_f == r_1 and "user_deleted" not in m_f["settings"] and m_f == m_1)
    un_3, _ = merge(r_3, [{}], "install", manifest=m_3, home=home)
    un_f, _ = merge(r_f, [{}], "install", manifest=m_f, home=home)
    check("uninstall after rewrites / after --force removes only ours", un_3 == {} and un_f == {})
    mine = copy.deepcopy(r_3)
    mine["permissions"]["allow"].append("Bash(jq *)")
    r_m, c_m = merge(mine, [overlay], "install", manifest=m_3, home=home)
    m_m = manifest_from_contrib(c_m)
    un_m, _ = merge(r_m, [{}], "install", manifest=m_m, home=home)
    check("a remembered rule the user adds back is the user's (not claimed, kept by uninstall, still remembered)",
          r_m["permissions"]["allow"].count("Bash(jq *)") == 1 and "Bash(jq *)" not in m_m["settings"]["permissions"]["allow"]
          and "Bash(jq *)" in ((m_m["settings"].get("user_deleted") or {}).get("permissions") or {}).get("allow", [])
          and un_m == {"permissions": {"allow": ["Bash(jq *)"]}})
    # 다시 넣은 기억 항목을 사용자가 또 지우면(매니페스트를 다시 쓴 뒤에도) 계속 지운 것으로 본다
    again = copy.deepcopy(r_m)
    again["permissions"]["allow"].remove("Bash(jq *)")
    r_ag, _ = merge(again, [overlay], "install", manifest=m_m, home=home)
    check("deleting a re-added remembered rule again keeps it out", r_ag == again)
    # 훅·값도 같다: 사용자가 다시 넣은 기억 항목은 사용자의 것이고 기억에 남는다 → 또 지우면 다시 넣지 않는다
    back = copy.deepcopy(r_3)
    back["statusLine"] = copy.deepcopy(overlay["statusLine"])
    back["hooks"]["PreToolUse"].insert(0, {"matcher": "Bash", "hooks": [_hook(ours)]})
    r_bk, c_bk = merge(back, [overlay], "install", manifest=m_3, home=home)
    m_bk = manifest_from_contrib(c_bk)
    gone_bk = m_bk["settings"].get("user_deleted") or {}
    again_bk = copy.deepcopy(r_bk)
    del again_bk["statusLine"]
    again_bk["hooks"]["PreToolUse"] = [g for g in again_bk["hooks"]["PreToolUse"] if g.get("matcher") != "Bash"]
    r_bk2, _ = merge(again_bk, [overlay], "install", manifest=m_bk, home=home)
    check("a re-added remembered hook and value stay remembered; deleting them again keeps them out",
          r_bk == back and not m_bk["settings"]["statusLine"] and len(m_bk["settings"]["hooks"]) == 2
          and "statusLine" in (gone_bk.get("values") or {})
          and [h.get("key") for h in gone_bk.get("hooks") or []] == [handler_key(_hook(ours), home)]
          and r_bk2 == again_bk)
    # --force 는 다시 넣은 항목의 기억만 지운다: 사용자가 직접 다시 넣어 둔 규칙·훅·값의 기억은 남아, 매니페스트를 다시 쓴
    # --force 뒤에도 또 지우면 다시 넣지 않는다. --force 가 저장소 값으로 바꾼 관리 값은 기여분이 되어 기억에서 빠진다.
    r_fk, c_fk = merge(r_m, [overlay], "install", manifest=m_m, force=True, home=home)
    m_fk = manifest_from_contrib(c_fk)
    gone_fk = m_fk["settings"].get("user_deleted") or {}
    again_fk = copy.deepcopy(r_fk)
    again_fk["permissions"]["allow"].remove("Bash(jq *)")
    r_fk2, _ = merge(again_fk, [overlay], "install", manifest=m_fk, home=home)
    un_fk, _ = merge(r_fk, [{}], "install", manifest=m_fk, home=home)
    check("--force keeps the memory of a rule the user re-added (deleting it again keeps it out)",
          (gone_fk.get("permissions") or {}).get("allow") == ["Bash(jq *)"] and not gone_fk.get("hooks")
          and not gone_fk.get("values") and "Bash(jq *)" not in m_fk["settings"]["permissions"]["allow"]
          and r_fk2 == again_fk and un_fk == {"permissions": {"allow": ["Bash(jq *)"]}})
    r_fb, c_fb = merge(r_bk, [overlay], "install", manifest=m_bk, force=True, home=home)
    gone_fb = manifest_from_contrib(c_fb)["settings"].get("user_deleted") or {}
    mine_sl = copy.deepcopy(r_3)
    mine_sl["statusLine"] = {"type": "command", "command": "mine"}
    r_ms, c_ms = merge(mine_sl, [overlay], "install", manifest=m_3, home=home)
    r_msf, c_msf = merge(r_ms, [overlay], "install", manifest=manifest_from_contrib(c_ms), force=True, home=home)
    m_msf = manifest_from_contrib(c_msf)["settings"]
    check("--force keeps the memory of a re-added hook and value, not of a value it replaces",
          [h.get("key") for h in gone_fb.get("hooks") or []] == [handler_key(_hook(ours), home)]
          and list(gone_fb.get("values") or {}) == ["statusLine"] and not any((gone_fb.get("permissions") or {}).values())
          and r_msf["statusLine"] == overlay["statusLine"] and m_msf["statusLine"]
          and "statusLine" not in ((m_msf.get("user_deleted") or {}).get("values") or {}))
    ov_less = copy.deepcopy(overlay)
    ov_less["permissions"]["allow"].remove("Bash(jq *)")
    r_l, c_l = merge(r_3, [ov_less], "install", manifest=m_3, home=home)
    m_l = manifest_from_contrib(c_l)
    r_b, _ = merge(r_l, [overlay], "install", manifest=m_l, home=home)
    check("memory survives a repo version without the entry (re-adding it later does not bring it back)",
          "Bash(jq *)" in ((m_l["settings"].get("user_deleted") or {}).get("permissions") or {}).get("allow", [])
          and "Bash(jq *)" not in r_b["permissions"]["allow"])
    ov_mt = copy.deepcopy(overlay)
    ov_mt["hooks"]["PreToolUse"][0]["matcher"] = "Bash|Monitor"
    r_mt, _ = merge(r_3, [ov_mt], "install", manifest=m_3, home=home)
    check("a deleted hook stays deleted when the repo only changes its matcher",
          ours not in [h["command"] for h in _handlers(r_mt, "PreToolUse")])
    two = {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [_hook(ours)]}, {"matcher": "Monitor", "hooks": [_hook(ours)]}]}}
    r_t, c_t = merge({}, [two], "install", home=home)
    cut_t = copy.deepcopy(r_t)
    cut_t["hooks"]["PreToolUse"] = [g for g in cut_t["hooks"]["PreToolUse"] if g["matcher"] != "Bash"]
    r_t2, c_t2 = merge(cut_t, [two], "install", manifest=manifest_from_contrib(c_t), home=home)
    check("deleting a hook under one matcher keeps the same command under another",
          [g["matcher"] for g in r_t2["hooks"]["PreToolUse"]] == ["Monitor"])
    # 같은 명령이 두 매처로 있는 훅: 사용자가 지웠다가 다시 넣은 쪽(Bash)의 기억은 다른 매처(Monitor) 쪽이 기여분이어도
    # --force 뒤에 남는다 → 또 지워도 다시 넣지 않는다(매니페스트를 다시 쓰지 않는 --force 와 같은 결과)
    back_t = copy.deepcopy(r_t2)
    back_t["hooks"]["PreToolUse"].append({"matcher": "Bash", "hooks": [_hook(ours)]})
    r_t3, c_t3 = merge(back_t, [two], "install", manifest=manifest_from_contrib(c_t2), home=home)
    r_t4, c_t4 = merge(r_t3, [two], "install", manifest=manifest_from_contrib(c_t3), force=True, home=home)
    m_t4 = manifest_from_contrib(c_t4)
    cut_t4 = copy.deepcopy(r_t4)
    cut_t4["hooks"]["PreToolUse"] = [g for g in cut_t4["hooks"]["PreToolUse"] if g["matcher"] != "Bash"]
    r_t5, _ = merge(cut_t4, [two], "install", manifest=m_t4, home=home)
    check("--force keeps the memory of a re-added hook whose command it claims under another matcher",
          [h.get("matcher") for h in (m_t4["settings"].get("user_deleted") or {}).get("hooks") or []] == ["Bash"]
          and [h.get("matcher") for h in m_t4["settings"]["hooks"]] == ["Monitor"] and r_t5 == cut_t4)
    # 기억과 기여분이 겹친 매니페스트(손으로 고침): --force 가 같은 규칙·같은 (이벤트, 매처, 명령) 훅을 기여분으로 기록하면 기억에서 뺀다
    m_dup = copy.deepcopy(m_1)
    m_dup["settings"]["user_deleted"] = {"permissions": {"allow": ["Bash(jq *)"]},
                                         "hooks": [h for h in m_1["settings"]["hooks"] if h["key"] == handler_key(_hook(ours), home)]}
    r_dup, c_dup = merge(r_1, [overlay], "install", manifest=m_dup, force=True, home=home)
    check("--force drops memory entries it claims (exact rule and hook)",
          r_dup == r_1 and "user_deleted" not in manifest_from_contrib(c_dup)["settings"])
    # --force 가 저장소 값으로 바꾸는 관리 값은 '유지(사용자 편집)'으로 알리지 않는다(일반 설치는 유지하고 알린다)
    edited_f = copy.deepcopy(result)
    edited_f["worktree"]["baseRef"] = "fresh"
    edited_f["$schema"] = "mine"
    WARNINGS[:] = []
    r_ef, _ = merge(edited_f, [overlay], "install", manifest=man_c, force=True, home=home)
    check("--force does not say it keeps the values it replaces",
          r_ef["worktree"]["baseRef"] == "head" and r_ef["$schema"] == SCHEMA_URL
          and not any(w.startswith("유지(사용자 편집)") for w in WARNINGS))
    WARNINGS[:] = []
    r_ek, _ = merge(edited_f, [overlay], "install", manifest=man_c, home=home)
    check("plain install keeps the edited values and says so",
          r_ek["worktree"]["baseRef"] == "fresh" and r_ek["$schema"] == "mine"
          and "유지(사용자 편집): worktree.baseRef" in WARNINGS and "유지(사용자 편집): $schema" in WARNINGS)
    # 손으로 고쳤거나 깨진 매니페스트(settings 의 값 형식이 틀림)도 예외 없이 처리한다
    bad = [{"settings": {"permissions": {}, "hooks": [], "statusLine": True, "values": ["x"]}},
           {"settings": {"permissions": ["x"], "hooks": [1, {"event": ["x"], "key": "k"}], "schema": True, "values": None}},
           {"settings": {"permissions": {"allow": "x", "deny": [1, ["y"], "Bash(x *)"]}, "worktree.baseRef": True,
                         "user_deleted": {"permissions": {"allow": "x"}, "hooks": {"a": 1}, "values": ["statusLine"]}}},
           {"settings": {"user_deleted": [1]}}, {"settings": []}]
    crashed = []
    for m_bad in bad:
        for ovs in ([overlay], [{}]):
            try:
                merge({"statusLine": {"type": "command", "command": "x"}, "$schema": "mine",
                       "worktree": "head"}, ovs, "install", manifest=m_bad, home=home)
            except Exception as exc:  # noqa: BLE001 — 어떤 예외든 실패로 센다
                crashed.append("%s: %r" % (type(exc).__name__, m_bad))
    check("malformed manifest settings do not crash the merge", not crashed)
    # 형식이 틀린 부분은 무시하되 WARN 으로 알린다(계획·--uninstall 출력에 보인다). 정상 매니페스트는 알리지 않는다.
    warned = []
    for m_bad in bad:
        WARNINGS[:] = []
        merge({"model": "x"}, [{}], "install", manifest=m_bad, home=home)
        warned.append(any(w.startswith("WARN 매니페스트 settings") for w in WARNINGS))
    WARNINGS[:] = []
    for m_ok in (m_1, m_2, m_f, m_m, legacy, prev, prev_s, {"settings": {}}):
        merge(r_1, [overlay], "install", manifest=m_ok, home=home)
    check("malformed manifest parts are reported, well-formed manifests are not",
          all(warned) and not any(w.startswith("WARN 매니페스트") for w in WARNINGS))
    # 넣을 항목이 모두 사용자 삭제인 컨테이너(훅 이벤트 목록·hooks·permissions)는 빈 채로 만들지 않는다:
    # settings.json 을 쓸데없이 다시 쓰지 않고 --uninstall 뒤에 빈 껍데기가 남지 않는다.
    ss = '"$HOME"/.claude/hooks/run-hook.sh session-context'
    ov_ev = {"permissions": {"allow": ["Bash(jq *)"]},
             "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [_hook(ours)]}], "SessionStart": [{"hooks": [_hook(ss)]}]}}
    r_ev, c_ev = merge({"model": "fable"}, [ov_ev], "install", home=home)
    m_ev = manifest_from_contrib(c_ev)
    cut_ev = copy.deepcopy(r_ev)
    del cut_ev["hooks"]["SessionStart"]
    r_ev2, c_ev2 = merge(cut_ev, [ov_ev], "install", manifest=m_ev, home=home)
    un_ev2, _ = merge(r_ev2, [{}], "install", manifest=manifest_from_contrib(c_ev2), home=home)
    check("deleting an event's only hook adds no empty event list (uninstall restores the seed)",
          r_ev2 == cut_ev and un_ev2 == {"model": "fable"})
    bare = {"model": "fable", "$schema": SCHEMA_URL}
    r_ev3, c_ev3 = merge(bare, [ov_ev], "install", manifest=m_ev, home=home)
    un_ev3, _ = merge(r_ev3, [{}], "install", manifest=manifest_from_contrib(c_ev3), home=home)
    check("deleting the whole hooks and permissions objects adds no empty containers",
          r_ev3 == bare and un_ev3 == {"model": "fable"})
    r_ap, _ = merge({}, [{"permissions": {"allow": [], "deny": []}}], "apply")
    check("apply template's empty permissions object is still created", r_ap.get("permissions") == {})
    # --force 가 사용자 $schema 를 저장소 값으로 바꾸면 우리 값으로 기록한다(--uninstall 이 저장소 URL 을 남기지 않는다)
    r_sf, c_sf = merge({"$schema": "mine", "model": "fable"}, [overlay], "install", force=True, home=home)
    m_sf = manifest_from_contrib(c_sf)
    un_sf, _ = merge(r_sf, [{}], "install", manifest=m_sf, home=home)
    check("--force records the $schema it replaces (uninstall removes it)",
          r_sf["$schema"] == SCHEMA_URL and m_sf["settings"]["schema"] and un_sf == {"model": "fable"})
    QUIET = False
    failed = [n for n, ok in checks if not ok]
    for name, ok in checks:
        print("%s %s" % ("PASS" if ok else "FAIL", name))
    print("selftest: %d/%d 통과" % (len(checks) - len(failed), len(checks)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
