extends SceneTree
## Headless checks on dynamic scores: the multitrack reader, the score format, and the
## player's promises — a take is the seed's, bounds are never left, instruments change
## only when the score allows, phrases drop tracks out and bring them back, ramps land.
##
##   godot --headless --path editor-godot --script res://score_test.gd
##
## The player runs headless here (no AudioStreamPlayers) and is clocked by hand, so every
## number below is a function of the seed and the step size.

const MidiTracks := preload("res://score/midi_tracks.gd")
const ScoreDoc := preload("res://score/score_doc.gd")
const ScorePlayer := preload("res://score/score_player.gd")
const ScoreWindow := preload("res://score/score_window.gd")
const HarnessExit := preload("res://harness_exit.gd")

const DT := 1.0 / 60.0

var failures := 0
var checks := 0


func check(condition: bool, description: String) -> void:
	checks += 1
	if condition:
		print("  ok   %s" % description)
	else:
		failures += 1
		print("  FAIL %s" % description)


func repo(rel: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").path_join(rel).simplify_path()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	if not ClassDB.class_exists("SoundGraphEngine"):
		print("SoundGraphEngine is not loaded; build runtime-godot first")
		quit(1)
		return
	_midi()
	_format()
	_ramps_and_phrases()
	_determinism()
	_bounds_and_changes()
	_parts_and_phrase_in_play()
	await _window()
	print("")
	if failures == 0:
		print("all %d score checks passed" % checks)
	else:
		print("%d of %d score checks failed" % [failures, checks])
	await HarnessExit.finish(self, null, 0 if failures == 0 else 1)


# ---------------------------------------------------------------------------------------

func _midi() -> void:
	print("multitrack MIDI")
	var m = MidiTracks.read(repo("examples/midi/bach-invention-08.mid"))
	check(m != null, "the Bach invention reads")
	check(m.tracks.size() == 2, "its two voices stay two tracks (%d)" % m.tracks.size())
	check(int(m.tracks[0]["index"]) == 1 and int(m.tracks[1]["index"]) == 2,
		"tracks keep their chunk index, past the conductor track")
	check(m.beats_per_bar == 3 and m.beat_unit == 4, "the time signature comes with it (3/4)")
	check(absf(m.bpm() - 90.0) < 0.01, "and the tempo (90 bpm)")
	var ode = MidiTracks.read(repo("examples/midi/ode-to-joy.mid"))
	check(ode != null and ode.tracks.size() == 1, "a format 0 file is one track")
	check(MidiTracks.new().parse(PackedByteArray([1, 2, 3])) == false, "not MIDI is refused")
	# The music box's convention: per-track loop markers.
	var b := _smf_with_loop()
	var lm = MidiTracks.new()
	check(lm.parse(b), "a file with loop markers reads")
	check(int(lm.tracks[0]["loop_start"]) == 480 and int(lm.tracks[0]["loop_end"]) == 1920,
		"loopStart / loopEnd markers are kept per track")


## One track: a note every beat for four beats, looping between beat 1 and beat 4.
func _smf_with_loop() -> PackedByteArray:
	var events: Array = [[0, [0x90, 60, 100]], [240, [0x80, 60, 0]],
		[480, [0xFF, 0x06, 9] + Array("loopStart".to_ascii_buffer())]]
	for k in 3:
		events.append([480 * (k + 1), [0x90, 62 + k, 100]])
		events.append([480 * (k + 1) + 240, [0x80, 62 + k, 0]])
	events.append([1920, [0xFF, 0x06, 7] + Array("loopEnd".to_ascii_buffer())])
	events.append([1920, [0xFF, 0x2F, 0]])
	events.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	var t := PackedByteArray()
	var at := 0
	for e: Array in events:
		t.append_array(_vlq(e[0] - at))
		t.append_array(PackedByteArray(e[1]))
		at = e[0]
	var out := PackedByteArray("MThd".to_ascii_buffer())
	out.append_array(PackedByteArray([0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0]))
	out.append_array("MTrk".to_ascii_buffer())
	out.append_array(PackedByteArray([0, 0, (t.size() >> 8) & 0xFF, t.size() & 0xFF]))
	out.append_array(t)
	return out


func _vlq(v: int) -> PackedByteArray:
	var bytes := [v & 0x7F]
	v >>= 7
	while v > 0:
		bytes.push_front((v & 0x7F) | 0x80)
		v >>= 7
	return PackedByteArray(bytes)


func _format() -> void:
	print("the score format")
	var r := ScoreDoc.read(repo("examples/scores/demo.score.json"))
	check(r["errors"].is_empty(), "the demo score validates %s" % str(r["errors"]))
	var bad := {"schema_version": 1, "songs": [{"id": "x", "midi": "a.mid", "tracks": [
		{"track": 1, "instruments": [{"patch": "p.json", "vary": {"c": {"min": 2, "max": 1}}}],
		 "phrase": {"unit": "fortnight", "pattern": ""},
		 "change": {"min_bars": 4, "max_bars": 2},
		 "parts": {"nope": {}}}]}]}
	var e := ScoreDoc.validate(bad)
	for want in ["min above max", "phrase unit", "pattern of A", "min_bars", "part nope"]:
		var hit := false
		for line: String in e:
			hit = hit or line.contains(want)
		check(hit, "a bad score says \"%s\"" % want)
	var song: Dictionary = r["doc"]["songs"][0]
	var left: Dictionary = song["tracks"][1]
	check(ScoreDoc.resolve(song, left, 5.0)["instruments"][0]["patch"] == "synths/acid-bass.json",
		"part A plays the track's own instruments")
	check(ScoreDoc.resolve(song, left, 13.0)["instruments"][0]["patch"] == "synths/mallard.json",
		"part B plays its override")
	check(ScoreDoc.resolve(song, left, 13.0)["transpose"] == -12, "and keeps what it does not override")
	check(ScoreDoc.relative_to("C:/a/b/scores", "C:/a/b/midi/x.mid") == "../midi/x.mid",
		"paths are stored relative to the score")
	var midi = MidiTracks.read(repo("examples/midi/greensleeves.mid"))
	var made := ScoreDoc.song_from_midi(midi, "../midi/greensleeves.mid", "g", "first-synth.json")
	check((made["tracks"] as Array).size() == 2, "a song made from MIDI gets a row per track")


func _ramps_and_phrases() -> void:
	print("ramps and phrases")
	var ramp := {"points": [[1, 100], [5, 500]]}
	check(is_equal_approx(ScoreDoc.ramp_value(ramp, 0.5), 100), "a ramp holds before its first point")
	check(is_equal_approx(ScoreDoc.ramp_value(ramp, 3), 300), "and is linear between points")
	check(is_equal_approx(ScoreDoc.ramp_value(ramp, 9), 500), "and holds after its last")
	check(is_equal_approx(ScoreDoc.ramp_value({"points": [[1, 0], [3, 1]], "repeat_bars": 2}, 4), 0.5),
		"a repeating ramp starts over")
	check(is_equal_approx(ScoreDoc.ramp_value({"points": [[1, 0], [3, 1]], "curve": "step"}, 2.9), 0),
		"a step ramp jumps")
	check(ScoreDoc.parse_points("1:200 9:3000, 17.5:2") == [[1.0, 200.0], [9.0, 3000.0], [17.5, 2.0]],
		"the window's ramp spelling parses")
	check(ScoreDoc.format_points([[1.0, 200.0], [17.5, 2.0]]) == "1:200 17.5:2", "and prints back")
	check(ScoreDoc.pattern_steps("AAB- x.1 0|") == [true, true, false, false, true, false, true, false],
		"patterns read A/x/1 as on and B/-/./0 as off")
	var cut := {"unit": "bar", "pattern": "AAAB"}
	var lv := func(ph: Dictionary, bar: float) -> float:
		return ScorePlayer.phrase_level_at(ph, (bar - 1.0) * 4.0, 4.0, 1.0)
	check(lv.call(cut, 1.0) == 1.0 and lv.call(cut, 3.9) == 1.0, "A bars play")
	check(lv.call(cut, 4.0) == 0.0 and lv.call(cut, 4.99) == 0.0, "the B bar drops out")
	check(lv.call(cut, 5.0) == 1.0, "and the pattern repeats, cutting back in")
	var ramped := {"unit": "bar", "pattern": "AAAB", "in": "ramp", "out": "ramp", "ramp": 0.5}
	check(is_equal_approx(lv.call(ramped, 4.25), 0.5), "a ramp out is half-way after a quarter bar")
	check(lv.call(ramped, 4.6) == 0.0, "and silent once it has run")
	check(is_equal_approx(lv.call(ramped, 5.25), 0.5), "a ramp in rises the same way")
	check(lv.call(ramped, 1.0) == 1.0, "the song's start is not a ramp in")
	var beats := {"unit": "beat", "pattern": "AB"}
	check(lv.call(beats, 1.0) == 1.0 and lv.call(beats, 1.25) == 0.0, "beat steps are quarter notes")
	var halves := {"unit": "half", "pattern": "AB"}
	check(lv.call(halves, 1.49) == 1.0 and lv.call(halves, 1.5) == 0.0, "half steps are half bars")
	var late := {"unit": "bar", "pattern": "B", "from_bar": 3}
	check(lv.call(late, 2.0) == 1.0 and lv.call(late, 3.0) == 0.0, "a phrase starts at its from_bar")


func _player(seed := 1987, song := 0) -> Node:
	var p: Node = ScorePlayer.new()
	p.headless = true
	root.add_child(p)
	var r := ScoreDoc.read(repo("examples/scores/demo.score.json"))
	var doc: Dictionary = r["doc"].duplicate(true)
	doc["seed"] = seed
	p.load_song(doc, repo("examples/scores"), song)
	p.play()
	return p


## The instrument and every walked value of every track, once a bar for `bars` bars.
func _take(p: Node, bars: int) -> Array:
	var out: Array = []
	var per_bar: float = p.beats_per_bar() * 60.0 / p.midi.bpm()
	var steps := int(round(per_bar / DT))
	for _b in bars:
		for _s in steps:
			p.advance(DT)
		var row: Array = []
		for i in p.track_count():
			var s: Dictionary = p.track_state(i)
			row.append([s["current"], s["values"]])
		out.append(row)
	return out


func _determinism() -> void:
	print("a take is its seed's")
	var a := _player(7)
	var b := _player(7)
	var c := _player(8)
	check(a.status == "" and a.is_loaded(), "the demo's first song loads (%s)" % a.status)
	var ta := _take(a, 24)
	var tb := _take(b, 24)
	var tc := _take(c, 24)
	check(ta == tb, "the same seed plays the same take")
	check(ta != tc, "another seed plays another")
	a.rewind()
	check(_take(a, 24) == ta, "rewinding plays it again")
	for p in [a, b, c]:
		p.teardown()
		p.free()


func _bounds_and_changes() -> void:
	print("bounds and instrument changes")
	var p := _player(3)
	var song: Dictionary = p.song
	var right: Dictionary = song["tracks"][0]
	var inside := true
	var moved := false
	var first := -1.0
	var changes: Array = []          # elapsed bar of each change on the right hand
	var last: String = p.track_state(0)["current"]
	var bpb: float = p.beats_per_bar()
	for _k in int(60.0 / DT):        # a minute
		p.advance(DT)
		var s: Dictionary = p.track_state(0)
		if s["current"] != last:
			changes.append(p.elapsed_beats / bpb)
			last = s["current"]
		for inst: Dictionary in right["instruments"]:
			if ScorePlayer._key(inst) != s["current"]:
				continue
			for key: String in inst.get("vary", {}):
				if not s["values"].has(key):
					continue
				var v: float = s["values"][key]
				var b: Dictionary = inst["vary"][key]
				inside = inside and v >= float(b["min"]) - 1e-6 and v <= float(b["max"]) + 1e-6
				if key == "cutoff":
					if first < 0.0:
						first = v
					moved = moved or absf(v - first) > 1.0
	check(inside, "every varied control stays inside its bounds for a minute")
	check(moved, "and does move")
	check(changes.size() >= 3, "the right hand changes instrument mid-song (%d times)" % changes.size())
	var spaced := true
	for k in range(1, changes.size()):
		var gap: float = changes[k] - changes[k - 1]
		spaced = spaced and gap >= 4.0 - 0.01 and gap <= 8.0 + 1.0 + 0.01
	check(spaced, "no sooner than min_bars and no later than max_bars (+ a bar to find a rest)")
	var held_ok := true
	for k in p.track_count():
		held_ok = held_ok and p.track_state(k)["held"] <= 8
	check(held_ok, "no notes are stranded across changes")
	var st: Dictionary = p._tracks[0]
	var vo: Dictionary = st["instruments"][st["current"]]
	var peak := 0.0
	for s: Variant in vo["engine"].render_block(4096):
		peak = maxf(peak, absf(s.x) if s is Vector2 else absf(float(s)))
	check(peak > 0.001 or st["held"].is_empty(), "the playing instrument makes sound (peak %.3f)" % peak)
	p.teardown()
	p.free()


func _parts_and_phrase_in_play() -> void:
	print("parts, phrases and ramps in play")
	var p := _player(1, 1)                  # The Entertainer
	var bpb: float = p.beats_per_bar()
	var per_bar: float = bpb * 60.0 / p.midi.bpm()
	var at_bar := func(target: float) -> void:
		while p.bar() < target:
			p.advance(DT)
	at_bar.call(5.0)
	var cut5: float = p.track_state(0)["values"].get("cutoff", -1.0)
	check(absf(cut5 - 2300.0) < 120.0, "the right hand's cutoff ramp is about half-way at bar 5 (%d)" % cut5)
	check(p.track_state(1)["level"] == 1.0, "the left hand plays through the intro")
	at_bar.call(12.1)
	check(p.track_state(1)["part"] == "Drop", "bar 12 is in the Drop part")
	check(p.track_state(1)["level"] == 0.0, "the left hand is out on the pattern's B bar")
	at_bar.call(13.5)
	var lv: float = p.track_state(1)["level"]
	check(lv > 0.3 and lv < 0.7, "and ramping back in half a bar later (%.2f)" % lv)
	at_bar.call(14.2)
	check(p.track_state(1)["level"] == 1.0, "then fully in")
	at_bar.call(26.0)
	check(p.track_state(1)["level"] == 1.0, "the Full part has no phrase")
	var g: float = p.track_state(1)["gain_db"]
	check(g <= -2.0 + 1e-6 and g >= -5.0 - 1e-6, "the track's gain_db varies inside its bounds (%.2f)" % g)
	p.teardown()
	p.free()


func _window() -> void:
	print("the score window")
	var w: Control = ScoreWindow.new()
	w.headless_audio = true
	root.add_child(w)
	await process_frame
	check(w.open_score(repo("examples/scores/demo.score.json")), "the window opens the demo")
	await process_frame
	check(w.song_list.item_count == 2, "its playlist lists both songs")
	check(w.track_rows.get_child_count() == 2, "and a row per track")
	w.select_song(1)
	await process_frame
	check(w.player.song.get("id") == "entertainer", "picking a song loads it")
	w.toggle_phrase_step(0, 2)
	check(String(w.player.song["tracks"][0]["phrase"]["pattern"]) == "AABA",
		"clicking a phrase cell turns that step off")
	w.step_song(1)
	check(w.player.song.get("id") == "invention-8", "next wraps round the playlist")
	var out := OS.get_user_data_dir().path_join("score_test.score.json")
	w.save_to(out)
	var back := ScoreDoc.read(out)
	check(back["errors"].is_empty(), "what it saves validates")
	check(String(back["doc"]["songs"][0]["midi"]) == "../midi/bach-invention-08.mid" or
		String(back["doc"]["songs"][0]["midi"]).ends_with("bach-invention-08.mid"),
		"and still finds its MIDI")
	w.player.teardown()
	w.queue_free()
	await process_frame
