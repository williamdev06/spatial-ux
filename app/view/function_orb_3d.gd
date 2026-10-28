class_name FunctionOrb3D
extends Node3D
## One function of an expanded class, orbiting its class sphere. Click to open
## its board right in front of it (or bring an open board back here).

const RADIUS := 0.032
const COLOR := Color(0.45, 0.72, 1.0)
const PRIVATE_COLOR := Color(0.40, 0.48, 0.60)

var class_node: Node3D ## ClassNode3D
var qualname := ""
var _sphere: MeshInstance3D
var _label: Label3D
var _color := COLOR
var _open := false
var _hovered := false


func setup(p_class_node: Node3D, p_qualname: String) -> FunctionOrb3D:
	class_node = p_class_node
	qualname = p_qualname
	name = "Orb_" + p_qualname.validate_node_name()
	_color = PRIVATE_COLOR if p_qualname.get_slice(".", p_qualname.get_slice_count(".") - 1).begins_with("_") else COLOR
	_sphere = Style.sphere(RADIUS, _color)
	_sphere.material_override = Style.material(_color, false)
	add_child(_sphere)
	_label = Style.label(p_qualname, Style.FONT)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_label.position = Vector3(0, -RADIUS - 0.008, 0)
	add_child(_label)
	add_child(Style.collider(self, Vector3.ONE * RADIUS * 3.0))
	return self


## Highlighted while its board is open.
func set_open(on: bool) -> void:
	_open = on
	_refresh()


func _refresh() -> void:
	var c := Style.SELECT_COLOR if _open else _color
	_sphere.material_override = Style.material(c, false)
	_sphere.scale = Vector3.ONE * (1.3 if _hovered else 1.0)
	_label.modulate = Style.SELECT_COLOR if _open or _hovered else Style.TEXT


func ix_hover(_p: Pointer, _hit: Dictionary, entered: bool) -> void:
	_hovered = entered
	_refresh()


func ix_click(_p: Pointer, _hit: Dictionary) -> void:
	class_node.macro.workspace.open_board(class_node.class_id, qualname)
