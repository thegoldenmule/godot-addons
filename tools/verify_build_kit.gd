extends SceneTree

## Headless verifier for the build_kit addon's service logic: shell quoting,
## failure classification, preset parsing, export-options generation, env
## parsing, teams parsing, helper-JSON parsing, and a real spawn round-trip
## through exec.gd's log + exit-sentinel contract.
## Run: godot --headless --path . --script res://tools/verify_build_kit.gd

const Exec := preload("res://addons/build_kit/exec.gd")
const Classify := preload("res://addons/build_kit/classify.gd")
const ServiceT := preload("res://addons/build_kit/build_kit_service.gd")

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

	print("VERIFY build_kit: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	quit(0 if _fails == 0 else 1)
