class_name FunctionLayout
## Places a function graph's nodes on its board: Sugiyama in 2D with flow
## running top to bottom, then nested scopes pushed toward the viewer in Z so
## structure reads in 3D. Stored manual positions win over the auto layout.
##
## Branch bodies are indented to the right of their statement, and layout-only
## "join" edges from each body's tail to the statement after the compound
## statement keep the continuation below the body, so the board reads in the
## same order as the code.

const DEPTH_STEP := 0.06 ## Z offset per nesting level (metres).
const INDENT := 0.12
const ROW_GAP := 0.05
const COLUMN_GAP := 0.08


## sizes: {stmt key: Vector2 (metres)}. Returns {stmt key: Vector3 top-left
## corner in board space, +x right, +y up, +z toward the viewer}.
static func compute(g: FunctionGraph, sizes: Dictionary, manual: Dictionary = {}) -> Dictionary:
	var edges := []
	var next_of := {}
	for e in g.edges:
		var from: FunctionGraph.Stmt = g.get_stmt(e.from)
		var is_next: bool = e.pin == "next" and e.from != "entry"
		var port := 0 if is_next else 1 + from.exec_outs.find(e.pin)
		edges.append({ from = e.from, to = e.to, port = port, shift = 0.0 if is_next or e.from == "entry" else INDENT })
		if is_next:
			next_of[e.from] = e.to
	for s in g.stmts:
		if not next_of.has(s.key):
			continue
		for pin in s.branch_bodies:
			for tail in _tails(g, s.branch_bodies[pin]):
				edges.append({ from = tail, to = next_of[s.key], weight = 0.0 })
	# The layout runs along its first axis; here that is downward.
	var swapped := {}
	for k in sizes:
		swapped[k] = Vector2(sizes[k].y, sizes[k].x)
	var lay := SugiyamaLayout.new()
	lay.layer_gap = ROW_GAP
	lay.node_gap = COLUMN_GAP
	var pos2 := lay.layout(swapped, edges, g.stmts.map(func(s): return s.key))
	var out := {}
	for s in g.stmts:
		if manual.has(s.key):
			out[s.key] = manual[s.key]
		elif pos2.has(s.key):
			var p: Vector2 = pos2[s.key]
			out[s.key] = Vector3(p.y, -p.x, s.depth * DEPTH_STEP)
	return out


## Last statements of a body, recursing into the bodies of a trailing compound
## statement (flow can leave from any of them).
static func _tails(g: FunctionGraph, body_key: String) -> Array:
	var b := g.get_body(body_key)
	if b == null or b.stmt_keys.is_empty():
		return []
	var last := g.get_stmt(b.stmt_keys[-1])
	var out := [last.key]
	for pin in last.branch_bodies:
		out.append_array(_tails(g, last.branch_bodies[pin]))
	return out
