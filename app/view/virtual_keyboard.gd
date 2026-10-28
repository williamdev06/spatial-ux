class_name VirtualKeyboard
extends Node3D
## A floating keyboard for VR, centred on its origin with the keys facing +Z.
##   trigger / mouse on a key: type (⌫, del and the arrows repeat while held)
##   poke a key with a controller tip: type (the rig calls poke() every frame)
##   grip anywhere on it, or trigger-drag its border: move it
##   grip it with both hands and pull apart / together: resize it
## Emits key events that the Workspace forwards to whichever panel has focus.

signal key_event(ev: InputEventKey)
signal tapped(hand: String) ## A key went down; `hand` is the pointer id, for haptics.

const UNIT := 0.048 ## Key pitch; a row is 15 units wide.
const GAP := 0.005
const BAR := 0.034 ## Title strip above the keys.
const PAD := 0.014
const CAP_DEPTH := 0.012
const PRESS_DEPTH := 0.006
const FONT_KEY := 34
const FONT_WORD := 22
const REPEAT_DELAY := 0.45
const REPEAT_RATE := 0.05
const REPEATS := ["⌫", "del", "←", "→", "↑", "↓"]
const CAPS_DOUBLE_TAP_MS := 400
const MIN_SCALE := 0.5
const MAX_SCALE := 2.5
const POKE_DEPTH := 0.03 ## How far behind a key face a poke still lands.
const POKE_REARM := 0.01 ## The tip must back out this far before it can poke again.

const ROWS := [
	["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=", "⌫"],
	["tab", "q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]", "\\"],
	["esc", "a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'", "enter"],
	["shift", "z", "x", "c", "v", "b", "n", "m", ",", ".", "/", "↑"],
	["ctrl", "home", "end", "space", "del", "←", "↓", "→"],
]
const WIDTHS := {
	"⌫": 2.0, "tab": 1.5, "\\": 1.5, "esc": 1.75, "enter": 2.25, "shift": 3.0,
	"ctrl": 1.5, "home": 1.25, "end": 1.25, "space": 6.0, "del": 2.0,
}
const SHIFTED := {
	"`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
	"-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?",
}
const SPECIAL := {
	"⌫": KEY_BACKSPACE, "tab": KEY_TAB, "esc": KEY_ESCAPE, "enter": KEY_ENTER, "space": KEY_SPACE,
	"del": KEY_DELETE, "home": KEY_HOME, "end": KEY_END,
	"←": KEY_LEFT, "→": KEY_RIGHT, "↑": KEY_UP, "↓": KEY_DOWN,
}
const KEY_COLOR := Color(0.18, 0.20, 0.24)
const MOD_COLOR := Color(0.13, 0.15, 0.19)
const HOVER_COLOR := Color(0.27, 0.32, 0.40)
const DOWN_COLOR := Color(0.36, 0.50, 0.72)
const LATCH_COLOR := Color(0.55, 0.42, 0.15)
const FRAME_COLOR := Color(0.05, 0.06, 0.08, 0.92)

var size := Vector2.ZERO ## Frame size in local units.
var user_placed := false ## Moved by hand: the Workspace leaves it where it is while in reach.
var _keys := {} ## id -> KeyCap
var _shift := false
var _caps := false
var _ctrl := false
var _last_shift_ms := -10000
var _held := {} ## holder ("left", "poke:right", ...) -> {key: KeyCap, t: float}
var _poke_armed := {} ## hand -> bool
var _move: MoveDrag ## Trigger drag on the border.
var _grabs := {} ## Pointer -> MoveDrag
var _pinch := {} ## Two-hand resize: distance, midpoint and transform at its start.


class KeyCap extends Node3D:
	var kb: VirtualKeyboard
	var id := ""
	var size := Vector2.ZERO
	var special := false
	var latched := false
	var hovers := 0
	var downs := 0
	var _cap: MeshInstance3D
	var _label: Label3D

	func setup(p_kb: VirtualKeyboard, p_id: String, p_size: Vector2) -> KeyCap:
		kb = p_kb
		id = p_id
		size = p_size
		special = VirtualKeyboard.SPECIAL.has(id) or id in ["shift", "ctrl"]
		_cap = Style.box(size, VirtualKeyboard.KEY_COLOR, VirtualKeyboard.CAP_DEPTH)
		add_child(_cap)
		_label = Style.label("", VirtualKeyboard.FONT_KEY)
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.position = Vector3(size.x * 0.5, -size.y * 0.5, 0.002)
		add_child(_label)
		# Colliders cover the gaps too, so a ray between keys never misses.
		var g := VirtualKeyboard.GAP
		add_child(Style.collider(self, Vector3(size.x + g, size.y + g, VirtualKeyboard.CAP_DEPTH), Vector3(size.x * 0.5, -size.y * 0.5, -VirtualKeyboard.CAP_DEPTH * 0.4)))
		return self

	func set_text(text: String) -> void:
		var font := VirtualKeyboard.FONT_WORD if special and text.length() > 1 else VirtualKeyboard.FONT_KEY
		var room := size.x - 0.01
		var w := Style.text_width(text, font)
		if w > room:
			font = int(font * room / w)
		_label.text = text
		_label.font_size = font

	func contains(local: Vector3) -> bool:
		var g := VirtualKeyboard.GAP * 0.5
		return local.x >= position.x - g and local.x <= position.x + size.x + g \
			and local.y <= position.y + g and local.y >= position.y - size.y - g

	func refresh() -> void:
		var c := VirtualKeyboard.MOD_COLOR if special else VirtualKeyboard.KEY_COLOR
		if downs > 0:
			c = VirtualKeyboard.DOWN_COLOR
		elif latched:
			c = VirtualKeyboard.LATCH_COLOR
		elif hovers > 0:
			c = VirtualKeyboard.HOVER_COLOR
		_cap.material_override = Style.material(c)
		position.z = -VirtualKeyboard.PRESS_DEPTH if downs > 0 else 0.0

	func ix_hover(_p: Pointer, _hit: Dictionary, entered: bool) -> void:
		hovers = maxi(0, hovers + (1 if entered else -1))
		refresh()

	func ix_press(p: Pointer, _hit: Dictionary) -> void:
		kb._key_down(self, p.id)

	func ix_release(p: Pointer, _hit: Dictionary) -> void:
		kb._key_up(p.id)

	func ix_grab(p: Pointer, hit: Dictionary) -> void:
		kb.ix_grab(p, hit)

	func ix_grab_drag(p: Pointer) -> void:
		kb.ix_grab_drag(p)

	func ix_ungrab(p: Pointer) -> void:
		kb.ix_ungrab(p)


func _ready() -> void:
	var keys_w := 15.0 * UNIT - GAP
	var keys_h := ROWS.size() * UNIT - GAP
	size = Vector2(keys_w + PAD * 2.0, keys_h + PAD * 2.0 + BAR)
	var top_left := Vector3(-size.x * 0.5, size.y * 0.5, 0)
	var frame := Style.box(size, FRAME_COLOR, 0.01)
	frame.position += top_left + Vector3(0, 0, -CAP_DEPTH * 0.7)
	add_child(frame)
	add_child(Style.collider(self, Vector3(size.x, size.y, 0.01), Vector3(0, 0, -CAP_DEPTH * 0.7 - 0.005)))
	var title := Style.label("grip: move  ·  grip with both hands: resize  ·  shift twice: caps lock", Style.FONT_SMALL, Style.TEXT_DIM)
	title.position = top_left + Vector3(PAD, -PAD * 0.5 - BAR * 0.5, 0.001)
	add_child(title)
	var y := top_left.y - PAD - BAR
	for row in ROWS:
		var x := top_left.x + PAD
		for id in row:
			var w: float = WIDTHS.get(id, 1.0) * UNIT
			var k := KeyCap.new().setup(self, id, Vector2(w - GAP, UNIT - GAP))
			k.position = Vector3(x, y, 0)
			add_child(k)
			_keys[id] = k
			x += w
		y -= UNIT
	_refresh_keys()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		for holder in _held.keys():
			_key_up(holder)
		_poke_armed.clear()


func _process(dt: float) -> void:
	for holder in _held:
		var h: Dictionary = _held[holder]
		if not REPEATS.has(h.key.id):
			continue
		h.t += dt
		if h.t >= 0.0:
			h.t -= REPEAT_RATE
			_type(h.key.id)


## Direct typing with a controller tip (a global position). Call every frame
## for each hand while the keyboard is shown.
func poke(hand: String, tip: Vector3) -> void:
	var holder := "poke:" + hand
	var local := global_transform.affine_inverse() * tip
	if local.z > POKE_REARM:
		_poke_armed[hand] = true
		_key_up(holder)
	elif _poke_armed.get(hand, false) and local.z <= 0.0 and local.z > -POKE_DEPTH:
		_poke_armed[hand] = false
		var k := key_at(local)
		if k:
			_key_down(k, holder)
	elif local.z <= -POKE_DEPTH * 2.0 or (_held.has(holder) and not _held[holder].key.contains(local)):
		_key_up(holder)


func key_at(local: Vector3) -> KeyCap:
	for id in _keys:
		if _keys[id].contains(local):
			return _keys[id]
	return null


func _key_down(k: KeyCap, holder: String) -> void:
	_key_up(holder)
	_held[holder] = { key = k, t = -REPEAT_DELAY }
	k.downs += 1
	k.refresh()
	_type(k.id)
	tapped.emit(holder.trim_prefix("poke:"))


func _key_up(holder: String) -> void:
	if not _held.has(holder):
		return
	var k: KeyCap = _held[holder].key
	_held.erase(holder)
	k.downs = maxi(0, k.downs - 1)
	k.refresh()


func _type(id: String) -> void:
	if id == "shift":
		var now := Time.get_ticks_msec()
		if _caps:
			_caps = false
			_shift = false
		elif _shift and now - _last_shift_ms < CAPS_DOUBLE_TAP_MS:
			_caps = true
			_shift = false
		else:
			_shift = not _shift
		_last_shift_ms = now
		_refresh_keys()
		return
	if id == "ctrl":
		_ctrl = not _ctrl
		_refresh_keys()
		return
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.ctrl_pressed = _ctrl
	ev.shift_pressed = _shift
	if SPECIAL.has(id):
		ev.keycode = SPECIAL[id]
		if id == "space":
			ev.unicode = 32
	else:
		var ch := _char(id)
		ev.unicode = ch.unicode_at(0)
		ev.keycode = OS.find_keycode_from_string(id.to_upper()) if _is_alnum(id) else KEY_NONE
	key_event.emit(ev)
	var up := ev.duplicate() as InputEventKey
	up.pressed = false
	key_event.emit(up)
	if _shift or _ctrl:
		_shift = false
		_ctrl = false
		_refresh_keys()


func _char(id: String) -> String:
	if id.to_upper() != id.to_lower():
		return id.to_upper() if _shift != _caps else id
	return SHIFTED.get(id, id) if _shift else id


static func _is_alnum(id: String) -> bool:
	return id.length() == 1 and (id.to_upper() != id.to_lower() or id.is_valid_int())


func _refresh_keys() -> void:
	for id in _keys:
		var k: KeyCap = _keys[id]
		match id:
			"space":
				k.set_text("")
			"shift":
				k.set_text("CAPS" if _caps else "shift")
			_:
				k.set_text(id if k.special else _char(id))
		k.latched = (id == "shift" and (_shift or _caps)) or (id == "ctrl" and _ctrl)
		k.refresh()


# --- moving and resizing ---------------------------------------------------------

func ix_press(p: Pointer, hit: Dictionary) -> void:
	_move = MoveDrag.begin(self, p, hit)


func ix_drag(p: Pointer) -> void:
	if _move:
		_move.update(p)


func ix_release(_p: Pointer, _hit: Dictionary) -> void:
	_move = null
	user_placed = true


func ix_scroll(_p: Pointer, amount: float) -> void:
	if _move:
		_move.push(amount)


func ix_grab(p: Pointer, hit: Dictionary) -> void:
	_grabs[p] = MoveDrag.begin(self, p, hit, true)
	_begin_pinch()


func ix_grab_drag(p: Pointer) -> void:
	if _grabs.size() >= 2:
		_update_pinch()
	elif _grabs.has(p):
		_grabs[p].update(p)


func ix_ungrab(p: Pointer) -> void:
	_grabs.erase(p)
	user_placed = true
	# The hand still holding on carries on from wherever the pinch left it.
	for q in _grabs.keys():
		_grabs[q] = MoveDrag.begin(self, q, {}, true)
	_begin_pinch()


func _begin_pinch() -> void:
	_pinch = {}
	if _grabs.size() < 2:
		return
	var ps: Array = _grabs.keys()
	var a: Vector3 = ps[0].origin
	var b: Vector3 = ps[1].origin
	_pinch = { d = maxf(0.02, a.distance_to(b)), mid = (a + b) * 0.5, xf = global_transform }


func _update_pinch() -> void:
	var ps: Array = _grabs.keys()
	var a: Vector3 = ps[0].origin
	var b: Vector3 = ps[1].origin
	var xf: Transform3D = _pinch.xf
	var s0 := xf.basis.get_scale().x
	var k := clampf(s0 * a.distance_to(b) / _pinch.d, MIN_SCALE, MAX_SCALE) / s0
	var mid := (a + b) * 0.5
	global_transform = Transform3D(xf.basis.scaled(Vector3.ONE * k), mid + (xf.origin - _pinch.mid) * k)
