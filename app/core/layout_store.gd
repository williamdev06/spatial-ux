class_name LayoutStore
extends RefCounted
## Manual positions, kept in `<project>/.graphlayout.json`.
##
##   scripts[res_path].functions[qualname].nodes[stmt_key] = {p: [x,y,z], h: header hash, k: kind}
##   scripts[res_path].functions[qualname].board = [12 floats, Transform3D]
##   macro[class_id] = [x, y, z]
##
## Statement keys are "function body index paths" ("3", "3.then.0"). When the
## file changed outside the tool, an entry is kept only if the statement at its
## key still has the same header hash; otherwise it is re-attached to the one
## statement in the function with that hash, if there is exactly one. Anything
## else falls back to auto-layout.

const FILE_NAME := ".graphlayout.json"
const VERSION := 1

var path := ""
var data := { version = VERSION, scripts = {}, macro = {} }
var dirty := false


func open(project_root: String) -> void:
	path = project_root.path_join(FILE_NAME)
	data = { version = VERSION, scripts = {}, macro = {} }
	if FileAccess.file_exists(path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary and parsed.get("version", 0) == VERSION:
			data = parsed
			if not data.has("macro"):
				data.macro = {}
	dirty = false


func save() -> void:
	if path.is_empty() or not dirty:
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t", true))
		dirty = false


func _func_entry(res_path: String, qualname: String, create: bool) -> Dictionary:
	var scripts: Dictionary = data.scripts
	if not scripts.has(res_path):
		if not create:
			return {}
		scripts[res_path] = { functions = {} }
	var fns: Dictionary = scripts[res_path].functions
	if not fns.has(qualname):
		if not create:
			return {}
		fns[qualname] = { nodes = {} }
	return fns[qualname]


# --- boards ----------------------------------------------------------------------

func get_board(res_path: String, qualname: String) -> Variant:
	var e := _func_entry(res_path, qualname, false)
	if e.is_empty() or not e.has("board"):
		return null
	return _arr_to_xform(e.board)


func set_board(res_path: String, qualname: String, xf: Transform3D) -> void:
	_func_entry(res_path, qualname, true).board = _xform_to_arr(xf)
	dirty = true


# --- statement nodes -------------------------------------------------------------

## Positions for the statements of `g` that still match a stored entry.
## Matched entries are re-keyed to the statements' current keys.
func node_positions(res_path: String, g: FunctionGraph) -> Dictionary:
	var e := _func_entry(res_path, g.qualname, false)
	if e.is_empty() or e.nodes.is_empty():
		return {}
	var stored: Dictionary = e.nodes
	var out := {}
	var used := {}
	# 1. Same key, same header.
	for s in g.stmts:
		var en = stored.get(s.key)
		if en is Dictionary and int(en.h) == s.hash and en.k == s.kind:
			out[s.key] = _arr_to_v3(en.p)
			used[s.key] = true
	# 2. Same header somewhere else in the function, if unambiguous.
	var by_hash := {}
	for k in stored:
		if used.has(k):
			continue
		var h := int(stored[k].h)
		by_hash[h] = [] if not by_hash.has(h) else by_hash[h]
		by_hash[h].append(k)
	var stmt_hash_count := {}
	for s in g.stmts:
		stmt_hash_count[s.hash] = stmt_hash_count.get(s.hash, 0) + 1
	for s in g.stmts:
		if out.has(s.key):
			continue
		var cands: Array = by_hash.get(s.hash, [])
		if cands.size() == 1 and stmt_hash_count[s.hash] == 1:
			out[s.key] = _arr_to_v3(stored[cands[0]].p)
	# Re-key so the next lookup is a direct hit.
	var rekeyed := {}
	for s in g.stmts:
		if out.has(s.key):
			rekeyed[s.key] = { p = _v3_to_arr(out[s.key]), h = s.hash, k = s.kind }
	if rekeyed.hash() != stored.hash():
		e.nodes = rekeyed
		dirty = true
	return out


func set_node(res_path: String, qualname: String, s: FunctionGraph.Stmt, pos: Vector3) -> void:
	_func_entry(res_path, qualname, true).nodes[s.key] = { p = _v3_to_arr(pos), h = s.hash, k = s.kind }
	dirty = true


func clear_nodes(res_path: String, qualname: String) -> void:
	var e := _func_entry(res_path, qualname, false)
	if not e.is_empty():
		e.nodes = {}
		dirty = true


# --- macro view ------------------------------------------------------------------

func get_macro(class_id: String) -> Variant:
	var v = data.macro.get(class_id)
	return _arr_to_v3(v) if v is Array else null


func set_macro(class_id: String, pos: Vector3) -> void:
	data.macro[class_id] = _v3_to_arr(pos)
	dirty = true


# --- conversions -----------------------------------------------------------------

static func _v3_to_arr(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]


static func _arr_to_v3(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])


static func _xform_to_arr(t: Transform3D) -> Array:
	var b := t.basis
	return [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z, t.origin.x, t.origin.y, t.origin.z].map(func(f): return snappedf(f, 0.0001))


static func _arr_to_xform(a: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]), Vector3(a[6], a[7], a[8])), Vector3(a[9], a[10], a[11]))
