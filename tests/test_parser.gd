extends TestCase
## Milestone 1: GDExtension parse + apply_edit round trips.

const SAMPLE := """extends Node
## Doc comment
# plain comment   with   odd spacing

var speed := 5.0 # trailing

func _ready() -> void:
	var x: int = 1 + 2
	print(x)  # keep me
	if x > 2:
		print("big")


func other(a, b):
	return a + b
"""


func test_parse_basic() -> void:
	var d := parse(SAMPLE)
	check(not d.has_errors(), "sample should parse cleanly")
	var root := d.get_tree()
	check_eq(root.type, "source")
	check_eq(root.start, 0)
	check_eq(root.end, d.get_byte_length())
	var funcs := Cst.all_of_type(root, "function_definition")
	check_eq(funcs.size(), 2, "two functions")
	check_eq(d.get_text(Cst.field(funcs[0], "name").start, Cst.field(funcs[0], "name").end), "_ready")


func test_tree_byte_ranges_cover_text() -> void:
	# Every leaf's text is exactly the source slice: concatenating leaves and
	# the gaps between them rebuilds the file.
	var d := parse(SAMPLE)
	var rebuilt := [""]
	var pos := [0]
	Cst.walk(d.get_tree(true), func(n):
		if n.children.is_empty():
			rebuilt[0] += d.get_text(pos[0], n.start) + d.get_text(n.start, n.end)
			pos[0] = n.end
	)
	rebuilt[0] += d.get_text(pos[0], d.get_byte_length())
	check_eq(rebuilt[0], SAMPLE)


func test_edit_leaves_untouched_bytes_identical() -> void:
	var d := parse(SAMPLE)
	var before := d.get_source_bytes()
	var s := byte_of(d, "1 + 2")
	check(d.apply_edit(s, s + 5, "compute(1, 2) * 3"), "edit applies")
	var after := d.get_source_bytes()
	check_eq(after.slice(0, s), before.slice(0, s), "prefix untouched")
	var new_len := "compute(1, 2) * 3".length()
	check_eq(after.slice(s + new_len), before.slice(s + 5), "suffix untouched")
	check(d.verify_incremental(), "incremental tree == fresh parse")
	check(not d.has_errors(), "still valid")


func test_edit_and_reverse_restores_original() -> void:
	var d := parse(SAMPLE)
	var before := d.get_source_bytes()
	var sexp := d.get_sexp()
	var s := byte_of(d, "print(x)")
	d.apply_edit(s, s + 8, "do_something_else(x, \"ünïcödé ✓\")")
	check(d.verify_incremental(), "incremental after edit")
	var new_end := s + "do_something_else(x, \"ünïcödé ✓\")".to_utf8_buffer().size()
	d.apply_edit(s, new_end, "print(x)")
	check_eq(d.get_source_bytes(), before, "bytes restored")
	check_eq(d.get_sexp(), sexp, "tree restored")
	check(d.verify_incremental(), "incremental after reverse")


func test_multi_edit_atomic_any_order() -> void:
	var d := parse(SAMPLE)
	var a := byte_of(d, "speed")
	var b := byte_of(d, "a + b")
	# Given front-to-back; offsets refer to the original buffer.
	check(d.apply_edits([
		{ start = a, end = a + 5, text = "velocity" },
		{ start = b, end = b + 5, text = "a - b" },
	]), "edits apply")
	var src := d.get_source()
	check(src.contains("var velocity := 5.0 # trailing"), "first edit")
	check(src.contains("return a - b"), "second edit")
	check(d.verify_incremental(), "incremental")


func test_overlapping_edits_rejected() -> void:
	var d := parse(SAMPLE)
	var before := d.get_source_bytes()
	var v := d.get_version()
	var ok := d.apply_edits([
		{ start = 10, end = 20, text = "x" },
		{ start = 15, end = 25, text = "y" },
	])
	check(not ok, "overlap must fail")
	check_eq(d.get_source_bytes(), before, "buffer unchanged after failed edit")
	check_eq(d.get_version(), v, "version unchanged")


func test_insertion_and_deletion() -> void:
	var d := parse(SAMPLE)
	var s := byte_of(d, "\tprint(x)")
	d.apply_edit(s, s, "\tvar y := x * 2\n")
	check(d.get_source().contains("\tvar y := x * 2\n\tprint(x)  # keep me"), "inserted line")
	check(d.verify_incremental(), "incremental after insert")
	var t := byte_of(d, "\tvar y := x * 2\n")
	d.apply_edit(t, t + "\tvar y := x * 2\n".length(), "")
	check_eq(d.get_source(), SAMPLE, "deleted again")
	check(d.verify_incremental(), "incremental after delete")


func test_changed_ranges_reported() -> void:
	var d := parse(SAMPLE)
	var s := byte_of(d, "\"big\"")
	d.apply_edit(s, s + 5, "\"bigger\"")
	var ranges := d.get_changed_ranges()
	# A same-shape edit may report no structural change; when it reports one
	# it has to be where the edit happened.
	for r in ranges:
		check(r.start <= s + 8 and r.end >= s, "changed range %s should cover the edit at %d" % [r, s])


func test_unicode_byte_offsets() -> void:
	var src := "func f():\n\tprint(\"héllo 🌍\")\n\tvar u := \"ü\"\n"
	var d := parse(src)
	check(not d.has_errors(), "parses")
	var s := byte_of(d, "var u")
	check_eq(d.get_text(s, s + "var u".to_utf8_buffer().size()), "var u")
	check_eq(d.byte_to_char(s), src.find("var u"), "byte -> char")
	check_eq(d.char_to_byte(src.find("var u")), s, "char -> byte")
	# A range that splits a multi-byte char is snapped to char boundaries.
	var e := byte_of(d, "🌍")
	check_eq(d.get_text(e, e + 2), "", "partial char snaps to empty")
	var q := byte_of(d, "ü")
	d.apply_edit(q, q + "ü".to_utf8_buffer().size(), "ö")
	check(d.get_source().contains("var u := \"ö\""), "edit after multibyte text")
	check(d.verify_incremental(), "incremental")


func test_file_roundtrip_byte_identical() -> void:
	# CRLF, BOM, tabs, trailing spaces and no final newline must all survive.
	var bytes := PackedByteArray([0xEF, 0xBB, 0xBF])
	bytes.append_array("extends Node\r\n\r\nfunc f():   \r\n\tpass\t# c\r\n\treturn".to_utf8_buffer())
	var dir := OS.get_user_data_dir().path_join("test_tmp")
	DirAccess.make_dir_recursive_absolute(dir)
	var p := dir.path_join("roundtrip.gd")
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	var d := GDSyntaxDocument.new()
	check_eq(d.load_file(p), OK, "load")
	check_eq(d.get_source_bytes(), bytes, "loaded bytes")
	check_eq(d.save_file(), OK, "save")
	check_eq(FileAccess.get_file_as_bytes(p), bytes, "saved bytes identical")
	# Edit in the middle of a CRLF file keeps every other byte.
	var s := byte_of(d, "pass")
	d.apply_edit(s, s + 4, "print(1)")
	d.save_file()
	var out := FileAccess.get_file_as_bytes(p)
	check_eq(out.slice(0, s), bytes.slice(0, s), "prefix")
	check_eq(out.slice(s + 8), bytes.slice(s + 4), "suffix")


func test_line_helpers() -> void:
	var d := parse(SAMPLE)
	var s := byte_of(d, "print(\"big\")")
	check_eq(d.line_indent(s), "\t\t")
	check_eq(d.get_text(d.line_start(s), d.line_end(s)), "\t\tprint(\"big\")")
	check_eq(d.row_of(s), SAMPLE.substr(0, SAMPLE.find("print(\"big\")")).count("\n"))


func test_error_recovery_still_editable() -> void:
	var d := parse("func f():\n\tvar x = (1 +\n\tprint(x)\n\nfunc g():\n\tpass\n")
	check(d.has_errors(), "broken code reports errors")
	check(d.get_errors().size() > 0, "error ranges")
	var s := byte_of(d, "(1 +")
	d.apply_edit(s, s + 4, "(1 + 2)")
	check(not d.has_errors(), "fixed by edit")
	check(d.verify_incremental(), "incremental")


func test_comments_are_extras() -> void:
	var d := parse(SAMPLE)
	var comments := []
	Cst.walk(d.get_tree(false), func(n):
		if n.type == "comment":
			comments.append(n)
	)
	check_eq(comments.size(), 4, "all comments visible in the tree")
	for c in comments:
		check(c.get("extra", false), "comment is an extra")
