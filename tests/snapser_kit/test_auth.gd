extends "res://tests/snapser_kit/snapkit_test_case.gd"

## SnapKitAuth: handle minting, single-flight login, persistence, reauth,
## refresh, sign-out, linking / account_exists / adopt_session.

const PUT := HTTPClient.METHOD_PUT


func test_generate_handle_is_128_bit_hex() -> void:
	var a := SnapKitAuth.generate_handle("demo-")
	var b := SnapKitAuth.generate_handle("demo-")
	check(a.begins_with("demo-"), "prefix")
	var hex := a.trim_prefix("demo-")
	check_eq(hex.length(), 32, "32 hex chars = 16 bytes")
	check(hex.is_valid_hex_number(), "hex")
	check(a != b, "unique")


func test_parse_login_response() -> void:
	var p := SnapKitAuth.parse_login_response({"user": {"id": "u1", "session_token": "t",
		"token_validity_seconds": "120", "login_types": ["ANON", "APPLE"]}})
	check(p.ok, "ok")
	check_eq(p.ttl_s, 120, "ttl from string")
	check_eq(p.linked, PackedStringArray(["apple"]), "linked excludes anon")
	check(not SnapKitAuth.parse_login_response({"user": {"id": "u1"}}).ok, "no token -> not ok")
	check(not SnapKitAuth.parse_login_response(null).ok, "null -> not ok")


func test_offline_never_requests() -> void:
	var mock := SnapKitMockGateway.new()
	var s := mock_stack(mock, SnapKitConfig.from_dict({}))
	check(not await s.auth.ensure_session(), "offline -> false")
	check_eq(mock.requests.size(), 0, "no requests")


func test_concurrent_ensure_session_is_single_flight() -> void:
	var mock := SnapKitMockGateway.new()
	mock.latency_s = 0.05
	var s := mock_stack(mock)
	var results := []
	var done := [0]
	for i in 3:
		(func() -> void:
			results.append(await s.auth.ensure_session())
			done[0] += 1).call()
	while done[0] < 3:
		await tree.process_frame
	check_eq(results, [true, true, true], "all callers succeed")
	check_eq(mock.login_count, 1, "exactly one login request")
	check(s.auth.username().begins_with("kit_test-"), "handle uses game prefix")


func test_session_persists_and_is_reused() -> void:
	var mock := SnapKitMockGateway.new()
	var s := mock_stack(mock)
	check(await s.auth.ensure_session(), "login")
	var path: String = s.auth.session_path
	var auth2 := SnapKitAuth.new()
	add_node(auth2)
	auth2.session_path = path
	auth2.setup(mock_config(), s.transport)
	check(auth2.has_session(), "loaded from disk")
	check_eq(auth2.user_id, s.auth.user_id, "same user")
	check(await auth2.ensure_session(), "ensure ok")
	check_eq(mock.login_count, 1, "no second login")


func test_reauth_keeps_handle_and_user() -> void:
	var mock := SnapKitMockGateway.new()
	var s := mock_stack(mock)
	await s.auth.ensure_session()
	var uid: String = s.auth.user_id
	var token: String = s.auth.session_token
	check(await s.auth.reauth(), "reauth")
	check_eq(s.auth.user_id, uid, "same user")
	check(s.auth.session_token != token, "new token")
	check_eq(mock.refresh_count, 0, "anon reauth skips refresh")


func test_expired_session_refreshes_first() -> void:
	var mock := SnapKitMockGateway.new()
	var s := mock_stack(mock)
	await s.auth.ensure_session()
	s.auth._expires_at = 0   # locally expired, still valid server-side
	check(await s.auth.ensure_session(), "ensure ok")
	check_eq(mock.refresh_count, 1, "refreshed")
	check_eq(mock.login_count, 1, "no new login")


func test_expired_and_invalid_falls_back_to_anon_login() -> void:
	var mock := SnapKitMockGateway.new()
	var s := mock_stack(mock)
	await s.auth.ensure_session()
	var uid: String = s.auth.user_id
	s.auth._expires_at = 0
	mock.invalidate_sessions()
	check(await s.auth.ensure_session(), "ensure ok")
	check_eq(mock.login_count, 2, "fell back to anon login")
	check_eq(s.auth.user_id, uid, "same user")


func test_sign_out_mints_new_user() -> void:
	var mock := SnapKitMockGateway.new()
	var s := mock_stack(mock)
	await s.auth.ensure_session()
	var uid: String = s.auth.user_id
	var seen := []
	s.auth.session_changed.connect(func(u: String) -> void: seen.append(u))
	s.auth.sign_out()
	check(not FileAccess.file_exists(s.auth.session_path), "file deleted")
	check_eq(s.auth.username(), "", "handle cleared")
	await s.auth.ensure_session()
	check(s.auth.user_id != uid, "new user")
	check_eq(seen.size(), 2, "signed-out + new session events")
	check_eq(seen[0], "", "empty id on sign-out")


func _provider_route(mock: SnapKitMockGateway, provider: String, uid: String, created: bool) -> void:
	mock.route(PUT, "/v1/auth/login/" + provider, func(_r: Dictionary) -> Dictionary:
		return {"status": 200, "json": {"user": {"id": uid, "created": created,
			"session_token": mock.issue_session(uid), "token_validity_seconds": 3600,
			"login_types": [provider.to_upper()]}}})


func test_link_fresh_provider_user_associates() -> void:
	var mock := SnapKitMockGateway.new()
	var assoc := []
	mock.route(PUT, "/v1/auth/associate-logins", func(req: Dictionary) -> Dictionary:
		assoc.append(req.body)
		return {"status": 200, "json": {}})
	_provider_route(mock, "apple", "apple-user", true)
	var s := mock_stack(mock)
	await s.auth.ensure_session()
	var anon_token: String = s.auth.session_token
	var res: Dictionary = await s.auth.link_provider("apple", "auth-code")
	check(res.ok, "linked")
	check_eq(assoc.size(), 1, "associate called once")
	check_eq(assoc[0].keep_user_token, anon_token, "keep = anon")
	check(assoc[0].discard_user_token != anon_token, "discard = provider")
	check_eq(s.auth.linked_providers(), PackedStringArray(["apple"]), "linked recorded")
	check_eq(mock.requests_to("/v1/auth/login/apple")[0].body.token, "auth-code", "code sent")


func test_link_existing_account_returns_account_exists() -> void:
	var mock := SnapKitMockGateway.new()
	mock.route(PUT, "/v1/auth/associate-logins", func(_r: Dictionary) -> Dictionary:
		return {"status": 200, "json": {}})
	_provider_route(mock, "apple", "existing-user", false)
	var s := mock_stack(mock)
	await s.auth.ensure_session()
	var res: Dictionary = await s.auth.link_provider("apple", "code")
	check(not res.ok, "not ok")
	check_eq(res.error, "account_exists", "error")
	check_eq(res.user_id, "existing-user", "other user id")
	check(str(res.switch_token) != "", "switch token")
	check_eq(mock.requests_to("/v1/auth/associate-logins").size(), 0, "never associates")
	# adopt it
	check(s.auth.adopt_session(res.switch_session), "adopted")
	check_eq(s.auth.user_id, "existing-user", "switched user")


func test_provider_login_is_never_retried() -> void:
	var mock := SnapKitMockGateway.new()
	var s := mock_stack(mock)
	await s.auth.ensure_session()
	mock.fail_next(1, "http_503")
	var res: Dictionary = await s.auth.link_provider("apple", "code")
	check_eq(res.error, "http_503", "error surfaced")
	check_eq(mock.requests_to("/v1/auth/login/apple").size(), 1, "single attempt")


func test_switched_session_never_falls_back_to_anon() -> void:
	var mock := SnapKitMockGateway.new()
	var s := mock_stack(mock)
	await s.auth.ensure_session()
	s.auth.adopt_session({"user_id": "other", "session_token": mock.issue_session("other")})
	mock.invalidate_sessions()
	check(not await s.auth.reauth(), "cannot heal silently")
	check_eq(mock.login_count, 1, "no anon login for a switched account")
	check_eq(s.auth.user_id, "other", "still the switched user")


func test_unsupported_provider() -> void:
	var s := mock_stack(SnapKitMockGateway.new())
	check_eq((await s.auth.link_provider("steam", "x")).error, "unsupported_provider", "rejected")
