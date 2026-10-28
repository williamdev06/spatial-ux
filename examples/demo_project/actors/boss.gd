class_name Boss
extends Enemy

var phase := 1


func hit(amount: int, from: Player) -> void:
	super.hit(amount / phase, from)
	if hp < 15 and phase == 1:
		enrage()


func enrage() -> void:
	phase = 2
	damage *= 2
	await get_tree().create_timer(0.5).timeout
	scale = Vector3.ONE * 1.5
