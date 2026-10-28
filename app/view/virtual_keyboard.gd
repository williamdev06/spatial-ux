class_name VirtualKeyboard
extends Node3D
## A simple floating keyboard for VR. Emits key events that the Workspace
## forwards to whichever panel has focus.

signal key_event(ev: InputEventKey)

const ROWS := [
	["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=", "⌫"],
	["⇥", "q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]", "\\"],
	["esc", "a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'", "⏎"],
	["⇧", "z", "x", "c", "v", "b", "n", "m", ",", ".", "/", "↑"],
	["ctrl", "space", "←", "↓", "→"],
]
const SHIFTED := {
	"`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
	"-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?",
}
const SPECIAL := {
	"⌫": KEY_BACKSPACE, "⇥": KEY_TAB, "esc": KEY_ESCAPE, "⏎": KEY_ENTER, "space": KEY_SPACE,
	"←": KEY_LEFT, "→": KEY_RIGHT, "↑": KEY_UP, "↓": KEY_DOWN,
}
const KEY_W := 0.045
const KEY_GAP := 0.006

var _shift := false
var _ctrl := false
var _labels := {}


func _ready() -> void:
	var y := 0.0
	for r in ROWS.size():
		var x := r * KEY_W * 0.3
		for k in ROWS[r]:
			var w := KEY_W * (5.0 if k == "space" else (1.6 if k.length() > 1 else 1.0))
			var b := Button3D.new().setup(k if k != "space" else "        space        ", Style.FONT)
			b.position = Vector3(x, y, 0)
			b.pressed.connect(_on_key.bind(k))
			add_child(b)
			_labels[k] = b
			x += maxf(w, b.width()) + KEY_GAP
		y -= KEY_W + KEY_GAP
	var bg := Style.box(Vector2(15.5 * (KEY_W + KEY_GAP), -y + 0.02), Color(0.05, 0.06, 0.08, 0.85), 0.004)
	bg.position += Vector3(-0.01, 0.01, -0.006)
	add_child(bg)


func _on_key(k: String) -> void:
	if k == "⇧":
		_shift = not _shift
		return
	if k == "ctrl":
		_ctrl = not _ctrl
		return
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.ctrl_pressed = _ctrl
	ev.shift_pressed = _shift
	if SPECIAL.has(k):
		ev.keycode = SPECIAL[k]
		if k == "space":
			ev.unicode = 32
	else:
		var ch: String = SHIFTED.get(k, k.to_upper()) if _shift else k
		ev.unicode = ch.unicode_at(0)
		ev.keycode = OS.find_keycode_from_string(k.to_upper()) if k.length() == 1 and k.to_upper() != k.to_lower() else KEY_NONE
	key_event.emit(ev)
	var up := ev.duplicate() as InputEventKey
	up.pressed = false
	key_event.emit(up)
	_shift = false
	_ctrl = false
