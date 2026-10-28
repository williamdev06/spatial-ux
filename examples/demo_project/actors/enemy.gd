class_name Enemy
extends CharacterBody3D

@export var damage := 5
var hp := 30
var _cooldown := 0.0


func _ready() -> void:
	add_to_group("enemies")


func _process(delta: float) -> void:
	_cooldown -= delta
	var player := Game.player
	if player == null:
		return
	look_at(player.global_position, Vector3.UP)
	if _cooldown <= 0.0 and global_position.distance_to(player.global_position) < 2.0:
		player.take_damage(damage, self)
		_cooldown = 1.0


func hit(amount: int, from: Player) -> void:
	hp -= amount
	if hp <= 0:
		Game.add_score(10)
		queue_free()
	else:
		from.take_damage(1, self) # thorns
