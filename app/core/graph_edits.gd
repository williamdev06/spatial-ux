class_name GraphEdits
## Compiles graph operations into byte-range text edits ({start, end, text}).
##
## Each function returns a result Dictionary:
##   {edits = [...]}                 apply and you're done
##   {edits = [...], retry = true}   apply, rebuild the graph, call again
##                                   (used to first turn an inline body like
##                                   `if x: return` into block form)
##   {}                              operation not possible
##
## Edits only ever touch the lines being changed; everything else, comments
## included, stays byte-identical.


static func _ok(edits: Array) -> Dictionary:
	return { edits = edits }


static func _retry(edits: Array) -> Dictionary:
	return { edits = edits, retry = true }


# --- fields ------------------------------------------------------------------

static func set_field(doc: GDSyntaxDocument, s: FunctionGraph.Stmt, f: FunctionGraph.Field, new_text: String) -> Dictionary:
	if f.multiline and s.kind == "code":
		return replace_statement(doc, s, new_text)
	var t := new_text
	if not f.multiline:
		t = t.replace("\r", "").replace("\n", " ")
	if t.strip_edges().is_empty() and f.opt_start >= 0:
		return _ok([{ start = f.opt_start, end = f.end, text = "" }])
	if f.start == f.end:
		if t.strip_edges().is_empty():
			return _ok([])
		return _ok([{ start = f.start, end = f.end, text = f.prefix + t }])
	return _ok([{ start = f.start, end = f.end, text = t }])


## Replaces a whole statement with text written without its base indentation
## (as shown by statement_text()); continuation lines get re-indented.
static func replace_statement(doc: GDSyntaxDocument, s: FunctionGraph.Stmt, new_text: String) -> Dictionary:
	var indent := doc.line_indent(s.start)
	var t := reindent(new_text.strip_edges(false, true), "", indent)
	# The first line keeps whatever precedes the statement on its line.
	t = t.substr(indent.length()) if t.begins_with(indent) else t.lstrip(" \t")
	return _ok([{ start = s.start, end = s.end, text = t }])


## Statement source with its base indentation removed from continuation lines.
static func statement_text(doc: GDSyntaxDocument, s: FunctionGraph.Stmt) -> String:
	var indent := doc.line_indent(s.start)
	return reindent(doc.get_text(s.start, s.end), indent, "", true)


# --- statements --------------------------------------------------------------

static func delete_statement(doc: GDSyntaxDocument, g: FunctionGraph, s: FunctionGraph.Stmt) -> Dictionary:
	if s.kind == "entry":
		return {}
	var body := g.get_body(s.body_key)
	if body.stmt_keys.size() == 1:
		# Keep the body valid.
		return _ok([{ start = s.start, end = s.end, text = "pass" }])
	return _ok([_removal(doc, s)])


## Inserts `code` (unindented, may span lines) as a new statement after `after`.
static func insert_after(doc: GDSyntaxDocument, g: FunctionGraph, after: FunctionGraph.Stmt, code: String) -> Dictionary:
	if after.kind == "entry":
		return insert_at_body_start(doc, g, after.branch_bodies.get("next", ""), code)
	var norm := _normalize_for(doc, g, after)
	if not norm.is_empty():
		return _retry(norm)
	var indent := doc.line_indent(after.start)
	var at := _eol(doc, after.end)
	return _ok([{ start = at, end = at, text = _newline(doc) + reindent(code, "", indent) }])


## Inserts `code` as the first statement of a body (e.g. the `then` branch).
static func insert_at_body_start(doc: GDSyntaxDocument, g: FunctionGraph, body_key: String, code: String) -> Dictionary:
	var body := g.get_body(body_key)
	if body == null or body.stmt_keys.is_empty():
		return {}
	var first := g.get_stmt(body.stmt_keys[0])
	var norm := _normalize_for(doc, g, first)
	if not norm.is_empty():
		return _retry(norm)
	var indent := doc.line_indent(first.start)
	if body.stmt_keys.size() == 1 and first.kind == "pass":
		return _ok([{ start = first.start, end = first.end, text = reindent(code, "", indent).substr(indent.length()) }])
	var at := doc.line_start(first.start)
	return _ok([{ start = at, end = at, text = reindent(code, "", indent) + _newline(doc) }])


## Moves statement `s` (with its body) to just after `target`.
static func move_after(doc: GDSyntaxDocument, g: FunctionGraph, s: FunctionGraph.Stmt, target: FunctionGraph.Stmt) -> Dictionary:
	if target.kind == "entry":
		return move_to_body_start(doc, g, s, target.branch_bodies.get("next", ""))
	if s == target or s.kind == "entry" or _is_inside(target.key, s.key):
		return {}
	var body := g.get_body(s.body_key)
	var idx := body.stmt_keys.find(s.key)
	if target.body_key == s.body_key and idx > 0 and body.stmt_keys[idx - 1] == target.key:
		return _ok([]) # Already there.
	var norm := _normalize_for(doc, g, s)
	if norm.is_empty():
		norm = _normalize_for(doc, g, target)
	if not norm.is_empty():
		return _retry(norm)
	var moved := reindent(_lines_text(doc, s), doc.line_indent(s.start), doc.line_indent(target.start))
	var at := _eol(doc, target.end)
	var removal := _removal_or_pass(doc, g, s)
	if at >= removal.start and at <= removal.end:
		# `s` is the last line of `target` (e.g. moving the last statement of an
		# if-body out to just after the if): one edit does both.
		if removal.get("text", "") == "pass":
			return _ok([{ start = s.start, end = at, text = "pass" + doc.get_text(s.end, at) + _newline(doc) + moved }])
		return _ok([{ start = removal.start, end = _eol(doc, s.end), text = moved }])
	return _ok([removal, { start = at, end = at, text = _newline(doc) + moved }])


## Moves statement `s` to the start of the body `body_key`.
static func move_to_body_start(doc: GDSyntaxDocument, g: FunctionGraph, s: FunctionGraph.Stmt, body_key: String) -> Dictionary:
	var body := g.get_body(body_key)
	if body == null or body.stmt_keys.is_empty() or s.kind == "entry":
		return {}
	if _is_inside(body.owner_key, s.key) or body.owner_key == s.key:
		return {}
	var first := g.get_stmt(body.stmt_keys[0])
	if first == s:
		return _ok([])
	var norm := _normalize_for(doc, g, s)
	if norm.is_empty():
		norm = _normalize_for(doc, g, first)
	if not norm.is_empty():
		return _retry(norm)
	var moved := _lines_text(doc, s)
	var indent := doc.line_indent(first.start)
	var text := reindent(moved, doc.line_indent(s.start), indent)
	var edits := [_removal_or_pass(doc, g, s)]
	if body.stmt_keys.size() == 1 and first.kind == "pass":
		edits.append({ start = first.start, end = first.end, text = text.substr(indent.length()) })
	else:
		var at := doc.line_start(first.start)
		edits.append({ start = at, end = at, text = text + _newline(doc) })
	return _ok(edits)


# --- functions -----------------------------------------------------------------

## Parses what the user typed for a new function or a signature edit:
## "name", "name(a: int)", "func name(a) -> int", "static func name()".
## Returns {name, header, ret} or {} if it isn't a usable signature.
static func parse_signature(text: String) -> Dictionary:
	var t := text.strip_edges().trim_suffix(":").strip_edges()
	var is_static := t.begins_with("static ")
	if is_static:
		t = t.trim_prefix("static ").strip_edges()
	t = t.trim_prefix("func ").strip_edges()
	var ret := ""
	var arrow := t.rfind("->")
	if arrow >= 0 and arrow > t.rfind(")"):
		ret = t.substr(arrow + 2).strip_edges()
		t = t.substr(0, arrow).strip_edges()
	if not t.contains("("):
		t += "()"
	var name := t.substr(0, t.find("(")).strip_edges()
	if not name.is_valid_identifier() or not t.ends_with(")"):
		return {}
	var header := ("static func " if is_static else "func ") + name + t.substr(t.find("("))
	if not ret.is_empty():
		header += " -> " + ret
	return { name = name, header = header, ret = ret }


## A body that compiles for the given return type.
static func default_body(ret: String) -> String:
	match ret:
		"", "void", "Variant":
			return "pass"
		"int":
			return "return 0"
		"float":
			return "return 0.0"
		"bool":
			return "return false"
		"String", "StringName":
			return "return \"\""
		"Dictionary":
			return "return {}"
	if ret.begins_with("Array"):
		return "return []"
	if ret.begins_with("Vector") or ret in ["Color", "Rect2", "Rect2i", "Transform2D", "Transform3D", "Basis", "Quaternion", "AABB", "Plane"]:
		return "return %s()" % ret
	return "return null"


## Adds a new function after `after` (a function node), or at the end of
## `class_node` (the file's `source` or a `class_definition`) when `after` is
## empty. `signature` as accepted by parse_signature().
static func create_function(doc: GDSyntaxDocument, sf: ScriptFile, after: Dictionary, class_node: Dictionary, signature: String) -> Dictionary:
	var sig := parse_signature(signature)
	if sig.is_empty():
		return {}
	var nl := _newline(doc)
	var unit := sf.indent_unit()
	var indent := ""
	var at := 0
	if not after.is_empty():
		indent = doc.line_indent(after.start)
		at = _eol(doc, FunctionGraph.stmt_end(after))
	elif class_node.type == "source":
		at = doc.get_byte_length()
		var tail := doc.get_text(maxi(0, at - 2), at)
		var appended: String = ("" if tail.ends_with("\n") or at == 0 else nl) + nl + nl + sig.header + ":" + nl + unit + default_body(sig.ret) + nl
		return _ok([{ start = at, end = at, text = appended }])
	else:
		var body := Cst.field(class_node, "body")
		var members := Cst.named(body)
		if members.is_empty():
			return {}
		indent = doc.line_indent(members[0].start)
		at = _eol(doc, FunctionGraph.stmt_end(members[-1]))
	var blank := nl + nl if indent.is_empty() else nl
	var text: String = nl + blank + indent + sig.header + ":" + nl + indent + unit + default_body(sig.ret)
	return _ok([{ start = at, end = at, text = text }])


## Removes a function together with the comment lines directly above it and
## the blank lines that separated it from what came before.
static func delete_function(doc: GDSyntaxDocument, func_node: Dictionary) -> Dictionary:
	var start := doc.line_start(func_node.start)
	# Doc / plain comments attached directly above.
	while start > 0:
		var prev := doc.line_start(start - 1)
		if not doc.get_text(prev, start).strip_edges().begins_with("#"):
			break
		start = prev
	# Blank lines before: cut from the end of the previous non-blank line.
	var cut := start
	while cut > 0:
		var prev := doc.line_start(cut - 1)
		if not doc.get_text(prev, cut).strip_edges().is_empty():
			cut = _eol(doc, prev)
			break
		cut = prev
	var end := _eol(doc, FunctionGraph.stmt_end(func_node))
	if cut == 0:
		# First thing in the file: also take its line break.
		end = mini(doc.line_end(end) + 1, doc.get_byte_length())
	return _ok([{ start = cut, end = end, text = "" }])


## Replaces name, parameters and return type in one go ("name(a: int) -> T").
static func set_signature(doc: GDSyntaxDocument, g: FunctionGraph, signature: String) -> Dictionary:
	var sig := parse_signature(signature)
	if sig.is_empty():
		return {}
	var name_node := Cst.field(g.func_node, "name")
	var params := Cst.field(g.func_node, "parameters")
	var ret := Cst.field(g.func_node, "return_type")
	var end: int = ret.end if not ret.is_empty() else params.end
	var header: String = sig.header.substr(sig.header.find("func ") + 5)
	return _ok([{ start = name_node.start, end = end, text = header }])


## Adds a parameter ("name", "name: Type", "name := value", ...). Parameters
## without a default go before the first one that has a default, as GDScript
## requires.
static func add_param(doc: GDSyntaxDocument, g: FunctionGraph, param_text: String) -> Dictionary:
	var t := param_text.strip_edges()
	var pname := t.get_slice(":", 0).get_slice("=", 0).strip_edges()
	if not pname.is_valid_identifier():
		return {}
	for p in g.param_nodes:
		if doc.get_text(p.start, p.end).get_slice(":", 0).get_slice("=", 0).strip_edges() == pname:
			return {}
	var params := Cst.field(g.func_node, "parameters")
	if params.is_empty():
		return {}
	var nodes := g.param_nodes
	if nodes.is_empty():
		return _ok([{ start = params.start + 1, end = params.end - 1, text = t }])
	if not t.contains("="):
		for p in nodes:
			if p.type in ["default_parameter", "typed_default_parameter"]:
				return _ok([{ start = p.start, end = p.start, text = t + ", " }])
	var last: Dictionary = nodes[-1]
	return _ok([{ start = last.end, end = last.end, text = ", " + t }])


## Removes parameter `index` and its separating comma.
static func remove_param(doc: GDSyntaxDocument, g: FunctionGraph, index: int) -> Dictionary:
	var nodes := g.param_nodes
	if index < 0 or index >= nodes.size():
		return {}
	if nodes.size() == 1:
		var params := Cst.field(g.func_node, "parameters")
		return _ok([{ start = params.start + 1, end = params.end - 1, text = "" }])
	if index < nodes.size() - 1:
		return _ok([{ start = nodes[index].start, end = nodes[index + 1].start, text = "" }])
	return _ok([{ start = nodes[index - 1].end, end = nodes[index].end, text = "" }])


# --- helpers -----------------------------------------------------------------

static func _is_inside(key: String, ancestor_key: String) -> bool:
	return key.begins_with(ancestor_key + ".")


static func _newline(doc: GDSyntaxDocument) -> String:
	# Respect CRLF files.
	var probe := doc.line_end(0)
	if probe > 0 and probe < doc.get_byte_length() and doc.get_text(probe - 1, probe) == "\r":
		return "\r\n"
	return "\n"


## End of the line containing `b`, before its line break (CRLF aware).
static func _eol(doc: GDSyntaxDocument, b: int) -> int:
	var le := doc.line_end(b)
	if le > 0 and doc.get_text(le - 1, le) == "\r":
		return le - 1
	return le


static func _owns_line_start(doc: GDSyntaxDocument, s: FunctionGraph.Stmt) -> bool:
	return doc.get_text(doc.line_start(s.start), s.start).strip_edges().is_empty()


static func _owns_line_end(doc: GDSyntaxDocument, s: FunctionGraph.Stmt) -> bool:
	var rest := doc.get_text(s.end, doc.line_end(s.end)).strip_edges()
	return rest.is_empty() or rest.begins_with("#")


static func _owns_lines(doc: GDSyntaxDocument, s: FunctionGraph.Stmt) -> bool:
	return _owns_line_start(doc, s) and _owns_line_end(doc, s)


## Full lines of a statement (without the final newline).
static func _lines_text(doc: GDSyntaxDocument, s: FunctionGraph.Stmt) -> String:
	return doc.get_text(doc.line_start(s.start), doc.line_end(s.end)).trim_suffix("\r")


static func _removal_or_pass(doc: GDSyntaxDocument, g: FunctionGraph, s: FunctionGraph.Stmt) -> Dictionary:
	if g.get_body(s.body_key).stmt_keys.size() == 1:
		return { start = s.start, end = s.end, text = "pass" }
	return _removal(doc, s)


## Edit that removes a statement and whatever separates it from its neighbours.
static func _removal(doc: GDSyntaxDocument, s: FunctionGraph.Stmt) -> Dictionary:
	if _owns_lines(doc, s):
		var ls := doc.line_start(s.start)
		var le := doc.line_end(s.end)
		return { start = ls, end = mini(le + 1, doc.get_byte_length()) }
	# Shares its line with other statements (`a; b`) or sits after a ':'.
	var after := doc.get_text(s.end, doc.line_end(s.end))
	var semi_after := after.find(";")
	if semi_after >= 0 and after.substr(0, semi_after).strip_edges().is_empty():
		var j := semi_after + 1
		while j < after.length() and after[j] in [" ", "\t"]:
			j += 1
		return { start = s.start, end = s.end + after.substr(0, j).to_utf8_buffer().size(), text = "" }
	var before := doc.get_text(doc.line_start(s.start), s.start)
	var semi_before := before.rfind(";")
	if semi_before >= 0 and before.substr(semi_before + 1).strip_edges().is_empty():
		var cut := before.substr(semi_before).to_utf8_buffer().size()
		return { start = s.start - cut, end = s.end, text = "" }
	return { start = s.start, end = s.end, text = "" }


## If `s` sits in a body written on its header's line (`if x: return`), returns
## edits that rewrite that body in block form; otherwise [].
static func _normalize_for(doc: GDSyntaxDocument, g: FunctionGraph, s: FunctionGraph.Stmt) -> Array:
	if s.kind == "entry":
		return []
	var body := g.get_body(s.body_key)
	var stmts: Array = []
	for k in body.stmt_keys:
		stmts.append(g.get_stmt(k))
	var inline := false
	for st in stmts:
		if not _owns_line_start(doc, st):
			inline = true
	# `a; b` inside a block body also counts: split it onto separate lines.
	if not inline:
		return []
	var first: FunctionGraph.Stmt = stmts[0]
	var last: FunctionGraph.Stmt = stmts[-1]
	var header_indent := doc.line_indent(body.header.start)
	var child_indent := header_indent + g.file.indent_unit()
	var nl := _newline(doc)
	var start := first.start
	if not _owns_line_start(doc, first):
		# Swallow the whitespace between ':' and the first statement.
		var before := doc.get_text(doc.line_start(first.start), first.start)
		var trimmed := before.rstrip(" \t")
		start = first.start - (before.to_utf8_buffer().size() - trimmed.to_utf8_buffer().size())
	else:
		child_indent = doc.line_indent(first.start)
	var parts := []
	for st in stmts:
		parts.append(reindent(_raw_text(doc, st), doc.line_indent(st.start), child_indent).substr(child_indent.length()))
	var text := ""
	if _owns_line_start(doc, first):
		text = nl.join(PackedStringArray(parts.map(func(p): return child_indent + p))).substr(child_indent.length())
		return [{ start = first.start, end = last.end, text = text }]
	for p in parts:
		text += nl + child_indent + p
	return [{ start = start, end = last.end, text = text }]


static func _raw_text(doc: GDSyntaxDocument, s: FunctionGraph.Stmt) -> String:
	return doc.get_text(s.start, s.end)


## Re-indents a block of lines from `old_indent` to `new_indent`.
## With `skip_first`, the first line is left as is (it starts mid-line).
static func reindent(text: String, old_indent: String, new_indent: String, skip_first := false) -> String:
	var lines := text.split("\n")
	for i in lines.size():
		if i == 0 and skip_first:
			continue
		var line := lines[i]
		if line.strip_edges().is_empty():
			lines[i] = line.lstrip(" \t") if i > 0 else line
			continue
		if not old_indent.is_empty() and line.begins_with(old_indent):
			line = line.substr(old_indent.length())
		lines[i] = new_indent + line
	return "\n".join(lines)
