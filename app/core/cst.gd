class_name Cst
## Helpers for the Dictionary CST returned by GDSyntaxDocument.get_tree().
##
## Every node is {type, named, start, end, row, col, end_row, end_col,
## children, [field], [extra], [error], [has_error]} with byte offsets.


static func field(n: Dictionary, name: String) -> Dictionary:
	for c in n.children:
		if c.get("field", "") == name:
			return c
	return {}


static func fields(n: Dictionary, name: String) -> Array:
	var out := []
	for c in n.children:
		if c.get("field", "") == name:
			out.append(c)
	return out


## Named children, skipping comments and other extras.
static func named(n: Dictionary) -> Array:
	var out := []
	for c in n.children:
		if c.named and not c.get("extra", false):
			out.append(c)
	return out


static func first_of_type(n: Dictionary, type: String) -> Dictionary:
	for c in n.children:
		if c.type == type:
			return c
	return {}


static func all_of_type(n: Dictionary, type: String) -> Array:
	var out := []
	for c in n.children:
		if c.type == type:
			out.append(c)
	return out


static func contains_type(n: Dictionary, types: Array) -> bool:
	if n.type in types:
		return true
	for c in n.children:
		if contains_type(c, types):
			return true
	return false


## Depth-first visit. Return false from the callable to skip a node's children.
static func walk(n: Dictionary, visit: Callable) -> void:
	if visit.call(n) == false:
		return
	for c in n.children:
		walk(c, visit)


static func is_empty(n: Dictionary) -> bool:
	return n.is_empty()


## Text of a `type` / `inferred_type` node, or "" for `:=` and missing types.
static func type_text(doc: GDSyntaxDocument, n: Dictionary) -> String:
	if n.is_empty() or n.type == "inferred_type":
		return ""
	return doc.get_text(n.start, n.end).strip_edges()
