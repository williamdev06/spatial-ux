class_name DesktopRig
extends Node3D
## Fly camera + mouse pointer. Same scene and interactions as VR.
##   RMB hold + mouse: look        WASD / QE: move (Shift: faster)
##   LMB: click / drag             wheel: push-pull while dragging, else dolly
##   MMB drag: pan

const LOOK_SPEED := 0.0025
const MOVE_SPEED := 2.0

var workspace: Workspace
var camera: Camera3D
var pointer := Pointer.new()
var _yaw := 0.0
var _pitch := 0.0
var _looking := false
var _panning := false


func _ready() -> void:
	camera = Camera3D.new()
	camera.near = 0.02
	camera.fov = 70.0
	add_child(camera)
	position = Vector3(0, 1.6, 3.4)
	pointer.id = "mouse"
	workspace.interaction.add_pointer(pointer)
	workspace.interaction.empty_handler = self


func head_transform() -> Transform3D:
	return camera.global_transform


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		match ev.button_index:
			MOUSE_BUTTON_LEFT:
				pointer.pressed = ev.pressed
			MOUSE_BUTTON_RIGHT:
				_looking = ev.pressed
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if ev.pressed else Input.MOUSE_MODE_VISIBLE
			MOUSE_BUTTON_MIDDLE:
				_panning = ev.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if ev.pressed:
					pointer.scroll += 1.0 * ev.factor if ev.factor > 0 else 1.0
			MOUSE_BUTTON_WHEEL_DOWN:
				if ev.pressed:
					pointer.scroll -= 1.0 * ev.factor if ev.factor > 0 else 1.0
	elif ev is InputEventMouseMotion:
		if _looking:
			_yaw -= ev.relative.x * LOOK_SPEED
			_pitch = clampf(_pitch - ev.relative.y * LOOK_SPEED, -1.5, 1.5)
			rotation = Vector3(_pitch, _yaw, 0)
		elif _panning:
			var s := 0.004
			position += (-basis.x * ev.relative.x + basis.y * ev.relative.y) * s


func _input(ev: InputEvent) -> void:
	# Releases always reach us, even over GUI, so buttons never stick.
	if ev is InputEventMouseButton and not ev.pressed:
		if ev.button_index == MOUSE_BUTTON_LEFT:
			pointer.pressed = false
		elif ev.button_index == MOUSE_BUTTON_RIGHT and _looking:
			_looking = false
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif ev.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = false


func _process(dt: float) -> void:
	var mp := get_viewport().get_mouse_position()
	if _looking:
		mp = get_viewport().get_visible_rect().size * 0.5
	pointer.origin = camera.project_ray_origin(mp)
	pointer.direction = camera.project_ray_normal(mp)
	pointer.transform = camera.global_transform
	if workspace.has_panel() or get_viewport().gui_get_focus_owner() != null:
		return
	var v := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		v.z -= 1
	if Input.is_physical_key_pressed(KEY_S):
		v.z += 1
	if Input.is_physical_key_pressed(KEY_A):
		v.x -= 1
	if Input.is_physical_key_pressed(KEY_D):
		v.x += 1
	if Input.is_physical_key_pressed(KEY_E):
		v.y += 1
	if Input.is_physical_key_pressed(KEY_Q):
		v.y -= 1
	if v != Vector3.ZERO and not Input.is_key_pressed(KEY_CTRL):
		var speed := MOVE_SPEED * (3.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		position += (basis * v.normalized()) * speed * dt


func ix_scroll_empty(_p: Pointer, amount: float) -> void:
	position += -basis.z * amount * 0.25
