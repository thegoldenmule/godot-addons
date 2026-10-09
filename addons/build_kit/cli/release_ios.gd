extends SceneTree

## Headless driver for the one-command iOS TestFlight release. Launched by
## release_ios.sh (which picks the Godot binary and the project dir):
##
##   godot --headless --path <project> --script res://addons/build_kit/cli/release_ios.gd -- [flags]
##
## Runs build_kit's own BuildKitService — the same pipeline the dock drives —
## and adds what the dock leaves to a human: picking a build number App Store
## Connect hasn't seen, waiting for processing, and committing + pushing the
## next build_number. Prints one line per stage and a final summary line, and
## exits non-zero on any failure (Core.EXIT_*: 3 = uploaded and recorded, but
## processing unconfirmed). Never prints credentials: the stage shell
## lines (which carry API-key flags) stay in the logs, and everything echoed
## is passed through Core.redact().

const Core := preload("res://addons/build_kit/cli/release_core.gd")
const ServiceT := preload("res://addons/build_kit/build_kit_service.gd")
const Exec := preload("res://addons/build_kit/exec.gd")

const ASC_CALL_TIMEOUT_S := 90.0
const POLL_INTERVAL_S := 30.0

var _svc: Node
var _secrets: Array = []
var _project_dir := ""

# pipeline progress, fed by the service's signals
var _stage := ""
var _stage_started_ms := 0
var _done := false
var _result := {}
var _verified := false


func _initialize() -> void:
	Engine.max_fps = 20  # the service polls files every frame; don't spin a core
	_main.call_deferred()


func _main() -> void:
	var code: int = await _release()
	if _svc != null:
		_svc.queue_free()
	quit(code)


func _line(stage: String, status: String, detail := "") -> void:
	var text := "[%s] %s" % [stage, status]
	if detail != "":
		text += " — " + detail
	print(Core.redact(text, _secrets))


func _release() -> int:
	var opts := Core.parse_args(OS.get_cmdline_user_args())
	if opts.get("help", false):
		print(Core.USAGE)
		return 0
	if not opts["ok"]:
		printerr("release_ios: %s\n\n%s" % [opts["error"], Core.USAGE])
		return 2

	_project_dir = ProjectSettings.globalize_path("res://").rstrip("/")
	_svc = ServiceT.new()
	root.add_child(_svc)  # _ready loads build_kit.config.json
	var creds: Dictionary = _svc.asc_credentials()
	_secrets = [creds["key_id"], creds["issuer_id"], creds["key_path"]]
	_svc.stage_changed.connect(_on_stage_changed)
	_svc.build_finished.connect(_on_build_finished)

	var version := ""
	var build := 0
	var asc_state := "skipped"
	var entitlements := "not reached"
	var commit := "skipped"

	# ── preflight ──
	var preset: Dictionary = _svc.load_preset("iOS")
	if preset.is_empty():
		_line("preflight", "FAIL", "no iOS export preset in export_presets.cfg (create it in Project → Export, or use the Build Kit dock)")
		return _finish(false, version, "?", asc_state, entitlements, commit)
	version = ServiceT.marketing_version(preset, str(ProjectSettings.get_setting("application/config/version", "")))
	if opts["upload"] and not _svc.has_asc_key():
		_line("preflight", "FAIL", "no App Store Connect API key (ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH) — set it up on the Build Kit dock's ASC row, or use --no-upload")
		return _finish(false, version, "?", asc_state, entitlements, commit)
	var upstream := {}
	if opts["commit"]:
		upstream = Core.git_preflight(_git, opts["push"])
		if not upstream["ok"]:
			_line("preflight", "FAIL", str(upstream["error"]))
			return _finish(false, version, "?", asc_state, entitlements, commit)
	_line("preflight", "ok", "preset %s, version %s, upload %s, commit %s, push %s" % [
		preset["name"], version if version != "" else "(unset)", _yn(opts["upload"]), _yn(opts["commit"]), _yn(opts["push"])])

	# ── build number ──
	var config_number := int(_svc.config["ios"].get("build_number", 1))
	build = config_number
	if opts["upload"]:
		var extra := PackedStringArray(["--app-version", version]) if version != "" else PackedStringArray()
		var asc: Dictionary = await _asc_call("build-numbers", str(preset["bundle_id"]), extra)
		if not asc.get("ok", false):
			_line("build_number", "FAIL", "App Store Connect query failed: %s" % asc.get("error", "unknown"))
			return _finish(false, version, "?", asc_state, entitlements, commit)
		if not asc.get("found", false):
			_line("build_number", "FAIL", "no App Store Connect app record for the preset's bundle id — create it (My Apps → ＋ → New App) first")
			return _finish(false, version, "?", asc_state, entitlements, commit)
		var highest := int(asc.get("highest", Core.highest_build(asc.get("builds", []))))
		build = Core.pick_build_number(config_number, highest)
		_line("build_number", "ok", "%d (config %d, highest on App Store Connect for %s: %s)" % [
			build, config_number, version if version != "" else "any version", str(highest) if highest > 0 else "none"])
	else:
		_line("build_number", "ok", "%d (config; --no-upload skips App Store Connect)" % build)

	# ── pipeline: export → patch → archive → sign → export .ipa → verify → upload ──
	var config_path := _project_dir.path_join(Core.CONFIG_FILE)
	var config_text := _read(config_path)  # pre-build bytes: the commit edits these, not the service's save
	var paths := ServiceT.derive_paths(_project_dir + "/", str(preset["export_path"]), "iOS")
	var before := _entries(paths["dir"])
	var started: Dictionary = _svc.start_build(opts["upload"], build)
	if not started.get("ok", false):
		_line("export", "FAIL", str(started.get("error", "could not start the build")))
		return _finish(false, version, str(build), asc_state, entitlements, commit)
	while not _done:
		await process_frame
	var built_ok := bool(_result.get("ok", false))
	entitlements = "verified" if _verified else ("FAILED" if str(_result.get("stage", "")) == "verify_entitlements" else "not reached")
	# The archived app's Info.plist has the build settings expanded; the
	# generated one only says $(MARKETING_VERSION) (Godot 4.7's template), which
	# reconcile_version ignores — it must never reach the commit or ASC.
	var shipped := ""
	for plist_path in [paths["archived_app"].path_join("Info.plist"), paths["info_plist"]]:
		var plist := ServiceT.read_plist_file(plist_path)
		if plist["ok"]:
			shipped = str(plist["data"].get("CFBundleShortVersionString", ""))
			if shipped != "" and not Core.is_unresolved_setting(shipped):
				break
	var reconciled := Core.reconcile_version(version, shipped)
	if str(reconciled["warn"]) != "":
		_line("version", "warn", str(reconciled["warn"]))
	version = str(reconciled["version"])
	_cleanup(paths, before, not opts["upload"])
	if not built_ok:
		return _finish(false, version, str(build), asc_state, entitlements, commit)
	if not opts["upload"]:
		_line("done", "ok", "signed .ipa at %s" % paths["ipa"])
		return _finish(true, version, str(build), asc_state, entitlements, commit)

	# ── record the build number: config + commit + push (the build is uploaded, so this happens even if processing later fails) ──
	var ok := true
	var next := build + 1
	var wrote := _write(config_path, config_text)
	var w := Core.write_build_number(config_path, next) if wrote else {"ok": false, "error": "cannot restore %s" % config_path}
	if not w["ok"]:
		_line("config", "FAIL", str(w["error"]))
		ok = false
		commit = "failed"
	else:
		_line("config", "ok", "%s build_number → %d" % [Core.CONFIG_FILE, next])
		if opts["commit"]:
			var c := Core.git_commit_and_push(_git, Core.commit_message(version, build, next), opts["push"], upstream)
			if c["sha"] != "":
				commit = str(c["sha"]).left(12)
			if not c["ok"]:
				ok = false
				_line("commit", "FAIL", str(c["error"]))
				if c["sha"] == "":
					commit = "failed"
			else:
				_line("commit", "ok", commit)
				if opts["push"]:
					_line("push", "ok", "%s/%s%s" % [upstream["remote"], str(upstream["merge"]).trim_prefix("refs/heads/"),
						" (after rebasing onto the new upstream)" if c["rebased"] else ""])
				else:
					_line("push", "skipped", "--no-push")
		else:
			commit = "uncommitted"
			_line("commit", "skipped", "--no-commit (%s left modified)" % Core.CONFIG_FILE)

	# ── wait for App Store Connect processing ──
	var poll: Dictionary = await _poll_processing(str(preset["bundle_id"]), version, build, int(opts["timeout_min"]))
	asc_state = str(poll["state"]) if str(poll["state"]) != "" else "NOT_LISTED"
	ok = ok and bool(poll["ok"])
	return _finish(ok, version, str(build), asc_state, entitlements, commit, bool(poll.get("unconfirmed", false)))


func _finish(ok: bool, version: String, build: String, asc_state: String, entitlements: String, commit: String,
		unconfirmed := false) -> int:
	print(Core.redact(Core.summary_line(ok, version, build, asc_state, entitlements, commit, unconfirmed), _secrets))
	return Core.exit_code(ok, unconfirmed)


static func _yn(b: bool) -> String:
	return "yes" if b else "no"


# ── pipeline signals ──

func _on_stage_changed(stage: String, platform: String) -> void:
	if platform != "ios" or stage == "":
		return
	if _stage != "":
		_stage_done(_stage)
	_stage = stage
	_stage_started_ms = Time.get_ticks_msec()


func _stage_done(stage: String) -> void:
	_line(stage, "ok", "%ds" % _elapsed_s())
	if stage == "verify_entitlements":
		_verified = true


func _on_build_finished(result: Dictionary, platform: String) -> void:
	if platform != "ios" or _done:
		return
	if result.get("ok", false):
		if _stage != "":
			_stage_done(_stage)
	else:
		var stage := str(result.get("stage", _stage))
		_line(stage if stage != "" else "build", "FAIL", "%ds — %s" % [_elapsed_s(), str(result.get("title", "failed"))])
		var guidance := str(result.get("guidance", result.get("error", ""))).strip_edges()
		for g in guidance.split("\n", false):
			print(Core.redact("    " + g, _secrets))
		if str(result.get("log", "")) != "":
			print("    log: " + str(result["log"]))
	_stage = ""
	_result = result
	_done = true


func _elapsed_s() -> int:
	return int((Time.get_ticks_msec() - _stage_started_ms) / 1000.0)


# ── App Store Connect ──

func _asc_call(command: String, bundle_id: String, extra: PackedStringArray) -> Dictionary:
	var h: Dictionary = _svc._spawn_asc(command, bundle_id, "cli_asc_%s.log" % command, extra)
	if not h.get("ok", false):
		return {"ok": false, "error": str(h.get("error", "spawn failed"))}
	var deadline := Time.get_ticks_msec() + int(ASC_CALL_TIMEOUT_S * 1000)
	while Exec.exit_code(h["exit_path"]) < 0:
		if Time.get_ticks_msec() > deadline:
			Exec.kill_tree(int(h["pid"]))
			return {"ok": false, "error": "timed out after %ds" % int(ASC_CALL_TIMEOUT_S)}
		await create_timer(0.25).timeout
	return ServiceT._parse_helper_json(Exec.read_all(h["log"]))


## Polls until build `build` of `version` is VALID (ok), FAILED/INVALID (not
## ok), or it stops watching: the timeout passes, or App Store Connect fails
## MAX_POLL_FAILURES times in a row / permanently. Stopping is ok + unconfirmed
## — the upload and the build-number commit already happened, so the run isn't
## a failure, just not confirmed (exit 3). Returns {ok, state, unconfirmed}.
func _poll_processing(bundle_id: String, version: String, build: int, timeout_min: int) -> Dictionary:
	var extra := PackedStringArray(["--build-number", str(build)])
	if version != "":
		extra += PackedStringArray(["--app-version", version])
	var start := Time.get_ticks_msec()
	var deadline := start + timeout_min * 60000
	var state := ""
	var last := "-"
	var failures := 0
	_stage_started_ms = start
	while true:
		var asc: Dictionary = await _asc_call("build-status", bundle_id, extra)
		if asc.get("ok", false):
			failures = 0
			state = str(asc.get("state", Core.build_state(asc.get("builds", []), build)))
			if state != last:
				print("[processing] build %d: %s (%dm)" % [build, state if state != "" else "not listed yet",
					int((Time.get_ticks_msec() - start) / 60000.0)])
				last = state
			match Core.state_verdict(state):
				"done":
					_line("processing", "ok", "build %d is VALID (ready to test) after %ds" % [build, _elapsed_s()])
					return {"ok": true, "state": state, "unconfirmed": false}
				"failed":
					_line("processing", "FAIL", "App Store Connect marked build %d %s — Apple emails the reason to the account holder" % [build, state])
					return {"ok": false, "state": state, "unconfirmed": false}
		else:
			failures += 1
			var error := str(asc.get("error", "unknown")).replace("\r", "").replace("\n", " ").replace("\t", "")
			if Core.poll_failure_verdict(asc, failures) == "give_up":
				_line("processing", "WARN", "stopped watching after %d failed App Store Connect quer%s (%s). Build %d WAS uploaded and its build number recorded; processing is unconfirmed — check TestFlight (or the dock's TestFlight status) instead of re-running" % [
					failures, "y" if failures == 1 else "ies", error.left(200), build])
				return {"ok": true, "state": "UNCONFIRMED", "unconfirmed": true}
			print(Core.redact("[processing] App Store Connect query failed (%d/%d, will retry): %s" % [
				failures, Core.MAX_POLL_FAILURES, error.left(200)], _secrets))
		if Time.get_ticks_msec() + int(POLL_INTERVAL_S * 1000) > deadline:
			break
		await create_timer(POLL_INTERVAL_S).timeout
	_line("processing", "WARN", "timed out after %d min with build %d %s — it WAS uploaded and its build number recorded; processing is unconfirmed — check TestFlight later (the dock's TestFlight status) or rerun with a longer --timeout only if you need to wait" % [
		timeout_min, build, state if state != "" else "not listed yet"])
	return {"ok": true, "state": state if state != "" else "TIMEOUT", "unconfirmed": true}


# ── git ──

func _git(args: PackedStringArray) -> Dictionary:
	OS.set_environment("GIT_TERMINAL_PROMPT", "0")  # fail, don't hang, on an auth prompt
	var out: Array = []
	# A captured OS.execute goes through popen + a shell: escape every arg, or
	# a commit message holding $(…) loses it (0.3.0's empty version).
	var argv := PackedStringArray(Array(PackedStringArray(["-C", _project_dir]) + args).map(
		func(a): return Exec.popen_safe(str(a))))
	var code := OS.execute("git", argv, out, true)
	return {"code": code, "output": "".join(out.map(func(c): return str(c)))}


# ── files ──

static func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


## Restores the pre-build config bytes (the service's own post-upload save
## re-serialises it with defaults merged in); "" = the file didn't exist.
static func _write(path: String, text: String) -> bool:
	if text == "":
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return true
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true


static func _entries(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.include_hidden = true
	for n in dir.get_files():
		out.append(n)
	for n in dir.get_directories():
		out.append(n)
	return out


func _cleanup(paths: Dictionary, before: Array, keep_ipa: bool) -> void:
	var dir := str(paths["dir"])
	var app := str(paths["app"])
	var known := [app, app + ".xcodeproj", app + ".xcarchive", app + ".ipa", app + ".xcframework",
		"build_kit_ipa_check", "build_kit_ipa_entitlements.plist", "build_kit_export_options.plist",
		"build_kit_upload_options.plist", "DistributionSummary.plist", "ExportOptions.plist", "Packaging.log"]
	var keep := [app + ".ipa"] if keep_ipa else []
	var after := _entries(dir)
	if after.has("project.godot") or after.has(".git"):
		_line("cleanup", "skipped", "%s is a project/repo root; not deleting anything there" % dir)
		return
	var failed := PackedStringArray()
	var victims := Core.cleanup_entries(before, after, known, keep)
	for name in victims:
		var p := dir.path_join(name)
		var d := DirAccess.open(dir)
		if d != null and d.dir_exists(name) and not d.is_link(name):
			var why := ServiceT._delete_tree(p, dir)
			if why != "":
				failed.append(why)
		elif DirAccess.remove_absolute(p) != OK:
			failed.append(p)
	if failed.is_empty():
		_line("cleanup", "ok", "removed %d build output(s); logs kept in %s" % [victims.size(), paths["logs"]])
	else:
		_line("cleanup", "warn", "couldn't remove: %s (logs in %s)" % [", ".join(failed), paths["logs"]])
