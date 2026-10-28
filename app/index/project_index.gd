class_name ProjectIndex
extends RefCounted
## Everything callable in the opened project: engine classes (ClassDB),
## builtin Variant types and utility functions (data/builtin_api.json), and
## the project's own scripts, extracted from their CSTs. Also keeps project-wide
## usage counts and the user's recently picked members for ranking.
##
## Type ids are plain strings:
##   "int", "Vector3", ...     builtin types
##   "Node3D", ...             engine classes
##   "Player"                  project class with `class_name Player`
##   "res://enemy.gd"          project script without class_name
##   "Player.Inner"            inner class
##   "type:X"                  the class X itself (static access, X.new())
##   ""                        unknown / Variant

signal file_reindexed(res_path: String)

const BUILTIN_API_PATH := "res://data/builtin_api.json"
const RECENT_PATH := "user://recent_members.json"
const MAX_RECENT := 200

## GDScript-only globals that are not in extension_api.json.
const GDSCRIPT_GLOBALS := {
	"range": { ret = "Array", args = [{ name = "n", type = "int" }] },
	"len": { ret = "int", args = [{ name = "var", type = "" }] },
	"load": { ret = "Resource", args = [{ name = "path", type = "String" }] },
	"preload": { ret = "Resource", args = [{ name = "path", type = "String" }] },
	"char": { ret = "String", args = [{ name = "code", type = "int" }] },
	"Color8": { ret = "Color", args = [{ name = "r8", type = "int" }, { name = "g8", type = "int" }, { name = "b8", type = "int" }] },
	"is_instance_of": { ret = "bool", args = [{ name = "value", type = "" }, { name = "type", type = "" }] },
	"type_exists": { ret = "bool", args = [{ name = "type", type = "StringName" }] },
	"get_stack": { ret = "Array", args = [] },
	"inst_to_dict": { ret = "Dictionary", args = [{ name = "instance", type = "Object" }] },
	"dict_to_inst": { ret = "Object", args = [{ name = "dictionary", type = "Dictionary" }] },
	"print_debug": { ret = "void", args = [] },
	"print_stack": { ret = "void", args = [] },
	"assert": { ret = "void", args = [{ name = "condition", type = "bool" }] },
}


class Member:
	var name := ""
	var kind := "" ## method, property, signal, constant, enum
	var owner := "" ## Type id that declares it.
	var type := "" ## Property / constant type, or method return type.
	var args: Array = [] ## [{name, type}]
	var is_static := false
	var source := "" ## project, engine, builtin
	var line := -1 ## Project members: 0-based line of the declaration.

	func key() -> String:
		return owner + "." + name


class ScriptClass:
	var id := ""
	var class_name_ := ""
	var res_path := ""
	var extends_raw := ""
	var parent := "" ## Resolved parent type id.
	var members := {} ## name -> Member (own only)
	var inner: Array[String] = []
	var outer := ""
	var preloads: Array[String] = [] ## res paths
	var refs := {} ## referenced project class ids -> count
	var node := {} ## CST of the class (source or class_definition)


var root_dir := "" ## OS path of the opened project.
var files := {} ## res path -> ScriptFile
var classes := {} ## id -> ScriptClass
var by_path := {} ## res path -> top-level class id
var class_names := {} ## class_name -> id
var autoloads := {} ## name -> type id
var usage := {} ## member name -> count
var usage_typed := {} ## "Owner.member" -> count
var recent := {} ## "Owner.member" -> unix time

var _usage_by_file := {} ## res path -> [name counts, typed counts]
var _builtin := {}
var _engine_cache := {}
var _member_owners := {} ## member name -> [Member] across engine + builtin (lazy)


func _init() -> void:
	var f := FileAccess.open(BUILTIN_API_PATH, FileAccess.READ)
	if f:
		_builtin = JSON.parse_string(f.get_as_text())
	_load_recent()


# --- opening -------------------------------------------------------------------

## Loads every .gd under `dir` (an OS path to a Godot project folder).
func open_project(dir: String) -> void:
	root_dir = dir.replace("\\", "/").trim_suffix("/")
	files.clear()
	var paths: Array[String] = []
	_find_scripts(root_dir, paths)
	for p in paths:
		var sf := ScriptFile.open(p, root_dir)
		if sf:
			files[sf.res_path] = sf
	_read_autoloads()
	reindex_all()


## Adds a single already-loaded script (used by tests and for new files).
func add_file(sf: ScriptFile) -> void:
	files[sf.res_path] = sf


func reindex_all() -> void:
	classes.clear()
	by_path.clear()
	class_names.clear()
	usage.clear()
	usage_typed.clear()
	_usage_by_file.clear()
	for rp in files:
		_extract(files[rp])
	_resolve_parents()
	for rp in files:
		_infer_member_types(rp)
	for rp in files:
		_count_usage(files[rp])
	_resolve_autoload_types()


## Re-extracts one file after it changed and refreshes usage counts.
func reindex_file(res_path: String) -> void:
	var sf: ScriptFile = files.get(res_path)
	if sf == null:
		return
	for id in classes.keys():
		if classes[id].res_path == res_path:
			if not classes[id].class_name_.is_empty():
				class_names.erase(classes[id].class_name_)
			classes.erase(id)
	by_path.erase(res_path)
	_extract(sf)
	_resolve_parents()
	_infer_member_types(res_path)
	_count_usage(sf)
	file_reindexed.emit(res_path)


func to_os_path(res_path: String) -> String:
	if res_path.begins_with("res://"):
		return root_dir.path_join(res_path.trim_prefix("res://"))
	return res_path


func _find_scripts(dir: String, out: Array[String]) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	if FileAccess.file_exists(dir.path_join(".gdignore")):
		return
	for f in da.get_files():
		if f.get_extension() == "gd":
			out.append(dir.path_join(f))
	for d in da.get_directories():
		if d.begins_with("."):
			continue
		_find_scripts(dir.path_join(d), out)


func _read_autoloads() -> void:
	autoloads.clear()
	var cfg := ConfigFile.new()
	if cfg.load(root_dir.path_join("project.godot")) != OK or not cfg.has_section("autoload"):
		return
	for name in cfg.get_section_keys("autoload"):
		autoloads[name] = str(cfg.get_value("autoload", name)).trim_prefix("*")


func _resolve_autoload_types() -> void:
	for name in autoloads.keys():
		var p: String = autoloads[name]
		if p.ends_with(".gd"):
			autoloads[name] = by_path.get(p, "Node")
		elif p.begins_with("res://"):
			autoloads[name] = "Node"


# --- extraction ----------------------------------------------------------------

func _extract(sf: ScriptFile) -> void:
	var root := sf.named_tree()
	var c := ScriptClass.new()
	c.res_path = sf.res_path
	c.node = root
	for n in Cst.named(root):
		if n.type == "class_name_statement":
			c.class_name_ = sf.text(Cst.field(n, "name"))
			var ext := Cst.field(n, "extends")
			if not ext.is_empty():
				c.extends_raw = _extends_text(sf, ext)
		elif n.type == "extends_statement":
			c.extends_raw = _extends_text(sf, n)
	c.id = c.class_name_ if not c.class_name_.is_empty() else sf.res_path
	classes[c.id] = c
	by_path[sf.res_path] = c.id
	if not c.class_name_.is_empty():
		class_names[c.class_name_] = c.id
	_extract_body(sf, c, root)
	# preload("res://...") / load("res://...") edges.
	Cst.walk(root, func(n):
		if n.type == "call":
			var parts := Cst.named(n)
			if parts.size() >= 2 and sf.text(parts[0]) in ["preload", "load"]:
				var args := Cst.named(Cst.field(n, "arguments"))
				if args.size() > 0 and args[0].type == "string":
					var p := sf.text(args[0]).trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'")
					if not c.preloads.has(p):
						c.preloads.append(p)
	)


func _extends_text(sf: ScriptFile, ext: Dictionary) -> String:
	var t := sf.text(ext).strip_edges().trim_prefix("extends").strip_edges()
	return t.trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'")


func _extract_body(sf: ScriptFile, c: ScriptClass, body: Dictionary) -> void:
	for n in Cst.named(body):
		match n.type:
			"function_definition", "constructor_definition":
				var m := Member.new()
				m.name = sf.text(Cst.field(n, "name"))
				if m.name.is_empty():
					m.name = "_init"
				m.kind = "method"
				m.type = Cst.type_text(sf.doc, Cst.field(n, "return_type"))
				m.args = _params(sf, Cst.field(n, "parameters"))
				m.is_static = not Cst.first_of_type(n, "static_keyword").is_empty()
				_add_member(c, m, n)
			"variable_statement", "export_variable_statement", "onready_variable_statement", "const_statement":
				var m := Member.new()
				m.name = sf.text(Cst.field(n, "name"))
				m.kind = "constant" if n.type == "const_statement" else "property"
				m.type = Cst.type_text(sf.doc, Cst.field(n, "type"))
				m.is_static = n.type == "const_statement" or sf.text(n).strip_edges().begins_with("static")
				_add_member(c, m, n)
			"signal_statement":
				var m := Member.new()
				m.name = sf.text(Cst.field(n, "name"))
				m.kind = "signal"
				m.type = "Signal"
				m.args = _params(sf, Cst.field(n, "parameters"))
				_add_member(c, m, n)
			"enum_definition":
				var en := sf.text(Cst.field(n, "name"))
				if not en.is_empty():
					var m := Member.new()
					m.name = en
					m.kind = "enum"
					m.type = "int"
					m.is_static = true
					_add_member(c, m, n)
				var list := Cst.field(n, "body")
				for e in Cst.named(list):
					var v := Member.new()
					v.name = sf.text(Cst.field(e, "left"))
					v.kind = "constant"
					v.type = "int"
					v.is_static = true
					_add_member(c, v, e)
			"class_definition":
				var ic := ScriptClass.new()
				var iname := sf.text(Cst.field(n, "name"))
				ic.id = c.id + "." + iname
				ic.res_path = c.res_path
				ic.outer = c.id
				ic.node = n
				var ext := Cst.field(n, "extends")
				ic.extends_raw = _extends_text(sf, ext) if not ext.is_empty() else ""
				classes[ic.id] = ic
				c.inner.append(ic.id)
				var cm := Member.new()
				cm.name = iname
				cm.kind = "class"
				cm.type = "type:" + ic.id
				cm.is_static = true
				_add_member(c, cm, n)
				var ib := Cst.field(n, "body")
				if not ib.is_empty():
					_extract_body(sf, ic, ib)


func _add_member(c: ScriptClass, m: Member, n: Dictionary) -> void:
	m.owner = c.id
	m.source = "project"
	m.line = n.row
	c.members[m.name] = m


func _params(sf: ScriptFile, params: Dictionary) -> Array:
	var out := []
	if params.is_empty():
		return out
	for p in Cst.named(params):
		if p.type == "identifier":
			out.append({ name = sf.text(p), type = "" })
		else:
			var id := Cst.first_of_type(p, "identifier")
			out.append({ name = sf.text(id), type = Cst.type_text(sf.doc, Cst.field(p, "type")), has_default = not Cst.field(p, "value").is_empty() })
	return out


func _resolve_parents() -> void:
	for id in classes:
		var c: ScriptClass = classes[id]
		var raw := c.extends_raw
		if raw.is_empty():
			c.parent = "RefCounted"
		elif raw.begins_with("res://"):
			c.parent = by_path.get(raw, "RefCounted")
		elif class_names.has(raw):
			c.parent = class_names[raw]
		elif raw.contains("."):
			# Outer.Inner, or "res://x.gd".Inner
			var head := raw.get_slice(".", 0)
			var head_id: String = class_names.get(head, "")
			c.parent = head_id + raw.substr(head.length()) if not head_id.is_empty() and classes.has(head_id + raw.substr(head.length())) else raw
		elif c.outer != "" and classes.has(c.outer + "." + raw):
			c.parent = c.outer + "." + raw
		else:
			c.parent = raw


## `var x := Foo.new()` style members get their type from the value.
func _infer_member_types(res_path: String) -> void:
	var sf: ScriptFile = files.get(res_path)
	for id in classes:
		var c: ScriptClass = classes[id]
		if c.res_path != res_path:
			continue
		var body: Dictionary = c.node if c.node.type == "source" else Cst.field(c.node, "body")
		for n in Cst.named(body):
			if n.type in ["variable_statement", "export_variable_statement", "onready_variable_statement", "const_statement"]:
				var tn := Cst.field(n, "type")
				var m: Member = c.members.get(sf.text(Cst.field(n, "name")))
				if m and m.type.is_empty() and (tn.get("type", "") == "inferred_type" or n.type == "const_statement"):
					var r := TypeResolver.new(self, c.id, sf)
					m.type = r.resolve(Cst.field(n, "value"))


func _count_usage(sf: ScriptFile) -> void:
	var prev: Array = _usage_by_file.get(sf.res_path, [{}, {}])
	for k in prev[0]:
		usage[k] = usage.get(k, 0) - prev[0][k]
	for k in prev[1]:
		usage_typed[k] = usage_typed.get(k, 0) - prev[1][k]
	var names := {}
	var typed := {}
	var cls_id: String = by_path.get(sf.res_path, "")
	var c: ScriptClass = classes.get(cls_id)
	if c:
		c.refs.clear()
	for f in sf.functions():
		var owner_id := cls_id
		for part in f.class_path:
			owner_id += "." + part
		var r := TypeResolver.for_function(self, owner_id, sf, f.node)
		r.visit_usage(f.node, func(member_name: String, receiver_type: String):
			names[member_name] = names.get(member_name, 0) + 1
			var m: Member = find_member(receiver_type, member_name) if not receiver_type.is_empty() else null
			if m:
				typed[m.key()] = typed.get(m.key(), 0) + 1
		)
	# References to other project classes by name (for the macro view).
	if c:
		Cst.walk(sf.named_tree(), func(n):
			if n.type == "identifier":
				var t := sf.text(n)
				if class_names.has(t) and class_names[t] != cls_id:
					c.refs[class_names[t]] = c.refs.get(class_names[t], 0) + 1
			return true
		)
	for k in names:
		usage[k] = usage.get(k, 0) + names[k]
	for k in typed:
		usage_typed[k] = usage_typed.get(k, 0) + typed[k]
	_usage_by_file[sf.res_path] = [names, typed]


# --- type queries --------------------------------------------------------------

func is_builtin_type(t: String) -> bool:
	return _builtin.get("builtin", {}).has(t)


func is_project_type(t: String) -> bool:
	return classes.has(t)


func is_engine_type(t: String) -> bool:
	return ClassDB.class_exists(t)


func type_exists(t: String) -> bool:
	return is_project_type(t) or is_engine_type(t) or is_builtin_type(t) or t in ["int", "float", "bool", "void"]


## Display name for a type id.
func type_label(t: String) -> String:
	if t.is_empty():
		return "Variant"
	if t.begins_with("type:"):
		return type_label(t.substr(5))
	if t.begins_with("res://"):
		return t.get_file()
	return t


## Resolves a type written in source (`Player`, `Node3D`, `Array[int]`, `Inner`)
## from the point of view of class `context`.
func resolve_type_name(written: String, context := "") -> String:
	var t := written.strip_edges()
	if t.is_empty():
		return ""
	if class_names.has(t):
		return class_names[t]
	if not context.is_empty():
		var ctx := context
		while not ctx.is_empty():
			if classes.has(ctx + "." + t):
				return ctx + "." + t
			ctx = classes[ctx].outer if classes.has(ctx) else ""
	if t.contains(".") and class_names.has(t.get_slice(".", 0)):
		var full: String = class_names[t.get_slice(".", 0)] + t.substr(t.find("."))
		if classes.has(full):
			return full
	return t


func parent_of(t: String) -> String:
	if classes.has(t):
		return classes[t].parent
	if ClassDB.class_exists(t):
		return ClassDB.get_parent_class(t)
	return ""


## [t, parent, grandparent, ...]
func ancestors(t: String) -> Array[String]:
	var out: Array[String] = []
	var cur := t
	while not cur.is_empty() and not out.has(cur) and out.size() < 64:
		out.append(cur)
		cur = parent_of(cur)
	return out


func is_assignable(from: String, to: String) -> bool:
	if to.is_empty() or from == to:
		return true
	if from.is_empty():
		return false
	if to == "float" and from == "int":
		return true
	if to.begins_with("Array") and from.begins_with("Array"):
		return true
	return ancestors(from).has(to)


## Members declared on `t` itself (no inheritance).
func own_members(t: String) -> Array:
	if classes.has(t):
		return classes[t].members.values()
	if _engine_cache.has(t):
		return _engine_cache[t]
	var out := []
	if ClassDB.class_exists(t):
		out = _engine_members(t)
	elif is_builtin_type(t):
		out = _builtin_members(t)
	_engine_cache[t] = out
	return out


func find_member(t: String, name: String) -> Member:
	var static_only := t.begins_with("type:")
	var base := t.substr(5) if static_only else t
	for a in ancestors(base):
		if classes.has(a):
			var m: Member = classes[a].members.get(name)
			if m:
				return m
		else:
			for m in own_members(a):
				if m.name == name:
					return m
	return null


## Return type of a global function (utility or GDScript builtin), or null.
func global_function(name: String) -> Dictionary:
	if GDSCRIPT_GLOBALS.has(name):
		return GDSCRIPT_GLOBALS[name]
	return _builtin.get("utility", {}).get(name, {})


func global_functions() -> Dictionary:
	var out: Dictionary = _builtin.get("utility", {}).duplicate()
	out.merge(GDSCRIPT_GLOBALS, true)
	return out


func builtin_constructors(t: String) -> Array:
	return _builtin.get("builtin", {}).get(t, {}).get("constructors", [])


## Every member that exists anywhere under `name`, for Variant receivers.
func members_named(name: String) -> Array:
	_build_member_owners()
	var out: Array = _member_owners.get(name, []).duplicate()
	for id in classes:
		var m: Member = classes[id].members.get(name)
		if m:
			out.push_front(m)
	return out


func _build_member_owners() -> void:
	if not _member_owners.is_empty():
		return
	for cls in ClassDB.get_class_list():
		for m in own_members(cls):
			if not _member_owners.has(m.name):
				_member_owners[m.name] = []
			_member_owners[m.name].append(m)
	for t in _builtin.get("builtin", {}):
		for m in own_members(t):
			if not _member_owners.has(m.name):
				_member_owners[m.name] = []
			_member_owners[m.name].append(m)


func _engine_members(cls: String) -> Array:
	var out := []
	for md in ClassDB.class_get_method_list(cls, true):
		if (md.flags & METHOD_FLAG_VIRTUAL) and not str(md.name).begins_with("_"):
			continue
		var m := Member.new()
		m.name = md.name
		m.kind = "method"
		m.owner = cls
		m.source = "engine"
		m.type = _prop_type(md.get("return", {}), true)
		m.is_static = (md.flags & METHOD_FLAG_STATIC) != 0
		for a in md.args:
			m.args.append({ name = a.name, type = _prop_type(a) })
		out.append(m)
	for pd in ClassDB.class_get_property_list(cls, true):
		if pd.usage & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP):
			continue
		if str(pd.name).contains("/"):
			continue
		var m := Member.new()
		m.name = pd.name
		m.kind = "property"
		m.owner = cls
		m.source = "engine"
		m.type = _prop_type(pd)
		out.append(m)
	for sd in ClassDB.class_get_signal_list(cls, true):
		var m := Member.new()
		m.name = sd.name
		m.kind = "signal"
		m.owner = cls
		m.source = "engine"
		m.type = "Signal"
		for a in sd.args:
			m.args.append({ name = a.name, type = _prop_type(a) })
		out.append(m)
	for cn in ClassDB.class_get_integer_constant_list(cls, true):
		var m := Member.new()
		m.name = cn
		m.kind = "constant"
		m.owner = cls
		m.source = "engine"
		m.type = "int"
		m.is_static = true
		out.append(m)
	return out


func _builtin_members(t: String) -> Array:
	var out := []
	var info: Dictionary = _builtin.builtin[t]
	for name in info.methods:
		var md: Dictionary = info.methods[name]
		var m := Member.new()
		m.name = name
		m.kind = "method"
		m.owner = t
		m.source = "builtin"
		m.type = md.ret if not md.ret.is_empty() else "void"
		m.args = md.args
		m.is_static = md.static
		out.append(m)
	for name in info.members:
		var m := Member.new()
		m.name = name
		m.kind = "property"
		m.owner = t
		m.source = "builtin"
		m.type = info.members[name]
		out.append(m)
	for name in info.constants:
		var m := Member.new()
		m.name = name
		m.kind = "constant"
		m.owner = t
		m.source = "builtin"
		m.type = info.constants[name]
		m.is_static = true
		out.append(m)
	return out


## Converts a ClassDB property/argument/return dictionary to a type id.
static func _prop_type(d: Dictionary, is_return := false) -> String:
	if d.is_empty():
		return "void" if is_return else ""
	var t: int = d.get("type", TYPE_NIL)
	if t == TYPE_NIL:
		if is_return and not (d.get("usage", 0) & PROPERTY_USAGE_NIL_IS_VARIANT):
			return "void"
		return ""
	if t == TYPE_OBJECT:
		var cn: String = d.get("class_name", "")
		return cn if not cn.is_empty() else "Object"
	if t == TYPE_INT and str(d.get("class_name", "")).contains("."):
		return "int" # enum
	if t == TYPE_ARRAY and d.get("hint", 0) == PROPERTY_HINT_ARRAY_TYPE:
		return "Array[%s]" % d.get("hint_string", "")
	return type_string(t)


# --- usage / recency -----------------------------------------------------------

func frequency(m: Member) -> int:
	return usage_typed.get(m.key(), 0) + usage.get(m.name, 0)


func recency(m: Member) -> float:
	return recent.get(m.key(), 0.0)


func mark_used(m: Member) -> void:
	recent[m.key()] = Time.get_unix_time_from_system()
	if recent.size() > MAX_RECENT:
		var keys := recent.keys()
		keys.sort_custom(func(a, b): return recent[a] < recent[b])
		for i in keys.size() - MAX_RECENT:
			recent.erase(keys[i])
	_save_recent()


func _load_recent() -> void:
	var f := FileAccess.open(RECENT_PATH, FileAccess.READ)
	if f:
		var d = JSON.parse_string(f.get_as_text())
		if d is Dictionary:
			recent = d


func _save_recent() -> void:
	var f := FileAccess.open(RECENT_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(recent))


# --- helpers for views -----------------------------------------------------------

## Type id of the class a function belongs to.
func class_of_function(sf: ScriptFile, func_info: Dictionary) -> String:
	var id: String = by_path.get(sf.res_path, sf.res_path)
	for part in func_info.get("class_path", []):
		id += "." + part
	return id
