class_name ScriptFile
extends RefCounted
## One .gd file of the opened project. The bytes in `doc` are the single source
## of truth: graphs are rebuilt from them, and every graph operation reaches
## the file as a byte-range edit followed by an incremental re-parse.

## Emitted after the text changed. `external` is true when the change came from
## another program editing the file on disk.
signal changed(external: bool)

const MAX_UNDO := 200

var path: String ## Absolute OS path.
var res_path: String ## Path as the opened project sees it ("res://...").
var doc := GDSyntaxDocument.new()

var _tree: Dictionary
var _tree_version := -1
var _named_tree: Dictionary
var _named_version := -1
var _disk_bytes := PackedByteArray()
var _disk_mtime := 0
var _undo: Array[PackedByteArray] = []
var _redo: Array[PackedByteArray] = []
var _group_depth := 0
var _group_snapshot_taken := false


static func open(os_path: String, project_root: String) -> ScriptFile:
	var f := ScriptFile.new()
	f.path = os_path
	f.res_path = ScriptFile.to_res_path(os_path, project_root)
	if f.reload() != OK:
		return null
	return f


static func to_res_path(os_path: String, project_root: String) -> String:
	var root := project_root.replace("\\", "/").trim_suffix("/")
	var p := os_path.replace("\\", "/")
	if p.begins_with(root + "/"):
		return "res://" + p.substr(root.length() + 1)
	return p


func reload() -> Error:
	var err := doc.load_file(path)
	if err != OK:
		return err
	_disk_bytes = doc.get_source_bytes()
	_disk_mtime = FileAccess.get_modified_time(path)
	return OK


## Full CST including anonymous tokens (operators, punctuation).
func tree() -> Dictionary:
	if _tree_version != doc.get_version():
		_tree = doc.get_tree(true)
		_tree_version = doc.get_version()
	return _tree


## Lighter CST with only named nodes (plus anonymous nodes that carry a field).
func named_tree() -> Dictionary:
	if _named_version != doc.get_version():
		_named_tree = doc.get_tree(false)
		_named_version = doc.get_version()
	return _named_tree


func text(n: Dictionary) -> String:
	if n.is_empty():
		return ""
	return doc.get_text(n.start, n.end)


# --- editing -----------------------------------------------------------------

## Groups several apply_edits() calls into a single undo step.
func begin_group() -> void:
	if _group_depth == 0:
		_group_snapshot_taken = false
	_group_depth += 1


func end_group() -> void:
	_group_depth = maxi(0, _group_depth - 1)


func apply_edits(edits: Array, save := true) -> bool:
	if edits.is_empty():
		return true
	var before := doc.get_source_bytes()
	if not doc.apply_edits(edits):
		return false
	if doc.get_source_bytes() == before:
		return true
	if _group_depth == 0 or not _group_snapshot_taken:
		_push_undo(before)
		_group_snapshot_taken = _group_depth > 0
	_redo.clear()
	if save:
		save_to_disk()
	changed.emit(false)
	return true


func can_undo() -> bool:
	return not _undo.is_empty()


func undo() -> bool:
	if _undo.is_empty():
		return false
	_redo.append(doc.get_source_bytes())
	doc.set_source_bytes(_undo.pop_back())
	save_to_disk()
	changed.emit(false)
	return true


func redo() -> bool:
	if _redo.is_empty():
		return false
	_push_undo(doc.get_source_bytes())
	doc.set_source_bytes(_redo.pop_back())
	save_to_disk()
	changed.emit(false)
	return true


func _push_undo(bytes: PackedByteArray) -> void:
	_undo.append(bytes)
	if _undo.size() > MAX_UNDO:
		_undo.pop_front()


func save_to_disk() -> Error:
	var err := doc.save_file(path)
	if err == OK:
		_disk_bytes = doc.get_source_bytes()
		_disk_mtime = FileAccess.get_modified_time(path)
	return err


## Picks up edits made by other programs. Returns true when the text changed.
func poll_external_change() -> bool:
	if not FileAccess.file_exists(path):
		return false
	var mtime := FileAccess.get_modified_time(path)
	# mtime has 1 s resolution: within a couple of seconds of our own write a
	# second write can keep the same mtime, so compare bytes then.
	if mtime == _disk_mtime and Time.get_unix_time_from_system() - mtime > 2.0:
		return false
	_disk_mtime = mtime
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes == _disk_bytes:
		return false
	_disk_bytes = bytes
	if bytes == doc.get_source_bytes():
		return false
	_push_undo(doc.get_source_bytes())
	doc.set_source_bytes(bytes)
	changed.emit(true)
	return true


# --- structure ---------------------------------------------------------------

## Every function in the file, including those of inner classes:
## [{name, qualname, node, class_path}] where class_path is e.g. ["Inner"].
func functions() -> Array:
	var out := []
	_collect_functions(named_tree(), [], out)
	return out


func _collect_functions(n: Dictionary, class_path: Array, out: Array) -> void:
	for c in Cst.named(n):
		match c.type:
			"function_definition", "constructor_definition":
				var fname := text(Cst.field(c, "name"))
				if fname.is_empty():
					fname = "_init"
				var qual := ".".join(class_path + [fname])
				out.append({ name = fname, qualname = qual, node = c, class_path = class_path })
			"class_definition":
				var cname := text(Cst.field(c, "name"))
				var body := Cst.field(c, "body")
				if not body.is_empty():
					_collect_functions(body, class_path + [cname], out)


func find_function(qualname: String) -> Dictionary:
	for f in functions():
		if f.qualname == qualname:
			return f
	return {}


## The file's indentation unit: a tab, or the smallest space indent in use.
func indent_unit() -> String:
	var src := doc.get_source()
	var best := ""
	for line in src.split("\n"):
		if line.strip_edges().is_empty():
			continue
		if line.begins_with("\t"):
			return "\t"
		if line.begins_with(" "):
			var n := line.length() - line.lstrip(" ").length()
			if best.is_empty() or n < best.length():
				best = " ".repeat(n)
	return best if not best.is_empty() else "\t"
