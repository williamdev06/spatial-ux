class_name Hud
extends PanelContainer
## Project picker, status line and help. Lives on a CanvasLayer on desktop
## and on a wrist panel in VR.

signal open_requested(path: String)

const HELP_DESKTOP := """Mouse: LMB click/drag · RMB hold to look · WASD/QE fly (Shift fast) · wheel dolly / push-pull while dragging · Ctrl+wheel scale world (Ctrl+0 reset) · MMB pan
Click a class sphere to show its functions as orbs; click an orb to open its board in front of it (boards stay open until "close"). Drag nodes and boards anywhere. Click a field to edit it; double-click a node for its full text.
Drag from a pin to empty space for the context search; drop on another pin to connect (exec: reorder, data: use the value).
Del delete · Alt+↑/↓ reorder · Space add after selected · Enter edit selected · Ctrl+Z/Y undo/redo · R auto-layout · K keyboard · Ctrl+O open · F1 help
Functions: "+ func" on a board or class sphere (N) · "+ input" on the func node (I) · click name / input / returns to edit, clear an input to remove it · double-click the func node to edit the whole signature · "delete" twice removes a function"""
const HELP_XR := """Trigger: click/drag · Grip: grab node/board/panel/keyboard, or the world · both grips on empty space: pull apart / together to scale the world
Left stick move · Right stick turn / up-down / push-pull · B/Y keyboard (poke or point at keys; grip with both hands to resize it) · A undo · X redo · Menu: this panel"""

var _path_label: Label
var _status: Label
var _help: Label
var _dialog: FileDialog


func build(xr: bool) -> Hud:
	theme = Panel3D.make_theme()
	theme.default_font_size = 14 if not xr else 24
	var vb := VBoxContainer.new()
	add_child(vb)
	var row := HBoxContainer.new()
	vb.add_child(row)
	var open := Button.new()
	open.text = "Open project…"
	open.pressed.connect(show_open_dialog)
	row.add_child(open)
	_path_label = Label.new()
	_path_label.text = "No project open"
	_path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_path_label)
	var hint := Label.new()
	hint.text = "F1 help" if not xr else ""
	hint.add_theme_color_override("font_color", Color(0.5, 0.52, 0.56))
	row.add_child(hint)
	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(0.65, 0.85, 1.0))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_status)
	_help = Label.new()
	_help.text = HELP_XR if xr else HELP_DESKTOP
	_help.add_theme_color_override("font_color", Color(0.6, 0.62, 0.66))
	_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_help.visible = xr
	vb.add_child(_help)
	_dialog = FileDialog.new()
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.title = "Open a Godot project folder"
	_dialog.size = Vector2i(900, 600)
	_dialog.use_native_dialog = not xr
	_dialog.dir_selected.connect(func(d): open_requested.emit(d))
	add_child(_dialog)
	return self


func show_open_dialog() -> void:
	_dialog.popup_centered()


func toggle_help() -> void:
	_help.visible = not _help.visible


func set_project(path: String) -> void:
	_path_label.text = path


func set_status(text: String) -> void:
	_status.text = text
