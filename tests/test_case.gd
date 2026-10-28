class_name TestCase
extends RefCounted
## Minimal test base: every method named test_* is run by tests/run_tests.gd.

var failures: Array[String] = []
var current := ""


func check(cond: bool, msg: String) -> bool:
	if not cond:
		failures.append("%s: %s" % [current, msg])
	return cond


func check_eq(got: Variant, want: Variant, msg := "") -> bool:
	if typeof(got) == typeof(want) and got == want:
		return true
	failures.append("%s: %s\n      got:  %s\n      want: %s" % [current, msg, _show(got), _show(want)])
	return false


func _show(v: Variant) -> String:
	if v is String:
		return (v as String).c_escape()
	return str(v)


## Parses `src` and returns a document.
func parse(src: String) -> GDSyntaxDocument:
	var d := GDSyntaxDocument.new()
	d.set_source(src)
	return d


## Byte offset of the n-th occurrence (0-based) of `needle` in the doc.
func byte_of(d: GDSyntaxDocument, needle: String, nth := 0) -> int:
	var bytes := d.get_source_bytes()
	var nb := needle.to_utf8_buffer()
	var found := -1
	for i in bytes.size() - nb.size() + 1:
		if bytes.slice(i, i + nb.size()) == nb:
			found += 1
			if found == nth:
				return i
	return -1


## Writes `src` to a temp file and opens it as a ScriptFile.
func temp_script(src: String, name := "t.gd") -> ScriptFile:
	var dir := OS.get_user_data_dir().path_join("test_tmp")
	DirAccess.make_dir_recursive_absolute(dir)
	var p := dir.path_join(name)
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_buffer(src.to_utf8_buffer())
	f.close()
	return ScriptFile.open(p, dir)
