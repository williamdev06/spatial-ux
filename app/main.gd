extends Node3D
## Entry point. Starts in VR when an OpenXR runtime is available (and
## --desktop was not given), otherwise in the desktop fly-camera mode.
##
##   godot --path . -- --open=C:/path/to/godot/project [--desktop]

const SETTINGS_PATH := "user://settings.cfg"

var workspace: Workspace
var rig: Node3D
var hud: Hud


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
		_save_last_project(p))
	hud.open_requested.connect(func(p): workspace.open_project(p))

	var path: String = args.get("open", _last_project())
	if not path.is_empty():
		if path.is_relative_path():
			path = ProjectSettings.globalize_path("res://").path_join(path)
		workspace.open_project.call_deferred(path)
	else:
		hud.set_status("Open a Godot project folder to begin (try examples/demo_project).")


func _mount_hud(use_xr: bool) -> void:
	if use_xr:
		var panel := Panel3D.new()
		panel.setup_panel(hud, Vector2(0.42, 0.26))
		var left: XRController3D = (rig as XRRig).hands.left.ctrl
		left.add_child(panel)
		panel.position = Vector3(0, 0.08, 0.08)
		panel.rotation = Vector3(-PI / 3.0, 0, 0)
		(rig as XRRig).hud_panel = panel
	else:
		var layer := CanvasLayer.new()
		add_child(layer)
		hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
		hud.position = Vector2(8, 8)
		hud.custom_minimum_size = Vector2(560, 0)
		hud.mouse_filter = Control.MOUSE_FILTER_PASS
		layer.add_child(hud)


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


func _save_last_project(p: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("recent", "last_project", p)
	cfg.save(SETTINGS_PATH)
