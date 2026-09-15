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
## folder): res://build_kit.config.json for shared settings (committed) and the
## repo .env for ASC_* credentials (gitignored, never committed).

const Exec := preload("res://addons/build_kit/exec.gd")
const Classify := preload("res://addons/build_kit/classify.gd")

const CONFIG_PATH := "res://build_kit.config.json"

## Candidate .env files, in precedence order — the first hit wins on read, and
## the first that already exists is what we write to. `res://../.env` covers the
## common layout where the Godot project is a subdir of the repo.
const ENV_PATHS := ["res://.env", "res://../.env"]

signal preflight_changed(rows: Array)
signal stage_changed(stage: String, platform: String)
signal log_line(text: String, platform: String)
signal build_finished(result: Dictionary, platform: String)

var config := {}
var preflight_rows: Array = []

var _stages: Array = []          # queued {name, shell} dicts
var _stage := ""                 # current stage name ("" = idle)
var _active_platform := ""       # platform owning the current build ("" = idle)
var _proc := {}                  # active Exec.spawn handle (+offset)
var _upload := false
var _context := {}               # bundle_id / team_id for classify + guidance
var _preset := {}                # parsed iOS preset (cached at build start)

var _asc_proc := {}              # async ASC preflight probe (see _asc_phase)
var _asc_phase := "team"         # "team" = key validation → chains into "app" = app-record check
var _asc_started_ms := 0
var _builds_proc := {}           # async TestFlight-status probe
var _fix_proc := {}              # async preflight fix (templates download/install)


func _ready() -> void:
	load_config()


func _process(_delta: float) -> void:
	_poll_pipeline()
	_poll_asc()
	_poll_builds()
	_poll_fix()


# ── Config ────────────────────────────────────────────────────────────────────

## Committed, so it holds only what collaborators share. ASC credentials live in
## the .env (see the Secrets section); they are read from here for back-compat
## but migrated out on load.
static func default_config() -> Dictionary:
	return {
		"ios": {
			"preset": "iOS",
			"build_number": 1,
		},
		"android": {
			"preset": "Android",
			"version_code": 1,
		},
	}


## Fields JSON parses as floats but that must round-trip as ints (CFBundleVersion
## "2" not "2.0"; same for Android's versionCode).
const INT_CONFIG_FIELDS := [
	["ios", "build_number"],
	["android", "version_code"],
]


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
	for pair in INT_CONFIG_FIELDS:
		config[pair[0]][pair[1]] = int(config[pair[0]].get(pair[1], 1))
	migrate_config_secrets_to_env()
	return config


func save_config() -> void:
	var f := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(config, "\t") + "\n")
		f.close()


## ASC API credentials: config first (legacy — see migrate_config_secrets_to_env),
## then environment, then a repo .env. Returns {key_id, issuer_id, key_path};
## empty strings = unset.
func asc_credentials() -> Dictionary:
	var ios: Dictionary = config.get("ios", {})
	var creds := {
		"key_id": str(ios.get("asc_key_id", "")),
		"issuer_id": str(ios.get("asc_issuer_id", "")),
		"key_path": str(ios.get("asc_key_path", "")),
	}
	var env := {}
	for env_path in ENV_PATHS:
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


# ── Secrets (.env) ────────────────────────────────────────────────────────────
#
# build_kit.config.json is committed — it carries the preset name and build
# number, which every collaborator wants. ASC credentials are the opposite: the
# .p8 is already kept outside the repo, so its id/issuer/path belong outside too,
# in the gitignored .env the read path already falls back to.

## The .env we write to: the first candidate that already exists, else the first.
static func env_write_path() -> String:
	for p in ENV_PATHS:
		if FileAccess.file_exists(p):
			return p
	return ENV_PATHS[0]


## Home-relative form, so a path written on one machine still resolves on another
## (asc_credentials() expands a leading ~).
static func tildify(path: String) -> String:
	var home := OS.get_environment("HOME")
	if home != "" and path.begins_with(home + "/"):
		return "~" + path.substr(home.length())
	return path


## Upsert KEY=value pairs into .env text: rewrite an existing key's value in
## place (keeping any `export ` prefix), append the rest. Comments, blank lines
## and unrelated keys survive untouched. Pure, so the verifier can exercise it
## without touching disk.
static func upsert_env_text(text: String, vars: Dictionary) -> String:
	var remaining := vars.duplicate()
	var out := PackedStringArray()
	for line in text.split("\n"):
		var s := line.strip_edges()
		var handled := false
		if not s.is_empty() and not s.begins_with("#") and s.contains("="):
			var key := s.substr(0, s.find("=")).trim_prefix("export ").strip_edges()
			if remaining.has(key):
				out.append("%s%s=%s" % ["export " if s.begins_with("export ") else "", key, remaining[key]])
				remaining.erase(key)
				handled = true
		if not handled:
			out.append(line)
	var joined := "\n".join(out)
	if not remaining.is_empty():
		if not joined.is_empty() and not joined.ends_with("\n"):
			joined += "\n"
		for key in remaining:
			joined += "%s=%s\n" % [key, remaining[key]]
	return joined


## Writing a secret into a file git tracks would just relocate the leak, so make
## sure the .env we just wrote is actually ignored. Only touches an existing
## .gitignore, or creates one beside a .git dir — never litters a non-repo.
static func ensure_env_gitignored(env_res_path: String) -> bool:
	var dir := ProjectSettings.globalize_path(env_res_path).get_base_dir()
	var ignore := dir.path_join(".gitignore")
	var text := ""
	var exists := FileAccess.file_exists(ignore)
	if not exists and not DirAccess.dir_exists_absolute(dir.path_join(".git")):
		return false
	if exists:
		var r := FileAccess.open(ignore, FileAccess.READ)
		if r != null:
			text = r.get_as_text()
		for line in text.split("\n"):
			if line.strip_edges() in [".env", "/.env", "*.env", ".env*"]:
				return true
	if not text.is_empty() and not text.ends_with("\n"):
		text += "\n"
	var f := FileAccess.open(ignore, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text + ".env\n")
	f.close()
	return true


## Persist secrets to the repo .env. Returns the path written ("" on failure).
func write_env_vars(vars: Dictionary) -> String:
	var path := env_write_path()
	var text := ""
	if FileAccess.file_exists(path):
		var r := FileAccess.open(path, FileAccess.READ)
		if r != null:
			text = r.get_as_text()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("build_kit: cannot write %s" % path)
		return ""
	f.store_string(upsert_env_text(text, vars))
	f.close()
	ensure_env_gitignored(path)
	return path


const SECRET_FIELDS := [
	["asc_key_id", "ASC_KEY_ID"],
	["asc_issuer_id", "ASC_ISSUER_ID"],
	["asc_key_path", "ASC_KEY_PATH"],
]

## The .env vars an ios config's legacy secret fields map to; {} when clean.
## Pure — the decision half of migrate_config_secrets_to_env().
static func config_secrets_as_env(ios: Dictionary) -> Dictionary:
	var out := {}
	for pair in SECRET_FIELDS:
		var value := str(ios.get(pair[0], "")).strip_edges()
		if value != "":
			out[pair[1]] = tildify(value) if pair[0] == "asc_key_path" else value
	return out


## Versions before 0.1.8 wrote the ASC ids into build_kit.config.json, which is
## committed. Move any we find into the .env and drop the config fields.
## Idempotent — a no-op once the config is clean. Returns the vars moved.
func migrate_config_secrets_to_env() -> Dictionary:
	var moved := config_secrets_as_env(config.get("ios", {}))
	if moved.is_empty():
		return {}
	var path := write_env_vars(moved)
	if path == "":
		return {}
	for pair in SECRET_FIELDS:
		config["ios"].erase(pair[0])
	save_config()
	print("build_kit: moved %s out of %s into %s (it is committed; secrets don't belong in it)"
		% [", ".join(PackedStringArray(moved.keys())), CONFIG_PATH, path])
	return moved


# ── Preset ────────────────────────────────────────────────────────────────────

## Parse export_presets.cfg text for a preset targeting `platform`. Returns {}
## when absent, else {section, name, export_path} plus whatever fields that
## platform's checks actually need on top. iOS needs bundle_id/team_id/
## export_project_only (its pipeline runs xcodebuild itself and needs to
## know the signing team). Android's pipeline does the whole build in one
## Godot step with no signing field to validate here — nothing extra needed.
static func parse_preset_text(text: String, platform: String, preset_name := "") -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.parse(text) != OK:
		return {}
	for section in cfg.get_sections():
		if section.contains(".options"):
			continue
		if str(cfg.get_value(section, "platform", "")) != platform:
			continue
		var name := str(cfg.get_value(section, "name", ""))
		if preset_name != "" and name != preset_name:
			continue
		var out := {
			"section": section,
			"name": name,
			"export_path": str(cfg.get_value(section, "export_path", "")),
		}
		if platform == "iOS":
			var opt := section + ".options"
			out["bundle_id"] = str(cfg.get_value(opt, "application/bundle_identifier", ""))
			out["team_id"] = str(cfg.get_value(opt, "application/app_store_team_id", ""))
			out["export_project_only"] = bool(cfg.get_value(opt, "application/export_project_only", false))
		return out
	return {}


func load_preset(platform: String) -> Dictionary:
	if not FileAccess.file_exists("res://export_presets.cfg"):
		return {}
	var f := FileAccess.open("res://export_presets.cfg", FileAccess.READ)
	var wanted := str(config.get(platform.to_lower(), {}).get("preset", platform))
	var preset := parse_preset_text(f.get_as_text(), platform, wanted)
	if preset.is_empty():
		preset = parse_preset_text(FileAccess.open("res://export_presets.cfg", FileAccess.READ).get_as_text(), platform)
	return preset


## Absolute paths derived from the preset's export_path. Android needs only
## the shared core (out/dir/app/logs) — the rest is Xcode-project-specific.
static func derive_paths(project_root: String, export_path: String, platform: String) -> Dictionary:
	var out_abs := (project_root.rstrip("/") + "/" + export_path).simplify_path()
	var build_dir := out_abs.get_base_dir()
	var app := out_abs.get_file().get_basename()
	var out := {
		"out": out_abs,
		"dir": build_dir,
		"app": app,
		"logs": build_dir.path_join("logs"),
	}
	if platform == "iOS":
		out["xcodeproj"] = build_dir.path_join(app + ".xcodeproj")
		out["archive"] = build_dir.path_join(app + ".xcarchive")
		out["info_plist"] = build_dir.path_join(app).path_join(app + "-Info.plist")
		out["options_plist"] = build_dir.path_join("build_kit_export_options.plist")
	return out


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
	_preset = load_preset("iOS")
	if _preset.is_empty():
		return err("No iOS export preset found. Create one in Project → Export (platform iOS), then Refresh preflight.")
	if not _preset["export_project_only"]:
		return err("The iOS preset must have application/export_project_only=true (Build Kit runs xcodebuild itself — Godot's internal Xcode build can't take API-key auth and is broken under Xcode 26). Use the preflight Fix button.")
	if _preset["team_id"] == "":
		return err("The iOS preset has no App Store Team ID. Use the preflight Fix button (or set application/app_store_team_id in Project → Export).")

	var root := ProjectSettings.globalize_path("res://")
	var paths := derive_paths(root, _preset["export_path"], "iOS")
	var build_number := int(config["ios"].get("build_number", 1))
	_context = {"bundle_id": _preset["bundle_id"], "team_id": _preset["team_id"],
		"key_id": str(asc_credentials()["key_id"])}
	_upload = upload
	_active_platform = "ios"

	# Auth choice: a logged-in Xcode session cloud-signs with full permission,
	# so prefer it; API-key flags only when there is no session (headless/CI).
	# A Developer-role key authenticates but CANNOT manage signing assets
	# ("Cloud signing permission error"), so forcing the key when a session
	# exists only downgrades capability.
	var teams := parse_teams(str(Exec.run(PackedStringArray(
		["defaults", "read", "com.apple.dt.Xcode", "IDEProvisioningTeamByIdentifier"]))["output"]))
	var use_key := teams.is_empty() and has_asc_key()

	var f := FileAccess.open(paths["options_plist"], FileAccess.WRITE)
	if f == null:
		DirAccess.make_dir_recursive_absolute(paths["dir"])
		f = FileAccess.open(paths["options_plist"], FileAccess.WRITE)
	if f == null:
		return err("Cannot write %s" % paths["options_plist"])
	f.store_string(make_export_options_xml(_preset["team_id"], upload))
	f.close()

	var auth := _auth_flags() if use_key else PackedStringArray()
	log_line.emit("auth: %s\n" % ("ASC API key %s" % _context["key_id"] if use_key
		else "Xcode session (teams: %s)" % ", ".join(teams)), _active_platform)
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
			# Unsigned on purpose: the export stage does the only signing that
			# matters (distribution), and distribution profiles need no
			# registered devices — dev-signing the archive required a dev
			# profile, which Apple refuses to mint for a device-less team.
			"name": "archive",
			"shell": Exec.command_line(PackedStringArray([
				"xcodebuild", "archive",
				"-project", paths["xcodeproj"], "-scheme", paths["app"],
				"-configuration", "Release", "-destination", "generic/platform=iOS",
				"-archivePath", paths["archive"],
				"CODE_SIGNING_ALLOWED=NO",
			])),
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


## Export a debug APK and adb install it. sdk_path/serial come from the dock
## (EditorSettings and the device picker aren't reachable from here); device
## state is re-checked fresh rather than trusted.
func start_build_android(sdk_path: String, serial := "") -> Dictionary:
	if is_busy():
		return err("A build is already running (stage: %s)." % _stage)
	load_config()
	_preset = load_preset("Android")
	if _preset.is_empty():
		return err("No Android export preset found. Create one in Project → Export (platform Android), then Refresh preflight.")

	var adb := resolve_adb_path(sdk_path)
	var devices := parse_adb_devices(str(Exec.run(PackedStringArray([adb, "devices", "-l"]))["output"]))
	var ready: Array = devices.filter(func(d): return str(d["state"]) == "device")
	if ready.is_empty():
		return err("No authorized Android device/emulator connected. See the preflight Device row.")
	var target := ""
	if ready.size() == 1:
		target = str(ready[0]["serial"])
	else:
		var matches: Array = ready.filter(func(d): return str(d["serial"]) == serial)
		if matches.is_empty():
			return err("%d devices connected — pick one in the preflight Device row." % ready.size())
		target = serial

	var root := ProjectSettings.globalize_path("res://")
	var paths := derive_paths(root, _preset["export_path"], "Android")
	_context = {}
	_active_platform = "android"
	_stages = [
		{
			"name": "export",
			"shell": Exec.command_line(PackedStringArray([
				OS.get_executable_path(), "--headless", "--path", root,
				"--export-debug", _preset["name"], paths["out"],
			])),
		},
		{
			"name": "install",
			"shell": Exec.command_line(PackedStringArray([adb, "-s", target, "install", "-r", paths["out"]])),
		},
	]
	_next_stage(paths)
	return ok({"stages": _stages.size() + 1})


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
		paths = derive_paths(root, _preset["export_path"], "iOS" if _active_platform == "ios" else "Android")
	if _stages.is_empty():
		if _active_platform == "ios":
			var was_upload := _upload
			if was_upload:
				config["ios"]["build_number"] = int(config["ios"].get("build_number", 1)) + 1
				save_config()
			_finish({
				"ok": true,
				"title": "Uploaded to App Store Connect" if was_upload else "Signed .ipa exported",
				"guidance": ("1. Processing takes a few minutes — press 'TestFlight status' to poll\n2. When Ready: TestFlight tab → Internal Testing → ＋ → add a group with yourself as tester (first time only)\n3. iPhone: install the TestFlight app, sign in with the same Apple ID — the build appears there."
					if was_upload else "The .ipa is in %s." % paths["dir"]),
				"links": ([
					{"label": "Open My Apps", "url": "https://appstoreconnect.apple.com/apps"},
					{"label": "TestFlight for iPhone", "url": "https://apps.apple.com/app/testflight/id899247664"},
				] if was_upload else []),
			})
		else:
			_finish({"ok": true, "title": "Installed on device",
				"guidance": "The APK is installed — check the device."})
		return
	var stage: Dictionary = _stages.pop_front()
	_stage = stage["name"]
	var handle := Exec.spawn_shell(stage["shell"], paths["logs"].path_join(_stage + ".log"))
	if not handle["ok"]:
		_finish({"ok": false, "stage": _stage, "title": "Spawn failed", "guidance": str(handle["error"])})
		return
	_proc = handle
	log_line.emit("\n── %s ──\n$ %s\n" % [_stage, stage["shell"]], _active_platform)
	stage_changed.emit(_stage, _active_platform)


## Godot's Android export can exit 0 while only WARNING that apksigner is
## missing, leaving an unsigned APK — the four strings it emits for that.
const APKSIGNER_WARNING_SIGNATURES := [
	"'apksigner' could not be found",
	"'apksigner' returned with error",
	"'apksigner' verification of APK failed",
	"All 'apksigner' tools located in Android SDK 'build-tools' directory failed",
]

static func apksigner_warning_signature(log_text: String) -> String:
	for sig in APKSIGNER_WARNING_SIGNATURES:
		if log_text.contains(sig):
			return sig
	return ""


func _poll_pipeline() -> void:
	if _proc.is_empty():
		return
	var tail: Dictionary = Exec.read_from(_proc["log"], int(_proc["offset"]))
	if str(tail["text"]) != "":
		_proc["offset"] = tail["offset"]
		log_line.emit(str(tail["text"]), _active_platform)
	var code := Exec.exit_code(_proc["exit_path"])
	if code < 0:
		if not Exec.is_running(int(_proc["pid"])) and str(tail["text"]) == "":
			# process gone without a sentinel: killed externally
			_finish({"ok": false, "stage": _stage, "title": "Process died",
				"guidance": "The %s process ended without an exit code (killed?). See %s." % [_stage, _proc["log"]]})
		return
	var log_path := str(_proc["log"])
	_proc = {}
	if code == 0 and _active_platform == "android" and _stage == "export":
		var warning := apksigner_warning_signature(Exec.read_all(log_path))
		if warning != "":
			_stages = []
			_finish({"ok": false, "stage": _stage, "title": "APK export produced an unsigned build",
				"guidance": "Godot's export succeeded but couldn't sign the APK (%s). See the Android SDK preflight row — apksigner ships in the SDK's build-tools." % warning,
				"log": log_path})
			return
	if code == 0:
		_next_stage()
		return
	var diagnosis := Classify.classify(Exec.read_all(log_path), _context, _active_platform)
	diagnosis["ok"] = false
	diagnosis["stage"] = _stage
	diagnosis["log"] = log_path
	_stages = []
	_finish(diagnosis)


func _finish(result: Dictionary) -> void:
	var platform := _active_platform
	_stage = ""
	_active_platform = ""
	_proc = {}
	build_finished.emit(result, platform)
	if result.get("ok", false):
		log_line.emit("\n✓ %s\n%s\n" % [result.get("title", ""), result.get("guidance", "")], platform)
	else:
		log_line.emit("\n✗ %s\n%s\n" % [result.get("title", ""), result.get("guidance", "")], platform)
	stage_changed.emit("", platform)


# ── TestFlight status (async ASC probe) ───────────────────────────────────────

func check_testflight_status() -> Dictionary:
	if not has_asc_key():
		return err("Needs an App Store Connect API key (see the preflight ASC row).")
	if not _builds_proc.is_empty():
		return err("Already checking.")
	var preset := load_preset("iOS")
	if preset.is_empty():
		return err("No iOS preset.")
	_builds_proc = _spawn_asc("builds", preset["bundle_id"], "asc_builds.log")
	if not _builds_proc.get("ok", false):
		var e := str(_builds_proc.get("error", "spawn failed"))
		_builds_proc = {}
		return err(e)
	log_line.emit("\n── TestFlight status ──\n", "ios")
	return ok()


func _poll_builds() -> void:
	if _builds_proc.is_empty():
		return
	var code := Exec.exit_code(_builds_proc["exit_path"])
	if code < 0:
		return
	var result := _parse_helper_json(Exec.read_all(_builds_proc["log"]))
	_builds_proc = {}
	# Every exit below MUST emit build_finished. The dock's status line is written
	# ONLY by that signal, so a bare `return` leaves the previous poll's result on
	# screen — a stale "Build N is Ready to Test", complete with green check, that
	# reads as the current answer while actually being one or more builds behind.
	var apps_link := [{"label": "Open My Apps", "url": "https://appstoreconnect.apple.com/apps"}]
	if not result.get("ok", false):
		var asc_error := str(result.get("error", "unknown"))
		log_line.emit("ASC error: %s\n" % asc_error, "ios")
		build_finished.emit({"ok": false, "title": "TestFlight status check failed",
			"guidance": asc_error, "links": apps_link}, "ios")
		return
	if not result.get("found", false):
		log_line.emit("No app record yet for this bundle id.\n", "ios")
		build_finished.emit({"ok": false, "title": "No app record for this bundle id",
			"guidance": "Create the app in App Store Connect (or use the preflight app-record row), then check again.",
			"links": apps_link}, "ios")
		return
	var builds: Array = result.get("builds", [])
	if builds.is_empty():
		log_line.emit("App record exists; no builds uploaded yet.\n", "ios")
		build_finished.emit({"ok": false, "title": "No builds uploaded yet",
			"guidance": "The app record exists but App Store Connect lists no builds for it.",
			"links": apps_link}, "ios")
		return
	for b in builds:
		log_line.emit("build %s  %s  (%s)\n" % [b.get("version"), b.get("state"), str(b.get("uploaded"))], "ios")
	# Surface the latest build's state as a status + next-step buttons, so
	# "Ready to Test" arrives with the download/share walkthrough attached.
	var latest: Dictionary = builds[0]
	var app_id := str(result.get("app_id", ""))
	var tf_url := ("https://appstoreconnect.apple.com/apps/%s/testflight/ios" % app_id
		if app_id != "" else "https://appstoreconnect.apple.com/apps")
	var links := [
		{"label": "Open TestFlight tab", "url": tf_url},
		{"label": "TestFlight for iPhone", "url": "https://apps.apple.com/app/testflight/id899247664"},
	]
	if str(latest.get("state", "")) == "VALID":
		build_finished.emit({"ok": true,
			"title": "Build %s is Ready to Test" % latest.get("version"),
			"guidance": "1. ↗ Open TestFlight tab → Internal Testing → ＋ → add a group with yourself as tester (first time only; later builds land in the group automatically)\n2. iPhone: install the TestFlight app, sign in with the same Apple ID → Moveborne appears → Install.",
			"links": links}, "ios")
	elif str(latest.get("state", "")) == "PROCESSING":
		build_finished.emit({"ok": true,
			"title": "Build %s still processing" % latest.get("version"),
			"guidance": "Apple is scanning the build — usually a few minutes. Press 'TestFlight status' again shortly.",
			"links": links}, "ios")
	else:
		build_finished.emit({"ok": false,
			"title": "Build %s: %s" % [latest.get("version"), latest.get("state")],
			"guidance": "Apple rejected the binary in post-processing — details were emailed to your developer account address.",
			"links": links}, "ios")


# ── Preflight ─────────────────────────────────────────────────────────────────

func refresh_preflight() -> void:
	load_config()
	var rows: Array = []
	rows.append(_check_xcode())
	rows.append(_check_templates())
	rows.append(_check_etc2())
	rows.append(_check_preset())
	rows.append(_check_account())
	rows.append(_check_dist_cert())
	rows.append(_check_asc_key())
	rows.append(_check_app_record())
	rows.append(_check_devices())
	rows.append(_check_android_templates())
	rows.append(_check_android_preset())
	preflight_rows = rows
	preflight_changed.emit(rows)


static func _row(id: String, label: String, status: String, detail := "", guidance := "", fixable := false, links: Array = []) -> Dictionary:
	return {"id": id, "label": label, "status": status, "detail": detail,
		"guidance": guidance, "fixable": fixable, "links": links}


func _check_xcode() -> Dictionary:
	var r: Dictionary = Exec.run(PackedStringArray(["xcodebuild", "-version"]))
	if int(r["code"]) != 0:
		return _row("ios.xcode", "Xcode", "fail", "",
			"Install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app",
			false, [{"label": "Xcode on the App Store", "url": "https://apps.apple.com/app/xcode/id497799835"}])
	return _row("ios.xcode", "Xcode", "ok", str(r["output"]).split("\n")[0].strip_edges())


## Godot's version strings omit a zero patch: 4.6.0 → "4.6", 4.7.1 → "4.7.1".
## Both the templates directory name and the release tag follow that form.
static func version_tag(v: Dictionary) -> String:
	if int(v.get("patch", 0)) == 0:
		return "%d.%d" % [v["major"], v["minor"]]
	return "%d.%d.%d" % [v["major"], v["minor"], v["patch"]]


## Official template-pack download for stable releases; "" for non-stable
## builds (their packs live in godot-builds with a different scheme).
static func templates_url(v: Dictionary) -> String:
	if str(v.get("status", "")) != "stable":
		return ""
	var tag := version_tag(v)
	return "https://github.com/godotengine/godot/releases/download/%s-stable/Godot_v%s-stable_export_templates.tpz" % [tag, tag]


func templates_dir() -> String:
	var v: Dictionary = Engine.get_version_info()
	# OS.get_data_dir() is the platform data root (~/Library/Application Support);
	# Godot's templates live under its own "Godot" subdir. macOS spelling is fine
	# here — the whole iOS pipeline is macOS-only (xcodebuild).
	return OS.get_data_dir().path_join("Godot").path_join("export_templates").path_join(
		version_tag(v) + "." + str(v["status"]))


func _check_templates() -> Dictionary:
	var v: Dictionary = Engine.get_version_info()
	var ver := version_tag(v) + "." + str(v["status"])
	if not FileAccess.file_exists(templates_dir().path_join("ios.zip")):
		if templates_url(v) == "":
			return _row("ios.templates", "iOS export templates", "fail", ver,
				"1. Editor → Manage Export Templates → Download and Install (no direct download for non-stable builds).")
		return _row("ios.templates", "iOS export templates", "fail", ver,
			"1. Press Fix — downloads the official %s template pack (~1 GB, several minutes) and installs it." % ver,
			true)
	return _row("ios.templates", "iOS export templates", "ok", ver)


## iOS export hard-requires ETC2/ASTC texture imports, and Godot reports the
## violation with an EMPTY error list in headless runs — preflight is the only
## place the user ever learns why. (Root-caused live: a fresh project fails
## with "configuration errors:" and nothing after the colon.)
func _check_etc2() -> Dictionary:
	if bool(ProjectSettings.get_setting("rendering/textures/vram_compression/import_etc2_astc", false)):
		return _row("etc2", "ETC2/ASTC textures", "ok", "enabled")
	return _row("etc2", "ETC2/ASTC textures", "fail", "disabled",
		"Both iOS and Android export require it. Godot hides this error in headless iOS builds; Android's own export reports it directly.\n1. Press Fix — enables rendering/textures/vram_compression/import_etc2_astc (textures reimport once)\n2. Build again.",
		true)


func _fix_etc2() -> Dictionary:
	ProjectSettings.set_setting("rendering/textures/vram_compression/import_etc2_astc", true)
	var saved := ProjectSettings.save()
	if saved != OK:
		return err("Cannot write project.godot (error %d)." % saved)
	refresh_preflight()
	return ok({"message": "ETC2/ASTC imports enabled — the editor will reimport textures once."})


func _check_preset() -> Dictionary:
	var preset := load_preset("iOS")
	if preset.is_empty():
		return _row("ios.preset", "iOS export preset", "fail", "",
			"1. Enter the bundle id below (reverse-DNS, e.g. com.studio.game)\n2. Pick your team\n3. Press Create preset.")
	var problems := PackedStringArray()
	if not preset["export_project_only"]:
		problems.append("export_project_only is off")
	if preset["team_id"] == "":
		problems.append("no Team ID")
	var missing := _missing_base_keys(preset["section"])
	if not missing.is_empty():
		problems.append("%d missing base keys" % missing.size())
	var detail := "%s → %s" % [preset["name"], preset["bundle_id"]]
	if problems.is_empty():
		return _row("ios.preset", "iOS export preset", "ok", detail)
	return _row("ios.preset", "iOS export preset", "warn",
		detail + " (" + ", ".join(problems) + ")",
		"1. Pick your team below\n2. Press Fix.", true)


static func parse_teams(defaults_output: String) -> PackedStringArray:
	var teams := PackedStringArray()
	for entry in parse_team_entries(defaults_output):
		if not teams.has(str(entry["id"])):
			teams.append(str(entry["id"]))
	return teams


static func _plist_value(line: String) -> String:
	return line.get_slice("=", 1).strip_edges().trim_suffix(";").strip_edges().trim_prefix("\"").trim_suffix("\"")


## Teams with their display names, in Xcode's order: [{id, name}, …]. The
## defaults blocks list teamID before teamName, so a name attaches to the most
## recent id.
static func parse_team_entries(defaults_output: String) -> Array:
	var entries: Array = []
	var seen := {}
	for line in defaults_output.split("\n"):
		var s := line.strip_edges()
		if s.begins_with("teamID"):
			var id := _plist_value(s)
			if id != "" and not seen.has(id):
				seen[id] = true
				entries.append({"id": id, "name": ""})
		elif s.begins_with("teamName") and not entries.is_empty():
			if str(entries[-1]["name"]) == "":
				entries[-1]["name"] = _plist_value(s)
	return entries


## The dock's team-picker source.
func list_teams() -> Array:
	var r: Dictionary = Exec.run(PackedStringArray(["defaults", "read", "com.apple.dt.Xcode", "IDEProvisioningTeamByIdentifier"]))
	return parse_team_entries(str(r["output"]))


func _check_account() -> Dictionary:
	var r: Dictionary = Exec.run(PackedStringArray(["defaults", "read", "com.apple.dt.Xcode", "IDEProvisioningTeamByIdentifier"]))
	var teams := parse_teams(str(r["output"]))
	if int(r["code"]) != 0 or teams.is_empty():
		var status := "warn" if has_asc_key() else "fail"
		return _row("ios.account", "Xcode account", status, "no signed-in teams",
			"Sign into Xcode (Xcode → Settings → Accounts → ＋). Not needed once an ASC API key is configured — cloud signing then works headless.",
			false, [{"label": "Apple Developer account", "url": "https://developer.apple.com/account"}])
	return _row("ios.account", "Xcode account", "ok", "teams: " + ", ".join(teams))


func _check_dist_cert() -> Dictionary:
	var r: Dictionary = Exec.run(PackedStringArray(["security", "find-identity", "-v", "-p", "codesigning"]))
	var out := str(r["output"])
	if out.contains("Apple Distribution") or out.contains("iOS Distribution"):
		return _row("ios.dist_cert", "Distribution certificate", "ok", "in keychain")
	return _row("ios.dist_cert", "Distribution certificate", "warn", "not in keychain",
		"1. Xcode → Settings → Accounts → select your team\n2. Manage Certificates… → ＋ (bottom-left) → Apple Distribution\n3. Refresh here.",
		false, [{"label": "Open Xcode", "url": "/Applications/Xcode.app"}])


func _check_asc_key() -> Dictionary:
	var c := asc_credentials()
	var links := [{"label": "Create API key", "url": "https://appstoreconnect.apple.com/access/integrations/api"}]
	if c["key_id"] == "" and c["key_path"] == "":
		return _row("ios.asc_key", "App Store Connect API key", "warn", "not configured",
			"1. ↗ Create API key → ＋ → any name, role: App Manager → Generate\n2. Download the .p8, then drop it on this panel (or Browse…)\n3. Copy the Issuer ID from the top of that page into the field below and Save",
			false, links)
	if c["key_path"] == "" or not FileAccess.file_exists(c["key_path"]):
		return _row("ios.asc_key", "App Store Connect API key", "fail", c["key_path"],
			"The key file is missing — re-drop the downloaded AuthKey_%s.p8 onto this panel (or Browse…)." % c["key_id"],
			false, links)
	if c["issuer_id"] == "":
		return _row("ios.asc_key", "App Store Connect API key", "warn",
			"key %s — missing Issuer ID" % c["key_id"],
			"Nearly there: copy the Issuer ID (top of the API-keys page, it has a Copy button) into the field below and Save.",
			false, links)
	var py: Dictionary = Exec.run(PackedStringArray(["command", "-v", "python3"]))
	if int(py["code"]) != 0:
		return _row("ios.asc_key", "App Store Connect API key", "warn", "python3 missing",
			"The ASC probes need python3 (ships with the Xcode command-line tools): xcode-select --install")
	# Fully configured — validate that the key actually belongs to the preset's
	# team before trusting any probe made with it (a wrong-team key answers
	# every query truthfully about the WRONG team).
	if _asc_proc.is_empty():
		_asc_phase = "team"
		_asc_proc = _spawn_asc("team-info", "-", "asc_team_info.log")
		_asc_started_ms = Time.get_ticks_msec()
	return _row("ios.asc_key", "App Store Connect API key", "busy", "validating key %s…" % c["key_id"])


func _check_app_record() -> Dictionary:
	var preset := load_preset("iOS")
	if preset.is_empty():
		return _row("ios.app_record", "App Store Connect app record", "warn", "needs a preset first")
	if not has_asc_key():
		return _row("ios.app_record", "App Store Connect app record", "warn",
			"unknown (no API key)",
			"Without an API key this is only verified at upload time — the upload error will carry the create-app steps if the record is missing.",
			false, [{"label": "Open My Apps", "url": "https://appstoreconnect.apple.com/apps"}])
	return _row("ios.app_record", "App Store Connect app record", "busy", "waiting for key validation…")


## "Name (ID)" when the team is signed into Xcode, else the bare id.
func _team_label(team_id: String) -> String:
	for entry in list_teams():
		if str(entry["id"]) == team_id and str(entry["name"]) != "":
			return "%s (%s)" % [entry["name"], team_id]
	return team_id


func _check_devices() -> Dictionary:
	var r: Dictionary = Exec.run(PackedStringArray(["xcrun", "devicectl", "list", "devices"]))
	var available := 0
	for line in str(r["output"]).split("\n"):
		if line.contains("available"):
			available += 1
	if int(r["code"]) != 0:
		return _row("ios.devices", "Paired device", "warn", "devicectl unavailable")
	if available == 0:
		return _row("ios.devices", "Paired device", "warn", "none",
			"Only needed for direct on-device installs — TestFlight builds don't require one. Pair via Xcode → Window → Devices and Simulators.")
	return _row("ios.devices", "Paired device", "ok", "%d available" % available)


# ── Android preflight (new checks; not wired into refresh_preflight() yet) ────

## The same .tpz download contains templates for every platform — just a
## different file to check for here (android_debug.apk, not ios.zip). Only
## that one matters this pass; android_release.apk/source.zip are for
## AAB/Gradle Build, both deferred.
func _check_android_templates() -> Dictionary:
	var v: Dictionary = Engine.get_version_info()
	var ver := version_tag(v) + "." + str(v["status"])
	if not FileAccess.file_exists(templates_dir().path_join("android_debug.apk")):
		if templates_url(v) == "":
			return _row("android.templates", "Android export templates", "fail", ver,
				"1. Editor → Manage Export Templates → Download and Install (no direct download for non-stable builds).")
		return _row("android.templates", "Android export templates", "fail", ver,
			"1. Press Fix — downloads the official %s template pack (~1 GB, several minutes) and installs it." % ver,
			true)
	return _row("android.templates", "Android export templates", "ok", ver)


## sdk_path is Editor Settings' android_sdk_path, fetched fresh by the dock
## each refresh (this service can't read EditorSettings itself). Fixable
## only when the conventional install location has something to point at;
## `fix_value` carries the resolved path for the dock to write directly.
func _check_android_sdk(sdk_path: String) -> Dictionary:
	if sdk_path != "" and DirAccess.dir_exists_absolute(sdk_path):
		return _row("android.sdk", "Android SDK", "ok", sdk_path)
	var conventional := android_sdk_conventional_path()
	if DirAccess.dir_exists_absolute(conventional):
		var row := _row("android.sdk", "Android SDK", "warn",
			_toolchain_path_detail(sdk_path) + " — found at " + conventional,
			"1. Press Fix — points Editor Settings at the SDK found here\n2. Refresh preflight.",
			true)
		row["fix_value"] = conventional
		return row
	return _row("android.sdk", "Android SDK", "fail", _toolchain_path_detail(sdk_path),
		"A valid Android SDK path is required in Editor Settings.\n1. Install Android Studio (it bundles the SDK) or the standalone command-line tools\n2. Editor → Editor Settings → Export → Android → Android SDK Path\n3. Refresh preflight.",
		false, [{"label": "Android Studio", "url": "https://developer.android.com/studio"}])


## jdk_path is Editor Settings' java_sdk_path, fetched fresh by the dock
## (this service can't read EditorSettings itself). Falls back to
## JAVA_HOME, then Android Studio's bundled runtime, before failing — a
## fixable row's `fix_value` is whichever of those two the dock should write.
func _check_android_jdk(jdk_path: String) -> Dictionary:
	if jdk_path != "" and DirAccess.dir_exists_absolute(jdk_path):
		return _row("android.jdk", "Java SDK", "ok", jdk_path)
	var java_home := OS.get_environment("JAVA_HOME")
	if java_home != "" and DirAccess.dir_exists_absolute(java_home):
		var row := _row("android.jdk", "Java SDK",
			"warn", _toolchain_path_detail(jdk_path) + " — found via JAVA_HOME: " + java_home,
			"1. Press Fix — points Editor Settings at JAVA_HOME\n2. Refresh preflight.",
			true)
		row["fix_value"] = java_home
		return row
	var jbr := android_studio_jbr_path()
	if DirAccess.dir_exists_absolute(jbr):
		var row := _row("android.jdk", "Java SDK",
			"warn", _toolchain_path_detail(jdk_path) + " — found Android Studio's bundled JDK: " + jbr,
			"1. Press Fix — points Editor Settings at Android Studio's bundled JDK\n2. Refresh preflight.",
			true)
		row["fix_value"] = jbr
		return row
	return _row("android.jdk", "Java SDK", "fail", _toolchain_path_detail(jdk_path),
		"A valid Java SDK path is required in Editor Settings.\n1. Install a JDK (Android Studio bundles one, or install one standalone)\n2. Editor → Editor Settings → Export → Android → Java SDK Path\n3. Refresh preflight.",
		false, [{"label": "Android Studio", "url": "https://developer.android.com/studio"}])


## Shared "not configured" vs "configured but wrong" detail text for
## Android's toolchain-path checks.
static func _toolchain_path_detail(configured_path: String) -> String:
	return "not configured" if configured_path == "" else "configured path missing (%s)" % configured_path


## Picks windows, linux, or macos by os_name — anything other than
## "Windows"/"Linux" falls back to macos.
static func pick_by_os(os_name: String, windows: String, linux: String, macos: String) -> String:
	match os_name:
		"Windows":
			return windows
		"Linux":
			return linux
		_:
			return macos


## Where the Android SDK conventionally lives after an Android Studio
## install — the "is it here even though nobody told us" fallback the Fix
## checks before writing anything.
static func android_sdk_conventional_path() -> String:
	return pick_by_os(OS.get_name(),
		OS.get_environment("LOCALAPPDATA").path_join("Android/Sdk"),
		OS.get_environment("HOME").path_join("Android/Sdk"),
		OS.get_environment("HOME").path_join("Library/Android/sdk"))


## Android Studio's own bundled JDK (JBR), checked only when JAVA_HOME
## isn't set. Less reliable than a plain SDK path guess: Android Studio's
## own install location varies more, especially per-user Windows/Linux installs.
static func android_studio_jbr_path() -> String:
	return pick_by_os(OS.get_name(),
		"C:/Program Files/Android/Android Studio/jbr",
		"/opt/android-studio/jbr",
		"/Applications/Android Studio.app/Contents/jbr/Contents/Home")


## adb isn't guaranteed on PATH (confirmed absent on a default macOS
## install) — prefers the SDK's own platform-tools, falling back to a bare
## command name.
static func resolve_adb_path(sdk_path: String) -> String:
	var exe_name := "adb.exe" if OS.get_name() == "Windows" else "adb"
	if sdk_path != "":
		var candidate := sdk_path.path_join("platform-tools").path_join(exe_name)
		if FileAccess.file_exists(candidate):
			return candidate
	return exe_name


## Parses `adb devices -l` into [{serial, state, model}, ...] for a future
## device picker. `state` lets callers tell "unauthorized"/"offline" apart
## from a ready ("device") one.
static func parse_adb_devices(output: String) -> Array:
	var devices: Array = []
	var seen_header := false
	for line in output.split("\n"):
		var s := line.strip_edges()
		if not seen_header:
			# skip everything until adb's device-list header — a cold server
			# prints "* daemon … *" startup lines (on stderr, captured via 2>&1)
			# before it
			if s.begins_with("List of devices"):
				seen_header = true
			continue
		if s.is_empty():
			continue
		var tokens := s.split(" ", false)
		if tokens.size() < 2:
			continue
		var model := ""
		for token in tokens:
			if token.begins_with("model:"):
				model = token.trim_prefix("model:")
		devices.append({"serial": tokens[0], "state": tokens[1], "model": model})
	return devices


## The dock's device-picker source (role of list_teams()).
func list_adb_devices(sdk_path: String) -> Array:
	var r: Dictionary = Exec.run(PackedStringArray([resolve_adb_path(sdk_path), "devices", "-l"]))
	return parse_adb_devices(str(r["output"]))


## Android's only build mode this pass IS a device install, so "no ready
## device" is a hard fail here (iOS's device row is a warn — TestFlight/.ipa
## export don't need a physical device).
func _check_android_devices(sdk_path: String) -> Dictionary:
	var adb := resolve_adb_path(sdk_path)
	var r: Dictionary = Exec.run(PackedStringArray([adb, "devices", "-l"]))
	if int(r["code"]) != 0:
		return _row("android.devices", "Device", "warn", "adb unavailable",
			"Needs a working Android SDK first — see the SDK row above.")
	var devices := parse_adb_devices(str(r["output"]))
	var ready: Array = devices.filter(func(d): return str(d["state"]) == "device")
	if devices.is_empty():
		return _row("android.devices", "Device", "fail", "none",
			"1. Plug in an Android device with USB debugging enabled (Settings → Developer options), or start an emulator\n2. Refresh preflight.")
	if ready.is_empty():
		return _row("android.devices", "Device", "fail", "%d connected, none authorized" % devices.size(),
			"A device is connected but hasn't accepted the debugging prompt yet.\n1. On the device, accept the \"Allow USB debugging\" RSA fingerprint prompt\n2. Refresh preflight.")
	return _row("android.devices", "Device", "ok", "%d available" % ready.size())


## Verified against engine source (not inferred): OS.get_data_dir()/godot/
## keystores/debug.keystore, lowercase "godot".
static func default_debug_keystore_path() -> String:
	return OS.get_data_dir().path_join("godot/keystores/debug.keystore")


## No Fix — Godot manages this file itself. Treats path/user/pass as one
## all-or-nothing group, per Godot's error text (exact validation rule
## unconfirmed). A preset-level override or GODOT_ANDROID_KEYSTORE_DEBUG_*
## env vars could make the keystore Godot actually uses diverge from what
## this row reports.
func _check_android_debug_keystore(keystore_path: String, keystore_user: String, keystore_pass: String) -> Dictionary:
	var configured := int(keystore_path != "") + int(keystore_user != "") + int(keystore_pass != "")
	if configured != 0 and configured != 3:
		return _row("android.debug_keystore", "Debug keystore", "fail", "inconsistent config",
			"Either Debug Keystore, Debug User AND Debug Password settings must be configured OR none of them.")
	if configured == 3:
		if FileAccess.file_exists(keystore_path):
			return _row("android.debug_keystore", "Debug keystore", "ok", keystore_path)
		return _row("android.debug_keystore", "Debug keystore", "fail", _toolchain_path_detail(keystore_path),
			"1. Fix the path under Editor → Editor Settings → Export → Android → Debug Keystore, or clear all three debug keystore fields to let Godot manage its own default\n2. Refresh preflight.")
	var default_path := default_debug_keystore_path()
	if FileAccess.file_exists(default_path):
		return _row("android.debug_keystore", "Debug keystore", "ok", "Godot-managed default: " + default_path)
	return _row("android.debug_keystore", "Debug keystore", "warn", "not yet generated",
		"Godot creates this automatically on first export, using the JDK configured above. Nothing to do here yet — Refresh after your first export to confirm it was created.")


## Confirms an Android export preset exists, has its required base config
## keys, and has an export_path Godot can actually write an APK to.
func _check_android_preset() -> Dictionary:
	var preset := load_preset("Android")
	if preset.is_empty():
		return _row("android.preset", "Android export preset", "fail", "",
			"No Android export preset found. Create one in Project → Export (platform Android).")
	var problems := PackedStringArray()
	var export_path := str(preset["export_path"])
	if export_path == "":
		problems.append("no export path")
	elif not export_path.ends_with(".apk"):
		problems.append("export path must end in .apk")
	var missing := _missing_base_keys(preset["section"])
	if not missing.is_empty():
		problems.append("%d missing base keys" % missing.size())
	var detail := "%s → %s" % [preset["name"], preset["export_path"]]
	if problems.is_empty():
		return _row("android.preset", "Android export preset", "ok", detail)
	return _row("android.preset", "Android export preset", "warn",
		detail + " (" + ", ".join(problems) + ")",
		"1. Press Fix — sets a default export path (and backfills missing base keys)\n2. Refresh preflight.", true)


## Backfills a missing/invalid export_path and missing base preset keys.
## Only writes export_presets.cfg — no Editor Settings involved.
func _fix_android_preset() -> Dictionary:
	var preset := load_preset("Android")
	if preset.is_empty():
		return err("No Android preset to fix — create one first.")
	var cfg := ConfigFile.new()
	if cfg.load("res://export_presets.cfg") != OK:
		return err("Cannot parse export_presets.cfg.")
	var msgs := PackedStringArray()
	var export_path := str(preset["export_path"])
	if export_path == "" or not export_path.ends_with(".apk"):
		var default_path := "build/android/%s.apk" % clean_app_name()
		cfg.set_value(str(preset["section"]), "export_path", default_path)
		msgs.append("export_path=" + default_path)
	var defaults := preset_base_defaults()
	var healed := 0
	for key in defaults:
		if not cfg.has_section_key(str(preset["section"]), key):
			cfg.set_value(str(preset["section"]), key, defaults[key])
			healed += 1
	if healed > 0:
		msgs.append("backfilled %d base keys" % healed)
	if cfg.save("res://export_presets.cfg") != OK:
		return err("Cannot write export_presets.cfg.")
	mark_dirty()
	refresh_preflight()
	return ok({"message": ", ".join(msgs) if not msgs.is_empty() else "nothing to fix"})


func _spawn_asc(command: String, bundle_id: String, log_name: String) -> Dictionary:
	var c := asc_credentials()
	var helper := ProjectSettings.globalize_path(
		get_script().resource_path.get_base_dir().path_join("asc_helper.py"))
	# -B: no .pyc/__pycache__ droppings inside the vendored addon folder.
	return Exec.spawn_logged(PackedStringArray([
		"python3", "-B", helper,
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
			var row_id := "ios.asc_key" if _asc_phase == "team" else "ios.app_record"
			_set_row(row_id, "warn", "check timed out", "Network problem reaching the App Store Connect API — Refresh to retry.")
		return
	var result := _parse_helper_json(Exec.read_all(_asc_proc["log"]))
	_asc_proc = {}
	var preset := load_preset("iOS")
	var bundle := str(preset.get("bundle_id", ""))
	if _asc_phase == "team":
		_handle_team_info(result, preset)
		return
	if not result.get("ok", false):
		_set_row("ios.app_record", "warn", "check failed", "ASC API error: %s" % result.get("error", "unknown"))
	elif result.get("found", false):
		var apps: Array = result.get("apps", [])
		var name := str(apps[0].get("name", "")) if not apps.is_empty() else ""
		_set_row("ios.app_record", "ok", name)
	elif not result.get("bundle_registered", true):
		# Nothing has registered the App ID yet (signing does it, but only once
		# a first build has run) — the New App dialog's dropdown would be empty.
		_set_row("ios.app_record", "fail", "bundle id not registered",
			"1. Press Fix — registers %s on the team through the API key\n2. Then: My Apps → ＋ → New App → pick it from the Bundle ID dropdown." % bundle,
			[{"label": "Register manually", "url": "https://developer.apple.com/account/resources/identifiers/add/bundleId"}],
			true)
	else:
		_set_row("ios.app_record", "fail", "missing for " + bundle,
			"One-time manual step (app creation is not in Apple's public API, ~2 min):\n1. My Apps → ＋ → New App\n2. Platform iOS; Name: unique across the App Store\n3. Bundle ID: pick %s from the dropdown\n4. SKU: any internal id. Then Refresh." % bundle,
			[{"label": "Open My Apps", "url": "https://appstoreconnect.apple.com/apps"}])


## Phase-1 result: does the key's team match the preset's team? Only a match
## unlocks the app-record probe — a wrong-team key answers every query
## truthfully about the wrong team, so its results must never be shown.
func _handle_team_info(result: Dictionary, preset: Dictionary) -> void:
	var c := asc_credentials()
	var expected := str(preset.get("team_id", ""))
	var key_links := [{"label": "Create API key", "url": "https://appstoreconnect.apple.com/access/integrations/api"}]
	if not result.get("ok", false):
		var error := str(result.get("error", "unknown"))
		if error.contains("401") or error.contains("NOT_AUTHORIZED"):
			_set_row("ios.asc_key", "fail", "key %s rejected" % c["key_id"],
				"1. ↗ Create API key — the stored key is invalid or revoked; make a new one (role: App Manager)\n2. Drop the new .p8 on this panel\n3. Paste its Issuer ID and Save.", key_links)
		else:
			_set_row("ios.asc_key", "warn", "validation failed", "ASC API error: %s" % error)
		_set_row("ios.app_record", "warn", "skipped (key not validated)")
		return
	var got := str(result.get("team_id", ""))
	if expected != "" and got != "" and got != expected:
		_set_row("ios.asc_key", "fail",
			"wrong team — key %s → %s" % [c["key_id"], _team_label(got)],
			"This project targets %s, but the key belongs to %s.\n1. ↗ Create API key — first switch the team picker (top right of that page) to %s\n2. ＋ → any name, role: App Manager → Generate → Download\n3. Drop the new .p8 on this panel, paste that page's Issuer ID, Save." % [
				_team_label(expected), _team_label(got), _team_label(expected)],
			key_links)
		_set_row("ios.app_record", "warn", "blocked — wrong-team API key (fix the row above)")
		return
	var detail := "key %s (team unverified — no assets on the team yet)" % c["key_id"]
	if got != "":
		detail = "key %s (team %s)" % [c["key_id"], _team_label(got)]
	_set_row("ios.asc_key", "ok", detail)
	if preset.is_empty():
		_set_row("ios.app_record", "warn", "needs a preset first")
		return
	_asc_phase = "app"
	_asc_proc = _spawn_asc("check-app", str(preset["bundle_id"]), "asc_check_app.log")
	_asc_started_ms = Time.get_ticks_msec()
	_set_row("ios.app_record", "busy", "checking…")


func _set_row(id: String, status: String, detail: String, guidance := "", links: Array = [], fixable := false) -> void:
	for row in preflight_rows:
		if row["id"] == id:
			row["status"] = status
			row["detail"] = detail
			row["guidance"] = guidance
			row["links"] = links
			row["fixable"] = fixable
	preflight_changed.emit(preflight_rows)


# ── Preset creation ───────────────────────────────────────────────────────────

static func valid_bundle_id(id: String) -> bool:
	var re := RegEx.create_from_string("^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$")
	return re.search(id) != null


## Prefill for the dock's create-preset field: com.example.<project-slug>.
static func default_bundle_id() -> String:
	var name := str(ProjectSettings.get_setting("application/config/name", "game"))
	var slug := ""
	for c in name.to_lower():
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			slug += c
	return "com.example." + (slug if slug != "" else "game")


static func clean_app_name() -> String:
	var name := str(ProjectSettings.get_setting("application/config/name", "Game"))
	var out := ""
	for c in name:
		if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9"):
			out += c
	return out if out != "" else "Game"


## Write a ready-to-build iOS preset: export_project_only on (Build Kit owns
## xcodebuild), signing fields untouched (xcodebuild owns signing), team id
## auto-filled when exactly one Xcode team is signed in. `path` is overridable
## so the verifier can exercise this without touching the project.
func create_ios_preset(bundle_id: String, team_id := "", path := "res://export_presets.cfg") -> Dictionary:
	bundle_id = bundle_id.strip_edges()
	if not valid_bundle_id(bundle_id):
		return err("Bundle id must be reverse-DNS, e.g. com.studio.game.")
	if path == "res://export_presets.cfg" and not load_preset("iOS").is_empty():
		return err("An iOS preset already exists.")
	var cfg := ConfigFile.new()
	if FileAccess.file_exists(path):
		if cfg.load(path) != OK:
			return err("Cannot parse %s." % path)
	var idx := 0
	while cfg.has_section("preset.%d" % idx):
		idx += 1
	var sec := "preset.%d" % idx
	cfg.set_value(sec, "name", "iOS")
	cfg.set_value(sec, "platform", "iOS")
	cfg.set_value(sec, "runnable", true)
	# Godot's preset loader get_value()s every base key with NO default — a
	# preset missing any of these hard-errors at export time, so write the full
	# set an editor-created preset would have.
	var base := preset_base_defaults()
	for key in base:
		cfg.set_value(sec, key, base[key])
	cfg.set_value(sec, "export_path", "build/ios/%s.ipa" % clean_app_name())
	var opt := sec + ".options"
	cfg.set_value(opt, "application/export_project_only", true)
	cfg.set_value(opt, "architectures/arm64", true)
	cfg.set_value(opt, "application/bundle_identifier", bundle_id)
	cfg.set_value(opt, "application/export_method_debug", 1)
	cfg.set_value(opt, "application/export_method_release", 0)
	cfg.set_value(opt, "application/targeted_device_family", 2)
	cfg.set_value(opt, "application/short_version", "1.0")
	cfg.set_value(opt, "application/version", "1.0")
	var msg := "iOS preset created (%s)" % bundle_id
	if team_id != "":
		cfg.set_value(opt, "application/app_store_team_id", team_id)
		msg += ", team " + team_id
	else:
		var teams := parse_teams(str(Exec.run(PackedStringArray(
			["defaults", "read", "com.apple.dt.Xcode", "IDEProvisioningTeamByIdentifier"]))["output"]))
		if teams.size() == 1:
			cfg.set_value(opt, "application/app_store_team_id", teams[0])
			msg += ", team " + teams[0]
	if cfg.save(path) != OK:
		return err("Cannot write %s." % path)
	if path == "res://export_presets.cfg":
		mark_dirty()
		refresh_preflight()
	return ok({"message": msg + "."})


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
## 600, and persist the id + path into the gitignored .env — NOT into
## build_kit.config.json, which is committed. The Issuer ID is NOT in the file —
## set_asc_issuer() completes the pair.
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
	var env_file := write_env_vars({"ASC_KEY_ID": key_id, "ASC_KEY_PATH": tildify(dest)})
	if env_file == "":
		return err("Key copied to %s but %s could not be written." % [dest, env_write_path()])
	refresh_preflight()
	var need_issuer: bool = str(asc_credentials().get("issuer_id", "")) == ""
	return ok({"message": "Key %s installed at %s; id + path saved to %s.%s" % [key_id, dest, env_file,
		" Now paste the Issuer ID and Save." if need_issuer else ""]})


func set_asc_issuer(issuer: String) -> Dictionary:
	issuer = issuer.strip_edges()
	if issuer == "":
		return err("Paste the Issuer ID first — it's at the top of the API-keys page (Copy button).")
	if issuer.count("-") != 4 or issuer.length() < 32:
		return err("That doesn't look like an Issuer ID (a UUID like 69a6de78-…). Copy it from the top of the API-keys page.")
	var env_file := write_env_vars({"ASC_ISSUER_ID": issuer})
	if env_file == "":
		return err("Could not write %s." % env_write_path())
	refresh_preflight()
	return ok({"message": "Issuer ID saved to %s." % env_file})


# ── Fixes ─────────────────────────────────────────────────────────────────────

## The preset fix: writes export_project_only=true and, when the preset has no
## Team ID, fills it from the signed-in Xcode account (only when exactly one
## team is available — with several, choosing is the user's call).
func apply_fix(id: String, opts: Dictionary = {}) -> Dictionary:
	match id:
		"ios.preset":
			return _fix_preset(str(opts.get("team_id", "")))
		"ios.templates", "android.templates":
			return _fix_templates(id)
		"etc2":
			return _fix_etc2()
		"ios.app_record":
			return _fix_bundle_id()
		"android.preset":
			return _fix_android_preset()
	return err("No fix for '%s'." % id)


## Register the preset's App ID on the developer portal through the API key —
## the same operation as Identifiers → ＋, so the New App dialog's Bundle ID
## dropdown has something to pick.
func _fix_bundle_id() -> Dictionary:
	if not _fix_proc.is_empty():
		return err("A fix is already running.")
	if not has_asc_key():
		return err("Needs an ASC API key (see the row above).")
	var preset := load_preset("iOS")
	if preset.is_empty():
		return err("No iOS preset.")
	var handle := _spawn_asc("ensure-bundle-id", preset["bundle_id"], "asc_bundle_id.log")
	if not handle.get("ok", false):
		return err(str(handle.get("error", "spawn failed")))
	handle["label"] = "bundle-id registration"
	_fix_proc = handle
	_set_row("ios.app_record", "busy", "registering %s…" % preset["bundle_id"])
	log_line.emit("\n── bundle-id registration ──\n", "ios")
	return ok({"message": "Registering the bundle id via the API key…"})


## Download the official export-template pack for the running Godot version and
## install it where the editor expects it — the same result as Manage Export
## Templates → Download and Install, without the dialog. `row_id` is whichever
## of ios.templates/android.templates triggered the Fix, so the busy indicator
## and log lines tag the right platform. Uses HTTPRequest + ZIPReader — no
## shell, so no OS branch needed.
func _fix_templates(row_id: String) -> Dictionary:
	if not _fix_proc.is_empty():
		return err("A fix is already running.")
	var v: Dictionary = Engine.get_version_info()
	var url := templates_url(v)
	if url == "":
		return err("No direct download for non-stable Godot builds — use Editor → Manage Export Templates.")
	var dest := templates_dir()
	var cache := OS.get_cache_dir().path_join("build_kit")
	var tpz := cache.path_join("templates.tpz")
	DirAccess.make_dir_recursive_absolute(cache)
	var platform := row_id.get_slice(".", 0)
	var http := HTTPRequest.new()
	http.download_file = tpz
	add_child(http)
	http.request_completed.connect(_on_templates_downloaded.bind(row_id, platform, dest, tpz, http))
	var request_err := http.request(url)
	if request_err != OK:
		http.queue_free()
		return err("Couldn't start the download (err %d)." % request_err)
	_fix_proc = {"label": "templates install", "platform": platform}
	_set_row(row_id, "busy", "downloading + installing (~1 GB, several minutes)…")
	log_line.emit("\n── templates install ──\n%s\n→ %s\n" % [url, dest], platform)
	return ok({"message": "Downloading export templates — the row updates when done."})


## "" for anything not under the templates/ prefix (including the bare
## directory-marker entry itself) — the filter half of the extraction, kept
## pure so the verifier can exercise it without a real zip or network.
static func _templates_zip_target(entry: String, dest: String) -> String:
	if not entry.begins_with("templates/") or entry == "templates/":
		return ""
	return dest.path_join(entry.trim_prefix("templates/"))


func _on_templates_downloaded(result: int, response_code: int, _headers: PackedStringArray,
		_body: PackedByteArray, row_id: String, platform: String, dest: String, tpz: String, http: HTTPRequest) -> void:
	http.queue_free()
	_fix_proc = {}
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		log_line.emit("templates install FAILED (result %d, HTTP %d) — see above.\n" % [result, response_code], platform)
		refresh_preflight()
		return
	var reader := ZIPReader.new()
	if reader.open(tpz) != OK:
		log_line.emit("templates install FAILED — could not open downloaded archive.\n", platform)
		refresh_preflight()
		return
	for entry in reader.get_files():
		var target := _templates_zip_target(entry, dest)
		if target == "":
			continue
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var f := FileAccess.open(target, FileAccess.WRITE)
		if f == null:
			continue
		f.store_buffer(reader.read_file(entry))
		f.close()
	reader.close()
	DirAccess.remove_absolute(tpz)
	log_line.emit("templates install finished.\n", platform)
	refresh_preflight()


func _poll_fix() -> void:
	if _fix_proc.is_empty() or not _fix_proc.has("exit_path"):
		return
	var platform := str(_fix_proc.get("platform", "ios"))
	var tail: Dictionary = Exec.read_from(_fix_proc["log"], int(_fix_proc.get("offset", 0)))
	if str(tail["text"]) != "":
		_fix_proc["offset"] = tail["offset"]
		log_line.emit(str(tail["text"]), platform)
	var code := Exec.exit_code(_fix_proc["exit_path"])
	if code < 0:
		return
	var label := str(_fix_proc.get("label", "fix"))
	_fix_proc = {}
	log_line.emit("%s finished.\n" % label if code == 0
		else "%s FAILED (exit %d) — see above.\n" % [label, code], platform)
	refresh_preflight()


## Every base key Godot's preset loader reads with no default, with the value
## an editor-created preset carries — used both when generating a preset and
## when healing one a leaner generator (or hand edit) left incomplete.
static func preset_base_defaults() -> Dictionary:
	return {
		"advanced_options": false,
		"dedicated_server": false,
		"custom_features": "",
		"export_filter": "all_resources",
		"include_filter": "",
		"exclude_filter": "",
		"patches": PackedStringArray(),
		"encryption_include_filters": "",
		"encryption_exclude_filters": "",
		"seed": 0,
		"encrypt_pck": false,
		"encrypt_directory": false,
		"script_export_mode": 2,
	}


func _missing_base_keys(section: String) -> PackedStringArray:
	var out := PackedStringArray()
	var cfg := ConfigFile.new()
	if cfg.load("res://export_presets.cfg") != OK:
		return out
	for key in preset_base_defaults():
		if not cfg.has_section_key(section, key):
			out.append(key)
	return out


func _fix_preset(team_id := "") -> Dictionary:
	var preset := load_preset("iOS")
	if preset.is_empty():
		return err("No iOS preset to fix — create one with the form below first.")
	var cfg := ConfigFile.new()
	if cfg.load("res://export_presets.cfg") != OK:
		return err("Cannot parse export_presets.cfg.")
	var opt: String = preset["section"] + ".options"
	cfg.set_value(opt, "application/export_project_only", true)
	var msg := "export_project_only=true"
	var defaults := preset_base_defaults()
	var healed := 0
	for key in defaults:
		if not cfg.has_section_key(str(preset["section"]), key):
			cfg.set_value(str(preset["section"]), key, defaults[key])
			healed += 1
	if healed > 0:
		msg += ", backfilled %d base keys" % healed
	if team_id != "":
		cfg.set_value(opt, "application/app_store_team_id", team_id)
		msg += ", team_id=" + team_id
	elif preset["team_id"] == "":
		var teams := parse_teams(str(Exec.run(PackedStringArray(
			["defaults", "read", "com.apple.dt.Xcode", "IDEProvisioningTeamByIdentifier"]))["output"]))
		if teams.size() == 1:
			cfg.set_value(opt, "application/app_store_team_id", teams[0])
			msg += ", team_id=" + teams[0]
		else:
			msg += " — pick a team in the dropdown and press Fix again"
	if cfg.save("res://export_presets.cfg") != OK:
		return err("Cannot write export_presets.cfg.")
	mark_dirty()
	refresh_preflight()
	return ok({"message": msg})
