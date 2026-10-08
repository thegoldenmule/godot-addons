extends "res://tests/snapser_kit/snapkit_test_case.gd"

## SnapKitStats: key validation, path/body builders, parsers, and contract tests
## through the fake transport.

const FakeTransport := preload("res://tests/snapser_kit/clients/fake_transport.gd")

var t: FakeTransport
var stats: SnapKitStats


func before_each() -> void:
	t = add_node(FakeTransport.new())
	stats = SnapKitStats.new(t)


func test_key_validation() -> void:
	for k in ["wins", "career_wins", "a1", "0", "x_y_z_9"]:
		check(SnapKitStats.is_valid_key(k), "valid: " + k)
	for k in ["", "Wins", "career.wins", "game-wins", "wins ", "wïns", "a/b", "battleships.wins"]:
		check(not SnapKitStats.is_valid_key(k), "invalid: '%s'" % k)


func test_builders_and_parsers() -> void:
	check_eq(SnapKitStats.stat_path("wins"), "/v1/statistics/user-stats/{user_id}/wins", "stat path")
	check_eq(SnapKitStats.all_stats_path(), "/v1/statistics/settings/user-stats/{user_id}", "all path")
	check_eq(SnapKitStats.set_body(12), {"value": "12"}, "set body: value is a string")
	check_eq(SnapKitStats.increment_body(-3), {"delta": -3}, "increment body")
	check_eq(SnapKitStats.parse_value({"key": "k", "value": "9007199254740993"}), 9007199254740993, "int64 string")
	check_eq(SnapKitStats.parse_value({"value": 5.0}), 5, "number value")
	check_eq(SnapKitStats.parse_value(null, 7), 7, "fallback")
	check_eq(SnapKitStats.parse_stats({"user_statistics": [
		{"key": "wins", "value": "3"}, {"key": "losses", "value": 2}, {"value": "1"}, "junk"]}),
		{"wins": 3, "losses": 2}, "parse_stats")
	check_eq(SnapKitStats.parse_stats({}), {}, "parse_stats empty")


func test_set_stat_contract() -> void:
	t.route(HTTPClient.METHOD_PUT, "/v1/statistics/user-stats/{uid}/{key}",
		func(req: Dictionary) -> Dictionary:
			return {"status": 200, "json": {"key": req.params.key, "user_id": req.params.uid, "value": req.body.value}})
	var r: Dictionary = await stats.set_stat("career_wins", 42)
	check(r.ok, "ok")
	check_eq(r.value, 42, "value")
	check_eq(r.error, "", "no error")
	check_eq(t.calls.size(), 1, "one request")
	check_eq(t.calls[0].path, "/v1/statistics/user-stats/user-1/career_wins", "user id expanded")
	check_eq(t.calls[0].body, {"value": "42"}, "body")


func test_increment_stat_contract() -> void:
	t.respond(HTTPClient.METHOD_PATCH, "/v1/statistics/user-stats/{uid}/{key}", 200,
		{"key": "games", "user_id": "user-1", "value": "8"})
	var r: Dictionary = await stats.increment_stat("games", 2)
	check(r.ok, "ok")
	check_eq(r.value, 8, "new total parsed from string")
	check_eq(t.calls[0].method, HTTPClient.METHOD_PATCH, "PATCH")
	check_eq(t.calls[0].body, {"delta": 2.0}, "delta (JSON number)")


func test_get_stat_missing_and_present() -> void:
	t.respond(HTTPClient.METHOD_GET, "/v1/statistics/user-stats/{uid}/missing", 404, {"error_code": 4000})
	t.respond(HTTPClient.METHOD_GET, "/v1/statistics/user-stats/{uid}/wins", 200, {"value": "5"})
	var r: Dictionary = await stats.get_stat("missing")
	check(r.ok, "404 -> ok")
	check_eq(r.exists, false, "exists false")
	check_eq(r.value, 0, "value 0")
	r = await stats.get_stat("wins")
	check(r.ok and r.exists, "present")
	check_eq(r.value, 5, "value")


func test_get_stats_contract() -> void:
	t.respond(HTTPClient.METHOD_GET, "/v1/statistics/settings/user-stats/{uid}", 200,
		{"user_statistics": [{"key": "a", "value": "1"}, {"key": "b", "value": "22"}]})
	var r: Dictionary = await stats.get_stats()
	check(r.ok, "ok")
	check_eq(r.stats, {"a": 1, "b": 22}, "stats map")


func test_invalid_key_makes_no_request() -> void:
	var r: Dictionary = await stats.set_stat("Bad.Key", 1)
	check(not r.ok, "rejected")
	check_eq(r.error, SnapKitTransport.ERR_INVALID_ARGUMENT, "invalid_argument")
	r = await stats.increment_stat("bad-key")
	check_eq(r.error, SnapKitTransport.ERR_INVALID_ARGUMENT, "increment rejected")
	r = await stats.get_stat("")
	check_eq(r.error, SnapKitTransport.ERR_INVALID_ARGUMENT, "get rejected")
	check_eq(t.calls.size(), 0, "no requests")


func test_offline_and_http_errors() -> void:
	t.offline = true
	var r: Dictionary = await stats.increment_stat("wins")
	check_eq(r.error, SnapKitTransport.ERR_OFFLINE, "offline")
	check_eq(r.value, 0, "value default")
	check_eq(r.keys().slice(0, 4), ["ok", "status", "json", "error"], "transport shape kept")
	t.offline = false
	t.respond(HTTPClient.METHOD_PUT, "/v1/statistics/user-stats/{uid}/{key}", 500, {"message": "boom"})
	r = await stats.set_stat("wins", 1)
	check(not r.ok, "500 not ok")
	check_eq(r.error, "http_500", "http error")
	check_eq(r.value, 0, "value default on error")
