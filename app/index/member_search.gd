class_name MemberSearch
extends RefCounted
## Ranked candidates for the drag-off menu.
##
## From an output pin of static type T:
##   group 0   members declared on T itself (project classes: funcs first)
##   group 1+  inherited members, nearest ancestor first
##   within a group: project usage frequency, then recency
## Untyped / Variant pins: every known member, ranked purely by usage.
## From an input pin expecting T: things in scope that produce a T.
##
## A fuzzy text filter is applied on top, keeping that order within each
## match-quality tier.

const KIND_ORDER := { "method": 0, "property": 1, "signal": 2, "constant": 3, "enum": 4, "class": 5 }
const MAX_VARIANT_RESULTS := 400


class Candidate:
	var label := "" ## Text shown in the list.
	var detail := "" ## Signature / type, shown dimmed.
	var group := 0
	var group_label := ""
	var kind := ""
	var type := "" ## Value type the candidate produces.
	var code := "" ## Statement to insert (output-pin search).
	var expr := "" ## Expression to put into the input field (input-pin search).
	var member: ProjectIndex.Member
	var freq := 0
	var recent := 0.0
	var rank := 0


var index: ProjectIndex


func _init(idx: ProjectIndex) -> void:
	index = idx


## Candidates when dragging from an output pin whose value is `expr` of type `t`.
func for_output(t: String, expr: String) -> Array:
	var out := []
	if t.is_empty():
		out = _variant_candidates(expr)
	else:
		var static_access := t.begins_with("type:")
		var base := t.substr(5) if static_access else t
		var chain := index.ancestors(base)
		for gi in chain.size():
			var owner: String = chain[gi]
			var group := []
			for m in index.own_members(owner):
				if static_access and not (m.is_static or m.kind in ["constant", "enum", "class"]):
					continue
				if m.name.begins_with("_") and m.kind == "method" and m.source != "project":
					continue
				group.append(_member_candidate(m, expr, gi, owner))
			if static_access and gi == 0:
				var c := Candidate.new()
				c.label = "new"
				c.detail = "() -> " + index.type_label(base)
				c.kind = "method"
				c.type = base
				c.group = 0
				c.group_label = index.type_label(base)
				c.code = "var %s := %s.new()" % [_var_name(base), expr]
				group.push_front(c)
			_sort_group(group, index.is_project_type(owner))
			out.append_array(group)
	for i in out.size():
		out[i].rank = i
	return out


## Candidates when dragging from an input pin that expects type `t`, given the
## resolver scope at that statement.
func for_input(t: String, r: TypeResolver) -> Array:
	var out := []
	# 1. Locals and parameters.
	for name in r.scope:
		if index.is_assignable(r.scope[name], t) and (not t.is_empty() or true):
			var c := Candidate.new()
			c.label = name
			c.detail = index.type_label(r.scope[name])
			c.kind = "local"
			c.type = r.scope[name]
			c.expr = name
			c.group = 0
			c.group_label = "In scope"
			out.append(c)
	# 2. Members of self (and ancestors) that produce the type.
	var gi := 1
	for owner in index.ancestors(r.self_type):
		var group := []
		for m in index.own_members(owner):
			var produced := r.member_value_type(m, m.kind == "method")
			if m.kind == "signal" or not index.is_assignable(produced, t) or t.is_empty() and m.kind == "constant":
				continue
			var c := _member_candidate(m, "self", gi, owner)
			c.type = produced
			c.expr = m.name + ("()" if m.kind == "method" else "")
			group.append(c)
		_sort_group(group, index.is_project_type(owner))
		out.append_array(group)
		gi += 1
	if not t.is_empty():
		# 3. Constructors and constants of the type itself.
		var ctor := Candidate.new()
		ctor.group = gi
		ctor.group_label = "Create"
		ctor.kind = "constructor"
		ctor.type = t
		if index.is_builtin_type(t):
			ctor.label = t + "()"
			ctor.expr = t + "()"
			out.append(ctor)
			for m in index.own_members(t):
				if m.kind == "constant" and m.type == t:
					var c := _member_candidate(m, t, gi, t)
					c.expr = t + "." + m.name
					out.append(c)
		elif index.is_project_type(t) or (ClassDB.class_exists(t) and ClassDB.can_instantiate(t)):
			ctor.label = index.type_label(t) + ".new()"
			ctor.expr = (index.classes[t].class_name_ if index.is_project_type(t) and not index.classes[t].class_name_.is_empty() else t) + ".new()"
			out.append(ctor)
		elif t == "bool":
			for v in ["true", "false"]:
				var c := Candidate.new()
				c.label = v
				c.expr = v
				c.kind = "literal"
				c.type = "bool"
				c.group = gi
				c.group_label = "Literal"
				out.append(c)
		# 4. Global functions returning it.
		gi += 1
		var globals := index.global_functions()
		var group := []
		for name in globals:
			if globals[name].ret == t:
				var c := Candidate.new()
				c.label = name
				c.detail = _sig(globals[name].args, globals[name].ret)
				c.kind = "function"
				c.type = t
				c.expr = name + "()"
				c.group = gi
				c.group_label = "Global"
				c.freq = index.usage.get(name, 0)
				group.append(c)
		group.sort_custom(func(a, b): return a.freq > b.freq if a.freq != b.freq else a.label < b.label)
		out.append_array(group)
	for i in out.size():
		out[i].rank = i
	return out


## Fuzzy filter on top of the ranking: exact > prefix > substring > subsequence,
## original rank inside each tier.
static func filter(cands: Array, query: String) -> Array:
	var q := query.strip_edges().to_lower()
	if q.is_empty():
		return cands
	var scored := []
	for c in cands:
		var tier := fuzzy_tier(q, c.label.to_lower().trim_suffix("()"))
		if tier > 0:
			scored.append([tier, c])
	scored.sort_custom(func(a, b): return a[0] > b[0] if a[0] != b[0] else a[1].rank < b[1].rank)
	return scored.map(func(x): return x[1])


## 4 exact, 3 prefix, 2 substring, 1 subsequence, 0 no match.
static func fuzzy_tier(q: String, s: String) -> int:
	if s == q:
		return 4
	if s.begins_with(q):
		return 3
	if s.contains(q):
		return 2
	var j := 0
	for ch in s:
		if j < q.length() and ch == q[j]:
			j += 1
	return 1 if j == q.length() else 0


func _member_candidate(m: ProjectIndex.Member, expr: String, group: int, owner: String) -> Candidate:
	var c := Candidate.new()
	c.member = m
	c.kind = m.kind
	c.group = group
	c.group_label = index.type_label(owner)
	c.freq = index.frequency(m)
	c.recent = index.recency(m)
	var recv := "" if expr == "self" else expr + "."
	match m.kind:
		"method":
			c.label = m.name + "()"
			c.detail = _sig(m.args, m.type)
			c.type = m.type
			c.code = "%s%s()" % [recv, m.name]
		"signal":
			c.label = m.name
			c.detail = "signal" + _sig(m.args, "")
			c.type = "Signal"
			c.code = "%s%s.connect()" % [recv, m.name]
		_:
			c.label = m.name
			c.detail = index.type_label(m.type) if m.kind != "class" else "class"
			c.type = m.type
			c.code = "var %s := %s%s" % [_var_name(m.name), recv, m.name]
	return c


func _sort_group(group: Array, project_owner: bool) -> void:
	group.sort_custom(func(a: Candidate, b: Candidate) -> bool:
		if project_owner:
			# Custom classes: their own funcs first.
			var ka: int = 0 if a.kind == "method" else 1
			var kb: int = 0 if b.kind == "method" else 1
			if ka != kb:
				return ka < kb
		if a.freq != b.freq:
			return a.freq > b.freq
		if a.recent != b.recent:
			return a.recent > b.recent
		var oa: int = KIND_ORDER.get(a.kind, 9)
		var ob: int = KIND_ORDER.get(b.kind, 9)
		if oa != ob:
			return oa < ob
		return a.label < b.label
	)


func _variant_candidates(expr: String) -> Array:
	# Everything the project uses, plus all project members, ranked by usage.
	var seen := {}
	var out := []
	for id in index.classes:
		for m in index.classes[id].members.values():
			if not seen.has(m.name):
				seen[m.name] = true
				out.append(_member_candidate(m, expr, 0, m.owner))
	for name in index.usage:
		if seen.has(name) or index.usage[name] <= 0:
			continue
		var owners := index.members_named(name)
		if owners.is_empty():
			continue
		seen[name] = true
		out.append(_member_candidate(owners[0], expr, 0, owners[0].owner))
	for c in out:
		c.freq = index.usage.get(c.member.name, 0)
		c.group_label = "Any"
	out.sort_custom(func(a, b):
		if a.freq != b.freq:
			return a.freq > b.freq
		if a.recent != b.recent:
			return a.recent > b.recent
		return a.label < b.label
	)
	if out.size() > MAX_VARIANT_RESULTS:
		out.resize(MAX_VARIANT_RESULTS)
	return out


func _sig(args: Array, ret: String) -> String:
	var parts := args.map(func(a): return a.name + (": " + index.type_label(a.type) if not str(a.type).is_empty() else ""))
	var s := "(" + ", ".join(PackedStringArray(parts)) + ")"
	if not ret.is_empty():
		s += " -> " + index.type_label(ret)
	return s


static func _var_name(s: String) -> String:
	var n := s.get_file().get_basename().to_snake_case()
	return n if n.is_valid_identifier() else "value"
