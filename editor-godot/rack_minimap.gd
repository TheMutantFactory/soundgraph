class_name RackMinimap
extends Control
## The rack's map: the case and its modules, small, in the corner of the rack lens, with
## the window drawn over them — and a click that puts the window there.
##
## The graph has one because GraphEdit ships one. The rack is a plain Control in a
## ScrollContainer, and at a 168 HP case on a show screen it is wider than the window
## with slack to pan into on every side, so the question "where am I on the case" is
## real. This answers it the way the graph's does: the whole thing, the bit you see,
## and a place to click.

const MAP_SIZE := Vector2(220.0, 136.0)
const INSET := 8.0

var rack: Rack
var scroll: ScrollContainer
var _dragging := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = MAP_SIZE * float(Design.SCALE_FACTORS[Design.ui_scale])


func _process(_delta: float) -> void:
	# Shown with the rack lens, and redrawn while it is: the window moves under the
	# wheel and the drag, and nothing signals that.
	var wanted: bool = scroll != null and scroll.visible and rack != null
	if wanted != visible:
		visible = wanted
	if visible:
		queue_redraw()


## Map units per rack unit: the whole case, fitted into the map with an inset.
func map_scale() -> float:
	if rack == null:
		return 0.0
	var content: Vector2 = rack.content_size()
	if content.x <= 0.0 or content.y <= 0.0:
		return 0.0
	var room := size - Vector2.ONE * INSET * 2.0
	return minf(room.x / content.x, room.y / content.y)


## Where the case sits in the map, so it is centred rather than cornered.
func _origin() -> Vector2:
	var s := map_scale()
	var content: Vector2 = rack.content_size() * s
	return (size - content) * 0.5


## The window over the case, in rack units.
func window_in_rack() -> Rect2:
	if scroll == null or rack == null:
		return Rect2()
	var zoom: float = maxf(rack.view_zoom, 0.01)
	var at := Vector2(scroll.scroll_horizontal, scroll.scroll_vertical) / zoom - rack.position
	return Rect2(at, scroll.size / zoom)


## Puts the window's centre at a map point.
func look_at_map_point(point: Vector2) -> void:
	if scroll == null or rack == null:
		return
	var s := map_scale()
	if s <= 0.0:
		return
	var zoom: float = maxf(rack.view_zoom, 0.01)
	var in_rack := (point - _origin()) / s
	var centre := (in_rack + rack.position) * zoom
	scroll.scroll_horizontal = int(centre.x - scroll.size.x * 0.5)
	scroll.scroll_vertical = int(centre.y - scroll.size.y * 0.5)


func _gui_input(event: InputEvent) -> void:
	var click := event as InputEventMouseButton
	if click != null and click.button_index == MOUSE_BUTTON_LEFT:
		_dragging = click.pressed
		if click.pressed:
			look_at_map_point(click.position)
		accept_event()
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _dragging:
		look_at_map_point(motion.position)
		accept_event()


func _draw() -> void:
	var back := Design.panel(Design.Surface.RAISED, Design.RADIUS_PANEL)
	back.bg_color = Color(back.bg_color, 0.92)
	draw_style_box(back, Rect2(Vector2.ZERO, size))
	if rack == null:
		return
	var s := map_scale()
	if s <= 0.0:
		return
	var origin := _origin()
	var content: Vector2 = rack.content_size()
	# The case: a plate the modules sit on.
	draw_rect(Rect2(origin, content * s), Color(Design.SURFACES[Design.Surface.CANVAS], 0.9))
	# The modules, each in its category's tint, dimmed: the map is a map.
	for id in rack._modules:
		var module: Control = rack._modules[id]
		if module == null:
			continue
		var tint: Color = Rack.category_tint(str(module.descriptor.get("category", "")))
		draw_rect(Rect2(origin + module.position * s, module.size * s), Color(tint, 0.55))
		draw_rect(Rect2(origin + module.position * s, module.size * s),
			Color(Design.INK_SECOND, 0.5), false, 1.0)
	# The window, over everything: what the rack lens is showing right now.
	var window := window_in_rack()
	var shown := Rect2(origin + window.position * s, window.size * s)
	draw_rect(shown, Color(Design.ACCENT, 0.12))
	draw_rect(shown, Design.ACCENT, false, 1.5)
