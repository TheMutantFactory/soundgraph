extends Control
## The score window: a playlist of songs, and for the song playing, a row per track with
## its instruments, its phrase and the bounds its controls drift inside.
##
## It edits the score document in place (score_doc.gd's dictionaries, shared with the
## player by reference), so a change is heard on the next update without restarting the
## song. "Editing" picks what an edit lands on: the whole song, or one of its parts — a
## part's edit is an override, made on first touch from what the song has.
##
## Opened from the editor's File > Open score…, or on its own:
##   godot --path editor-godot res://score/score.tscn -- --score <file> [--song <id>]
## (tools/score.sh does that.)

const ScoreDoc := preload("res://score/score_doc.gd")
const ScorePlayer := preload("res://score/score_player.gd")
const MidiTracks := preload("res://score/midi_tracks.gd")

const WHOLE := "Whole song"
const MUTED := Color(0.62, 0.64, 0.7)
const LIT := Color(0.55, 0.85, 1.0)

## True in the tests: the player makes no AudioStreamPlayers.
var headless_audio := false

var doc: Dictionary = {}
var path := ""
var player: Node
var song_index := -1
var editing := WHOLE                       # WHOLE or a part name

var song_list: ItemList
var track_rows: VBoxContainer
var _title: Label
var _where: Label
var _play_btn: Button
var _seed: SpinBox
var _target_pick: OptionButton
var _errors: Label
var _open_dialog: FileDialog
var _save_dialog: FileDialog
var _midi_dialog: FileDialog
var _catalogue: Dictionary = {}            # folder -> [relative patch paths]
var _patch_cache: Dictionary = {}          # relative path -> parsed patch
var _selected: Dictionary = {}             # track index -> instrument index being edited
var _open_bounds: Dictionary = {}          # track index -> bounds shown
var _live: Array = []                      # per row: {level, now, dots: {key: RangeBar}}
var _stopped := true


class RangeBar:
	extends Control
	## A control's whole range, its allowed [min, max] as a band, and where it is now.
	var lo := 0.0
	var hi := 1.0
	var vmin := 0.0
	var vmax := 1.0
	var now := NAN
	var exponential := false

	func _init() -> void:
		custom_minimum_size = Vector2(120, 14)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _x(v: float) -> float:
		var u := 0.0
		if exponential and lo > 0.0 and hi > lo and v > 0.0:
			u = (log(v) - log(lo)) / (log(hi) - log(lo))
		elif hi > lo:
			u = (v - lo) / (hi - lo)
		return clampf(u, 0.0, 1.0) * size.x

	func _draw() -> void:
		var h := size.y
		draw_rect(Rect2(0, h * 0.4, size.x, h * 0.2), Color(1, 1, 1, 0.15))
		var a := _x(vmin)
		var b := _x(vmax)
		draw_rect(Rect2(a, h * 0.2, maxf(2.0, b - a), h * 0.6), Color(0.4, 0.7, 1.0, 0.45))
		if not is_nan(now):
			draw_circle(Vector2(_x(now), h * 0.5), h * 0.35, Color(1, 1, 1))


func _ready() -> void:
	if player == null:
		_make_player()
	_build()
	var args := OS.get_cmdline_user_args()
	var i := args.find("--score")
	if i >= 0 and i + 1 < args.size():
		open_score(args[i + 1])
		var j := args.find("--song")
		if j >= 0 and j + 1 < args.size():
			for k in (doc.get("songs", []) as Array).size():
				if String(doc["songs"][k].get("id", "")) == args[j + 1]:
					select_song(k)
					play()


func _make_player() -> void:
	player = ScorePlayer.new()
	player.headless = headless_audio
	add_child(player)
	player.song_ended.connect(func() -> void:
		step_song(1)
		play())


func _exit_tree() -> void:
	if player != null:
		player.teardown()


# ------------------------------------------------------------------ the document

func open_score(p: String) -> bool:
	var r := ScoreDoc.read(p)
	if (r["doc"] as Dictionary).is_empty():
		_say("; ".join(r["errors"]))
		return false
	doc = r["doc"]
	path = p
	_after_load(r["errors"])
	return true


func new_score() -> void:
	doc = ScoreDoc.blank()
	path = ""
	_after_load([])


func _after_load(errors: Array) -> void:
	if player == null:
		_make_player()
	player.stop()
	_catalogue = _scan_patches()
	_title.text = String(doc.get("name", "Score"))
	_seed.set_value_no_signal(int(doc.get("seed", 1)))
	_say("" if errors.is_empty() else "; ".join(errors))
	_fill_playlist()
	song_index = -1
	if not (doc.get("songs", []) as Array).is_empty():
		select_song(0)
	else:
		_rebuild_rows()


func _dir() -> String:
	return path.get_base_dir() if path != "" else ProjectSettings.globalize_path("res://").path_join("../examples/scores").simplify_path()


func save_to(p: String) -> bool:
	# Paths in the score are relative to it, so a save somewhere else moves them along.
	var from := _dir()
	var to := p.get_base_dir()
	if from.simplify_path() != to.simplify_path():
		for s: Dictionary in doc.get("songs", []):
			s["midi"] = ScoreDoc.relative_to(to, ScoreDoc.resolve_path(from, String(s.get("midi", ""))))
		var pr := String(doc.get("patch_root", ""))
		if pr != "":
			doc["patch_root"] = ScoreDoc.relative_to(to, ScoreDoc.resolve_path(from, pr))
	var ok := ScoreDoc.write(doc, p)
	if ok:
		path = p
		player.score_dir = _dir()
	_say("saved %s" % p.get_file() if ok else "could not write %s" % p)
	return ok


func add_song_from_midi(midi_path: String) -> bool:
	var m = MidiTracks.read(midi_path)
	if m == null:
		_say("%s is not a MIDI file this can read" % midi_path.get_file())
		return false
	var base := midi_path.get_file().get_basename().to_lower().replace(" ", "-")
	var id := base
	var n := 2
	var taken := {}
	for s: Dictionary in doc.get("songs", []):
		taken[String(s.get("id", ""))] = true
	while taken.has(id):
		id = "%s-%d" % [base, n]
		n += 1
	var first := "first-synth.json"
	var s := ScoreDoc.song_from_midi(m, ScoreDoc.relative_to(_dir(), midi_path), id, first)
	if not doc.has("songs"):
		doc["songs"] = []
	doc["songs"].append(s)
	_fill_playlist()
	select_song(doc["songs"].size() - 1)
	return true


# ------------------------------------------------------------------ transport

func select_song(i: int) -> void:
	var songs: Array = doc.get("songs", [])
	if i < 0 or i >= songs.size():
		return
	var was_playing: bool = player.playing
	song_index = i
	song_list.select(i)
	editing = WHOLE
	_selected.clear()
	if not player.load_song(doc, _dir(), i):
		_say(player.status)
	elif player.status != "":
		_say(player.status)
	_fill_targets()
	_rebuild_rows()
	if was_playing:
		play()


func step_song(d: int) -> void:
	var n := (doc.get("songs", []) as Array).size()
	if n == 0:
		return
	select_song(posmod(song_index + d, n))


func play() -> void:
	if song_index < 0:
		if (doc.get("songs", []) as Array).is_empty():
			return
		select_song(0)
	player.play()
	_play_btn.text = "⏸"


func pause() -> void:
	player.stop()
	_play_btn.text = "▶"


func reroll() -> void:
	doc["seed"] = randi() % 100000
	_seed.set_value_no_signal(int(doc["seed"]))
	_restart()


func _restart() -> void:
	if song_index >= 0:
		var was: bool = player.playing
		player.stop()
		player.rewind()
		if was:
			player.play()


# ------------------------------------------------------------------ editing helpers

func _song() -> Dictionary:
	return doc["songs"][song_index] if song_index >= 0 else {}


func _track(i: int) -> Dictionary:
	return _song()["tracks"][i]


## The dictionary an edit to track i lands on: the track, or its override for the part
## being edited (made on first touch). `key` is copied in from the track when the
## override does not have it yet, so the edit starts from what plays.
func _target(i: int, key: String) -> Dictionary:
	var t := _track(i)
	if editing == WHOLE:
		return t
	if not (t.get("parts", null) is Dictionary):
		t["parts"] = {}
	if not (t["parts"].get(editing, null) is Dictionary):
		t["parts"][editing] = {}
	var o: Dictionary = t["parts"][editing]
	if key != "" and not o.has(key) and t.has(key):
		o[key] = t[key].duplicate(true) if (t[key] is Dictionary or t[key] is Array) else t[key]
	return o


## The track as the edit target sees it: the song's, or with the part laid over.
func _view(i: int) -> Dictionary:
	if editing == WHOLE:
		return _track(i)
	var from := 1.0
	for p: Variant in _song().get("parts", []):
		if p is Dictionary and String(p.get("name", "")) == editing:
			from = float(p.get("from_bar", 1.0))
	return ScoreDoc.resolve(_song(), _track(i), from)


func _instruments(i: int, for_edit: bool) -> Array:
	var t := _target(i, "instruments") if for_edit else _view(i)
	if not (t.get("instruments", null) is Array):
		t["instruments"] = []
	return t["instruments"]


func _changed(structural := false) -> void:
	player.refresh()
	if structural:
		_rebuild_rows()


## Turns phrase step `step` of track i on or off (making a four-step bar phrase, all on,
## when the track has none).
func toggle_phrase_step(i: int, step: int) -> void:
	var t := _target(i, "phrase")
	if not (t.get("phrase", null) is Dictionary):
		t["phrase"] = {"unit": "bar", "pattern": "AAAA", "in": "cut", "out": "cut", "ramp": 1}
	var ph: Dictionary = t["phrase"]
	var steps := ScoreDoc.pattern_steps(String(ph.get("pattern", "")))
	while steps.size() <= step:
		steps.append(true)
	steps[step] = not steps[step]
	ph["pattern"] = _spell(steps)
	_changed(true)


static func _spell(steps: Array) -> String:
	var s := ""
	for k in steps.size():
		if k > 0 and k % 4 == 0:
			s += " "
		s += "A" if steps[k] else "B"
	return s


# ------------------------------------------------------------------ building the UI

func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.1, 0.13)
	bg.add_theme_stylebox_override("panel", sb)
	add_child(bg)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	margin.add_child(outer)

	var head := HBoxContainer.new()
	outer.add_child(head)
	_title = Label.new()
	_title.text = "Score"
	_title.add_theme_font_size_override("font_size", 20)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	head.add_child(_button("New", "A score with no songs", new_score))
	head.add_child(_button("Open…", "Open a .score.json", func() -> void: _open_dialog.popup_centered_ratio(0.6)))
	head.add_child(_button("Save", "Save the score", func() -> void:
		if path == "":
			_save_dialog.popup_centered_ratio(0.6)
		else:
			save_to(path)))
	head.add_child(_button("Save as…", "Save the score somewhere else", func() -> void: _save_dialog.popup_centered_ratio(0.6)))
	head.add_child(_button("Add song…", "A song from a MIDI file: a row per track", func() -> void: _midi_dialog.popup_centered_ratio(0.6)))

	var body := HSplitContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(body)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 220
	body.add_child(left)
	var pl := Label.new()
	pl.text = "Playlist"
	pl.add_theme_color_override("font_color", MUTED)
	left.add_child(pl)
	song_list = ItemList.new()
	song_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	song_list.item_selected.connect(func(i: int) -> void: select_song(i))
	left.add_child(song_list)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 6)
	body.add_child(right)
	var transport := HBoxContainer.new()
	transport.add_theme_constant_override("separation", 6)
	right.add_child(transport)
	transport.add_child(_button("⏮", "The song before", func() -> void: step_song(-1)))
	_play_btn = _button("▶", "Play or pause", func() -> void:
		if player.playing:
			pause()
		else:
			play())
	_play_btn.custom_minimum_size.x = 40
	transport.add_child(_play_btn)
	transport.add_child(_button("⏭", "The song after", func() -> void: step_song(1)))
	transport.add_child(_button("⟲", "From the top, the same take", _restart))
	var sl := Label.new()
	sl.text = "Seed"
	transport.add_child(sl)
	_seed = SpinBox.new()
	_seed.min_value = 0
	_seed.max_value = 99999
	_seed.tooltip_text = "The same seed plays the same take"
	_seed.value_changed.connect(func(v: float) -> void:
		doc["seed"] = int(v)
		_restart())
	transport.add_child(_seed)
	transport.add_child(_button("🎲", "A new take: a new seed, from the top", reroll))
	_where = Label.new()
	_where.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_where.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	transport.add_child(_where)
	var el := Label.new()
	el.text = "Editing"
	transport.add_child(el)
	_target_pick = OptionButton.new()
	_target_pick.tooltip_text = "What an edit changes: the whole song, or one part of it (an override)"
	_target_pick.item_selected.connect(func(k: int) -> void:
		editing = _target_pick.get_item_text(k)
		_rebuild_rows())
	transport.add_child(_target_pick)

	_errors = Label.new()
	_errors.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_errors.add_theme_color_override("font_color", Color(1.0, 0.75, 0.5))
	right.add_child(_errors)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	track_rows = VBoxContainer.new()
	track_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	track_rows.add_theme_constant_override("separation", 8)
	scroll.add_child(track_rows)

	_open_dialog = _dialog(FileDialog.FILE_MODE_OPEN_FILE, "Open score", ["*.score.json, *.json ; Scores"])
	_open_dialog.file_selected.connect(func(p: String) -> void: open_score(p))
	_save_dialog = _dialog(FileDialog.FILE_MODE_SAVE_FILE, "Save score", ["*.score.json ; Scores"])
	_save_dialog.file_selected.connect(func(p: String) -> void: save_to(p))
	_midi_dialog = _dialog(FileDialog.FILE_MODE_OPEN_FILE, "Add a song from MIDI", ["*.mid, *.midi ; MIDI"])
	_midi_dialog.file_selected.connect(func(p: String) -> void: add_song_from_midi(p))


func _dialog(mode: int, title: String, filters: Array) -> FileDialog:
	var d := FileDialog.new()
	d.file_mode = mode
	d.access = FileDialog.ACCESS_FILESYSTEM
	d.title = title
	d.filters = PackedStringArray(filters)
	d.current_dir = ProjectSettings.globalize_path("res://").path_join("../examples").simplify_path()
	add_child(d)
	return d


func _button(text: String, tip: String, then: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.pressed.connect(then)
	return b


func _small(text: String, colour := MUTED) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", colour)
	return l


func _spin(v: float, lo: float, hi: float, step: float, tip: String, then: Callable, w := 72.0) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.allow_greater = true
	s.allow_lesser = true
	s.set_value_no_signal(v)
	s.tooltip_text = tip
	s.custom_minimum_size.x = w
	s.value_changed.connect(then)
	return s


func _say(text: String) -> void:
	if _errors:
		_errors.text = text


func _fill_playlist() -> void:
	song_list.clear()
	for s: Dictionary in doc.get("songs", []):
		song_list.add_item(String(s.get("title", s.get("id", "?"))))


func _fill_targets() -> void:
	_target_pick.clear()
	_target_pick.add_item(WHOLE)
	for p: Variant in _song().get("parts", []):
		if p is Dictionary:
			_target_pick.add_item(String(p.get("name", "")))
	_target_pick.select(0)


func _rebuild_rows() -> void:
	for c in track_rows.get_children():
		track_rows.remove_child(c)
		c.queue_free()
	_live.clear()
	if song_index < 0:
		return
	var tracks: Array = _song().get("tracks", [])
	for i in tracks.size():
		track_rows.add_child(_row(i))


func _row(i: int) -> Control:
	var t := _track(i)
	var v := _view(i)
	var live := {"dots": {}}
	_live.append(live)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.15, 0.15, 0.19)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)

	# Header: who, mute, solo, level, level and pitch.
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	box.add_child(head)
	var mute := CheckBox.new()
	mute.text = String(t.get("name", "Track %d" % int(t.get("track", 0))))
	mute.button_pressed = true
	mute.tooltip_text = "Untick to mute (not saved)"
	mute.toggled.connect(func(on: bool) -> void: player.set_mute(i, not on))
	mute.custom_minimum_size.x = 140
	head.add_child(mute)
	var solo := Button.new()
	solo.text = "S"
	solo.toggle_mode = true
	solo.tooltip_text = "Solo this track (not saved)"
	solo.toggled.connect(func(on: bool) -> void:
		player.set_solo(i if on else -1))
	head.add_child(solo)
	var level := ProgressBar.new()
	level.max_value = 1.0
	level.show_percentage = false
	level.custom_minimum_size = Vector2(60, 10)
	level.tooltip_text = "How much the phrase lets through now"
	head.add_child(level)
	live["level"] = level
	var now := _small("")
	now.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	now.add_theme_color_override("font_color", LIT)
	head.add_child(now)
	live["now"] = now
	head.add_child(_small("dB"))
	head.add_child(_spin(float(t.get("gain_db", 0.0)), -60, 24, 0.5, "The track's level (whole song)",
		func(x: float) -> void: t["gain_db"] = x))
	head.add_child(_small("semitones"))
	head.add_child(_spin(float(t.get("transpose", 0)), -48, 48, 1, "Transpose (whole song)",
		func(x: float) -> void: t["transpose"] = int(x), 60))

	var over: Variant = t.get("parts", {})
	if over is Dictionary and not over.is_empty():
		var bits: PackedStringArray = []
		for pn: String in over:
			if over[pn] is Dictionary and not over[pn].is_empty():
				bits.append("%s (%s)" % [pn, ", ".join(PackedStringArray(over[pn].keys()))])
		if not bits.is_empty():
			box.add_child(_small("Part overrides: " + "; ".join(bits) +
				("" if editing != WHOLE else "  · pick the part under Editing to change them")))
	box.add_child(_instrument_row(i, v, live))
	box.add_child(_change_row(i, v))
	box.add_child(_phrase_row(i, v))
	var toggle := Button.new()
	toggle.flat = true
	toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	toggle.text = ("▾ " if _open_bounds.get(i, false) else "▸ ") + "Bounds and ramps"
	toggle.tooltip_text = "How the selected instrument's controls may drift, and authored ramps"
	toggle.pressed.connect(func() -> void:
		_open_bounds[i] = not _open_bounds.get(i, false)
		_rebuild_rows())
	box.add_child(toggle)
	if _open_bounds.get(i, false):
		box.add_child(_bounds(i, v, live))
	return panel


func _instrument_row(i: int, v: Dictionary, live: Dictionary) -> Control:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 4)
	row.add_child(_small("Instruments"))
	var list: Array = v.get("instruments", [])
	var sel: int = clampi(int(_selected.get(i, 0)), 0, maxi(0, list.size() - 1))
	for k in list.size():
		var inst: Dictionary = list[k]
		var chip := Button.new()
		chip.toggle_mode = true
		chip.button_pressed = k == sel
		chip.text = String(inst.get("patch", "")).get_file().get_basename()
		if String(inst.get("preset", "")) != "":
			chip.text += " · " + String(inst["preset"])
		chip.tooltip_text = "%s\nClick to edit its bounds; ▶ plays it now" % inst.get("patch", "")
		chip.set_meta("key", ScorePlayer._key(inst))
		live.get_or_add("chips", []).append(chip)
		chip.pressed.connect(func() -> void:
			_selected[i] = k
			_rebuild_rows())
		row.add_child(chip)
		row.add_child(_spin(float(inst.get("weight", 1.0)), 0, 100, 0.5, "Weight: how often it is picked",
			func(x: float) -> void:
				_instruments(i, true)[k]["weight"] = x
				_changed(), 56))
		row.add_child(_button("▶", "Play this instrument now", func() -> void: player.force_instrument(i, inst)))
		row.add_child(_button("×", "Remove it from the list", func() -> void:
			_instruments(i, true).remove_at(k)
			_selected[i] = 0
			_changed(true)))
	var add := MenuButton.new()
	add.text = "+"
	add.tooltip_text = "Add an acceptable instrument"
	_fill_patch_menu(add.get_popup(), func(rel: String) -> void:
		_instruments(i, true).append({"patch": rel, "weight": 1})
		_selected[i] = _instruments(i, true).size() - 1
		_changed(true))
	row.add_child(add)
	return row


func _change_row(i: int, v: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var ch: Variant = v.get("change", null)
	var on := CheckBox.new()
	on.text = "Change instrument every"
	on.button_pressed = ch is Dictionary
	on.tooltip_text = "Pick another instrument from the list now and then, between notes"
	row.add_child(on)
	var lo := _spin(float(ch.get("min_bars", 8)) if ch is Dictionary else 8.0, 1, 512, 1, "At least this many bars",
		func(x: float) -> void:
			var t := _target(i, "change")
			if t.get("change", null) is Dictionary:
				t["change"]["min_bars"] = int(x)
				_changed(), 60)
	var hi := _spin(float(ch.get("max_bars", 16)) if ch is Dictionary else 16.0, 1, 512, 1, "At most this many bars",
		func(x: float) -> void:
			var t := _target(i, "change")
			if t.get("change", null) is Dictionary:
				t["change"]["max_bars"] = int(x)
				_changed(), 60)
	on.toggled.connect(func(yes: bool) -> void:
		var t := _target(i, "change")
		if yes:
			t["change"] = {"min_bars": int(lo.value), "max_bars": int(maxf(lo.value, hi.value))}
		else:
			t.erase("change")
		_changed())
	row.add_child(lo)
	row.add_child(_small("to"))
	row.add_child(hi)
	row.add_child(_small("bars"))
	return row


func _phrase_row(i: int, v: Dictionary) -> Control:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 3)
	var ph: Variant = v.get("phrase", null)
	row.add_child(_small("Phrase"))
	var unit := OptionButton.new()
	for u in ["off", "beat", "half", "bar"]:
		unit.add_item(u)
	unit.tooltip_text = "Steps of the drop-out pattern: a beat, half a bar or a bar each"
	unit.select(0 if not (ph is Dictionary) else ["off", "beat", "half", "bar"].find(String(ph.get("unit", "bar"))))
	unit.item_selected.connect(func(k: int) -> void:
		var t := _target(i, "phrase")
		if k == 0:
			t.erase("phrase")
		else:
			if not (t.get("phrase", null) is Dictionary):
				t["phrase"] = {"pattern": "AAAA", "in": "cut", "out": "cut", "ramp": 1}
			t["phrase"]["unit"] = unit.get_item_text(k)
		_changed(true))
	row.add_child(unit)
	if ph is Dictionary:
		var steps := ScoreDoc.pattern_steps(String(ph.get("pattern", "")))
		for k in steps.size():
			var cell := Button.new()
			cell.toggle_mode = true
			cell.button_pressed = steps[k]
			cell.text = "A" if steps[k] else "B"
			cell.custom_minimum_size = Vector2(26, 0)
			cell.tooltip_text = "Step %d: A plays, B drops out. Click to flip." % (k + 1)
			cell.pressed.connect(func() -> void: toggle_phrase_step(i, k))
			row.add_child(cell)
		row.add_child(_spin(steps.size(), 1, 64, 1, "Steps in the pattern", func(x: float) -> void:
			var t := _target(i, "phrase")
			var s := ScoreDoc.pattern_steps(String(t["phrase"].get("pattern", "")))
			s.resize(int(x))
			for k in s.size():
				if s[k] == null:
					s[k] = true
			t["phrase"]["pattern"] = _spell(s)
			_changed(true), 56))
		for side in ["in", "out"]:
			var o := OptionButton.new()
			o.add_item("cut " + side)
			o.add_item("ramp " + side)
			o.select(1 if String(ph.get(side, "cut")) == "ramp" else 0)
			o.tooltip_text = "Back in" if side == "in" else "Dropping out"
			o.item_selected.connect(func(k: int) -> void:
				_target(i, "phrase")["phrase"][side] = "ramp" if k == 1 else "cut"
				_changed())
			row.add_child(o)
		row.add_child(_spin(float(ph.get("ramp", 1.0)), 0, 64, 0.25, "Ramp length, in steps",
			func(x: float) -> void:
				_target(i, "phrase")["phrase"]["ramp"] = x
				_changed(), 64))
	return row


## The selected instrument's controls (and the track's gain): vary on/off, min, max, rate
## min and max (fraction of the span per bar), a ramp, and a bar showing where it is now.
func _bounds(i: int, v: Dictionary, live: Dictionary) -> Control:
	var grid := GridContainer.new()
	grid.columns = 8
	grid.add_theme_constant_override("h_separation", 6)
	for h in ["Control", "Vary", "Min", "Max", "Rate min", "Rate max", "Ramp (bar:value …)", ""]:
		grid.add_child(_small(h))
	var list: Array = v.get("instruments", [])
	var k: int = clampi(int(_selected.get(i, 0)), 0, maxi(0, list.size() - 1))
	var controls: Array = [{"id": ScoreDoc.GAIN, "label": "Track level (dB)", "min": -30.0, "max": 12.0,
		"default": 0.0, "_track": true}]
	if k < list.size():
		var patch := _patch(String(list[k].get("patch", "")))
		for c: Variant in patch.get("controls", []):
			if c is Dictionary and c.has("target"):
				controls.append(c)
	for c: Dictionary in controls:
		var id := String(c.get("id", ""))
		var on_track: bool = c.get("_track", false)
		var holder := func() -> Dictionary:
			# Where this control's vary lives: the track's for its gain, else the
			# selected instrument's entry in the list being edited.
			if on_track:
				return _target(i, "vary")
			var insts := _instruments(i, true)
			return insts[clampi(k, 0, insts.size() - 1)] if not insts.is_empty() else {}
		var cur: Dictionary = (v.get("vary", {}) if on_track else (list[k].get("vary", {}) if k < list.size() else {}))
		var b: Variant = cur.get(id, null)
		var cmin := float(c.get("min", 0.0))
		var cmax := float(c.get("max", 1.0))
		grid.add_child(_small(String(c.get("label", id)), Color(0.9, 0.9, 0.95)))
		var vary := CheckBox.new()
		vary.button_pressed = b is Dictionary
		grid.add_child(vary)
		var fields: Array = []
		var keys := ["min", "max", "rate_min", "rate_max"]
		var defaults := [-6.0, 0.0, 0.0, 0.25] if on_track else [cmin, cmax, 0.0, 0.25]
		for f in 4:
			var val := float(b.get(keys[f], defaults[f])) if b is Dictionary else float(defaults[f])
			var step := 0.01 if f >= 2 or absf(cmax - cmin) <= 10.0 else 1.0
			var key: String = keys[f]
			var s := _spin(val, -1e9, 1e9, step, "", func(x: float) -> void:
				var h: Dictionary = holder.call()
				if not (h.get("vary", null) is Dictionary) or not (h["vary"].get(id, null) is Dictionary):
					return
				h["vary"][id][key] = x
				_changed())
			s.tooltip_text = ["Lowest it may go", "Highest it may go",
				"Slowest drift: fraction of [min, max] per bar (0: may rest)",
				"Fastest drift: fraction of [min, max] per bar (0 for both: picked once, held)"][f]
			fields.append(s)
			grid.add_child(s)
		vary.toggled.connect(func(yes: bool) -> void:
			var h: Dictionary = holder.call()
			if not (h.get("vary", null) is Dictionary):
				h["vary"] = {}
			if yes:
				h["vary"][id] = {"min": fields[0].value, "max": fields[1].value,
					"rate_min": fields[2].value, "rate_max": fields[3].value}
			else:
				h["vary"].erase(id)
			_changed())
		var ramps: Dictionary = v.get("ramps", {}) if v.get("ramps", null) is Dictionary else {}
		var ramp := LineEdit.new()
		ramp.placeholder_text = "e.g. 1:%s 9:%s" % [ScoreDoc._num(cmin), ScoreDoc._num(cmax)]
		ramp.text = ScoreDoc.format_points(ScoreDoc.ramp_points(ramps[id])) if ramps.has(id) else ""
		ramp.custom_minimum_size.x = 170
		ramp.tooltip_text = "Bar:value points, glided between; a ramp wins over the vary. Empty: none."
		ramp.text_submitted.connect(func(text: String) -> void: _set_ramp(i, id, text))
		ramp.focus_exited.connect(func() -> void: _set_ramp(i, id, ramp.text))
		grid.add_child(ramp)
		var bar := RangeBar.new()
		bar.lo = cmin
		bar.hi = cmax
		bar.exponential = String(c.get("scaling", "linear")) == "exponential"
		bar.vmin = float(b.get("min", cmin)) if b is Dictionary else cmin
		bar.vmax = float(b.get("max", cmax)) if b is Dictionary else cmax
		bar.modulate.a = 1.0 if b is Dictionary else 0.35
		vary.toggled.connect(func(yes: bool) -> void: bar.modulate.a = 1.0 if yes else 0.35)
		bar.set_meta("instrument", ScorePlayer._key(list[k]) if (k < list.size() and not on_track) else "")
		grid.add_child(bar)
		live["dots"][id] = bar
	return grid


func _set_ramp(i: int, id: String, text: String) -> void:
	var t := _target(i, "ramps")
	var pts := ScoreDoc.parse_points(text)
	if not (t.get("ramps", null) is Dictionary):
		t["ramps"] = {}
	var existing: Variant = t["ramps"].get(id, null)
	if pts.is_empty():
		t["ramps"].erase(id)
	elif existing is Dictionary:
		existing["points"] = pts
	else:
		t["ramps"][id] = {"points": pts}
	_changed()


func _fill_patch_menu(menu: PopupMenu, then: Callable) -> void:
	var folders := _catalogue.keys()
	folders.sort()
	var lookup: Array = []
	for f: String in folders:
		var sub := PopupMenu.new()
		sub.name = "f_" + str(lookup.size())
		for rel: String in _catalogue[f]:
			sub.add_item(rel.get_file().get_basename(), lookup.size())
			lookup.append(rel)
		sub.id_pressed.connect(func(id: int) -> void: then.call(lookup[id]))
		menu.add_child(sub)
		menu.add_submenu_node_item(f if f != "" else "(top)", sub)


func _scan_patches() -> Dictionary:
	var root := ScoreDoc.patch_root(doc, _dir())
	var out := {}
	var top := DirAccess.open(root)
	if top == null:
		return out
	out[""] = []
	for f in top.get_files():
		if f.ends_with(".json"):
			out[""].append(f)
	for d in top.get_directories():
		var sub := DirAccess.open(root.path_join(d))
		if sub == null:
			continue
		var list: Array = []
		for f in sub.get_files():
			if f.ends_with(".json"):
				list.append(d + "/" + f)
		if not list.is_empty():
			out[d] = list
	return out


func _patch(rel: String) -> Dictionary:
	if not _patch_cache.has(rel):
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(
			ScoreDoc.patch_root(doc, _dir()).path_join(rel)))
		_patch_cache[rel] = j if j is Dictionary else {}
	return _patch_cache[rel]


# ------------------------------------------------------------------ live

func _process(_dt: float) -> void:
	if player == null or not player.is_loaded():
		if _where:
			_where.text = ""
		return
	var part := String(ScoreDoc.part_at(player.song, player.bar()).get("name", ""))
	var t: float = player.seconds()
	_where.text = "bar %.1f%s  %d:%04.1f" % [player.bar(), ("  · " + part) if part != "" else "",
		int(t) / 60, fmod(t, 60.0)]
	for i in mini(_live.size(), player.track_count()):
		var s: Dictionary = player.track_state(i)
		var live: Dictionary = _live[i]
		live["level"].value = float(s["level"])
		live["now"].text = "now: " + String(s["current"]).get_slice("|", 0).get_file().get_basename()
		for chip: Button in live.get("chips", []):
			chip.modulate = LIT if String(chip.get_meta("key")) == String(s["current"]) else Color.WHITE
		for id: String in live["dots"]:
			var bar: RangeBar = live["dots"][id]
			var inst := String(bar.get_meta("instrument", ""))
			var here: bool = s["values"].has(id) and (inst == "" or inst == s["current"])
			var v: float = float(s["values"][id]) if here else NAN
			if not (is_nan(v) and is_nan(bar.now)) and v != bar.now:
				bar.now = v
				bar.queue_redraw()
