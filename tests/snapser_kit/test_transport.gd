extends "res://tests/snapser_kit/snapkit_test_case.gd"

## SnapKitTransport contract tests against the mock gateway: offline,
## {user_id} expansion, 401 -> reauth -> replay, retries, timeouts, int64.

const GET := HTTPClient.METHOD_GET
const PUT := HTTPClient.METHOD_PUT
const POST := HTTPClient.METHOD_POST


func test_offline_short_circuits() -> void:
	var t := SnapKitTransport.new()
	add_node(t)
	t.setup(SnapKitConfig.from_dict({}), null)
	var res: Dictionary = await t.request(GET, "/v1/x")
	check_eq(res, SnapKitTransport.error_result("offline"), "offline result")
	check_eq(t.attempts_sent, 0, "nothing sent")


func test_user_id_placeholder_and_headers() -> void:
	var mock := SnapKitMockGateway.new()
	var seen := {}
	mock.route(PUT, "/v1/stats/{uid}/{key}", func(req: Dictionary) -> Dictionary:
		seen.merge(req)
		return {"status": 200, "json": {"ok": true}})
	var s := mock_stack(mock)
	var res: Dictionary = await s.transport.request(PUT, "/v1/stats/{user_id}/wins", {"value": 3})
	check(res.ok, "ok")
	check_eq(res.json, {"ok": true}, "json parsed")
	check_eq(seen.params.uid, s.auth.user_id, "user id substituted after login")
	check_eq(seen.body, {"value": 3.0}, "json body (JSON numbers parse as float)")
	check_eq(seen.headers.get("user-id"), s.auth.user_id, "User-Id header")
	check(str(seen.headers.get("token", "")) != "", "Token header")
	check_eq(mock.login_count, 1, "one login")


func test_unauthenticated_call_sends_no_session() -> void:
	var mock := SnapKitMockGateway.new()
	mock.require_auth = false
	var hdrs := {}
	mock.route(GET, "/v1/open", func(req: Dictionary) -> Dictionary:
		hdrs.merge(req.headers)
		return {"status": 200})
	var s := mock_stack(mock)
	var res: Dictionary = await s.transport.request(GET, "/v1/open", null, {"auth": false})
	check(res.ok, "ok")
	check_eq(mock.login_count, 0, "no login")
	check(not hdrs.has("token"), "no Token header")


func test_401_reauths_once_and_replays_same_user() -> void:
	var mock := SnapKitMockGateway.new()
	mock.respond(GET, "/v1/item", 200, {"v": 1})
	var s := mock_stack(mock)
	check((await s.transport.request(GET, "/v1/item")).ok, "first call")
	var uid: String = s.auth.user_id
	var handle: String = s.auth.username()
	mock.invalidate_sessions()   # simulates a snapend apply
	var res: Dictionary = await s.transport.request(GET, "/v1/item")
	check(res.ok, "replayed after reauth")
	check_eq(s.auth.user_id, uid, "same user after reauth")
	check_eq(s.auth.username(), handle, "handle kept")


func test_401_applies_to_post_too() -> void:
	var mock := SnapKitMockGateway.new()
	mock.respond(POST, "/v1/p", 200, {})
	var s := mock_stack(mock)
	check((await s.transport.request(POST, "/v1/p", {})).ok, "first")
	mock.invalidate_sessions()
	var before: int = mock.login_count
	check((await s.transport.request(POST, "/v1/p", {})).ok, "POST replayed after 401")
	check_eq(mock.login_count, before + 1, "exactly one re-login")


func test_persistent_401_is_returned_after_one_replay() -> void:
	var mock := SnapKitMockGateway.new()
	mock.respond(GET, "/v1/item", 401, {"message": "nope"})
	var s := mock_stack(mock)
	var res: Dictionary = await s.transport.request(GET, "/v1/item")
	check_eq(res.error, "http_401", "error")
	check_eq(mock.requests_to("/v1/item").size(), 2, "original + one replay")


func test_get_retries_on_timeout_then_succeeds() -> void:
	var mock := SnapKitMockGateway.new()
	mock.respond(GET, "/v1/item", 200, {})
	var s := mock_stack(mock)
	await s.auth.ensure_session()
	mock.fail_next(2, "timeout")
	var res: Dictionary = await s.transport.request(GET, "/v1/item")
	check(res.ok, "succeeds on 3rd attempt")
	check_eq(mock.requests_to("/v1/item").size(), 3, "three attempts")


func test_retries_exhausted_returns_timeout() -> void:
	var mock := SnapKitMockGateway.new()
	mock.respond(GET, "/v1/item", 200, {})
	var s := mock_stack(mock)
	await s.auth.ensure_session()
	mock.fail_next(5, "timeout")
	var res: Dictionary = await s.transport.request(GET, "/v1/item", null, {"retries": 1})
	check_eq(res, SnapKitTransport.error_result("timeout"), "timeout result")
	check_eq(mock.requests_to("/v1/item").size(), 2, "1 + 1 retry")


func test_post_not_retried_by_default() -> void:
	var mock := SnapKitMockGateway.new()
	mock.respond(POST, "/v1/item", 200, {})
	var s := mock_stack(mock)
	await s.auth.ensure_session()
	mock.fail_next(1, "http_503")
	var res: Dictionary = await s.transport.request(POST, "/v1/item", {})
	check_eq(res.error, "http_503", "no retry")
	check_eq(mock.requests_to("/v1/item").size(), 1, "single attempt")


func test_5xx_and_429_retried_but_404_not() -> void:
	var mock := SnapKitMockGateway.new()
	mock.respond(GET, "/v1/item", 200, {})
	var s := mock_stack(mock)
	await s.auth.ensure_session()
	mock.fail_next(1, "http_500")
	mock.fail_next(1, "http_429")
	check((await s.transport.request(GET, "/v1/item")).ok, "recovered from 500 + 429")
	var res: Dictionary = await s.transport.request(GET, "/v1/missing")
	check_eq(res.error, "http_404", "404")
	check_eq(mock.requests_to("/v1/missing").size(), 1, "404 not retried")


func test_no_retry_disables_retries_and_401_replay() -> void:
	var mock := SnapKitMockGateway.new()
	mock.respond(PUT, "/v1/item", 200, {})
	var s := mock_stack(mock)
	await s.auth.ensure_session()
	mock.fail_next(1, "timeout")
	var res: Dictionary = await s.transport.request(PUT, "/v1/item", {}, {"no_retry": true})
	check_eq(res.error, "timeout", "no backoff retry")
	mock.invalidate_sessions()
	res = await s.transport.request(PUT, "/v1/item", {}, {"no_retry": true})
	check_eq(res.error, "http_401", "no 401 replay")
	check_eq(mock.requests_to("/v1/item").size(), 2, "one attempt each")


func test_network_error_and_login_failure() -> void:
	var mock := SnapKitMockGateway.new()
	mock.respond(PUT, "/v1/auth/login/anon", 500, {"message": "down"})
	var s := mock_stack(mock)
	var res: Dictionary = await s.transport.request(GET, "/v1/item")
	check_eq(res.error, "no_session", "login failure -> no_session")


func test_int64_strings_and_bad_json() -> void:
	var mock := SnapKitMockGateway.new()
	mock.route(GET, "/v1/big", func(_r: Dictionary) -> Dictionary:
		return {"status": 200, "text": "{\"score_64\": \"9007199254740993\", \"score\": 1}"})
	mock.route(GET, "/v1/bad", func(_r: Dictionary) -> Dictionary:
		return {"status": 200, "text": "not json"})
	var s := mock_stack(mock)
	var big: Dictionary = await s.transport.request(GET, "/v1/big")
	check_eq(SnapKitJson.get_int64(big.json, "score_64", "score"), 9007199254740993, "int64 precision")
	var bad: Dictionary = await s.transport.request(GET, "/v1/bad")
	check(bad.ok and bad.json == null, "2xx with unparsable body: ok, json null")


func test_backoff_delay_bounds() -> void:
	for attempt in [1, 2, 3, 10]:
		var d := SnapKitTransport.backoff_delay(attempt)
		var base := minf(SnapKitTransport.BACKOFF_BASE_S * pow(2.0, attempt - 1), SnapKitTransport.BACKOFF_MAX_S)
		check(d >= base * 0.75 - 0.0001 and d <= base * 1.25 + 0.0001, "attempt %d in jitter band" % attempt)


func test_mock_latency_is_honoured() -> void:
	var mock := SnapKitMockGateway.new()
	mock.require_auth = false
	mock.respond(GET, "/v1/item", 200, {})
	mock.latency_s = 0.1
	var s := mock_stack(mock)
	# Settle: the first frame after a long synchronous stretch has a large delta
	# that would fire a fresh timer early.
	await tree.process_frame
	await tree.process_frame
	var t0 := Time.get_ticks_msec()
	check((await s.transport.request(GET, "/v1/item", null, {"auth": false})).ok, "ok")
	# A SceneTree timer can fire up to ~1 frame early (frame accounting starts
	# before t0), so assert it clearly waited rather than an exact 100 ms.
	check(Time.get_ticks_msec() - t0 >= 50, "waited for latency")


func test_snap_code_and_named_errors() -> void:
	var mock := SnapKitMockGateway.new()
	mock.respond(PUT, "/v1/q/claim", 400, {"api_error_code": 15014, "message": "Quest not completed"})
	mock.respond(PUT, "/v1/q/other", 400, {"api_error_code": 999})
	mock.respond(PUT, "/v1/q/old", 404, {"error_code": 4000})
	var s := mock_stack(mock)
	var r: Dictionary = await s.transport.request(PUT, "/v1/q/claim", {})
	check_eq(r.error, SnapKitErrors.QUEST_NOT_CLAIMABLE, "15014 -> quest_not_claimable")
	check_eq(r.snap_code, 15014, "snap_code")
	r = await s.transport.request(PUT, "/v1/q/other", {})
	check_eq(r.error, "http_400", "unknown code keeps http_<status>")
	check_eq(r.snap_code, 999, "unknown snap_code still reported")
	r = await s.transport.request(PUT, "/v1/q/old", {})
	check_eq(r.error, SnapKitErrors.UNDECLARED, "older error_code key understood")
	r = await s.transport.request(GET, "/v1/missing")
	check_eq(r.snap_code, 0, "no code in body -> 0")
