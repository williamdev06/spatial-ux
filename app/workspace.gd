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
	if external:
		# New functions appear on expanded classes.
		if _boards.has(cls) and macro.nodes.has(cls) and macro.nodes[cls].expanded:
			_add_missing_boards(cls)
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
	else:
		n.expanded = true
		n.set_highlight(true)
		_face_viewer(n.boards_root)
		_boards[class_id] = []
		_add_missing_boards(class_id)
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
		if stored != null:
			b.transform = stored
		else:
			unplaced.append(b)
	_arrange_boards(n, unplaced)


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
	var bottom := FLOOR_CLEARANCE - n.global_position.y
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
	node.global_basis = Basis.looking_at(-to.normalized(), Vector3.UP)


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
		edit_field(b, key, "params")
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


func _show_panel(p: Panel3D, near: Node3D, at := Vector3.INF) -> void:
	_close_panel()
	_panel = p
	add_child(p)
	var pos := at if at != Vector3.INF else near.global_position
	var head: Transform3D = head_provider.call() if head_provider.is_valid() else Transform3D(Basis(), pos + Vector3(0, 0, 1))
	var to_head := head.origin - pos
	var dist := to_head.length()
	# Float the panel between the node and the viewer, facing the viewer.
	var place := pos + to_head.normalized() * minf(0.35, dist * 0.4)
	p.global_transform = Transform3D(Basis.looking_at(-to_head.normalized(), Vector3.UP), place)
	if is_xr:
		keyboard.visible = true
		_set_keyboard_enabled(true)
		keyboard.global_transform = Transform3D(p.global_basis, place - p.global_basis.y * 0.42 + to_head.normalized() * 0.05)
		keyboard.global_position -= keyboard.global_basis.x * 0.35


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
	keyboard.visible = not keyboard.visible
	_set_keyboard_enabled(keyboard.visible)
	if keyboard.visible and head_provider.is_valid():
		var head: Transform3D = head_provider.call()
		var fwd := -head.basis.z
		fwd.y = 0
		fwd = fwd.normalized()
		keyboard.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), head.origin + fwd * 0.55 + Vector3(0, -0.45, 0))
		keyboard.global_position -= keyboard.global_basis.x * 0.35


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
			_open_search("%s : %s  ›" % [expr, index.type_label(d.type)], cands, b, drop, func(c: MemberSearch.Candidate):
				if d.name == "result" and not _extract_result_var(b, key, expr):
					return
				_insert_statement(b, key, "next", c.code))
		"data_in":
			var f := s.get_field(src.pin_name)
			var r := TypeResolver.for_function(index, b.self_type, b.file, b.graph.func_node, s.start if s.kind != "entry" else -1)
			var cands := search.for_input(f.expect_type, r)
			var fname := f.name
			_open_search("› %s (%s)" % [f.label if not f.label.is_empty() else f.name, index.type_label(f.expect_type)], cands, b, drop, func(c: MemberSearch.Candidate):
				run_op(b, func(g):
					var ss: FunctionGraph.Stmt = g.get_stmt(key)
					return GraphEdits.set_field(b.file.doc, ss, ss.get_field(fname), c.expr) if ss else {}))
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
		KEY_ESCAPE:
			select(null, "")
		_:
			return false
	return true
