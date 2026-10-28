extends TestCase
## Project index, static type resolution and drag-off search ranking.

const PLAYER := """class_name Player extends CharacterBody3D
## The player.

signal died(cause: String)
const MAX_HP := 100
@export var health: int = 100
var weapon := Weapon.new()
var target: Node3D

class Weapon extends RefCounted:
	var damage := 3
	func fire(at: Vector3) -> bool:
		return true

func take_damage(amount: int, source: Node = null) -> int:
	health -= amount
	return health

func heal(amount: int) -> void:
	health += amount

static func spawn() -> Player:
	return Player.new()
"""

const BOSS := """class_name Boss
extends Player

func enrage() -> void:
	take_damage(1)
"""

const MAIN := """extends Node3D

const EnemyScene = preload("res://enemy.gd")

func _ready() -> void:
	var p := Player.new()
	p.take_damage(5)
	p.take_damage(6)
	p.heal(1)
	var b: Boss = Boss.new()
	b.take_damage(2)
	var up := Vector3.UP
	var n := get_node("x")
	var hp := p.health
	var w := p.weapon.fire(up)
	for i in range(3):
		print(i)
	for child: Node3D in get_children():
		child.look_at(up)
	var mixed = p
	position.x += 1.0
"""

const ENEMY := """extends Node

func attack(p: Player) -> void:
	p.take_damage(1)
"""

var idx: ProjectIndex


func _init() -> void:
	var dir := OS.get_user_data_dir().path_join("test_index_project")
	DirAccess.make_dir_recursive_absolute(dir)
	_write(dir.path_join("project.godot"), "config_version=5\n\n[autoload]\n\nGame=\"*res://main.gd\"\n")
	_write(dir.path_join("player.gd"), PLAYER)
	_write(dir.path_join("boss.gd"), BOSS)
	_write(dir.path_join("main.gd"), MAIN)
	_write(dir.path_join("enemy.gd"), ENEMY)
	idx = ProjectIndex.new()
	idx.recent.clear()
	idx.open_project(dir)


func _write(p: String, s: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(s)
	f.close()


func test_classes_extracted() -> void:
	check(idx.classes.has("Player"), "Player")
	check(idx.classes.has("Boss"), "Boss")
	check(idx.classes.has("res://main.gd"), "unnamed script keyed by path")
	check(idx.classes.has("Player.Weapon"), "inner class")
	var p: ProjectIndex.ScriptClass = idx.classes["Player"]
	check_eq(p.parent, "CharacterBody3D")
	var td: ProjectIndex.Member = p.members["take_damage"]
	check_eq(td.kind, "method")
	check_eq(td.type, "int")
	check_eq(td.args.map(func(a): return a.name + ":" + a.type), ["amount:int", "source:Node"])
	check(p.members["spawn"].is_static, "static func")
	check_eq(p.members["died"].kind, "signal")
	check_eq(p.members["MAX_HP"].kind, "constant")
	check_eq(p.members["MAX_HP"].type, "int", "inferred const type")
	check_eq(p.members["weapon"].type, "Player.Weapon", "inferred from Inner.new()")
	check_eq(idx.classes["res://main.gd"].preloads, ["res://enemy.gd"] as Array[String])
	check_eq(idx.autoloads.get("Game"), "res://main.gd")


func test_ancestors_cross_project_and_engine() -> void:
	var a := idx.ancestors("Boss")
	check_eq(a.slice(0, 4), ["Boss", "Player", "CharacterBody3D", "PhysicsBody3D"] as Array[String])
	check(a.has("Node"), "reaches Node")
	check_eq(a[-1], "Object")


func test_usage_counts() -> void:
	check_eq(idx.usage_typed.get("Player.take_damage", 0), 5, "typed usage (p, b, boss self-call, enemy param)")
	check_eq(idx.usage_typed.get("Player.heal", 0), 1)
	check(idx.usage.get("look_at", 0) >= 1, "engine method name counted")
	check_eq(idx.usage_typed.get("Node3D.look_at", 0), 1, "typed loop var receiver")


func _resolver_at(res_path: String, fname: String, needle: String) -> TypeResolver:
	var sf: ScriptFile = idx.files[res_path]
	var f := sf.find_function(fname)
	var at := byte_of(sf.doc, needle)
	return TypeResolver.for_function(idx, idx.class_of_function(sf, f), sf, f.node, at)


func test_type_resolution() -> void:
	var r := _resolver_at("res://main.gd", "_ready", "position.x")
	check_eq(r.scope.get("p"), "Player")
	check_eq(r.scope.get("b"), "Boss")
	check_eq(r.scope.get("up"), "Vector3")
	check_eq(r.scope.get("n"), "Node")
	check_eq(r.scope.get("hp"), "int")
	check_eq(r.scope.get("w"), "bool", "inner class method return")
	check_eq(r.scope.get("mixed"), "", "plain = stays Variant")
	check(not r.scope.has("i"), "loop var not visible after loop")
	var r2 := _resolver_at("res://main.gd", "_ready", "print(i)")
	check_eq(r2.scope.get("i"), "int", "range() loop var")
	var r3 := _resolver_at("res://main.gd", "_ready", "child.look_at")
	check_eq(r3.scope.get("child"), "Node3D", "typed loop var")
	check_eq(r.self_type, "res://main.gd")
	check_eq(r.member_type("Node3D", "position"), "Vector3")
	check_eq(r.member_type("Vector3", "x"), "float")


func test_search_custom_class_funcs_first_then_inherited_engine() -> void:
	var ms := MemberSearch.new(idx)
	var c := ms.for_output("Player", "p")
	check(c.size() > 50, "includes engine members")
	# Player's own methods come first, most used first.
	check_eq(c[0].label, "take_damage()")
	check_eq(c[0].group_label, "Player")
	var first_non_method := -1
	var first_engine := -1
	for i in c.size():
		if c[i].group == 0 and c[i].kind != "method" and first_non_method < 0:
			first_non_method = i
		if c[i].group_label != "Player" and first_engine < 0:
			first_engine = i
	for i in first_non_method:
		check_eq(c[i].kind, "method", "funcs before vars/signals in own group")
	check_eq(c[first_engine].group_label, "CharacterBody3D", "nearest engine ancestor next")
	check_eq(c[0].code, "p.take_damage()")


func test_search_inherited_project_class_before_engine() -> void:
	var ms := MemberSearch.new(idx)
	var groups := []
	for cand in ms.for_output("Boss", "b"):
		if groups.is_empty() or groups[-1] != cand.group_label:
			groups.append(cand.group_label)
	check_eq(groups.slice(0, 3), ["Boss", "Player", "CharacterBody3D"])


func test_search_recency_breaks_ties() -> void:
	var ms := MemberSearch.new(idx)
	var heal: ProjectIndex.Member = idx.classes["Player"].members["heal"]
	var spawn: ProjectIndex.Member = idx.classes["Player"].members["spawn"]
	check_eq(idx.frequency(spawn), 0)
	idx.recent[spawn.key()] = Time.get_unix_time_from_system()
	var labels := ms.for_output("Player", "p").map(func(x): return x.label)
	check(labels.find("spawn()") < labels.find("_init()") or labels.find("_init()") < 0, "recent before unused")
	check(labels.find("heal()") < labels.find("spawn()"), "usage beats recency")
	idx.recent.clear()


func test_search_variant_ranks_by_usage() -> void:
	var ms := MemberSearch.new(idx)
	var c := ms.for_output("", "mixed")
	check(c.size() > 0, "has results")
	check_eq(c[0].label, "take_damage()", "most used member first")


func test_search_static_access() -> void:
	var ms := MemberSearch.new(idx)
	var c := ms.for_output("type:Player", "Player")
	check_eq(c[0].label, "new")
	var labels := c.map(func(x): return x.label)
	check(labels.has("spawn()"), "static func")
	check(not labels.has("heal()"), "no instance methods on the class itself")


func test_search_input_producers() -> void:
	var ms := MemberSearch.new(idx)
	var r := _resolver_at("res://main.gd", "_ready", "position.x")
	var labels := ms.for_input("int", r).map(func(x): return x.label)
	check(labels.has("hp"), "int local")
	check(not labels.has("up"), "Vector3 local excluded")
	var v := ms.for_input("Vector3", r).map(func(x): return x.label)
	check(v.has("up"), "Vector3 local")
	check(v.has("Vector3()"), "constructor")
	check(v.has("UP"), "constant")
	var p := ms.for_input("Player", r).map(func(x): return x.label)
	check(p.has("p") and p.has("b"), "subclass is assignable")


func test_fuzzy_filter() -> void:
	var ms := MemberSearch.new(idx)
	var c := MemberSearch.filter(ms.for_output("Player", "p"), "tdmg")
	check(c.size() > 0 and c[0].label == "take_damage()", "subsequence match")
	var h := MemberSearch.filter(ms.for_output("Player", "p"), "heal")
	check_eq(h[0].label, "heal()", "exact first")


func test_graph_annotation() -> void:
	var sf: ScriptFile = idx.files["res://main.gd"]
	var f := sf.find_function("_ready")
	var g := FunctionGraph.build(sf, f)
	TypeResolver.new(idx, idx.class_of_function(sf, f), sf).annotate(g)
	var s := g.get_stmt("1") # p.take_damage(5)
	check_eq(s.get_field("arg0").label, "amount")
	check_eq(s.get_field("arg0").expect_type, "int")
	check_eq(s.get_field("arg1").label, "source?", "placeholder for missing arg")
	check_eq(s.get_data_out("result").type, "int")
	check_eq(g.get_stmt("0").data_outs[0].type, "Player")
	check(g.get_stmt("3").get_data_out("result") == null, "void call has no result pin")
	check_eq(g.get_stmt("entry").data_outs[0].type, "res://main.gd")


func test_reindex_after_edit() -> void:
	var sf: ScriptFile = idx.files["res://boss.gd"]
	var at := byte_of(sf.doc, "func enrage")
	sf.apply_edits([{ start = at, end = at, text = "func roar(volume: float) -> String:\n\treturn \"\"\n\n" }], false)
	idx.reindex_file("res://boss.gd")
	check(idx.classes["Boss"].members.has("roar"), "new func indexed")
	check_eq(idx.classes["Boss"].parent, "Player")
	check_eq(idx.usage_typed.get("Player.take_damage", 0), 5, "usage not double counted")
