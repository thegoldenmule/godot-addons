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
