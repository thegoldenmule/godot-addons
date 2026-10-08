extends "res://tests/snapser_kit/snapkit_test_case.gd"

## SnapKitConfig: resolution order, validation, accessors.

const COMMITTED := {
	"game_id": "demo",
	"gateway_url": "https://gateway.example.test/abc",
	"anon_handle_prefix": "demo-",
	"leaderboards": {"wins": "career_wins"},
	"cloud_save": {"blob_key": "save_v2", "sync_prefixes": ["prog_", "", 3]},
	"link_providers": ["apple", "google"],
	"custom": {"x": 1},
}


func _resolve(env := {}, args := PackedStringArray(), override := {}, debug := true,
		committed: Dictionary = COMMITTED) -> SnapKitConfig:
	return SnapKitConfig.resolve(committed, env, args, override, debug)


func test_committed_is_used_when_nothing_else_set() -> void:
	var c := _resolve()
	check(c.is_ready(), "online")
	check_eq(c.gateway_url, "https://gateway.example.test/abc", "gateway")
	check_eq(c.source, SnapKitConfig.SOURCE_COMMITTED, "source")
	check_eq(c.offline_reason, "", "no reason")


func test_env_offline_wins_over_everything() -> void:
	var c := _resolve({"SNAPSER_OFFLINE": "1", "SNAPSER_GATEWAY_URL": "https://e.test/x"},
		PackedStringArray(), {"gateway_url": "https://o.test/y"})
	check(c.is_offline(), "offline")
	check_eq(c.gateway_url, "", "no gateway when offline")
	check(c.offline_reason.contains("SNAPSER_OFFLINE"), "reason names env var")
	check_eq(c.game_id, "demo", "committed settings still loaded offline")


func test_env_offline_zero_is_not_offline() -> void:
	check(_resolve({"SNAPSER_OFFLINE": "0"}).is_ready(), "0 means not forced")
	check(_resolve({"SNAPSER_OFFLINE": ""}).is_ready(), "empty means not forced")


func test_cli_offline_flag() -> void:
	var c := _resolve({}, PackedStringArray(["--foo", "--snapser-offline"]))
	check(c.is_offline(), "offline")
	check_eq(c.offline_reason, "--snapser-offline", "reason")


func test_env_gateway_beats_override_and_committed() -> void:
	var c := _resolve({"SNAPSER_GATEWAY_URL": "https://env.test/s/"}, PackedStringArray(),
		{"gateway_url": "https://o.test/y"})
	check_eq(c.gateway_url, "https://env.test/s", "env url, trailing slash stripped")
	check_eq(c.source, SnapKitConfig.SOURCE_ENV, "source env")


func test_override_only_in_debug() -> void:
	var dbg := _resolve({}, PackedStringArray(), {"gateway_url": "https://o.test/y"}, true)
	check_eq(dbg.gateway_url, "https://o.test/y", "debug uses override")
	check_eq(dbg.source, SnapKitConfig.SOURCE_OVERRIDE, "source override")
	var rel := _resolve({}, PackedStringArray(), {"gateway_url": "https://o.test/y"}, false)
	check_eq(rel.gateway_url, "https://gateway.example.test/abc", "release ignores override")


func test_override_can_force_offline() -> void:
	var c := _resolve({}, PackedStringArray(), {"offline": true}, true)
	check(c.is_offline(), "override offline")


func test_nothing_configured_is_offline() -> void:
	var c := _resolve({}, PackedStringArray(), {}, true, {"game_id": "x"})
	check(c.is_offline(), "offline")
	check_eq(c.offline_reason, "no gateway configured", "reason")


func test_invalid_gateway_is_offline() -> void:
	var c := _resolve({}, PackedStringArray(), {}, true,
		{"gateway_url": "https://gateway.snapser.com/<snapend-id>"})
	check(c.is_offline(), "placeholder url rejected")
	check(c.offline_reason.begins_with("invalid gateway_url"), "reason")


func test_is_valid_gateway_url() -> void:
	check(SnapKitConfig.is_valid_gateway_url("https://a.b/c"), "https")
	check(SnapKitConfig.is_valid_gateway_url("http://mock.invalid"), "http")
	check(not SnapKitConfig.is_valid_gateway_url("ftp://a.b"), "scheme")
	check(not SnapKitConfig.is_valid_gateway_url("https://"), "no host")
	check(not SnapKitConfig.is_valid_gateway_url("https://{id}"), "placeholder")
	check(not SnapKitConfig.is_valid_gateway_url(""), "empty")


func test_accessors() -> void:
	var c := _resolve()
	check_eq(c.handle_prefix(), "demo-", "explicit prefix")
	check_eq(c.leaderboard_id("wins"), "career_wins", "mapped board")
	check_eq(c.leaderboard_id("other"), "other", "unmapped passes through")
	check_eq(c.cloud_save_blob_key(), "save_v2", "blob key")
	check_eq(c.cloud_save_prefixes(), PackedStringArray(["prog_"]), "prefixes filtered")
	check_eq(c.link_providers, PackedStringArray(["apple", "google"]), "providers")
	check_eq(c.raw.get("custom"), {"x": 1}, "unknown keys kept in raw")
	check(not c.quests_enabled(), "quests off by default")


func test_defaults() -> void:
	var c := SnapKitConfig.from_dict({"game_id": "g"})
	check_eq(c.handle_prefix(), "g-", "prefix from game id")
	check_eq(SnapKitConfig.from_dict({}).handle_prefix(), "snapkit-", "fallback prefix")
	check_eq(c.cloud_save_blob_key(), "save_v1", "default blob key")
	check_eq(c.cloud_save_prefixes().size(), 0, "no prefixes = disabled")


func test_quests_flag() -> void:
	check(SnapKitConfig.from_dict({"quests": true}).quests_enabled(), "bool true")
	check(SnapKitConfig.from_dict({"quests": {}}).quests_enabled(), "section present")
	check(not SnapKitConfig.from_dict({"quests": {"enabled": false}}).quests_enabled(), "section disabled")
	check(not SnapKitConfig.from_dict({"quests": false}).quests_enabled(), "bool false")


func test_from_dict_ignores_environment() -> void:
	# The suite runs with SNAPSER_OFFLINE=1; from_dict must still be online.
	check(SnapKitConfig.from_dict({"gateway_url": "http://mock.invalid"}).is_ready(), "online")


func test_from_project_missing_file_never_fails() -> void:
	var c := SnapKitConfig.from_project("res://does_not_exist.json")
	check(c.is_offline(), "offline")
	check(c.describe().begins_with("offline: "), "describe offline")


# ---- v0.2: test/tool rule, force_offline, declarations ------------------------

func test_test_or_tool_run_forces_offline() -> void:
	for args in [["res://tests/OnlineSmoke.tscn"], ["--script", "res://tools/x.gd"],
			["tests/run.gd"], ["--headless", "./tools/build.tscn"]]:
		var c := _resolve({}, PackedStringArray(args))
		check(c.is_offline(), "offline for %s" % str(args))
		check(c.offline_reason.begins_with("test/tool run"), "reason for %s" % str(args))
	check(_resolve({}, PackedStringArray(["res://main.tscn", "tests"])).is_ready(), "normal run online")
	check(_resolve({"SNAPSER_TESTS_ONLINE": "1"}, PackedStringArray(["res://tests/a.tscn"])).is_ready(),
		"SNAPSER_TESTS_ONLINE=1 opts back in")
	check(_resolve({"SNAPSER_TESTS_ONLINE": "1", "SNAPSER_OFFLINE": "1"},
		PackedStringArray(["res://tests/a.tscn"])).is_offline(), "SNAPSER_OFFLINE still wins")


func test_force_offline() -> void:
	var c := SnapKitConfig.from_dict({"gateway_url": "https://g.test/x"})
	check(c.is_ready(), "online first")
	check(c.force_offline("capture run") == c, "chains")
	check(c.is_offline(), "offline")
	check_eq(c.gateway_url, "", "gateway cleared")
	check_eq(c.offline_reason, "capture run", "reason")
	check_eq(SnapKitConfig.from_dict({"gateway_url": "https://g.test/x"}).force_offline("").offline_reason,
		"forced offline", "default reason")


func test_declarations_parse_and_lookup() -> void:
	var c := SnapKitConfig.from_dict({"declared": {"stats": ["hits", "", 3], "events": []}})
	check(c.has_declarations("stats") and c.has_declarations("events"), "declared kinds")
	check(not c.has_declarations("boards"), "absent kind")
	check(c.is_declared("stats", "hits"), "declared stat")
	check(not c.is_declared("stats", "misses"), "undeclared stat")
	check(not c.is_declared("events", "run_end"), "empty list declares nothing")
	check(c.is_declared("boards", "anything"), "absent kind is unchecked")
	check_eq(c.declared.stats, PackedStringArray(["hits"]), "junk filtered")


const MANIFEST := {"settings": [
	{"id": "statistics", "data": {"statistics": [{"key": "hits"}, {"key": "misses"}]}},
	{"id": "leaderboards", "data": {"leaderboards": [{"name": "career_wins"}]}},
	{"id": "analytics", "data": {"events": [{"name": "run_end", "is_snap_event": false},
		{"name": "snap_logins", "is_snap_event": true}]}},
	{"id": "storage", "data": {"keys": [{"key": "save_v1"}]}},
]}


func test_declaration_problems() -> void:
	var good := SnapKitConfig.from_dict({
		"leaderboards": {"wins": "career_wins"},
		"cloud_save": {"blob_key": "save_v1", "sync_prefixes": ["p_"]},
		"declared": {"stats": ["hits", "misses"], "boards": ["career_wins"], "events": ["run_end"], "blobs": ["save_v1"]},
	})
	check_eq(good.declaration_problems(MANIFEST), PackedStringArray(), "consistent")
	var names := SnapKitConfig.manifest_names(MANIFEST)
	check_eq(names.events, PackedStringArray(["run_end"]), "snap_* built-ins excluded")
	var bad := SnapKitConfig.from_dict({
		"leaderboards": {"best": "best_accuracy"},
		"cloud_save": {"blob_key": "save_v2", "sync_prefixes": ["p_"]},
		"declared": {"stats": ["hits", "sinks"]},
	})
	var probs := bad.declaration_problems(MANIFEST)
	var text := "\n".join(probs)
	check(text.contains("stat 'sinks' is declared in the config but not on the snapend"), "extra stat")
	check(text.contains("stat 'misses' is on the snapend manifest but missing"), "drifted stat")
	check(text.contains("'best_accuracy' is not a board"), "unmapped board")
	check(text.contains("blob 'save_v2'"), "blob key")
	check_eq(probs.size(), 4, "exactly those 4")


# ---- v0.2.1: auto-offline fails CLOSED ----------------------------------------

## The theo-asteroids verifier incident: a test run resolved ONLINE because the
## script was not spelled res://tests/... Reproduced with an absolute --script
## path; 0.2.0's allow-list of spellings missed it and logged in for real.
func test_absolute_script_path_is_a_test_run() -> void:
	var abs_script := ProjectSettings.globalize_path("res://tests/snapser_kit/run_tests.gd")
	var c := _resolve({}, PackedStringArray(["--script", abs_script]))
	check(c.is_offline(), "--script <absolute path> -> offline (was online on 0.2.0)")
	var abs_scene := ProjectSettings.globalize_path("res://tests/Any.tscn")
	check(SnapKitConfig.is_test_or_tool_run(PackedStringArray([abs_scene])), "absolute scene path inside the project")


func test_any_script_run_is_a_tool_run() -> void:
	for args in [["--script", "res://bake.gd"], ["-s", "bake.gd"], ["-s", "/elsewhere/x.gd"]]:
		check(_resolve({}, PackedStringArray(args)).is_offline(), "script run offline: %s" % str(args))


func test_headless_fails_closed() -> void:
	var c := _resolve({}, PackedStringArray([SnapKitConfig.ARG_HEADLESS_RUN, "res://scenes/Main.tscn"]))
	check(c.is_offline(), "headless game-looking run stays offline")
	check(c.offline_reason.begins_with("headless run"), "reason: " + c.offline_reason)
	check(_resolve({"SNAPSER_TESTS_ONLINE": "1"}, PackedStringArray([SnapKitConfig.ARG_HEADLESS_RUN])).is_ready(),
		"SNAPSER_TESTS_ONLINE=1 opts a headless run in")
	check(_resolve({}, PackedStringArray(["res://scenes/Main.tscn"])).is_ready(), "windowed game run online")


func test_from_project_in_this_headless_suite_is_offline() -> void:
	# This suite runs headless via --script: the real resolver must say offline
	# even with a committed gateway and without SNAPSER_OFFLINE.
	var args := OS.get_cmdline_args()
	args.append(SnapKitConfig.ARG_HEADLESS_RUN)
	var c := SnapKitConfig.resolve({"gateway_url": "https://g.test/x"}, {}, args, {}, true)
	check(c.is_offline(), "offline: " + c.offline_reason)


func test_offline_paths_config() -> void:
	var cfg := {"gateway_url": "https://g.test/x", "offline_paths": ["res://scenes/tools", "res://tests/"]}
	check(SnapKitConfig.resolve(cfg, {}, PackedStringArray(["res://scenes/tools/Bake.tscn"]), {}, true).is_offline(),
		"custom root")
	check(SnapKitConfig.resolve(cfg, {}, PackedStringArray(["res://tests/A.tscn"]), {}, true).is_offline(),
		"trailing slash tolerated")
	check(SnapKitConfig.resolve(cfg, {}, PackedStringArray(["res://tools/X.tscn"]), {}, true).is_ready(),
		"replaces the default list (res://tools no longer listed)")
	check(SnapKitConfig.resolve(cfg, {}, PackedStringArray(["res://scenes/toolsmith/A.tscn"]), {}, true).is_ready(),
		"prefix match is per path segment")
	check_eq(SnapKitConfig.from_dict({}).offline_paths, PackedStringArray(["res://tests", "res://tools"]), "default")


func test_as_res_path_forms() -> void:
	check_eq(SnapKitConfig.as_res_path("res://tests/a/../b.gd"), "res://tests/b.gd", "simplified")
	check_eq(SnapKitConfig.as_res_path("./tools/x.tscn"), "res://tools/x.tscn", "relative")
	check_eq(SnapKitConfig.as_res_path("--headless"), "", "flag")
	check_eq(SnapKitConfig.as_res_path("/definitely/outside/project.gd"), "", "outside the project")
	var id := ResourceLoader.get_resource_uid("res://tests/snapser_kit/run_tests.gd")
	if id != ResourceUID.INVALID_ID:
		check_eq(SnapKitConfig.as_res_path(ResourceUID.id_to_text(id)), "res://tests/snapser_kit/run_tests.gd", "uid://")
