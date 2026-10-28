class_name XRRig
extends XROrigin3D
## OpenXR rig. Each hand is a Pointer (aim pose):
##   trigger: click / drag pins, fields, nodes, panels
##   grip on a node / board / panel: grab and move it (rotation follows)
##   grip on empty space: grab the world and pull yourself around
##   left stick: move    right stick x: snap turn    right stick y: up/down,
##     or push/pull whatever is being dragged
##   B / Y: virtual keyboard    A: undo    X: redo    menu: HUD panel

const MOVE_SPEED := 1.5
const SNAP_TURN := deg_to_rad(30.0)
const RAY_COLOR := Color(0.6, 0.8, 1.0, 0.6)

var workspace: Workspace
var camera: XRCamera3D
var hands := {} ## "left"/"right" -> {ctrl, pointer, ray}
var hud_panel: Panel3D
var _snap_armed := true
var _world_grab := {} ## pointer id -> last controller position in origin space


func _ready() -> void:
	camera = XRCamera3D.new()
	add_child(camera)
	for side in ["left", "right"]:
		var c := XRController3D.new()
		c.tracker = "%s_hand" % side
		c.pose = "aim"
		c.name = side.capitalize() + "Hand"
		add_child(c)
		var p := Pointer.new()
		p.id = side
		p.is_xr = true
		workspace.interaction.add_pointer(p)
		var ray := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.0015
		cm.bottom_radius = 0.0015
		cm.height = 1.0
		ray.mesh = cm
		ray.material_override = Style.material(RAY_COLOR)
		ray.rotation.x = -PI / 2.0
		c.add_child(ray)
		c.button_pressed.connect(_on_button.bind(side))
		hands[side] = { ctrl = c, pointer = p, ray = ray }
	workspace.interaction.empty_handler = self


func head_transform() -> Transform3D:
	return camera.global_transform


func _process(dt: float) -> void:
	for side in hands:
		var h: Dictionary = hands[side]
		var c: XRController3D = h.ctrl
		var p: Pointer = h.pointer
		p.origin = c.global_position
		p.direction = -c.global_basis.z
		p.transform = c.global_transform
		p.pressed = c.get_float("trigger") > 0.6
		p.gripping = c.get_float("grip") > 0.6
		var length: float = p.hit.get("distance", 3.0)
		var ray: MeshInstance3D = h.ray
		ray.scale = Vector3(1, length, 1)
		ray.position = Vector3(0, 0, -length * 0.5)
		ray.visible = c.get_has_tracking_data()
		if _world_grab.has(p.id):
			var local := global_transform.affine_inverse() * c.global_position
			global_position -= global_basis * (local - _world_grab[p.id])
			_world_grab[p.id] = global_transform.affine_inverse() * c.global_position

	var left: XRController3D = hands.left.ctrl
	var right: XRController3D = hands.right.ctrl
	var move := left.get_vector2("primary")
	if move.length() > 0.15:
		var fwd := -camera.global_basis.z
		fwd.y = 0
		fwd = fwd.normalized()
		var side := camera.global_basis.x
		side.y = 0
		side = side.normalized()
		global_position += (fwd * move.y + side * move.x) * MOVE_SPEED * dt
	var turn := right.get_vector2("primary")
	if absf(turn.x) > 0.7 and _snap_armed:
		_snap_armed = false
		var pivot := camera.global_position
		var t := Transform3D(Basis(Vector3.UP, -signf(turn.x) * SNAP_TURN), Vector3.ZERO)
		global_transform = Transform3D(t.basis * global_basis, pivot + t.basis * (global_position - pivot))
	elif absf(turn.x) < 0.3:
		_snap_armed = true
	if absf(turn.y) > 0.2:
		var rp: Pointer = hands.right.pointer
		if is_instance_valid(rp.capture) or is_instance_valid(rp.grab_capture):
			rp.scroll += turn.y * dt * 6.0
		else:
			global_position.y += turn.y * MOVE_SPEED * 0.6 * dt


func _on_button(button: String, side: String) -> void:
	match button:
		"by_button":
			workspace.toggle_keyboard()
		"ax_button":
			if side == "right":
				workspace.undo()
			else:
				workspace.redo()
		"menu_button":
			if hud_panel:
				hud_panel.visible = not hud_panel.visible


func ix_grab_empty(p: Pointer) -> void:
	var c: XRController3D = hands[p.id].ctrl
	_world_grab[p.id] = global_transform.affine_inverse() * c.global_position


func ix_ungrab_empty(p: Pointer) -> void:
	_world_grab.erase(p.id)
