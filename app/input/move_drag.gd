class_name MoveDrag
extends RefCounted
## Moves a Node3D with a pointer.
##   ray drag (mouse / trigger): the grabbed point stays on the ray at the
##     distance it was grabbed; scrolling pushes it away or pulls it closer.
##   grip drag (VR): the object follows the controller rigidly, rotation included.

var target: Node3D
var distance := 1.0
var offset := Vector3.ZERO
var relative := Transform3D.IDENTITY
var rigid := false


static func begin(t: Node3D, p: Pointer, hit: Dictionary, grip := false) -> MoveDrag:
	var d := MoveDrag.new()
	d.target = t
	d.rigid = grip and p.is_xr
	var hp: Vector3 = hit.get("position", t.global_position)
	d.distance = maxf(0.05, p.origin.distance_to(hp))
	d.offset = t.global_position - hp
	d.relative = p.transform.affine_inverse() * t.global_transform
	return d


func update(p: Pointer) -> void:
	if not is_instance_valid(target):
		return
	if rigid:
		target.global_transform = p.transform * relative
	else:
		target.global_position = p.point_at(distance) + offset


func push(amount: float) -> void:
	distance = maxf(0.05, distance * pow(1.12, amount))
