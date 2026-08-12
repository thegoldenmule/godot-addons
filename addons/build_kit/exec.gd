@tool
extends RefCounted

## Process runner for the build pipeline's external commands (Godot headless
## export, xcodebuild, devicectl, the ASC helper). Long commands are spawned
## detached with stdout+stderr redirected to a log file plus an exit-code
## sentinel file, so callers poll and tail — GDScript cannot interrupt a
## blocking OS.execute, so a hung xcodebuild must never ride the editor thread.
## Short probes (version checks, `defaults read`) may use the blocking run().


## Single-quote an argument for /bin/zsh.
static func quote(arg: String) -> String:
	return "'" + arg.replace("'", "'\\''") + "'"


static func command_line(args: PackedStringArray) -> String:
	var parts := PackedStringArray()
	for a in args:
		parts.append(quote(a))
	return " ".join(parts)


## Spawn a raw shell line detached; its output goes to log_path and its exit
## code to log_path + ".exit" (written last, so the sentinel's existence means
## "finished"). Returns {ok, pid, log, exit_path} or {ok:false, error}.
static func spawn_shell(shell_line: String, log_path: String) -> Dictionary:
	var exit_path := log_path + ".exit"
	DirAccess.make_dir_recursive_absolute(log_path.get_base_dir())
	if FileAccess.file_exists(exit_path):
		DirAccess.remove_absolute(exit_path)
	var f := FileAccess.open(log_path, FileAccess.WRITE)
	if f != null:
		f.close()
	# Subshell, not a brace group: an `exit` inside the command must not skip
	# the exit-code sentinel write (the sentinel's existence = "finished").
	var wrapped := "( %s ) > %s 2>&1; echo $? > %s" % [
		shell_line, quote(log_path), quote(exit_path)]
	var pid := OS.create_process("/bin/zsh", ["-lc", wrapped])
	if pid <= 0:
		return {"ok": false, "error": "failed to spawn: " + shell_line}
	return {"ok": true, "pid": pid, "log": log_path, "exit_path": exit_path, "offset": 0}


## Argv convenience over spawn_shell.
static func spawn_logged(args: PackedStringArray, log_path: String) -> Dictionary:
	return spawn_shell(command_line(args), log_path)


## The sentinel file's existence is the completion signal; -1 means still
## running (or killed before the shell could write it).
static func exit_code(exit_path: String) -> int:
	if not FileAccess.file_exists(exit_path):
		return -1
	var f := FileAccess.open(exit_path, FileAccess.READ)
	if f == null:
		return -1
	return int(f.get_as_text().strip_edges())


static func is_running(pid: int) -> bool:
	return pid > 0 and OS.is_process_running(pid)


## Kill the spawned shell AND its children (xcodebuild is a child of the zsh
## wrapper; OS.kill alone would orphan it, not stop it).
static func kill_tree(pid: int) -> void:
	if pid <= 0:
		return
	var out: Array = []
	OS.execute("/bin/zsh", ["-c", "pkill -TERM -P %d; kill -TERM %d" % [pid, pid]], out, true)


## Incremental log tail: read from byte offset, return {text, offset}.
static func read_from(log_path: String, offset: int) -> Dictionary:
	var f := FileAccess.open(log_path, FileAccess.READ)
	if f == null:
		return {"text": "", "offset": offset}
	var length := f.get_length()
	if offset >= length:
		return {"text": "", "offset": offset}
	f.seek(offset)
	var bytes := f.get_buffer(length - offset)
	return {"text": bytes.get_string_from_utf8(), "offset": length}


static func read_all(log_path: String) -> String:
	var f := FileAccess.open(log_path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


## Blocking run for sub-second probes ONLY (version checks, defaults read).
## Returns {code, output}.
static func run(args: PackedStringArray) -> Dictionary:
	var out: Array = []
	var code := OS.execute("/bin/zsh", ["-lc", command_line(args)], out, true)
	var text := ""
	for chunk in out:
		text += str(chunk)
	return {"code": code, "output": text}
