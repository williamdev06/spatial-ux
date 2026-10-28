class_name EditPanel
extends Panel3D
## Floating text editor for one field or one whole statement.
## Enter commits a single-line field; Ctrl+Enter commits multi-line text.

signal committed(text: String)
signal cancelled

var _line: LineEdit
var _text: TextEdit
var _multiline := false


func open(title: String, text: String, multiline: bool, hint := "") -> void:
	_multiline = multiline
	var pc := PanelContainer.new()
	pc.theme = Panel3D.make_theme()
	var vb := VBoxContainer.new()
	pc.add_child(vb)
	var tl := Label.new()
	tl.text = title
	tl.add_theme_color_override("font_color", Color(0.7, 0.8, 1.0))
	vb.add_child(tl)
	if multiline:
		_text = TextEdit.new()
		_text.text = text
		_text.custom_minimum_size = Vector2(0, 320)
		_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_text.add_theme_font_override("font", _mono())
		_text.indent_wrapped_lines = true
		vb.add_child(_text)
	else:
		_line = LineEdit.new()
		_line.text = text
		_line.add_theme_font_override("font", _mono())
		_line.text_submitted.connect(func(t): committed.emit(t))
		vb.add_child(_line)
	var hl := Label.new()
	hl.text = hint if not hint.is_empty() else ("Ctrl+Enter to apply, Esc to cancel" if multiline else "Enter to apply, Esc to cancel")
	hl.add_theme_color_override("font_color", Color(0.55, 0.58, 0.62))
	hl.add_theme_font_size_override("font_size", 20)
	vb.add_child(hl)
	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_END
	var ok := Button.new()
	ok.text = "Apply"
	ok.pressed.connect(func(): committed.emit(get_text()))
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func(): cancelled.emit())
	hb.add_child(cancel)
	hb.add_child(ok)
	vb.add_child(hb)
	setup_panel(pc, Vector2(0.75, 0.42 if multiline else 0.17))
	_focus.call_deferred()


func _focus() -> void:
	if _line:
		_line.grab_focus()
		_line.caret_column = _line.text.length()
	elif _text:
		_text.grab_focus()


func get_text() -> String:
	return _line.text if _line else _text.text


func send_key(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and ev.keycode in [KEY_ENTER, KEY_KP_ENTER] and _multiline and (ev.ctrl_pressed or ev.meta_pressed):
		committed.emit(get_text())
		return
	super.send_key(ev)


static func _mono() -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Cascadia Mono", "Consolas", "DejaVu Sans Mono", "Menlo", "monospace"])
	return f
