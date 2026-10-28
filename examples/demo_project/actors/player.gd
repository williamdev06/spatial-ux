class_name Player
extends CharacterBody3D
## The player character.

signal died(cause: String)
signal health_changed(value: int)

const SPEED := 5.0
const JUMP_VELOCITY := 4.5

@export var max_health: int = 100
var health: int = 100
var inventory: Array[String] = []
var target: Enemy


func _ready() -> void:
	health = max_health
	add_to_group("players")
	Game.register_player(self)


func _physics_process(delta: float) -> void:
	# Gravity first, then input.
	if not is_on_floor():
		velocity += get_gravity() * delta
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY
	var input_dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.z = move_toward(velocity.z, 0, SPEED)
	move_and_slide()


func take_damage(amount: int, source: Node = null) -> int:
	health -= amount
	health_changed.emit(health)
	if health <= 0:
		died.emit("killed by %s" % source)
		queue_free()
	return health


func heal(amount: int) -> void:
	health = mini(health + amount, max_health)
	health_changed.emit(health)


func pick_up(item: String) -> void:
	inventory.append(item)
	match item:
		"potion":
			heal(25)
		_:
			print("picked up ", item)


func attack_nearest() -> void:
	var nearest: Enemy = null
	var best := INF
	for e: Enemy in get_tree().get_nodes_in_group("enemies"):
		var d := global_position.distance_to(e.global_position)
		if d < best:
			best = d
			nearest = e
	if nearest:
		target = nearest
		target.hit(10, self)
