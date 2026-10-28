#!/usr/bin/env python
"""Strips Godot's extension_api.json down to what the project index needs and
ClassDB cannot provide: builtin Variant types (Vector3, String, Array, ...) and
global utility functions (print, range, ...).

    godot --headless --dump-extension-api
    python tools/extract_builtin_api.py extension_api.json data/builtin_api.json
"""
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
api = json.load(open(src, encoding="utf-8"))


def args(m):
    return [{"name": a["name"], "type": a["type"]} for a in m.get("arguments", [])]


out = {"version": api["header"]["version_full_name"], "builtin": {}, "utility": {}, "global_enums": []}
for c in api["builtin_classes"]:
    out["builtin"][c["name"]] = {
        "methods": {
            m["name"]: {"ret": m.get("return_type", ""), "args": args(m), "static": m.get("is_static", False),
                        "vararg": m.get("is_vararg", False)}
            for m in c.get("methods", [])
        },
        "members": {m["name"]: m["type"] for m in c.get("members", [])},
        "constants": {k["name"]: k["type"] for k in c.get("constants", [])},
        "constructors": [args(k) for k in c.get("constructors", [])],
    }
for u in api["utility_functions"]:
    out["utility"][u["name"]] = {"ret": u.get("return_type", ""), "args": args(u), "vararg": u.get("is_vararg", False)}
out["global_enums"] = [e["name"] for e in api.get("global_enums", [])]
json.dump(out, open(dst, "w", encoding="utf-8"), separators=(",", ":"), sort_keys=True)
print(dst, len(out["builtin"]), "builtin types,", len(out["utility"]), "utility functions")
