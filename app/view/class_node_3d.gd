class_name ClassNode3D
extends Node3D
## A script/class in the macro view. Click to show its functions as a ring of
## orbs (they hang off `orbs_root`, which faces the viewer, and move with the
## sphere); click again to hide them. Drag to move.

const ORB_SPACING := 0.14 ## Arc length between neighbouring orbs.

var macro: Node3D ## MacroView
var class_id := ""
var expanded := false
var pinned := false
var radius := 0.08
var orbs_root: Node3D
var orbs := {} ## qualname -> FunctionOrb3D
var _sphere: MeshInstance3D
var _label: Label3D
var _move: MoveDrag
var _add_func: Button3D
var _spokes := ImmediateMesh.new()


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
	orbs_root = Node3D.new()
	orbs_root.name = "Orbs"
	add_child(orbs_root)
	var spokes := MeshInstance3D.new()
	spokes.mesh = _spokes
	spokes.material_override = Style.material(Color(0.45, 0.72, 1.0, 0.35))
	orbs_root.add_child(spokes)
	return self


## Shows one orb per function (in source order, clockwise from the top as the
## viewer sees it), or none for an empty list. `open` holds the qualnames
## whose boards are open.
func set_functions(qualnames: Array, open: Dictionary) -> void:
	for q in orbs.keys():
		if not qualnames.has(q):
			orbs[q].queue_free()
			orbs.erase(q)
	var ring := maxf(radius + 0.16, qualnames.size() * ORB_SPACING / TAU)
	_spokes.clear_surfaces()
	if not qualnames.is_empty():
		_spokes.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in qualnames.size():
		var q: String = qualnames[i]
		if not orbs.has(q):
			orbs[q] = FunctionOrb3D.new().setup(self, q)
			orbs_root.add_child(orbs[q])
		var a := TAU * i / qualnames.size()
		var orb: FunctionOrb3D = orbs[q]
		orb.position = Vector3(sin(a), cos(a), 0) * ring
		orb.set_open(open.has(q))
		_spokes.surface_add_vertex(orb.position.normalized() * radius)
		_spokes.surface_add_vertex(orb.position.normalized() * (ring - FunctionOrb3D.RADIUS))
	if not qualnames.is_empty():
		_spokes.surface_end()
	_label.position.y = ring + 0.08 if not qualnames.is_empty() else radius + 0.02


func set_highlight(on: bool) -> void:
	_label.modulate = Style.SELECT_COLOR if on else Style.TEXT
	if _add_func == null:
		_add_func = Button3D.new().setup("+ func", Style.FONT)
		_add_func.pressed.connect(func(): macro.workspace.prompt_new_function(class_id))
		orbs_root.add_child(_add_func)
		_add_func.position = Vector3(-_add_func.width() * 0.5, -radius - 0.03, 0.05)
	_add_func.visible = on
	for c in _add_func.find_children("*", "StaticBody3D", true, false):
		(c as StaticBody3D).collision_layer = Style.UI_LAYER if on else 0


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

