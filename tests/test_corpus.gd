extends TestCase
## Round-trip tests over real GDScript files.
##
## Uses --corpus=<dir> if given, else this project's own scripts plus the
## Godot demo projects if they are in Downloads. For every file:
##   * loading and saving is byte-identical
##   * random token edits keep every other byte, the incremental tree equals a
##     fresh parse, and undoing the edit restores the original bytes and tree
##   * graph operations (set field, delete, insert, move) only change the lines
##     they are about, and never introduce parse errors

const DEFAULT_CORPORA := [
	"res://app",
	"res://tests",
	"~/Downloads/godot-demo-projects-master",
]
const MAX_FILES := 2000
const TOKEN_EDITS_PER_FILE := 6
const GRAPH_OPS_PER_FILE := 6

var rng := RandomNumberGenerator.new()
var _files: Array[String] = []
var _stats := { files = 0, with_errors = 0, token_edits = 0, graph_ops = 0, functions = 0, stmts = 0 }


func _init() -> void:
	rng.seed = 1234
	var roots: Array = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--corpus="):
			roots.append(a.trim_prefix("--corpus="))
	if roots.is_empty():
		roots = DEFAULT_CORPORA
	for r in roots:
		var dir: String = ProjectSettings.globalize_path(r) if r.begins_with("res://") else r
		if dir.begins_with("~"):
			var home := OS.get_environment("USERPROFILE") if OS.has_environment("USERPROFILE") else OS.get_environment("HOME")
			dir = home.replace("\\", "/") + dir.substr(1)
		if DirAccess.dir_exists_absolute(dir):
			_collect(dir)
	_files.sort()
	if _files.size() > MAX_FILES:
		_files.resize(MAX_FILES)


func _collect(dir: String) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for f in da.get_files():
		if f.get_extension() == "gd":
			_files.append(dir.path_join(f))
	for d in da.get_directories():
		if d.begins_with(".") or d == "thirdparty":
			continue
		_collect(dir.path_join(d))


func test_corpus_roundtrip() -> void:
	check(_files.size() > 0, "corpus has files")
	for p in _files:
		_stats.files += 1
		var bytes := FileAccess.get_file_as_bytes(p)
		var d := GDSyntaxDocument.new()
		if not check_eq(d.load_file(p), OK, "load " + p):
			continue
		check(d.get_source_bytes() == bytes, "load is byte-identical: " + p)
		if d.has_errors():
			_stats.with_errors += 1
		_token_edits(d, p)
	print("    corpus: %d files, %d with grammar errors, %d token edits" % [_stats.files, _stats.with_errors, _stats.token_edits])


func test_corpus_graph_ops() -> void:
	var clean := 0
	for p in _files:
		var d := GDSyntaxDocument.new()
		d.load_file(p)
		if d.has_errors():
			continue
		clean += 1
		_graph_ops(p, d.get_source_bytes())
	print("    graph ops: %d clean files, %d functions, %d statements, %d ops" % [clean, _stats.functions, _stats.stmts, _stats.graph_ops])


func _token_edits(d: GDSyntaxDocument, p: String) -> void:
	var original := d.get_source_bytes()
	var sexp := d.get_sexp()
	var leaves := []
	Cst.walk(d.get_tree(false), func(n):
		if n.type == "identifier":
			leaves.append(n)
	)
	if leaves.is_empty():
		return
	for i in TOKEN_EDITS_PER_FILE:
		var n: Dictionary = leaves[rng.randi() % leaves.size()]
		var old_text := d.get_text(n.start, n.end)
		var new_text := "r%d_ü%s" % [rng.randi() % 1000, "x".repeat(rng.randi() % 5)]
		var before := d.get_source_bytes()
		d.apply_edit(n.start, n.end, new_text)
		_stats.token_edits += 1
		var after := d.get_source_bytes()
		var new_end: int = n.start + new_text.to_utf8_buffer().size()
		if not check(after.slice(0, n.start) == before.slice(0, n.start) and after.slice(new_end) == before.slice(n.end), "untouched bytes changed in %s" % p):
			return
		if not check(d.verify_incremental(), "incremental mismatch after edit in %s at %d" % [p, n.start]):
			return
		d.apply_edit(n.start, new_end, old_text)
		if not check(d.get_source_bytes() == before, "reverse edit in " + p):
			return
	check(d.get_source_bytes() == original, "restored " + p)
	check_eq(d.get_sexp(), sexp, "tree restored " + p)


func _fresh(p: String, bytes: PackedByteArray) -> ScriptFile:
	var sf := ScriptFile.new()
	sf.path = p
	sf.doc.set_source_bytes(bytes)
	return sf


func _graph_ops(p: String, bytes: PackedByteArray) -> void:
	var probe := _fresh(p, bytes)
	var funcs := probe.functions()
	if funcs.is_empty():
		return
	for f in funcs:
		var g := FunctionGraph.build(probe, f)
		_stats.functions += 1
		_stats.stmts += g.stmts.size() - 1
	for i in GRAPH_OPS_PER_FILE:
		var f: Dictionary = funcs[rng.randi() % funcs.size()]
		var sf := _fresh(p, bytes)
		var g := FunctionGraph.build(sf, sf.find_function(f.qualname))
		if g.stmts.size() < 2:
			continue
		var s: FunctionGraph.Stmt = g.stmts[1 + rng.randi() % (g.stmts.size() - 1)]
		var other: FunctionGraph.Stmt = g.stmts[rng.randi() % g.stmts.size()]
		var op := rng.randi() % 4
		var desc: String = ["set_field", "delete", "insert_after", "move_after"][op]
		var before := sf.doc.get_source()
		var lo: int = sf.doc.row_of(s.start)
		var hi: int = sf.doc.row_of(s.end)
		var pure_insert := false
		var result: Dictionary
		match op:
			0:
				var fs := s.fields.filter(func(x): return not x.multiline)
				if fs.is_empty():
					continue
				var fld: FunctionGraph.Field = fs[rng.randi() % fs.size()]
				result = GraphEdits.set_field(sf.doc, s, fld, "probe_value")
			1:
				result = GraphEdits.delete_statement(sf.doc, g, s)
			2:
				pure_insert = true
				result = _run(sf, f.qualname, func(gg): return GraphEdits.insert_after(sf.doc, gg, gg.get_stmt(s.key), "probe_call(1)"))
			3:
				if other.kind != "entry":
					lo = mini(lo, sf.doc.row_of(other.start))
					hi = maxi(hi, sf.doc.row_of(other.end) + 1)
				else:
					lo = mini(lo, sf.doc.row_of(other.start))
				result = _run(sf, f.qualname, func(gg):
					var ss = gg.get_stmt(s.key)
					var tt = gg.get_stmt(other.key)
					if ss == null or tt == null:
						return {}
					return GraphEdits.move_after(sf.doc, gg, ss, tt))
		if result.is_empty():
			continue # Operation not applicable (e.g. move into itself).
		if op < 2:
			if not check(sf.apply_edits(result.edits, false), "%s applies in %s" % [desc, p]):
				continue
		_stats.graph_ops += 1
		var where := "%s on %s:%s [%s] in %s" % [desc, f.qualname, s.key, s.kind, p]
		if not check(not sf.doc.has_errors(), "%s introduced parse errors:\n%s" % [where, _diff(before, sf.doc.get_source())]):
			continue
		check(sf.doc.verify_incremental(), "incremental mismatch after " + where)
		_check_diff_region(before, sf.doc.get_source(), lo, hi, pure_insert, where)


## Applies a GraphEdits op with the normalize-and-retry protocol; returns the
## last result, or {} if the op was not possible.
func _run(sf: ScriptFile, qualname: String, op: Callable) -> Dictionary:
	var last := {}
	for attempt in 4:
		var g := FunctionGraph.build(sf, sf.find_function(qualname))
		var r: Dictionary = op.call(g)
		if r.is_empty():
			return last if attempt > 0 else {}
		if not sf.apply_edits(r.edits, false):
			return {}
		last = r
		if not r.get("retry", false):
			return r
	return last


## Lines outside the rows an operation is about must be untouched.
func _check_diff_region(before: String, after: String, lo: int, hi: int, pure_insert: bool, where: String) -> void:
	var a := before.split("\n")
	var b := after.split("\n")
	var pre := 0
	while pre < a.size() and pre < b.size() and a[pre] == b[pre]:
		pre += 1
	var suf := 0
	while suf < a.size() - pre and suf < b.size() - pre and a[a.size() - 1 - suf] == b[b.size() - 1 - suf]:
		suf += 1
	var changed_lo := pre
	var changed_hi := a.size() - 1 - suf # inclusive, in `before`
	if changed_hi < changed_lo:
		return # pure insertion or no change
	if pure_insert:
		# Inserting may rewrite an inline body (`if x: a` -> block form) but
		# nothing outside the statement's own lines.
		check(changed_lo >= lo and changed_hi <= hi, "insert changed lines %d-%d outside %d-%d: %s\n%s" % [changed_lo, changed_hi, lo, hi, where, _diff(before, after)])
		return
	check(changed_lo >= lo and changed_hi <= hi, "changed lines %d-%d outside %d-%d: %s\n%s" % [changed_lo, changed_hi, lo, hi, where, _diff(before, after)])


func _diff(a: String, b: String) -> String:
	var la := a.split("\n")
	var lb := b.split("\n")
	var pre := 0
	while pre < la.size() and pre < lb.size() and la[pre] == lb[pre]:
		pre += 1
	var out := "      @@ line %d\n" % (pre + 1)
	for i in range(pre, mini(pre + 8, la.size())):
		out += "      - " + la[i] + "\n"
	for i in range(pre, mini(pre + 8, lb.size())):
		out += "      + " + lb[i] + "\n"
	return out
