extends Node
## Autoload: global game state.

const EnemyScene = preload("res://actors/enemy.gd")

var player: Player
var score := 0
var _spawn_timer := Timer.new()


func _ready() -> void:
	add_child(_spawn_timer)
	_spawn_timer.timeout.connect(func(): spawn_enemy(Vector3.ZERO))
	_spawn_timer.start(3.0)


func register_player(p: Player) -> void:
	player = p
	player.died.connect(_on_player_died)


func add_score(points: int) -> void:
	score += points
	print("score: ", score)


func spawn_enemy(at: Vector3) -> Enemy:
	var e := Enemy.new()
	e.position = at
	add_child(e)
	return e


func _on_player_died(cause: String) -> void:
	print("Game over: ", cause)
	get_tree().reload_current_scene()
