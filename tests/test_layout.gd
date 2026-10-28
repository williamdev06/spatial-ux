extends TestCase
## Auto-layout and the layout sidecar.

const SRC := """func f(x):
	a()
	if x:
		b()
		c()
	else:
		d()
	for i in x:
		e()
	g()
"""


func _sizes(g: FunctionGraph) -> Dictionary:
	var sizes := {}
	for s in g.stmts:
		sizes[s.key] = Vector2(0.4, 0.1 + 0.05 * s.fields.size())
	return sizes


func test_layered_and_non_overlapping() -> void:
	var sf := temp_script(SRC)
	var g := FunctionGraph.build(sf, sf.find_function("f"))
	var sizes := _sizes(g)
	var pos := FunctionLayout.compute(g, sizes)
	check_eq(pos.size(), g.stmts.size(), "every node placed")
	for e in g.edges:
		check(pos[e.to].y < pos[e.from].y, "edge %s -> %s flows down" % [e.from, e.to])
	for a in pos:
		for b in pos:
			if a >= b:
				continue
			var ra := Rect2(Vector2(pos[a].x, -pos[a].y), sizes[a])
			var rb := Rect2(Vector2(pos[b].x, -pos[b].y), sizes[b])
			check(not ra.grow(-0.001).intersects(rb.grow(-0.001)), "%s overlaps %s" % [a, b])


func test_nested_scopes_get_depth() -> void:
	var sf := temp_script(SRC)
	var g := FunctionGraph.build(sf, sf.find_function("f"))
	var pos := FunctionLayout.compute(g, _sizes(g))
	check_eq(pos["0"].z, 0.0)
	check(pos["1.then.0"].z > pos["1"].z, "body pushed forward")


func test_reads_like_the_code() -> void:
	var sf := temp_script(SRC)
	var g := FunctionGraph.build(sf, sf.find_function("f"))
	var pos := FunctionLayout.compute(g, _sizes(g))
	check(pos["1.then.0"].x > pos["1"].x, "branch body indented right")
	check(pos["2"].y < pos["1.then.1"].y, "continuation below the then-body")
	check(pos["2"].y < pos["1.else.0"].y, "continuation below the else-body")
	check(is_equal_approx(pos["2"].x, pos["1"].x), "continuation in the same column as the if")
	check(pos["3"].y < pos["2.body.0"].y, "after the loop body")


func test_store_matches_by_key_then_hash() -> void:
	var dir := OS.get_user_data_dir().path_join("test_layout_store")
	DirAccess.make_dir_recursive_absolute(dir)
	DirAccess.remove_absolute(dir.path_join(LayoutStore.FILE_NAME))
	var sf := temp_script(SRC)
	var g := FunctionGraph.build(sf, sf.find_function("f"))
	var store := LayoutStore.new()
	store.open(dir)
	store.set_node(sf.res_path, "f", g.get_stmt("0"), Vector3(1, 2, 3))
	store.set_node(sf.res_path, "f", g.get_stmt("3"), Vector3(4, 5, 6)) # g()
	store.save()
	# External edit: a new statement at the top shifts every index.
	sf.apply_edits([{ start = sf.doc.line_start(byte_of(sf.doc, "\ta()")), end = sf.doc.line_start(byte_of(sf.doc, "\ta()")), text = "\tz()\n" }], false)
	var g2 := FunctionGraph.build(sf, sf.find_function("f"))
	var store2 := LayoutStore.new()
	store2.open(dir)
	var m := store2.node_positions(sf.res_path, g2)
	check_eq(m.get("1"), Vector3(1, 2, 3), "a() found by hash at its new key")
	check_eq(m.get("4"), Vector3(4, 5, 6), "g() found by hash")
	check(not m.has("0"), "new statement auto-laid out")
	# Edited header: no match.
	var at := byte_of(sf.doc, "a()")
	sf.apply_edits([{ start = at, end = at + 3, text = "a(1)" }], false)
	var g3 := FunctionGraph.build(sf, sf.find_function("f"))
	check(not store2.node_positions(sf.res_path, g3).has("1"), "changed statement falls back to auto layout")


func test_board_transform_roundtrip() -> void:
	var dir := OS.get_user_data_dir().path_join("test_layout_store")
	var store := LayoutStore.new()
	store.open(dir)
	var xf := Transform3D(Basis(Vector3.UP, 0.5), Vector3(1, 2, 3))
	store.set_board("res://x.gd", "f", xf)
	store.save()
	var s2 := LayoutStore.new()
	s2.open(dir)
	var got: Transform3D = s2.get_board("res://x.gd", "f")
	check(got.is_equal_approx(xf) or got.origin.is_equal_approx(xf.origin), "transform restored")
