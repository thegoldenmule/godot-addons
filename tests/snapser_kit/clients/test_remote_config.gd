extends "res://tests/snapser_kit/snapkit_test_case.gd"

## SnapKitRemoteConfig: path, parsers, contract.

const FakeTransport := preload("res://tests/snapser_kit/clients/fake_transport.gd")

var t: FakeTransport
var rc: SnapKitRemoteConfig


func before_each() -> void:
	t = add_node(FakeTransport.new())
	rc = SnapKitRemoteConfig.new(t)


func test_builders_and_parsers() -> void:
	check_eq(SnapKitRemoteConfig.app_config_path(), "/v1/remote-config/app-config/v1", "default version")
	check_eq(SnapKitRemoteConfig.app_config_path("v 2"), "/v1/remote-config/app-config/v%202", "encoded")
	check_eq(SnapKitRemoteConfig.parse_app_config({"config": {"a": 1}}), {"a": 1}, "parse")
	check_eq(SnapKitRemoteConfig.parse_app_config({"config": "x"}), {}, "non-dict config")
	check_eq(SnapKitRemoteConfig.parse_app_config(null), {}, "null")
	var cfg := {"daily_missions": {"pool": [1]}, "flag": true}
	check_eq(SnapKitRemoteConfig.extract_block(cfg, "daily_missions"), {"pool": [1]}, "block")
	check_eq(SnapKitRemoteConfig.extract_block(cfg, "flag"), {}, "non-dict block")
	check_eq(SnapKitRemoteConfig.extract_block(cfg, "nope"), {}, "missing block")


func test_fetch_contract() -> void:
	t.respond(HTTPClient.METHOD_GET, "/v1/remote-config/app-config/{v}", 200,
		{"config": {"daily_missions": {"count": 3}, "motd": "hi"}})
	var r: Dictionary = await rc.fetch_app_config()
	check(r.ok, "ok")
	check_eq(r.config.motd, "hi", "config parsed")
	check_eq(SnapKitRemoteConfig.extract_block(r.config, "daily_missions").count, 3.0, "block")
	check_eq(t.calls[0].path, "/v1/remote-config/app-config/v1", "path")


func test_fetch_errors() -> void:
	t.respond(HTTPClient.METHOD_GET, "/v1/remote-config/app-config/v1", 200, {"nope": 1})
	var r: Dictionary = await rc.fetch_app_config()
	check(not r.ok, "2xx without config -> not ok")
	check_eq(r.error, SnapKitTransport.ERR_BAD_RESPONSE, "bad_response")
	check_eq(r.config, {}, "empty config")
	t.respond(HTTPClient.METHOD_GET, "/v1/remote-config/app-config/v1", 404)
	r = await rc.fetch_app_config()
	check_eq(r.error, "http_404", "404")
	t.offline = true
	r = await rc.fetch_app_config()
	check_eq(r.error, "offline", "offline")
	check_eq(r.config, {}, "offline config")
