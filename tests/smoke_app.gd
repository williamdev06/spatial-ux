extends SceneTree
## Headless end-to-end smoke test of the app: opens a temp copy of the demo
## project, expands every class, and drives edits through the Workspace and
## simulated pointer input. Not part of run_tests.gd (needs the full scene).
##
##   godot --headless --path . --script res://tests/smoke_app.gd

var main: Node
var ws: Workspace
var failures := 0
var tmp := ""


func _initialize() -> void:
	tmp = OS.get_user_data_dir().path_join("smoke_demo")
	_copy_dir(ProjectSettings.globalize_path("res://examples/demo_project"), tmp)
	DirAccess.remove_absolute(tmp.path_join(".graphlayout.json"))
	main = load("res://app/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func check(cond: bool, msg: String) -> void:
	print(("  ok   " if cond else " FAIL  ") + msg)
	if not cond:
		failures += 1


func frames(n: int) -> void:
	for i in n:
		await process_frame
		await physics_frame


func _run() -> void:
	ws = main.workspace
	await frames(2)
	check(ws.open_project(tmp), "open project")
	check(ws.macro.nodes.size() == 4, "4 classes in macro view (got %d)" % ws.macro.nodes.size())
	await frames(30)
	for id in ws.macro.nodes.keys():
		ws.toggle_class(id)
	await frames(5)
	var boards := ws.all_boards()
	check(boards.size() >= 14, "boards for every function (got %d)" % boards.size())

	var player_file: ScriptFile = ws.index.files["res://actors/player.gd"]
	var b: FunctionBoard = null
	for x in boards:
		if x.file == player_file and x.qualname == "take_damage":
			b = x
	check(b != null, "take_damage board")
	var before := player_file.doc.get_source()

	# Field edit.
	var s := b.graph.get_stmt("0")
	ws.edit_field(b, "0", "right")
	check(ws.has_panel(), "edit panel opened")
	(ws._panel as EditPanel).committed.emit("amount * 2")
	await frames(2)
	check(player_file.doc.get_source().contains("health -= amount * 2"), "field edit written")
	check(FileAccess.get_file_as_string(player_file.path).contains("health -= amount * 2"), "on disk")

	# Insert via exec drag-off search (simulated choose).
	var pin: GraphPin = b.pin("0", "exec_out:next")
	ws._open_pin_search(pin, pin.global_position)
	check(ws.has_panel() and ws._panel is SearchPanel, "search panel opened")
	var cands: Array = ws._panel._all
	var heal_c = cands.filter(func(c): return c.label == "heal()")
	check(heal_c.size() == 1, "self method offered")
	(ws._panel as SearchPanel).chosen.emit(heal_c[0])
	await frames(2)
	check(player_file.doc.get_source().contains("health -= amount * 2\n\theal()\n"), "statement inserted")

	# Data drag-off from a typed param (`source: Node`) lists Node members first.
	var entry_pin: GraphPin = b.pin("entry", "data_out:param:source")
	ws._open_pin_search(entry_pin, entry_pin.global_position)
	var first_groups: Array = ws._panel._all.slice(0, 3).map(func(c): return c.group_label)
	check(first_groups[0] == "Node", "Node members first (got %s)" % [first_groups])
	ws._close_panel()

	# Drag-off from a custom class: Enemy in attack_nearest (`target` var typed Enemy).
	var cands_enemy := ws.search.for_output("Enemy", "target")
	check(cands_enemy[0].group_label == "Enemy" and cands_enemy[0].kind == "method", "Enemy funcs first")
	var engine_idx := cands_enemy.map(func(c): return c.group_label).find("CharacterBody3D")
	check(engine_idx > 0, "then inherited engine members")

	# Delete + undo.
	b = _board(ws, player_file, "take_damage")
	ws.select(b, "1")
	ws.delete_selected()
	await frames(2)
	check(not player_file.doc.get_source().contains("\theal()\n"), "deleted")
	ws.undo()
	await frames(2)
	check(player_file.doc.get_source().contains("\theal()\n"), "undo")

	# Reorder via exec wire: connect entry.next -> stmt 1 (move it first).
	b = _board(ws, player_file, "take_damage")
	ws._connect_pins(b.pin("entry", "exec_out:next"), b.pin("1", "exec_in"))
	await frames(2)
	check(player_file.doc.get_source().contains("-> int:\n\theal()\n\thealth -= amount * 2"), "reordered by wire")

	# Simulated pointer drag of a node writes the layout sidecar.
	b = _board(ws, player_file, "take_damage")
	var node: StmtNode3D = b.nodes["0"]
	var p := Pointer.new()
	p.id = "test"
	var cam: Transform3D = ws.head_provider.call()
	var target_pt := node.global_position + Vector3(0.05, -0.02, 0)
	p.origin = target_pt + node.global_basis.z * 0.03
	p.direction = -node.global_basis.z
	ws.interaction.add_pointer(p)
	await frames(2)
	check(p.hover == node, "pointer hovers node (got %s)" % [p.hover])
	p.pressed = true
	await frames(2)
	p.origin += node.global_basis.x * 0.3 + node.global_basis.y * 0.1
	await frames(2)
	p.pressed = false
	await frames(2)
	ws.layout_store.save()
	check(FileAccess.file_exists(tmp.path_join(".graphlayout.json")), "layout sidecar written")
	var moved_pos := node.position

	# External edit: insert a line at the top of take_damage; manual position survives.
	var src := FileAccess.get_file_as_string(player_file.path)
	src = src.replace("-> int:\n", "-> int:\n\tprint(\"external\")\n")
	var f := FileAccess.open(player_file.path, FileAccess.WRITE)
	f.store_string(src)
	f.close()
	await create_timer(1.6).timeout
	await frames(3)
	b = _board(ws, player_file, "take_damage")
	check(b.graph.get_stmt("0").kind == "call" and b.graph.get_stmt("0").call_name == "print", "external edit picked up")
	var heal_node: StmtNode3D = b.nodes["1"]
	check(heal_node.position.distance_to(moved_pos) < 0.002 and moved_pos.distance_to(Vector3.ZERO) > 0.0, "manual layout kept for moved statement (%s vs %s)" % [heal_node.position, moved_pos])

	# Diff cleanliness: only edited lines differ from the original.
	var after := player_file.doc.get_source()
	var a := before.split("\n")
	var c := after.split("\n")
	var changed := 0
	for line in c:
		if not a.has(line):
			changed += 1
	check(changed <= 3, "only edited lines changed (%d new lines)" % changed)
	check(after.contains("# Gravity first, then input."), "comments preserved")

	await _function_ops(player_file)

	# Clicking the macro node collapses it.
	ws.toggle_class("Player")
	await frames(2)
	check(ws._boards.get("Player") == null, "collapsed")

	print("\nsmoke: %d failures" % failures)
	quit(1 if failures > 0 else 0)


## New functions, inputs, outputs, rename and delete, driven through the panels.
func _function_ops(sf: ScriptFile) -> void:
	var heal := _board(ws, sf, "heal")
	# "+ func" from the heal board.
	ws.prompt_new_function(heal.self_type, heal)
	check(ws._panel is EditPanel, "new function prompt")
	(ws._panel as EditPanel).committed.emit("jump(height: float) -> bool")
	await frames(3)
	check(sf.doc.get_source().contains("\n\n\nfunc jump(height: float) -> bool:\n\treturn false\n"), "function created")
	var jump := _board(ws, sf, "jump")
	check(jump != null, "board for the new function")
	if jump == null:
		return
	check(jump.position.x > heal.position.x and is_equal_approx(jump.global_basis.z.dot(heal.global_basis.z), 1.0), "placed next to the source board")

	# "+ input".
	ws.add_input(jump)
	(ws._panel as EditPanel).committed.emit("boost := 1.0")
	await frames(2)
	check(sf.doc.get_source().contains("func jump(height: float, boost := 1.0) -> bool:"), "input added")
	jump = _board(ws, sf, "jump")
	check(jump.graph.get_stmt("entry").get_data_out("param:boost") != null, "input pin on the func node")

	# Edit an input; clearing it removes it.
	ws.edit_field(jump, "entry", "param0")
	(ws._panel as EditPanel).committed.emit("height: int")
	await frames(2)
	check(sf.doc.get_source().contains("func jump(height: int, boost := 1.0) -> bool:"), "input edited")
	ws.edit_field(_board(ws, sf, "jump"), "entry", "param1")
	(ws._panel as EditPanel).committed.emit("")
	await frames(2)
	check(sf.doc.get_source().contains("func jump(height: int) -> bool:"), "input removed")

	# Output type via the type picker, including a typed custom type.
	ws.edit_field(_board(ws, sf, "jump"), "entry", "ret")
	check(ws._panel is SearchPanel, "type picker")
	var picker: SearchPanel = ws._panel
	picker._filter.text = "Array[Vector3]"
	picker._refresh()
	check(picker._shown[0].expr == "Array[Vector3]", "typed type offered first")
	picker.chosen.emit(picker._shown[0])
	await frames(2)
	check(sf.doc.get_source().contains("func jump(height: int) -> Array[Vector3]:"), "output type changed")

	# Rename keeps the board.
	jump = _board(ws, sf, "jump")
	var jump_xf := jump.global_transform
	ws.edit_field(jump, "entry", "name")
	(ws._panel as EditPanel).committed.emit("leap")
	await frames(3)
	check(sf.doc.get_source().contains("func leap(height: int) -> Array[Vector3]:"), "renamed")
	var leap := _board(ws, sf, "leap")
	check(leap == jump and leap.global_transform.is_equal_approx(jump_xf), "same board, same place")
	check(_board(ws, sf, "jump") == null, "no stale board")

	# Whole-signature edit.
	ws.edit_raw(leap, "entry")
	(ws._panel as EditPanel).committed.emit("leap(height: int, when: float) -> int")
	await frames(2)
	check(sf.doc.get_source().contains("func leap(height: int, when: float) -> int:"), "signature edited")

	# Drag-off from a call argument: "+ new input" adds a parameter and uses it.
	var heal_b := _board(ws, sf, "heal")
	var g := heal_b.graph
	var call_key := ""
	for s in g.stmts:
		if s.kind == "call" and s.call_name == "emit":
			call_key = s.key
	ws._open_pin_search(heal_b.pin(call_key, "data_in:arg0"), heal_b.global_position)
	var first: MemberSearch.Candidate = ws._panel._all[0]
	check(first.kind == "new_input", "new input offered first (got %s)" % first.label)
	(ws._panel as SearchPanel).chosen.emit(first)
	await frames(2)
	var heal_src := sf.doc.get_source().substr(sf.doc.get_source().find("func heal"), 200)
	check(heal_src.contains("func heal(amount: int, value: int) -> void:") and heal_src.contains("health_changed.emit(value)"), "new input wired into the call:\n" + heal_src)
	sf.undo()
	await frames(2)
	check(sf.doc.get_source().contains("func heal(amount: int) -> void:") and sf.doc.get_source().contains("health_changed.emit(health)"), "one undo step")

	# Drag-off from a value (`var d := ...: float` in attack_nearest):
	# "return d as the function's output" also sets the return type.
	var an := _board(ws, sf, "attack_nearest")
	var dkey := ""
	for s in an.graph.stmts:
		if s.kind == "var" and s.title == "var d":
			dkey = s.key
	ws._open_pin_search(an.pin(dkey, "data_out:var"), an.global_position)
	var ret_c: MemberSearch.Candidate = ws._panel._all[0]
	check(ret_c.kind == "return_output", "return-as-output offered first")
	(ws._panel as SearchPanel).chosen.emit(ret_c)
	await frames(2)
	check(sf.doc.get_source().contains("func attack_nearest() -> float:") and sf.doc.get_source().contains("\t\tvar d := global_position.distance_to(e.global_position)\n\t\treturn d\n"), "returned and output type set")
	sf.undo()
	await frames(2)
	check(sf.doc.get_source().contains("func attack_nearest() -> void:"), "undone in one step")

	# Delete needs two clicks.
	leap = _board(ws, sf, "leap")
	ws.delete_function(leap)
	await frames(2)
	check(sf.doc.get_source().contains("func leap("), "first click only arms delete")
	ws.delete_function(leap)
	await frames(3)
	check(not sf.doc.get_source().contains("func leap("), "deleted")
	check(_board(ws, sf, "leap") == null, "board removed")
	check(not sf.doc.has_errors(), "file still parses")

	# "+ func" on a class with the class sphere (end of class).
	ws.prompt_new_function("Boss")
	(ws._panel as EditPanel).committed.emit("taunt")
	await frames(3)
	var boss_file: ScriptFile = ws.index.files["res://actors/boss.gd"]
	check(boss_file.doc.get_source().ends_with("scale = Vector3.ONE * 1.5\n\n\nfunc taunt():\n\tpass\n"), "created at end of class")


func _board(w: Workspace, sf: ScriptFile, qual: String) -> FunctionBoard:
	for x in w.all_boards():
		if is_instance_valid(x) and x.file == sf and x.qualname == qual:
			return x
	return null


func _copy_dir(from: String, to: String) -> void:
	DirAccess.make_dir_recursive_absolute(to)
	var da := DirAccess.open(from)
	for fn in da.get_files():
		DirAccess.copy_absolute(from.path_join(fn), to.path_join(fn))
	for d in da.get_directories():
		_copy_dir(from.path_join(d), to.path_join(d))
