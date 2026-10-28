class_name SearchPanel
extends Panel3D
## The drag-off menu: ranked candidates with a fuzzy filter on top.

signal chosen(candidate: MemberSearch.Candidate)
signal cancelled

const MAX_SHOWN := 120

var _all: Array = []
var _shown: Array = [] ## Item index -> Candidate (null for group headers)
var _filter: LineEdit
var _list: ItemList
var _allow_custom := false


## With `allow_custom`, whatever is typed in the filter can be picked as is.
func open(title: String, candidates: Array, allow_custom := false) -> void:
	_all = candidates
	_allow_custom = allow_custom
	var pc := PanelContainer.new()
	pc.theme = Panel3D.make_theme()
	var vb := VBoxContainer.new()
	pc.add_child(vb)
	var tl := Label.new()
	tl.text = title
	tl.add_theme_color_override("font_color", Color(0.7, 0.8, 1.0))
	vb.add_child(tl)
	_filter = LineEdit.new()
	_filter.placeholder_text = "filter…"
	_filter.text_changed.connect(func(_t): _refresh())
	_filter.text_submitted.connect(func(_t): _choose_selected())
	_filter.gui_input.connect(_on_filter_input)
	vb.add_child(_filter)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_activated.connect(func(i): _choose(i))
	_list.item_clicked.connect(func(i, _pos, _btn): _choose(i))
	vb.add_child(_list)
	setup_panel(pc, Vector2(0.62, 0.72))
	_refresh()
	_filter.grab_focus.call_deferred()


func _refresh() -> void:
	var filtered := MemberSearch.filter(_all, _filter.text)
	var typed := _filter.text.strip_edges()
	if _allow_custom and not typed.is_empty() and (filtered.is_empty() or filtered[0].label != typed):
		var custom := MemberSearch.Candidate.new()
		custom.label = typed
		custom.detail = "(use as typed)"
		custom.expr = typed
		custom.group_label = "Typed"
		filtered.push_front(custom)
	_list.clear()
	_shown.clear()
	var last_group := ""
	for c in filtered.slice(0, MAX_SHOWN):
		if c.group_label != last_group and _filter.text.is_empty():
			last_group = c.group_label
			var hi := _list.add_item("— %s —" % last_group)
			_list.set_item_disabled(hi, true)
			_list.set_item_selectable(hi, false)
			_list.set_item_custom_fg_color(hi, Color(0.55, 0.65, 0.85))
			_shown.append(null)
		var text: String = c.label + ("    " + c.detail if not c.detail.is_empty() else "")
		var i := _list.add_item(text)
		_list.set_item_tooltip(i, c.code if not c.code.is_empty() else c.expr)
		_shown.append(c)
	for i in _shown.size():
		if _shown[i] != null:
			_list.select(i)
			break


func _on_filter_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed:
		var step := 0
		if ev.keycode == KEY_DOWN:
			step = 1
		elif ev.keycode == KEY_UP:
			step = -1
		if step != 0:
			var sel := _list.get_selected_items()
			var i: int = sel[0] if sel.size() > 0 else -1
			i += step
			while i >= 0 and i < _shown.size() and _shown[i] == null:
				i += step
			if i >= 0 and i < _shown.size():
				_list.select(i)
				_list.ensure_current_is_visible()
			_filter.accept_event()


func _choose_selected() -> void:
	var sel := _list.get_selected_items()
	if sel.size() > 0:
		_choose(sel[0])


func _choose(i: int) -> void:
	if i >= 0 and i < _shown.size() and _shown[i] != null:
		chosen.emit(_shown[i])
