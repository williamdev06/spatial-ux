class_name Button3D
extends Node3D
## A small clickable text label.

signal pressed

var _label: Label3D
var _bg: MeshInstance3D


func setup(text: String, size := Style.FONT_SMALL, color := Style.TEXT) -> Button3D:
	_label = Style.label(text, size, color)
	var w := Style.text_width(text, size) + 0.016
	var h := size * Style.PIXEL * 1.3
	_label.position = Vector3(0.008, -h * 0.5, 0.002)
	add_child(_label)
	_bg = Style.box(Vector2(w, h), Color(0.2, 0.22, 0.26, 0.9), 0.002)
	add_child(_bg)
	add_child(Style.collider(self, Vector3(w, h, 0.01), Vector3(w * 0.5, -h * 0.5, 0)))
	return self


func width() -> float:
	return Style.text_width(_label.text, _label.font_size) + 0.016


func ix_hover(_p: Pointer, _hit: Dictionary, entered: bool) -> void:
	_label.modulate = Style.SELECT_COLOR if entered else Style.TEXT


func ix_click(_p: Pointer, _hit: Dictionary) -> void:
	pressed.emit()
