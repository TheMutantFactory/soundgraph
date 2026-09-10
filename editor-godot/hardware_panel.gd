extends PopupPanel
## The hardware door: what is on USB, the bank that Flash writes, and the flash as it
## happens.
##
## One panel rather than three, because the three questions are asked in a row — is the
## board there, is this the set I mean, did it take — and a person switching between
## Godot dialogs to answer them is a person who has stopped looking at the board. The
## bank list is the set list: order is Program Change order, so Up and Down are the
## real controls and everything else is bookkeeping. Main owns the file dialogs and the
## process; this panel asks for things through signals and draws what it is handed.

const PatchBank := preload("res://patch_bank.gd")

signal scan_requested
signal flash_requested
signal new_bank_requested
signal open_bank_requested
signal add_current_requested
signal add_file_requested
signal bank_edited

var bank: PatchBank
var busy := false

var board_label: Label
var scan_button: Button
var bank_label: Label
var new_button: Button
var open_button: Button
var list: ItemList
var add_current_button: Button
var add_file_button: Button
var up_button: Button
var down_button: Button
var remove_button: Button
var flash_button: Button
var progress_label: Label
var log_view: RichTextLabel
var scroller: ScrollContainer
var body: VBoxContainer


func _init() -> void:
	# Sized by the caller, not by the content: a PopupPanel that wraps its controls takes
	# its first frame's minimum — an autowrapped label at zero width is a column of
	# words — and a Window never shrinks back from that. The list flexes inside instead.
	wrap_controls = false
	size = wanted_size()
	add_theme_stylebox_override("panel",
		Design.padded_panel(Design.Surface.NODE, Design.SPACE_M, Design.SPACE_M))
	# The body scrolls when the window it was fitted into is shorter than the body:
	# rows past the bottom edge are reachable rather than gone.
	scroller = ScrollContainer.new()
	scroller.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroller)
	var box := VBoxContainer.new()
	body = box
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", Design.SPACE_S)
	scroller.add_child(box)

	var heading := Label.new()
	heading.text = "Hardware"
	heading.add_theme_font_override("font", Design.font(Design.WEIGHT_SEMIBOLD))
	heading.add_theme_font_size_override("font_size", Design.type(Design.SIZE_HEADING))
	box.add_child(heading)

	# ---- the board ----------------------------------------------------------------
	var board_row := HBoxContainer.new()
	board_row.add_theme_constant_override("separation", Design.SPACE_S)
	board_label = Label.new()
	board_label.text = "Not scanned yet."
	board_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	board_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	board_label.add_theme_color_override("font_color", Design.INK_SECOND)
	board_row.add_child(board_label)
	scan_button = Button.new()
	scan_button.text = "Scan"
	scan_button.tooltip_text = "Look for an Axoloti on USB, and what it is running"
	scan_button.pressed.connect(func() -> void: scan_requested.emit())
	board_row.add_child(scan_button)
	box.add_child(board_row)

	box.add_child(_rule())

	# ---- the bank -----------------------------------------------------------------
	var bank_row := HBoxContainer.new()
	bank_row.add_theme_constant_override("separation", Design.SPACE_S)
	bank_label = Label.new()
	bank_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bank_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	bank_row.add_child(bank_label)
	new_button = Button.new()
	new_button.text = "New bank…"
	new_button.tooltip_text = "Start an empty set list in a file of its own"
	new_button.pressed.connect(func() -> void: new_bank_requested.emit())
	bank_row.add_child(new_button)
	open_button = Button.new()
	open_button.text = "Open bank…"
	open_button.tooltip_text = "Choose the bank that Flash writes"
	open_button.pressed.connect(func() -> void: open_bank_requested.emit())
	bank_row.add_child(open_button)
	box.add_child(bank_row)

	list = ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.custom_minimum_size.y = Design.furniture_scale(160)
	list.item_selected.connect(func(_index: int) -> void: _refresh_buttons())
	box.add_child(list)

	var edit_row := HBoxContainer.new()
	edit_row.add_theme_constant_override("separation", Design.SPACE_XS)
	add_current_button = Button.new()
	add_current_button.text = "Add current patch"
	add_current_button.tooltip_text = "The patch that is open, as the next entry"
	add_current_button.pressed.connect(func() -> void: add_current_requested.emit())
	edit_row.add_child(add_current_button)
	add_file_button = Button.new()
	add_file_button.text = "Add file…"
	add_file_button.pressed.connect(func() -> void: add_file_requested.emit())
	edit_row.add_child(add_file_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit_row.add_child(spacer)
	up_button = Button.new()
	up_button.text = "Up"
	up_button.tooltip_text = "Earlier in Program Change order"
	up_button.pressed.connect(func() -> void: _move(-1))
	edit_row.add_child(up_button)
	down_button = Button.new()
	down_button.text = "Down"
	down_button.tooltip_text = "Later in Program Change order"
	down_button.pressed.connect(func() -> void: _move(1))
	edit_row.add_child(down_button)
	remove_button = Button.new()
	remove_button.text = "Remove"
	remove_button.pressed.connect(_remove)
	edit_row.add_child(remove_button)
	box.add_child(edit_row)

	box.add_child(_rule())

	# ---- the flash ----------------------------------------------------------------
	var flash_row := HBoxContainer.new()
	flash_row.add_theme_constant_override("separation", Design.SPACE_S)
	progress_label = Label.new()
	progress_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	progress_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	progress_label.add_theme_color_override("font_color", Design.INK_SECOND)
	flash_row.add_child(progress_label)
	flash_button = Button.new()
	flash_button.text = "Flash"
	flash_button.tooltip_text = "Bake every entry and write the bank to the board's card"
	flash_button.pressed.connect(func() -> void: flash_requested.emit())
	flash_row.add_child(Design.make_primary(flash_button))
	box.add_child(flash_row)

	log_view = RichTextLabel.new()
	log_view.custom_minimum_size.y = Design.furniture_scale(110)
	log_view.scroll_following = true
	log_view.selection_enabled = true
	log_view.add_theme_font_override("normal_font", Design.numeric_font())
	log_view.add_theme_font_size_override("normal_font_size",
		Design.type(Design.SIZE_SECONDARY))
	log_view.add_theme_color_override("default_color", Design.INK_SECOND)
	box.add_child(log_view)

	show_bank()


## Furniture-sized: the panel is read once and dismissed, and has to fit the window.
static func wanted_size() -> Vector2i:
	return Vector2i(Design.furniture_scale(640), Design.furniture_scale(600))


## The height the body actually wants, once it has had a frame to lay out: every row
## at its minimum, plus the panel's own padding. Asked after the first frame because
## an autowrapped label measured before layout is a column of words.
func content_height() -> int:
	if body == null:
		return wanted_size().y
	var padding := get_theme_stylebox("panel").get_minimum_size().y
	return int(body.get_combined_minimum_size().y + padding)


## Grows the window to its content when the room allows, so nothing is cut off; when
## it does not, the body scrolls.
func fit_to_content(room: Vector2, ratio: float = 0.85) -> void:
	var need := content_height()
	var allowed := int(room.y * ratio)
	var height := mini(maxi(size.y, need), allowed)
	if height != size.y:
		var was := size
		size = Vector2i(size.x, height)
		position = Vector2i(position.x, position.y - (height - was.y) / 2)


func _rule() -> HSeparator:
	var rule := HSeparator.new()
	rule.add_theme_constant_override("separation", Design.SPACE_S)
	return rule


## The last scan, in a sentence.
func show_board(report: Dictionary) -> void:
	board_label.text = describe_board(report)
	var found := bool(report.get("found", false))
	board_label.add_theme_color_override("font_color",
		Design.INK_NORMAL if found else Design.INK_SECOND)
	scan_button.text = "Connected" if found else "Scan"
	if found:
		Design.make_lit(scan_button, Design.LIVE)
	else:
		Design.make_plain(scan_button)


static func describe_board(report: Dictionary) -> String:
	if report.is_empty():
		return "Not scanned yet."
	if not bool(report.get("found", false)):
		var why := str(report.get("error", ""))
		return "No Axoloti on USB." + (" " + why if why != "" else "")
	var parts: Array[String] = []
	parts.append("Axoloti Core on USB, firmware %s%s" % [
		str(report.get("firmware", "?")),
		"" if bool(report.get("fwid_ok", true)) else " (not the 1.0.12-2 build the patches link against)"])
	parts.append("card mounted" if bool(report.get("sd_ready", false)) else "no card mounted")
	parts.append("DSP %d%%" % int(report.get("dsp_load", 0)))
	var tools: Dictionary = report.get("toolchain", {})
	if not tools.is_empty():
		var lacking: Array[String] = []
		if tools.get("compiler", null) == null:
			lacking.append("arm-none-eabi-g++")
		if not bool(tools.get("sdk", false)):
			lacking.append("the SDK")
		if not bool(tools.get("sg_validate", false)):
			lacking.append("sg-validate")
		if lacking.is_empty():
			parts.append("toolchain ready")
		else:
			parts.append("cannot flash yet: missing " + ", ".join(lacking))
	return "; ".join(parts) + "."


## The bank as it stands: file, entries, and which buttons make sense.
func show_bank() -> void:
	var kept := list.get_selected_items()
	var selected: int = kept[0] if not kept.is_empty() else -1
	list.clear()
	if bank == null:
		bank_label.text = "No bank chosen. Flash writes a bank: make one, or open one."
	else:
		bank_label.text = "%s — %s" % [bank.name, bank.path]
		bank_label.tooltip_text = bank.path
		var lost := bank.missing()
		for index in bank.entries.size():
			var entry: Dictionary = bank.entries[index]
			var text := "%d  %s    %s" % [index, str(entry["name"]), str(entry["patch"])]
			list.add_item(text)
			if lost.has(str(entry["name"])):
				list.set_item_custom_fg_color(index, Design.ERROR)
				list.set_item_tooltip(index, "This file is not there any more.")
		if selected >= 0 and selected < list.item_count:
			list.select(selected)
	_refresh_buttons()


func _refresh_buttons() -> void:
	var has_bank := bank != null
	var selected := list.get_selected_items()
	var index: int = selected[0] if not selected.is_empty() else -1
	add_current_button.disabled = not has_bank or busy
	add_file_button.disabled = not has_bank or busy
	up_button.disabled = index <= 0 or busy
	down_button.disabled = index < 0 or bank == null or index >= bank.entries.size() - 1 or busy
	remove_button.disabled = index < 0 or busy
	flash_button.disabled = not has_bank or busy or bank.entries.is_empty()
	scan_button.disabled = busy


func selected_index() -> int:
	var selected := list.get_selected_items()
	return selected[0] if not selected.is_empty() else -1


func _move(delta: int) -> void:
	if bank == null:
		return
	var index := selected_index()
	if index < 0:
		return
	var landed := bank.move(index, delta)
	show_bank()
	if landed >= 0 and landed < list.item_count:
		list.select(landed)
		_refresh_buttons()
	bank_edited.emit()


func _remove() -> void:
	if bank == null:
		return
	var index := selected_index()
	if index < 0:
		return
	bank.remove(index)
	show_bank()
	bank_edited.emit()


## The tool's status file, drawn: the step on the line and the log underneath.
func show_progress(status: Dictionary) -> void:
	if status.is_empty():
		progress_label.text = "Working…" if busy else ""
		return
	var state := str(status.get("state", ""))
	var step := str(status.get("step", ""))
	if state == "running":
		progress_label.text = step if step != "" else "Working…"
	elif state == "failed":
		progress_label.text = "Failed: %s" % str(status.get("error", "see the log"))
	elif str(status.get("action", "")) == "flash":
		progress_label.text = "Wrote %d entries to the card." % int(status.get("entries", 0)) \
			if bool(status.get("written", false)) \
			else "Baked %d entries into %s." % [int(status.get("entries", 0)), str(status.get("out_dir", ""))]
	else:
		progress_label.text = ""
	var lines: Array = status.get("log", [])
	log_view.text = "\n".join(PackedStringArray(lines.map(func(line: Variant) -> String: return str(line))))
	if state == "failed" and status.has("trace"):
		log_view.text += "\n" + str(status["trace"])


func set_busy(on: bool) -> void:
	busy = on
	_refresh_buttons()
	if on:
		log_view.text = ""
