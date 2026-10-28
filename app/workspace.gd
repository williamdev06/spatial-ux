class_name Workspace
extends Node3D
## The open project: index, layout sidecar, macro view, function boards,
## panels and every editing operation. Input-agnostic: desktop and VR rigs
## only feed Pointers to `interaction` and key events to handle_key().

signal status_changed(text: String)
signal project_opened(path: String)

const POLL_SECONDS := 1.0
const RESCAN_SECONDS := 4.0
const SAVE_DELAY := 0.6
const MIN_WORLD_SCALE := 0.05
const MAX_WORLD_SCALE := 20.0
const KEYBOARD_REACH := 1.2 ## A keyboard put further away than this is brought back.
const KEYBOARD_TILT := deg_to_rad(35.0)

const STATEMENT_TEMPLATES := [
	["if", "if condition:\n\tpass"],
	["if / else", "if condition:\n\tpass\nelse:\n\tpass"],
	["for", "for i in range(10):\n\tpass"],
	["while", "while condition:\n\tpass"],
	["var", "var value = null"],
	["set", "target = value"],
	["return", "return"],
	["print()", "print()"],
	["await", "await get_tree().process_frame"],
	["match", "match value:\n\t_:\n\t\tpass"],
	["pass", "pass"],
]

var index := ProjectIndex.new()
var layout_store := LayoutStore.new()
var search := MemberSearch.new(index)
var interaction: Interaction
var macro: MacroView
var keyboard: VirtualKeyboard
var project_path := ""
var selection := { board = null, key = "" }
var head_provider: Callable ## -> Transform3D of the viewer's head / camera
var is_xr := false

var _boards := {} ## class id -> Array[FunctionBoard]
var _dirty_files := {} ## res path -> external?
var _panel: Panel3D ## Open edit / search panel, if any.
var _wire := { pin = null, mesh = null, imesh = null, distance = 1.0 }
var _poll_t := 0.0
var _rescan_t := 0.0
var _save_t := -1.0
var _last_file: ScriptFile


func _ready() -> void:
	interaction = Interaction.new()
	interaction.name = "Interaction"
	add_child(interaction)
	macro = MacroView.new()
	macro.name = "Macro"
	macro.workspace = self
	macro.position = Vector3(0, 1.4, 0)
	add_child(macro)
	keyboard = VirtualKeyboard.new()
	keyboard.name = "Keyboard"
	keyboard.visible = false
	keyboard.top_level = true # keeps its real-world size when the world is scaled
	keyboard.key_event.connect(handle_key)
	add_child(keyboard)
	_set_keyboard_enabled(false)
	var wmi := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	wmi.mesh = im
	var wm := StandardMaterial3D.new()
	wm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wm.albedo_color = Style.SELECT_COLOR
	wm.no_depth_test = true
	wmi.material_override = wm
	wmi.top_level = true # vertices are global positions
	add_child(wmi)
	_wire.mesh = wmi
	_wire.imesh = im
	index.file_reindexed.connect(func(_p): pass)


func status(text: String) -> void:
	print("[spatial-ux] ", text)
	status_changed.emit(text)


# --- project -------------------------------------------------------------------

func open_project(path: String) -> bool:
	var dir := path.replace("\\", "/").trim_suffix("/")
	if dir.ends_with("project.godot"):
		dir = dir.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		status("Not a folder: " + dir)
		return false
	close_project()
	project_path = dir
	var t0 := Time.get_ticks_msec()
	index.open_project(dir)
	layout_store.open(dir)
	for rp in index.files:
		_watch(index.files[rp])
	macro.refresh()
	status("Opened %s: %d scripts, %d classes (%d ms)" % [dir.get_file(), index.files.size(), index.classes.size(), Time.get_ticks_msec() - t0])
	project_opened.emit(dir)
	return true


func close_project() -> void:
	layout_store.save()
	_close_panel()
	for id in _boards:
		for b in _boards[id]:
			b.queue_free()
	_boards.clear()
	macro.clear()
	selection = { board = null, key = "" }
	project_path = ""


func _watch(sf: ScriptFile) -> void:
	sf.changed.connect(func(external: bool): _dirty_files[sf.res_path] = _dirty_files.get(sf.res_path, false) or external)


func _process(dt: float) -> void:
	if project_path.is_empty():
		return
	_poll_t += dt
	if _poll_t >= POLL_SECONDS:
		_poll_t = 0.0
		for rp in index.files:
			index.files[rp].poll_external_change()
	_rescan_t += dt
	if _rescan_t >= RESCAN_SECONDS:
		_rescan_t = 0.0
		_rescan()
	if not _dirty_files.is_empty():
		var dirty := _dirty_files
		_dirty_files = {}
		for rp in dirty:
			_refresh_file(rp, dirty[rp])
	if _save_t >= 0.0:
		_save_t -= dt
		if _save_t < 0.0:
			layout_store.save()


## Picks up .gd files that were added or deleted outside the tool.
func _rescan() -> void:
	var paths: Array[String] = []
	index._find_scripts(project_path, paths)
	var seen := {}
	var changed := false
	for p in paths:
		var rp := ScriptFile.to_res_path(p, project_path)
		seen[rp] = true
		if not index.files.has(rp):
			var sf := ScriptFile.open(p, project_path)
			if sf:
				index.add_file(sf)
				_watch(sf)
				changed = true
	for rp in index.files.keys():
		if not seen.has(rp):
			index.files.erase(rp)
			changed = true
	if changed:
		index.reindex_all()
		macro.refresh()
		status("Project files changed on disk; re-indexed")


func _refresh_file(res_path: String, external: bool) -> void:
	index.reindex_file(res_path)
	var cls: String = index.by_path.get(res_path, "")
	for id in _boards.keys():
		for b in _boards[id].duplicate():
			if b.file.res_path == res_path and not b.rebuild():
				_boards[id].erase(b)
				b.queue_free()
	# New functions (made here or elsewhere) appear on expanded classes.
	if _boards.has(cls) and macro.nodes.has(cls) and macro.nodes[cls].expanded:
		_add_missing_boards(cls)
	if external:
		status("Reloaded %s (changed on disk)" % res_path.get_file())
	macro.refresh()


func layout_changed() -> void:
	_save_t = SAVE_DELAY


# --- macro / boards ----------------------------------------------------------------

func toggle_class(class_id: String) -> void:
	var n: ClassNode3D = macro.nodes.get(class_id)
	if n == null:
		return
	if n.expanded:
		for b in _boards.get(class_id, []):
			b.queue_free()
		_boards.erase(class_id)
		n.expanded = false
		n.set_highlight(false)
		n.set_label_top(-1.0)
	else:
		n.expanded = true
		n.set_highlight(true)
		_face_viewer(n.boards_root)
		_boards[class_id] = []
		_add_missing_boards(class_id)
		macro.reheat()
		status("%s: %d functions" % [index.type_label(class_id), _boards[class_id].size()])


func _add_missing_boards(class_id: String) -> void:
	var c: ProjectIndex.ScriptClass = index.classes.get(class_id)
	if c == null:
		return
	var sf: ScriptFile = index.files.get(c.res_path)
	var n: ClassNode3D = macro.nodes[class_id]
	var open := {}
	for b in _boards[class_id]:
		open[b.qualname] = true
	var unplaced: Array[FunctionBoard] = []
	for f in sf.functions():
		if open.has(f.qualname):
			continue
		var b := FunctionBoard.new().setup(self, sf, f.qualname)
		n.boards_root.add_child(b)
		b.rebuild()
		_boards[class_id].append(b)
		var stored = layout_store.get_board(sf.res_path, f.qualname)
		var near: FunctionBoard = _pending_place.get(sf.res_path + "|" + f.qualname)
		_pending_place.erase(sf.res_path + "|" + f.qualname)
		if stored != null:
			b.transform = stored
		elif is_instance_valid(near) and near.get_parent() == b.get_parent():
			# Created from another board: put it right next to that one.
			var nr := near.bounds()
			var br := b.bounds()
			b.transform = near.transform.translated_local(Vector3(nr.position.x + nr.size.x + 0.2 - br.position.x, -nr.position.y + br.position.y, 0))
			board_moved(b)
		else:
			unplaced.append(b)
	_arrange_boards(n, unplaced)
	var top := 0.0
	for b in _boards[class_id]:
		top = maxf(top, b.position.y - b.bounds().position.y + 0.1)
	n.set_label_top(top)


## Packs boards into centred rows in front of the class node. Rows stack
## upward from just above the floor (boards hang down from their top-left
## corner, so tall boards would otherwise sink through it); boards already
## open stay where they are and new rows go above them.
func _arrange_boards(n: ClassNode3D, boards: Array[FunctionBoard]) -> void:
	if boards.is_empty():
		return
	const MAX_ROW := 5.0
	const GAP := 0.2
	const FLOOR_CLEARANCE := 0.25
	var rows: Array = [[]]
	var width := 0.0
	for b in boards:
		var w := b.bounds().size.x
		if not rows[-1].is_empty() and width + w > MAX_ROW:
			rows.append([])
			width = 0.0
		rows[-1].append(b)
		width += w + GAP
	var bottom := (FLOOR_CLEARANCE - n.global_position.y) / n.boards_root.global_basis.get_scale().y
	for b in _boards.get(n.class_id, []):
		if not boards.has(b):
			bottom = maxf(bottom, b.position.y - b.bounds().position.y + GAP)
	for row in rows:
		var row_w := -GAP
		var row_h := 0.0
		for b in row:
			row_w += b.bounds().size.x + GAP
			row_h = maxf(row_h, b.bounds().size.y)
		var x := -row_w * 0.5
		for b in row:
			var r: Rect2 = b.bounds()
			# Board origin -> bounds: local x in [r.x, r.x + w], local y in [-(r.y + h), -r.y].
			b.position = Vector3(x - r.position.x, bottom + row_h + r.position.y, 0.3)
			x += r.size.x + GAP
		bottom += row_h + GAP + 0.1


func _face_viewer(node: Node3D) -> void:
	if not head_provider.is_valid():
		return
	var head: Vector3 = head_provider.call().origin
	var to := head - node.global_position
	to.y = 0.0
	if to.length() < 0.01:
		return
	node.global_basis = Basis.looking_at(-to.normalized(), Vector3.UP).scaled(node.global_basis.get_scale())


func close_board(b: FunctionBoard) -> void:
	for id in _boards:
		_boards[id].erase(b)
	if selection.board == b:
		selection = { board = null, key = "" }
	b.queue_free()


func board_moved(b: FunctionBoard) -> void:
	layout_store.set_board(b.file.res_path, b.qualname, b.transform)
	layout_changed()


func relayout(b: FunctionBoard) -> void:
	layout_store.clear_nodes(b.file.res_path, b.qualname)
	layout_changed()
	b.rebuild()


func all_boards() -> Array:
	var out := []
	for id in _boards:
		out.append_array(_boards[id])
	return out


# --- selection -----------------------------------------------------------------------

func select(b: FunctionBoard, key: String) -> void:
	var old: FunctionBoard = selection.board
	if is_instance_valid(old) and old.nodes.has(selection.key):
		old.nodes[selection.key].set_selected(false)
	selection = { board = b, key = key }
	if b and b.nodes.has(key):
		b.nodes[key].set_selected(true)
		_last_file = b.file


func _selected_stmt() -> FunctionGraph.Stmt:
	var b: FunctionBoard = selection.board
	if not is_instance_valid(b) or b.graph == null:
		return null
	return b.graph.get_stmt(selection.key)


# --- running edits -------------------------------------------------------------------

## Runs a GraphEdits operation against a fresh graph, applying normalisation
## steps and retrying as needed. All steps form one undo step.
func run_op(b: FunctionBoard, op: Callable) -> bool:
	var sf := b.file
	_last_file = sf
	sf.begin_group()
	var ok := false
	for attempt in 4:
		var g := b.fresh_graph()
		if g == null:
			break
		var r: Dictionary = op.call(g)
		if r.is_empty():
			break
		if not sf.apply_edits(r.edits):
			break
		if not r.get("retry", false):
			ok = true
			break
	sf.end_group()
	if not ok:
		status("That edit is not possible here")
	return ok


func _adapt_indent(code: String, sf: ScriptFile) -> String:
	var unit := sf.indent_unit()
	if unit == "\t":
		return code
	var lines := code.split("\n")
	for i in lines.size():
		var tabs := 0
		while tabs < lines[i].length() and lines[i][tabs] == "\t":
			tabs += 1
		lines[i] = unit.repeat(tabs) + lines[i].substr(tabs)
	return "\n".join(lines)


func delete_selected() -> void:
	var s := _selected_stmt()
	if s == null or s.kind == "entry":
		return
	var b: FunctionBoard = selection.board
	var key := s.key
	if run_op(b, func(g): return GraphEdits.delete_statement(b.file.doc, g, g.get_stmt(key))):
		status("Deleted statement")


func move_selected(delta: int) -> void:
	var s := _selected_stmt()
	if s == null or s.kind == "entry":
		return
	var b: FunctionBoard = selection.board
	var body := b.graph.get_body(s.body_key)
	var i := body.stmt_keys.find(s.key)
	var j := i + delta
	if j < 0 or j >= body.stmt_keys.size():
		return
	var key := s.key
	var ok := false
	if delta < 0 and j == 0:
		ok = run_op(b, func(g): return GraphEdits.move_to_body_start(b.file.doc, g, g.get_stmt(key), s.body_key))
	else:
		var target_key: String = body.stmt_keys[j if delta > 0 else j - 1]
		ok = run_op(b, func(g): return GraphEdits.move_after(b.file.doc, g, g.get_stmt(key), g.get_stmt(target_key)))
	if ok:
		var dot := key.rfind(".")
		selection.key = (key.substr(0, dot + 1) if dot >= 0 else "") + str(j)


func undo() -> void:
	var sf := _target_file()
	if sf and sf.undo():
		status("Undo in " + sf.res_path.get_file())


func redo() -> void:
	var sf := _target_file()
	if sf and sf.redo():
		status("Redo in " + sf.res_path.get_file())


func _target_file() -> ScriptFile:
	if is_instance_valid(selection.board):
		return selection.board.file
	return _last_file


# --- inline editing --------------------------------------------------------------------

func edit_field(b: FunctionBoard, key: String, field_name: String) -> void:
	var s := b.graph.get_stmt(key)
	var f := s.get_field(field_name) if s else null
	if f == null:
		return
	if s.kind == "code":
		edit_raw(b, key)
		return
	if s.kind == "entry":
		_edit_entry_field(b, f)
		return
	var title := "%s › %s" % [s.title, f.label if not f.label.is_empty() else f.name]
	if not f.expect_type.is_empty():
		title += "   (%s)" % index.type_label(f.expect_type)
	var p := EditPanel.new()
	_show_panel(p, b.nodes[key])
	p.open(title, f.text, false)
	var hash := s.hash
	p.committed.connect(func(text: String):
		_close_panel()
		run_op(b, func(g):
			var ss: FunctionGraph.Stmt = g.get_stmt(key)
			if ss == null or ss.hash != hash:
				return {}
			return GraphEdits.set_field(b.file.doc, ss, ss.get_field(field_name), text))
	)
	p.cancelled.connect(_close_panel)


func edit_raw(b: FunctionBoard, key: String) -> void:
	var s := b.graph.get_stmt(key)
	if s == null:
		return
	if s.kind == "entry":
		edit_signature(b)
		return
	var p := EditPanel.new()
	_show_panel(p, b.nodes[key])
	p.open("Edit statement (%s)" % s.kind, GraphEdits.statement_text(b.file.doc, s), true)
	var hash := s.hash
	p.committed.connect(func(text: String):
		_close_panel()
		run_op(b, func(g):
			var ss: FunctionGraph.Stmt = g.get_stmt(key)
			if ss == null or ss.hash != hash:
				return {}
			return GraphEdits.replace_statement(b.file.doc, ss, _adapt_indent(text, b.file)))
	)
	p.cancelled.connect(_close_panel)


# --- functions: create, delete, rename, inputs and output ------------------------------

const BASIC_TYPES := ["void", "bool", "int", "float", "String", "StringName", "Vector2", "Vector2i", "Vector3", "Vector3i",
	"Color", "Array", "Dictionary", "Callable", "Signal", "NodePath", "Variant"]
const DELETE_CONFIRM_MS := 3000

var _pending_place := {} ## "res|qualname" -> FunctionBoard to put a new board next to
var _delete_armed := {} ## FunctionBoard -> ticks of the first click


func _edit_entry_field(b: FunctionBoard, f: FunctionGraph.Field) -> void:
	var near: Node3D = b.nodes["entry"]
	if f.name == "name":
		_prompt(near, "Rename %s" % b.qualname, f.text, func(t: String): rename_function(b, t))
	elif f.name == "ret":
		_pick_type(b, "Output (return type) of %s" % b.qualname, func(t: String): _set_entry_field(b, "ret", "" if t == "void" and f.is_absent() else t))
	elif f.name.begins_with("param"):
		var i := f.name.trim_prefix("param").to_int()
		_prompt(near, "Input of %s" % b.qualname, f.text, func(t: String):
			if t.strip_edges().is_empty():
				remove_input(b, i)
			else:
				_set_entry_field(b, f.name, t),
			"name: Type = default   ·   empty removes the input")


func _prompt(near: Node3D, title: String, text: String, on_commit: Callable, hint := "") -> void:
	var p := EditPanel.new()
	_show_panel(p, near)
	p.open(title, text, false, hint)
	p.committed.connect(func(t: String):
		_close_panel()
		on_commit.call(t))
	p.cancelled.connect(_close_panel)


func _set_entry_field(b: FunctionBoard, fname: String, text: String) -> bool:
	return run_op(b, func(g):
		var e: FunctionGraph.Stmt = g.get_stmt("entry")
		var f: FunctionGraph.Field = e.get_field(fname)
		return GraphEdits.set_field(b.file.doc, e, f, text) if f else {})


## Shows a type list (with a free-text option) and calls on_pick(type).
func _pick_type(b: FunctionBoard, title: String, on_pick: Callable) -> void:
	var cands := []
	var add := func(t: String, group: String):
		var c := MemberSearch.Candidate.new()
		c.label = t
		c.expr = t
		c.kind = "type"
		c.group_label = group
		cands.append(c)
	for t in BASIC_TYPES:
		add.call(t, "Basic")
	var project := index.class_names.keys()
	project.sort()
	for t in project:
		add.call(t, "Project")
	var engine := Array(ClassDB.get_class_list())
	engine.sort()
	for t in engine:
		if not str(t).begins_with("_"):
			add.call(t, "Engine")
	for i in cands.size():
		cands[i].rank = i
	var p := SearchPanel.new()
	_show_panel(p, b.nodes["entry"])
	p.open(title, cands, true)
	p.chosen.connect(func(c: MemberSearch.Candidate):
		_close_panel()
		on_pick.call(c.expr))
	p.cancelled.connect(_close_panel)


func add_input(b: FunctionBoard, preset := "value: int") -> void:
	_prompt(b.nodes["entry"], "New input for %s" % b.qualname, preset, func(t: String):
		if run_op(b, func(g): return GraphEdits.add_param(b.file.doc, g, t)):
			status("Added input %s" % t.strip_edges())
		else:
			status("Not a valid new input (bad or duplicate name?)"),
		"name: Type   ·   name := default")


func remove_input(b: FunctionBoard, index_: int) -> void:
	if run_op(b, func(g): return GraphEdits.remove_param(b.file.doc, g, index_)):
		status("Removed input (call sites are not updated)")


## Qualname prefix ("Inner." etc.) for functions of `qualname`'s class.
static func _qual_prefix(qualname: String) -> String:
	var dot := qualname.rfind(".")
	return qualname.substr(0, dot + 1) if dot >= 0 else ""


func rename_function(b: FunctionBoard, new_name: String) -> void:
	var n := new_name.strip_edges()
	if not n.is_valid_identifier():
		status("'%s' is not a valid function name" % n)
		return
	var old := b.qualname
	var new_qual := _qual_prefix(old) + n
	if new_qual == old:
		return
	if not b.file.find_function(new_qual).is_empty():
		status("%s already exists" % new_qual)
		return
	if _set_entry_field(b, "name", n):
		_retarget_board(b, old, new_qual)
		status("Renamed %s to %s (call sites are not updated)" % [old, new_qual])


func edit_signature(b: FunctionBoard) -> void:
	var f := b.file.find_function(b.qualname)
	if f.is_empty():
		return
	var name_node := Cst.field(f.node, "name")
	var ret := Cst.field(f.node, "return_type")
	var params := Cst.field(f.node, "parameters")
	var current := b.file.doc.get_text(name_node.start, ret.end if not ret.is_empty() else params.end)
	_prompt(b.nodes["entry"], "Signature of %s" % b.qualname, current, func(t: String):
		var sig := GraphEdits.parse_signature(t)
		if sig.is_empty():
			status("Not a valid signature")
			return
		var old := b.qualname
		var new_qual: String = _qual_prefix(old) + sig.name
		if new_qual != old and not b.file.find_function(new_qual).is_empty():
			status("%s already exists" % new_qual)
			return
		if run_op(b, func(g): return GraphEdits.set_signature(b.file.doc, g, t)) and new_qual != old:
			_retarget_board(b, old, new_qual),
		"name(inputs) -> output")


func _retarget_board(b: FunctionBoard, old: String, new_qual: String) -> void:
	b.qualname = new_qual
	b.name = "Board_" + new_qual.replace(".", "_")
	layout_store.rename_function(b.file.res_path, old, new_qual)
	layout_changed()


## Asks for a signature and creates the function after `after` (or at the end
## of the class when there is no board to anchor to).
func prompt_new_function(class_id: String, after: FunctionBoard = null) -> void:
	var near: Node3D = after if after else macro.nodes.get(class_id)
	if near == null:
		return
	_prompt(near, "New function in %s" % index.type_label(class_id), "new_function() -> void", func(t: String):
		create_function(class_id, after, t),
		"name(inputs) -> output")


func create_function(class_id: String, after: FunctionBoard, text: String) -> bool:
	var sig := GraphEdits.parse_signature(text)
	if sig.is_empty():
		status("Not a valid function signature")
		return false
	var c: ProjectIndex.ScriptClass = index.classes.get(class_id)
	if after:
		c = index.classes.get(after.self_type, c)
	if c == null:
		return false
	var sf: ScriptFile = index.files[c.res_path]
	var class_path := _class_path(c)
	var qual := ".".join(class_path + [sig.name])
	if not sf.find_function(qual).is_empty():
		status("%s already exists" % qual)
		return false
	var after_node := {}
	if after:
		after_node = sf.find_function(after.qualname).get("node", {})
	else:
		for f in sf.functions():
			if f.class_path == class_path:
				after_node = f.node
	var class_node := sf.named_tree() if class_path.is_empty() else _find_class_node(sf, class_path)
	var r := GraphEdits.create_function(sf.doc, sf, after_node, class_node, text)
	if r.is_empty() or not sf.apply_edits(r.edits):
		status("Could not add %s here" % sig.name)
		return false
	_last_file = sf
	var top := c.id
	while not index.classes[top].outer.is_empty():
		top = index.classes[top].outer
	if after:
		_pending_place[sf.res_path + "|" + qual] = after
	if macro.nodes.has(top) and not macro.nodes[top].expanded:
		toggle_class(top)
	status("Created %s" % qual)
	return true


func _class_path(c: ProjectIndex.ScriptClass) -> Array:
	var out := []
	while not c.outer.is_empty():
		out.push_front(c.id.substr(c.outer.length() + 1))
		c = index.classes[c.outer]
	return out


func _find_class_node(sf: ScriptFile, class_path: Array) -> Dictionary:
	var node := sf.named_tree()
	for part in class_path:
		var found := {}
		var container: Dictionary = node if node.type == "source" else Cst.field(node, "body")
		for n in Cst.named(container):
			if n.type == "class_definition" and sf.text(Cst.field(n, "name")) == part:
				found = n
		if found.is_empty():
			return {}
		node = found
	return node


## Deletes the board's function on the second click within a few seconds.
func delete_function(b: FunctionBoard) -> void:
	var now := Time.get_ticks_msec()
	if now - _delete_armed.get(b, -DELETE_CONFIRM_MS * 2) > DELETE_CONFIRM_MS:
		_delete_armed[b] = now
		status("Click delete again to remove %s (Ctrl+Z undoes it)" % b.qualname)
		return
	_delete_armed.erase(b)
	var f := b.file.find_function(b.qualname)
	if f.is_empty():
		return
	_last_file = b.file
	if b.file.apply_edits(GraphEdits.delete_function(b.file.doc, f.node).edits):
		status("Deleted %s" % b.qualname)


## Type text that can be written in source, or "" (Variant / unnameable).
func _writable_type(t: String) -> String:
	if t.is_empty() or t.begins_with("res://") or t.begins_with("type:") or t == "void":
		return ""
	return index.type_label(t)


func _show_panel(p: Panel3D, near: Node3D, at := Vector3.INF) -> void:
	_close_panel()
	_panel = p
	p.top_level = true # real-world size whatever the world scale
	add_child(p)
	var pos := at if at != Vector3.INF else near.global_position
	var head: Transform3D = head_provider.call() if head_provider.is_valid() else Transform3D(Basis(), pos + Vector3(0, 0, 1))
	var to_head := head.origin - pos
	var dist := to_head.length()
	# Float the panel between the node and the viewer, facing the viewer.
	var place := pos + to_head.normalized() * minf(0.35, dist * 0.4)
	p.global_transform = Transform3D(Basis.looking_at(-to_head.normalized(), Vector3.UP), place)
	if is_xr:
		_show_keyboard(p)


func _close_panel() -> void:
	if is_instance_valid(_panel):
		_panel.queue_free()
	_panel = null
	if is_xr:
		keyboard.visible = false
		_set_keyboard_enabled(false)


func _set_keyboard_enabled(on: bool) -> void:
	keyboard.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
	for c in keyboard.find_children("*", "StaticBody3D", true, false):
		(c as StaticBody3D).collision_layer = Style.UI_LAYER if on else 0


func toggle_keyboard() -> void:
	if keyboard.visible:
		keyboard.visible = false
		_set_keyboard_enabled(false)
	else:
		_show_keyboard(null)


## Shows the keyboard tilted like a desk keyboard at arm's length below the
## viewer's eyes, turned towards `facing` (else the view direction). A keyboard
## the user moved stays put while it is still within reach.
func _show_keyboard(facing: Node3D) -> void:
	keyboard.visible = true
	_set_keyboard_enabled(true)
	if not head_provider.is_valid():
		return
	var head: Transform3D = head_provider.call()
	if keyboard.user_placed and keyboard.global_position.distance_to(head.origin) < KEYBOARD_REACH:
		return
	keyboard.user_placed = false
	var fwd: Vector3 = facing.global_position - head.origin if facing else -head.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3(-head.basis.z.x, 0.0, -head.basis.z.z) if absf(head.basis.z.y) < 0.99 else Vector3.FORWARD
	fwd = fwd.normalized()
	var b := Basis.looking_at(fwd, Vector3.UP) * Basis(Vector3.RIGHT, -KEYBOARD_TILT)
	keyboard.global_transform = Transform3D(b.scaled(keyboard.global_basis.get_scale()), head.origin + fwd * 0.45 + Vector3.DOWN * 0.42)


# --- world scale -----------------------------------------------------------------------

func world_scale() -> float:
	return global_basis.get_scale().x


## Scales everything in the project by `factor` about the global point `pivot`
## (two-hand grip in VR, Ctrl+wheel on desktop). Layout positions are local, so
## the sidecar is unaffected; panels and the keyboard are top_level and keep
## their real-world size.
func scale_world(factor: float, pivot: Vector3) -> void:
	var s := world_scale()
	factor = clampf(s * factor, MIN_WORLD_SCALE, MAX_WORLD_SCALE) / s
	if is_equal_approx(factor, 1.0):
		return
	global_transform = Transform3D(global_basis.scaled(Vector3.ONE * factor), pivot + (global_position - pivot) * factor)


func reset_world_scale() -> void:
	var pivot: Vector3 = head_provider.call().origin if head_provider.is_valid() else Vector3.ZERO
	scale_world(1.0 / world_scale(), pivot)
	status("World scale 100%")


func has_panel() -> bool:
	return is_instance_valid(_panel)


# --- wires & drag-off search ---------------------------------------------------------

func begin_wire(pin: GraphPin, p: Pointer) -> void:
	_wire.pin = pin
	_wire.distance = p.origin.distance_to(pin.global_position)


func update_wire(p: Pointer) -> void:
	var pin: GraphPin = _wire.pin
	if not is_instance_valid(pin):
		return
	var im: ImmediateMesh = _wire.imesh
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(pin.global_position)
	var end: Vector3 = p.hit.position if p.hit.has("position") else p.point_at(_wire.distance)
	im.surface_add_vertex(end)
	im.surface_end()


func end_wire(p: Pointer, hit: Dictionary) -> void:
	var src: GraphPin = _wire.pin
	_wire.pin = null
	(_wire.imesh as ImmediateMesh).clear_surfaces()
	if not is_instance_valid(src):
		return
	var dst = hit.get("target")
	if dst is GraphPin and dst != src:
		_connect_pins(src, dst)
		return
	if p.moved_since_press < Interaction.CLICK_MAX_MOVE:
		return # a click on a pin, not a drag
	var drop: Vector3 = hit.position if hit.has("position") else p.point_at(_wire.distance)
	_open_pin_search(src, drop)


func _connect_pins(a: GraphPin, c: GraphPin) -> void:
	if a.board != c.board:
		status("Pins on different functions cannot be connected")
		return
	var out: GraphPin = c if a.is_input() else a
	var inp: GraphPin = a if a.is_input() else c
	if out.is_input() or not inp.is_input():
		return
	var b: FunctionBoard = a.board
	if out.kind == "exec_out" and inp.kind == "exec_in":
		var from_key := out.stmt_key
		var pin := out.pin_name
		var to_key := inp.stmt_key
		run_op(b, func(g):
			var from: FunctionGraph.Stmt = g.get_stmt(from_key)
			var s: FunctionGraph.Stmt = g.get_stmt(to_key)
			if from == null or s == null:
				return {}
			if pin == "next":
				return GraphEdits.move_after(b.file.doc, g, s, from)
			return GraphEdits.move_to_body_start(b.file.doc, g, s, from.branch_bodies.get(pin, "")))
	elif out.kind == "data_out" and inp.kind == "data_in":
		var s := b.graph.get_stmt(out.stmt_key)
		var d := s.get_data_out(out.pin_name)
		var target_key := inp.stmt_key
		var field := inp.pin_name
		if d.name == "result":
			var vname := MemberSearch._var_name(s.call_name) + "_result"
			if not _extract_result_var(b, s.key, vname):
				return
			run_op(b, func(g):
				var t: FunctionGraph.Stmt = g.get_stmt(target_key)
				return GraphEdits.set_field(b.file.doc, t, t.get_field(field), vname) if t else {})
		else:
			var expr := d.expr
			run_op(b, func(g):
				var t: FunctionGraph.Stmt = g.get_stmt(target_key)
				return GraphEdits.set_field(b.file.doc, t, t.get_field(field), expr) if t else {})
	else:
		status("Those pins don't connect")


## Turns `foo()` into `var <vname> := foo()` so its result can be used.
func _extract_result_var(b: FunctionBoard, key: String, vname: String) -> bool:
	return run_op(b, func(g):
		var s: FunctionGraph.Stmt = g.get_stmt(key)
		if s == null or s.kind != "call":
			return {}
		return GraphEdits.replace_statement(b.file.doc, s, "var %s := %s" % [vname, GraphEdits.statement_text(b.file.doc, s)]))


func _open_pin_search(src: GraphPin, drop: Vector3) -> void:
	var b: FunctionBoard = src.board
	var s := b.graph.get_stmt(src.stmt_key)
	if s == null:
		return
	var key := s.key
	match src.kind:
		"data_out":
			var d := s.get_data_out(src.pin_name)
			var expr := d.expr
			if d.name == "result":
				expr = MemberSearch._var_name(s.call_name) + "_result"
			var cands := search.for_output(d.type, expr)
			if s.kind != "entry":
				# Make this value the function's output.
				var out := MemberSearch.Candidate.new()
				out.label = "return %s  (as the function's output)" % expr
				out.kind = "return_output"
				out.group_label = "Function output"
				out.code = "return " + expr
				cands.push_front(out)
				for i in cands.size():
					cands[i].rank = i
			_open_search("%s : %s  ›" % [expr, index.type_label(d.type)], cands, b, drop, func(c: MemberSearch.Candidate):
				var sf := b.file
				sf.begin_group()
				if d.name == "result" and not _extract_result_var(b, key, expr):
					sf.end_group()
					return
				_insert_statement(b, key, "next", c.code)
				if c.kind == "return_output":
					var t := _writable_type(d.type)
					var ret: FunctionGraph.Field = b.fresh_graph().get_stmt("entry").get_field("ret")
					if not t.is_empty() and ret and (ret.is_absent() or ret.text == "void"):
						_set_entry_field(b, "ret", t)
				sf.end_group())
		"data_in":
			var f := s.get_field(src.pin_name)
			var r := TypeResolver.for_function(index, b.self_type, b.file, b.graph.func_node, s.start if s.kind != "entry" else -1)
			var cands := search.for_input(f.expect_type, r)
			var fname := f.name
			# Or turn it into a new input of the function.
			var pname := f.label.trim_suffix("?").to_snake_case()
			if not pname.is_valid_identifier() or r.scope.has(pname) or pname in ["on", "in", "if", "elif", "while", "value"]:
				pname = "value"
			while r.scope.has(pname):
				pname += "_2"
			var ptype := _writable_type(f.expect_type)
			var param_text := pname + (": " + ptype if not ptype.is_empty() else "")
			var new_in := MemberSearch.Candidate.new()
			new_in.label = "+ new input  %s" % param_text
			new_in.kind = "new_input"
			new_in.group_label = "Function input"
			new_in.expr = pname
			cands.push_front(new_in)
			for i in cands.size():
				cands[i].rank = i
			_open_search("› %s (%s)" % [f.label if not f.label.is_empty() else f.name, index.type_label(f.expect_type)], cands, b, drop, func(c: MemberSearch.Candidate):
				var sf := b.file
				sf.begin_group()
				if c.kind == "new_input" and not run_op(b, func(g): return GraphEdits.add_param(b.file.doc, g, param_text)):
					sf.end_group()
					return
				run_op(b, func(g):
					var ss: FunctionGraph.Stmt = g.get_stmt(key)
					return GraphEdits.set_field(b.file.doc, ss, ss.get_field(fname), c.expr) if ss else {})
				sf.end_group())
		"exec_out":
			var pin := src.pin_name
			_open_search("Add statement after %s (%s)" % [s.title, pin], _statement_candidates(b), b, drop, func(c: MemberSearch.Candidate):
				_insert_statement(b, key, pin, c.code))
		"exec_in":
			_open_search("Add statement before %s" % s.title, _statement_candidates(b), b, drop, func(c: MemberSearch.Candidate):
				_insert_before(b, key, c.code))


## Double-click on empty board: add at the end of the function body.
func open_append_search(b: FunctionBoard, p: Pointer, hit: Dictionary) -> void:
	var body := b.graph.get_body("entry|next")
	if body == null or body.stmt_keys.is_empty():
		return
	var last: String = body.stmt_keys[-1]
	_open_search("Add statement at end of %s" % b.qualname, _statement_candidates(b), b, hit.get("position", p.point_at(1.0)), func(c: MemberSearch.Candidate):
		_insert_statement(b, last, "next", c.code))


## Shortcut: add after the selected statement (Space / Tab on desktop).
func open_search_after_selection() -> void:
	var s := _selected_stmt()
	if s == null:
		return
	var b: FunctionBoard = selection.board
	var key := s.key
	_open_search("Add statement after %s" % s.title, _statement_candidates(b), b, b.nodes[key].global_position, func(c: MemberSearch.Candidate):
		_insert_statement(b, key, "next", c.code))


func _statement_candidates(b: FunctionBoard) -> Array:
	var out := []
	for t in STATEMENT_TEMPLATES:
		var c := MemberSearch.Candidate.new()
		c.label = t[0]
		c.detail = t[1].get_slice("\n", 0)
		c.kind = "statement"
		c.code = t[1]
		c.group = -1
		c.group_label = "Statement"
		out.append(c)
	for c in search.for_output(b.self_type, "self"):
		if c.kind in ["method", "signal"]:
			out.append(c)
	var globals := index.global_functions()
	var g := []
	for name in globals:
		var c := MemberSearch.Candidate.new()
		c.label = name + "()"
		c.kind = "function"
		c.code = name + "()"
		c.group_label = "Global"
		c.freq = index.usage.get(name, 0)
		g.append(c)
	g.sort_custom(func(a, c): return a.freq > c.freq if a.freq != c.freq else a.label < c.label)
	out.append_array(g)
	for i in out.size():
		out[i].rank = i
	return out


func _open_search(title: String, cands: Array, b: FunctionBoard, at: Vector3, on_choose: Callable) -> void:
	var p := SearchPanel.new()
	_show_panel(p, b, at)
	p.open(title, cands)
	p.chosen.connect(func(c: MemberSearch.Candidate):
		_close_panel()
		if c.member:
			index.mark_used(c.member)
		on_choose.call(c)
	)
	p.cancelled.connect(_close_panel)


func _insert_statement(b: FunctionBoard, key: String, pin: String, code: String) -> void:
	var text := _adapt_indent(code, b.file)
	run_op(b, func(g):
		var s: FunctionGraph.Stmt = g.get_stmt(key)
		if s == null:
			return {}
		if pin == "next":
			return GraphEdits.insert_after(b.file.doc, g, s, text)
		return GraphEdits.insert_at_body_start(b.file.doc, g, s.branch_bodies.get(pin, ""), text))


func _insert_before(b: FunctionBoard, key: String, code: String) -> void:
	var text := _adapt_indent(code, b.file)
	run_op(b, func(g):
		var s: FunctionGraph.Stmt = g.get_stmt(key)
		if s == null:
			return {}
		var body: FunctionGraph.Body = g.get_body(s.body_key)
		var i: int = body.stmt_keys.find(key)
		if i == 0:
			return GraphEdits.insert_at_body_start(b.file.doc, g, s.body_key, text)
		return GraphEdits.insert_after(b.file.doc, g, g.get_stmt(body.stmt_keys[i - 1]), text))


# --- keys ------------------------------------------------------------------------------

## Physical or virtual key press. Returns true if consumed.
func handle_key(ev: InputEventKey) -> bool:
	if is_instance_valid(_panel):
		if ev.pressed and ev.keycode == KEY_ESCAPE:
			_close_panel()
		else:
			_panel.send_key(ev)
		return true
	if not ev.pressed or ev.echo and not ev.keycode in [KEY_UP, KEY_DOWN]:
		return false
	var ctrl := ev.ctrl_pressed or ev.meta_pressed
	match ev.keycode:
		KEY_DELETE, KEY_BACKSPACE:
			delete_selected()
		KEY_Z:
			if not ctrl:
				return false
			if ev.shift_pressed:
				redo()
			else:
				undo()
		KEY_Y:
			if not ctrl:
				return false
			redo()
		KEY_UP, KEY_DOWN:
			if not ev.alt_pressed:
				return false
			move_selected(-1 if ev.keycode == KEY_UP else 1)
		KEY_SPACE, KEY_TAB:
			open_search_after_selection()
		KEY_ENTER, KEY_KP_ENTER:
			var b: FunctionBoard = selection.board
			if is_instance_valid(b) and not selection.key.is_empty():
				edit_raw(b, selection.key)
		KEY_R:
			if is_instance_valid(selection.board):
				relayout(selection.board)
		KEY_K:
			toggle_keyboard()
		KEY_0:
			if not ctrl:
				return false
			reset_world_scale()
		KEY_N:
			if is_instance_valid(selection.board):
				prompt_new_function(selection.board.self_type, selection.board)
		KEY_I:
			if is_instance_valid(selection.board):
				add_input(selection.board)
		KEY_ESCAPE:
			select(null, "")
		_:
			return false
	return true
