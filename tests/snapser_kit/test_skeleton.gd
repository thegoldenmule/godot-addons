extends "res://tests/snapser_kit/snapkit_test_case.gd"

## Skeleton guard: every kit script loads and parses, and the pure helpers that
## are implemented from the start (SnapKitJson, SnapKitTransport statics) behave.

const SCRIPTS := [
	"res://addons/snapser_kit/plugin.gd",
	"res://addons/snapser_kit/core/snapkit_config.gd",
	"res://addons/snapser_kit/core/snapkit_auth.gd",
	"res://addons/snapser_kit/core/snapkit_transport.gd",
	"res://addons/snapser_kit/core/snapkit_json.gd",
	"res://addons/snapser_kit/core/snapkit_errors.gd",
	"res://addons/snapser_kit/clients/snapkit_stats.gd",
	"res://addons/snapser_kit/clients/snapkit_leaderboards.gd",
	"res://addons/snapser_kit/clients/snapkit_storage.gd",
	"res://addons/snapser_kit/clients/snapkit_remote_config.gd",
	"res://addons/snapser_kit/clients/snapkit_quests.gd",
	"res://addons/snapser_kit/clients/snapkit_profiles.gd",
	"res://addons/snapser_kit/clients/snapkit_analytics.gd",
	"res://addons/snapser_kit/service/snapkit_service.gd",
	"res://addons/snapser_kit/service/snapkit_cloud_save.gd",
	"res://addons/snapser_kit/testing/snapkit_mock_gateway.gd",
]


func test_all_scripts_load() -> void:
	for path in SCRIPTS:
		var s: Script = load(path)
		check(s != null and s.can_instantiate(), "loads: " + path)


func test_json_to_int_lenient() -> void:
	check_eq(SnapKitJson.to_int("9007199254740993"), 9007199254740993, "int64 string keeps precision")
	check_eq(SnapKitJson.to_int(42.0), 42, "float")
	check_eq(SnapKitJson.to_int(" 7 "), 7, "padded string")
	check_eq(SnapKitJson.to_int("nope", -1), -1, "garbage -> fallback")
	check_eq(SnapKitJson.to_int(null, 3), 3, "null -> fallback")


func test_json_accessors() -> void:
	var d := {"a_64": "123", "a": 1, "s": 5.0, "arr": [1], "obj": {"x": {"y": 2}}}
	check_eq(SnapKitJson.get_int64(d, "a_64", "a"), 123, "prefers *_64")
	check_eq(SnapKitJson.get_int64({"a": 4}, "a_64", "a"), 4, "falls back to plain key")
	check_eq(SnapKitJson.get_str(d, "s"), "5", "integral float -> no .0")
	check_eq(SnapKitJson.get_array(d, "obj"), [], "wrong type -> []")
	check_eq(SnapKitJson.dig(d, ["obj", "x", "y"]), 2, "dig")
	check_eq(SnapKitJson.dig(d, ["obj", "nope"], "z"), "z", "dig miss")
	check_eq(SnapKitJson.parse("{bad"), null, "bad json -> null")
	check_eq(SnapKitJson.parse(""), null, "empty -> null")


func test_transport_helpers() -> void:
	check_eq(SnapKitTransport.with_query("/v1/x", {"a": 1, "b": null, "t": "x y"}),
		"/v1/x?a=1&t=x%20y", "query build")
	check_eq(SnapKitTransport.with_query("/v1/x?z=1", {"a": true}), "/v1/x?z=1&a=true", "append query")
	check_eq(SnapKitTransport.expand_path("/v1/u/{user_id}/k", "a/b"), "/v1/u/a%2Fb/k", "user_id placeholder")
	check(SnapKitTransport.is_idempotent(HTTPClient.METHOD_PUT), "PUT idempotent")
	check(not SnapKitTransport.is_idempotent(HTTPClient.METHOD_POST), "POST not idempotent")
	check(SnapKitTransport.is_retryable({"status": 503, "error": "http_503"}), "5xx retryable")
	check(not SnapKitTransport.is_retryable({"status": 404, "error": "http_404"}), "404 not retryable")
	var r := SnapKitTransport.error_result(SnapKitTransport.ERR_OFFLINE)
	check_eq(r.keys(), ["ok", "status", "json", "error", "snap_code"], "result shape")
