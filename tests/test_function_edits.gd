extends TestCase
## Function-level operations: create / delete / rename functions, add and
## remove inputs (parameters), change the output (return type).

const SRC := """extends Node

## Moves the thing.
func move(speed: float, dir := Vector3.UP) -> void:
	position += dir * speed


func reset():
	pass

class Inner:
	func a():
		pass
"""


func _apply(sf: ScriptFile, r: Dictionary) -> bool:
	if not check(not r.is_empty(), "op possible"):
		return false
	return check(sf.apply_edits(r.edits, false), "edits apply")


func _graph(sf: ScriptFile, qual: String) -> FunctionGraph:
	return FunctionGraph.build(sf, sf.find_function(qual))


func _valid(sf: ScriptFile) -> void:
	check(not sf.doc.has_errors(), "result parses cleanly:\n" + sf.doc.get_source())
	check(sf.doc.verify_incremental(), "incremental == fresh")


func test_parse_signature() -> void:
	check_eq(GraphEdits.parse_signature("jump"), { name = "jump", header = "func jump()", ret = "" })
	check_eq(GraphEdits.parse_signature("func hit(a: int) -> bool:"), { name = "hit", header = "func hit(a: int) -> bool", ret = "bool" })
	check_eq(GraphEdits.parse_signature("static make() -> Node").header, "static func make() -> Node")
	check_eq(GraphEdits.parse_signature("cb(f: Callable) -> Array[int]").ret, "Array[int]")
	check(GraphEdits.parse_signature("2bad()").is_empty(), "invalid name rejected")
	check(GraphEdits.parse_signature("").is_empty(), "empty rejected")


func test_create_after_function() -> void:
	var sf := temp_script(SRC)
	_apply(sf, GraphEdits.create_function(sf.doc, sf, sf.find_function("move").node, {}, "jump(height: float) -> bool"))
	check_eq(sf.doc.get_source(), SRC.replace("\tposition += dir * speed\n", "\tposition += dir * speed\n\n\nfunc jump(height: float) -> bool:\n\treturn false\n"))
	_valid(sf)
	check(not sf.find_function("jump").is_empty(), "new function found")


func test_create_at_end_of_file() -> void:
	var src := "extends Node\n\nfunc a():\n\tpass\n"
	var sf := temp_script(src)
	_apply(sf, GraphEdits.create_function(sf.doc, sf, {}, sf.named_tree(), "b"))
	check_eq(sf.doc.get_source(), src + "\n\nfunc b():\n\tpass\n")
	_valid(sf)


func test_create_in_inner_class_uses_one_blank_line() -> void:
	var sf := temp_script(SRC)
	_apply(sf, GraphEdits.create_function(sf.doc, sf, sf.find_function("Inner.a").node, {}, "b() -> int"))
	check_eq(sf.doc.get_source(), SRC + "\n\tfunc b() -> int:\n\t\treturn 0\n")
	_valid(sf)
	check(not sf.find_function("Inner.b").is_empty(), "inner function found")


func test_create_with_spaces_and_crlf() -> void:
	var src := "func a():\r\n    pass\r\n"
	var sf := temp_script(src)
	_apply(sf, GraphEdits.create_function(sf.doc, sf, sf.find_function("a").node, {}, "b"))
	check_eq(sf.doc.get_source(), "func a():\r\n    pass\r\n\r\n\r\nfunc b():\r\n    pass\r\n")
	_valid(sf)


func test_delete_function_with_doc_comment() -> void:
	var sf := temp_script(SRC)
	_apply(sf, GraphEdits.delete_function(sf.doc, sf.find_function("move").node))
	check_eq(sf.doc.get_source(), "extends Node\n\n\nfunc reset():\n\tpass\n\nclass Inner:\n\tfunc a():\n\t\tpass\n")
	_valid(sf)


func test_delete_then_create_roundtrip_is_clean() -> void:
	var sf := temp_script(SRC)
	_apply(sf, GraphEdits.create_function(sf.doc, sf, sf.find_function("reset").node, {}, "temp"))
	_apply(sf, GraphEdits.delete_function(sf.doc, sf.find_function("temp").node))
	check_eq(sf.doc.get_source(), SRC)


func test_rename_via_name_field() -> void:
	var sf := temp_script(SRC)
	var g := _graph(sf, "reset")
	var e := g.get_stmt("entry")
	_apply(sf, GraphEdits.set_field(sf.doc, e, e.get_field("name"), "restart"))
	check(sf.doc.get_source().contains("func restart():"), "renamed")
	_valid(sf)


func test_set_signature() -> void:
	var sf := temp_script(SRC)
	_apply(sf, GraphEdits.set_signature(sf.doc, _graph(sf, "move"), "walk(speed: int) -> bool"))
	check(sf.doc.get_source().contains("## Moves the thing.\nfunc walk(speed: int) -> bool:\n\tposition"), "signature replaced, comment kept")
	_valid(sf)


func test_add_param() -> void:
	var sf := temp_script(SRC)
	_apply(sf, GraphEdits.add_param(sf.doc, _graph(sf, "reset"), "hard: bool"))
	check(sf.doc.get_source().contains("func reset(hard: bool):"), "first param")
	_apply(sf, GraphEdits.add_param(sf.doc, _graph(sf, "reset"), "delay := 0.5"))
	check(sf.doc.get_source().contains("func reset(hard: bool, delay := 0.5):"), "appended")
	# A required param goes before the first defaulted one.
	_apply(sf, GraphEdits.add_param(sf.doc, _graph(sf, "move"), "target: Node3D"))
	check(sf.doc.get_source().contains("func move(speed: float, target: Node3D, dir := Vector3.UP) -> void:"), "required before defaults")
	_valid(sf)
	check(GraphEdits.add_param(sf.doc, _graph(sf, "move"), "speed: int").is_empty(), "duplicate name rejected")
	check(GraphEdits.add_param(sf.doc, _graph(sf, "move"), "1x").is_empty(), "bad name rejected")


func test_add_param_shows_as_input_pin() -> void:
	var sf := temp_script(SRC)
	_apply(sf, GraphEdits.add_param(sf.doc, _graph(sf, "reset"), "hard: bool"))
	var e := _graph(sf, "reset").get_stmt("entry")
	check(e.get_data_out("param:hard") != null, "new data pin")
	check_eq(e.get_data_out("param:hard").type, "bool")
	check_eq(e.get_field("param0").text, "hard: bool")


func test_remove_param() -> void:
	var sf := temp_script(SRC)
	_apply(sf, GraphEdits.remove_param(sf.doc, _graph(sf, "move"), 0))
	check(sf.doc.get_source().contains("func move(dir := Vector3.UP) -> void:"), "first removed")
	_apply(sf, GraphEdits.remove_param(sf.doc, _graph(sf, "move"), 0))
	check(sf.doc.get_source().contains("func move() -> void:"), "last removed")
	_valid(sf)
	sf = temp_script(SRC)
	_apply(sf, GraphEdits.remove_param(sf.doc, _graph(sf, "move"), 1))
	check(sf.doc.get_source().contains("func move(speed: float) -> void:"), "trailing removed")
	check(GraphEdits.remove_param(sf.doc, _graph(sf, "reset"), 0).is_empty(), "nothing to remove")


func test_change_return_type() -> void:
	var sf := temp_script(SRC)
	var e := _graph(sf, "reset").get_stmt("entry")
	_apply(sf, GraphEdits.set_field(sf.doc, e, e.get_field("ret"), "int"))
	check(sf.doc.get_source().contains("func reset() -> int:"), "added")
	e = _graph(sf, "reset").get_stmt("entry")
	_apply(sf, GraphEdits.set_field(sf.doc, e, e.get_field("ret"), "String"))
	check(sf.doc.get_source().contains("func reset() -> String:"), "changed")
	e = _graph(sf, "reset").get_stmt("entry")
	_apply(sf, GraphEdits.set_field(sf.doc, e, e.get_field("ret"), ""))
	check(sf.doc.get_source().contains("func reset():"), "cleared")
	_valid(sf)


func test_default_body() -> void:
	check_eq(GraphEdits.default_body("void"), "pass")
	check_eq(GraphEdits.default_body("Vector3"), "return Vector3()")
	check_eq(GraphEdits.default_body("Array[Node]"), "return []")
	check_eq(GraphEdits.default_body("Player"), "return null")
