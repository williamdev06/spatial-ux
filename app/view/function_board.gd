class_name FunctionBoard
extends Node3D
## One function's graph on a floating board. Rebuilt from the text whenever
## the file changes; manual node positions come from the LayoutStore.

const MARGIN := 0.06
const WIRE_SEGMENTS := 18

var workspace: Node ## Workspace
var file: ScriptFile
var qualname := ""
var graph: FunctionGraph
var self_type := ""
var nodes := {} ## stmt key -> StmtNode3D
var wires_dirty := true

var _content: Node3D
var _wire_mesh := ImmediateMesh.new()
var _bg: MeshInstance3D
var _title: Label3D
var _title_hit: StaticBody3D
var _area_hit: StaticBody3D
var _buttons: Node3D
var _move: MoveDrag
var _bounds := Rect2()


func setup(ws: Node, sf: ScriptFile, p_qualname: String) -> FunctionBoard:
	workspace = ws
	file = sf
	qualname = p_qualname
	name = "Board_" + p_qualname.replace(".", "_")
	_content = Node3D.new()
	add_child(_content)
	var wmi := MeshInstance3D.new()
	wmi.mesh = _wire_mesh
	var wm := StandardMaterial3D.new()
	wm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wm.vertex_color_use_as_albedo = true
	wmi.material_override = wm
	add_child(wmi)
	_title = Style.label("", Style.FONT_TITLE + 8)
	add_child(_title)
	_buttons = Node3D.new()
	add_child(_buttons)
	var x := 0.0
	for spec in [["+ func", func(): workspace.prompt_new_function(self_type, self)],
			["auto layout", func(): workspace.relayout(self)],
			["close", func(): workspace.close_board(self)],
			["delete", func(): workspace.delete_function(self)]]:
		var btn := Button3D.new().setup(spec[0])
		btn.position.x = x
		btn.pressed.connect(spec[1])
		_buttons.add_child(btn)
		x += btn.width() + 0.01
	return self


## Rebuilds nodes and layout from the current text. Returns false if the
## function no longer exists.
func rebuild() -> bool:
	var f := file.find_function(qualname)
	if f.is_empty():
		return false
	graph = FunctionGraph.build(file, f)
	self_type = workspace.index.class_of_function(file, f)
	TypeResolver.new(workspace.index, self_type, file).annotate(graph)
	for c in _content.get_children():
		c.queue_free()
	nodes.clear()
	var sizes := {}
	for s in graph.stmts:
		var n := StmtNode3D.new().build(self, s)
		_content.add_child(n)
		nodes[s.key] = n
		sizes[s.key] = n.size
	var manual: Dictionary = workspace.layout_store.node_positions(file.res_path, graph)
	var pos := FunctionLayout.compute(graph, sizes, manual)
	for key in nodes:
		if pos.has(key):
			nodes[key].position = pos[key]
	_title.text = "%s  ›  %s" % [file.res_path.get_file(), qualname]
	_update_bounds()
	wires_dirty = true
	var sel = workspace.selection
	if sel.board == self and nodes.has(sel.key):
		nodes[sel.key].set_selected(true)
	return true


## A graph freshly built from the current text, for running edit operations.
func fresh_graph() -> FunctionGraph:
	var f := file.find_function(qualname)
	if f.is_empty():
		return null
	return FunctionGraph.build(file, f)


func node_moved(n: StmtNode3D) -> void:
	workspace.layout_store.set_node(file.res_path, qualname, n.stmt, n.position)
	workspace.layout_changed()
	_update_bounds()
	wires_dirty = true


func pin(key: String, pin_id: String) -> GraphPin:
	var n: StmtNode3D = nodes.get(key)
	return n.pins.get(pin_id) if n else null


func _process(_dt: float) -> void:
	if wires_dirty:
		wires_dirty = false
		_draw_wires()


func _draw_wires() -> void:
	_wire_mesh.clear_surfaces()
	if graph == null:
		return
	var any := false
	for e in graph.edges:
		var a := pin(e.from, "exec_out:" + e.pin)
		var b := pin(e.to, "exec_in")
		if a and b:
			if not any:
				_wire_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
				any = true
			_wire(a, b, Style.EXEC_COLOR)
	# Data wires: a variable / parameter to every later field that mentions it.
	for s in graph.stmts:
		for d in s.data_outs:
			if d.name == "self" or d.name == "result":
				continue
			var a := pin(s.key, "data_out:" + d.name)
			if a == null:
				continue
			var re := RegEx.create_from_string("\\b" + d.expr + "\\b")
			var started := false
			for t in graph.stmts:
				if t.start <= s.start and t != s or t.kind == "code" or t == s:
					continue
				for f in t.fields:
					if f.is_absent() or re.search(f.text) == null:
						continue
					var b := pin(t.key, "data_in:" + f.name)
					if b:
						if not any:
							_wire_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
							any = true
						_wire(a, b, Style.type_color(d.type).darkened(0.25))
	if any:
		_wire_mesh.surface_end()


func _wire(a: GraphPin, b: GraphPin, color: Color) -> void:
	var p0 := to_local(a.global_position)
	var p3 := to_local(b.global_position)
	var d0 := (to_local(a.global_position + a.global_basis * a.dir) - p0).normalized()
	var d3 := (to_local(b.global_position + b.global_basis * b.dir) - p3).normalized()
	var k := clampf(p0.distance_to(p3) * 0.4, 0.03, 0.4)
	_bezier(p0, p0 + d0 * k, p3 + d3 * k, p3, color)


func _bezier(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, color: Color) -> void:
	var prev := p0
	for i in range(1, WIRE_SEGMENTS + 1):
		var t := float(i) / WIRE_SEGMENTS
		var u := 1.0 - t
		var p := u * u * u * p0 + 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t * p3
		_wire_mesh.surface_set_color(color)
		_wire_mesh.surface_add_vertex(prev)
		_wire_mesh.surface_set_color(color)
		_wire_mesh.surface_add_vertex(p)
		prev = p


func _update_bounds() -> void:
	var r := Rect2()
	var first := true
	var min_z := 0.0
	for key in nodes:
		var n: StmtNode3D = nodes[key]
		var nr := Rect2(Vector2(n.position.x, -n.position.y), n.size)
		r = nr if first else r.merge(nr)
		min_z = minf(min_z, n.position.z)
		first = false
	_bounds = r.grow(MARGIN)
	if _bg:
		_bg.queue_free()
	_bg = Style.box(_bounds.size, Style.BOARD_COLOR, 0.01)
	_bg.position += Vector3(_bounds.position.x, -_bounds.position.y, min_z - 0.012)
	add_child(_bg)
	if _title_hit:
		_title_hit.queue_free()
	var tw := maxf(_bounds.size.x, Style.text_width(_title.text, _title.font_size))
	var th := 0.06
	_title.position = Vector3(_bounds.position.x, -_bounds.position.y + th * 0.5 + 0.01, 0)
	_buttons.position = Vector3(_bounds.position.x + Style.text_width(_title.text, _title.font_size) + 0.04, -_bounds.position.y + th * 0.5 + 0.024, 0)
	# Title bar and empty board area both drag the whole board.
	_title_hit = Style.collider(self, Vector3(tw, th, 0.02), Vector3(_bounds.position.x + tw * 0.5, -_bounds.position.y + th * 0.5 + 0.01, 0))
	add_child(_title_hit)
	if _area_hit:
		_area_hit.queue_free()
	_area_hit = Style.collider(self, Vector3(_bounds.size.x, _bounds.size.y, 0.004), Vector3(_bounds.position.x + _bounds.size.x * 0.5, -_bounds.position.y - _bounds.size.y * 0.5, min_z - 0.02))
	_area_hit.set_meta("board_area", true)
	add_child(_area_hit)


func bounds() -> Rect2:
	return _bounds


# --- interaction: move the whole board ---------------------------------------------

func ix_press(p: Pointer, hit: Dictionary) -> void:
	_move = MoveDrag.begin(self, p, hit)


func ix_drag(p: Pointer) -> void:
	if _move:
		_move.update(p)


func ix_release(_p: Pointer, _hit: Dictionary) -> void:
	_move = null


func ix_click(_p: Pointer, _hit: Dictionary) -> void:
	workspace.select(self, "")


## Double-clicking empty board space adds a statement at the end of the function.
func ix_double_click(p: Pointer, hit: Dictionary) -> void:
	if hit.collider.has_meta("board_area"):
		workspace.open_append_search(self, p, hit)


func ix_scroll(_p: Pointer, amount: float) -> void:
	if _move:
		_move.push(amount)


func ix_grab(p: Pointer, hit: Dictionary) -> void:
	_move = MoveDrag.begin(self, p, hit, true)


func ix_grab_drag(p: Pointer) -> void:
	ix_drag(p)


func ix_ungrab(_p: Pointer) -> void:
	_move = null
