extends "res://tests/snapser_kit/snapkit_test_case.gd"

## SnapKitMockGateway: routing, auth enforcement, failure injection.

const PUT := HTTPClient.METHOD_PUT
const GET := HTTPClient.METHOD_GET


func _login(mock: SnapKitMockGateway, handle := "h1") -> Dictionary:
	var r := mock.handle(PUT, "/v1/auth/login/anon", PackedStringArray(),
		JSON.stringify({"username": handle, "create_user": true}))
	return SnapKitJson.parse(r.text).user


func _authed(user: Dictionary) -> PackedStringArray:
	return PackedStringArray(["Token: " + user.session_token, "User-Id: " + user.id])


func test_anon_login_is_stable_per_handle() -> void:
	var mock := SnapKitMockGateway.new()
	var a := _login(mock, "x")
	var b := _login(mock, "x")
	var c := _login(mock, "y")
	check_eq(a.id, b.id, "same handle -> same user")
	check(a.id != c.id, "different handle -> different user")
	check(a.created and not b.created, "created flag")
	check_eq(mock.login_count, 3, "login count")


func test_routes_params_and_query() -> void:
	var mock := SnapKitMockGateway.new()
	mock.require_auth = false
	mock.route(GET, "/v1/things/{id}/x", func(req: Dictionary) -> Dictionary:
		return {"status": 200, "json": {"id": req.params.id, "q": req.query}})
	var r := mock.handle(GET, "/v1/things/a%2Fb/x?n=1&t=a&t=b", PackedStringArray(), "")
	var j: Dictionary = SnapKitJson.parse(r.text)
	check_eq(r.status, 200, "status")
	check_eq(j.id, "a/b", "decoded param")
	check_eq(j.q, {"n": "1", "t": ["a", "b"]}, "query with repeated key")
	check_eq(mock.handle(GET, "/v1/nope", PackedStringArray(), "").status, 404, "unrouted 404")
	check_eq(mock.requests_to("/v1/things").size(), 1, "request log")


func test_later_route_wins_and_text_passthrough() -> void:
	var mock := SnapKitMockGateway.new()
	mock.require_auth = false
	mock.respond(GET, "/v1/a", 200, {"v": 1})
	mock.route(GET, "/v1/a", func(_r: Dictionary) -> Dictionary:
		return {"status": 200, "text": "{\"big\": \"9007199254740993\"}"})
	var r := mock.handle(GET, "/v1/a", PackedStringArray(), "")
	check_eq(r.text, "{\"big\": \"9007199254740993\"}", "verbatim text from later route")


func test_auth_enforced_and_invalidated() -> void:
	var mock := SnapKitMockGateway.new()
	mock.respond(GET, "/v1/a", 200, {})
	check_eq(mock.handle(GET, "/v1/a", PackedStringArray(), "").status, 401, "no token -> 401")
	var u := _login(mock)
	check_eq(mock.handle(GET, "/v1/a", _authed(u), "").status, 200, "valid token")
	mock.invalidate_sessions()
	check_eq(mock.handle(GET, "/v1/a", _authed(u), "").status, 401, "invalidated -> 401")


func test_fail_next_kinds() -> void:
	var mock := SnapKitMockGateway.new()
	mock.require_auth = false
	mock.respond(GET, "/v1/a", 200, {})
	mock.fail_next(1, "timeout")
	mock.fail_next(1, "network")
	mock.fail_next(1, "http_503")
	check(mock.handle(GET, "/v1/a", PackedStringArray(), "").get("timeout", false), "timeout")
	check(mock.handle(GET, "/v1/a", PackedStringArray(), "").get("network_error", false), "network")
	check_eq(mock.handle(GET, "/v1/a", PackedStringArray(), "").status, 503, "http_503")
	check_eq(mock.handle(GET, "/v1/a", PackedStringArray(), "").status, 200, "then normal")


func test_reset() -> void:
	var mock := SnapKitMockGateway.new()
	mock.require_auth = false
	mock.respond(GET, "/v1/a", 200, {})
	_login(mock)
	mock.reset()
	check_eq(mock.handle(GET, "/v1/a", PackedStringArray(), "").status, 404, "routes cleared")
	check_eq(mock.login_count, 0, "counters cleared")
	check_eq(mock.requests.size(), 1, "log restarted")
