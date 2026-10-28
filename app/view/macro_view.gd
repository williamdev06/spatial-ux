class_name MacroView
extends Node3D
## 3D force-directed graph of the project's scripts. Edges: extends (white),
## preload/load (orange) and references by class_name (blue).

const IDEAL := 1.1 ## Ideal edge length (m).
const MAX_STEPS := 600

var workspace: Node ## Workspace
var nodes := {} ## class id -> ClassNode3D
var edges: Array = [] ## {a, b, kind}
var edges_dirty := true
var _temp := 0.3
var _steps := 0
var _edge_mesh := ImmediateMesh.new()


func _ready() -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _edge_mesh
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = m
	add_child(mi)


func clear() -> void:
	for id in nodes:
		nodes[id].queue_free()
	nodes.clear()
	edges.clear()
	edges_dirty = true


## Syncs nodes and edges with the index (call after any reindex).
func refresh() -> void:
	var idx: ProjectIndex = workspace.index
	var top := {}
	for id in idx.classes:
		var c: ProjectIndex.ScriptClass = idx.classes[id]
		if c.outer.is_empty():
			top[id] = c
	for id in nodes.keys():
		if not top.has(id):
			nodes[id].queue_free()
			nodes.erase(id)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for id in top:
		var c: ProjectIndex.ScriptClass = top[id]
		if nodes.has(id):
			continue
		var funcs := c.members.values().filter(func(m): return m.kind == "method").size()
		var base := _engine_base(c.id)
		var title := c.class_name_ if not c.class_name_.is_empty() else c.res_path.get_file()
		var n := ClassNode3D.new().setup(self, id, title, "%s · %d funcs" % [base, funcs], _base_color(base), funcs)
		var stored = workspace.layout_store.get_macro(id)
		if stored != null:
			n.position = stored
			n.pinned = true
		else:
			n.position = Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.5, 0.5), rng.randf_range(-1, 1)) * IDEAL * 1.5
		add_child(n)
		nodes[id] = n
	edges.clear()
	for id in top:
		var c: ProjectIndex.ScriptClass = top[id]
		var parent := _top_level(c.parent)
		if nodes.has(parent) and parent != id:
			edges.append({ a = id, b = parent, kind = "extends" })
		for p in c.preloads:
			var t: String = idx.by_path.get(p, "")
			if nodes.has(t) and t != id:
				edges.append({ a = id, b = t, kind = "preload" })
		for t in c.refs:
			var tt := _top_level(t)
			if nodes.has(tt) and tt != id and tt != parent:
				edges.append({ a = id, b = tt, kind = "calls" })
	_temp = 0.3
	_steps = 0
	edges_dirty = true


func _top_level(id: String) -> String:
	var idx: ProjectIndex = workspace.index
	while idx.classes.has(id) and not idx.classes[id].outer.is_empty():
		id = idx.classes[id].outer
	return id


func _engine_base(id: String) -> String:
	for a in workspace.index.ancestors(id):
		if not workspace.index.is_project_type(a):
			return a
	return "RefCounted"


func _base_color(base: String) -> Color:
	if ClassDB.is_parent_class(base, "Control"):
		return Color(0.35, 0.75, 0.45)
	if ClassDB.is_parent_class(base, "Node3D"):
		return Color(0.95, 0.45, 0.35)
	if ClassDB.is_parent_class(base, "Node2D"):
		return Color(0.40, 0.60, 0.95)
	if ClassDB.is_parent_class(base, "Resource"):
		return Color(0.95, 0.75, 0.30)
	if ClassDB.is_parent_class(base, "Node"):
		return Color(0.80, 0.80, 0.85)
	return Color(0.65, 0.55, 0.85)


func node_moved(n: ClassNode3D) -> void:
	workspace.layout_store.set_macro(n.class_id, n.position)
	workspace.layout_changed()
	edges_dirty = true


func _process(_dt: float) -> void:
	if _steps < MAX_STEPS and _temp > 0.002:
		_simulate()
		_steps += 1
		edges_dirty = true
	if edges_dirty:
		edges_dirty = false
		_draw_edges()


## One Fruchterman-Reingold step. Expanded classes push harder so their
## boards have room.
func _simulate() -> void:
	var ids := nodes.keys()
	var disp := {}
	for id in ids:
		disp[id] = Vector3.ZERO
	for i in ids.size():
		var a: ClassNode3D = nodes[ids[i]]
		for j in range(i + 1, ids.size()):
			var b: ClassNode3D = nodes[ids[j]]
			var d := a.position - b.position
			var dist := maxf(d.length(), 0.01)
			var k := IDEAL * (3.0 if a.expanded or b.expanded else 1.0)
			var f := d / dist * (k * k / dist)
			disp[ids[i]] += f
			disp[ids[j]] -= f
	for e in edges:
		var a: ClassNode3D = nodes[e.a]
		var b: ClassNode3D = nodes[e.b]
		var d := a.position - b.position
		var dist := maxf(d.length(), 0.01)
		var f := d / dist * (dist * dist / IDEAL) * (1.0 if e.kind != "calls" else 0.5)
		disp[e.a] -= f
		disp[e.b] += f
	for id in ids:
		var n: ClassNode3D = nodes[id]
		if n.pinned or n.expanded:
			continue
		disp[id] -= n.position * 0.15 # gravity toward the centre
		var v: Vector3 = disp[id]
		n.position += v.normalized() * minf(v.length(), _temp)
	_temp *= 0.985


func _draw_edges() -> void:
	_edge_mesh.clear_surfaces()
	if edges.is_empty():
		return
	_edge_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for e in edges:
		var color := Color(0.9, 0.9, 0.9, 0.9)
		if e.kind == "preload":
			color = Color(1.0, 0.6, 0.2, 0.9)
		elif e.kind == "calls":
			color = Color(0.4, 0.6, 1.0, 0.55)
		var a: Vector3 = nodes[e.a].position
		var b: Vector3 = nodes[e.b].position
		_edge_mesh.surface_set_color(color)
		_edge_mesh.surface_add_vertex(a)
		_edge_mesh.surface_set_color(color.darkened(0.5))
		_edge_mesh.surface_add_vertex(b)
	_edge_mesh.surface_end()
