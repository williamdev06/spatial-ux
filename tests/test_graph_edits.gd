extends TestCase
## Graph operations -> text edits. Every case checks the exact resulting text,
## that the tree stays valid, and that the incremental tree matches a fresh parse.

const SRC := """extends Node

# Header comment stays.
func run(enemy: Node3D) -> void:
	var hp := 10 # health
	enemy.queue_free()
	if hp > 5:
		print("high")
		print("still high")
	else:
		print("low")
	# trailing comment
	print("done")
"""


## Runs a GraphEdits op the way the app does: apply, rebuild, retry if asked.
func run_op(sf: ScriptFile, fname: String, op: Callable) -> bool:
	for attempt in 4:
		var g := FunctionGraph.build(sf, sf.find_function(fname))
		var r: Dictionary = op.call(g)
		if r.is_empty():
			return false
		if not sf.apply_edits(r.edits, false):
			return false
		if not r.get("retry", false):
			return true
	return false


func _src_of(sf: ScriptFile) -> String:
	return sf.doc.get_source()


func _valid(sf: ScriptFile) -> void:
	check(not sf.doc.has_errors(), "result parses cleanly:\n" + _src_of(sf))
	check(sf.doc.verify_incremental(), "incremental == fresh")


func test_set_field() -> void:
	var sf := temp_script(SRC)
	check(run_op(sf, "run", func(g):
		var s: FunctionGraph.Stmt = g.get_stmt("2")
		return GraphEdits.set_field(sf.doc, s, s.get_field("cond"), "hp >= 7")), "op")
	check_eq(_src_of(sf), SRC.replace("if hp > 5:", "if hp >= 7:"))
	_valid(sf)


func test_set_absent_field_inserts_prefix_and_clear_removes_it() -> void:
	var src := "func f():\n\tvar a\n\treturn\n"
	var sf := temp_script(src)
	run_op(sf, "f", func(g):
		var s: FunctionGraph.Stmt = g.get_stmt("0")
		return GraphEdits.set_field(sf.doc, s, s.get_field("value"), "3"))
	run_op(sf, "f", func(g):
		var s: FunctionGraph.Stmt = g.get_stmt("1")
		return GraphEdits.set_field(sf.doc, s, s.get_field("value"), "a"))
	check_eq(_src_of(sf), "func f():\n\tvar a = 3\n\treturn a\n")
	run_op(sf, "f", func(g):
		var s: FunctionGraph.Stmt = g.get_stmt("0")
		return GraphEdits.set_field(sf.doc, s, s.get_field("value"), ""))
	check_eq(_src_of(sf), "func f():\n\tvar a\n\treturn a\n")
	_valid(sf)


func test_delete_statement_only_touches_its_line() -> void:
	var sf := temp_script(SRC)
	check(run_op(sf, "run", func(g): return GraphEdits.delete_statement(sf.doc, g, g.get_stmt("1"))), "op")
	check_eq(_src_of(sf), SRC.replace("\tenemy.queue_free()\n", ""))
	_valid(sf)


func test_delete_before_blank_line_keeps_following_lines() -> void:
	var src := "func f(n, p, first_point):\n\tfor i in n:\n\t\tpolygon.append(p)\n\tpolygon.append(first_point)\n\n\t# comment\n\tget_window().x = polygon\n"
	var sf := temp_script(src)
	check(run_op(sf, "f", func(g): return GraphEdits.delete_statement(sf.doc, g, g.get_stmt("1"))), "op")
	check_eq(_src_of(sf), src.replace("\tpolygon.append(first_point)\n", ""))
	_valid(sf)


func test_delete_one_of_identical_neighbours() -> void:
	# From sprite_polygon_passthrough.gd: deleting either copy leaves the other,
	# and the blank line and comment around them, as they were.
	var src := "func f():\n\tfor b in bs:\n\t\tfor p in b:\n\t\t\tpolygon.append(p)\n\n\t\tpolygon.append(first_point)\n\t\tpolygon.append(first_point)\n\n\t# comment\n\tget_window().x = polygon\n"
	var want := "func f():\n\tfor b in bs:\n\t\tfor p in b:\n\t\t\tpolygon.append(p)\n\n\t\tpolygon.append(first_point)\n\n\t# comment\n\tget_window().x = polygon\n"
	for key in ["0.body.1", "0.body.2"]:
		var sf := temp_script(src)
		check(run_op(sf, "f", func(g): return GraphEdits.delete_statement(sf.doc, g, g.get_stmt(key))), "op " + key)
		check_eq(_src_of(sf), want)
		_valid(sf)


func test_delete_compound_keeps_following_comment() -> void:
	var sf := temp_script(SRC)
	run_op(sf, "run", func(g): return GraphEdits.delete_statement(sf.doc, g, g.get_stmt("2")))
	var want := SRC.replace("\tif hp > 5:\n\t\tprint(\"high\")\n\t\tprint(\"still high\")\n\telse:\n\t\tprint(\"low\")\n", "")
	check_eq(_src_of(sf), want)
	_valid(sf)


func test_delete_only_statement_becomes_pass() -> void:
	var sf := temp_script(SRC)
	run_op(sf, "run", func(g): return GraphEdits.delete_statement(sf.doc, g, g.get_stmt("2.else.0")))
	check_eq(_src_of(sf), SRC.replace("print(\"low\")", "pass"))
	_valid(sf)


func test_insert_after() -> void:
	var sf := temp_script(SRC)
	run_op(sf, "run", func(g): return GraphEdits.insert_after(sf.doc, g, g.get_stmt("0"), "enemy.hide()"))
	check_eq(_src_of(sf), SRC.replace("# health\n", "# health\n\tenemy.hide()\n"))
	_valid(sf)


func test_insert_after_compound_goes_after_its_body() -> void:
	var sf := temp_script(SRC)
	run_op(sf, "run", func(g): return GraphEdits.insert_after(sf.doc, g, g.get_stmt("2"), "print(1)"))
	check_eq(_src_of(sf), SRC.replace("\t\tprint(\"low\")\n", "\t\tprint(\"low\")\n\tprint(1)\n"))
	_valid(sf)


func test_insert_multiline_reindents() -> void:
	var sf := temp_script(SRC)
	run_op(sf, "run", func(g): return GraphEdits.insert_at_body_start(sf.doc, g, "2|then", "if a:\n\tb()"))
	check_eq(_src_of(sf), SRC.replace("\tif hp > 5:\n", "\tif hp > 5:\n\t\tif a:\n\t\t\tb()\n"))
	_valid(sf)


func test_insert_at_function_start() -> void:
	var sf := temp_script(SRC)
	run_op(sf, "run", func(g): return GraphEdits.insert_after(sf.doc, g, g.get_stmt("entry"), "print(\"start\")"))
	check_eq(_src_of(sf), SRC.replace("-> void:\n", "-> void:\n\tprint(\"start\")\n"))
	_valid(sf)


func test_insert_into_inline_body_normalizes_it() -> void:
	var src := "func f(x):\n\tif x: return\n\tprint(x)\n"
	var sf := temp_script(src)
	check(run_op(sf, "f", func(g): return GraphEdits.insert_after(sf.doc, g, g.get_stmt("0.then.0"), "print(2)")), "op")
	check_eq(_src_of(sf), "func f(x):\n\tif x:\n\t\treturn\n\t\tprint(2)\n\tprint(x)\n")
	_valid(sf)


func test_insert_replaces_lone_pass() -> void:
	var src := "func f(x):\n\tif x:\n\t\tpass # todo\n"
	var sf := temp_script(src)
	run_op(sf, "f", func(g): return GraphEdits.insert_at_body_start(sf.doc, g, "0|then", "go()"))
	check_eq(_src_of(sf), "func f(x):\n\tif x:\n\t\tgo() # todo\n")
	_valid(sf)


func test_move_down_within_body() -> void:
	var sf := temp_script(SRC)
	run_op(sf, "run", func(g): return GraphEdits.move_after(sf.doc, g, g.get_stmt("0"), g.get_stmt("1")))
	check_eq(_src_of(sf), SRC.replace("\tvar hp := 10 # health\n\tenemy.queue_free()\n", "\tenemy.queue_free()\n\tvar hp := 10 # health\n"))
	_valid(sf)


func test_move_up_within_body() -> void:
	var sf := temp_script(SRC)
	run_op(sf, "run", func(g): return GraphEdits.move_to_body_start(sf.doc, g, g.get_stmt("1"), "entry|next"))
	check_eq(_src_of(sf), SRC.replace("\tvar hp := 10 # health\n\tenemy.queue_free()\n", "\tenemy.queue_free()\n\tvar hp := 10 # health\n"))
	_valid(sf)


func test_move_into_nested_body_reindents() -> void:
	var sf := temp_script(SRC)
	run_op(sf, "run", func(g): return GraphEdits.move_to_body_start(sf.doc, g, g.get_stmt("1"), "2|else"))
	var want := SRC.replace("\tenemy.queue_free()\n", "").replace("\telse:\n", "\telse:\n\t\tenemy.queue_free()\n")
	check_eq(_src_of(sf), want)
	_valid(sf)


func test_move_last_of_body_out_after_owner() -> void:
	var sf := temp_script(SRC)
	run_op(sf, "run", func(g): return GraphEdits.move_after(sf.doc, g, g.get_stmt("2.else.0"), g.get_stmt("2")))
	check_eq(_src_of(sf), SRC.replace("\telse:\n\t\tprint(\"low\")\n", "\telse:\n\t\tpass\n\tprint(\"low\")\n"))
	_valid(sf)


func test_move_compound_with_body() -> void:
	var sf := temp_script(SRC)
	run_op(sf, "run", func(g): return GraphEdits.move_after(sf.doc, g, g.get_stmt("2"), g.get_stmt("3")))
	var block := "\tif hp > 5:\n\t\tprint(\"high\")\n\t\tprint(\"still high\")\n\telse:\n\t\tprint(\"low\")\n"
	var want := SRC.replace(block, "").replace("\tprint(\"done\")\n", "\tprint(\"done\")\n" + block)
	check_eq(_src_of(sf), want)
	_valid(sf)


func test_move_into_itself_rejected() -> void:
	var sf := temp_script(SRC)
	check(not run_op(sf, "run", func(g): return GraphEdits.move_to_body_start(sf.doc, g, g.get_stmt("2"), "2|then")), "rejected")
	check_eq(_src_of(sf), SRC)


func test_semicolon_statements() -> void:
	var src := "func f():\n\tvar q = 1; print(q)\n\tdone()\n"
	var sf := temp_script(src)
	run_op(sf, "f", func(g): return GraphEdits.delete_statement(sf.doc, g, g.get_stmt("1")))
	check_eq(_src_of(sf), "func f():\n\tvar q = 1\n\tdone()\n")
	sf = temp_script(src)
	run_op(sf, "f", func(g): return GraphEdits.delete_statement(sf.doc, g, g.get_stmt("0")))
	check_eq(_src_of(sf), "func f():\n\tprint(q)\n\tdone()\n")
	_valid(sf)


func test_raw_edit_of_code_block_reindents() -> void:
	var src := "func f(x):\n\tif x:\n\t\tmatch x:\n\t\t\t1: pass\n"
	var sf := temp_script(src)
	var g := FunctionGraph.build(sf, sf.find_function("f"))
	var s := g.get_stmt("0.then.0")
	check_eq(s.kind, "code")
	check_eq(GraphEdits.statement_text(sf.doc, s), "match x:\n\t1: pass")
	sf.apply_edits(GraphEdits.replace_statement(sf.doc, s, "match x:\n\t1: pass\n\t2: go()").edits, false)
	check_eq(_src_of(sf), "func f(x):\n\tif x:\n\t\tmatch x:\n\t\t\t1: pass\n\t\t\t2: go()\n")
	_valid(sf)


func test_crlf_file_stays_crlf() -> void:
	var src := "func f():\r\n\ta()\r\n\tb()\r\n"
	var sf := temp_script(src)
	run_op(sf, "f", func(g): return GraphEdits.insert_after(sf.doc, g, g.get_stmt("0"), "c()"))
	check_eq(_src_of(sf), "func f():\r\n\ta()\r\n\tc()\r\n\tb()\r\n")
	sf = temp_script(src)
	run_op(sf, "f", func(g): return GraphEdits.move_after(sf.doc, g, g.get_stmt("0"), g.get_stmt("1")))
	check_eq(_src_of(sf), "func f():\r\n\tb()\r\n\ta()\r\n")


func test_spaces_indentation() -> void:
	var src := "func f(x):\n    if x: return\n    b()\n"
	var sf := temp_script(src)
	run_op(sf, "f", func(g): return GraphEdits.insert_at_body_start(sf.doc, g, "0|then", "a()"))
	check_eq(_src_of(sf), "func f(x):\n    if x:\n        a()\n        return\n    b()\n")
	_valid(sf)


func test_undo_restores_bytes() -> void:
	var sf := temp_script(SRC)
	sf.begin_group()
	run_op(sf, "run", func(g): return GraphEdits.insert_after(sf.doc, g, g.get_stmt("2.then.0"), "x()"))
	run_op(sf, "run", func(g): return GraphEdits.delete_statement(sf.doc, g, g.get_stmt("1")))
	sf.end_group()
	check(sf.undo(), "undo")
	check_eq(_src_of(sf), SRC, "one undo step for the group")
