@tool
extends RefCounted

## Process runner for the build pipeline's external commands (Godot headless
## export, xcodebuild, devicectl, adb, the ASC helper). Long commands are
## spawned detached with stdout+stderr redirected to a log file plus an
## exit-code sentinel file, so callers poll and tail — GDScript cannot
## interrupt a blocking OS.execute, so a hung xcodebuild must never ride the
## editor thread. Short probes (version checks, `defaults read`, `adb
## devices`) may use the blocking run().
##
## Shells out via cmd.exe on Windows and a POSIX shell elsewhere (zsh on
## macOS, /bin/sh on Linux — zsh isn't guaranteed there), picked per call via
## _is_windows()/_posix_shell() so every other function stays branch-free.
##
## Windows uses cmd.exe, not PowerShell: its `>`/`2>&1` is real file-handle
## redirection, immune to a lingering forked child (e.g. adb's own server)
## blocking it the way a piped capture can.

static func _is_windows() -> bool:
	return OS.get_name() == "Windows"


# zsh is macOS's default shell; elsewhere fall back to /bin/sh (POSIX and always
# present — zsh isn't guaranteed on Linux). The wrapped scripts are plain POSIX
# (subshell + `> 2>&1` + `echo $?`), so /bin/sh runs them fine.
static func _posix_shell() -> String:
	return "/bin/zsh" if OS.get_name() == "macOS" else "/bin/sh"


## Quote an argument literally for the platform's shell (POSIX ' -> '\'',
## cmd.exe " -> "").
static func quote(arg: String) -> String:
	if _is_windows():
		return '"' + arg.replace('"', '""') + '"'
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
	var pid: int
	if _is_windows():
		# A temp .bat file, not an inline /c string: cmd.exe's own ""-quoting
		# doesn't survive being re-escaped as an argv element by
		# OS.create_process. Space before the final `>` is load-bearing — a
		# bare digit right before it reads as a file-handle number, not
		# echo's argument, so it silently masks failures at exit code 0.
		var bat_path := exit_path + ".bat"
		var script := "%s > %s 2>&1\r\n(echo %%ERRORLEVEL%% > %s)\r\n" % [
			shell_line, quote(log_path), quote(exit_path)]
		var bf := FileAccess.open(bat_path, FileAccess.WRITE)
		if bf == null:
			return {"ok": false, "error": "couldn't write build script %s (err %d)" % [bat_path, FileAccess.get_open_error()]}
		bf.store_string(script)
		bf.close()
		pid = OS.create_process("cmd.exe", ["/d", "/c", bat_path])
	else:
		# Subshell, not a brace group: an `exit` inside the command must not
		# skip the exit-code sentinel write (the sentinel's existence = "finished").
		var wrapped := "( %s ) > %s 2>&1; echo $? > %s" % [
			shell_line, quote(log_path), quote(exit_path)]
		pid = OS.create_process(_posix_shell(), ["-lc", wrapped])
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


## Kill the spawned shell AND its children (xcodebuild/adb is a child of the
## shell wrapper; OS.kill alone would orphan it, not stop it).
static func kill_tree(pid: int) -> void:
	if pid <= 0:
		return
	var out: Array = []
	if _is_windows():
		# taskkill's own /T (tree) + /F (force) do this natively, no shell needed.
		OS.execute("taskkill", ["/T", "/F", "/PID", str(pid)], out, true)
	else:
		OS.execute(_posix_shell(), ["-c", "pkill -TERM -P %d; kill -TERM %d" % [pid, pid]], out, true)


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
	return {"text": strip_ansi(bytes.get_string_from_utf8()), "offset": length}


## Drops ANSI escape sequences (colour/bold codes Godot's own --headless
## export prints even into a file) so the log panel shows plain text.
static func strip_ansi(text: String) -> String:
	if text.find(char(27)) == -1:
		return text
	var re := RegEx.new()
	re.compile("\\x1b\\[[0-9;?]*[ -/]*[@-~]")
	return re.sub(text, "", true)


static func read_all(log_path: String) -> String:
	var f := FileAccess.open(log_path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


## Blocking run for sub-second probes ONLY (version checks, defaults read,
## adb devices -l). Returns {code, output}. Pass a program + args; on Windows
## the capture runs through a cmd .bat, so it can't host a nested `cmd /c "…"`.
static func run(args: PackedStringArray) -> Dictionary:
	if _is_windows():
		return _run_blocking_windows(args)
	var out: Array = []
	var code := OS.execute(_posix_shell(), ["-lc", command_line(args)], out, true)
	var text := ""
	for chunk in out:
		text += str(chunk)
	return {"code": code, "output": text}


# File redirection, not a piped OS.execute capture (see header: a piped probe
# can hang on adb's forked server); block until the .exit sentinel lands.
static func _run_blocking_windows(args: PackedStringArray) -> Dictionary:
	var log_path := OS.get_cache_dir().path_join("build_kit") \
		.path_join("probe_%d.log" % Time.get_ticks_usec())
	var h := spawn_logged(args, log_path)
	if not h["ok"]:
		return {"code": -1, "output": ""}
	while not FileAccess.file_exists(h["exit_path"]):
		OS.delay_msec(20)
	var result := {"code": exit_code(h["exit_path"]), "output": read_all(log_path)}
	DirAccess.remove_absolute(h["exit_path"])
	DirAccess.remove_absolute(h["exit_path"] + ".bat")
	DirAccess.remove_absolute(log_path)
	return result
