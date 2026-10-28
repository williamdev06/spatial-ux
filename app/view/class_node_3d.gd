class_name ClassNode3D
extends Node3D
## A script/class in the macro view. Click to expand into its function boards
## (which hang off `boards_root` and move with it); drag to move.

var macro: Node3D ## MacroView
var class_id := ""
var expanded := false
var pinned := false
var radius := 0.08
var boards_root: Node3D
var _sphere: MeshInstance3D
var _label: Label3D
var _move: MoveDrag


func setup(p_macro: Node3D, id: String, title: String, subtitle: String, color: Color, func_count: int) -> ClassNode3D:
	macro = p_macro
	class_id = id
	name = "Class_" + id.validate_node_name()
	radius = 0.08 + 0.025 * sqrt(float(func_count))
	_sphere = Style.sphere(radius, color)
	_sphere.material_override = Style.material(color, false)
	add_child(_sphere)
	_label = Style.label("%s\n%s" % [title, subtitle], Style.FONT_TITLE + 6)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_label.position = Vector3(0, radius + 0.02, 0)
	_label.pixel_size = 0.0022
	add_child(_label)
	add_child(Style.collider(self, Vector3.ONE * radius * 2.2))
	boards_root = Node3D.new()
	boards_root.name = "Boards"
	add_child(boards_root)
	return self


func set_highlight(on: bool) -> void:
	_label.modulate = Style.SELECT_COLOR if on else Style.TEXT


func ix_hover(_p: Pointer, _hit: Dictionary, entered: bool) -> void:
	_sphere.scale = Vector3.ONE * (1.15 if entered else 1.0)


func ix_press(p: Pointer, hit: Dictionary) -> void:
	_move = MoveDrag.begin(self, p, hit)


func ix_drag(p: Pointer) -> void:
	if _move:
		_move.update(p)
		macro.edges_dirty = true


func ix_release(p: Pointer, _hit: Dictionary) -> void:
	if _move and p.moved_since_press >= Interaction.CLICK_MAX_MOVE:
		pinned = true
		macro.node_moved(self)
	_move = null


func ix_scroll(_p: Pointer, amount: float) -> void:
	if _move:
		_move.push(amount)


func ix_click(_p: Pointer, _hit: Dictionary) -> void:
	macro.workspace.toggle_class(class_id)


func ix_grab(p: Pointer, hit: Dictionary) -> void:
	_move = MoveDrag.begin(self, p, hit, false)
	_move.rigid = false


func ix_grab_drag(p: Pointer) -> void:
	ix_drag(p)


func ix_ungrab(_p: Pointer) -> void:
	pinned = true
	macro.node_moved(self)
	_move = null
