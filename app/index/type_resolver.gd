class_name TypeResolver
extends RefCounted
## Static type inference over the CST, limited to what is knowable without
## running anything: type annotations, `:=` declarations, literals, return
## types from ClassDB / builtin API / the project index, `self`'s class and its
## `extends` chain. Anything else resolves to "" (Variant).

const COMPARISON_OPS := ["==", "!=", "<", ">", "<=", ">=", "and", "or", "&&", "||", "in", "not in", "is", "is not", "not"]
const VECTOR_TYPES := ["Vector2", "Vector2i", "Vector3", "Vector3i", "Vector4", "Vector4i", "Color", "Quaternion", "Basis", "Transform2D", "Transform3D", "Projection"]

var index: ProjectIndex
var self_type := ""
var file: ScriptFile
var scope := {} ## local name -> type id
var func_return := ""


func _init(idx: ProjectIndex, self_t: String, sf: ScriptFile) -> void:
	index = idx
	self_type = self_t
	file = sf


## Resolver with params plus every local declared before `at_byte` that is
## visible there (-1 = params only).
static func for_function(idx: ProjectIndex, self_t: String, sf: ScriptFile, func_node: Dictionary, at_byte := -1) -> TypeResolver:
	var r := TypeResolver.new(idx, self_t, sf)
	r._add_params(func_node)
	r.func_return = r.type_of_written(Cst.type_text(sf.doc, Cst.field(func_node, "return_type")))
	if at_byte >= 0:
		r._scope_until(Cst.field(func_node, "body"), at_byte)
	return r


func type_of_written(t: String) -> String:
	if t.is_empty():
		return ""
	return index.resolve_type_name(t, self_type)


func _add_params(func_node: Dictionary) -> void:
	var params := Cst.field(func_node, "parameters")
	if params.is_empty():
		return
	for p in Cst.named(params):
		if p.type == "identifier":
			scope[file.text(p)] = ""
			continue
		var name := file.text(Cst.first_of_type(p, "identifier"))
		var tn := Cst.field(p, "type")
		if tn.get("type", "") == "inferred_type":
			scope[name] = resolve(Cst.field(p, "value"))
		else:
			scope[name] = type_of_written(Cst.type_text(file.doc, tn))


func _scope_until(body: Dictionary, at: int) -> void:
	if body.is_empty():
		return
	for st in Cst.named(body):
		if st.start >= at:
			return
		if at >= st.end:
			if st.type in ["variable_statement", "const_statement"]:
				declare(st)
			continue
		# `at` is inside this statement: descend into the body that holds it.
		match st.type:
			"for_statement":
				var b := Cst.field(st, "body")
				if at >= b.get("start", st.end):
					_declare_loop_var(st)
					_scope_until(b, at)
			"if_statement", "while_statement":
				_scope_until(Cst.field(st, "body"), at)
				for alt in Cst.fields(st, "alternative"):
					if at >= alt.start and at < alt.end:
						_scope_until(Cst.field(alt, "body"), at)
			"match_statement":
				for sec in Cst.named(Cst.field(st, "body")):
					if at >= sec.start and at < sec.end:
						_scope_until(Cst.field(sec, "body"), at)
		return


func declare(st: Dictionary) -> void:
	var name := file.text(Cst.field(st, "name"))
	scope[name] = declared_type(st)


## Type of a `var`/`const` statement: its annotation, or its value for `:=`.
func declared_type(st: Dictionary) -> String:
	var tn := Cst.field(st, "type")
	if tn.get("type", "") == "type":
		return type_of_written(file.text(tn))
	if tn.get("type", "") == "inferred_type" or st.type == "const_statement":
		return resolve(Cst.field(st, "value"))
	return ""


func _declare_loop_var(st: Dictionary) -> void:
	scope[file.text(Cst.field(st, "left"))] = loop_var_type(st)


func loop_var_type(st: Dictionary) -> String:
	var tn := Cst.field(st, "type")
	if not tn.is_empty():
		return type_of_written(file.text(tn))
	var it := Cst.field(st, "right")
	if it.type == "call" and file.text(Cst.named(it)[0]) == "range":
		return "int"
	return element_type(resolve(it))


static func element_type(t: String) -> String:
	if t.begins_with("Array[") and t.ends_with("]"):
		return t.substr(6, t.length() - 7)
	if t in ["int", "String"]:
		return t
	if t.begins_with("Packed") and t.ends_with("Array"):
		return {
			"PackedByteArray": "int", "PackedInt32Array": "int", "PackedInt64Array": "int",
			"PackedFloat32Array": "float", "PackedFloat64Array": "float", "PackedStringArray": "String",
			"PackedVector2Array": "Vector2", "PackedVector3Array": "Vector3", "PackedColorArray": "Color",
			"PackedVector4Array": "Vector4",
		}.get(t, "")
	return ""


# --- expressions ---------------------------------------------------------------

func resolve(n: Dictionary) -> String:
	if n.is_empty():
		return ""
	match n.type:
		"identifier":
			return _identifier(file.text(n))
		"integer":
			return "int"
		"float":
			return "float"
		"string":
			return "String"
		"true", "false":
			return "bool"
		"array":
			return "Array"
		"dictionary":
			return "Dictionary"
		"string_name":
			return "StringName"
		"node_path":
			return "NodePath"
		"get_node":
			return "Node"
		"lambda":
			return "Callable"
		"parenthesized_expression":
			var inner := Cst.named(n)
			return resolve(inner[0]) if inner.size() > 0 else ""
		"conditional_expression":
			return resolve(Cst.field(n, "left"))
		"unary_operator":
			var t := file.text(n).strip_edges()
			if t.begins_with("not") or t.begins_with("!"):
				return "bool"
			var inner := Cst.named(n)
			return resolve(inner[0]) if inner.size() > 0 else ""
		"binary_operator":
			return _binary(n)
		"call":
			return _call(n)
		"attribute":
			return resolve_chain(n, -1)
		"subscript":
			var inner := Cst.named(n)
			return element_type(resolve(inner[0])) if inner.size() > 0 else ""
	return ""


func _identifier(name: String) -> String:
	if name == "self":
		return self_type
	if name == "super":
		return index.parent_of(self_type)
	if scope.has(name):
		return scope[name]
	if name in ["INF", "NAN", "PI", "TAU"]:
		return "float"
	var m := index.find_member(self_type, name)
	if m:
		return member_value_type(m)
	if index.autoloads.has(name):
		return index.autoloads[name]
	var t := index.resolve_type_name(name, self_type)
	if index.type_exists(t):
		return "type:" + t
	return ""


func _binary(n: Dictionary) -> String:
	var op := file.text(Cst.field(n, "op")).strip_edges()
	if op in COMPARISON_OPS:
		return "bool"
	if op == "as":
		return type_of_written(file.text(Cst.field(n, "right")))
	var l := resolve(Cst.field(n, "left"))
	var r := resolve(Cst.field(n, "right"))
	if l == r:
		return l
	if l in ["int", "float"] and r in ["int", "float"]:
		return "float"
	if l in VECTOR_TYPES:
		return l
	if r in VECTOR_TYPES:
		return r
	if l == "String" and op == "%":
		return "String"
	return l


func _call(n: Dictionary) -> String:
	var parts := Cst.named(n)
	if parts.is_empty():
		return ""
	var name := file.text(parts[0])
	if index.is_builtin_type(name):
		return name
	var m := index.find_member(self_type, name)
	if m and m.kind == "method":
		return member_value_type(m, true)
	if name in ["preload", "load"]:
		var args := Cst.named(Cst.field(n, "arguments"))
		if args.size() > 0 and args[0].type == "string":
			var p := file.text(args[0]).trim_prefix("\"").trim_suffix("\"")
			if p.ends_with(".gd") and index.by_path.has(p):
				return "type:" + index.by_path[p]
			if p.ends_with(".tscn") or p.ends_with(".scn"):
				return "PackedScene"
		return "Resource"
	var g := index.global_function(name)
	if not g.is_empty():
		return g.ret if g.ret != "void" else "void"
	return ""


## Resolves the first `count` parts of an attribute chain (-1 = all of it).
func resolve_chain(n: Dictionary, count: int) -> String:
	var parts := Cst.named(n)
	if count < 0:
		count = parts.size()
	if parts.is_empty():
		return ""
	var t := resolve(parts[0])
	for i in range(1, mini(count, parts.size())):
		t = step(t, parts[i])
	return t


## Type after applying one chain part (`.name`, `.name(...)`, `.name[...]`).
func step(t: String, part: Dictionary) -> String:
	var name := file.text(Cst.named(part)[0]) if part.type != "identifier" else file.text(part)
	match part.type:
		"identifier":
			return member_type(t, name)
		"attribute_call":
			return method_return(t, name)
		"attribute_subscript":
			return element_type(member_type(t, name))
	return ""


func member_type(t: String, name: String) -> String:
	if t.is_empty():
		return ""
	var m := index.find_member(t, name)
	if m == null:
		return ""
	return member_value_type(m)


func method_return(t: String, name: String) -> String:
	if t.begins_with("type:") and name == "new":
		return t.substr(5)
	if t.is_empty():
		return ""
	var m := index.find_member(t, name)
	if m == null:
		return ""
	if m.kind != "method":
		return ""
	return member_value_type(m, true)


## Type of a member when read (`obj.prop`) or, with `called`, its return type.
func member_value_type(m: ProjectIndex.Member, called := false) -> String:
	match m.kind:
		"method":
			if not called:
				return "Callable"
		"signal":
			return "Signal"
		"class":
			return m.type
	if m.source == "project":
		return index.resolve_type_name(m.type, m.owner)
	return m.type


# --- graph annotation ------------------------------------------------------------

## Fills in pin types and expected input types on a freshly built graph.
func annotate(g: FunctionGraph) -> void:
	for s in g.stmts:
		var r := TypeResolver.for_function(index, self_type, file, g.func_node, s.start if s.kind != "entry" else -1)
		match s.kind:
			"entry":
				for d in s.data_outs:
					d.type = self_type if d.name == "self" else r.scope.get(d.label, "")
			"var":
				var t := r.declared_type(s.node)
				s.data_outs[0].type = t
				var vf: FunctionGraph.Field = s.get_field("value")
				if vf and Cst.field(s.node, "type").get("type", "") == "type":
					vf.expect_type = t
			"for":
				s.data_outs[0].type = r.loop_var_type(s.node)
			"assign":
				var e: Dictionary = Cst.named(s.node)[0]
				s.get_field("right").expect_type = r.resolve(Cst.field(e, "left"))
			"return":
				s.get_field("value").expect_type = func_return
			"call":
				r._annotate_call(g, s)


func _annotate_call(g: FunctionGraph, s: FunctionGraph.Stmt) -> void:
	var e: Dictionary = Cst.named(s.node)[0]
	var parts := g.call_parts(e)
	var receiver := self_type
	var m: ProjectIndex.Member = null
	var sig_args: Array = []
	var ret := ""
	if not parts.target.is_empty():
		receiver = resolve_chain(e, Cst.named(e).size() - 1)
		m = index.find_member(receiver, s.call_name) if not receiver.is_empty() else null
	else:
		m = index.find_member(self_type, s.call_name)
		if m == null:
			var gf := index.global_function(s.call_name)
			if not gf.is_empty():
				sig_args = gf.args
				ret = gf.ret
			elif index.is_builtin_type(s.call_name):
				ret = s.call_name
	if m:
		sig_args = m.args
		ret = member_value_type(m, true) if m.kind == "method" else ""
	# `some_signal.emit(...)` takes the signal's declared parameters.
	if receiver == "Signal" and s.call_name == "emit":
		var chain := Cst.named(e)
		var sig_owner := self_type if chain.size() <= 2 else resolve_chain(e, chain.size() - 2)
		var sig := index.find_member(sig_owner, file.text(chain[-2])) if chain.size() >= 2 and chain[-2].type == "identifier" else null
		if sig and sig.kind == "signal":
			sig_args = sig.args
			s.title = "emit " + sig.name
	var res: FunctionGraph.DataOut = s.get_data_out("result")
	if res:
		res.type = ret
		if ret == "void":
			s.data_outs.erase(res)
	var target_field: FunctionGraph.Field = s.get_field("target")
	if target_field:
		target_field.expect_type = receiver if m else ""
	# Argument expectations, plus a placeholder for the next missing argument.
	var arg_fields := s.fields.filter(func(f): return f.name.begins_with("arg"))
	var given := arg_fields.filter(func(f): return not f.is_absent())
	for i in given.size():
		if i < sig_args.size():
			given[i].label = sig_args[i].name
			given[i].expect_type = type_of_written(sig_args[i].type) if m and m.source == "project" else sig_args[i].type
	if given.size() < sig_args.size():
		var next_arg: Dictionary = sig_args[given.size()]
		var ph: FunctionGraph.Field
		if given.is_empty() and arg_fields.size() > 0:
			ph = arg_fields[0]
		else:
			var args: Dictionary = parts.args
			ph = FunctionGraph.Field.new()
			ph.name = "arg%d" % given.size()
			ph.start = args.end - 1
			ph.end = args.end - 1
			ph.prefix = ", "
			s.fields.append(ph)
		ph.label = next_arg.name + ("?" if next_arg.get("has_default", false) else "")
		ph.expect_type = next_arg.type


# --- usage walking ---------------------------------------------------------------

## Calls `cb(member_name, receiver_type)` for every member access and call in a
## function, with receiver types resolved in proper scope order.
func visit_usage(func_node: Dictionary, cb: Callable) -> void:
	_visit_block(Cst.field(func_node, "body"), cb)


func _visit_block(body: Dictionary, cb: Callable) -> void:
	if body.is_empty():
		return
	var saved := scope.duplicate()
	for st in Cst.named(body):
		_visit_stmt(st, cb)
	scope = saved


func _visit_stmt(st: Dictionary, cb: Callable) -> void:
	match st.type:
		"variable_statement", "const_statement":
			_visit_expr(Cst.field(st, "value"), cb)
			declare(st)
		"for_statement":
			_visit_expr(Cst.field(st, "right"), cb)
			var saved := scope.duplicate()
			_declare_loop_var(st)
			_visit_block(Cst.field(st, "body"), cb)
			scope = saved
		"if_statement", "while_statement":
			_visit_expr(Cst.field(st, "condition"), cb)
			_visit_block(Cst.field(st, "body"), cb)
			for alt in Cst.fields(st, "alternative"):
				_visit_expr(Cst.field(alt, "condition"), cb)
				_visit_block(Cst.field(alt, "body"), cb)
		"match_statement":
			_visit_expr(Cst.field(st, "value"), cb)
			for sec in Cst.named(Cst.field(st, "body")):
				_visit_block(Cst.field(sec, "body"), cb)
		_:
			_visit_expr(st, cb)


func _visit_expr(n: Dictionary, cb: Callable) -> void:
	if n.is_empty():
		return
	match n.type:
		"attribute":
			var parts := Cst.named(n)
			if parts.is_empty():
				return
			_visit_expr(parts[0], cb)
			var t := resolve(parts[0])
			for i in range(1, parts.size()):
				var p: Dictionary = parts[i]
				var name := file.text(p) if p.type == "identifier" else file.text(Cst.named(p)[0])
				cb.call(name, t)
				for sub in Cst.named(p):
					if sub.type == "arguments" or sub.get("field", "") == "arguments":
						_visit_expr(sub, cb)
				t = step(t, p)
			return
		"call":
			var parts := Cst.named(n)
			if parts.size() > 0:
				var name := file.text(parts[0])
				cb.call(name, self_type if index.find_member(self_type, name) else "")
			_visit_expr(Cst.field(n, "arguments"), cb)
			return
		"lambda":
			var saved := scope.duplicate()
			_add_params(n)
			_visit_block(Cst.field(n, "body"), cb)
			scope = saved
			return
	for c in Cst.named(n):
		_visit_expr(c, cb)
