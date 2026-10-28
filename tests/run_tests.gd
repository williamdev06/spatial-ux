extends SceneTree
## Headless test runner.
##
##   godot --headless --path . --script res://tests/run_tests.gd
##   godot --headless --path . --script res://tests/run_tests.gd -- --corpus=C:/path/to/godot/projects
##
## --corpus points the corpus round-trip test at a folder of real .gd files.
## --only=<file stem> runs a single test file.

const TEST_FILES := [
	"res://tests/test_parser.gd",
	"res://tests/test_function_graph.gd",
	"res://tests/test_graph_edits.gd",
	"res://tests/test_layout.gd",
	"res://tests/test_index.gd",
	"res://tests/test_corpus.gd",
]


func _initialize() -> void:
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.trim_prefix("--only=")
	var total := 0
	var failed := 0
	var t0 := Time.get_ticks_msec()
	for path in TEST_FILES:
		if not only.is_empty() and not path.get_file().get_basename().contains(only):
			continue
		if not ResourceLoader.exists(path):
			continue
		var script: GDScript = load(path)
		if script == null:
			print("LOAD FAIL ", path)
			failed += 1
			continue
		var tc: TestCase = script.new()
		for m in tc.get_method_list():
			var mname: String = m.name
			if not mname.begins_with("test_"):
				continue
			total += 1
			tc.current = "%s::%s" % [path.get_file().get_basename(), mname]
			var before := tc.failures.size()
			tc.call(mname)
			var ok := tc.failures.size() == before
			if not ok:
				failed += 1
			print("%s %s" % ["  ok  " if ok else " FAIL ", tc.current])
		for f in tc.failures:
			print("    - ", f)
	print("\n%d tests, %d failed (%d ms)" % [total, failed, Time.get_ticks_msec() - t0])
	quit(1 if failed > 0 else 0)
