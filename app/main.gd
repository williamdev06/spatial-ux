extends Node3D
## Entry point. Starts in VR when an OpenXR runtime is available (and
## --desktop was not given), otherwise in the desktop fly-camera mode.
##
##   godot --path . -- --open=C:/path/to/godot/project [--desktop]

const SETTINGS_PATH := "user://settings.cfg"
const MENU_SIZE := Vector2(0.9, 0.72)
const MENU_DISTANCE := 0.8

var workspace: Workspace
var rig: Node3D
var hud: Hud
var menu: Panel3D ## VR only: the HUD as a panel the menu button summons.


func _ready() -> void:
	_setup_environment()
	workspace = Workspace.new()
	workspace.name = "Workspace"
	add_child(workspace)

	var args := _user_args()
	var xr := XRServer.find_interface("OpenXR")
	var use_xr: bool = xr != null and xr.is_initialized() and not args.has("desktop")
	hud = Hud.new().build(use_xr)
	if use_xr:
		get_viewport().use_xr = true
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		var r := XRRig.new()
		r.workspace = workspace
		rig = r
		workspace.is_xr = true
	else:
		var r := DesktopRig.new()
		r.workspace = workspace
		rig = r
	add_child(rig)
	workspace.head_provider = rig.head_transform
	_mount_hud(use_xr)

	workspace.status_changed.connect(hud.set_status)
	workspace.project_opened.connect(func(p):
		hud.set_project(p)
		_save_last_project(p)
		hud.set_recent(_recent_projects())
		if menu:
			show_menu(false))
	hud.open_requested.connect(func(p): workspace.open_project(p))
	hud.set_recent(_recent_projects())

	var path: String = args.get("open", _last_project())
	if not path.is_empty():
		if path.is_relative_path():
			path = ProjectSettings.globalize_path("res://").path_join(path)
		workspace.open_project.call_deferred(path)
	else:
		hud.set_status("Open a Godot project folder to begin (try examples/demo_project).")
		if menu:
			# Give head tracking a moment so the menu lands in front of the viewer.
			get_tree().create_timer(0.5).timeout.connect(func():
				show_menu(true)
				hud.show_open_dialog())


func _mount_hud(use_xr: bool) -> void:
	if use_xr:
		menu = Panel3D.new()
		menu.name = "Menu"
		menu.setup_panel(hud, MENU_SIZE)
		add_child(menu)
		menu.visible = false
		(rig as XRRig).menu_pressed.connect(func(): show_menu(not menu.visible))
		hud.close_requested.connect(show_menu.bind(false))
		hud.keyboard_requested.connect(workspace.toggle_keyboard)
		hud.reset_scale_requested.connect(workspace.reset_world_scale)
	else:
		var layer := CanvasLayer.new()
		add_child(layer)
		hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
		hud.position = Vector2(8, 8)
		hud.custom_minimum_size = Vector2(560, 0)
		hud.mouse_filter = Control.MOUSE_FILTER_PASS
		layer.add_child(hud)


## Shows the VR menu in front of the viewer at about eye height, or hides it.
func show_menu(on: bool) -> void:
	menu.visible = on
	if not on:
		return
	var head: Transform3D = rig.head_transform()
	var fwd := -head.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	menu.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), head.origin + fwd * MENU_DISTANCE + Vector3.DOWN * 0.15)


func _input(ev: InputEvent) -> void:
	if not ev is InputEventKey:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus != null and not workspace.has_panel():
		return # Typing into the 2D HUD / file dialog.
	if ev.pressed and ev.keycode == KEY_O and (ev.ctrl_pressed or ev.meta_pressed):
		hud.show_open_dialog()
	elif ev.pressed and ev.keycode == KEY_F1:
		hud.toggle_help()
	elif not workspace.handle_key(ev):
		return
	get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and workspace:
		workspace.layout_store.save()


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.035, 0.04, 0.055)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.58, 0.65)
	env.ambient_light_energy = 0.8
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.5, 0)
	sun.light_energy = 0.9
	add_child(sun)
	# A faint floor so VR users have a horizon.
	var floor := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	floor.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.albedo_color = Color(0.08, 0.09, 0.12)
	floor.material_override = fm # single-sided: never hides anything from below
	add_child(floor)


func _user_args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		var s := a.trim_prefix("--")
		if s.contains("="):
			out[s.get_slice("=", 0)] = s.substr(s.find("=") + 1)
		else:
			out[s] = true
	return out


func _last_project() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		return cfg.get_value("recent", "last_project", "")
	return ""


func _recent_projects() -> Array:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		return cfg.get_value("recent", "projects", [])
	return []


func _save_last_project(p: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("recent", "last_project", p)
	var recent: Array = cfg.get_value("recent", "projects", [])
	recent.erase(p)
	recent.push_front(p)
	cfg.set_value("recent", "projects", recent.slice(0, Hud.MAX_RECENT))
	cfg.save(SETTINGS_PATH)
