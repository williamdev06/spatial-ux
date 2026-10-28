class_name MoveDrag
extends RefCounted
## Moves a Node3D with a pointer (mouse / trigger): the grabbed point stays on
## the ray at the distance it was grabbed; scrolling pushes it away or pulls it
## closer.

var target: Node3D
var distance := 1.0
var offset := Vector3.ZERO


static func begin(t: Node3D, p: Pointer, hit: Dictionary) -> MoveDrag:
	var d := MoveDrag.new()
	d.target = t
	var hp: Vector3 = hit.get("position", t.global_position)
	d.distance = maxf(0.05, p.origin.distance_to(hp))
	d.offset = t.global_position - hp
	return d


func update(p: Pointer) -> void:
	if not is_instance_valid(target):
		return
	target.global_position = p.point_at(distance) + offset


func push(amount: float) -> void:
	distance = maxf(0.05, distance * pow(1.12, amount))
