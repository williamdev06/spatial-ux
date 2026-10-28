class_name XRRig
extends XROrigin3D
## OpenXR rig. Each hand is a Pointer (aim pose):
##   trigger: click / drag pins, fields, nodes, panels
##   grip on a node / board / panel: grab and move it (rotation follows)
##   grip on empty space: grab the world and pull yourself around
##   grip on empty space with both hands: pull apart / together to scale the world
##   poke a virtual key with the controller tip to type
##   left stick: move    right stick x: snap turn    right stick y: up/down,
##     or push/pull whatever is being dragged
##   B / Y: virtual keyboard    A: undo    X: redo    menu: HUD panel

const MOVE_SPEED := 1.5
const SNAP_TURN := deg_to_rad(30.0)
const RAY_COLOR := Color(0.6, 0.8, 1.0, 0.6)
const POKE_TIP := 0.03 ## Poke point, this far along the aim ray from the controller.

var workspace: Workspace
var camera: XRCamera3D
var hands := {} ## "left"/"right" -> {ctrl, pointer, ray, tip}
var hud_panel: Panel3D
var _snap_armed := true
var _world_grab := {} ## pointer id -> last controller position in origin space
var _scale_line: MeshInstance3D
var _scale_label: Label3D


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
		var tip := Style.sphere(0.006, Style.SELECT_COLOR)
		tip.position = Vector3(0, 0, -POKE_TIP)
		c.add_child(tip)
		c.button_pressed.connect(_on_button.bind(side))
		hands[side] = { ctrl = c, pointer = p, ray = ray, tip = tip }
	workspace.interaction.empty_handler = self
	workspace.keyboard.tapped.connect(func(hand: String):
		if hands.has(hand):
			(hands[hand].ctrl as XRController3D).trigger_haptic_pulse("haptic", 0.0, 0.3, 0.025, 0.0))

	_scale_line = MeshInstance3D.new()
	var lm := CylinderMesh.new()
	lm.top_radius = 0.002
	lm.bottom_radius = 0.002
	lm.height = 1.0
	_scale_line.mesh = lm
	_scale_line.material_override = Style.material(Style.SELECT_COLOR)
	_scale_line.top_level = true
	_scale_line.visible = false
	add_child(_scale_line)
	_scale_label = Style.label("", Style.FONT_TITLE, Style.SELECT_COLOR)
	_scale_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_scale_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_scale_label.no_depth_test = true
	_scale_label.top_level = true
	_scale_label.visible = false
	add_child(_scale_label)


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
		var tip: MeshInstance3D = h.tip
		tip.visible = ray.visible and workspace.keyboard.visible
		if tip.visible:
			workspace.keyboard.poke(side, tip.global_position)
	_update_world_grab()

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


## One hand on empty space drags the rig; both hands drag it by their midpoint
## and scale the world about that midpoint by how far apart they have moved.
func _update_world_grab() -> void:
	var now := {}
	for id in _world_grab:
		now[id] = _hand_local(id)
	if now.size() == 2:
		var a0: Vector3 = _world_grab.left
		var b0: Vector3 = _world_grab.right
		var a: Vector3 = now.left
		var b: Vector3 = now.right
		var mid := (a + b) * 0.5
		global_position -= global_basis * (mid - (a0 + b0) * 0.5)
		if a0.distance_to(b0) > 0.02:
			workspace.scale_world(a.distance_to(b) / a0.distance_to(b0), global_transform * mid)
		_show_scale_gizmo(global_transform * a, global_transform * b)
	else:
		for id in now:
			global_position -= global_basis * (now[id] - _world_grab[id])
	_world_grab = now


func _hand_local(id: String) -> Vector3:
	var c: XRController3D = hands[id].ctrl
	return global_transform.affine_inverse() * c.global_position


func _show_scale_gizmo(a: Vector3, b: Vector3) -> void:
	var d := b - a
	if d.length() < 0.001:
		return
	_scale_line.global_transform = Transform3D(Basis(Quaternion(Vector3.UP, d.normalized())).scaled(Vector3(1, d.length(), 1)), (a + b) * 0.5)
	_scale_line.visible = true
	_scale_label.global_position = (a + b) * 0.5 + Vector3.UP * 0.05
	_scale_label.text = "%d%%" % roundi(workspace.world_scale() * 100.0)
	_scale_label.visible = true


func ix_grab_empty(p: Pointer) -> void:
	_world_grab[p.id] = _hand_local(p.id)


func ix_ungrab_empty(p: Pointer) -> void:
	if _world_grab.size() == 2:
		workspace.status("World scale %d%%" % roundi(workspace.world_scale() * 100.0))
	_world_grab.erase(p.id)
	_scale_line.visible = false
	_scale_label.visible = false
