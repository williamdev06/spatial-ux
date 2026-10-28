class_name FunctionGraph
extends RefCounted
## Read-only projection of one function's CST into an execution-flow graph.
##
## It is rebuilt from the text after every change; nothing here is ever written
## back except through GraphEdits, which turns operations into byte edits.
##
## Statements become nodes; expressions stay as text fields on those nodes.
## Exec edges follow the structure of the code: `next` links a statement to the
## one after it in the same body, and compound statements have one extra pin
## per body (`then`, `elif0`, `else`, `body`) leading to that body's first
## statement. The last statement of a body has no `next` edge; flow resumes
## from the owning statement's own `next`, like a Blueprint "Completed" pin.

const CONTAINER_TYPES := [
	"body", "elif_clause", "else_clause", "match_body", "pattern_section", "class_body",
	"if_statement", "for_statement", "while_statement", "match_statement",
	"function_definition", "constructor_definition", "class_definition", "lambda",
]
const OPAQUE_EXPR_TYPES := ["lambda", "await_expression"]


class Field:
	var name := ""
	var label := ""
	var start := 0
	var end := 0
	var text := ""
	## Inserted in front of the text when the field is absent (start == end).
	var prefix := ""
	## When >= 0, clearing the field removes [opt_start, end) so no dangling
	## `=` or `->` is left behind.
	var opt_start := -1
	var expect_type := ""
	var multiline := false
	var node := {}

	func is_absent() -> bool:
		return start == end and text.is_empty()


class DataOut:
	var name := "" ## Pin id within its statement.
	var label := ""
	var expr := "" ## Expression text that yields the value (`self`, `player`, ...).
	var type := "" ## Static type, "" when unknown / Variant.


class Stmt:
	var key := ""
	var kind := "" ## entry, call, assign, var, if, for, while, return, pass, break, continue, code
	var title := ""
	var node := {}
	var start := 0
	var end := 0
	var depth := 0
	var fields: Array = []
	var exec_outs: Array[String] = []
	var branch_bodies := {} ## exec pin -> Body key
	var data_outs: Array = []
	var owner_key := "" ## Statement owning the body this one sits in.
	var body_key := ""
	var index := 0
	var hash := 0 ## Hash of the statement header, used to re-match manual layout.
	var has_error := false
	var call_name := ""
	var call_target := "" ## Receiver expression of a call, "" for self / global calls.

	func get_field(fname: String) -> Field:
		for f in fields:
			if f.name == fname:
				return f
		return null

	func get_data_out(pname: String) -> DataOut:
		for d in data_outs:
			if d.name == pname:
				return d
		return null


class Body:
	var key := "" ## "<owner key>|<pin>"
	var owner_key := ""
	var pin := ""
	var node := {}
	var header := {} ## Node whose line holds the ':' that opens this body.
	var stmt_keys: Array[String] = []
	var depth := 0


var file: ScriptFile
var name := ""
var qualname := ""
var func_node := {}
var stmts: Array = [] ## Pre-order, entry first.
var by_key := {}
var bodies := {}
var edges: Array = [] ## {from, pin, to}
var param_nodes: Array = [] ## CST nodes of the parameters, in order.


static func build(script_file: ScriptFile, func_info: Dictionary) -> FunctionGraph:
	var g := FunctionGraph.new()
	g.file = script_file
	g.name = func_info.name
	g.qualname = func_info.qualname
	g.func_node = func_info.node
	g._build()
	return g


func get_stmt(key: String) -> Stmt:
	return by_key.get(key)


func get_body(key: String) -> Body:
	return bodies.get(key)


## Statements on the path from the function body down to `key` (exclusive),
## i.e. every compound statement that encloses it.
func ancestors_of(key: String) -> Array:
	var out := []
	var s: Stmt = by_key.get(key)
	while s and s.owner_key != "entry" and s.owner_key != "":
		s = by_key.get(s.owner_key)
		out.push_front(s)
	return out


func _t(n: Dictionary) -> String:
	return file.text(n)


func _build() -> void:
	var entry := Stmt.new()
	entry.key = "entry"
	entry.kind = "entry"
	entry.node = func_node
	entry.start = func_node.start
	entry.end = func_node.start
	entry.title = "func " + name
	entry.exec_outs = ["next"]
	_add(entry)

	# Signature: the name, one field per parameter (the function's inputs) and
	# the return type (its output).
	var name_node := Cst.field(func_node, "name")
	if not name_node.is_empty():
		entry.fields.append(_node_field("name", "func", name_node))
	var params := Cst.field(func_node, "parameters")
	if not params.is_empty():
		param_nodes = Cst.named(params)
		for i in param_nodes.size():
			entry.fields.append(_node_field("param%d" % i, "in", param_nodes[i]))
	var ret := Cst.field(func_node, "return_type")
	if not ret.is_empty():
		var rf := _field("ret", "returns", ret.start, ret.end)
		rf.opt_start = params.end if not params.is_empty() else ret.start
		entry.fields.append(rf)
	elif not params.is_empty():
		var rf := _field("ret", "returns", params.end, params.end)
		rf.prefix = " -> "
		entry.fields.append(rf)

	var self_out := DataOut.new()
	self_out.name = "self"
	self_out.label = "self"
	self_out.expr = "self"
	entry.data_outs.append(self_out)
	if not params.is_empty():
		for p in Cst.named(params):
			var pname := ""
			var ptype := ""
			if p.type == "identifier":
				pname = _t(p)
			else:
				var id := Cst.first_of_type(p, "identifier")
				pname = _t(id)
				ptype = Cst.type_text(file.doc, Cst.field(p, "type"))
			if pname.is_empty():
				continue
			var d := DataOut.new()
			d.name = "param:" + pname
			d.label = pname
			d.expr = pname
			d.type = ptype
			entry.data_outs.append(d)
	entry.hash = _t(params).hash()

	var body := Cst.field(func_node, "body")
	if not body.is_empty():
		entry.branch_bodies["next"] = _add_body(body, func_node, entry, "next", 0).key


func _add(s: Stmt) -> void:
	stmts.append(s)
	by_key[s.key] = s


func _add_body(body_node: Dictionary, header: Dictionary, owner: Stmt, pin: String, depth: int) -> Body:
	var b := Body.new()
	b.key = owner.key + "|" + pin
	b.owner_key = owner.key
	b.pin = pin
	b.node = body_node
	b.header = header
	b.depth = depth
	bodies[b.key] = b
	var prev: Stmt = null
	var i := 0
	for c in Cst.named(body_node):
		var key := str(i) if owner.key == "entry" else "%s.%s.%d" % [owner.key, pin, i]
		var s := _make_stmt(c, key, depth, b, i)
		if prev == null:
			edges.append({ from = owner.key, pin = pin, to = s.key })
		elif prev.exec_outs.has("next"):
			edges.append({ from = prev.key, pin = "next", to = s.key })
		prev = s
		i += 1
	return b


func _make_stmt(c: Dictionary, key: String, depth: int, body: Body, index: int) -> Stmt:
	var s := Stmt.new()
	s.key = key
	s.node = c
	s.start = c.start
	s.end = stmt_end(c)
	s.depth = depth
	s.body_key = body.key
	s.owner_key = body.owner_key
	s.index = index
	s.exec_outs = ["next"]
	s.has_error = c.get("has_error", false) or c.get("error", false)
	_add(s)
	body.stmt_keys.append(key)

	if s.has_error:
		_as_code(s)
	else:
		match c.type:
			"expression_statement":
				_map_expression_statement(s, c)
			"variable_statement", "const_statement":
				_map_var(s, c)
			"if_statement":
				_map_if(s, c, depth)
			"for_statement":
				_map_for(s, c, depth)
			"while_statement":
				_map_while(s, c, depth)
			"return_statement":
				_map_return(s, c)
			"pass_statement":
				s.kind = "pass"
				s.title = "pass"
			"break_statement", "continue_statement":
				s.kind = "break" if c.type == "break_statement" else "continue"
				s.title = s.kind
				s.exec_outs = []
			_:
				_as_code(s)
	s.hash = _header_text(s).replace(" ", "").replace("\t", "").replace("\n", "").replace("\r", "").hash()
	return s


func _as_code(s: Stmt) -> void:
	s.kind = "code"
	s.fields.clear()
	s.branch_bodies.clear()
	s.data_outs.clear()
	s.exec_outs = ["next"]
	var first_word := _t(s.node).strip_edges().get_slice(" ", 0).get_slice("(", 0).get_slice(":", 0)
	s.title = first_word if first_word in ["match", "await", "assert", "@warning_ignore"] else "code"
	var f := _field("raw", "", s.start, s.end)
	f.multiline = true
	s.fields.append(f)


func _field(fname: String, label: String, start: int, end: int, node := {}) -> Field:
	var f := Field.new()
	f.name = fname
	f.label = label
	f.start = start
	f.end = end
	f.text = file.doc.get_text(start, end) if end > start else ""
	f.node = node
	return f


func _node_field(fname: String, label: String, n: Dictionary) -> Field:
	return _field(fname, label, n.start, n.end, n)


## Splits a call expression into receiver / name / arguments. Returns {} if the
## expression is not a call.
func call_parts(e: Dictionary) -> Dictionary:
	if e.type == "call":
		var parts := Cst.named(e)
		if parts.is_empty():
			return {}
		return { target = {}, name = _t(parts[0]), args = Cst.field(e, "arguments") }
	if e.type == "attribute":
		var parts := Cst.named(e)
		if parts.size() >= 2 and parts[-1].type == "attribute_call":
			var ac: Dictionary = parts[-1]
			var ac_parts := Cst.named(ac)
			var target := { start = e.start, end = parts[-2].end }
			return { target = target, name = _t(ac_parts[0]) if ac_parts.size() > 0 else "", args = Cst.field(ac, "arguments") }
	return {}


func _map_expression_statement(s: Stmt, c: Dictionary) -> void:
	var inner := Cst.named(c)
	if inner.is_empty() or Cst.contains_type(c, OPAQUE_EXPR_TYPES):
		_as_code(s)
		return
	var e: Dictionary = inner[0]
	match e.type:
		"call", "attribute":
			var parts := call_parts(e)
			if parts.is_empty():
				_as_code(s)
				return
			s.kind = "call"
			s.call_name = parts.name
			if not parts.target.is_empty():
				s.call_target = file.doc.get_text(parts.target.start, parts.target.end)
				s.fields.append(_field("target", "on", parts.target.start, parts.target.end))
			s.title = parts.name + "()"
			_add_arg_fields(s, parts.args)
			var r := DataOut.new()
			r.name = "result"
			r.label = "result"
			r.expr = _t(e)
			s.data_outs.append(r)
		"assignment", "augmented_assignment":
			s.kind = "assign"
			var op := Cst.field(e, "op")
			s.title = "set" if e.type == "assignment" else _t(op)
			s.fields.append(_node_field("left", "", Cst.field(e, "left")))
			s.fields.append(_node_field("right", "=" if e.type == "assignment" else _t(op), Cst.field(e, "right")))
		_:
			_as_code(s)


func _add_arg_fields(s: Stmt, args: Dictionary) -> void:
	if args.is_empty():
		return
	var i := 0
	for a in Cst.named(args):
		s.fields.append(_node_field("arg%d" % i, "", a))
		i += 1
	if i == 0:
		# Empty argument list: an insertion point between the parentheses.
		s.fields.append(_field("arg0", "args", args.start + 1, args.start + 1))


func _map_var(s: Stmt, c: Dictionary) -> void:
	if Cst.contains_type(c, OPAQUE_EXPR_TYPES) or not Cst.first_of_type(c, "annotations").is_empty():
		_as_code(s)
		return
	var name_node := Cst.field(c, "name")
	var type_node := Cst.field(c, "type")
	var value := Cst.field(c, "value")
	var vname := _t(name_node)
	s.kind = "var"
	s.title = ("const " if c.type == "const_statement" else "var ") + vname
	if not type_node.is_empty() and type_node.type == "type":
		s.fields.append(_node_field("type", ":", type_node))
	var decl_end: int = type_node.end if not type_node.is_empty() else name_node.end
	if not value.is_empty():
		var vf := _node_field("value", ":=" if type_node.get("type", "") == "inferred_type" else "=", value)
		vf.opt_start = decl_end if type_node.get("type", "") != "inferred_type" else name_node.end
		s.fields.append(vf)
	else:
		var vf := _field("value", "=", decl_end, decl_end)
		vf.prefix = " = "
		s.fields.append(vf)
	var d := DataOut.new()
	d.name = "var"
	d.label = vname
	d.expr = vname
	d.type = Cst.type_text(file.doc, type_node)
	s.data_outs.append(d)


func _map_if(s: Stmt, c: Dictionary, depth: int) -> void:
	if Cst.contains_type(Cst.field(c, "condition"), OPAQUE_EXPR_TYPES):
		_as_code(s)
		return
	s.kind = "if"
	s.title = "if"
	var cond := _node_field("cond", "if", Cst.field(c, "condition"))
	cond.expect_type = "bool"
	s.fields.append(cond)
	s.exec_outs = ["then"]
	s.branch_bodies["then"] = _add_body(Cst.field(c, "body"), c, s, "then", depth + 1).key
	var k := 0
	for alt in Cst.fields(c, "alternative"):
		if alt.type == "elif_clause":
			var pin := "elif%d" % k
			var ef := _node_field("cond_" + pin, "elif", Cst.field(alt, "condition"))
			ef.expect_type = "bool"
			s.fields.append(ef)
			s.exec_outs.append(pin)
			s.branch_bodies[pin] = _add_body(Cst.field(alt, "body"), alt, s, pin, depth + 1).key
			k += 1
		elif alt.type == "else_clause":
			s.exec_outs.append("else")
			s.branch_bodies["else"] = _add_body(Cst.field(alt, "body"), alt, s, "else", depth + 1).key
	s.exec_outs.append("next")


func _map_for(s: Stmt, c: Dictionary, depth: int) -> void:
	if Cst.contains_type(Cst.field(c, "right"), OPAQUE_EXPR_TYPES):
		_as_code(s)
		return
	s.kind = "for"
	s.title = "for"
	var left := Cst.field(c, "left")
	var type_node := Cst.field(c, "type")
	s.fields.append(_node_field("var", "each", left))
	if not type_node.is_empty():
		s.fields.append(_node_field("type", ":", type_node))
	s.fields.append(_node_field("iter", "in", Cst.field(c, "right")))
	s.exec_outs = ["body", "next"]
	var d := DataOut.new()
	d.name = "item"
	d.label = _t(left)
	d.expr = _t(left)
	d.type = Cst.type_text(file.doc, type_node)
	s.data_outs.append(d)
	_add_body_after(s, c, depth)


func _add_body_after(s: Stmt, c: Dictionary, depth: int) -> void:
	# Inserted at the front of exec_outs order is "body", "next"; the body is
	# built after the statement so pre-order stays parent-before-children.
	s.branch_bodies["body"] = _add_body(Cst.field(c, "body"), c, s, "body", depth + 1).key


func _map_while(s: Stmt, c: Dictionary, depth: int) -> void:
	if Cst.contains_type(Cst.field(c, "condition"), OPAQUE_EXPR_TYPES):
		_as_code(s)
		return
	s.kind = "while"
	s.title = "while"
	var cond := _node_field("cond", "while", Cst.field(c, "condition"))
	cond.expect_type = "bool"
	s.fields.append(cond)
	s.exec_outs = ["body", "next"]
	_add_body_after(s, c, depth)


func _map_return(s: Stmt, c: Dictionary) -> void:
	if Cst.contains_type(c, OPAQUE_EXPR_TYPES):
		_as_code(s)
		return
	s.kind = "return"
	s.title = "return"
	s.exec_outs = []
	var kw_end: int = c.start + "return".length()
	var vals := Cst.named(c)
	if vals.is_empty():
		var f := _field("value", "value", kw_end, kw_end)
		f.prefix = " "
		s.fields.append(f)
	else:
		var f := _node_field("value", "value", vals[0])
		f.opt_start = kw_end
		s.fields.append(f)


func _header_text(s: Stmt) -> String:
	if s.kind in ["if", "for", "while"]:
		var body := Cst.field(s.node, "body")
		if not body.is_empty():
			return file.doc.get_text(s.start, body.start)
	return file.doc.get_text(s.start, s.end)


## End byte of a statement, ignoring trailing comments that tree-sitter may
## have folded into a compound statement's last body.
static func stmt_end(n: Dictionary) -> int:
	if not n.type in CONTAINER_TYPES:
		return n.end
	for i in range(n.children.size() - 1, -1, -1):
		var k: Dictionary = n.children[i]
		if k.get("extra", false):
			continue
		return stmt_end(k) if k.type in CONTAINER_TYPES else k.end
	return n.end
