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

	# exec.gd quoting
	_check("quote plain", Exec.quote("abc") == "'abc'")
	_check("quote space", Exec.quote("a b") == "'a b'")
	_check("quote apostrophe", Exec.quote("a'b") == "'a'\\''b'")
	_check("command_line", Exec.command_line(PackedStringArray(["x", "a b"])) == "'x' 'a b'")

	# classify.gd
	var missing := Classify.classify("Step failed: IDEDistribution.DistributionAppRecordProviderError.missingApp(bundleId: \"com.x\")", {"bundle_id": "com.x"})
	_check("classify missingApp", missing["id"] == "missing_app_record", str(missing))
	_check("classify guidance splice", str(missing["guidance"]).contains("com.x"))
	var conflict := Classify.classify("error: Moveborne has conflicting provisioning settings.")
	_check("classify signing conflict", conflict["id"] == "signing_conflict")
	var no_cert := Classify.classify("error: exportArchive No signing certificate \"iOS Distribution\" found\n** EXPORT FAILED **", {"team_id": "T1"})
	_check("classify missing dist cert", no_cert["id"] == "no_dist_cert", str(no_cert))
	_check("classify dist cert splice", str(no_cert["guidance"]).contains("T1"))
	var perm := Classify.classify("error: exportArchive Cloud signing permission error\nerror: exportArchive Provisioning profile \"X\" doesn't include signing certificate \"Y\".", {"key_id": "K9"})
	_check("classify cloud-signing permission first", perm["id"] == "cloud_signing_permission", str(perm))
	_check("classify key id splice", str(perm["guidance"]).contains("K9"))
	var stale := Classify.classify("error: exportArchive Provisioning profile \"X\" doesn't include signing certificate \"Y\".")
	_check("classify stale managed profile", stale["id"] == "profile_missing_cert", str(stale))
	var generic := Classify.classify("something entirely novel")
	_check("classify fallback", generic["id"] == "unknown")
	_check("classify links passthrough", str(missing.get("links", [])).contains("appstoreconnect.apple.com/apps"), str(missing))
	_check("classify fallback links empty", (generic.get("links", [1]) as Array).is_empty())
	var order := Classify.classify("error: exportArchive Error Downloading App Information\n** EXPORT FAILED **")
	_check("classify specific beats generic", order["id"] == "missing_app_record", str(order))

	# preset parsing
	var preset := ServiceT.parse_ios_preset_text(PRESET_FIXTURE)
	_check("preset found", preset.get("name", "") == "iOS", str(preset))
	_check("preset section", preset.get("section", "") == "preset.1")
	_check("preset bundle", preset.get("bundle_id", "") == "com.example.game")
	_check("preset team", preset.get("team_id", "") == "TEAM123456")
	_check("preset project_only", preset.get("export_project_only", false) == true)
	_check("preset by name miss", ServiceT.parse_ios_preset_text(PRESET_FIXTURE, "nope").is_empty())
	_check("preset no ios", ServiceT.parse_ios_preset_text("[preset.0]\nname=\"Web\"\nplatform=\"Web\"\n").is_empty())

	# derived paths
	var paths := ServiceT.derive_paths("/proj/game/", "../build/ios/Game.ipa")
	_check("paths out", paths["out"] == "/proj/build/ios/Game.ipa", str(paths))
	_check("paths app", paths["app"] == "Game")
	_check("paths plist", paths["info_plist"] == "/proj/build/ios/Game/Game-Info.plist")

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

	# bundle-id validation + preset creation round-trip
	_check("bundle id ok", ServiceT.valid_bundle_id("com.studio.game-2"))
	_check("bundle id needs dot", not ServiceT.valid_bundle_id("game"))
	_check("bundle id rejects junk", not ServiceT.valid_bundle_id("com..game") and not ServiceT.valid_bundle_id("com.stu dio.game"))
	var svc2: Node = ServiceT.new()
	var tmp_preset := "user://verify_build_kit_presets.cfg"
	if FileAccess.file_exists(tmp_preset):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_preset))
	var created: Dictionary = svc2.create_ios_preset("com.example.verify", tmp_preset)
	_check("create preset ok", created.get("ok", false), str(created))
	var created_text := FileAccess.open(tmp_preset, FileAccess.READ).get_as_text() if FileAccess.file_exists(tmp_preset) else ""
	var reparsed := ServiceT.parse_ios_preset_text(created_text)
	_check("created preset parses", reparsed.get("bundle_id", "") == "com.example.verify", created_text.left(200))
	_check("created preset project-only", reparsed.get("export_project_only", false) == true)
	_check("create rejects bad bundle", not svc2.create_ios_preset("nodots", tmp_preset).get("ok", true))
	svc2.free()

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

	# real spawn round-trip (log + exit sentinel)
	var log_path := OS.get_cache_dir().path_join("build_kit_verify").path_join("spawn.log")
	var handle := Exec.spawn_shell("echo hello; exit 7", log_path)
	_check("spawn ok", bool(handle.get("ok", false)), str(handle))
	if handle.get("ok", false):
		var tries := 0
		while Exec.exit_code(handle["exit_path"]) < 0 and tries < 100:
			OS.delay_msec(50)
			tries += 1
		_check("spawn exit code", Exec.exit_code(handle["exit_path"]) == 7)
		_check("spawn log", Exec.read_all(log_path).contains("hello"))
		var tail := Exec.read_from(log_path, 0)
		_check("spawn tail", str(tail["text"]).contains("hello") and int(tail["offset"]) > 0)

	print("VERIFY build_kit: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	quit(0 if _fails == 0 else 1)
