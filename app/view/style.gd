class_name Style
## Shared look and small scene-building helpers for the 3D views.

const PIXEL := 0.0008 ## Label3D metres per font pixel.
const FONT := 30
const FONT_TITLE := 34
const FONT_SMALL := 24
const ROW := 0.04
const HEADER := 0.048
const PAD := 0.016
const PIN_R := 0.011
const UI_LAYER := 1 << 1 ## Physics layer of everything the pointer can hit.

const KIND_COLORS := {
	"entry": Color(0.55, 0.22, 0.22),
	"call": Color(0.20, 0.36, 0.60),
	"assign": Color(0.25, 0.45, 0.35),
	"var": Color(0.30, 0.48, 0.30),
	"if": Color(0.55, 0.42, 0.15),
	"for": Color(0.50, 0.30, 0.55),
	"while": Color(0.50, 0.30, 0.55),
	"return": Color(0.50, 0.22, 0.30),
	"pass": Color(0.30, 0.30, 0.32),
	"break": Color(0.40, 0.30, 0.30),
	"continue": Color(0.40, 0.30, 0.30),
	"code": Color(0.28, 0.28, 0.30),
}
const BODY_COLOR := Color(0.11, 0.12, 0.14, 0.94)
const BOARD_COLOR := Color(0.06, 0.07, 0.09, 0.55)
const TEXT := Color(0.92, 0.93, 0.95)
const TEXT_DIM := Color(0.62, 0.65, 0.70)
const FIELD_TEXT := Color(0.98, 0.86, 0.55)
const EXEC_COLOR := Color(0.95, 0.95, 0.95)
const SELECT_COLOR := Color(1.0, 0.75, 0.2)
const ERROR_COLOR := Color(1.0, 0.25, 0.25)

static var _font: Font
static var _mat_cache := {}


static func font() -> Font:
	if _font == null:
		_font = ThemeDB.fallback_font
	return _font


static func text_width(text: String, size := FONT) -> float:
	return font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x * PIXEL


static func type_color(t: String) -> Color:
	if t.is_empty():
		return Color(0.75, 0.75, 0.75)
	match t:
		"bool":
			return Color(0.85, 0.25, 0.25)
		"int":
			return Color(0.35, 0.85, 0.75)
		"float":
			return Color(0.55, 0.95, 0.35)
		"String", "StringName":
			return Color(0.95, 0.40, 0.85)
		"Vector2", "Vector3", "Vector2i", "Vector3i":
			return Color(0.95, 0.80, 0.25)
	# Stable hue per class name.
	return Color.from_hsv(fposmod(float(t.hash() % 1000) / 1000.0, 1.0), 0.55, 0.95)


static func material(color: Color, unshaded := true) -> StandardMaterial3D:
	var key := "%s|%s" % [color.to_html(), unshaded]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if color.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_cache[key] = m
	return m


static func label(text: String, size := FONT, color := TEXT) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = size
	l.pixel_size = PIXEL
	l.modulate = color
	l.outline_size = 0
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.shaded = false
	l.double_sided = true
	l.render_priority = 2
	return l


## A thin box whose top-left front corner sits at the local origin.
static func box(size: Vector2, color: Color, depth := 0.006) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(size.x, size.y, depth)
	mi.mesh = bm
	mi.position = Vector3(size.x * 0.5, -size.y * 0.5, -depth * 0.5)
	mi.material_override = material(color)
	return mi


static func sphere(radius: float, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = 12
	sm.rings = 6
	mi.mesh = sm
	mi.material_override = material(color)
	return mi


## Pointer-hittable box. Events go to `target` (see Interaction).
static func collider(target: Object, size: Vector3, center := Vector3.ZERO) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = UI_LAYER
	body.collision_mask = 0
	body.set_meta("ix", target)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	cs.position = center
	body.add_child(cs)
	return body


static func shorten(s: String, max_chars := 46) -> String:
	var one_line := s.replace("\r", "").replace("\n", " ⏎ ").replace("\t", " ")
	if one_line.length() > max_chars:
		return one_line.left(max_chars - 1) + "…"
	return one_line
