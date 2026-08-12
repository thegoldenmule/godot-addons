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
