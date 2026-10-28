class_name StmtNode3D
extends Node3D
## One statement drawn as a node: header with the title, one row per inline
## expression field (click to edit), exec pins for flow and data pins for
## values. The local origin is the node's top-left front corner.

const MIN_W := 0.2
const MAX_W := 1.3
const CODE_MAX_LINES := 8
const EXEC_X := 0.03

var board: Node3D ## FunctionBoard
var stmt: FunctionGraph.Stmt
var size := Vector2.ZERO
var pins := {} ## "exec_in", "exec_out:<pin>", "data_in:<field>", "data_out:<name>" -> GraphPin
var _outline: MeshInstance3D
var _move: MoveDrag
var _selected := false


func build(p_board: Node3D, s: FunctionGraph.Stmt) -> StmtNode3D:
	board = p_board
	stmt = s
	name = "S_" + s.key.replace(".", "_")
	var branch_pins: Array = s.exec_outs.filter(func(x): return x != "next")
	var field_rows := []
	for f in s.fields:
		field_rows.append(_field_text(f))
	var code_lines := 0
	if s.kind == "code":
		code_lines = mini(field_rows[0].count("\n") + 1, CODE_MAX_LINES)
	var rows := maxi(field_rows.size(), branch_pins.size()) + (code_lines - 1 if code_lines > 0 else 0)
	var w := Style.text_width(s.title, Style.FONT_TITLE) + (0.2 if s.kind == "entry" else 0.08)
	for i in field_rows.size():
		var rw: float = branch_pins[i].length() * 0.012 if i < branch_pins.size() else 0.0
		for line in field_rows[i].split("\n"):
			w = maxf(w, Style.text_width(line) + rw + Style.PAD * 2 + 0.03)
	for d in s.data_outs:
		w = maxf(w, Style.text_width(_data_out_text(d), Style.FONT_SMALL) + Style.PAD * 2 + 0.03)
	w = clampf(w, MIN_W, MAX_W)
	var h := Style.HEADER + (rows + s.data_outs.size()) * Style.ROW + Style.PAD * 0.6
	size = Vector2(w, h)

	var kind_color: Color = Style.KIND_COLORS.get(s.kind, Style.KIND_COLORS.code)
	add_child(Style.box(size, Style.BODY_COLOR, 0.008))
	var header := Style.box(Vector2(w, Style.HEADER), kind_color, 0.004)
	header.position.z += 0.0015
	add_child(header)
	_outline = Style.box(size + Vector2(0.012, 0.012), Style.ERROR_COLOR if s.has_error else Style.SELECT_COLOR, 0.004)
	_outline.position += Vector3(-0.006, 0.006, -0.004)
	_outline.visible = s.has_error
	add_child(_outline)

	var title := Style.label(s.title, Style.FONT_TITLE)
	title.position = Vector3(EXEC_X + 0.022, -Style.HEADER * 0.5, 0.003)
	add_child(title)
	# Whole-node collider (drag / select / double-click for raw edit).
	add_child(Style.collider(self, Vector3(w, h, 0.012), Vector3(w * 0.5, -h * 0.5, -0.003)))

	# Exec pins.
	# Flow runs top to bottom: exec in on the top edge, `next` on the bottom.
	if s.kind != "entry":
		_add_pin("exec_in", "", Vector3(EXEC_X, 0, 0.004), "", Vector3.UP)
	if s.exec_outs.has("next"):
		_add_pin("exec_out", "next", Vector3(EXEC_X, -h, 0.004), "", Vector3.DOWN)
	for i in branch_pins.size():
		var y := -(Style.HEADER + Style.ROW * (i + 0.5))
		_add_pin("exec_out", branch_pins[i], Vector3(w, y, 0.004), "", Vector3.RIGHT)
		var bl := Style.label(branch_pins[i], Style.FONT_SMALL, Style.TEXT_DIM)
		bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		bl.position = Vector3(w - 0.016, y, 0.003)
		add_child(bl)

	# Field rows.
	var row := 0
	for i in s.fields.size():
		var f: FunctionGraph.Field = s.fields[i]
		var y := -(Style.HEADER + Style.ROW * (row + 0.5))
		var text: String = field_rows[i]
		var lines := 1
		if s.kind == "code":
			var all := text.split("\n")
			lines = mini(all.size(), CODE_MAX_LINES)
			text = "\n".join(all.slice(0, lines)) + ("\n…" if all.size() > lines else "")
			y = -(Style.HEADER + Style.ROW * lines * 0.5)
		var fl := Style.label(text, Style.FONT, Style.TEXT_DIM if f.is_absent() else Style.FIELD_TEXT)
		fl.position = Vector3(Style.PAD + 0.006, y, 0.003)
		fl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		add_child(fl)
		var fw := w * 0.8 if s.kind != "code" else w - 0.02
		var hit_h := Style.ROW * lines
		var fc := Style.collider(self, Vector3(fw, hit_h, 0.016), Vector3(Style.PAD + fw * 0.5, y, 0.0))
		fc.set_meta("field", f.name)
		add_child(fc)
		if s.kind != "code" and s.kind != "entry":
			_add_pin("data_in", f.name, Vector3(0, y, 0.004), f.expect_type, Vector3.LEFT)
		row += lines

	if s.kind == "entry":
		var add := Button3D.new().setup("+ input", Style.FONT_SMALL)
		add.position = Vector3(w - add.width() - 0.012, -Style.HEADER * 0.12, 0.005)
		add.pressed.connect(func(): board.workspace.add_input(board))
		add_child(add)

	# Data outputs.
	for j in s.data_outs.size():
		var d: FunctionGraph.DataOut = s.data_outs[j]
		var y := -(Style.HEADER + Style.ROW * (rows + j + 0.5))
		var dl := Style.label(_data_out_text(d), Style.FONT_SMALL, Style.type_color(d.type).lerp(Style.TEXT, 0.4))
		dl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		dl.position = Vector3(w - 0.016, y, 0.003)
		add_child(dl)
		_add_pin("data_out", d.name, Vector3(w, y, 0.004), d.type, Vector3.RIGHT)
	return self


func _field_text(f: FunctionGraph.Field) -> String:
	if stmt.kind == "code":
		return GraphEdits.statement_text(board.file.doc, stmt)
	var value := Style.shorten(f.text) if not f.is_absent() else "‹%s›" % (f.label if not f.label.is_empty() else f.name)
	if f.label.is_empty() or f.is_absent():
		return value
	return "%s  %s" % [f.label, value]


func _data_out_text(d: FunctionGraph.DataOut) -> String:
	return "%s : %s" % [d.label, board.workspace.index.type_label(d.type)]


func _add_pin(kind: String, pin_name: String, pos: Vector3, type: String, dir: Vector3) -> void:
	var p := GraphPin.new().setup(board, stmt.key, kind, pin_name, type)
	p.position = pos
	p.dir = dir
	add_child(p)
	pins[kind if pin_name.is_empty() else kind + ":" + pin_name] = p


func set_selected(v: bool) -> void:
	_selected = v
	_outline.visible = v or stmt.has_error
	_outline.material_override = Style.material(Style.SELECT_COLOR if v else Style.ERROR_COLOR)


# --- interaction -------------------------------------------------------------------

func ix_press(p: Pointer, hit: Dictionary) -> void:
	if hit.collider.has_meta("field"):
		return
	_move = MoveDrag.begin(self, p, hit)


func ix_drag(p: Pointer) -> void:
	if _move:
		_move.update(p)
		board.wires_dirty = true


func ix_release(p: Pointer, _hit: Dictionary) -> void:
	if _move and p.moved_since_press >= Interaction.CLICK_MAX_MOVE:
		board.node_moved(self)
	_move = null


func ix_scroll(_p: Pointer, amount: float) -> void:
	if _move:
		_move.push(amount)


func ix_click(_p: Pointer, hit: Dictionary) -> void:
	board.workspace.select(board, stmt.key)
	if hit.collider.has_meta("field"):
		board.workspace.edit_field(board, stmt.key, hit.collider.get_meta("field"))


func ix_double_click(_p: Pointer, _hit: Dictionary) -> void:
	board.workspace.edit_raw(board, stmt.key)


func ix_grab(p: Pointer, hit: Dictionary) -> void:
	_move = MoveDrag.begin(self, p, hit, true)


func ix_grab_drag(p: Pointer) -> void:
	ix_drag(p)


func ix_ungrab(_p: Pointer) -> void:
	board.node_moved(self)
	_move = null
