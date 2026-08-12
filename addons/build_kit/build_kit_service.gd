@tool
extends "res://addons/editor_tool_kit/tool_service.gd"

## Device-build pipeline service. Two halves:
##
## 1. PREFLIGHT — a checklist that diagnoses the local Apple toolchain and App
##    Store Connect state (Xcode, export templates, the iOS preset, signed-in
##    teams, ASC API key, whether the app record exists, paired devices), each
##    row carrying the exact fix when it fails. The tool's job is to TELL YOU
##    what to do, not to fail with a raw log.
## 2. PIPELINE — the staged build: Godot headless export (project-only) →
##    Info.plist patch (encryption-exempt + build number) → xcodebuild archive
##    (automatic signing) → xcodebuild -exportArchive (destination: upload →
##    TestFlight, or export → local .ipa).
##
## Every external command runs detached (exec.gd) with its output tailed from a
## log file — nothing blocks the editor thread and the pipeline is cancellable.
## Failures are mapped to guidance by classify.gd.
##
## Project-specific state lives OUTSIDE the addon (self-update overwrites this
## folder): res://build_kit.config.json + optional ASC_* env / .env fallbacks.

const Exec := preload("res://addons/build_kit/exec.gd")
const Classify := preload("res://addons/build_kit/classify.gd")

const CONFIG_PATH := "res://build_kit.config.json"

signal preflight_changed(rows: Array)
signal stage_changed(stage: String)
signal log_line(text: String)
signal build_finished(result: Dictionary)

var config := {}
var preflight_rows: Array = []

var _stages: Array = []          # queued {name, shell} dicts
var _stage := ""                 # current stage name ("" = idle)
var _proc := {}                  # active Exec.spawn handle (+offset)
var _upload := false
var _context := {}               # bundle_id / team_id for classify + guidance
var _preset := {}                # parsed iOS preset (cached at build start)

var _asc_proc := {}              # async app-record preflight probe
var _asc_started_ms := 0
var _builds_proc := {}           # async TestFlight-status probe


func _ready() -> void:
	load_config()


func _process(_delta: float) -> void:
	_poll_pipeline()
	_poll_asc()
	_poll_builds()


# ── Config ────────────────────────────────────────────────────────────────────

static func default_config() -> Dictionary:
	return {
		"ios": {
			"preset": "iOS",
			"build_number": 1,
			"asc_key_id": "",
			"asc_issuer_id": "",
			"asc_key_path": "",
		},
	}


func load_config() -> Dictionary:
	config = default_config()
	if FileAccess.file_exists(CONFIG_PATH):
		var f := FileAccess.open(CONFIG_PATH, FileAccess.READ)
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if parsed is Dictionary:
			for key in parsed:
				if config.has(key) and parsed[key] is Dictionary:
					config[key].merge(parsed[key], true)
				else:
					config[key] = parsed[key]
	return config


func save_config() -> void:
	var f := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(config, "\t") + "\n")
		f.close()


## ASC API credentials: config first, then environment, then a repo .env
## (res://.env or res://../.env — Moveborne keeps its .env one level above the
## Godot project). Returns {key_id, issuer_id, key_path}; empty strings = unset.
func asc_credentials() -> Dictionary:
	var ios: Dictionary = config.get("ios", {})
	var creds := {
		"key_id": str(ios.get("asc_key_id", "")),
		"issuer_id": str(ios.get("asc_issuer_id", "")),
		"key_path": str(ios.get("asc_key_path", "")),
	}
	var env := {}
	for env_path in ["res://.env", "res://../.env"]:
		if FileAccess.file_exists(env_path):
			var f := FileAccess.open(env_path, FileAccess.READ)
			env.merge(parse_env(f.get_as_text()))
	if creds["key_id"] == "":
		creds["key_id"] = OS.get_environment("ASC_KEY_ID")
		if creds["key_id"] == "":
			creds["key_id"] = str(env.get("ASC_KEY_ID", ""))
	if creds["issuer_id"] == "":
		creds["issuer_id"] = OS.get_environment("ASC_ISSUER_ID")
		if creds["issuer_id"] == "":
			creds["issuer_id"] = str(env.get("ASC_ISSUER_ID", ""))
	if creds["key_path"] == "":
		creds["key_path"] = OS.get_environment("ASC_KEY_PATH")
		if creds["key_path"] == "":
			creds["key_path"] = str(env.get("ASC_KEY_PATH", ""))
	if creds["key_path"].begins_with("~"):
		creds["key_path"] = OS.get_environment("HOME") + creds["key_path"].substr(1)
	return creds


func has_asc_key() -> bool:
	var c := asc_credentials()
	return c["key_id"] != "" and c["issuer_id"] != "" and c["key_path"] != ""


static func parse_env(text: String) -> Dictionary:
	var out := {}
	for line in text.split("\n"):
		var s := line.strip_edges()
		if s.is_empty() or s.begins_with("#") or not s.contains("="):
			continue
		var eq := s.find("=")
		var key := s.substr(0, eq).trim_prefix("export ").strip_edges()
		var value := s.substr(eq + 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
		out[key] = value
	return out


# ── Preset ────────────────────────────────────────────────────────────────────

## Parse export_presets.cfg text for the iOS preset. Returns {} when absent,
## else {section, name, export_path, bundle_id, team_id, export_project_only}.
static func parse_ios_preset_text(text: String, preset_name := "") -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.parse(text) != OK:
		return {}
	for section in cfg.get_sections():
		if section.contains(".options"):
			continue
		if str(cfg.get_value(section, "platform", "")) != "iOS":
			continue
		var name := str(cfg.get_value(section, "name", ""))
		if preset_name != "" and name != preset_name:
			continue
		var opt := section + ".options"
		return {
			"section": section,
			"name": name,
			"export_path": str(cfg.get_value(section, "export_path", "")),
			"bundle_id": str(cfg.get_value(opt, "application/bundle_identifier", "")),
			"team_id": str(cfg.get_value(opt, "application/app_store_team_id", "")),
			"export_project_only": bool(cfg.get_value(opt, "application/export_project_only", false)),
		}
	return {}


func load_ios_preset() -> Dictionary:
	if not FileAccess.file_exists("res://export_presets.cfg"):
		return {}
	var f := FileAccess.open("res://export_presets.cfg", FileAccess.READ)
	var wanted := str(config.get("ios", {}).get("preset", "iOS"))
	var preset := parse_ios_preset_text(f.get_as_text(), wanted)
	if preset.is_empty():
		preset = parse_ios_preset_text(FileAccess.open("res://export_presets.cfg", FileAccess.READ).get_as_text())
	return preset


## Absolute paths derived from the preset's export_path.
static func derive_paths(project_root: String, export_path: String) -> Dictionary:
	var out_abs := (project_root.rstrip("/") + "/" + export_path).simplify_path()
	var build_dir := out_abs.get_base_dir()
	var app := out_abs.get_file().get_basename()
	return {
		"out": out_abs,
		"dir": build_dir,
		"app": app,
		"xcodeproj": build_dir.path_join(app + ".xcodeproj"),
		"archive": build_dir.path_join(app + ".xcarchive"),
		"info_plist": build_dir.path_join(app).path_join(app + "-Info.plist"),
		"options_plist": build_dir.path_join("build_kit_export_options.plist"),
		"logs": build_dir.path_join("logs"),
	}


static func make_export_options_xml(team_id: String, upload: bool) -> String:
	var destination := "upload" if upload else "export"
	return """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>%s</string>
	<key>teamID</key>
	<string>%s</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
""" % [destination, team_id]


# ── Pipeline ──────────────────────────────────────────────────────────────────

func is_busy() -> bool:
	return _stage != ""


func current_stage() -> String:
	return _stage


## upload=true → TestFlight; upload=false → signed .ipa left in the build dir.
func start_build(upload := true) -> Dictionary:
	if is_busy():
		return err("A build is already running (stage: %s)." % _stage)
	load_config()
	_preset = load_ios_preset()
	if _preset.is_empty():
		return err("No iOS export preset found. Create one in Project → Export (platform iOS), then Refresh preflight.")
	if not _preset["export_project_only"]:
		return err("The iOS preset must have application/export_project_only=true (Build Kit runs xcodebuild itself — Godot's internal Xcode build can't take API-key auth and is broken under Xcode 26). Use the preflight Fix button.")
	if _preset["team_id"] == "":
		return err("The iOS preset has no App Store Team ID. Use the preflight Fix button (or set application/app_store_team_id in Project → Export).")

	var root := ProjectSettings.globalize_path("res://")
	var paths := derive_paths(root, _preset["export_path"])
	var build_number := int(config["ios"].get("build_number", 1))
	_context = {"bundle_id": _preset["bundle_id"], "team_id": _preset["team_id"]}
	_upload = upload

	var f := FileAccess.open(paths["options_plist"], FileAccess.WRITE)
	if f == null:
		DirAccess.make_dir_recursive_absolute(paths["dir"])
		f = FileAccess.open(paths["options_plist"], FileAccess.WRITE)
	if f == null:
		return err("Cannot write %s" % paths["options_plist"])
	f.store_string(make_export_options_xml(_preset["team_id"], upload))
	f.close()

	var auth := _auth_flags()
	var pb := "/usr/libexec/PlistBuddy"
	var plist: String = paths["info_plist"]
	_stages = [
		{
			"name": "export",
			"shell": Exec.command_line(PackedStringArray([
				OS.get_executable_path(), "--headless", "--path", root,
				"--export-release", _preset["name"], paths["out"],
			])),
		},
		{
			"name": "patch",
			"shell": "%s -c 'Delete :ITSAppUsesNonExemptEncryption' %s 2>/dev/null; %s -c 'Add :ITSAppUsesNonExemptEncryption bool false' %s && %s -c 'Set :CFBundleVersion %d' %s" % [
				pb, Exec.quote(plist), pb, Exec.quote(plist), pb, build_number, Exec.quote(plist)],
		},
		{
			"name": "archive",
			"shell": Exec.command_line(PackedStringArray([
				"xcodebuild", "archive",
				"-project", paths["xcodeproj"], "-scheme", paths["app"],
				"-configuration", "Release", "-destination", "generic/platform=iOS",
				"-archivePath", paths["archive"], "-allowProvisioningUpdates",
				"CODE_SIGN_STYLE=Automatic", "CODE_SIGN_IDENTITY=Apple Development",
			]) + auth),
		},
		{
			"name": "upload" if upload else "export_ipa",
			"shell": Exec.command_line(PackedStringArray([
				"xcodebuild", "-exportArchive",
				"-archivePath", paths["archive"],
				"-exportOptionsPlist", paths["options_plist"],
				"-allowProvisioningUpdates",
			]) + (PackedStringArray() if upload else PackedStringArray(["-exportPath", paths["dir"]])) + auth),
		},
	]
	_next_stage(paths)
	return ok({"stages": _stages.size() + 1, "build_number": build_number})


func cancel() -> void:
	if _proc.has("pid"):
		Exec.kill_tree(int(_proc["pid"]))
	_stages = []
	_finish({"ok": false, "stage": _stage, "title": "Cancelled",
		"guidance": "Build cancelled by user."})


func _auth_flags() -> PackedStringArray:
	if not has_asc_key():
		return PackedStringArray()
	var c := asc_credentials()
	return PackedStringArray([
		"-authenticationKeyPath", c["key_path"],
		"-authenticationKeyID", c["key_id"],
		"-authenticationKeyIssuerID", c["issuer_id"],
	])


func _next_stage(paths: Dictionary = {}) -> void:
	if paths.is_empty():
		var root := ProjectSettings.globalize_path("res://")
		paths = derive_paths(root, _preset["export_path"])
	if _stages.is_empty():
		var was_upload := _upload
		if was_upload:
			config["ios"]["build_number"] = int(config["ios"].get("build_number", 1)) + 1
			save_config()
		_finish({
			"ok": true,
			"title": "Uploaded to App Store Connect" if was_upload else "Signed .ipa exported",
			"guidance": ("TestFlight will show the build under Processing for a few minutes — use 'TestFlight status' to poll it."
				if was_upload else "The .ipa is in %s." % paths["dir"]),
			"links": ([{"label": "Open My Apps", "url": "https://appstoreconnect.apple.com/apps"}] if was_upload else []),
		})
		return
	var stage: Dictionary = _stages.pop_front()
	_stage = stage["name"]
	var handle := Exec.spawn_shell(stage["shell"], paths["logs"].path_join(_stage + ".log"))
	if not handle["ok"]:
		_finish({"ok": false, "stage": _stage, "title": "Spawn failed", "guidance": str(handle["error"])})
		return
	_proc = handle
	log_line.emit("\n── %s ──\n$ %s\n" % [_stage, stage["shell"]])
	stage_changed.emit(_stage)


func _poll_pipeline() -> void:
	if _proc.is_empty():
		return
	var tail: Dictionary = Exec.read_from(_proc["log"], int(_proc["offset"]))
	if str(tail["text"]) != "":
		_proc["offset"] = tail["offset"]
		log_line.emit(str(tail["text"]))
	var code := Exec.exit_code(_proc["exit_path"])
	if code < 0:
		if not Exec.is_running(int(_proc["pid"])) and str(tail["text"]) == "":
			# process gone without a sentinel: killed externally
			_finish({"ok": false, "stage": _stage, "title": "Process died",
				"guidance": "The %s process ended without an exit code (killed?). See %s." % [_stage, _proc["log"]]})
		return
	var log_path := str(_proc["log"])
	_proc = {}
	if code == 0:
		_next_stage()
		return
	var diagnosis := Classify.classify(Exec.read_all(log_path), _context)
	diagnosis["ok"] = false
	diagnosis["stage"] = _stage
	diagnosis["log"] = log_path
	_stages = []
	_finish(diagnosis)


func _finish(result: Dictionary) -> void:
	_stage = ""
	_proc = {}
	build_finished.emit(result)
	if result.get("ok", false):
		log_line.emit("\n✓ %s\n%s\n" % [result.get("title", ""), result.get("guidance", "")])
	else:
		log_line.emit("\n✗ %s\n%s\n" % [result.get("title", ""), result.get("guidance", "")])
	stage_changed.emit("")


# ── TestFlight status (async ASC probe) ───────────────────────────────────────

func check_testflight_status() -> Dictionary:
	if not has_asc_key():
		return err("Needs an App Store Connect API key (see the preflight ASC row).")
	if not _builds_proc.is_empty():
		return err("Already checking.")
	var preset := load_ios_preset()
	if preset.is_empty():
		return err("No iOS preset.")
	_builds_proc = _spawn_asc("builds", preset["bundle_id"], "asc_builds.log")
	if not _builds_proc.get("ok", false):
		var e := str(_builds_proc.get("error", "spawn failed"))
		_builds_proc = {}
		return err(e)
	log_line.emit("\n── TestFlight status ──\n")
	return ok()


func _poll_builds() -> void:
	if _builds_proc.is_empty():
		return
	var code := Exec.exit_code(_builds_proc["exit_path"])
	if code < 0:
		return
	var result := _parse_helper_json(Exec.read_all(_builds_proc["log"]))
	_builds_proc = {}
	if not result.get("ok", false):
		log_line.emit("ASC error: %s\n" % result.get("error", "unknown"))
		return
	if not result.get("found", false):
		log_line.emit("No app record yet for this bundle id.\n")
		return
	var builds: Array = result.get("builds", [])
	if builds.is_empty():
		log_line.emit("App record exists; no builds uploaded yet.\n")
	for b in builds:
		log_line.emit("build %s  %s  (%s)\n" % [b.get("version"), b.get("state"), str(b.get("uploaded"))])


# ── Preflight ─────────────────────────────────────────────────────────────────

func refresh_preflight() -> void:
	load_config()
	var rows: Array = []
	rows.append(_check_xcode())
	rows.append(_check_templates())
	rows.append(_check_preset())
	rows.append(_check_account())
	rows.append(_check_asc_key())
	rows.append(_check_app_record())
	rows.append(_check_devices())
	preflight_rows = rows
	preflight_changed.emit(rows)


static func _row(id: String, label: String, status: String, detail := "", guidance := "", fixable := false, links: Array = []) -> Dictionary:
	return {"id": id, "label": label, "status": status, "detail": detail,
		"guidance": guidance, "fixable": fixable, "links": links}


func _check_xcode() -> Dictionary:
	var r: Dictionary = Exec.run(PackedStringArray(["xcodebuild", "-version"]))
	if int(r["code"]) != 0:
		return _row("xcode", "Xcode", "fail", "",
			"Install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app",
			false, [{"label": "Xcode on the App Store", "url": "https://apps.apple.com/app/xcode/id497799835"}])
	return _row("xcode", "Xcode", "ok", str(r["output"]).split("\n")[0].strip_edges())


func _check_templates() -> Dictionary:
	var v: Dictionary = Engine.get_version_info()
	var ver := "%d.%d.%d.%s" % [v["major"], v["minor"], v["patch"], v["status"]]
	# OS.get_data_dir() is the platform data root (~/Library/Application Support);
	# Godot's templates live under its own "Godot" subdir. macOS spelling is fine
	# here — the whole iOS pipeline is macOS-only (xcodebuild).
	var path := OS.get_data_dir().path_join("Godot").path_join("export_templates").path_join(ver).path_join("ios.zip")
	if not FileAccess.file_exists(path):
		return _row("templates", "iOS export templates", "fail", ver,
			"Editor → Manage Export Templates → Download and Install (version %s)." % ver)
	return _row("templates", "iOS export templates", "ok", ver)


func _check_preset() -> Dictionary:
	var preset := load_ios_preset()
	if preset.is_empty():
		return _row("preset", "iOS export preset", "fail", "",
			"Create an iOS preset in Project → Export → Add… → iOS. Set the bundle identifier; leave signing fields empty (Build Kit signs via xcodebuild).")
	var problems := PackedStringArray()
	if not preset["export_project_only"]:
		problems.append("export_project_only is off")
	if preset["team_id"] == "":
		problems.append("no Team ID")
	var detail := "%s → %s" % [preset["name"], preset["bundle_id"]]
	if problems.is_empty():
		return _row("preset", "iOS export preset", "ok", detail)
	return _row("preset", "iOS export preset", "warn",
		detail + " (" + ", ".join(problems) + ")",
		"Fix writes export_project_only=true and fills the Team ID from your signed-in Xcode account.", true)


static func parse_teams(defaults_output: String) -> PackedStringArray:
	var teams := PackedStringArray()
	for line in defaults_output.split("\n"):
		var s := line.strip_edges()
		if s.begins_with("teamID"):
			var value := s.get_slice("=", 1).strip_edges().trim_suffix(";").strip_edges().trim_prefix("\"").trim_suffix("\"")
			if value != "" and not teams.has(value):
				teams.append(value)
	return teams


func _check_account() -> Dictionary:
	var r: Dictionary = Exec.run(PackedStringArray(["defaults", "read", "com.apple.dt.Xcode", "IDEProvisioningTeamByIdentifier"]))
	var teams := parse_teams(str(r["output"]))
	if int(r["code"]) != 0 or teams.is_empty():
		var status := "warn" if has_asc_key() else "fail"
		return _row("account", "Xcode account", status, "no signed-in teams",
			"Sign into Xcode (Xcode → Settings → Accounts → ＋). Not needed once an ASC API key is configured — cloud signing then works headless.",
			false, [{"label": "Apple Developer account", "url": "https://developer.apple.com/account"}])
	return _row("account", "Xcode account", "ok", "teams: " + ", ".join(teams))


func _check_asc_key() -> Dictionary:
	var c := asc_credentials()
	var links := [{"label": "Create API key", "url": "https://appstoreconnect.apple.com/access/integrations/api"}]
	if c["key_id"] == "" and c["key_path"] == "":
		return _row("asc_key", "App Store Connect API key", "warn", "not configured",
			"Recommended (headless auth, proactive app-record checks, TestFlight polling). Three clicks:\n1. ↗ Create API key → ＋ → any name, role: App Manager → Generate\n2. Download the .p8 (downloadable exactly once), then drop it on this panel — or Browse… — and the key id + path are extracted automatically\n3. Copy the Issuer ID from the top of that same page into the field below and Save",
			false, links)
	if c["key_path"] == "" or not FileAccess.file_exists(c["key_path"]):
		return _row("asc_key", "App Store Connect API key", "fail", c["key_path"],
			"The key file is missing — re-drop the downloaded AuthKey_%s.p8 onto this panel (or Browse…)." % c["key_id"],
			false, links)
	if c["issuer_id"] == "":
		return _row("asc_key", "App Store Connect API key", "warn",
			"key %s — missing Issuer ID" % c["key_id"],
			"Nearly there: copy the Issuer ID (top of the API-keys page, it has a Copy button) into the field below and Save.",
			false, links)
	var py: Dictionary = Exec.run(PackedStringArray(["command", "-v", "python3"]))
	if int(py["code"]) != 0:
		return _row("asc_key", "App Store Connect API key", "warn", "python3 missing",
			"The ASC probes need python3 (ships with the Xcode command-line tools): xcode-select --install")
	return _row("asc_key", "App Store Connect API key", "ok", "key %s" % c["key_id"])


func _check_app_record() -> Dictionary:
	var preset := load_ios_preset()
	if preset.is_empty():
		return _row("app_record", "App Store Connect app record", "warn", "needs a preset first")
	if not has_asc_key():
		return _row("app_record", "App Store Connect app record", "warn",
			"unknown (no API key)",
			"Without an API key this is only verified at upload time — the upload error will carry the create-app steps if the record is missing.",
			false, [{"label": "Open My Apps", "url": "https://appstoreconnect.apple.com/apps"}])
	if _asc_proc.is_empty():
		_asc_proc = _spawn_asc("check-app", preset["bundle_id"], "asc_check_app.log")
		_asc_started_ms = Time.get_ticks_msec()
	return _row("app_record", "App Store Connect app record", "busy", "checking…")


func _check_devices() -> Dictionary:
	var r: Dictionary = Exec.run(PackedStringArray(["xcrun", "devicectl", "list", "devices"]))
	var available := 0
	for line in str(r["output"]).split("\n"):
		if line.contains("available"):
			available += 1
	if int(r["code"]) != 0:
		return _row("devices", "Paired device", "warn", "devicectl unavailable")
	if available == 0:
		return _row("devices", "Paired device", "warn", "none",
			"Only needed for direct on-device installs — TestFlight builds don't require one. Pair via Xcode → Window → Devices and Simulators.")
	return _row("devices", "Paired device", "ok", "%d available" % available)


func _spawn_asc(command: String, bundle_id: String, log_name: String) -> Dictionary:
	var c := asc_credentials()
	var helper := ProjectSettings.globalize_path(
		get_script().resource_path.get_base_dir().path_join("asc_helper.py"))
	return Exec.spawn_logged(PackedStringArray([
		"python3", helper,
		"--key-path", c["key_path"], "--key-id", c["key_id"], "--issuer-id", c["issuer_id"],
		command, bundle_id,
	]), OS.get_cache_dir().path_join("build_kit").path_join(log_name))


static func _parse_helper_json(log_text: String) -> Dictionary:
	for line in log_text.split("\n"):
		var s := line.strip_edges()
		if s.begins_with("{"):
			var parsed: Variant = JSON.parse_string(s)
			if parsed is Dictionary:
				return parsed
	return {"ok": false, "error": "no JSON in helper output: " + log_text.strip_edges().left(200)}


func _poll_asc() -> void:
	if _asc_proc.is_empty():
		return
	var code := Exec.exit_code(_asc_proc["exit_path"])
	if code < 0:
		if Time.get_ticks_msec() - _asc_started_ms > 60000:
			Exec.kill_tree(int(_asc_proc["pid"]))
			_asc_proc = {}
			_set_row("app_record", "warn", "check timed out", "Network problem reaching the App Store Connect API — Refresh to retry.")
		return
	var result := _parse_helper_json(Exec.read_all(_asc_proc["log"]))
	_asc_proc = {}
	var preset := load_ios_preset()
	var bundle := str(preset.get("bundle_id", ""))
	if not result.get("ok", false):
		_set_row("app_record", "warn", "check failed", "ASC API error: %s" % result.get("error", "unknown"))
	elif result.get("found", false):
		var apps: Array = result.get("apps", [])
		var name := str(apps[0].get("name", "")) if not apps.is_empty() else ""
		_set_row("app_record", "ok", name)
	else:
		_set_row("app_record", "fail", "missing for " + bundle,
			"One-time manual step (app creation is not in Apple's public API, ~2 min):\n1. My Apps → ＋ → New App\n2. Platform iOS; Name: unique across the App Store\n3. Bundle ID: pick %s from the dropdown (already registered by signing)\n4. SKU: any internal id. Then Refresh." % bundle,
			[{"label": "Open My Apps", "url": "https://appstoreconnect.apple.com/apps"}])


func _set_row(id: String, status: String, detail: String, guidance := "", links: Array = []) -> void:
	for row in preflight_rows:
		if row["id"] == id:
			row["status"] = status
			row["detail"] = detail
			row["guidance"] = guidance
			row["links"] = links
	preflight_changed.emit(preflight_rows)


# ── ASC key adoption ──────────────────────────────────────────────────────────

## Apple names every downloaded key AuthKey_<KEYID>.p8 — the key id rides in
## the filename, so a dropped file configures itself.
static func parse_key_id_from_filename(path: String) -> String:
	var file := path.get_file()
	if file.begins_with("AuthKey_") and file.ends_with(".p8"):
		var id := file.trim_prefix("AuthKey_").trim_suffix(".p8")
		if id.length() >= 6:
			return id
	return ""


## Ingest a dropped/browsed .p8: extract the key id, copy the file to
## ~/private_keys/ (outside any repo, so it can never be committed), lock it to
## 600, and persist both into build_kit.config.json. The Issuer ID is NOT in
## the file — set_asc_issuer() completes the pair.
func adopt_asc_key(p8_path: String) -> Dictionary:
	if not FileAccess.file_exists(p8_path):
		return err("File not found: " + p8_path)
	var key_id := parse_key_id_from_filename(p8_path)
	if key_id == "":
		return err("Expected Apple's filename AuthKey_<KEYID>.p8 — got '%s'. Re-download (or rename it back) and retry." % p8_path.get_file())
	var f := FileAccess.open(p8_path, FileAccess.READ)
	if f == null or not f.get_as_text().contains("BEGIN PRIVATE KEY"):
		return err("'%s' doesn't look like a .p8 private key." % p8_path.get_file())
	var dest_dir := OS.get_environment("HOME").path_join("private_keys")
	var dest := dest_dir.path_join(p8_path.get_file())
	if dest != p8_path:
		DirAccess.make_dir_recursive_absolute(dest_dir)
		var w := FileAccess.open(dest, FileAccess.WRITE)
		if w == null:
			return err("Cannot write " + dest)
		w.store_string(FileAccess.open(p8_path, FileAccess.READ).get_as_text())
		w.close()
		Exec.run(PackedStringArray(["chmod", "600", dest]))
	config["ios"]["asc_key_id"] = key_id
	config["ios"]["asc_key_path"] = dest
	save_config()
	refresh_preflight()
	var need_issuer: bool = str(config["ios"].get("asc_issuer_id", "")) == ""
	return ok({"message": "Key %s installed at %s.%s" % [key_id, dest,
		" Now paste the Issuer ID and Save." if need_issuer else ""]})


func set_asc_issuer(issuer: String) -> Dictionary:
	issuer = issuer.strip_edges()
	if issuer == "":
		return err("Paste the Issuer ID first — it's at the top of the API-keys page (Copy button).")
	if issuer.count("-") != 4 or issuer.length() < 32:
		return err("That doesn't look like an Issuer ID (a UUID like 69a6de78-…). Copy it from the top of the API-keys page.")
	config["ios"]["asc_issuer_id"] = issuer
	save_config()
	refresh_preflight()
	return ok({"message": "Issuer ID saved."})


# ── Fixes ─────────────────────────────────────────────────────────────────────

## The preset fix: writes export_project_only=true and, when the preset has no
## Team ID, fills it from the signed-in Xcode account (only when exactly one
## team is available — with several, choosing is the user's call).
func apply_fix(id: String) -> Dictionary:
	if id != "preset":
		return err("No fix for '%s'." % id)
	var preset := load_ios_preset()
	if preset.is_empty():
		return err("No iOS preset to fix — create one in Project → Export first.")
	var cfg := ConfigFile.new()
	if cfg.load("res://export_presets.cfg") != OK:
		return err("Cannot parse export_presets.cfg.")
	var opt: String = preset["section"] + ".options"
	cfg.set_value(opt, "application/export_project_only", true)
	var msg := "export_project_only=true"
	if preset["team_id"] == "":
		var r: Dictionary = Exec.run(PackedStringArray(["defaults", "read", "com.apple.dt.Xcode", "IDEProvisioningTeamByIdentifier"]))
		var teams := parse_teams(str(r["output"]))
		if teams.size() == 1:
			cfg.set_value(opt, "application/app_store_team_id", teams[0])
			msg += ", team_id=" + teams[0]
		elif teams.size() > 1:
			msg += " — several teams signed in (%s): set application/app_store_team_id yourself in Project → Export" % ", ".join(teams)
		else:
			msg += " — no signed-in team found: set application/app_store_team_id yourself"
	if cfg.save("res://export_presets.cfg") != OK:
		return err("Cannot write export_presets.cfg.")
	mark_dirty()
	refresh_preflight()
	return ok({"message": msg})
