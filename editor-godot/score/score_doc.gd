extends RefCounted
## A score: songs from multitrack MIDI, with each track's instruments and how they vary.
##
## The document is plain JSON (schema/score.schema.json, explained in docs/scores.md) and
## this file only reads, checks, writes and resolves it — playing it is score_player.gd's.
## Everything is a Dictionary in the file's own shape, so what the window edits is what
## gets saved, with no second model to keep in step.
##
## Bars are counted from 1, as musicians count them, and may be fractional (bar 2.5 is
## half-way through the second bar). A part runs from its from_bar to the next part's.

const SCHEMA_VERSION := 1
const UNITS := ["beat", "half", "bar"]
const TRANSITIONS := ["cut", "ramp"]
## Not a control of any patch: the track's level, which vary and ramps may also move.
const GAIN := "gain_db"


static func blank(name := "Untitled score") -> Dictionary:
	return {"schema_version": SCHEMA_VERSION, "name": name, "seed": 1, "patch_root": "",
		"songs": []}


## Reads a score; {"doc": {...}, "errors": [...]}. A doc that fails validation is still
## returned, so the window can show what is wrong next to what is there.
static func read(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		return {"doc": {}, "errors": ["could not read %s" % path]}
	var j: Variant = JSON.parse_string(text)
	if not (j is Dictionary):
		return {"doc": {}, "errors": ["%s is not a JSON object" % path.get_file()]}
	return {"doc": j, "errors": validate(j)}


static func write(doc: Dictionary, path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(doc, "  ", false) + "\n")
	return true


## Everything wrong with a score, in words, or [] when it can be played.
static func validate(doc: Dictionary) -> Array:
	var e: Array = []
	if int(doc.get("schema_version", 0)) != SCHEMA_VERSION:
		e.append("schema_version must be %d" % SCHEMA_VERSION)
	var songs: Variant = doc.get("songs", [])
	if not (songs is Array):
		return e + ["songs must be a list"]
	var ids := {}
	for s: Variant in songs:
		if not (s is Dictionary):
			e.append("every song must be an object")
			continue
		var sd: Dictionary = s
		var where := "song %s" % String(sd.get("id", "?"))
		if String(sd.get("id", "")) == "":
			e.append("a song has no id")
		elif ids.has(sd["id"]):
			e.append("%s: the id is used twice" % where)
		ids[sd.get("id", "")] = true
		if String(sd.get("midi", "")) == "":
			e.append("%s: no midi file" % where)
		var parts: Dictionary = {}
		for p: Variant in sd.get("parts", []):
			if not (p is Dictionary) or String(p.get("name", "")) == "" or float(p.get("from_bar", 0)) < 1.0:
				e.append("%s: a part needs a name and a from_bar of 1 or more" % where)
				continue
			parts[p["name"]] = true
		for t: Variant in sd.get("tracks", []):
			if not (t is Dictionary) or not t.has("track"):
				e.append("%s: every track names its MIDI track" % where)
				continue
			var tw := "%s track %d" % [where, int(t["track"])]
			_check_track(t, tw, e)
			var over: Variant = t.get("parts", {})
			if over is Dictionary:
				for pn: String in over:
					if not parts.has(pn):
						e.append("%s: overrides part %s, which the song does not have" % [tw, pn])
					elif over[pn] is Dictionary:
						_check_track(over[pn], "%s part %s" % [tw, pn], e)
	return e


static func _check_track(t: Dictionary, where: String, e: Array) -> void:
	for inst: Variant in t.get("instruments", []):
		if not (inst is Dictionary) or String(inst.get("patch", "")) == "":
			e.append("%s: every instrument names a patch" % where)
			continue
		if float(inst.get("weight", 1.0)) < 0.0:
			e.append("%s: %s has a negative weight" % [where, inst["patch"]])
		_check_vary(inst.get("vary", {}), "%s %s" % [where, inst["patch"]], e)
	_check_vary(t.get("vary", {}), where, e)
	var ph: Variant = t.get("phrase", null)
	if ph is Dictionary:
		if not UNITS.has(String(ph.get("unit", "bar"))):
			e.append("%s: phrase unit must be beat, half or bar" % where)
		var pat := pattern_steps(String(ph.get("pattern", "")))
		if pat.is_empty():
			e.append("%s: a phrase needs a pattern of A (on) and B (off)" % where)
		for k in ["in", "out"]:
			if not TRANSITIONS.has(String(ph.get(k, "cut"))):
				e.append("%s: phrase %s must be cut or ramp" % [where, k])
	var ch: Variant = t.get("change", null)
	if ch is Dictionary:
		var lo := float(ch.get("min_bars", 0))
		var hi := float(ch.get("max_bars", lo))
		if lo < 1.0 or hi < lo:
			e.append("%s: change needs 1 <= min_bars <= max_bars" % where)
	var ramps: Variant = t.get("ramps", {})
	if ramps is Dictionary:
		for k: String in ramps:
			if ramp_points(ramps[k]).is_empty():
				e.append("%s: ramp %s has no points" % [where, k])


static func _check_vary(v: Variant, where: String, e: Array) -> void:
	if not (v is Dictionary):
		return
	for k: String in v:
		var b: Variant = v[k]
		if not (b is Dictionary) or not b.has("min") or not b.has("max"):
			e.append("%s: vary %s needs min and max" % [where, k])
			continue
		if float(b["min"]) > float(b["max"]):
			e.append("%s: vary %s has min above max" % [where, k])
		var rl := float(b.get("rate_min", 0.0))
		var rh := float(b.get("rate_max", rl))
		if rl < 0.0 or rh < rl:
			e.append("%s: vary %s needs 0 <= rate_min <= rate_max" % [where, k])


# ------------------------------------------------------------------ resolving

## The part playing at `bar`: {"name", "from_bar"}, or {} before the first part.
static func part_at(song: Dictionary, bar: float) -> Dictionary:
	var best := {}
	for p: Variant in song.get("parts", []):
		if p is Dictionary and float(p.get("from_bar", 1)) <= bar + 1e-6:
			if best.is_empty() or float(p["from_bar"]) >= float(best["from_bar"]):
				best = p
	return best


## A track as it plays at `bar`: the track's own fields with the current part's overrides
## laid over them. "_part" and "_part_from" say which part that was.
static func resolve(song: Dictionary, track: Dictionary, bar: float) -> Dictionary:
	var out := track.duplicate()
	out.erase("parts")
	var p := part_at(song, bar)
	out["_part"] = String(p.get("name", ""))
	out["_part_from"] = float(p.get("from_bar", 1.0))
	var over: Variant = track.get("parts", {})
	if over is Dictionary and over.has(out["_part"]) and over[out["_part"]] is Dictionary:
		for k: String in over[out["_part"]]:
			out[k] = over[out["_part"]][k]
	return out


## "AAAB BBAA" -> [true, true, true, false, false, false, true, true]. A, 1, x and X are
## on; B, 0, - and . are off; anything else (spaces, bar lines) is only for the eye.
static func pattern_steps(pattern: String) -> Array:
	var out: Array = []
	for ch in pattern:
		if "A1xX".contains(ch):
			out.append(true)
		elif "B0-.".contains(ch):
			out.append(false)
	return out


static func unit_beats(unit: String, beats_per_bar: float) -> float:
	match unit:
		"beat":
			return 1.0
		"half":
			return beats_per_bar / 2.0
	return beats_per_bar


## A ramp's points as [[bar, value], ...] sorted by bar. A ramp is written as that list,
## or as {"points": [...], "repeat_bars": n, "curve": "linear" | "smooth" | "step"}.
static func ramp_points(r: Variant) -> Array:
	var pts: Variant = r.get("points", []) if r is Dictionary else r
	var out: Array = []
	if pts is Array:
		for p: Variant in pts:
			if p is Array and p.size() >= 2:
				out.append([float(p[0]), float(p[1])])
			elif p is Dictionary and p.has("bar") and p.has("value"):
				out.append([float(p["bar"]), float(p["value"])])
	out.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	return out


## A ramp's value at `bar`: held before its first point and after its last, unless it
## repeats every repeat_bars from its first point.
static func ramp_value(r: Variant, bar: float) -> float:
	var pts := ramp_points(r)
	if pts.is_empty():
		return 0.0
	var curve := String(r.get("curve", "linear")) if r is Dictionary else "linear"
	var rep := float(r.get("repeat_bars", 0.0)) if r is Dictionary else 0.0
	if rep > 0.0 and bar > pts[0][0]:
		bar = pts[0][0] + fposmod(bar - pts[0][0], rep)
	if bar <= pts[0][0]:
		return pts[0][1]
	for i in range(1, pts.size()):
		if bar < pts[i][0]:
			var a: Array = pts[i - 1]
			var b: Array = pts[i]
			var u: float = (bar - a[0]) / maxf(b[0] - a[0], 1e-9)
			if curve == "step":
				return a[1]
			if curve == "smooth":
				u = u * u * (3.0 - 2.0 * u)
			return lerpf(a[1], b[1], u)
	return pts[-1][1]


## "1:200 9:3000 17:200" -> [[1, 200], [9, 3000], [17, 200]], the window's spelling.
static func parse_points(text: String) -> Array:
	var out: Array = []
	for tok in text.replace(",", " ").split(" ", false):
		var kv := tok.split(":")
		if kv.size() == 2 and kv[0].is_valid_float() and kv[1].is_valid_float():
			out.append([float(kv[0]), float(kv[1])])
	return out


static func format_points(pts: Array) -> String:
	var bits: PackedStringArray = []
	for p: Array in pts:
		bits.append("%s:%s" % [_num(p[0]), _num(p[1])])
	return " ".join(bits)


static func _num(x: float) -> String:
	return str(int(x)) if is_equal_approx(x, roundf(x)) else String.num(x, 3)


# ------------------------------------------------------------------ building

## A new song for `midi_path`: one track per MIDI track that has notes, each with the
## given instrument. The path is stored as given (the caller makes it relative).
static func song_from_midi(midi, midi_path: String, id: String, patch: String) -> Dictionary:
	var tracks: Array = []
	for tr: Dictionary in midi.tracks:
		var name := String(tr["name"])
		if name == "":
			name = "Track %d" % int(tr["index"])
		tracks.append({"track": int(tr["index"]), "name": name,
			"instruments": [{"patch": patch, "weight": 1}]})
	var title: String = midi.title if midi.title != "" else midi_path.get_file().get_basename()
	return {"id": id, "title": title, "midi": midi_path, "loop": true, "tracks": tracks}


## Where the patches named in `doc` live: its patch_root against the score's folder, or
## the repository's examples/patches when it names none.
static func patch_root(doc: Dictionary, score_dir: String) -> String:
	var r := String(doc.get("patch_root", ""))
	if r == "":
		return ProjectSettings.globalize_path("res://").path_join("../examples/patches").simplify_path()
	return (r if r.is_absolute_path() else score_dir.path_join(r)).simplify_path()


static func resolve_path(score_dir: String, rel: String) -> String:
	return (rel if rel.is_absolute_path() else score_dir.path_join(rel)).simplify_path()


## `path` relative to `dir` where it lies under it or beside it, else absolute.
static func relative_to(dir: String, path: String) -> String:
	var a := dir.simplify_path().replace("\\", "/").split("/", false)
	var b := path.simplify_path().replace("\\", "/").split("/", false)
	if a.is_empty() or b.is_empty() or a[0].to_lower() != b[0].to_lower():
		return path
	var i := 0
	while i < a.size() and i < b.size() and a[i].to_lower() == b[i].to_lower():
		i += 1
	var bits: PackedStringArray = []
	for _k in range(i, a.size()):
		bits.append("..")
	for k in range(i, b.size()):
		bits.append(b[k])
	return "/".join(bits)
