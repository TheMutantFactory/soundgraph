extends Node
## Plays one song of a score: a SoundGraph engine per instrument, the MIDI clock, and
## everything that makes one play-through differ from the next within the score's bounds.
##
## Per track, each update:
##   1. the track as it plays now: its part's overrides laid over it (score_doc.resolve)
##   2. notes due since the last update go to the instrument playing now; a note-off goes
##      to whichever instrument took its note-on, so a switch never strands a held note
##   3. the instrument may change: when its hold (change.min_bars..max_bars, drawn at
##      random) runs out, or when the part's list no longer includes it, at the first
##      moment the track holds no notes
##   4. every varied control glides toward a random target inside [min, max] at a random
##      speed inside [rate_min, rate_max] (fractions of that span per bar); a ramp on the
##      same control wins over its vary
##   5. the phrase: an A/B pattern in beats, half bars or bars that drops the track out
##      and brings it back, with a cut or a ramp each way
##
## advance(seconds) is the whole clock, called from _process when playing for real and
## directly by the tests, so a take is a function of the seed and the time steps alone.
## Nothing here draws; the window reads track_state() to show what is happening.

const ScoreDoc := preload("res://score/score_doc.gd")
const MidiTracks := preload("res://score/midi_tracks.gd")

const MIX_RATE := 48000.0
const BUFFER_S := 0.1
## The engine of an instrument that has not played for this long is not run (its player
## plays silence), which keeps a track with eight candidate instruments cheap.
const IDLE_S := 4.0
## Each patch's held middle C is brought to this peak before gain_db, so gain_db is a mix
## choice and not a patch's quirk (as FFFF's music box does).
const NORM_PEAK := 0.25
const SILENT_DB := -80.0

signal song_ended

## No AudioStreamPlayers: the tests, and anything that renders by hand.
var headless := false
## The level of everything, in dB, on top of each track's.
var volume_db := 0.0

var doc: Dictionary = {}
var score_dir := ""
var song: Dictionary = {}
var midi = null
var playing := false
var status := ""

## Elapsed play time in beats (never wraps) and the song position in beats (wraps when
## the whole song loops). Bars, parts, phrases and ramps read the position.
var elapsed_beats := 0.0
var position_beats := 0.0

var _tracks: Array = []         # per score track: its state (below)
var _song_ticks := 0            # the song's length, rounded up to a bar
var _engines := {}              # patch|preset -> {engine, text, controls}: shared parse
var _norm_cache := {}
var _solo := -1


func _process(delta: float) -> void:
	if playing:
		advance(delta)
	_fill()


func _exit_tree() -> void:
	teardown()


# ------------------------------------------------------------------ loading

## Loads song `index` of `score`, ready to play from the top. False (and status says why)
## when its MIDI cannot be read; a patch that fails to load leaves that instrument silent.
func load_song(score: Dictionary, dir: String, index: int) -> bool:
	stop()
	_drop_all()
	doc = score
	score_dir = dir
	var songs: Array = doc.get("songs", [])
	if index < 0 or index >= songs.size():
		status = "no song %d" % index
		return false
	song = songs[index]
	midi = MidiTracks.read(ScoreDoc.resolve_path(dir, String(song.get("midi", ""))))
	if midi == null:
		status = "%s is not a MIDI file this can play" % String(song.get("midi", ""))
		return false
	var tpb: float = midi.ticks_per_bar()
	_song_ticks = int(ceil(midi.length_ticks() / tpb) * tpb)
	status = ""
	for t: Dictionary in song.get("tracks", []):
		_tracks.append(_new_track(t))
	rewind()
	return true


func _new_track(t: Dictionary) -> Dictionary:
	var mt: Dictionary = midi.track(int(t.get("track", -1)))
	var st := {"def": t, "midi": mt, "pos": 0, "tick": 0.0, "done": mt.is_empty(),
		"instruments": {}, "current": "", "held": {}, "next_change": INF, "walks": {},
		"rng": RandomNumberGenerator.new(), "level": 1.0, "gain_db": 0.0, "mute": false,
		"tails": []}
	return st


## Back to the top, with the same seed: the same take again.
func rewind() -> void:
	elapsed_beats = 0.0
	position_beats = 0.0
	var seed := int(doc.get("seed", 1))
	for st: Dictionary in _tracks:
		_release_all(st)
		st["pos"] = 0
		st["tick"] = 0.0
		st["done"] = (st["midi"] as Dictionary).is_empty()
		st["held"] = {}
		st["walks"] = {}
		st["tails"] = []
		st["rng"].seed = hash([seed, String(song.get("id", "")), int(st["def"].get("track", 0))])
		st["current"] = ""
		var r := ScoreDoc.resolve(song, st["def"], 1.0)
		_switch(st, r, _pick(st, r, ""))
		_schedule_change(st, r)


func play() -> void:
	if midi != null:
		playing = true


func stop() -> void:
	playing = false
	for st: Dictionary in _tracks:
		_release_all(st)


func is_loaded() -> bool:
	return midi != null


func beats_per_bar() -> float:
	return float(midi.beats_per_bar) * 4.0 / float(midi.beat_unit) if midi != null else 4.0


## The bar playing now, counted from 1 (fractional).
func bar() -> float:
	return 1.0 + position_beats / beats_per_bar()


func length_bars() -> float:
	return _song_ticks / midi.ticks_per_bar() if midi != null else 0.0


func seconds() -> float:
	return elapsed_beats * 60.0 / midi.bpm() if midi != null else 0.0


# ------------------------------------------------------------------ the clock

func advance(dt: float) -> void:
	if midi == null or dt <= 0.0:
		return
	var dbeats: float = dt * midi.bpm() / 60.0
	var dticks: float = dbeats * midi.division
	var before_bar := bar()
	elapsed_beats += dbeats
	position_beats += dbeats
	var whole_loop := _whole_song_loops()
	var song_beats: float = float(_song_ticks) / midi.division
	if whole_loop and song_beats > 0.0 and position_beats >= song_beats:
		position_beats = fposmod(position_beats, song_beats)
	var now_bar := bar()
	var dbars: float = dbeats / beats_per_bar()
	for i in _tracks.size():
		var st: Dictionary = _tracks[i]
		var r := ScoreDoc.resolve(song, st["def"], now_bar)
		_step_notes(i, st, dticks, whole_loop)
		_maybe_change(st, r, before_bar, now_bar)
		_walk(st, r, dbars, now_bar)
		st["level"] = _phrase_level(r)
		_apply_gain(st)
	if not whole_loop and _all_done():
		playing = false
		song_ended.emit()


func _whole_song_loops() -> bool:
	if not bool(song.get("loop", true)):
		return false
	for st: Dictionary in _tracks:
		if int((st["midi"] as Dictionary).get("loop_end", -1)) >= 0:
			return false            # the tracks loop on their own markers
	return true


func _all_done() -> bool:
	for st: Dictionary in _tracks:
		if not st["done"]:
			return false
	return true


## The track's notes up to its new tick. A track loops between its own markers, or with
## the whole song (from 0 to the song's length, rounded up to a bar) when it has none.
func _step_notes(i: int, st: Dictionary, dticks: float, whole_loop: bool) -> void:
	if st["done"]:
		return
	var mt: Dictionary = st["midi"]
	var ev: Array = mt["events"]
	var ls := int(mt["loop_start"])
	var le := int(mt["loop_end"])
	if le < 0 and whole_loop:
		ls = 0
		le = _song_ticks
	if le >= 0 and not bool(song.get("loop", true)):
		le = -1
	var t: float = st["tick"] + dticks
	while true:
		var limit: float = t
		if le >= 0 and t >= le:
			limit = le
		while st["pos"] < ev.size() and ev[st["pos"]][0] < limit:
			var e: Array = ev[st["pos"]]
			_note(st, int(e[1]), int(e[2]))
			st["pos"] += 1
		if le >= 0 and t >= le:
			_release_all(st)
			t = ls + (t - le)
			st["pos"] = _first_at(ev, ls)
			if le - ls <= 0:
				break
			continue
		break
	st["tick"] = t
	if le < 0 and st["pos"] >= ev.size():
		_release_all(st)
		st["done"] = true


func _first_at(ev: Array, tick: int) -> int:
	for k in ev.size():
		if ev[k][0] >= tick:
			return k
	return ev.size()


func _note(st: Dictionary, note: int, vel: int) -> void:
	var held: Dictionary = st["held"]
	if vel == 0:
		if held.has(note):
			var vo: Dictionary = st["instruments"].get(held[note][0], {})
			if not vo.is_empty() and vo["engine"] != null:
				vo["engine"].note_off(held[note][1])
			held.erase(note)
		return
	var key: String = st["current"]
	var vo: Dictionary = st["instruments"].get(key, {})
	if vo.is_empty() or vo["engine"] == null:
		return
	if held.has(note):
		_note(st, note, 0)
	var transpose := int(st["def"].get("transpose", 0)) + int(vo["entry"].get("transpose", 0))
	var n := clampi(note + transpose, 0, 127)
	# Each note starts on the controls' current values, not on a value from a frame ago.
	_send_values(st, vo)
	vo["engine"].note_on(n, vel / 127.0)
	vo["idle"] = 0.0
	held[note] = [key, n]


func _release_all(st: Dictionary) -> void:
	for note: int in (st["held"] as Dictionary).keys():
		_note(st, note, 0)


# ------------------------------------------------------------------ instruments

## Weighted pick from the track's list as it plays now, avoiding `not_this` when there is
## anything else to pick. "" when the list is empty.
func _pick(st: Dictionary, r: Dictionary, not_this: String) -> String:
	var list: Array = r.get("instruments", [])
	var keys: Array = []
	var weights: Array = []
	var total := 0.0
	for inst: Variant in list:
		if not (inst is Dictionary):
			continue
		var k := _key(inst)
		if k == not_this and list.size() > 1:
			continue
		var w := maxf(0.0, float(inst.get("weight", 1.0)))
		keys.append([k, inst])
		weights.append(w)
		total += w
	if keys.is_empty():
		return ""
	var x: float = st["rng"].randf() * total
	for j in keys.size():
		x -= weights[j]
		if x <= 0.0 or j == keys.size() - 1:
			_ensure(st, keys[j][1])
			return keys[j][0]
	return ""


static func _key(inst: Dictionary) -> String:
	return String(inst.get("patch", "")) + "|" + String(inst.get("preset", ""))


func _in_list(r: Dictionary, key: String) -> bool:
	for inst: Variant in r.get("instruments", []):
		if inst is Dictionary and _key(inst) == key:
			return true
	return false


func _schedule_change(st: Dictionary, r: Dictionary) -> void:
	var ch: Variant = r.get("change", null)
	if not (ch is Dictionary) or (r.get("instruments", []) as Array).size() < 2:
		st["next_change"] = INF
		return
	var lo := maxf(1.0, float(ch.get("min_bars", 8)))
	var hi := maxf(lo, float(ch.get("max_bars", lo)))
	var hold := float(st["rng"].randi_range(int(lo), int(hi)))
	st["next_change"] = floorf(elapsed_beats / beats_per_bar()) + hold


func _maybe_change(st: Dictionary, r: Dictionary, _before_bar: float, _now_bar: float) -> void:
	var cur: String = st["current"]
	var listed := not (r.get("instruments", []) as Array).is_empty()
	var out_of_list := listed and (cur == "" or not _in_list(r, cur))
	var elapsed_bar := elapsed_beats / beats_per_bar()
	var due: bool = elapsed_bar >= float(st["next_change"])
	if not (out_of_list or due):
		st.erase("wanted_since")
		return
	if not st.has("wanted_since"):
		st["wanted_since"] = elapsed_bar
	if not (st["held"] as Dictionary).is_empty():
		# Between notes only, unless the track has not rested for a whole bar since the
		# change came due: then its held notes are let go so the change happens at all.
		if elapsed_bar - float(st["wanted_since"]) < 1.0:
			return
		_release_all(st)
	st.erase("wanted_since")
	_switch(st, r, _pick(st, r, cur))
	_schedule_change(st, r)


func _switch(st: Dictionary, r: Dictionary, key: String) -> void:
	st["current"] = key
	st["walks"] = {}
	var vo: Dictionary = st["instruments"].get(key, {})
	if vo.is_empty():
		return
	_start_walks(st, r, vo)
	_send_values(st, vo)
	_apply_gain(st)


## The instrument's engine, made once per song and kept while the song plays.
func _ensure(st: Dictionary, inst: Dictionary) -> void:
	var key := _key(inst)
	if (st["instruments"] as Dictionary).has(key):
		st["instruments"][key]["entry"] = inst
		return
	var vo := {"entry": inst, "engine": null, "player": null, "playback": null,
		"controls": {}, "norm_db": 0.0, "idle": IDLE_S}
	st["instruments"][key] = vo
	var path := ScoreDoc.patch_root(doc, score_dir).path_join(String(inst.get("patch", "")))
	var text := FileAccess.get_file_as_string(path)
	if text == "" or not ClassDB.class_exists("SoundGraphEngine"):
		status = "no patch %s" % path
		return
	var engine: Object = ClassDB.instantiate("SoundGraphEngine")
	if not engine.load_patch(text, MIX_RATE):
		status = "%s did not load" % String(inst.get("patch", ""))
		return
	var patch: Variant = JSON.parse_string(text)
	if patch is Dictionary:
		for c: Variant in patch.get("controls", []):
			if c is Dictionary and c.has("target"):
				vo["controls"][String(c.get("id", ""))] = c
		var preset := String(inst.get("preset", ""))
		if preset != "":
			for p: Variant in patch.get("presets", []):
				if p is Dictionary and String(p.get("name", "")) == preset:
					var values: Dictionary = p.get("values", {})
					for id: String in values:
						if vo["controls"].has(id):
							_set_control(engine, vo["controls"][id], float(values[id]))
	vo["engine"] = engine
	vo["norm_db"] = _norm_db(engine, key)
	if not headless:
		var gen := AudioStreamGenerator.new()
		gen.mix_rate = MIX_RATE
		gen.buffer_length = BUFFER_S
		var player := AudioStreamPlayer.new()
		player.stream = gen
		player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
		player.volume_db = SILENT_DB
		add_child(player)
		player.play()
		vo["player"] = player
		vo["playback"] = player.get_stream_playback()


func _norm_db(engine: Object, key: String) -> float:
	if _norm_cache.has(key):
		return _norm_cache[key]
	engine.note_on(60, 100.0 / 127.0)
	var peak := 0.0
	for _b in 24:
		for s: Variant in engine.render_block(1024):
			peak = maxf(peak, absf(s.x) if s is Vector2 else absf(float(s)))
	engine.note_off(60)
	engine.reset()
	var db := 0.0 if peak < 0.0005 else clampf(linear_to_db(NORM_PEAK / peak), -24.0, 30.0)
	_norm_cache[key] = db
	return db


# ------------------------------------------------------------------ variation

## What a vary key moves: one of the patch's controls, a raw "node:parameter" (for a
## patch with no controls; its range is the vary's own), or the track's gain_db.
func _control_for(vo: Dictionary, key: String, bounds: Dictionary) -> Dictionary:
	if key == ScoreDoc.GAIN:
		return {"id": key, "min": -60.0, "max": 24.0, "scaling": "linear"}
	if (vo["controls"] as Dictionary).has(key):
		return vo["controls"][key]
	if key.contains(":"):
		return {"id": key, "target": {"node": key.get_slice(":", 0), "parameter": key.get_slice(":", 1)},
			"min": float(bounds.get("min", 0.0)), "max": float(bounds.get("max", 1.0)), "scaling": "linear"}
	return {}


## The bounds that apply to the playing instrument: its own vary, then the track's (the
## track's wins for a key both name, since the track is the more specific choice for a
## song), and gain_db only from the track.
func _bounds(r: Dictionary, vo: Dictionary) -> Dictionary:
	var out := {}
	var own: Variant = vo["entry"].get("vary", {})
	if own is Dictionary:
		for k: String in own:
			if k != ScoreDoc.GAIN:
				out[k] = own[k]
	var tv: Variant = r.get("vary", {})
	if tv is Dictionary:
		for k: String in tv:
			out[k] = tv[k]
	return out


func _start_walks(st: Dictionary, r: Dictionary, vo: Dictionary) -> void:
	var bounds := _bounds(r, vo)
	for k: String in bounds:
		var c := _control_for(vo, k, bounds[k])
		if c.is_empty() or not (bounds[k] is Dictionary):
			continue
		var w := {"control": c, "u": st["rng"].randf(), "target": 0.0, "speed": 0.0,
			"bounds": bounds[k]}
		_new_target(st, w)
		st["walks"][k] = w


func _new_target(st: Dictionary, w: Dictionary) -> void:
	var b: Dictionary = w["bounds"]
	var lo := maxf(0.0, float(b.get("rate_min", 0.0)))
	var hi := maxf(lo, float(b.get("rate_max", lo)))
	w["target"] = st["rng"].randf()
	w["speed"] = st["rng"].randf_range(lo, hi)


func _walk(st: Dictionary, r: Dictionary, dbars: float, now_bar: float) -> void:
	var vo: Dictionary = st["instruments"].get(st["current"], {})
	if vo.is_empty():
		return
	# A bound edited while playing (the window does this) is picked up here.
	var bounds := _bounds(r, vo)
	for k: String in (st["walks"] as Dictionary).keys():
		if not bounds.has(k):
			st["walks"].erase(k)
	for k: String in bounds:
		if not (st["walks"] as Dictionary).has(k):
			var c := _control_for(vo, k, bounds[k])
			if c.is_empty():
				continue
			var w := {"control": c, "u": st["rng"].randf(), "target": 0.0, "speed": 0.0,
				"bounds": bounds[k]}
			_new_target(st, w)
			st["walks"][k] = w
		else:
			st["walks"][k]["bounds"] = bounds[k]
	for k: String in st["walks"]:
		var w: Dictionary = st["walks"][k]
		var step := float(w["speed"]) * dbars
		var gap := float(w["target"]) - float(w["u"])
		if step <= 0.0:
			if float(w["speed"]) <= 0.0 and float(w["bounds"].get("rate_max", 0.0)) > 0.0:
				_new_target(st, w)       # a rate_min of 0 drew a rest; draw again
			continue
		if absf(gap) <= step:
			w["u"] = w["target"]
			_new_target(st, w)
		else:
			w["u"] = float(w["u"]) + signf(gap) * step
	# Ramps, which win over a vary on the same key.
	st["ramped"] = {}
	var ramps: Variant = r.get("ramps", {})
	if ramps is Dictionary:
		for k: String in ramps:
			st["ramped"][k] = ScoreDoc.ramp_value(ramps[k], now_bar)
	_send_values(st, vo)


## The value a walk stands for now, in the control's units, inside both the vary's bounds
## and the control's declared range.
func walk_value(w: Dictionary) -> float:
	var c: Dictionary = w["control"]
	var b: Dictionary = w["bounds"]
	var cmin := float(c.get("min", -INF))
	var cmax := float(c.get("max", INF))
	var lo := clampf(float(b.get("min", cmin)), cmin, cmax)
	var hi := clampf(float(b.get("max", cmax)), lo, cmax)
	var u := clampf(float(w["u"]), 0.0, 1.0)
	if String(c.get("scaling", "linear")) == "exponential" and lo > 0.0 and hi > 0.0:
		return exp(lerpf(log(lo), log(hi), u))
	return lerpf(lo, hi, u)


func _send_values(st: Dictionary, vo: Dictionary) -> void:
	if vo["engine"] == null:
		return
	var ramped: Dictionary = st.get("ramped", {})
	for k: String in st["walks"]:
		if k == ScoreDoc.GAIN or ramped.has(k):
			continue
		var w: Dictionary = st["walks"][k]
		_set_control(vo["engine"], w["control"], walk_value(w))
	for k: String in ramped:
		if k == ScoreDoc.GAIN:
			continue
		var c := _control_for(vo, k, {"min": -INF, "max": INF})
		if not c.is_empty():
			_set_control(vo["engine"], c, clampf(float(ramped[k]), float(c.get("min", -INF)), float(c.get("max", INF))))


func _set_control(engine: Object, c: Dictionary, value: float) -> void:
	var t: Dictionary = c.get("target", {})
	if t.is_empty():
		return
	engine.set_parameter(String(t.get("node", "")), String(t.get("parameter", "")), value)


# ------------------------------------------------------------------ phrase and level

## 0..1: how much of the track the phrase lets through now.
func _phrase_level(r: Dictionary) -> float:
	var ph: Variant = r.get("phrase", null)
	if not (ph is Dictionary):
		return 1.0
	return phrase_level_at(ph, position_beats, beats_per_bar(), float(r.get("_part_from", 1.0)))


## A phrase's level at `beats` into the song: 1 on an A step, 0 on a B step, and between
## them while a ramp runs. A ramp starts where the run of A (or B) steps starts, and lasts
## `ramp` units. The pattern is laid from its from_bar (the part's start when it belongs
## to a part), and the song before that plays as written.
static func phrase_level_at(ph: Dictionary, beats: float, bpb: float, part_from: float) -> float:
	var steps := ScoreDoc.pattern_steps(String(ph.get("pattern", "")))
	if steps.is_empty():
		return 1.0
	var unit := ScoreDoc.unit_beats(String(ph.get("unit", "bar")), bpb)
	var from_bar := float(ph.get("from_bar", part_from))
	var u := (beats - (from_bar - 1.0) * bpb) / unit
	if u < 0.0:
		return 1.0
	var n := steps.size()
	var k := int(floor(u))
	var on: bool = steps[k % n]
	var s := k
	var looked := 0
	while s > 0 and bool(steps[(s - 1) % n]) == on and looked < n:
		s -= 1
		looked += 1
	if looked >= n:
		return 1.0 if on else 0.0          # all A, or all B
	var run := u - s
	var length := maxf(0.0, float(ph.get("ramp", 1.0)))
	if on:
		if s > 0 and String(ph.get("in", "cut")) == "ramp" and length > 0.0:
			return clampf(run / length, 0.0, 1.0)
		return 1.0
	if s > 0 and String(ph.get("out", "cut")) == "ramp" and length > 0.0:
		return clampf(1.0 - run / length, 0.0, 1.0)
	return 0.0


func _apply_gain(st: Dictionary) -> void:
	var r_db := float(st["def"].get("gain_db", 0.0))
	var walks: Dictionary = st["walks"]
	var ramped: Dictionary = st.get("ramped", {})
	if ramped.has(ScoreDoc.GAIN):
		r_db += float(ramped[ScoreDoc.GAIN])
	elif walks.has(ScoreDoc.GAIN):
		r_db += walk_value(walks[ScoreDoc.GAIN])
	st["gain_db"] = r_db
	var level: float = st["level"]
	var silent: bool = st["mute"] or (_solo >= 0 and _tracks[_solo] != st)
	for key: String in st["instruments"]:
		var vo: Dictionary = st["instruments"][key]
		if vo["player"] == null:
			continue
		if key != st["current"] and float(vo["idle"]) >= IDLE_S:
			continue
		var db := volume_db + r_db + float(vo["entry"].get("gain_db", 0.0)) + float(vo["norm_db"])
		if silent or level <= 0.001:
			db = SILENT_DB
		else:
			db += linear_to_db(level)
		vo["player"].volume_db = maxf(db, SILENT_DB)


# ------------------------------------------------------------------ the window's hooks

func track_count() -> int:
	return _tracks.size()


## What the window shows for track i: {"current" (patch|preset), "part", "level" (0..1),
## "gain_db", "values": {key: value now}, "held": note count}.
func track_state(i: int) -> Dictionary:
	if i < 0 or i >= _tracks.size():
		return {}
	var st: Dictionary = _tracks[i]
	var values := {}
	for k: String in st["walks"]:
		values[k] = walk_value(st["walks"][k])
	for k: String in st.get("ramped", {}):
		values[k] = st["ramped"][k]
	return {"current": st["current"], "level": st["level"], "gain_db": st["gain_db"],
		"values": values, "held": (st["held"] as Dictionary).size(),
		"part": String(ScoreDoc.part_at(song, bar()).get("name", ""))}


## The controls of an instrument of track i, by id ({} until it has been loaded).
func controls_of(i: int, key: String) -> Dictionary:
	if i < 0 or i >= _tracks.size():
		return {}
	return (_tracks[i]["instruments"].get(key, {}) as Dictionary).get("controls", {})


func set_mute(i: int, on: bool) -> void:
	if i >= 0 and i < _tracks.size():
		_tracks[i]["mute"] = on
		_apply_gain(_tracks[i])


func set_solo(i: int) -> void:
	_solo = i
	for st: Dictionary in _tracks:
		_apply_gain(st)


## Plays the given instrument on track i now (the window's audition), then lets the score
## take over again at its next change.
func force_instrument(i: int, inst: Dictionary) -> void:
	if i < 0 or i >= _tracks.size():
		return
	var st: Dictionary = _tracks[i]
	_release_all(st)
	_ensure(st, inst)
	_switch(st, ScoreDoc.resolve(song, st["def"], bar()), _key(inst))


## The track definitions changed in the window: their new fields are used from the next
## update, and an instrument no longer listed is left at the next rest.
func refresh() -> void:
	for st: Dictionary in _tracks:
		var r := ScoreDoc.resolve(song, st["def"], bar())
		for inst: Variant in r.get("instruments", []):
			if inst is Dictionary:
				_ensure(st, inst)
		_apply_gain(st)


# ------------------------------------------------------------------ audio

func _fill() -> void:
	for st: Dictionary in _tracks:
		for key: String in st["instruments"]:
			var vo: Dictionary = st["instruments"][key]
			if vo["engine"] == null:
				continue
			if (st["held"] as Dictionary).is_empty() or key != st["current"]:
				vo["idle"] = float(vo["idle"]) + get_process_delta_time()
			if float(vo["idle"]) >= IDLE_S and key != st["current"]:
				continue
			var pb = vo["playback"]
			if pb == null:
				continue
			var n: int = pb.get_frames_available()
			if n > 0:
				vo["engine"].fill_playback(pb, n)


## Lets go of every engine and player. Call before the tree goes: an extension object
## alive when the extension unloads crashes on exit (editor-godot/harness_exit.gd).
func teardown() -> void:
	stop()
	_drop_all()


func _drop_all() -> void:
	for st: Dictionary in _tracks:
		for key: String in st["instruments"]:
			var vo: Dictionary = st["instruments"][key]
			if vo["player"] != null:
				AudioServer.lock()
				vo["player"].stop()
				vo["player"].stream = null
				AudioServer.unlock()
				remove_child(vo["player"])
				vo["player"].free()
			vo["player"] = null
			vo["playback"] = null
			vo["engine"] = null
	_tracks.clear()
	midi = null
