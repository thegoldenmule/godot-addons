extends SceneTree

## Headless runner for the snapser_kit suite:
##
##   SNAPSER_OFFLINE=1 /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##       --script res://tests/snapser_kit/run_tests.gd [-- --filter=<substring>]
##
## Discovers res://tests/snapser_kit/**/test_*.gd (each extends
## snapkit_test_case.gd), runs every test_* method, prints one line per test and a
## summary, and exits 0 only if everything passed. --filter matches against
## "<file>::<test>".

const ROOT := "res://tests/snapser_kit"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var filter := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--filter="):
			filter = a.trim_prefix("--filter=")

	var passed := 0
	var failed := 0
	for path in _discover(ROOT):
		var script: Script = load(path)
		if script == null or not script.can_instantiate():
			print("FAIL %s: script failed to load" % path)
			failed += 1
			continue
		var case: Object = script.new()
		case.set("tree", self)
		for m in script.get_script_method_list():
			var mname: String = m["name"]
			if not mname.begins_with("test_"):
				continue
			var label := "%s::%s" % [path.get_file(), mname]
			if filter != "" and not label.contains(filter):
				continue
			case.set("failures", PackedStringArray())
			await case.call("before_each")
			await case.call(mname)
			await case.call("after_each")
			case.call("_free_nodes")
			var fails: PackedStringArray = case.get("failures")
			if fails.is_empty():
				passed += 1
				print("  ok   %s" % label)
			else:
				failed += 1
				print("  FAIL %s" % label)
				for f in fails:
					print("         - %s" % f)

	print("SNAPKIT TESTS: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _discover(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	var subdirs := dir.get_directories()
	var files := dir.get_files()
	files.sort()
	for f in files:
		if f.begins_with("test_") and f.ends_with(".gd"):
			out.append(dir_path.path_join(f))
	subdirs.sort()
	for d in subdirs:
		out.append_array(_discover(dir_path.path_join(d)))
	return out
