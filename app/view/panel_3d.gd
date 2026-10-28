class_name Panel3D
extends Node3D
## A regular Control tree rendered into a SubViewport on a quad. Pointer rays
## become mouse events in the viewport; keys are forwarded with send_key().
## Trigger-drag the handle bar under it to move it.

const PX_PER_M := 1100.0

var viewport: SubViewport
var size_m := Vector2(0.6, 0.4)
var root: Control
var _quad: MeshInstance3D
var _buttons := 0


func setup_panel(control: Control, p_size_m: Vector2) -> void:
	size_m = p_size_m
	viewport = SubViewport.new()
	viewport.size = Vector2i(roundi(size_m.x * PX_PER_M), roundi(size_m.y * PX_PER_M))
	viewport.transparent_bg = true
	viewport.gui_embed_subwindows = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	root = control
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	viewport.add_child(root)

	_quad = MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = size_m
	_quad.mesh = qm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = viewport.get_texture()
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	mat.render_priority = 4
	_quad.material_override = mat
	add_child(_quad)
	add_child(Style.collider(self, Vector3(size_m.x, size_m.y, 0.01)))
	var handle := Handle.new().setup(self)
	handle.position = Vector3(0, -size_m.y * 0.5 - 0.025, 0)
	add_child(handle)


func send_key(ev: InputEvent) -> void:
	viewport.push_input(ev)


## Pointer ray -> viewport pixel, via the panel plane (so drags that leave the
## panel keep tracking).
func _ray_px(p: Pointer) -> Vector2:
	var inv := global_transform.affine_inverse()
	var o: Vector3 = inv * p.origin
	var d: Vector3 = inv.basis * p.direction
	var local := o
	if not is_zero_approx(d.z):
		local = o + d * (-o.z / d.z)
	return Vector2((local.x / size_m.x + 0.5) * viewport.size.x, (0.5 - local.y / size_m.y) * viewport.size.y)


func _mouse_motion(p: Pointer) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = _ray_px(p)
	ev.global_position = ev.position
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if _buttons > 0 else 0
	viewport.push_input(ev)


func _mouse_button(p: Pointer, button: MouseButton, down: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = _ray_px(p)
	ev.global_position = ev.position
	ev.button_index = button
	ev.pressed = down
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if down and button == MOUSE_BUTTON_LEFT else 0
	viewport.push_input(ev)


func ix_hover_move(p: Pointer, _hit: Dictionary) -> void:
	_mouse_motion(p)


func ix_press(p: Pointer, _hit: Dictionary) -> void:
	_buttons = 1
	_mouse_button(p, MOUSE_BUTTON_LEFT, true)


func ix_drag(p: Pointer) -> void:
	_mouse_motion(p)


func ix_release(p: Pointer, _hit: Dictionary) -> void:
	_buttons = 0
	_mouse_button(p, MOUSE_BUTTON_LEFT, false)


## One wheel event whose factor is `amount` notches, so the small per-frame
## amounts a thumbstick sends scroll smoothly.
func ix_scroll(p: Pointer, amount: float) -> void:
	var b := MOUSE_BUTTON_WHEEL_UP if amount > 0 else MOUSE_BUTTON_WHEEL_DOWN
	for down in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.position = _ray_px(p)
		ev.global_position = ev.position
		ev.button_index = b
		ev.pressed = down
		ev.factor = absf(amount)
		viewport.push_input(ev)


## The bar under a panel: trigger-drag it to move the panel.
class Handle extends Node3D:
	const SIZE := Vector2(0.16, 0.022)
	const COLOR := Color(0.35, 0.45, 0.6, 0.9)
	var panel: Node3D
	var _bar: MeshInstance3D
	var _move: MoveDrag

	func setup(p_panel: Node3D) -> Handle:
		panel = p_panel
		_bar = Style.box(SIZE, COLOR, 0.008)
		_bar.position += Vector3(-SIZE.x * 0.5, SIZE.y * 0.5, 0)
		add_child(_bar)
		add_child(Style.collider(self, Vector3(SIZE.x, SIZE.y * 1.6, 0.02)))
		return self

	func ix_hover(_p: Pointer, _hit: Dictionary, entered: bool) -> void:
		_bar.material_override = Style.material(Style.SELECT_COLOR if entered else COLOR)

	func ix_press(p: Pointer, hit: Dictionary) -> void:
		_move = MoveDrag.begin(panel, p, hit)

	func ix_drag(p: Pointer) -> void:
		if _move:
			_move.update(p)

	func ix_release(_p: Pointer, _hit: Dictionary) -> void:
		_move = null

	func ix_scroll(_p: Pointer, amount: float) -> void:
		if _move:
			_move.push(amount)


static func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 26
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.10, 0.12, 0.96)
	sb.border_color = Color(0.35, 0.45, 0.6)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(14)
	t.set_stylebox("panel", "PanelContainer", sb)
	return t
