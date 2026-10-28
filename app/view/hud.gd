class_name Hud
extends PanelContainer
## Project picker, status line and help. Lives on a CanvasLayer on desktop.
## In VR it is the menu (a panel the left menu button summons) with a project
## browser made of big list rows instead of the file dialog.

signal open_requested(path: String)
signal keyboard_requested
signal reset_scale_requested
signal close_requested

const MAX_RECENT := 8

const HELP_DESKTOP := """Mouse: LMB click/drag · RMB hold to look · WASD/QE fly (Shift fast) · wheel dolly / push-pull while dragging · Ctrl+wheel scale world (Ctrl+0 reset) · MMB pan
Click a class sphere to show its functions as orbs; click an orb to open its board in front of it (boards stay open until "close"). Drag nodes and boards anywhere. Click a field to edit it; double-click a node for its full text.
Drag from a pin to empty space for the context search; drop on another pin to connect (exec: reorder, data: use the value).
Del delete · Alt+↑/↓ reorder · Space add after selected · Enter edit selected · Ctrl+Z/Y undo/redo · R auto-layout · K keyboard · Ctrl+O open · F1 help
Functions: "+ func" on a board or class sphere (N) · "+ input" on the func node (I) · click name / input / returns to edit, clear an input to remove it · double-click the func node to edit the whole signature · "delete" twice removes a function"""
const HELP_XR := """Trigger: click / drag anything (panels by the bar under them, the keyboard by its frame) · Grip: grab the world · both grips: pull apart / together to scale the world
Left stick move · Right stick turn / up-down / push-pull · point at a panel and push a stick up/down to scroll it · B/Y keyboard (poke or point at keys; trigger its frame with both hands to resize) · A undo · X redo · ≡ (left controller): this menu"""

var _xr := false
var _path_label: Label
var _status: Label
var _help: Label
var _dialog: FileDialog
var _recent: Array = []
var _browser: VBoxContainer
var _browse_label: Label
var _open_here: Button
var _entries: ItemList
var _entry_data: Array = [] ## item index -> {path, open} (null for headers)
var _cwd := "" ## Folder being browsed; "" = recent projects and places.


func build(xr: bool) -> Hud:
	_xr = xr
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
	if xr:
		for spec in [["Keyboard", keyboard_requested], ["Reset scale", reset_scale_requested], ["Close menu", close_requested]]:
			var b := Button.new()
			b.text = spec[0]
			b.pressed.connect((spec[1] as Signal).emit)
			row.add_child(b)
	_path_label = Label.new()
	_path_label.text = "No project open"
	_path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_label.clip_text = true
	if xr:
		vb.add_child(_path_label)
	else:
		row.add_child(_path_label)
	var hint := Label.new()
	hint.text = "F1 help" if not xr else ""
	hint.add_theme_color_override("font_color", Color(0.5, 0.52, 0.56))
	row.add_child(hint)
	if xr:
		_build_browser(vb)
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
	if _xr:
		_browser.visible = not _browser.visible
		if _browser.visible:
			_browse(_cwd)
	else:
		_dialog.popup_centered()


func set_recent(paths: Array) -> void:
	_recent = paths.slice(0, MAX_RECENT)
	if _browser and _browser.visible and _cwd.is_empty():
		_browse("")


# --- VR project browser ----------------------------------------------------------------

func _build_browser(parent: Control) -> void:
	_browser = VBoxContainer.new()
	_browser.visible = false
	_browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(_browser)
	var row := HBoxContainer.new()
	_browser.add_child(row)
	var up := Button.new()
	up.text = "↑ Up"
	up.pressed.connect(func(): _browse(_parent_dir(_cwd)))
	row.add_child(up)
	var home := Button.new()
	home.text = "Recent & places"
	home.pressed.connect(func(): _browse(""))
	row.add_child(home)
	_open_here = Button.new()
	_open_here.pressed.connect(func(): open_requested.emit(_cwd))
	row.add_child(_open_here)
	_browse_label = Label.new()
	_browse_label.add_theme_color_override("font_color", Color(0.7, 0.8, 1.0))
	_browse_label.clip_text = true
	_browser.add_child(_browse_label)
	_entries = ItemList.new()
	_entries.custom_minimum_size = Vector2(0, 330)
	_entries.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Wheel / stick scrolling also reports item_clicked: only a real click picks.
	_entries.item_clicked.connect(func(i, _pos, btn): if btn == MOUSE_BUTTON_LEFT: _pick(i))
	_browser.add_child(_entries)


## Lists `path`'s folders (Godot projects open on click, others are entered),
## or recent projects and places for "".
func _browse(path: String) -> void:
	_cwd = path
	_entries.clear()
	_entry_data.clear()
	if path.is_empty():
		_browse_label.text = "Recent projects and places"
		_header("Recent projects")
		for p in _recent:
			_entry(p, p, true)
		_header("Places")
		_entry("Bundled examples", ProjectSettings.globalize_path("res://examples"), false)
		var home := OS.get_environment("USERPROFILE") if OS.has_environment("USERPROFILE") else OS.get_environment("HOME")
		if not home.is_empty():
			_entry("Home    " + home.replace("\\", "/"), home.replace("\\", "/"), false)
		var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
		if not docs.is_empty():
			_entry("Documents    " + docs, docs, false)
		for i in DirAccess.get_drive_count():
			var drive := DirAccess.get_drive_name(i)
			_entry(drive + "/", drive + "/", false)
	else:
		_browse_label.text = path
		var da := DirAccess.open(path)
		if da == null:
			_header("Can't read this folder")
		else:
			var dirs := Array(da.get_directories())
			dirs.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
			for d in dirs:
				var full := path.path_join(d)
				if _is_project(full):
					_entry(d + "    — Godot project", full, true)
				else:
					_entry(d + "/", full, false)
	_open_here.disabled = path.is_empty()
	_open_here.text = "Open this project" if _is_project(path) else "Open this folder"


func _header(text: String) -> void:
	var i := _entries.add_item("— %s —" % text)
	_entries.set_item_disabled(i, true)
	_entries.set_item_selectable(i, false)
	_entries.set_item_custom_fg_color(i, Color(0.55, 0.65, 0.85))
	_entry_data.append(null)


func _entry(text: String, path: String, open: bool) -> void:
	var i := _entries.add_item(text)
	if open:
		_entries.set_item_custom_fg_color(i, Color(1.0, 0.85, 0.45))
	_entry_data.append({ path = path, open = open })


func _pick(i: int) -> void:
	if i < 0 or i >= _entry_data.size() or _entry_data[i] == null:
		return
	var e: Dictionary = _entry_data[i]
	if e.open:
		open_requested.emit(e.path)
	else:
		_browse(e.path)


static func _is_project(path: String) -> bool:
	return not path.is_empty() and FileAccess.file_exists(path.path_join("project.godot"))


## "" (the start view) above a drive root.
static func _parent_dir(path: String) -> String:
	var up := path.get_base_dir()
	return "" if path.is_empty() or up == path else up


func toggle_help() -> void:
	_help.visible = not _help.visible


func set_project(path: String) -> void:
	_path_label.text = path
	if _browser:
		_browser.visible = false


func set_status(text: String) -> void:
	_status.text = text
