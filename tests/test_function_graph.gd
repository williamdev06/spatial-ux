extends TestCase
## CST -> function graph projection.

const SRC := """class_name Player extends CharacterBody3D

func step(delta: float, target: Node3D) -> void:
	position.x += speed * delta
	target.look_at(global_position, Vector3.UP)
	var n := get_node("A")
	if speed > 1:
		print("fast")
	elif speed < 0: pass
	else:
		return
	for i: int in range(3):
		continue
	while true: break
	match n:
		1: pass
	await get_tree().process_frame
	var f = func(): return 1
	return

class Inner:
	func foo():
		pass
"""


func _graph(src: String, fname: String) -> FunctionGraph:
	var sf := temp_script(src)
	return FunctionGraph.build(sf, sf.find_function(fname))


func test_functions_listed() -> void:
	var sf := temp_script(SRC)
	var names := sf.functions().map(func(f): return f.qualname)
	check_eq(names, ["step", "Inner.foo"])


func test_statement_kinds() -> void:
	var g := _graph(SRC, "step")
	var kinds := []
	for k in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]:
		kinds.append(g.get_stmt(k).kind if g.get_stmt(k) else "?")
	check_eq(kinds, ["assign", "call", "var", "if", "for", "while", "code", "code", "code", "return"])


func test_entry_pins() -> void:
	var g := _graph(SRC, "step")
	var e := g.get_stmt("entry")
	var outs := e.data_outs.map(func(d): return "%s:%s" % [d.label, d.type])
	check_eq(outs, ["self:", "delta:float", "target:Node3D"])
	check_eq(e.get_field("name").text, "step")
	check_eq(e.get_field("param0").text, "delta: float")
	check_eq(e.get_field("param1").text, "target: Node3D")
	check_eq(e.get_field("ret").text, "void")


func test_call_fields() -> void:
	var g := _graph(SRC, "step")
	var s := g.get_stmt("1")
	check_eq(s.call_name, "look_at")
	check_eq(s.call_target, "target")
	check_eq(s.get_field("arg0").text, "global_position")
	check_eq(s.get_field("arg1").text, "Vector3.UP")


func test_if_branches_and_edges() -> void:
	var g := _graph(SRC, "step")
	var s := g.get_stmt("3")
	check_eq(s.exec_outs, ["then", "elif0", "else", "next"] as Array[String])
	check_eq(s.get_field("cond").text, "speed > 1")
	check_eq(s.get_field("cond_elif0").text, "speed < 0")
	check(g.get_stmt("3.then.0") != null, "then body")
	check_eq(g.get_stmt("3.elif0.0").kind, "pass")
	check_eq(g.get_stmt("3.else.0").kind, "return")
	var edge_set := g.edges.map(func(e): return "%s.%s>%s" % [e.from, e.pin, e.to])
	for want in ["entry.next>0", "0.next>1", "3.then>3.then.0", "3.elif0>3.elif0.0", "3.else>3.else.0", "3.next>4", "4.body>4.body.0"]:
		check(want in edge_set, "edge " + want)
	# break/continue/return end flow: no next edge out of them.
	check(not ("4.body.0.next>5" in edge_set), "continue has no next")


func test_nested_depth() -> void:
	var g := _graph(SRC, "step")
	check_eq(g.get_stmt("3").depth, 0)
	check_eq(g.get_stmt("3.then.0").depth, 1)


func test_var_fields() -> void:
	var g := _graph(SRC, "step")
	var s := g.get_stmt("2")
	check_eq(s.title, "var n")
	check_eq(s.get_field("value").text, "get_node(\"A\")")
	check_eq(s.data_outs[0].label, "n")


func test_return_without_value_has_insert_field() -> void:
	var g := _graph(SRC, "step")
	var s := g.get_stmt("9")
	var f := s.get_field("value")
	check(f.is_absent(), "absent value")
	check_eq(f.prefix, " ")


func test_hash_stable_across_whitespace_changes() -> void:
	var g1 := _graph(SRC, "step")
	var g2 := _graph(SRC.replace("look_at(global_position, Vector3.UP)", "look_at( global_position,  Vector3.UP )"), "step")
	check_eq(g1.get_stmt("1").hash, g2.get_stmt("1").hash)


func test_keys_unique() -> void:
	var g := _graph(SRC, "step")
	var seen := {}
	for s in g.stmts:
		check(not seen.has(s.key), "duplicate key " + s.key)
		seen[s.key] = true
