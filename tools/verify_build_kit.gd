extends SceneTree

## Headless verifier for the build_kit addon's service logic: shell quoting,
## failure classification, preset parsing, export-options generation, env
## parsing, teams parsing, helper-JSON parsing, a real spawn round-trip
## through exec.gd's log + exit-sentinel contract, and the iOS signing stages
## (command lines + the .ipa entitlement check, end to end on macOS), and the
## one-command release CLI (cli/release_core.gd) with git and ASC mocked.
## Run: godot --headless --path . --script res://tools/verify_build_kit.gd

const Exec := preload("res://addons/build_kit/exec.gd")
const Classify := preload("res://addons/build_kit/classify.gd")
const ServiceT := preload("res://addons/build_kit/build_kit_service.gd")
const Itch := preload("res://addons/build_kit/itch.gd")
const Release := preload("res://addons/build_kit/cli/release_core.gd")

var _fails := 0


func _check(name: String, passed: bool, detail := "") -> void:
	if passed:
		print("  ok  %s" % name)
	else:
		_fails += 1
		print("  FAIL %s  %s" % [name, detail])


const PRESET_FIXTURE := """
[preset.0]

name="macOS"
platform="macOS"
export_path="../build/macos/Game.zip"

[preset.0.options]

codesign/codesign=0

[preset.1]

name="iOS"
platform="iOS"
runnable=true
export_path="../build/ios/Game.ipa"

[preset.1.options]

application/export_project_only=true
application/app_store_team_id="TEAM123456"
application/bundle_identifier="com.example.game"
"""


func _initialize() -> void:
	print("VERIFY build_kit: running")

	# exec.gd quoting — cmd.exe (double quotes) on Windows, POSIX (single
	# quotes) elsewhere.
	if OS.get_name() == "Windows":
		_check("quote plain", Exec.quote("abc") == "\"abc\"")
		_check("quote space", Exec.quote("a b") == "\"a b\"")
		_check("quote embedded quote", Exec.quote("a\"b") == "\"a\"\"b\"")
		_check("command_line", Exec.command_line(PackedStringArray(["x", "a b"])) == "\"x\" \"a b\"")
	else:
		_check("quote plain", Exec.quote("abc") == "'abc'")
		_check("quote space", Exec.quote("a b") == "'a b'")
		_check("quote apostrophe", Exec.quote("a'b") == "'a'\\''b'")
		_check("command_line", Exec.command_line(PackedStringArray(["x", "a b"])) == "'x' 'a b'")

	# classify.gd
	var missing := Classify.classify("Step failed: IDEDistribution.DistributionAppRecordProviderError.missingApp(bundleId: \"com.x\")", {"bundle_id": "com.x"}, "ios")
	_check("classify missingApp", missing["id"] == "missing_app_record", str(missing))
	_check("classify guidance splice", str(missing["guidance"]).contains("com.x"))
	var conflict := Classify.classify("error: Moveborne has conflicting provisioning settings.", {}, "ios")
	_check("classify signing conflict", conflict["id"] == "signing_conflict")
	var no_cert := Classify.classify("error: exportArchive No signing certificate \"iOS Distribution\" found\n** EXPORT FAILED **", {"team_id": "T1"}, "ios")
	_check("classify missing dist cert", no_cert["id"] == "no_dist_cert", str(no_cert))
	_check("classify dist cert splice", str(no_cert["guidance"]).contains("T1"))
	var perm := Classify.classify("error: exportArchive Cloud signing permission error\nerror: exportArchive Provisioning profile \"X\" doesn't include signing certificate \"Y\".", {"key_id": "K9"}, "ios")
	_check("classify cloud-signing permission first", perm["id"] == "cloud_signing_permission", str(perm))
	_check("classify key id splice", str(perm["guidance"]).contains("K9"))
	var stale := Classify.classify("error: exportArchive Provisioning profile \"X\" doesn't include signing certificate \"Y\".", {}, "ios")
	_check("classify stale managed profile", stale["id"] == "profile_missing_cert", str(stale))
	var generic := Classify.classify("something entirely novel")
	_check("classify fallback", generic["id"] == "unknown")
	var cfg_err := Classify.classify("ERROR: Cannot export project with preset \"iOS\" due to configuration errors:\n\n   at: _fs_changed")
	_check("classify empty config errors", cfg_err["id"] == "export_config_errors", str(cfg_err))
	_check("classify links passthrough", str(missing.get("links", [])).contains("appstoreconnect.apple.com/apps"), str(missing))
	_check("classify fallback links empty", (generic.get("links", [1]) as Array).is_empty())
	var order := Classify.classify("error: exportArchive Error Downloading App Information\n** EXPORT FAILED **", {}, "ios")
	_check("classify specific beats generic", order["id"] == "missing_app_record", str(order))

	# classify.gd platform scoping
	var ios_on_android := Classify.classify("error: exportArchive Cloud signing permission error", {}, "android")
	_check("classify ios rule doesn't match android", ios_on_android["id"] == "unknown", str(ios_on_android))
	var android_incompatible := Classify.classify("adb: failed to install game.apk: INSTALL_FAILED_UPDATE_INCOMPATIBLE", {}, "android")
	_check("classify android install incompatible", android_incompatible["id"] == "install_update_incompatible", str(android_incompatible))
	var android_on_ios := Classify.classify("adb: failed to install game.apk: INSTALL_FAILED_UPDATE_INCOMPATIBLE", {}, "ios")
	_check("classify android rule doesn't match ios", android_on_ios["id"] == "unknown", str(android_on_ios))
	var neutral_templates := Classify.classify("No export template found for platform \"Android\".", {}, "android")
	_check("classify unscoped rule matches android", neutral_templates["id"] == "no_export_templates", str(neutral_templates))
	_check("classify no_export_templates wording is platform-neutral", not str(neutral_templates["guidance"]).contains("iOS"), str(neutral_templates))

	# preset parsing
	var preset := ServiceT.parse_preset_text(PRESET_FIXTURE, "iOS")
	_check("preset found", preset.get("name", "") == "iOS", str(preset))
	_check("preset section", preset.get("section", "") == "preset.1")
	_check("preset bundle", preset.get("bundle_id", "") == "com.example.game")
	_check("preset team", preset.get("team_id", "") == "TEAM123456")
	_check("preset project_only", preset.get("export_project_only", false) == true)
	_check("preset by name miss", ServiceT.parse_preset_text(PRESET_FIXTURE, "iOS", "nope").is_empty())
	_check("preset no ios", ServiceT.parse_preset_text("[preset.0]\nname=\"Web\"\nplatform=\"Web\"\n", "iOS").is_empty())

	# android preset parsing — base fields only, no iOS-only fields leaking in
	const ANDROID_PRESET_FIXTURE := "[preset.0]\nname=\"Android\"\nplatform=\"Android\"\nexport_path=\"../build/android/game.apk\"\n[preset.0.options]\npackage/unique_name=\"com.example.game\"\n"
	var android_preset := ServiceT.parse_preset_text(ANDROID_PRESET_FIXTURE, "Android")
	_check("preset android found", android_preset.get("name", "") == "Android", str(android_preset))
	_check("preset android export_path", android_preset.get("export_path", "") == "../build/android/game.apk", str(android_preset))
	_check("preset android has no ios-only fields",
		not android_preset.has("bundle_id") and not android_preset.has("team_id") and not android_preset.has("export_project_only"),
		str(android_preset))
	_check("preset no android", ServiceT.parse_preset_text("[preset.0]\nname=\"Web\"\nplatform=\"Web\"\n", "Android").is_empty())

	# derived paths
	var paths := ServiceT.derive_paths("/proj/game/", "../build/ios/Game.ipa", "iOS")
	_check("paths out", paths["out"] == "/proj/build/ios/Game.ipa", str(paths))
	_check("paths app", paths["app"] == "Game")
	_check("paths plist", paths["info_plist"] == "/proj/build/ios/Game/Game-Info.plist")

	var android_paths := ServiceT.derive_paths("/proj/game/", "../build/android/game.apk", "Android")
	_check("android paths out", android_paths["out"] == "/proj/build/android/game.apk", str(android_paths))
	_check("android paths logs", android_paths["logs"] == "/proj/build/android/logs", str(android_paths))
	_check("android paths has no ios-only keys",
		not android_paths.has("xcodeproj") and not android_paths.has("archive")
		and not android_paths.has("info_plist") and not android_paths.has("options_plist"),
		str(android_paths))

	# apksigner silent-failure detection
	_check("apksigner missing detected", ServiceT.apksigner_warning_signature(
		"...\n'apksigner' could not be found. Please check that the command is available...\nThe resulting APK is unsigned.\n") != "")
	_check("apksigner clean log", ServiceT.apksigner_warning_signature("Project export for platform Android successful.") == "")

	# export options plist
	var up := ServiceT.make_export_options_xml("TEAM123456", true)
	_check("options upload", up.contains("<string>upload</string>") and up.contains("app-store-connect") and up.contains("TEAM123456"))
	var local := ServiceT.make_export_options_xml("TEAM123456", false)
	_check("options export", local.contains("<string>export</string>"))

	# env parsing
	var env := ServiceT.parse_env("# c\nASC_KEY_ID=ABC\nexport ASC_KEY_PATH=\"/k/p.p8\"\nbroken\n")
	_check("env plain", env.get("ASC_KEY_ID", "") == "ABC")
	_check("env export+quotes", env.get("ASC_KEY_PATH", "") == "/k/p.p8")
	_check("env skips junk", not env.has("broken"))

	# teams parsing
	var teams := ServiceT.parse_teams("    {\n  teamID = ABCDE12345;\n  teamName = X;\n  teamID = FGHIJ67890;\n")
	_check("teams parsed", teams.size() == 2 and teams[0] == "ABCDE12345" and teams[1] == "FGHIJ67890", str(teams))

	# helper JSON parsing
	var parsed := ServiceT._parse_helper_json("noise\n{\"ok\": true, \"found\": false}\n")
	_check("helper json", parsed.get("ok", false) == true and parsed.get("found", true) == false)
	_check("helper json garbage", ServiceT._parse_helper_json("nothing here").get("ok", true) == false)

	# config defaults
	_check("default config", int(ServiceT.default_config()["ios"]["build_number"]) == 1)
	_check("default config android preset", ServiceT.default_config()["android"]["preset"] == "Android")
	_check("default config android version_code", int(ServiceT.default_config()["android"]["version_code"]) == 1)
	# ...and carries no credential fields — those belong in the gitignored .env
	var defaults: Dictionary = ServiceT.default_config()
	_check("default config holds no secrets",
		not defaults["ios"].has("asc_key_id") and not defaults["ios"].has("asc_issuer_id")
		and not defaults["ios"].has("asc_key_path"), str(defaults))

	# .env upsert
	var up_new := ServiceT.upsert_env_text("# comment\nOTHER=1\n", {"ASC_KEY_ID": "ABC"})
	_check("env upsert appends", ServiceT.parse_env(up_new).get("ASC_KEY_ID", "") == "ABC", up_new)
	_check("env upsert keeps others", ServiceT.parse_env(up_new).get("OTHER", "") == "1", up_new)
	_check("env upsert keeps comments", up_new.contains("# comment"), up_new)
	var up_over := ServiceT.upsert_env_text("ASC_KEY_ID=OLD\nOTHER=1\n", {"ASC_KEY_ID": "NEW"})
	_check("env upsert overwrites in place", ServiceT.parse_env(up_over).get("ASC_KEY_ID", "") == "NEW", up_over)
	_check("env upsert no duplicate key", up_over.count("ASC_KEY_ID") == 1, up_over)
	_check("env upsert keeps export prefix",
		ServiceT.upsert_env_text("export ASC_KEY_ID=OLD\n", {"ASC_KEY_ID": "NEW"}).begins_with("export ASC_KEY_ID=NEW"))
	var up_empty := ServiceT.upsert_env_text("", {"A": "1", "B": "2"})
	_check("env upsert from empty", ServiceT.parse_env(up_empty).get("A", "") == "1"
		and ServiceT.parse_env(up_empty).get("B", "") == "2", up_empty)
	var up_nonl := ServiceT.upsert_env_text("OTHER=1", {"A": "1"})
	_check("env upsert without trailing newline", ServiceT.parse_env(up_nonl).get("A", "") == "1"
		and ServiceT.parse_env(up_nonl).get("OTHER", "") == "1", up_nonl)
	_check("env upsert ignores commented key",
		ServiceT.upsert_env_text("#ASC_KEY_ID=OLD\n", {"ASC_KEY_ID": "NEW"}).contains("#ASC_KEY_ID=OLD"))

	# tildify — a key path must survive moving between machines
	var home := OS.get_environment("HOME")
	_check("tildify home path", ServiceT.tildify(home + "/private_keys/k.p8") == "~/private_keys/k.p8")
	_check("tildify leaves other paths", ServiceT.tildify("/opt/k.p8") == "/opt/k.p8")

	# templates download URL / version tag
	_check("version tag with patch", ServiceT.version_tag({"major": 4, "minor": 7, "patch": 1, "status": "stable"}) == "4.7.1")
	_check("version tag zero patch", ServiceT.version_tag({"major": 4, "minor": 6, "patch": 0, "status": "stable"}) == "4.6")
	_check("templates url stable", ServiceT.templates_url({"major": 4, "minor": 7, "patch": 1, "status": "stable"}) == "https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_export_templates.tpz")
	_check("templates url non-stable empty", ServiceT.templates_url({"major": 4, "minor": 8, "patch": 0, "status": "beta1"}) == "")

	# templates zip extraction target — the filter/mapping half of
	# _fix_templates()'s HTTPRequest+ZIPReader install (network + real zip I/O
	# excluded here, same as ios.templates/android.templates below)
	_check("zip target ios", ServiceT._templates_zip_target("templates/ios.zip", "/dest") == "/dest/ios.zip")
	_check("zip target android", ServiceT._templates_zip_target("templates/android_debug.apk", "/dest") == "/dest/android_debug.apk")
	_check("zip target directory marker", ServiceT._templates_zip_target("templates/", "/dest") == "")
	_check("zip target outside prefix", ServiceT._templates_zip_target("templates_source/foo.txt", "/dest") == "")
	_check("zip target unrelated file", ServiceT._templates_zip_target("README.md", "/dest") == "")

	# bundle-id validation + preset creation round-trip
	_check("bundle id ok", ServiceT.valid_bundle_id("com.studio.game-2"))
	_check("bundle id needs dot", not ServiceT.valid_bundle_id("game"))
	_check("bundle id rejects junk", not ServiceT.valid_bundle_id("com..game") and not ServiceT.valid_bundle_id("com.stu dio.game"))
	var svc2: Node = ServiceT.new()
	var tmp_preset := "user://verify_build_kit_presets.cfg"
	if FileAccess.file_exists(tmp_preset):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_preset))
	var created: Dictionary = svc2.create_ios_preset("com.example.verify", "TEAMPICKED1", tmp_preset)
	_check("create preset ok", created.get("ok", false), str(created))
	var created_text := FileAccess.open(tmp_preset, FileAccess.READ).get_as_text() if FileAccess.file_exists(tmp_preset) else ""
	var reparsed := ServiceT.parse_preset_text(created_text, "iOS")
	_check("created preset parses", reparsed.get("bundle_id", "") == "com.example.verify", created_text.left(200))
	_check("created preset project-only", reparsed.get("export_project_only", false) == true)
	# Godot's loader reads every base key with no default — all must be present.
	for base_key in ["include_filter", "exclude_filter", "patches", "encryption_include_filters",
			"encryption_exclude_filters", "seed", "encrypt_pck", "encrypt_directory",
			"script_export_mode", "custom_features", "dedicated_server", "advanced_options"]:
		_check("created preset has %s" % base_key, created_text.contains(base_key), created_text.left(400))
	_check("created preset picked team", reparsed.get("team_id", "") == "TEAMPICKED1", created_text.left(200))
	_check("create rejects bad bundle", not svc2.create_ios_preset("nodots", "", tmp_preset).get("ok", true))
	svc2.free()

	# team entries (id + display name, deduped)
	var entries := ServiceT.parse_team_entries("{\n  teamID = AAA1111111;\n  teamName = \"Studio LLC\";\n  teamID = BBB2222222;\n  teamName = Personal;\n  teamID = AAA1111111;\n")
	_check("team entries parsed", entries.size() == 2, str(entries))
	_check("team entry names", entries.size() == 2 and str(entries[0]["name"]) == "Studio LLC" and str(entries[1]["name"]) == "Personal", str(entries))

	# legacy-config migration (the decision half; the write half touches disk)
	var legacy := {"preset": "iOS", "build_number": 3, "asc_key_id": "K1", "asc_issuer_id": "I1",
		"asc_key_path": home + "/private_keys/AuthKey_K1.p8"}
	var moved := ServiceT.config_secrets_as_env(legacy)
	_check("migrate finds all three", moved.size() == 3, str(moved))
	_check("migrate maps to env names", moved.get("ASC_KEY_ID", "") == "K1"
		and moved.get("ASC_ISSUER_ID", "") == "I1", str(moved))
	_check("migrate tildifies key path", moved.get("ASC_KEY_PATH", "") == "~/private_keys/AuthKey_K1.p8", str(moved))
	_check("migrate no-ops on clean config",
		ServiceT.config_secrets_as_env({"preset": "iOS", "build_number": 3}).is_empty())
	_check("migrate ignores blank fields",
		ServiceT.config_secrets_as_env({"asc_key_id": "", "asc_issuer_id": "  "}).is_empty())

	# ASC key ingest
	_check("key id from filename", ServiceT.parse_key_id_from_filename("/d/AuthKey_ABC123DEFG.p8") == "ABC123DEFG")
	_check("key id rejects other names", ServiceT.parse_key_id_from_filename("/d/key.p8") == "")
	_check("key id rejects too short", ServiceT.parse_key_id_from_filename("/d/AuthKey_AB.p8") == "")
	var svc: Node = ServiceT.new()
	_check("issuer rejects junk", not svc.set_asc_issuer("abc").get("ok", true))
	_check("issuer rejects empty", not svc.set_asc_issuer("").get("ok", true))
	svc.free()

	# apply_fix dispatch — routing only. ios.templates/android.templates/etc2
	# are excluded: their fixes always run for real (network download,
	# project.godot write), never safe from a test.
	var svc4: Node = ServiceT.new()
	_check("apply_fix unknown id falls through",
		str(svc4.apply_fix("bogus.id").get("error", "")) == "No fix for 'bogus.id'.")
	# Only safe when the early-return (no preset yet) actually fires — a real
	# preset makes apply_fix write export_presets.cfg for real, same reason
	# ios.templates/android.templates/etc2 are excluded above.
	if svc4.load_preset("iOS").is_empty():
		_check("apply_fix routes ios.preset",
			str(svc4.apply_fix("ios.preset").get("error", "")) == "No iOS preset to fix — create one with the form below first.")
	else:
		print("  skip apply_fix routes ios.preset (a real iOS preset exists in export_presets.cfg)")
	if svc4.load_preset("Android").is_empty():
		_check("apply_fix routes android.preset",
			str(svc4.apply_fix("android.preset").get("error", "")) == "No Android preset to fix — create one first.")
	else:
		print("  skip apply_fix routes android.preset (a real Android preset exists in export_presets.cfg)")
	_check("apply_fix routes ios.app_record",
		str(svc4.apply_fix("ios.app_record").get("error", "")) == "Needs an ASC API key (see the row above).")
	svc4.free()

	# Read-only (unlike Fix), so safe to exercise against the real repo's export_presets.cfg.
	var svc5: Node = ServiceT.new()
	var real_android_preset: Dictionary = svc5.load_preset("Android")
	if not real_android_preset.is_empty():
		var row: Dictionary = svc5._check_android_preset()
		var real_export_path := str(real_android_preset.get("export_path", ""))
		if real_export_path == "" or not real_export_path.ends_with(".apk"):
			_check("android preset flags bad export_path",
				str(row["status"]) == "warn" and str(row["detail"]).contains("export path"), str(row))
		else:
			_check("android preset ok with valid export_path", str(row["status"]) == "ok", str(row))
	else:
		print("  skip android preset export_path check (no real Android preset)")
	svc5.free()

	# real spawn round-trip: log + tail capture.
	var log_path := OS.get_cache_dir().path_join("build_kit_verify").path_join("spawn.log")
	var handle := Exec.spawn_shell("echo hello", log_path)
	_check("spawn ok", bool(handle.get("ok", false)), str(handle))
	if handle.get("ok", false):
		var tries := 0
		while Exec.exit_code(handle["exit_path"]) < 0 and tries < 100:
			OS.delay_msec(50)
			tries += 1
		_check("spawn exit code", Exec.exit_code(handle["exit_path"]) == 0)
		_check("spawn log", Exec.read_all(log_path).contains("hello"))
		var tail := Exec.read_from(log_path, 0)
		_check("spawn tail", str(tail["text"]).contains("hello") and int(tail["offset"]) > 0)

	# a nonzero exit code propagates correctly. shell_line has no subshell
	# isolation on Windows, so `exit` needs a real child process — cmd.exe's
	# own /c must stay unquoted for cmd to recognize it as the switch.
	var exit_log_path := OS.get_cache_dir().path_join("build_kit_verify").path_join("spawn_exit.log")
	var exit_shell_line := ("cmd.exe /c %s" % Exec.quote("exit 7")
		if OS.get_name() == "Windows" else "exit 7")
	var exit_handle := Exec.spawn_shell(exit_shell_line, exit_log_path)
	_check("spawn nonzero exit ok", bool(exit_handle.get("ok", false)), str(exit_handle))
	if exit_handle.get("ok", false):
		var tries2 := 0
		while Exec.exit_code(exit_handle["exit_path"]) < 0 and tries2 < 100:
			OS.delay_msec(50)
			tries2 += 1
		_check("spawn nonzero exit code", Exec.exit_code(exit_handle["exit_path"]) == 7)

	# real run() round-trip — this path has no other coverage (the "adb
	# devices" tests above are pure string-parsing over synthetic output).
	# Windows run() runs a program via a cmd .bat, so it can't host a nested
	# `cmd /c "…"` — probe a real program (`where`) the way callers do.
	var win := OS.get_name() == "Windows"
	var run_ok: Dictionary = Exec.run(PackedStringArray(["where", "cmd"]) if win else PackedStringArray(["echo", "hi"]))
	_check("run captures output", int(run_ok["code"]) == 0 and str(run_ok["output"]).contains("cmd" if win else "hi"), str(run_ok))
	var run_bad: Dictionary = Exec.run(PackedStringArray(["where", "__no_such_xyz__"]) if win else PackedStringArray(["sh", "-c", "exit 7"]))
	_check("run nonzero exit code", int(run_bad["code"]) != 0 if win else int(run_bad["code"]) == 7, str(run_bad))

	# per-OS conventional-path picker (Android preflight groundwork)
	_check("pick_by_os windows", ServiceT.pick_by_os("Windows", "W", "L", "M") == "W")
	_check("pick_by_os linux", ServiceT.pick_by_os("Linux", "W", "L", "M") == "L")
	_check("pick_by_os macos", ServiceT.pick_by_os("macOS", "W", "L", "M") == "M")
	_check("pick_by_os unknown falls back to macos", ServiceT.pick_by_os("FreeBSD", "W", "L", "M") == "M")
	_check("toolchain detail empty", ServiceT._toolchain_path_detail("") == "not configured")
	_check("toolchain detail wrong path", ServiceT._toolchain_path_detail("/nope") == "configured path missing (/nope)")

	# adb devices -l parsing
	var adb_out := "List of devices attached\nemulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emulator64_arm64 transport_id:1\nR58N70ABCDE             unauthorized usb:1-1 transport_id:2\n\n"
	var adb_devices := ServiceT.parse_adb_devices(adb_out)
	_check("adb devices count", adb_devices.size() == 2, str(adb_devices))
	_check("adb devices serial", str(adb_devices[0]["serial"]) == "emulator-5554", str(adb_devices))
	_check("adb devices state", str(adb_devices[0]["state"]) == "device", str(adb_devices))
	_check("adb devices model", str(adb_devices[0]["model"]) == "sdk_gphone64_arm64", str(adb_devices))
	_check("adb devices unauthorized state", str(adb_devices[1]["state"]) == "unauthorized", str(adb_devices))
	_check("adb devices no model on unauthorized", str(adb_devices[1]["model"]) == "", str(adb_devices))
	_check("adb devices empty output", ServiceT.parse_adb_devices("List of devices attached\n\n").is_empty())
	# a cold adb server prepends "* daemon …" lines before the header; they must
	# not parse as devices
	var adb_cold := "* daemon not running; starting now at tcp:5037\n* daemon started successfully\nList of devices attached\nemulator-5554          device model:sdk_gphone64_arm64 transport_id:1\n"
	_check("adb devices skips cold-start daemon noise", ServiceT.parse_adb_devices(adb_cold).size() == 1, str(ServiceT.parse_adb_devices(adb_cold)))
	# _check_android_devices is now a pure classifier over query_adb_devices()'s
	# {code, devices} — test its branches directly (it used to spawn adb)
	var dev_svc: Node = ServiceT.new()
	_check("device row: nonzero adb code warns",
		dev_svc._check_android_devices(1, []).get("status", "") == "warn")
	_check("device row: no devices fails",
		dev_svc._check_android_devices(0, []).get("detail", "") == "none")
	var unauth: Array = [{"serial": "R58N", "state": "unauthorized", "model": ""}]
	var unauth_row: Dictionary = dev_svc._check_android_devices(0, unauth)
	_check("device row: connected but none ready fails",
		unauth_row.get("status", "") == "fail" and str(unauth_row.get("detail", "")).contains("none authorized"), str(unauth_row))
	_check("device row: a ready device is ok",
		dev_svc._check_android_devices(0, [{"serial": "emulator-5554", "state": "device", "model": "x"}]).get("status", "") == "ok")
	# reconcile_device_selection drops a pick no longer among ready devices
	# (unplugged) so it can't block a build while a valid one exists
	var d_a := {"serial": "A", "state": "device", "model": ""}
	var d_c := {"serial": "C", "state": "device", "model": ""}
	_check("reconcile: empty pick takes first ready", dev_svc.reconcile_device_selection("", [d_a, d_c]) == "A")
	_check("reconcile: valid pick preserved", dev_svc.reconcile_device_selection("C", [d_a, d_c]) == "C")
	_check("reconcile: stale pick falls back to first ready", dev_svc.reconcile_device_selection("B", [d_a, d_c]) == "A")
	_check("reconcile: no ready devices clears pick", dev_svc.reconcile_device_selection("A", []) == "")
	# is_apk_export_path gates start_build_android + the preset Fix
	_check("apk path valid", ServiceT.is_apk_export_path("build/android/game.apk"))
	_check("apk path rejects blank", not ServiceT.is_apk_export_path(""))
	_check("apk path rejects non-apk", not ServiceT.is_apk_export_path("build/android/game"))
	# _extract_templates aborts with {ok:false} on a write failure — build a
	# 1-entry zip, then force open==null by putting a dir where the file goes
	var tpl_svc: Node = ServiceT.new()
	var tmp := OS.get_environment("TEMP") if OS.get_name() == "Windows" else "/tmp"
	var zpath := tmp.path_join("bk_tpl_test.zip")
	var packer := ZIPPacker.new()
	packer.open(zpath)
	packer.start_file("templates/foo.txt")
	packer.write_file("hi".to_utf8_buffer())
	packer.close_file()
	packer.close()
	var okdest := tmp.path_join("bk_tpl_ok")
	var reader := ZIPReader.new()
	reader.open(zpath)
	var okres: Dictionary = tpl_svc._extract_templates(reader, okdest)
	reader.close()
	_check("templates extract ok", okres.get("ok", false), str(okres))
	_check("templates extract wrote the file", FileAccess.file_exists(okdest.path_join("foo.txt")))
	var baddest := tmp.path_join("bk_tpl_bad")
	DirAccess.make_dir_recursive_absolute(baddest.path_join("foo.txt"))
	var reader2 := ZIPReader.new()
	reader2.open(zpath)
	var badres: Dictionary = tpl_svc._extract_templates(reader2, baddest)
	reader2.close()
	_check("templates extract fails when a file can't be written", not badres.get("ok", true), str(badres))

	# debug keystore all-or-nothing grouping — the one branch worth pinning
	# down given how unverified the exact rule is (see the function's doc
	# comment); the file-existence branches below it aren't tested, same as
	# every other check that touches real DirAccess/FileAccess state.
	var svc3: Node = ServiceT.new()
	var partial: Dictionary = svc3._check_android_debug_keystore("/some/path", "", "")
	_check("debug keystore flags partial config",
		partial.get("status", "") == "fail" and partial.get("id", "") == "android.debug_keystore", str(partial))
	var none_configured: Dictionary = svc3._check_android_debug_keystore("", "", "")
	_check("debug keystore allows none configured", none_configured.get("status", "") != "fail", str(none_configured))
	svc3.free()

	# android sdk/jdk: only the deterministic branch (a path that exists) is
	# pinned exactly; fixable branches assert fix_value self-consistently
	# since the fallback they land on depends on the machine.
	var svc6: Node = ServiceT.new()
	var real_dir := OS.get_cache_dir()
	var sdk_ok: Dictionary = svc6._check_android_sdk(real_dir)
	_check("android sdk check recognizes a path that exists",
		sdk_ok.get("status", "") == "ok" and sdk_ok.get("detail", "") == real_dir, str(sdk_ok))
	var sdk_unset: Dictionary = svc6._check_android_sdk("")
	if sdk_unset.get("fixable", false):
		_check("android sdk fix_value matches the conventional path it found",
			sdk_unset.get("fix_value", "") == ServiceT.android_sdk_conventional_path(), str(sdk_unset))
	var jdk_ok: Dictionary = svc6._check_android_jdk(real_dir)
	_check("android jdk check recognizes a path that exists",
		jdk_ok.get("status", "") == "ok" and jdk_ok.get("detail", "") == real_dir, str(jdk_ok))
	var jdk_unset: Dictionary = svc6._check_android_jdk("")
	if jdk_unset.get("fixable", false):
		var java_home := OS.get_environment("JAVA_HOME")
		var expected_fix := java_home if (java_home != "" and DirAccess.dir_exists_absolute(java_home)) else ServiceT.android_studio_jbr_path()
		_check("android jdk fix_value matches whichever fallback it found",
			jdk_unset.get("fix_value", "") == expected_fix, str(jdk_unset))
	svc6.free()

	var esc := char(27)
	_check("strip_ansi drops Godot's colour codes",
		Exec.strip_ansi("[  98%% ] %s[90m%s[1msavepack%s[22m | ok%s[39m%s[0m" % [esc, esc, esc, esc, esc])
			== "[  98% ] savepack | ok")
	_check("strip_ansi leaves plain text alone", Exec.strip_ansi("a [b] c") == "a [b] c")

	_verify_itch()
	_verify_itch_classify()
	_verify_ios_signing()
	_verify_release_cli()

	print("VERIFY build_kit: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	quit(0 if _fails == 0 else 1)


# --- itch.gd -----------------------------------------------------------------

const ITCH_PRESETS_FIXTURE := """
[preset.0]

name="Web"
platform="Web"
runnable=true
export_path="build/web/index.html"

[preset.0.options]

custom_template/debug=""
custom_template/release=""
variant/extensions_support=false
variant/thread_support=true

[preset.1]

name="Windows Desktop"
platform="Windows Desktop"
export_path="../build/win/My Game.exe"

[preset.1.options]

custom_template/release=""
binary_format/architecture="arm64"

[preset.2]

name="macOS"
platform="macOS"
export_path=""

[preset.2.options]

binary_format/architecture="universal"

[preset.3]

name="Linux"
platform="Linux"
export_path=""

[preset.3.options]

binary_format/architecture="x86_64"

[preset.4]

name="iOS"
platform="iOS"
export_path="../build/ios/Game.ipa"

[preset.4.options]

application/bundle_identifier="com.example.game"
"""


func _verify_itch() -> void:
	# slugs / channels
	_check("itch slug ok", Itch.valid_slug("my-game_2"))
	_check("itch slug rejects upper/space/dot/leading dash",
		not Itch.valid_slug("MyGame") and not Itch.valid_slug("my game")
		and not Itch.valid_slug("a.b") and not Itch.valid_slug("-a") and not Itch.valid_slug(""))
	_check("itch channel ok", Itch.valid_channel("html5") and Itch.valid_channel("win-1.2_beta"))
	_check("itch channel rejects junk",
		not Itch.valid_channel("Win") and not Itch.valid_channel("a:b") and not Itch.valid_channel(".x")
		and not Itch.valid_channel("a b") and not Itch.valid_channel(""))

	# URL / target parsing
	var u1 := Itch.parse_itch_url("https://studio.itch.io/cool-game")
	_check("itch url https", u1.get("user", "") == "studio" and u1.get("game", "") == "cool-game", str(u1))
	var u2 := Itch.parse_itch_url("  http://Studio.itch.io/cool-game/?secret=1#x ")
	_check("itch url trailing slash/query/case", u2.get("user", "") == "studio" and u2.get("game", "") == "cool-game", str(u2))
	var u3 := Itch.parse_itch_url("studio.itch.io/cool-game/devlog")
	_check("itch url schemeless + subpage", u3.get("game", "") == "cool-game", str(u3))
	var u4 := Itch.parse_itch_url("studio/cool-game")
	_check("itch url butler form", u4.get("user", "") == "studio" and u4.get("game", "") == "cool-game", str(u4))
	_check("itch url rejects bare host", Itch.parse_itch_url("https://studio.itch.io/").is_empty())
	_check("itch url rejects channel suffix", Itch.parse_itch_url("studio/cool-game:html5").is_empty())
	_check("itch url rejects itch.io root", Itch.parse_itch_url("https://itch.io/game").is_empty())
	_check("itch url rejects 3 segments", Itch.parse_itch_url("a/b/c").is_empty())
	_check("itch url rejects empty", Itch.parse_itch_url("").is_empty())
	_check("itch url rejects bad slug", Itch.parse_itch_url("https://stu_dio.itch.io/a b").is_empty())
	_check("itch game_url", Itch.game_url("studio", "cool-game") == "https://studio.itch.io/cool-game")

	# default channels
	_check("itch default channels",
		Itch.default_channel("Web") == "html5" and Itch.default_channel("Windows Desktop") == "windows"
		and Itch.default_channel("macOS") == "mac" and Itch.default_channel("Linux") == "linux"
		and Itch.default_channel("Linux/X11") == "linux")
	_check("itch default channel irrelevant", Itch.default_channel("iOS") == "" and Itch.default_channel("Android") == "")

	# list_presets
	var presets := Itch.list_presets(ITCH_PRESETS_FIXTURE)
	_check("itch list_presets count", presets.size() == 5, str(presets.size()))
	if presets.size() == 5:
		_check("itch list_presets fields", presets[0]["name"] == "Web" and presets[0]["platform"] == "Web"
			and presets[0]["section"] == "preset.0" and presets[0]["export_path"] == "build/web/index.html", str(presets[0]))
		_check("itch list_presets options typed", presets[0]["options"].get("variant/thread_support", null) == true, str(presets[0]["options"]))
		_check("itch list_presets order", presets[4]["platform"] == "iOS" and presets[1]["name"] == "Windows Desktop")
	_check("itch list_presets garbage", Itch.list_presets("not [ a cfg").is_empty())
	_check("itch list_presets empty", Itch.list_presets("").is_empty())

	# resolve_channels — discovery
	var auto := Itch.resolve_channels([], presets)
	_check("itch discover skips iOS", auto.size() == 4, str(auto))
	if auto.size() == 4:
		_check("itch discover channels", auto[0]["channel"] == "html5" and auto[1]["channel"] == "windows"
			and auto[2]["channel"] == "mac" and auto[3]["channel"] == "linux", str(auto))
		_check("itch discover entry shape", auto[0]["preset"] == "Web" and auto[0]["platform"] == "Web"
			and auto[0]["enabled"] == true and auto[0]["problem"] == ""
			and auto[0]["options"].get("variant/thread_support", false) == true
			and auto[1]["export_path"] == "../build/win/My Game.exe", str(auto[0]))
	var two_webs := Itch.list_presets("[preset.0]\nname=\"Web\"\nplatform=\"Web\"\n[preset.1]\nname=\"Web Demo!\"\nplatform=\"Web\"\n")
	var auto2 := Itch.resolve_channels([], two_webs)
	_check("itch discover dedupes channel", auto2.size() == 2 and auto2[0]["channel"] == "html5"
		and auto2[1]["channel"] == "html5-web-demo" and auto2[1]["problem"] == "", str(auto2))

	# resolve_channels — configured
	var configured := Itch.resolve_channels([
		{"preset": "Web", "channel": "html5", "enabled": true},
		{"preset": "Ghost", "channel": "ghost", "enabled": true},
		{"preset": "Linux", "channel": "html5", "enabled": true},
		{"preset": "macOS", "channel": "Bad Name", "enabled": true},
		{"preset": "iOS", "channel": "ios", "enabled": true},
		{"preset": "Windows Desktop", "channel": "", "enabled": false},
	], presets)
	_check("itch configured count", configured.size() == 6, str(configured))
	if configured.size() == 6:
		_check("itch configured ok entry", configured[0]["problem"] == "" and configured[0]["platform"] == "Web")
		_check("itch configured missing preset", str(configured[1]["problem"]).contains("No export preset named 'Ghost'")
			and configured[1]["preset"] == "Ghost", str(configured[1]))
		_check("itch configured duplicate channel", str(configured[2]["problem"]).contains("more than one preset"), str(configured[2]))
		_check("itch configured invalid channel", str(configured[3]["problem"]).contains("isn't valid"), str(configured[3]))
		_check("itch configured non-itch platform", str(configured[4]["problem"]).contains("iOS"), str(configured[4]))
		_check("itch configured blank channel → default + disabled kept",
			configured[5]["channel"] == "windows" and configured[5]["enabled"] == false and configured[5]["problem"] == "", str(configured[5]))
	var dis_dup := Itch.resolve_channels([
		{"preset": "Web", "channel": "html5", "enabled": false},
		{"preset": "Linux", "channel": "html5"},
	], presets)
	_check("itch disabled entry doesn't claim channel; enabled defaults true",
		dis_dup.size() == 2 and dis_dup[1]["problem"] == "" and dis_dup[1]["enabled"] == true, str(dis_dup))

	# safe_output_dir
	_check("itch outdir ok", Itch.safe_output_dir("build/itch") and Itch.safe_output_dir("./out") and Itch.safe_output_dir("x"))
	for bad in ["", "  ", ".", "./", "./.", "..", "build/../..", "../out", "/abs/out", "\\abs", "C:/out", "res://build", "~/out", "a/../b"]:
		_check("itch outdir rejects '%s'" % bad, not Itch.safe_output_dir(bad))

	# channel_paths
	var web_p := Itch.channel_paths("/proj/game/", "build/itch", "html5", "Web", "build/web/game.html", "My Game")
	_check("itch paths root", web_p["root"] == "/proj/game/build/itch", str(web_p))
	_check("itch paths dir", web_p["dir"] == "/proj/game/build/itch/html5", str(web_p))
	_check("itch paths web is index.html", web_p["out"] == "/proj/game/build/itch/html5/index.html", str(web_p))
	_check("itch paths logs", web_p["logs"] == "/proj/game/build/itch/logs", str(web_p))
	var win_p := Itch.channel_paths("/proj", "build/itch", "windows", "Windows Desktop", "../build/win/My Game.exe", "X")
	_check("itch paths keep preset basename", win_p["out"] == "/proj/build/itch/windows/My Game.exe", str(win_p))
	_check("itch paths fallback exe", Itch.channel_paths("/proj", "out", "windows", "Windows Desktop", "", "My Game!")["out"] == "/proj/out/windows/My_Game.exe")
	_check("itch paths fallback linux", Itch.channel_paths("/proj", "out", "linux", "Linux", "", "Game")["out"] == "/proj/out/linux/Game.x86_64")
	_check("itch paths fallback mac", Itch.channel_paths("/proj", "out", "mac", "macOS", "", "Game")["out"] == "/proj/out/mac/Game.zip")
	_check("itch paths fallback empty app name", Itch.channel_paths("/proj", "out", "mac", "macOS", "", "!!")["out"] == "/proj/out/mac/game.zip")
	_check("itch paths ./ output dir", Itch.channel_paths("/proj", "./out", "linux", "Linux", "", "G")["root"] == "/proj/out")

	# required_template_files — names checked against Godot 4.6/4.7 template packs
	var tf := func(platform: String, opts: Dictionary, release := true) -> String:
		return ",".join(Itch.required_template_files(platform, opts, release))
	_check("itch tpl web default nothreads", tf.call("Web", {}) == "web_nothreads_release.zip")
	_check("itch tpl web threads", tf.call("Web", {"variant/thread_support": true}) == "web_release.zip")
	_check("itch tpl web dlink nothreads", tf.call("Web", {"variant/extensions_support": true, "variant/thread_support": false}) == "web_dlink_nothreads_release.zip")
	_check("itch tpl web dlink threads debug", tf.call("Web", {"variant/extensions_support": true, "variant/thread_support": true}, false) == "web_dlink_debug.zip")
	_check("itch tpl web string bools", tf.call("Web", {"variant/thread_support": "true"}) == "web_release.zip")
	_check("itch tpl windows default", tf.call("Windows Desktop", {}) == "windows_release_x86_64.exe")
	_check("itch tpl windows arm64", tf.call("Windows Desktop", {"binary_format/architecture": "arm64"}) == "windows_release_arm64.exe")
	_check("itch tpl windows debug x86_32", tf.call("Windows Desktop", {"binary_format/architecture": "x86_32"}, false) == "windows_debug_x86_32.exe")
	_check("itch tpl linux", tf.call("Linux", {}) == "linux_release.x86_64" and tf.call("Linux/X11", {"binary_format/architecture": "arm64"}) == "linux_release.arm64")
	_check("itch tpl macos", tf.call("macOS", {"binary_format/architecture": "universal"}) == "macos.zip")
	_check("itch tpl custom template needs nothing", tf.call("Web", {"custom_template/release": "/x/web.zip"}) == "")
	_check("itch tpl custom debug only still needs release", tf.call("Web", {"custom_template/debug": "/x/web.zip"}) == "web_nothreads_release.zip")
	_check("itch tpl unknown platform", tf.call("iOS", {}) == "")
	# Cross-check against a real installed template pack when one is present.
	var v: Dictionary = Engine.get_version_info()
	var tdir := OS.get_data_dir().path_join("Godot/export_templates").path_join(ServiceT.version_tag(v) + "." + str(v["status"]))
	if DirAccess.dir_exists_absolute(tdir):
		var all_present := true
		var absent := PackedStringArray()
		for case in [["Web", {}], ["Web", {"variant/thread_support": true}],
				["Web", {"variant/extensions_support": true}], ["Web", {"variant/extensions_support": true, "variant/thread_support": true}],
				["Windows Desktop", {}], ["Windows Desktop", {"binary_format/architecture": "arm64"}],
				["Linux", {}], ["Linux", {"binary_format/architecture": "arm64"}], ["macOS", {}]]:
			for rel in [true, false]:
				for f in Itch.required_template_files(case[0], case[1], rel):
					if not FileAccess.file_exists(tdir.path_join(f)):
						all_present = false
						absent.append(f)
		_check("itch tpl names exist in installed pack", all_present, ", ".join(absent))
	else:
		print("  skip itch tpl installed-pack cross-check (no templates at %s)" % tdir)

	# butler argv — never a key on the command line
	var push := Itch.butler_push_args("/b/butler", "/out/html5", "studio", "game", "html5", "1.2.0", false, true)
	_check("itch push args", push == PackedStringArray(["/b/butler", "push", "/out/html5", "studio/game:html5", "--userversion=1.2.0", "--if-changed"]), str(push))
	var push_dry := Itch.butler_push_args("butler", "/o", "s", "g", "mac", "", true, false)
	_check("itch push args dry run, no version, no if-changed",
		push_dry == PackedStringArray(["butler", "push", "/o", "s/g:mac", "--dry-run"]), str(push_dry))
	_check("itch push args defaults", Itch.butler_push_args("butler", "/o", "s", "g", "linux") == PackedStringArray(["butler", "push", "/o", "s/g:linux", "--if-changed"]))
	var push_line := Exec.command_line(push)
	_check("itch push line carries no key", not push_line.to_lower().contains("key") and not push_line.contains("BUTLER_API"), push_line)
	_check("itch status args", Itch.butler_status_args("butler", "s", "g") == PackedStringArray(["butler", "status", "s/g"]))
	_check("itch login args (macOS: pty via script, inherited key dropped)",
		Itch.butler_login_args("/a b/butler", "macOS") == PackedStringArray(
			["env", "-u", "BUTLER_API_KEY", "script", "-q", "/dev/null", "/a b/butler", "login"]))
	_check("itch login args (Linux: one quoted -c string)",
		Itch.butler_login_args("/o'k/butler", "Linux") == PackedStringArray(
			["env", "-u", "BUTLER_API_KEY", "script", "-qec", "'/o'\\''k/butler' login", "/dev/null"]))
	_check("itch login args (Windows: no tty check, run directly)",
		Itch.butler_login_args("C:/b/butler.exe", "Windows") == PackedStringArray(["C:/b/butler.exe", "login"]))

	# broth / install
	_check("itch broth mac arm", Itch.butler_broth_channel("macOS", "arm64") == "darwin-arm64")
	_check("itch broth mac intel", Itch.butler_broth_channel("macOS", "x86_64") == "darwin-amd64")
	_check("itch broth linux", Itch.butler_broth_channel("Linux", "x86_64") == "linux-amd64" and Itch.butler_broth_channel("Linux", "arm64") == "linux-arm64")
	_check("itch broth windows", Itch.butler_broth_channel("Windows", "x86_64") == "windows-amd64" and Itch.butler_broth_channel("Windows", "arm64") == "windows-amd64")
	_check("itch broth unsupported", Itch.butler_broth_channel("Linux", "x86_32") == "" and Itch.butler_broth_channel("FreeBSD", "x86_64") == ""
		and Itch.butler_broth_channel("Windows", "x86_32") == "")
	_check("itch broth url", Itch.butler_download_url("darwin-arm64") == "https://broth.itch.zone/butler/darwin-arm64/LATEST/archive/default")
	_check("itch broth url empty", Itch.butler_download_url("") == "")
	_check("itch exe name", Itch.butler_exe_name("Windows") == "butler.exe" and Itch.butler_exe_name("macOS") == "butler" and Itch.butler_exe_name("Linux") == "butler")

	# creds file (butler main.go defaultKeyPath)
	_check("itch creds macOS", Itch.butler_creds_path("macOS", "/Users/u", "") == "/Users/u/Library/Application Support/itch/butler_creds")
	_check("itch creds linux", Itch.butler_creds_path("Linux", "/home/u", "") == "/home/u/.config/itch/butler_creds")
	_check("itch creds windows userprofile", Itch.butler_creds_path("Windows", "", "C:/Users/u") == "C:/Users/u/.config/itch/butler_creds")
	_check("itch creds HOME wins over USERPROFILE", Itch.butler_creds_path("Windows", "C:/h", "C:/Users/u") == "C:/h/.config/itch/butler_creds")
	_check("itch creds nothing", Itch.butler_creds_path("Linux", "", "") == "")

	# butler version
	_check("itch version release", Itch.parse_butler_version("v15.32.0, built on Oct  9 2026 @ 13:02:37, ref 0123abcd\n") == "15.32.0")
	_check("itch version no v", Itch.parse_butler_version("15.24.1, no build date") == "15.24.1")
	_check("itch version head", Itch.parse_butler_version("head, no build date") == "head")
	_check("itch version after noise", Itch.parse_butler_version("warning: something\nv15.1.0, built on x") == "15.1.0")
	_check("itch version garbage", Itch.parse_butler_version("zsh: command not found: butler") == "")

	# butler status table
	const STATUS_OK := "+---------+----------+-----------+---------+\n| CHANNEL |  UPLOAD  |   BUILD   | VERSION |\n+---------+----------+-----------+---------+\n| html5   | #1234567 | √ #456789 | 1.0.0   |\n|         |          | • #456790 |         |\n| windows | #7654321 | No builds yet |     |\n+---------+----------+-----------+---------+\n"
	var st := Itch.parse_status(STATUS_OK)
	_check("itch status rows (header + pending skipped)", st.size() == 2, str(st))
	if st.size() == 2:
		_check("itch status html5", st[0]["channel"] == "html5" and st[0]["upload"] == "#1234567"
			and st[0]["build"] == "√ #456789" and st[0]["version"] == "1.0.0", str(st[0]))
		_check("itch status no builds", st[1]["channel"] == "windows" and st[1]["build"] == "No builds yet", str(st[1]))
	_check("itch status empty", Itch.parse_status("No channel  found for studio/game\n").is_empty())

	# interpret_status
	var ok_s := Itch.interpret_status(0, STATUS_OK)
	_check("itch interpret ok", ok_s["auth"]["status"] == "ok" and ok_s["target"]["status"] == "ok"
		and str(ok_s["target"]["detail"]).contains("html5"), str(ok_s))
	var fresh := Itch.interpret_status(0, "No channel  found for studio/game\n")
	_check("itch interpret ok no channels", fresh["target"]["status"] == "ok" and str(fresh["target"]["detail"]).contains("no builds"), str(fresh))
	var bad_key := Itch.interpret_status(1, "listing channels: itch.io API error (403): /wharf/channels: invalid key\n")
	_check("itch interpret bad key", bad_key["auth"]["status"] == "fail" and bad_key["target"]["status"] == "warn"
		and str(bad_key["auth"]["guidance"]).contains("API key"), str(bad_key))
	var no_creds := Itch.interpret_status(1, "Please set BUTLER_API_KEY to your API key, see https://itch.io/docs/butler/login.html for more info.\nNo credentials and stdin is not a terminal - terminating.\n")
	_check("itch interpret no creds", no_creds["auth"]["status"] == "fail", str(no_creds))
	var bad_game := Itch.interpret_status(1, "listing channels: itch.io API error (400): /wharf/channels: invalid target (bad game)\n")
	_check("itch interpret bad game", bad_game["auth"]["status"] == "ok" and bad_game["target"]["status"] == "fail"
		and str(bad_game["target"]["guidance"]).contains("slug"), str(bad_game))
	var game_403 := Itch.interpret_status(1, "itch.io API error (403): /wharf/channels: invalid game\n")
	_check("itch interpret page error beats bare 403", game_403["target"]["status"] == "fail" and game_403["auth"]["status"] == "ok", str(game_403))
	var bare_401 := Itch.interpret_status(1, "itch.io API error (401): /wharf/channels: \n")
	_check("itch interpret bare 401 is auth", bare_401["auth"]["status"] == "fail", str(bare_401))
	var offline := Itch.interpret_status(1, "listing channels: Get \"https://api.itch.io/wharf/channels\": dial tcp: lookup api.itch.io: no such host\n")
	_check("itch interpret offline", offline["auth"]["status"] == "warn" and offline["target"]["status"] == "warn"
		and str(offline["auth"]["detail"]).contains("reach"), str(offline))
	var missing_b := Itch.interpret_status(127, "zsh: command not found: butler\n")
	_check("itch interpret butler missing", missing_b["auth"]["status"] == "warn" and str(missing_b["auth"]["guidance"]).contains("butler row"), str(missing_b))
	var weird := Itch.interpret_status(2, "something odd happened\n")
	_check("itch interpret unknown", weird["auth"]["status"] == "warn" and str(weird["auth"]["guidance"]).contains("something odd happened"), str(weird))
	for k in ["auth", "target"]:
		_check("itch interpret %s shape" % k, ok_s[k].has("status") and ok_s[k].has("detail") and ok_s[k].has("guidance"))

	# web bundle
	_check("itch web bundle ok", Itch.web_bundle_violations([{"path": "index.html", "size": 1000}, {"path": "index.pck", "size": 50000000}]).is_empty())
	var no_index := Itch.web_bundle_violations([{"path": "game.html", "size": 10}])
	_check("itch web bundle no index", no_index.size() == 1 and no_index[0].contains("index.html"), str(no_index))
	_check("itch web bundle nested index isn't root", Itch.web_bundle_violations([{"path": "sub/index.html", "size": 10}]).size() == 1)
	_check("itch web bundle ./index ok", Itch.web_bundle_violations([{"path": "./index.html", "size": 10}]).is_empty())
	var many: Array = [{"path": "index.html", "size": 1}]
	for i in Itch.WEB_MAX_FILES:
		many.append({"path": "f%d" % i, "size": 1})
	var too_many := Itch.web_bundle_violations(many)
	_check("itch web bundle too many files", too_many.size() == 1 and too_many[0].contains("1001 files"), str(too_many))
	many.resize(Itch.WEB_MAX_FILES)
	_check("itch web bundle exactly at file limit", Itch.web_bundle_violations(many).is_empty())
	var big := Itch.web_bundle_violations([{"path": "index.html", "size": 1}, {"path": "index.pck", "size": Itch.WEB_MAX_FILE_BYTES + 1}])
	_check("itch web bundle file too big", big.size() == 1 and big[0].contains("index.pck"), str(big))
	_check("itch web bundle file at limit ok", Itch.web_bundle_violations([{"path": "index.html", "size": Itch.WEB_MAX_FILE_BYTES}]).is_empty())
	var total := Itch.web_bundle_violations([{"path": "index.html", "size": 1}, {"path": "a", "size": 200 * 1048576},
		{"path": "b", "size": 200 * 1048576}, {"path": "c", "size": 101 * 1048576}])
	_check("itch web bundle total too big", total.size() == 1 and total[0].contains("500 MB"), str(total))
	_check("itch web bundle constants", Itch.WEB_MAX_FILES == 1000 and Itch.WEB_MAX_FILE_BYTES == 200 * 1048576 and Itch.WEB_MAX_TOTAL_BYTES == 500 * 1048576)

	# row helper mirrors Service._row
	var r := Itch.row("itch.x", "L", "ok")
	_check("itch row keys", r.has_all(["id", "label", "status", "detail", "guidance", "fixable", "links"]) and r.size() == 7, str(r))

	# check_butler
	var b_none := Itch.check_butler({}, "", true)
	_check("itch.butler missing fixable", b_none["id"] == "itch.butler" and b_none["status"] == "fail" and b_none["fixable"] == true, str(b_none))
	_check("itch.butler missing no download", Itch.check_butler({}, "", false)["fixable"] == false)
	var b_broken := Itch.check_butler({"code": 1, "output": "bad CPU type"}, "/x/butler", true)
	_check("itch.butler broken", b_broken["status"] == "fail" and b_broken["fixable"] == true and str(b_broken["guidance"]).contains("/x/butler"), str(b_broken))
	var b_ok := Itch.check_butler({"code": 0, "output": "v15.32.0, built on Oct  9 2026 @ 13:02:37, ref abc\n"}, "/x/butler", true)
	_check("itch.butler ok", b_ok["status"] == "ok" and str(b_ok["detail"]).contains("15.32.0") and b_ok["fixable"] == false, str(b_ok))

	# check_auth
	var a_env := Itch.check_auth("env", false)
	_check("itch.auth env busy", a_env["id"] == "itch.auth" and a_env["status"] == "busy" and str(a_env["detail"]).contains("environment"), str(a_env))
	_check("itch.auth dotenv busy", Itch.check_auth("dotenv", true)["status"] == "busy" and str(Itch.check_auth("dotenv", true)["detail"]).contains(".env"))
	_check("itch.auth creds file busy", Itch.check_auth("", true)["status"] == "busy")
	var a_none := Itch.check_auth("", false)
	_check("itch.auth none warns with guidance", a_none["status"] == "warn" and a_none["fixable"] == false
		and str(a_none["guidance"]).contains("butler login") and str(a_none).contains(Itch.API_KEYS_URL), str(a_none))

	# check_target
	var t_unset := Itch.check_target("", "")
	_check("itch.target unset", t_unset["status"] == "fail" and t_unset["fixable"] == false
		and str(t_unset["guidance"]).contains("Draft") and str(t_unset).contains(Itch.NEW_GAME_URL), str(t_unset))
	_check("itch.target invalid", Itch.check_target("Bad User", "g")["status"] == "fail")
	var t_ok := Itch.check_target("studio", "game")
	_check("itch.target valid busy", t_ok["status"] == "busy" and str(t_ok).contains("https://studio.itch.io/game"), str(t_ok))

	# check_channels
	var c_auto := Itch.check_channels(auto, false)
	_check("itch.channels discovered fixable", c_auto["status"] == "warn" and c_auto["fixable"] == true and str(c_auto["detail"]).contains("html5"), str(c_auto))
	var pinned := Itch.resolve_channels([{"preset": "Web", "channel": "html5"}], presets)
	var c_pinned := Itch.check_channels(pinned, true)
	_check("itch.channels configured ok", c_pinned["status"] == "ok" and c_pinned["fixable"] == false, str(c_pinned))
	var c_bad := Itch.check_channels(configured, true)
	_check("itch.channels problems fail", c_bad["status"] == "fail" and str(c_bad["guidance"]).contains("Ghost") and c_bad["fixable"] == false, str(c_bad))
	_check("itch.channels no presets", Itch.check_channels([], false)["status"] == "fail" and Itch.check_channels([], false)["fixable"] == false)
	var all_off := Itch.resolve_channels([{"preset": "Web", "channel": "html5", "enabled": false}], presets)
	_check("itch.channels all disabled", Itch.check_channels(all_off, true)["status"] == "fail")
	var ghost_off := Itch.resolve_channels([{"preset": "Web", "channel": "html5"}, {"preset": "Ghost", "channel": "g", "enabled": false}], presets)
	_check("itch.channels disabled problem ignored", Itch.check_channels(ghost_off, true)["status"] == "ok")

	# check_templates
	_check("itch.templates ok", Itch.check_templates(PackedStringArray(), "4.7.1.stable", true)["status"] == "ok")
	var tm := Itch.check_templates(PackedStringArray(["web_nothreads_release.zip"]), "4.7.1.stable", true)
	_check("itch.templates missing fixable", tm["status"] == "fail" and tm["fixable"] == true and str(tm["detail"]).contains("web_nothreads_release.zip"), str(tm))
	_check("itch.templates missing manual", Itch.check_templates(PackedStringArray(["x"]), "4.8.beta1", false)["fixable"] == false)

	# check_web
	var w_threads := Itch.check_web(auto)
	_check("itch.web threads warns fixable", w_threads["status"] == "warn" and w_threads["fixable"] == true
		and str(w_threads["guidance"]).contains("SharedArrayBuffer"), str(w_threads))
	var nothreads := Itch.list_presets("[preset.0]\nname=\"Web\"\nplatform=\"Web\"\n[preset.0.options]\nvariant/thread_support=false\n")
	_check("itch.web nothreads ok", Itch.check_web(Itch.resolve_channels([], nothreads))["status"] == "ok")
	_check("itch.web no web channel ok", Itch.check_web(Itch.resolve_channels([{"preset": "Linux", "channel": "linux"}], presets))["status"] == "ok")
	_check("itch.web disabled threaded web ignored",
		Itch.check_web(Itch.resolve_channels([{"preset": "Web", "channel": "html5", "enabled": false}], presets))["status"] == "ok")

	# check_version
	var ver_none := Itch.check_version("")
	_check("itch.version unset warns", ver_none["status"] == "warn" and ver_none["fixable"] == false and str(ver_none["guidance"]).contains("--userversion"), str(ver_none))
	_check("itch.version set", Itch.check_version(" 1.2.3 ")["status"] == "ok" and Itch.check_version("1.2.3")["detail"] == "1.2.3")

	# every evaluator returns its contract id
	var ids := [Itch.check_butler({}, "", true)["id"], Itch.check_auth("", false)["id"], Itch.check_target("", "")["id"],
		Itch.check_channels([], false)["id"], Itch.check_templates(PackedStringArray(), "", true)["id"],
		Itch.check_web([])["id"], Itch.check_version("")["id"]]
	_check("itch row ids", ids == ["itch.butler", "itch.auth", "itch.target", "itch.channels", "itch.templates", "itch.web", "itch.version"], str(ids))


func _verify_itch_classify() -> void:
	var cases := [
		["zsh: command not found: butler", "butler_missing"],
		["zsh: no such file or directory: /Users/u/Library/Application Support/Godot/build_kit/butler/butler", "butler_missing"],
		["'butler' is not recognized as an internal or external command,", "butler_missing"],
		["authenticating: itch.io API error (403): /wharf/status: invalid key", "butler_auth"],
		["Please set BUTLER_API_KEY to your API key, see https://itch.io/docs/butler/login.html for more info.\nNo credentials and stdin is not a terminal - terminating.", "butler_auth"],
		["searching for parent build signature: in conn.tryConnect, got HTTP non-2XX: api.itch.io: HTTP 403: {\"errors\":[\"invalid key\"]}", "butler_auth"],
		["creating build on remote server: itch.io API error (400): /wharf/builds: invalid target (bad user)", "butler_invalid_game"],
		["creating build on remote server: itch.io API error (400): /wharf/builds: invalid game", "butler_invalid_game"],
		["itch.io API error (403): /wharf/builds: invalid game", "butler_invalid_game"],
		["parsing push target 'studio': invalid spec: studio, expected something of the form user/page:channel", "butler_invalid_game"],
		["parsing push target 'studio/game': invalid spec: studio/game, missing channel (examples: studio/game:windows-32-beta, studio/game:linux-64)", "butler_invalid_channel"],
		["itch.io API error (400): /wharf/builds: invalid channel", "butler_invalid_channel"],
		["Get \"https://api.itch.io/wharf/status\": dial tcp: lookup api.itch.io: no such host", "butler_network"],
		["read tcp 10.0.0.2:5555->1.2.3.4:443: i/o timeout", "butler_network"],
	]
	for c in cases:
		var got := Classify.classify(c[0], {}, "itch")
		_check("classify itch %s" % c[1], got["id"] == c[1], "%s ← %s" % [got["id"], c[0]])
	# scoping: android's bare "unauthorized" must not catch itch output, and
	# butler rules must never fire for ios/android
	var itch_unauth := Classify.classify("got HTTP 401 Unauthorized: unauthorized", {}, "itch")
	_check("classify itch 'unauthorized' isn't the android device rule", itch_unauth["id"] == "butler_auth", str(itch_unauth))
	_check("classify android 'unauthorized' still android", Classify.classify("error: device unauthorized.", {}, "android")["id"] == "device_unauthorized")
	_check("classify butler rule doesn't match android",
		Classify.classify("itch.io API error (403): /wharf/status: invalid key", {}, "android")["id"] == "unknown")
	_check("classify butler network doesn't shadow ios network",
		Classify.classify("The request timed out.", {}, "ios")["id"] == "network")
	_check("classify ios rule doesn't match itch",
		Classify.classify("error: exportArchive Cloud signing permission error", {}, "itch")["id"] == "unknown")
	_check("classify unscoped export rule matches itch",
		Classify.classify("No export template found at the expected path: web_nothreads_release.zip", {}, "itch")["id"] == "no_export_templates")
	_check("classify itch rules carry links", not (Classify.classify("invalid key", {}, "itch").get("links", []) as Array).is_empty())


# --- iOS signing: stage command lines + .ipa entitlement verification ----------

const ENT_SIWA := """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>aps-environment</key>
	<string>development</string>
	<key>com.apple.developer.applesignin</key>
	<array>
		<string>Default</string>
	</array>
	<key>com.apple.developer.game-center</key>
	<true/>
</dict>
</plist>
"""

const ENT_SIGNED_OK := """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>application-identifier</key><string>ABCDE12345.com.example.game</string><key>aps-environment</key><string>production</string><key>beta-reports-active</key><true/><key>com.apple.developer.applesignin</key><array><string>Default</string></array><key>com.apple.developer.game-center</key><true/><key>com.apple.developer.team-identifier</key><string>ABCDE12345</string><key>get-task-allow</key><false/></dict></plist>
"""

const ENT_SIGNED_STALE := """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>application-identifier</key><string>ABCDE12345.com.example.game</string><key>aps-environment</key><string>production</string><key>com.apple.developer.game-center</key><true/><key>get-task-allow</key><false/></dict></plist>
"""


func _verify_ios_signing() -> void:
	var paths := ServiceT.derive_paths("/proj/game/", "../build/ios/Game.ipa", "iOS")
	_check("paths entitlements", paths["entitlements"] == "/proj/build/ios/Game/Game.entitlements", str(paths))
	_check("paths archived app", paths["archived_app"] == "/proj/build/ios/Game.xcarchive/Products/Applications/Game.app", str(paths))
	_check("paths ipa", paths["ipa"] == "/proj/build/ios/Game.ipa", str(paths))
	_check("paths options split", paths["options_plist"] != paths["upload_options_plist"], str(paths))

	var auth := PackedStringArray(["-authenticationKeyPath", "/k/AuthKey.p8", "-authenticationKeyID", "KEY", "-authenticationKeyIssuerID", "ISS"])
	var up: Array = ServiceT.ios_stages(paths, "/godot", "/proj/game/", "iOS", 7, true, auth)
	var names := up.map(func(st): return st["name"])
	_check("ios stages (upload)", names == ["export", "patch", "archive", "embed_entitlements", "export_ipa", "verify_entitlements", "upload"], str(names))
	var local: Array = ServiceT.ios_stages(paths, "/godot", "/proj/game/", "iOS", 7, false, PackedStringArray())
	var local_names := local.map(func(st): return st["name"])
	_check("ios stages (ipa only) verify but never upload", local_names == ["export", "patch", "archive", "embed_entitlements", "export_ipa", "verify_entitlements"], str(local_names))
	if OS.get_name() == "Windows":
		return  # the rest asserts POSIX quoting; the iOS pipeline is macOS-only anyway
	var by_name := {}
	for st in up:
		by_name[st["name"]] = st
	var archive := str(by_name["archive"]["shell"])
	_check("archive stays unsigned", archive.contains("'CODE_SIGNING_ALLOWED=NO'"), archive)
	var embed := str(by_name["embed_entitlements"]["shell"])
	_check("embed ad-hoc signs the archived app with the project entitlements",
		embed.contains("'codesign' '--force' '--sign' '-' '--entitlements' '/proj/build/ios/Game/Game.entitlements' '/proj/build/ios/Game.xcarchive/Products/Applications/Game.app'"), embed)
	_check("embed fails loudly without the entitlements file", embed.contains("build_kit: no entitlements file at") and embed.contains("exit 1"), embed)
	var exp := str(by_name["export_ipa"]["shell"])
	_check("export_ipa exports locally with provisioning updates",
		exp.contains("'-exportOptionsPlist' '%s'" % paths["options_plist"]) and exp.contains("'-exportPath' '/proj/build/ios'")
			and exp.contains("'-allowProvisioningUpdates'") and exp.contains("'-authenticationKeyID' 'KEY'"), exp)
	_check("export_ipa clears a stale .ipa first", exp.begins_with("rm -f '/proj/build/ios/Game.ipa' && "), exp)
	var ver: Dictionary = by_name["verify_entitlements"]
	_check("verify unzips the ipa and dumps the signed entitlements",
		str(ver["shell"]).contains("'unzip' '-q' '/proj/build/ios/Game.ipa'")
			and str(ver["shell"]).contains("'codesign' '--display' '--entitlements' '-' '--xml' '/proj/build/ios/build_kit_ipa_check/Payload/Game.app'"), str(ver["shell"]))
	_check("verify post_check wiring", ver.get("post_check", "") == "entitlements"
		and ver.get("expected", "") == paths["entitlements"] and ver.get("actual", "") == paths["ipa_entitlements"], str(ver))
	var upl := str(by_name["upload"]["shell"])
	_check("upload uses the upload options + provisioning updates + auth",
		upl.contains("'-exportOptionsPlist' '%s'" % paths["upload_options_plist"]) and upl.contains("'-allowProvisioningUpdates'")
			and upl.contains("'-authenticationKeyIssuerID' 'ISS'") and not upl.contains("-exportPath"), upl)
	_check("export options destinations", ServiceT.make_export_options_xml("ABCDE12345", false).contains("<string>export</string>")
		and ServiceT.make_export_options_xml("ABCDE12345", true).contains("<string>upload</string>"))

	# entitlement_mismatches (pure)
	var want := {"com.apple.developer.applesignin": ["Default"], "aps-environment": "development",
		"com.apple.developer.game-center": true, "com.apple.developer.associated-domains": ["applinks:example.com"],
		"com.apple.developer.ubiquity-container-identifiers": ["iCloud.$(CFBundleIdentifier)"]}
	var full := {"com.apple.developer.applesignin": ["Default"], "aps-environment": "production",
		"com.apple.developer.game-center": true, "com.apple.developer.associated-domains": ["applinks:example.com", "webcredentials:example.com"],
		"com.apple.developer.ubiquity-container-identifiers": ["iCloud.com.example.game"], "application-identifier": "ABCDE12345.com.example.game"}
	_check("mismatch none when all present (aps rewritten, $() expanded, extras ok)", ServiceT.entitlement_mismatches(want, full).is_empty(),
		str(ServiceT.entitlement_mismatches(want, full)))
	var no_siwa := full.duplicate()
	no_siwa.erase("com.apple.developer.applesignin")
	var m := ServiceT.entitlement_mismatches(want, no_siwa)
	_check("mismatch: missing SIWA", m.size() == 1 and m[0].begins_with("com.apple.developer.applesignin (missing)"), str(m))
	var short_domains := full.duplicate()
	short_domains["com.apple.developer.associated-domains"] = ["webcredentials:example.com"]
	var short_m := ServiceT.entitlement_mismatches(want, short_domains)
	_check("mismatch: array element missing", short_m.size() == 1
		and short_m[0] == "com.apple.developer.associated-domains (missing value \"applinks:example.com\")", str(short_m))
	var gc_off := full.duplicate()
	gc_off["com.apple.developer.game-center"] = false
	_check("mismatch: bool value differs", ServiceT.entitlement_mismatches(want, gc_off).size() == 1)
	_check("mismatch: empty expectation always passes", ServiceT.entitlement_mismatches({}, {}).is_empty())

	if OS.get_name() != "macOS":
		return  # plutil / codesign / zip are macOS tools
	var dir := OS.get_cache_dir().path_join("build_kit_verify").path_join("ios_signing")
	_delete_dir(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var ent_path := dir.path_join("Game.entitlements")
	_write(ent_path, ENT_SIWA)
	_write(dir.path_join("ok.plist"), ENT_SIGNED_OK)
	_write(dir.path_join("stale.plist"), ENT_SIGNED_STALE)
	_write(dir.path_join("empty.plist"), "")
	var parsed := ServiceT.read_plist_file(ent_path)
	_check("read_plist_file parses XML", parsed["ok"] and parsed["data"].get("com.apple.developer.applesignin", []) == ["Default"], str(parsed))
	_check("read_plist_file: empty codesign dump = no entitlements", ServiceT.read_plist_file(dir.path_join("empty.plist")) == {"ok": true, "data": {}})
	_check("read_plist_file: missing file errors", not ServiceT.read_plist_file(dir.path_join("nope.plist"))["ok"])
	_check("check_ipa_entitlements passes a fully-signed fixture", ServiceT.check_ipa_entitlements(ent_path, dir.path_join("ok.plist")).is_empty())
	var stale := ServiceT.check_ipa_entitlements(ent_path, dir.path_join("stale.plist"), {"bundle_id": "com.example.game"})
	_check("check_ipa_entitlements fails the stale-profile fixture", stale.get("ok", true) == false
		and str(stale.get("guidance", "")).contains("com.apple.developer.applesignin (missing)")
		and str(stale.get("title", "")).contains("not uploaded"), str(stale))
	_check("check_ipa_entitlements fails an empty signature", not ServiceT.check_ipa_entitlements(ent_path, dir.path_join("empty.plist")).is_empty())

	# End to end: run the real embed + verify stage shells against a fake
	# archive / .ipa (an ad-hoc-signable stand-in binary, no Xcode needed).
	var e2e := ServiceT.derive_paths(dir.path_join("game") + "/", "../out/Game.ipa", "iOS")
	DirAccess.make_dir_recursive_absolute(e2e["archived_app"])
	DirAccess.make_dir_recursive_absolute(e2e["entitlements"].get_base_dir())
	_write(e2e["entitlements"], ENT_SIWA)
	_write(e2e["archived_app"].path_join("Info.plist"), "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>Game</string><key>CFBundleIdentifier</key><string>com.example.game</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>\n")
	var app_q := Exec.quote(e2e["archived_app"])
	var setup := _sh("cp /usr/bin/true %s/Game && codesign --remove-signature %s/Game" % [app_q, app_q])
	_check("e2e: fake unsigned app", setup[0] == 0, setup[1])
	var stages: Array = ServiceT.ios_stages(e2e, "/godot", "/x", "iOS", 1, false, PackedStringArray())
	var embed_st: Dictionary = stages.filter(func(st): return st["name"] == "embed_entitlements")[0]
	var verify_st: Dictionary = stages.filter(func(st): return st["name"] == "verify_entitlements")[0]
	var to_ipa := "cd %s && rm -rf Payload %s && mkdir Payload && cp -R %s Payload/ && zip -qr %s Payload && rm -rf Payload" % [
		Exec.quote(dir), Exec.quote(e2e["ipa"]), app_q, Exec.quote(e2e["ipa"])]
	var r := _sh(str(embed_st["shell"]))
	_check("e2e: embed stage signs", r[0] == 0, r[1])
	r = _sh(to_ipa)
	_check("e2e: ipa zipped", r[0] == 0, r[1])
	r = _sh(str(verify_st["shell"]))
	_check("e2e: verify stage dumps entitlements", r[0] == 0, r[1])
	var pass_result := ServiceT.check_ipa_entitlements(verify_st["expected"], verify_st["actual"])
	_check("e2e: entitlements survive into the ipa", pass_result.is_empty(), str(pass_result))
	# the bug: an app signed WITHOUT the entitlements (what -exportArchive made
	# of the unsigned archive) must fail the check, i.e. block the upload
	r = _sh("codesign --force --sign - %s && %s && %s" % [app_q, to_ipa, verify_st["shell"]])
	_check("e2e: re-sign without entitlements", r[0] == 0, r[1])
	var fail_result := ServiceT.check_ipa_entitlements(verify_st["expected"], verify_st["actual"])
	_check("e2e: missing entitlement fails the build", fail_result.get("ok", true) == false
		and str(fail_result.get("guidance", "")).contains("com.apple.developer.applesignin (missing)"), str(fail_result))
	# missing entitlements file -> loud, classified failure
	DirAccess.remove_absolute(e2e["entitlements"])
	r = _sh(str(embed_st["shell"]))
	_check("e2e: embed fails without the entitlements file", r[0] != 0
		and Classify.classify(r[1], {}, "ios")["id"] == "no_entitlements_file", r[1])
	_delete_dir(dir)


func _sh(line: String) -> Array:
	var out: Array = []
	var code := OS.execute("/bin/zsh", ["-c", "( %s ) 2>&1" % line], out)
	return [code, "".join(out.map(func(c): return str(c)))]


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _delete_dir(path: String) -> void:
	if path.contains("build_kit_verify") and DirAccess.dir_exists_absolute(path):
		OS.execute("rm", ["-rf", path])


# --- release CLI (cli/release_core.gd) ---------------------------------------
#
# git and App Store Connect are mocked: GitMock answers by argv prefix and
# records every call; ASC results are fed as the helper's JSON dicts. Nothing
# here uploads, commits or pushes.

class GitMock:
	var calls: Array = []
	var replies := {}  # argv-prefix -> Array of {code, output}; the last one repeats
	var defaults := {}  # prefixes set by base(): the first on() replaces them

	func base(prefix: String, code := 0, output := "") -> GitMock:
		replies[prefix] = [{"code": code, "output": output}]
		defaults[prefix] = true
		return self

	func on(prefix: String, code := 0, output := "") -> GitMock:
		if defaults.has(prefix):
			defaults.erase(prefix)
			replies.erase(prefix)
		if not replies.has(prefix):
			replies[prefix] = []
		replies[prefix].append({"code": code, "output": output})
		return self

	func run(args: PackedStringArray) -> Dictionary:
		var line := " ".join(args)
		calls.append(line)
		var best := ""
		for prefix in replies:
			if line.begins_with(prefix) and prefix.length() > best.length():
				best = prefix
		if best == "":
			return {"code": 0, "output": ""}
		var queue: Array = replies[best]
		return queue.pop_front() if queue.size() > 1 else queue[0]

	func called(prefix: String) -> int:
		return calls.filter(func(c): return str(c).begins_with(prefix)).size()


func _no_force(calls: Array) -> bool:
	for x in calls:
		var line := str(x)
		if line.contains("--force") or line.contains(" -f") or line.contains("+HEAD"):
			return false
	return true


## A repo on main tracking origin/main, clean, nothing staged, not ahead.
func _clean_git() -> GitMock:
	return GitMock.new() \
		.base("rev-parse --is-inside-work-tree", 0, "true\n") \
		.base("symbolic-ref", 0, "main\n") \
		.base("config --get branch.main.remote", 0, "origin\n") \
		.base("config --get branch.main.merge", 0, "refs/heads/main\n") \
		.base("rev-list --count", 0, "0\n") \
		.base("rev-parse HEAD", 0, "abc123def4567890\n")


func _verify_release_cli() -> void:
	# argument parsing
	var d := Release.parse_args(PackedStringArray())
	_check("args: defaults upload+commit+push", d["ok"] and d["upload"] and d["commit"] and d["push"]
		and d["project"] == "" and d["timeout_min"] == Release.DEFAULT_TIMEOUT_MIN and not d["help"], str(d))
	var a := Release.parse_args(PackedStringArray(["--no-upload"]))
	_check("args: --no-upload implies no commit/push", a["ok"] and not a["upload"] and not a["commit"] and not a["push"], str(a))
	a = Release.parse_args(PackedStringArray(["--no-commit"]))
	_check("args: --no-commit implies no push", a["ok"] and a["upload"] and not a["commit"] and not a["push"], str(a))
	a = Release.parse_args(PackedStringArray(["--no-push"]))
	_check("args: --no-push keeps the commit", a["ok"] and a["upload"] and a["commit"] and not a["push"], str(a))
	a = Release.parse_args(PackedStringArray(["--project", "/tmp/game", "--timeout", "45"]))
	_check("args: --project <dir> --timeout <n>", a["ok"] and a["project"] == "/tmp/game" and a["timeout_min"] == 45, str(a))
	a = Release.parse_args(PackedStringArray(["--project=/tmp/g h", "--timeout=5"]))
	_check("args: --flag=value form", a["ok"] and a["project"] == "/tmp/g h" and a["timeout_min"] == 5, str(a))
	a = Release.parse_args(PackedStringArray(["--project"]))
	_check("args: --project without value", not a["ok"] and str(a["error"]).contains("--project"), str(a))
	a = Release.parse_args(PackedStringArray(["--project", "--no-push"]))
	_check("args: --project doesn't swallow a flag", not a["ok"], str(a))
	a = Release.parse_args(PackedStringArray(["--force"]))
	_check("args: unknown flag rejected", not a["ok"] and str(a["error"]).contains("--force"), str(a))
	a = Release.parse_args(PackedStringArray(["--timeout", "0"]))
	_check("args: --timeout must be positive", not a["ok"], str(a))
	a = Release.parse_args(PackedStringArray(["--timeout=soon"]))
	_check("args: --timeout must be a number", not a["ok"], str(a))
	a = Release.parse_args(PackedStringArray(["--no-push=1"]))
	_check("args: switches take no value", not a["ok"], str(a))
	a = Release.parse_args(PackedStringArray(["-h"]))
	_check("args: -h", a["ok"] and a["help"], str(a))
	_check("usage names the script path", Release.USAGE.contains("addons/build_kit/cli/release_ios.sh"))

	# build-number selection
	_check("build#: config ahead of ASC", Release.pick_build_number(9, 3) == 9)
	_check("build#: uploaded-but-uncommitted bump is skipped", Release.pick_build_number(5, 7) == 8)
	_check("build#: config == highest+1", Release.pick_build_number(5, 4) == 5)
	_check("build#: config == highest", Release.pick_build_number(5, 5) == 6)
	_check("build#: nothing on ASC", Release.pick_build_number(5, 0) == 5)
	_check("build#: floor of 1", Release.pick_build_number(0, 0) == 1)
	var asc_builds := [
		{"version": "7", "state": "PROCESSING"}, {"version": "12", "state": "VALID"},
		{"version": "1.0.3", "state": "VALID"}, {"version": "3", "state": "INVALID"}]
	_check("build#: highest ignores non-integer versions", Release.highest_build(asc_builds) == 12)
	_check("build#: highest of none", Release.highest_build([]) == 0)
	_check("poll: state of a listed build", Release.build_state(asc_builds, 7) == "PROCESSING")
	_check("poll: unlisted build", Release.build_state(asc_builds, 13) == "")
	_check("poll: verdicts", Release.state_verdict("VALID") == "done" and Release.state_verdict("INVALID") == "failed"
		and Release.state_verdict("FAILED") == "failed" and Release.state_verdict("PROCESSING") == "wait"
		and Release.state_verdict("") == "wait")
	var py := _sh("cd %s && python3 -B -c %s" % [Exec.quote(ProjectSettings.globalize_path("res://addons/build_kit")),
		Exec.quote("import asc_helper as h; print(h.highest_build_number([{'version':'7'},{'version':'12'},{'version':'1.0.3'}]), h.highest_build_number([]))")])
	_check("asc_helper highest_build_number", py[0] == 0 and str(py[1]).strip_edges() == "12 0", str(py))

	# config write
	var two_space := "{\n  \"ios\": {\n    \"preset\": \"iOS\",\n    \"build_number\": 7\n  },\n  \"android\": {\"version_code\": 3}\n}\n"
	var w := Release.set_build_number_text(two_space, 8)
	_check("config: in-place edit keeps formatting", w == two_space.replace("\"build_number\": 7", "\"build_number\": 8"), w)
	w = Release.set_build_number_text("{\"ios\": {\"build_number\": 4.0}}", 5)
	_check("config: float build_number rewritten as int", w == "{\"ios\": {\"build_number\": 5}}", w)
	w = Release.set_build_number_text("{\"itch\": {\"user\": \"u\"}}", 2)
	var wp: Variant = JSON.parse_string(w)
	_check("config: missing ios section added", wp is Dictionary and int(wp["ios"]["build_number"]) == 2
		and wp["itch"]["user"] == "u" and not wp.has("android"), w)
	w = Release.set_build_number_text("{\"ios\": {\"build_number\": 4}, \"x\": {\"build_number\": 9}}", 5)
	wp = JSON.parse_string(w)
	_check("config: an unrelated build_number survives", wp is Dictionary and int(wp["ios"]["build_number"]) == 5
		and int(wp["x"]["build_number"]) == 9, w)
	_check("config: empty file", JSON.parse_string(Release.set_build_number_text("", 3))["ios"]["build_number"] == 3)
	_check("config: invalid JSON refused", Release.set_build_number_text("not json", 3) == "")
	var tmp_dir := OS.get_temp_dir().path_join("build_kit_verify_release_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(tmp_dir)
	var cfg_path := tmp_dir.path_join("build_kit.config.json")
	_write(cfg_path, "{\n\t\"ios\": {\n\t\t\"preset\": \"iOS\",\n\t\t\"build_number\": 41\n\t}\n}\n")
	var wr := Release.write_build_number(cfg_path, 42)
	_check("config: write_build_number on disk", wr["ok"] and FileAccess.get_file_as_string(cfg_path)
		== "{\n\t\"ios\": {\n\t\t\"preset\": \"iOS\",\n\t\t\"build_number\": 42\n\t}\n}\n", FileAccess.get_file_as_string(cfg_path))
	_write(cfg_path, "[1, 2]")
	_check("config: write refuses a non-object", not Release.write_build_number(cfg_path, 2)["ok"]
		and FileAccess.get_file_as_string(cfg_path) == "[1, 2]")
	_delete_dir(tmp_dir)

	# commit message
	var msg := Release.commit_message("1.4", 42, 43)
	_check("commit message format", msg == "build: iOS 1.4 (42) uploaded to TestFlight; next build_number 43", msg)
	_check("commit message has no trailers", not msg.contains("\n") and not msg.to_lower().contains("co-authored"))

	# git preflight
	var g := _clean_git()
	var pre := Release.git_preflight(g.run, true)
	_check("git preflight: clean repo with upstream", pre["ok"] and pre["remote"] == "origin"
		and pre["merge"] == "refs/heads/main" and pre["branch"] == "main", str(pre))
	g = _clean_git().on("diff --cached --name-only", 0, "src/main.gd\n")
	pre = Release.git_preflight(g.run, true)
	_check("git preflight: refuses other staged changes", not pre["ok"] and str(pre["error"]).contains("src/main.gd"), str(pre))
	g = _clean_git().on("status --porcelain", 0, " M build_kit.config.json\n")
	_check("git preflight: refuses a locally modified config", not Release.git_preflight(g.run, true)["ok"])
	g = _clean_git().on("status --porcelain", 0, "?? build_kit.config.json\n")
	_check("git preflight: untracked config is fine", Release.git_preflight(g.run, true)["ok"])
	g = _clean_git().on("symbolic-ref", 1, "")
	_check("git preflight: detached HEAD refused when pushing", not Release.git_preflight(g.run, true)["ok"])
	_check("git preflight: detached HEAD fine with --no-push", Release.git_preflight(g.run, false)["ok"])
	g = _clean_git().on("config --get branch.main.remote", 1, "")
	pre = Release.git_preflight(g.run, true)
	_check("git preflight: no upstream", not pre["ok"] and str(pre["error"]).contains("upstream"), str(pre))
	g = _clean_git().on("rev-list --count", 0, "2\n")
	pre = Release.git_preflight(g.run, true)
	_check("git preflight: ahead of upstream refused", not pre["ok"] and str(pre["error"]).contains("ahead"), str(pre))
	g = _clean_git().on("rev-parse --is-inside-work-tree", 128, "fatal: not a git repository")
	_check("git preflight: not a repo", not Release.git_preflight(g.run, false)["ok"])

	# git commit + push
	var upstream := {"remote": "origin", "merge": "refs/heads/main"}
	g = _clean_git().on("diff --cached --name-only", 0, "").on("diff --cached --name-only", 0, "build_kit.config.json\n")
	var c := Release.git_commit_and_push(g.run, msg, true, upstream)
	_check("git: commit + push ok", c["ok"] and c["pushed"] and not c["rebased"] and c["sha"] == "abc123def4567890", str(c))
	_check("git: adds ONLY the config", g.called("add -- build_kit.config.json") == 1 and g.called("add") == 1, str(g.calls))
	_check("git: commits with the message, pathspec-limited",
		g.calls.has("commit -q -m %s -- build_kit.config.json" % msg), str(g.calls))
	_check("git: pushes HEAD to the upstream branch", g.calls.has("push origin HEAD:refs/heads/main"), str(g.calls))
	_check("git: never forces", _no_force(g.calls), str(g.calls))

	g = _clean_git().on("diff --cached --name-only", 0, "").on("diff --cached --name-only", 0, "build_kit.config.json\n")
	c = Release.git_commit_and_push(g.run, msg, false, upstream)
	_check("git: --no-push commits without pushing", c["ok"] and not c["pushed"] and g.called("push") == 0, str(g.calls))

	g = _clean_git().on("diff --cached --name-only", 0, "other.gd\n")
	c = Release.git_commit_and_push(g.run, msg, true, upstream)
	_check("git: refuses when something else is staged", not c["ok"] and g.called("add") == 0 and g.called("commit") == 0, str(c))

	g = _clean_git().on("diff --cached --name-only", 0, "").on("diff --cached --name-only", 0, "build_kit.config.json\nsneaky.gd\n")
	c = Release.git_commit_and_push(g.run, msg, true, upstream)
	_check("git: refuses + unstages when add staged more than the config", not c["ok"] and g.called("commit") == 0
		and g.called("reset -q -- build_kit.config.json") == 1, str(g.calls))

	var rejected := " ! [rejected]        HEAD -> main (fetch first)\nerror: failed to push some refs\n"
	g = _clean_git().on("diff --cached --name-only", 0, "").on("diff --cached --name-only", 0, "build_kit.config.json\n") \
		.on("push", 1, rejected).on("push", 0, "") \
		.on("rev-parse HEAD", 0, "abc123def4567890\n").on("rev-parse HEAD", 0, "fedcba9876543210\n")
	c = Release.git_commit_and_push(g.run, msg, true, upstream)
	_check("git: rejected push → fetch, rebase only the release commit, retry", c["ok"] and c["pushed"] and c["rebased"]
		and c["sha"] == "fedcba9876543210" and g.called("fetch -q origin") == 1
		and g.called("rebase -q --autostash --onto @{u} HEAD~1") == 1 and g.called("push") == 2, str(g.calls))

	g = _clean_git().on("diff --cached --name-only", 0, "").on("diff --cached --name-only", 0, "build_kit.config.json\n") \
		.on("push", 1, rejected)
	c = Release.git_commit_and_push(g.run, msg, true, upstream)
	_check("git: retries only once, then fails (no force)", not c["ok"] and g.called("push") == 2
		and _no_force(g.calls), str(g.calls))

	g = _clean_git().on("diff --cached --name-only", 0, "").on("diff --cached --name-only", 0, "build_kit.config.json\n") \
		.on("push", 1, rejected).on("rebase -q", 1, "CONFLICT (content): Merge conflict in build_kit.config.json")
	c = Release.git_commit_and_push(g.run, msg, true, upstream)
	_check("git: rebase conflict aborts and leaves the commit local", not c["ok"] and g.called("rebase --abort") == 1
		and g.called("push") == 1 and c["sha"] != "", str(g.calls))

	g = _clean_git().on("diff --cached --name-only", 0, "").on("diff --cached --name-only", 0, "build_kit.config.json\n") \
		.on("push", 128, "fatal: Could not read from remote repository.")
	c = Release.git_commit_and_push(g.run, msg, true, upstream)
	_check("git: non-rejection push failure isn't retried", not c["ok"] and g.called("push") == 1 and g.called("fetch") == 0, str(g.calls))

	# cleanup selection, redaction, summary
	var victims := Release.cleanup_entries(["logs", "old.txt", "Game"],
		["logs", "old.txt", "Game", "Game.xcodeproj", "Game.ipa", "Game.xcarchive"],
		["Game", "Game.xcodeproj", "Game.xcarchive", "Game.ipa"], [])
	_check("cleanup: new + known outputs, never logs or foreign files",
		victims == ["Game", "Game.ipa", "Game.xcarchive", "Game.xcodeproj"], str(victims))
	victims = Release.cleanup_entries([], ["logs", "Game.ipa", "Game"], ["Game", "Game.ipa"], ["Game.ipa"])
	_check("cleanup: --no-upload keeps the .ipa", victims == ["Game"], str(victims))
	_check("cleanup: refuses a project root", Release.cleanup_entries([], ["project.godot", "Game"], ["Game"], []).is_empty())
	_check("redact", Release.redact("key K1234 at /x/AuthKey.p8, issuer abcd-1", ["K1234", "/x/AuthKey.p8", "abcd-1", ""])
		== "key <redacted> at <redacted>, issuer <redacted>")
	var summary := Release.summary_line(true, "1.4", "42", "VALID", "verified", "abc123def456")
	_check("summary line", summary == "release_ios: OK  version=1.4 build=42 asc=VALID entitlements=verified commit=abc123def456", summary)

	# version + preset
	_check("marketing version from preset", ServiceT.marketing_version({"short_version": "2.1"}, "1.0") == "2.1")
	_check("marketing version falls back to project", ServiceT.marketing_version({"short_version": ""}, "1.3") == "1.3")
	var sv := ServiceT.parse_preset_text(PRESET_FIXTURE.replace("application/export_project_only=true",
		"application/export_project_only=true\napplication/short_version=\"3.2\""), "iOS")
	_check("preset short_version parsed", sv.get("short_version", "") == "3.2", str(sv))

	# the shipped entry point: executable, and wired to the runner (usage paths
	# only — they exit before any service, ASC or git work)
	var sh := ProjectSettings.globalize_path("res://addons/build_kit/cli/release_ios.sh")
	_check("release_ios.sh is executable", _sh("test -x %s" % Exec.quote(sh))[0] == 0)
	if OS.get_name() == "macOS" or OS.get_name() == "Linux":
		var env := "GODOT=%s " % Exec.quote(OS.get_executable_path())
		var r := _sh(env + Exec.quote(sh) + " --help")
		_check("release_ios.sh --help", r[0] == 0 and str(r[1]).contains("--no-upload"), str(r))
		r = _sh(env + Exec.quote(sh) + " --bogus")
		_check("release_ios.sh rejects unknown flags (exit 2)", r[0] == 2 and str(r[1]).contains("--bogus"), str(r))
		r = _sh(env + Exec.quote(sh) + " --project /nonexistent/build_kit_verify")
		_check("release_ios.sh needs a project.godot", r[0] == 2 and str(r[1]).contains("project.godot"), str(r))
		r = _sh("GODOT=/nonexistent/godot " + Exec.quote(sh) + " --help")
		_check("release_ios.sh reports a missing Godot", r[0] == 2 and str(r[1]).contains("GODOT"), str(r))
