class_name Pointer
extends RefCounted
## A ray that can hover, press, drag and grab: the mouse on desktop, each
## controller in VR. Interaction turns pointer state into ix_* calls on the
## object behind the hit collider, so every feature works the same way with
## either input.

var id := ""
var is_xr := false
var origin := Vector3.ZERO
var direction := Vector3.FORWARD
var transform := Transform3D.IDENTITY ## Camera / controller transform.
var max_distance := 30.0

var pressed := false ## Trigger or left mouse button.
var gripping := false ## Grip button (VR): only ever moves / scales the world.
var scroll := 0.0 ## Accumulated wheel / stick push-pull for this frame.

# Managed by Interaction:
var hover: Object
var hit := {} ## {position, normal, collider, distance} of the current hover.
var capture: Object ## Receives drag/release until the button goes up.
var was_pressed := false
var was_gripping := false
var press_time := 0
var press_point := Vector3.ZERO
var last_click_time := -10000
var last_click_target: Object
var moved_since_press := 0.0


func point_at(distance: float) -> Vector3:
	return origin + direction * distance
