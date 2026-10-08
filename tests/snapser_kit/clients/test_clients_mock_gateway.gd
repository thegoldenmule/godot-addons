extends "res://tests/snapser_kit/snapkit_test_case.gd"

## Contract tests: every client through the REAL SnapKitTransport + SnapKitAuth
## against SnapKitMockGateway — session headers and "{user_id}" expansion,
## 401 -> reauth -> replay, timeout retry on idempotent calls (and none on
## POST), int64-as-string bodies, offline short-circuit.

const FakeStorageServer := preload("res://tests/snapser_kit/clients/fake_storage_server.gd")
const FakeSaveStore := preload("res://tests/snapser_kit/clients/fake_save_store.gd")

var mock: SnapKitMockGateway
var transport: SnapKitTransport
var auth: SnapKitAuth


func before_each() -> void:
	mock = SnapKitMockGateway.new()
	var s := mock_stack(mock)
	transport = s.transport
	auth = s.auth
	SnapKitProfiles.clear_name_cache()


func test_stats_session_and_401_replay() -> void:
	var stats := SnapKitStats.new(transport)
	mock.route(HTTPClient.METHOD_PATCH, "/v1/statistics/user-stats/{uid}/{key}", func(req: Dictionary) -> Dictionary:
		return {"status": 200, "text": '{"key":"%s","user_id":"%s","value":"9007199254740993"}' % [req.params.key, req.params.uid]})
	var r: Dictionary = await stats.increment_stat("games", 1)
	check(r.ok, "ok: " + str(r.error))
	check_eq(r.value, 9007199254740993, "int64 string value")
	var req: Dictionary = mock.requests_to("/v1/statistics/")[0]
	check(auth.user_id != "" and req.path.ends_with("/%s/games" % auth.user_id), "placeholder expanded with session user")
	check_eq(req.user_id, auth.user_id, "session headers sent")
	mock.invalidate_sessions()
	r = await stats.increment_stat("games", 1)
	check(r.ok, "401 healed by reauth + replay")
	check_eq(mock.login_count, 2, "re-logged in once")


func test_leaderboards_and_profile_names() -> void:
	var lb := SnapKitLeaderboards.new(transport)
	mock.respond(HTTPClient.METHOD_GET, "/v1/leaderboards/leaderboards/{board}", 200,
		{"user_scores": [{"user_id": "other", "score": 10.0, "rank": "1", "user_metadata": {"name": "SPOOF"}}]})
	mock.route(HTTPClient.METHOD_GET, "/v1/profiles/batch/profiles", func(req: Dictionary) -> Dictionary:
		return {"status": 200, "json": {"profiles": {"other": {"display_name": "Real Name"}}}})
	mock.fail_next(1, "timeout")
	var r: Dictionary = await lb.get_top("weekly", 5)
	check(r.ok, "GET retried after a timeout: " + str(r.error))
	check_eq(r.entries[0].display_name, "Real Name", "name from Profiles")
	check_eq(r.entries[0].rank, 1, "rank")
	var q: Dictionary = mock.requests_to("/v1/leaderboards/")[-1].query
	check_eq(q.get("range"), "top", "range")
	mock.respond(HTTPClient.METHOD_PUT, "/v1/leaderboards/leaderboards/{board}/users/{uid}/score", 200, {"rank": 3})
	r = await lb.submit_score("weekly", 10)
	check(r.ok and r.rank == 3, "submit")
	check(not (mock.requests_to("/v1/leaderboards/")[-1].body as Dictionary).has("user_metadata"), "no metadata sent")


func test_quests_post_not_retried() -> void:
	var quests := SnapKitQuests.new(transport)
	mock.respond(HTTPClient.METHOD_POST, "/v1/quests/users/{uid}/quests/{q}/claim_rewards", 200,
		{"currencies_granted_64": {"coins": "5"}})
	await auth.ensure_session()
	mock.fail_next(1, "timeout")
	var r: Dictionary = await quests.claim("daily")
	check_eq(r.error, SnapKitTransport.ERR_TIMEOUT, "POST claim is not retried (no double grant)")
	r = await quests.claim("daily")
	check(r.ok, "second attempt ok")
	check_eq(r.reward, {"coins": 5}, "reward")


func test_profiles_name_taken_and_remote_config() -> void:
	var profiles := SnapKitProfiles.new(transport)
	mock.respond(HTTPClient.METHOD_PATCH, "/v1/profiles/user/{uid}", 409, {"error_code": 14012})
	var r: Dictionary = await profiles.set_display_name("Taken")
	check_eq(r.error, SnapKitProfiles.ERR_NAME_TAKEN, "name_taken")
	var rc := SnapKitRemoteConfig.new(transport)
	mock.respond(HTTPClient.METHOD_GET, "/v1/remote-config/app-config/{v}", 200, {"config": {"k": {"a": 1}}})
	r = await rc.fetch_app_config()
	check(r.ok, "rc ok")
	check_eq(SnapKitRemoteConfig.extract_block(r.config, "k"), {"a": 1.0}, "block")


func test_analytics_flush_after_login() -> void:
	var an: SnapKitAnalytics = add_node(SnapKitAnalytics.new())
	an.setup(transport, {"batch_size": 10, "flush_interval_s": 0.0})
	var bodies: Array = []
	mock.route(HTTPClient.METHOD_PUT, "/v1/analytics/batch/user-events", func(req: Dictionary) -> Dictionary:
		bodies.append(req.body)
		return {"status": 200, "json": {"events_ingested": req.body.data.size()}})
	an.track("run_end", {"won": true, "score": 3})
	var r: Dictionary = await an.flush()
	check_eq(r.error, SnapKitTransport.ERR_NO_SESSION, "no session before login: kept")
	await auth.ensure_session()
	r = await an.flush()
	check(r.ok and r.sent == 1, "sent after login")
	check_eq(bodies[0].user_id, auth.user_id, "user id in body")
	check_eq(bodies[0].data[0].properties, {"won": "1", "score": "3"}, "props as strings, bool as 1")


func test_cloud_save_through_real_transport() -> void:
	var server := FakeStorageServer.new()
	server.install(mock)
	var store := FakeSaveStore.new()
	store.set_value("prog_level", 4)
	var cfg := mock_config({"cloud_save": {"blob_key": "save_v1", "sync_prefixes": ["prog_"]}})
	var cs: SnapKitCloudSave = add_node(SnapKitCloudSave.new())
	cs.state_path = temp_path("cloud_save_state.json")
	cs.setup(SnapKitStorage.new(transport), store, cfg)
	check(cs.is_enabled(), "enabled from the real config")
	var r: Dictionary = await cs.pull()
	check(r.ok, "first sync: " + str(r.error))
	check_eq(r.applied, SnapKitCloudSave.APPLIED_LOCAL, "uploaded")
	var env := SnapKitCloudSave.parse_envelope(server.value_of(auth.user_id, "save_v1"))
	check_eq(typeof(env.data.prog_level), TYPE_INT, "int survives the real transport")
	mock.invalidate_sessions()
	store.set_value("prog_level", 5)
	r = await cs.push()
	check(r.ok, "push after session loss (401 replay)")
	check_eq(SnapKitCloudSave.parse_envelope(server.value_of(auth.user_id, "save_v1")).data.prog_level, 5, "pushed")


func test_offline_short_circuit() -> void:
	var off := SnapKitTransport.new()
	add_node(off)
	off.setup(SnapKitConfig.from_dict({"game_id": "t", "gateway_url": ""}), null)
	var r: Dictionary = await SnapKitStats.new(off).set_stat("wins", 1)
	check_eq(r.error, SnapKitTransport.ERR_OFFLINE, "stats offline")
	r = await SnapKitLeaderboards.new(off).get_top("b")
	check_eq(r.error, SnapKitTransport.ERR_OFFLINE, "leaderboards offline")
	r = await SnapKitStorage.new(off).get_json_blob("k")
	check_eq(r.error, SnapKitTransport.ERR_OFFLINE, "storage offline")
	r = await SnapKitProfiles.new(off).fetch_profile()
	check_eq(r.error, SnapKitTransport.ERR_OFFLINE, "profiles offline")
	var an: SnapKitAnalytics = add_node(SnapKitAnalytics.new())
	an.setup(off, {"flush_interval_s": 0.0})
	an.track("x")
	r = await an.flush()
	check_eq(r.error, SnapKitTransport.ERR_OFFLINE, "analytics offline")
	check_eq(mock.requests.size(), 0, "nothing reached the gateway")
