class_name Interaction
extends Node3D
## Raycasts every Pointer each physics frame and dispatches to interactables.
##
## A collider made with Style.collider(target, ...) routes events to `target`,
## which may implement any of:
##   ix_hover(pointer, hit, entered: bool)
##   ix_press(pointer, hit)       ix_drag(pointer)       ix_release(pointer, hit)
##   ix_click(pointer, hit)       ix_double_click(pointer, hit)
##   ix_grab(pointer, hit)        ix_grab_drag(pointer)  ix_ungrab(pointer)
##   ix_scroll(pointer, amount)
## Unhandled presses/grabs on empty space go to `empty_handler` (the rig).

signal pointer_released_on_empty(pointer: Pointer)

const CLICK_MAX_MOVE := 0.02
const CLICK_MAX_MS := 450
const DOUBLE_CLICK_MS := 400

var pointers: Array[Pointer] = []
var empty_handler: Object


func add_pointer(p: Pointer) -> void:
	pointers.append(p)


func _physics_process(_dt: float) -> void:
	for p in pointers:
		_update(p)


func raycast(p: Pointer, exclude: Array = []) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(p.origin, p.point_at(p.max_distance), Style.UI_LAYER, exclude)
	q.collide_with_areas = true
	q.collide_with_bodies = true
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return {}
	hit.distance = p.origin.distance_to(hit.position)
	hit.target = hit.collider.get_meta("ix") if hit.collider.has_meta("ix") else null
	return hit


func _update(p: Pointer) -> void:
	var hit := raycast(p)
	var target: Object = hit.get("target")
	if target != null and not is_instance_valid(target):
		target = null
	if p.hover != target:
		if is_instance_valid(p.hover) and p.hover.has_method("ix_hover"):
			p.hover.ix_hover(p, hit, false)
		p.hover = target
		if target and target.has_method("ix_hover"):
			target.ix_hover(p, hit, true)
	elif target and target.has_method("ix_hover_move"):
		target.ix_hover_move(p, hit)
	p.hit = hit

	# Primary button.
	if p.pressed and not p.was_pressed:
		p.press_time = Time.get_ticks_msec()
		p.press_point = hit.get("position", p.point_at(1.0))
		p.moved_since_press = 0.0
		p.capture = target
		if target and target.has_method("ix_press"):
			target.ix_press(p, hit)
		elif target == null and empty_handler and empty_handler.has_method("ix_press_empty"):
			empty_handler.ix_press_empty(p)
	elif p.pressed and p.was_pressed:
		if is_instance_valid(p.capture):
			var cur: Vector3 = hit.get("position", p.press_point)
			p.moved_since_press = maxf(p.moved_since_press, cur.distance_to(p.press_point))
			if p.capture.has_method("ix_drag"):
				p.capture.ix_drag(p)
	elif not p.pressed and p.was_pressed:
		var cap := p.capture
		p.capture = null
		if is_instance_valid(cap):
			if cap.has_method("ix_release"):
				cap.ix_release(p, hit)
			var now := Time.get_ticks_msec()
			if p.moved_since_press < CLICK_MAX_MOVE and now - p.press_time < CLICK_MAX_MS and cap == target:
				if cap == p.last_click_target and now - p.last_click_time < DOUBLE_CLICK_MS and cap.has_method("ix_double_click"):
					cap.ix_double_click(p, hit)
					p.last_click_target = null
				else:
					if cap.has_method("ix_click"):
						cap.ix_click(p, hit)
					p.last_click_target = cap
					p.last_click_time = now
		elif target == null:
			pointer_released_on_empty.emit(p)
	p.was_pressed = p.pressed

	# Grip.
	if p.gripping and not p.was_gripping:
		p.grab_capture = target if target and target.has_method("ix_grab") else null
		if p.grab_capture:
			p.grab_capture.ix_grab(p, hit)
		elif empty_handler and empty_handler.has_method("ix_grab_empty"):
			empty_handler.ix_grab_empty(p)
	elif p.gripping and is_instance_valid(p.grab_capture):
		if p.grab_capture.has_method("ix_grab_drag"):
			p.grab_capture.ix_grab_drag(p)
	elif not p.gripping and p.was_gripping:
		if is_instance_valid(p.grab_capture) and p.grab_capture.has_method("ix_ungrab"):
			p.grab_capture.ix_ungrab(p)
		elif empty_handler and empty_handler.has_method("ix_ungrab_empty"):
			empty_handler.ix_ungrab_empty(p)
		p.grab_capture = null
	p.was_gripping = p.gripping

	# Scroll goes to what is being dragged, else to what is hovered.
	if not is_zero_approx(p.scroll):
		var st: Object = p.capture if is_instance_valid(p.capture) else (p.grab_capture if is_instance_valid(p.grab_capture) else target)
		if st and st.has_method("ix_scroll"):
			st.ix_scroll(p, p.scroll)
		elif empty_handler and empty_handler.has_method("ix_scroll_empty"):
			empty_handler.ix_scroll_empty(p, p.scroll)
		p.scroll = 0.0
