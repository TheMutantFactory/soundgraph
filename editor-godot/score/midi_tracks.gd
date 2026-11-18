extends RefCounted
## Reads a Standard MIDI File with its tracks kept apart, for a score.
##
## midi_import.gd is the piano roll's reader: it merges every track into one tune for one
## patch, which is the right reading for the roll and the wrong one here — a score gives
## each track its own instruments, so the tracks have to survive the reading. This is that
## other reading. It was ported from FFFF's music box sequencer (viewer/native/
## MidiSequencer.gd), which already played FF1's songs a channel at a time.
##
## What it keeps: note-ons and note-offs per track, each track's name and first channel,
## the first tempo, the first time signature, and "loopStart" / "loopEnd" markers per
## track (a track with both loops between them on its own; FFFF's exporter writes them).
## What it steps over: controllers, pitch bend, sysex, every other meta event.
##
## Drums are kept. The roll drops channel ten because one pitched instrument playing a
## drum map is noise; here a drum track can be given a drum patch.
##
## It refuses quietly — parse() returns false — for anything that is not SMF format 0 or 1
## with a ticks-per-beat division.

## Every track with at least one note, in file order:
## {"index": chunk index in the file, "name", "channel" (0-15, -1 none),
##  "events": [[tick, note, velocity 0-127 (0 = off)], ...] sorted by tick,
##  "loop_start", "loop_end" (ticks, -1 = none), "end" (tick of the last event)}
var tracks: Array = []
var division := 480
var tempo_us := 500000.0
var beats_per_bar := 4
var beat_unit := 4
## The first track's name when it carries no notes (format 1's conductor track).
var title := ""


static func read(path: String):
	var m = load("res://score/midi_tracks.gd").new()
	if not m.parse(FileAccess.get_file_as_bytes(path)):
		return null
	return m


func parse(b: PackedByteArray) -> bool:
	tracks.clear()
	title = ""
	if b.size() < 14 or b.slice(0, 4).get_string_from_ascii() != "MThd":
		return false
	var format := (b[8] << 8) | b[9]
	var ntracks := (b[10] << 8) | b[11]
	division = (b[12] << 8) | b[13]
	if format > 1 or division == 0 or (division & 0x8000) != 0:
		return false
	var at := 8 + ((b[4] << 24) | (b[5] << 16) | (b[6] << 8) | b[7])
	var tempo_seen := false
	var meter_seen := false
	for t in ntracks:
		if at + 8 > b.size() or b.slice(at, at + 4).get_string_from_ascii() != "MTrk":
			return false
		var length := (b[at + 4] << 24) | (b[at + 5] << 16) | (b[at + 6] << 8) | b[at + 7]
		var c := at + 8
		var end := mini(c + length, b.size())
		var tr := {"index": t, "name": "", "channel": -1, "events": [],
			"loop_start": -1, "loop_end": -1, "end": 0}
		var tick := 0
		var running := 0
		while c < end:
			var r := _vlq(b, c)
			tick += r[0]
			c = r[1]
			if c >= end:
				break
			var st: int = b[c]
			if st >= 0x80:
				c += 1
			else:
				if running == 0:
					return false
				st = running
			match st & 0xF0:
				0x80, 0x90:
					running = st
					if c + 1 >= end:
						break
					var note: int = b[c]
					var vel: int = b[c + 1]
					c += 2
					if st & 0xF0 == 0x80:
						vel = 0
					if tr["channel"] < 0:
						tr["channel"] = st & 0x0F
					tr["events"].append([tick, note, vel])
				0xA0, 0xB0, 0xE0:
					running = st
					c += 2
				0xC0, 0xD0:
					running = st
					c += 1
				0xF0:
					running = 0
					if st == 0xFF:
						var kind: int = b[c]
						var lr := _vlq(b, c + 1)
						var data := b.slice(lr[1], lr[1] + lr[0])
						c = lr[1] + lr[0]
						match kind:
							0x51:
								if not tempo_seen and data.size() == 3:
									tempo_us = float((data[0] << 16) | (data[1] << 8) | data[2])
									tempo_seen = true
							0x58:
								if not meter_seen and data.size() >= 2:
									beats_per_bar = maxi(1, data[0])
									beat_unit = 1 << clampi(data[1], 0, 4)
									meter_seen = true
							0x03:
								tr["name"] = data.get_string_from_ascii()
							0x06:
								var text := data.get_string_from_ascii()
								if text == "loopStart":
									tr["loop_start"] = tick
								elif text == "loopEnd":
									tr["loop_end"] = tick
					else:
						var sr := _vlq(b, c)
						c = sr[1] + sr[0]
				_:
					return false
		tr["end"] = tick
		at = end
		if tr["events"].is_empty():
			if tracks.is_empty() and title == "":
				title = tr["name"]
			continue
		if tr["loop_end"] <= tr["loop_start"]:
			tr["loop_start"] = -1
			tr["loop_end"] = -1
		# A note-on and its off on the same tick: offs first, so a repeated note retriggers.
		tr["events"].sort_custom(func(x: Array, y: Array) -> bool:
			return x[0] < y[0] or (x[0] == y[0] and x[2] == 0 and y[2] != 0))
		tracks.append(tr)
	return not tracks.is_empty()


## Ticks in one bar, from the time signature.
func ticks_per_bar() -> float:
	return division * beats_per_bar * 4.0 / beat_unit


## Beats per minute, from the first tempo.
func bpm() -> float:
	return 60000000.0 / tempo_us


## The track whose chunk index is `index`, or {}.
func track(index: int) -> Dictionary:
	for tr: Dictionary in tracks:
		if int(tr["index"]) == index:
			return tr
	return {}


## Where the whole song ends: the last event of any track, in ticks.
func length_ticks() -> int:
	var n := 0
	for tr: Dictionary in tracks:
		n = maxi(n, int(tr["end"]))
	return n


static func _vlq(b: PackedByteArray, c: int) -> Array:
	var v := 0
	while c < b.size():
		var x: int = b[c]
		c += 1
		v = (v << 7) | (x & 0x7F)
		if x & 0x80 == 0:
			break
	return [v, c]
