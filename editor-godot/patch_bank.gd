extends RefCounted
## An ordered list of patches for a board's card: what Flash writes.
##
## The file is schema/bank.schema.json. Entry order is MIDI Program Change order —
## program 0 is the first entry, and the first entry is what the board boots into — so
## the list is a set list, and moving an entry is the point of editing one. Patch paths
## are kept relative to the bank file when the patch lives under it, so a folder with a
## bank and its patches can be moved or handed over whole; anything elsewhere stays
## absolute.
##
## Entry names mirror tools/bake-bank.py's sanitizer exactly, because the name becomes a
## directory on a FAT card and the baker refuses duplicates: the same rule here means the
## editor never writes a bank the baker turns down.

const SCHEMA_VERSION := 1
const EXTENSION := "json"

var path := ""
var name := ""
var target := "axoloti"
## Which controller the set's knobs and pads are numbered for; a note, not a rule.
var controller := ""
## How the board answers a Program Change: "midi" loads the entry the number names;
## "prev-next" makes program 0 the previous entry, 1 the next and 2 the first, for a
## controller with eight program pads and a bank of two hundred.
var program_change := "midi"
## The MIDI notes that walk the bank on the board ({"previous": n, "next": n}, each a
## note or a list of them), or empty: the patches never hear them. Two pads on a
## controller with no spare buttons, on whichever pad bank it is switched to.
var navigation_notes := {}
var entries: Array[Dictionary] = []


## The baker's rule: letters, digits, - and _; everything else becomes -.
static func sanitize(wanted: String) -> String:
	var clean := ""
	for character in wanted:
		var code := character.unicode_at(0)
		var alnum := (code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
			or (code >= 97 and code <= 122)
		clean += character if alnum or character == "-" or character == "_" else "-"
	return clean


## The path to store: relative when the patch sits under the bank's folder.
static func relative_path(bank_dir: String, patch_path: String) -> String:
	var folder := bank_dir.simplify_path().rstrip("/")
	var file := patch_path.simplify_path()
	if folder != "" and file.begins_with(folder + "/"):
		return file.substr(folder.length() + 1)
	return file


## Reads a bank file. Returns "" or what went wrong.
func load_file(from: String) -> String:
	var file := FileAccess.open(from, FileAccess.READ)
	if file == null:
		return "could not open %s" % from
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		return "%s is not a bank: not a JSON object" % from.get_file()
	var data: Dictionary = parsed
	if int(data.get("schema_version", 0)) != SCHEMA_VERSION:
		return "%s is not a bank: schema_version must be %d" % [from.get_file(), SCHEMA_VERSION]
	path = from
	name = str(data.get("name", from.get_file().get_basename()))
	target = str(data.get("target", "axoloti"))
	controller = str(data.get("controller", ""))
	program_change = str(data.get("program_change", "midi"))
	navigation_notes = {}
	var notes: Variant = data.get("navigation_notes", null)
	if notes is Dictionary and notes.has("previous") and notes.has("next"):
		navigation_notes = {"previous": _notes_of(notes["previous"]), "next": _notes_of(notes["next"])}
	entries.clear()
	for entry in data.get("entries", []):
		if entry is Dictionary and entry.has("patch"):
			entries.append({
				"name": sanitize(str(entry.get("name", str(entry["patch"]).get_file().get_basename()))),
				"patch": str(entry["patch"]),
			})
	return ""


## A note stays a number; a list of notes stays a list of numbers.
static func _notes_of(value: Variant) -> Variant:
	if value is Array:
		var notes: Array = []
		for n in value:
			notes.append(int(n))
		return notes
	return int(value)


func to_json() -> String:
	var data := {
		"schema_version": SCHEMA_VERSION,
		"name": name,
		"target": target,
	}
	if controller != "":
		data["controller"] = controller
	if program_change != "midi":
		data["program_change"] = program_change
	if not navigation_notes.is_empty():
		data["navigation_notes"] = navigation_notes
	data["entries"] = entries
	return JSON.stringify(data, "  ") + "\n"


## Writes the bank back where it came from. Returns "" or what went wrong.
func save() -> String:
	if path == "":
		return "the bank has no file yet"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "could not write %s" % path
	file.store_string(to_json())
	file.close()
	return ""


## Adds a patch at the end and returns its index. The name is the file's stem unless one
## is given, sanitized, and made unique with -2, -3… because two entries with one name
## would be one directory on the card.
func add(patch_path: String, wanted_name := "") -> int:
	var base := sanitize(wanted_name if wanted_name != "" else patch_path.get_file().get_basename())
	if base == "":
		base = "patch"
	entries.append({
		"name": unique_name(base),
		"patch": relative_path(path.get_base_dir(), patch_path),
	})
	return entries.size() - 1


func unique_name(base: String) -> String:
	var taken := {}
	for entry in entries:
		taken[str(entry["name"])] = true
	if not taken.has(base):
		return base
	var n := 2
	while taken.has("%s-%d" % [base, n]):
		n += 1
	return "%s-%d" % [base, n]


func remove(index: int) -> void:
	if index >= 0 and index < entries.size():
		entries.remove_at(index)


## Moves an entry by `delta` places, clamped, and returns where it landed.
func move(index: int, delta: int) -> int:
	if index < 0 or index >= entries.size():
		return index
	var landing := clampi(index + delta, 0, entries.size() - 1)
	if landing == index:
		return index
	var entry: Dictionary = entries[index]
	entries.remove_at(index)
	entries.insert(landing, entry)
	return landing


## An entry's patch as an absolute path.
func resolve(index: int) -> String:
	if index < 0 or index >= entries.size():
		return ""
	var patch := str(entries[index]["patch"])
	if patch.is_absolute_path():
		return patch
	return path.get_base_dir().path_join(patch).simplify_path()


## Which entries point at files that are not there.
func missing() -> Array[String]:
	var lost: Array[String] = []
	for index in entries.size():
		if not FileAccess.file_exists(resolve(index)):
			lost.append(str(entries[index]["name"]))
	return lost
