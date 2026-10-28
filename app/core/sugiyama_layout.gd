class_name SugiyamaLayout
extends RefCounted
## Layered (Sugiyama-style) layout of a directed graph in 2D.
##
## Coordinates are (layer axis, in-layer axis); callers map them to screen
## axes. Steps: break cycles, longest-path layering, dummy nodes for long
## edges, barycenter crossing reduction, then a placement that pulls each node
## toward its neighbours (plus a per-edge `shift`) without overlaps.
##
## Edges are {from, to, port, shift, weight}:
##   port    orders the outgoing edges of a node
##   shift   desired in-layer offset of `to` relative to `from` (indentation)
##   weight  0 = layering constraint only (not drawn, not used for placement)

var layer_gap := 0.35
var node_gap := 0.12
var sweeps := 6


## nodes: {id: Vector2(layer-axis size, in-layer size)}.
## Returns {id: Vector2(layer-axis pos, in-layer pos)} of each node's corner.
func layout(nodes: Dictionary, edges: Array, order_hint: Array = []) -> Dictionary:
	if nodes.is_empty():
		return {}
	var ids: Array = order_hint.filter(func(i): return nodes.has(i)) if not order_hint.is_empty() else nodes.keys()
	for id in nodes:
		if not ids.has(id):
			ids.append(id)
	var hint_pos := {}
	for i in ids.size():
		hint_pos[ids[i]] = i

	# 1. Drop self-loops; reverse back-edges (by hint order) to get a DAG.
	var dag := []
	for e in edges:
		if not nodes.has(e.from) or not nodes.has(e.to) or e.from == e.to:
			continue
		var d := { from = e.from, to = e.to, port = e.get("port", 0), shift = e.get("shift", 0.0), weight = e.get("weight", 1.0) }
		if hint_pos[e.from] > hint_pos[e.to]:
			d.from = e.to
			d.to = e.from
			d.shift = -d.shift
		dag.append(d)

	# 2. Longest-path layering in hint order (topological for this DAG).
	var layer := {}
	for id in ids:
		layer[id] = 0
	var out_edges := {}
	for e in dag:
		if not out_edges.has(e.from):
			out_edges[e.from] = []
		out_edges[e.from].append(e)
	for id in ids:
		for e in out_edges.get(id, []):
			layer[e.to] = maxi(layer[e.to], layer[id] + 1)

	# 3. Dummy nodes so every placement edge spans one layer.
	var size := nodes.duplicate()
	var succ := {} ## id -> [[to, port, shift]]
	var pred := {} ## id -> [[from, shift]]
	for id in ids:
		succ[id] = []
		pred[id] = []
	var dummy_count := 0
	for e in dag:
		if e.weight <= 0.0:
			continue
		var a = e.from
		var span: int = layer[e.to] - layer[a]
		for k in range(1, span):
			var d := "~d%d" % dummy_count
			dummy_count += 1
			layer[d] = layer[e.from] + k
			size[d] = Vector2.ZERO
			succ[d] = []
			pred[d] = []
			succ[a].append([d, e.port, 0.0])
			pred[d].append([a, 0.0])
			a = d
		succ[a].append([e.to, e.port, e.shift])
		pred[e.to].append([a, e.shift])

	# 4. Initial order: DFS from roots following ports.
	var max_layer := 0
	for id in layer:
		max_layer = maxi(max_layer, layer[id])
	var layers := []
	for i in max_layer + 1:
		layers.append([])
	var visited := {}
	for id in ids:
		if pred[id].is_empty():
			_dfs_place(id, succ, layer, layers, visited)
	for id in layer:
		if not visited.has(id):
			_dfs_place(id, succ, layer, layers, visited)

	# 5. Barycenter sweeps.
	for it in sweeps:
		var down := it % 2 == 0
		var rng := range(1, layers.size()) if down else range(layers.size() - 2, -1, -1)
		for li in rng:
			var ref: Array = layers[li - 1] if down else layers[li + 1]
			var ref_pos := {}
			for i in ref.size():
				ref_pos[ref[i]] = i
			var cur: Array = layers[li]
			var keyed := []
			for i in cur.size():
				var nbrs: Array = pred[cur[i]] if down else succ[cur[i]]
				var sum := 0.0
				var cnt := 0
				for nb in nbrs:
					if ref_pos.has(nb[0]):
						sum += ref_pos[nb[0]]
						cnt += 1
				keyed.append([sum / cnt if cnt > 0 else float(i), i, cur[i]])
			keyed.sort_custom(func(a, b): return a[0] < b[0] if not is_equal_approx(a[0], b[0]) else a[1] < b[1])
			layers[li] = keyed.map(func(k): return k[2])

	# 6. Layer-axis coordinate from layer extents.
	var layer_pos := []
	var x := 0.0
	for li in layers.size():
		layer_pos.append(x)
		var w := 0.0
		for id in layers[li]:
			w = maxf(w, size[id].x)
		x += w + layer_gap

	# 7. In-layer coordinate: stack, then pull toward neighbours.
	var y := {}
	for li in layers.size():
		var cy := 0.0
		for id in layers[li]:
			y[id] = cy
			cy += size[id].y + node_gap
	var from_pred := func(id): return pred[id].map(func(p): return [p[0], p[1]])
	var from_succ := func(id): return succ[id].map(func(s): return [s[0], -s[2]])
	for it in 4:
		for li in range(1, layers.size()):
			_align_layer(layers[li], y, size, from_pred)
		for li in range(layers.size() - 2, -1, -1):
			_align_layer(layers[li], y, size, from_succ)
	for li in range(1, layers.size()):
		_align_layer(layers[li], y, size, from_pred)

	var out := {}
	var min_y := INF
	for id in nodes:
		min_y = minf(min_y, y[id])
	for li in layers.size():
		for id in layers[li]:
			if nodes.has(id):
				out[id] = Vector2(layer_pos[li], y[id] - min_y)
	return out


func _dfs_place(id, succ: Dictionary, layer: Dictionary, layers: Array, visited: Dictionary) -> void:
	if visited.has(id):
		return
	visited[id] = true
	layers[layer[id]].append(id)
	var outs: Array = succ[id].duplicate()
	outs.sort_custom(func(a, b): return a[1] < b[1])
	for s in outs:
		_dfs_place(s[0], succ, layer, layers, visited)


## Moves each node toward the mean of (neighbour + shift), then resolves
## overlaps forward and backward so the layer order is preserved.
func _align_layer(cur: Array, y: Dictionary, size: Dictionary, nbrs_of: Callable) -> void:
	var want := {}
	for id in cur:
		var nbrs: Array = nbrs_of.call(id)
		if nbrs.is_empty():
			want[id] = y[id]
			continue
		var s := 0.0
		for nb in nbrs:
			s += y[nb[0]] + nb[1]
		want[id] = s / nbrs.size()
	var prev_end := -INF
	for id in cur:
		y[id] = maxf(want[id], prev_end)
		prev_end = y[id] + size[id].y + node_gap
	var next_start := INF
	for i in range(cur.size() - 1, -1, -1):
		var id = cur[i]
		var limit: float = next_start - size[id].y - node_gap
		if y[id] > want[id]:
			y[id] = maxf(want[id], minf(y[id], limit))
		y[id] = minf(y[id], limit)
		next_start = y[id]
	prev_end = -INF
	for id in cur:
		y[id] = maxf(y[id], prev_end)
		prev_end = y[id] + size[id].y + node_gap
