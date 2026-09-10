extends RefCounted
## The editor's line to embedded/axoloti/tools/hw.py: start it, ask whether it is still
## going, read what it wrote.
##
## The tool runs as its own process and reports through run/axoloti-status.json rather
## than a pipe, for the reason the gate does: a flash is minutes of compiling and card
## writing, and the editor should keep drawing while it happens. `runner`, when set,
## stands in for the process — the suite gives it a Callable that writes the status file
## itself, so scan and flash can be exercised without a board, a compiler, or Python.

var runner: Callable
var _pid := -1


static func repo_root() -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").simplify_path()


static func status_path() -> String:
	return repo_root().path_join("run/axoloti-status.json")


static func tool_path() -> String:
	return repo_root().path_join("embedded/axoloti/tools/hw.py")


## The rig's own venv when it has been made, else whatever `python` is on the path.
static func python_path() -> String:
	var venv := repo_root().path_join("embedded/axoloti/.venv")
	for candidate in ["Scripts/python.exe", "bin/python3", "bin/python"]:
		var python := venv.path_join(candidate)
		if FileAccess.file_exists(python):
			return python
	return "python3" if OS.get_name() != "Windows" else "python"


## Starts the tool with `args`. The old status file goes first, so a stale "done" is
## never read as this run's.
func start(args: Array) -> bool:
	if FileAccess.file_exists(status_path()):
		DirAccess.remove_absolute(status_path())
	if runner.is_valid():
		runner.call(args)
		return true
	var arguments: Array[String] = [tool_path()]
	for arg in args:
		arguments.append(str(arg))
	_pid = OS.create_process(python_path(), PackedStringArray(arguments))
	return _pid > 0


func running() -> bool:
	if runner.is_valid():
		return false
	return _pid > 0 and OS.is_process_running(_pid)


## What the tool has written so far, or {} before it has written anything.
func status() -> Dictionary:
	var file := FileAccess.open(status_path(), FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}
