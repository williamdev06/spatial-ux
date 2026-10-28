class_name GraphPin
extends Node3D
## One pin on a statement node. Dragging from it starts a wire; the Workspace
## decides what a drop means (reorder, fill an input, or open the search).

var board: Node3D ## FunctionBoard
var stmt_key := ""
var kind := "" ## exec_in, exec_out, data_in, data_out
var pin_name := "" ## exec pin, field name, or data-out name
var type := ""
var dir := Vector3.RIGHT ## Direction a wire leaves / enters, in node space.
var _mesh: MeshInstance3D


func setup(p_board: Node3D, p_key: String, p_kind: String, p_name: String, p_type := "") -> GraphPin:
	board = p_board
	stmt_key = p_key
	kind = p_kind
	pin_name = p_name
	type = p_type
	var exec := kind.begins_with("exec")
	if exec:
		_mesh = MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(Style.PIN_R * 1.6, Style.PIN_R * 1.6, Style.PIN_R * 0.8)
		_mesh.mesh = bm
		_mesh.rotation.z = PI / 4.0
		_mesh.material_override = Style.material(Style.EXEC_COLOR)
	else:
		_mesh = Style.sphere(Style.PIN_R, Style.type_color(type))
	add_child(_mesh)
	add_child(Style.collider(self, Vector3.ONE * Style.PIN_R * 3.2))
	return self


func is_input() -> bool:
	return kind == "exec_in" or kind == "data_in"


func ix_hover(_p: Pointer, _hit: Dictionary, entered: bool) -> void:
	_mesh.scale = Vector3.ONE * (1.6 if entered else 1.0)


func ix_press(p: Pointer, _hit: Dictionary) -> void:
	board.workspace.begin_wire(self, p)


func ix_drag(p: Pointer) -> void:
	board.workspace.update_wire(p)


func ix_release(p: Pointer, hit: Dictionary) -> void:
	board.workspace.end_wire(p, hit)
