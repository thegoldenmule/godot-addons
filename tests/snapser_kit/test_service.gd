extends "res://tests/snapser_kit/snapkit_test_case.gd"

## SnapKitService: offline guarantees, boot sequence, signals, identity bridges,
## automatic analytics events. (Client-backed results are covered by the
## clients' own tests.)

const PUT := HTTPClient.METHOD_PUT


## Records track() calls instead of queueing them.
class SpyService extends SnapKitService:
	var events: Array = []
	func track(event: String, props: Dictionary = {}) -> void:
		events.append([event, props])
	func names() -> Array:
		return events.map(func(e: Array) -> String: return e[0])


class FakeBridge extends RefCounted:
	var result: Dictionary
	var calls := 0
	func _init(r: Dictionary) -> void:
		result = r
	func get_identity_token() -> Dictionary:
		calls += 1
		await Engine.get_main_loop().process_frame
		return result


func _service(cfg: SnapKitConfig, mock: SnapKitMockGateway = null) -> SpyService:
	var svc := SpyService.new()
	add_node(svc)
	svc.start_with_config(cfg)
	svc.auth.session_path = temp_path("svc_session_%d.json" % randi())
	if mock != null:
		svc.use_mock_gateway(track_mock(mock))
		svc.transport.backoff_scale = 0.0
	return svc


func test_offline_everything_returns_offline() -> void:
	var svc := _service(SnapKitConfig.from_dict({"game_id": "g"}))
	var states := []
	svc.online_changed.connect(func(v: bool) -> void: states.append(v))
	await svc.boot_finished
	check_eq(states, [false], "online_changed(false) once")
	check(not svc.is_online(), "not online")
	check_eq(svc.user_id(), "", "no user id")
	var t0 := Time.get_ticks_msec()
	for res in [
		await svc.record_stat("a", 1), await svc.increment_stat("a"),
		await svc.submit_score("b", 1), await svc.top_scores("b"), await svc.scores_around_me("b"),
		await svc.cloud_save_push(), await svc.cloud_save_pull(),
		await svc.link_account("apple"), await svc.set_display_name("Bob"),
		await svc.switch_account({}), await svc.quests_fetch_active(),
	]:
		check_eq(res, SnapKitTransport.error_result("offline"), "offline result")
	check(Time.get_ticks_msec() - t0 < 100, "offline calls return immediately")
	check_eq(svc.remote_config(), {}, "empty remote config")
	check(svc.display_name() != "", "display name never empty")
	svc.track("anything", {"x": 1})   # must not throw


func test_not_started() -> void:
	var svc := SnapKitService.new()
	add_node(svc)
	check_eq((await svc.record_stat("a", 1)).error, "not_started", "not started")
	svc.track("x")   # no-op before start
	check_eq(svc.display_name(), "Player", "fallback name before start")


func test_start_is_idempotent_and_wires_children() -> void:
	var svc := _service(SnapKitConfig.from_dict({}))
	var t: SnapKitTransport = svc.transport
	svc.start_with_config(SnapKitConfig.from_dict({}))
	check(svc.transport == t, "second start ignored")
	for n in ["SnapKitTransport", "SnapKitAuth", "SnapKitAnalytics", "SnapKitCloudSave"]:
		check(svc.has_node(n), "child " + n)
	check(svc.quests_client == null, "quests off by default")
	await svc.boot_finished


func test_online_boot_emits_session_and_online() -> void:
	var mock := SnapKitMockGateway.new()
	var svc := _service(mock_config(), mock)
	var ready_ids := []
	var states := []
	svc.session_ready.connect(func(u: String) -> void: ready_ids.append(u))
	svc.online_changed.connect(func(v: bool) -> void: states.append(v))
	await svc.boot_finished
	check(svc.is_online(), "online")
	check(svc.user_id() != "", "user id")
	check_eq(ready_ids, [svc.user_id()], "session_ready once")
	check_eq(states, [true], "online_changed(true) once")
	check_eq(mock.login_count, 1, "one login")


func test_login_failure_boots_offline_state() -> void:
	var mock := SnapKitMockGateway.new()
	mock.respond(PUT, "/v1/auth/login/anon", 500, {})
	var svc := _service(mock_config(), mock)
	var states := []
	svc.online_changed.connect(func(v: bool) -> void: states.append(v))
	await svc.boot_finished
	check_eq(states, [false], "online_changed(false)")
	check(not svc.is_online(), "not online")


func test_automatic_analytics_events() -> void:
	var mock := SnapKitMockGateway.new()
	var svc := _service(mock_config(), mock)
	await svc.boot_finished
	check_eq(svc.names().slice(0, 2), ["session_start", "online_state"], "start + online_state")
	var start_props: Dictionary = svc.events[0][1]
	check(start_props.has("build_mode") and start_props.has("version") and start_props.has("platform"),
		"session_start props")
	check_eq(svc.events[1][1], {"online": 1, "reason": "login"}, "online_state props (0/1: Snapser has no bool type)")
	svc.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	svc.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	check_eq(svc.names().count("session_end"), 1, "session_end once")
	check(svc.events.back()[1].has("duration_s"), "duration prop")
	svc.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	check_eq(svc.names().count("session_start"), 2, "new session on resume")


func test_link_account_needs_bridge() -> void:
	var mock := SnapKitMockGateway.new()
	var svc := _service(mock_config(), mock)
	await svc.boot_finished
	check_eq((await svc.link_account("apple")).error, "no_provider", "no bridge")
	svc.register_identity_provider("apple", FakeBridge.new({"ok": false, "error": "cancelled"}))
	check_eq((await svc.link_account("apple")).error, "cancelled", "bridge error surfaced")
	svc.register_identity_provider("apple", null)
	check_eq((await svc.link_account("apple")).error, "no_provider", "unregistered")


func test_link_account_respects_config_providers() -> void:
	var mock := SnapKitMockGateway.new()
	var svc := _service(mock_config({"link_providers": ["apple"]}), mock)
	await svc.boot_finished
	svc.register_identity_provider("google", FakeBridge.new({"ok": true, "token": "t"}))
	check_eq((await svc.link_account("google")).error, "unsupported_provider", "not in config")


func test_link_then_switch_account() -> void:
	var mock := SnapKitMockGateway.new()
	mock.route(PUT, "/v1/auth/login/apple", func(_r: Dictionary) -> Dictionary:
		return {"status": 200, "json": {"user": {"id": "existing", "created": false,
			"session_token": mock.issue_session("existing"), "login_types": ["APPLE"]}}})
	var svc := _service(mock_config(), mock)
	await svc.boot_finished
	var bridge := FakeBridge.new({"ok": true, "token": "apple-auth-code"})
	svc.register_identity_provider("apple", bridge)
	var res: Dictionary = await svc.link_account("apple")
	check_eq(res.error, "account_exists", "account exists")
	check_eq(bridge.calls, 1, "bridge asked once")
	var ids := []
	svc.session_ready.connect(func(u: String) -> void: ids.append(u))
	var sw: Dictionary = await svc.switch_account(res)
	check(sw.ok, "switched")
	check_eq(svc.user_id(), "existing", "now the existing user")
	check_eq(ids, ["existing"], "session_ready for the switched user")


func test_quests_disabled_and_enabled() -> void:
	var mock := SnapKitMockGateway.new()
	var off := _service(mock_config(), mock)
	await off.boot_finished
	check_eq((await off.quests_claim("q")).error, "disabled", "disabled without config")
	var on := _service(mock_config({"quests": true}), SnapKitMockGateway.new())
	await on.boot_finished
	check(on.quests_client != null, "quests client built")


func test_save_store_duck_typing() -> void:
	check(not SnapKitService.is_valid_save_store(RefCounted.new()), "plain object rejected")
	check(not SnapKitService.is_valid_save_store(null), "null rejected")
	var store := GDScript.new()
	store.source_code = "extends RefCounted\nsignal changed(key)\nfunc export_prefix(p): return {}\nfunc import_prefix(p, d): pass\n"
	store.reload()
	check(SnapKitService.is_valid_save_store(store.new()), "SaveService-shaped object accepted")


func test_merge_default_delegates_to_cloud_save() -> void:
	var svc := SnapKitService.new()
	add_node(svc)
	check_eq(svc._merge({"a": 1}, {"a": 2}), {"a": 2}, "numbers take max (before start)")


func test_merge_scalar_follows_last_remote_is_newer() -> void:
	var svc := _service(SnapKitConfig.from_dict({}))
	await svc.boot_finished
	svc.cloud_save.last_remote_is_newer = false
	check_eq(svc._merge({"name": "local", "n": 1}, {"name": "remote", "n": 5}),
		{"name": "local", "n": 5}, "local newer: scalar keeps local, number takes max")
	svc.cloud_save.last_remote_is_newer = true
	check_eq(svc._merge({"name": "local"}, {"name": "remote"}), {"name": "remote"},
		"remote newer: scalar takes remote")


func test_leaderboards_share_profiles_client() -> void:
	var svc := _service(SnapKitConfig.from_dict({}))
	await svc.boot_finished
	check(svc.leaderboards_client.profiles == svc.profiles_client, "same profiles client")


func test_analytics_wire_format_end_to_end() -> void:
	var mock := SnapKitMockGateway.new()
	var bodies := []
	mock.route(HTTPClient.METHOD_PUT, "/v1/analytics/batch/user-events", func(req: Dictionary) -> Dictionary:
		bodies.append(req)
		return {"status": 200, "json": {"events_ingested": (req.body.data as Array).size(), "events_failed": 0}})
	var svc := SnapKitService.new()   # real track(), not the spy
	add_node(svc)
	svc.start_with_config(mock_config())
	svc.auth.session_path = temp_path("svc_wire_%d.json" % randi())
	svc.use_mock_gateway(track_mock(mock))
	await svc.boot_finished
	svc.track("run_end", {"mode": "story", "result": "win", "score": 120, "duration_s": 3.0, "flag": true})
	var res: Dictionary = await svc.analytics_client.flush()
	check(res.ok, "flush ok")
	check_eq(bodies.size(), 1, "one batch")
	var body: Dictionary = bodies[0].body
	check_eq(body.get("user_id"), svc.user_id(), "user_id in body = session user")
	var seen := {}
	for e in body.data:
		seen[e.event] = e.properties
		for k in e.properties:
			check(e.properties[k] is String, "%s.%s is a string" % [e.event, k])
	check_eq(seen.get("online_state", {}).get("online"), "1", "online flag as \"1\"")
	check_eq(seen.get("run_end", {}), {"mode": "story", "result": "win", "score": "120",
		"duration_s": "3", "flag": "1"}, "numbers/bools stringified")


# ---- v0.2 ---------------------------------------------------------------------

func test_wait_until_ready() -> void:
	var idle := SnapKitService.new()
	add_node(idle)
	check(not await idle.wait_until_ready(), "before start -> false at once")
	var svc := _service(mock_config(), SnapKitMockGateway.new())
	check(not svc.is_online(), "not online before boot")
	check(await svc.wait_until_ready(), "online after boot")
	check(await svc.wait_until_ready(), "already booted -> immediate")
	var off := _service(SnapKitConfig.from_dict({}))
	check(not await off.wait_until_ready(), "offline config -> false")


func test_force_offline_after_boot() -> void:
	var mock := SnapKitMockGateway.new()
	mock.respond(PUT, "/v1/statistics/user-stats/{u}/{k}", 200, {"value": "1"})
	var svc := _service(mock_config(), mock)
	await svc.boot_finished
	check(svc.is_online(), "online")
	var states := []
	svc.online_changed.connect(func(v: bool) -> void: states.append(v))
	var before := mock.requests.size()
	svc.force_offline("capture run")
	check_eq(states, [false], "online_changed(false)")
	check(not svc.is_online(), "offline now")
	check_eq((await svc.record_stat("hits", 1)).error, "offline", "calls return offline")
	check_eq(mock.requests.size(), before, "no request after force_offline")
	check_eq(svc.config.offline_reason, "capture run", "reason kept")


func test_force_offline_before_start() -> void:
	var svc := SpyService.new()
	add_node(svc)
	svc.force_offline("settings toggle")
	svc.start_with_config(mock_config())
	svc.auth.session_path = temp_path("svc_pre_off_%d.json" % randi())
	await svc.boot_finished
	check(svc.config.is_offline(), "config offline")
	check_eq(svc.config.offline_reason, "settings toggle", "reason")


func _declared_service(strict: bool, mock: SnapKitMockGateway) -> SnapKitService:
	var svc := SnapKitService.new()
	svc.strict_declarations = strict
	add_node(svc)
	svc.start_with_config(mock_config({"leaderboards": {"wins": "career_wins"},
		"declared": {"stats": ["hits"], "boards": ["career_wins"], "events": ["run_end"]}}))
	svc.auth.session_path = temp_path("svc_decl_%d.json" % randi())
	svc.use_mock_gateway(track_mock(mock))
	return svc


func test_undeclared_debug_build_never_sends() -> void:
	var mock := SnapKitMockGateway.new()
	var svc := _declared_service(true, mock)
	await svc.boot_finished
	var before := mock.requests.size()
	check_eq((await svc.record_stat("misses", 1)).error, SnapKitErrors.UNDECLARED, "stat")
	check_eq((await svc.increment_stat("misses")).error, SnapKitErrors.UNDECLARED, "increment")
	check_eq((await svc.submit_score("best", 5)).error, SnapKitErrors.UNDECLARED, "board")
	check_eq(mock.requests.size(), before, "no network call")
	var queued := svc.analytics_client.pending_count()
	svc.track("faction_selected", {"f": "x"})
	check_eq(svc.analytics_client.pending_count(), queued, "undeclared event dropped")
	svc.track("run_end", {"mode": "m"})
	check_eq(svc.analytics_client.pending_count(), queued + 1, "declared event queued")


func test_undeclared_is_checked_before_offline() -> void:
	var svc := SnapKitService.new()
	svc.strict_declarations = true
	add_node(svc)
	svc.start_with_config(SnapKitConfig.from_dict({"declared": {"stats": ["hits"]}}))
	await svc.boot_finished
	check_eq((await svc.record_stat("typo_stat", 1)).error, SnapKitErrors.UNDECLARED,
		"offline test runs still catch undeclared names")
	check_eq((await svc.record_stat("hits", 1)).error, "offline", "declared -> offline as usual")


func test_undeclared_release_build_still_sends() -> void:
	var mock := SnapKitMockGateway.new()
	mock.respond(PUT, "/v1/statistics/user-stats/{u}/{k}", 404, {"api_error_code": 4000})
	var svc := _declared_service(false, mock)
	await svc.boot_finished
	var r: Dictionary = await svc.record_stat("misses", 1)
	check_eq(mock.requests_to("/v1/statistics/").size(), 1, "sent once")
	check_eq(r.error, SnapKitErrors.UNDECLARED, "server 4000 maps to the same code")
	check_eq(r.snap_code, 4000, "snap_code")
	var queued := svc.analytics_client.pending_count()
	svc.track("faction_selected")
	check_eq(svc.analytics_client.pending_count(), queued + 1, "release: event still queued")


func test_cloud_save_applied_is_re_emitted() -> void:
	var svc := _service(SnapKitConfig.from_dict({}))
	await svc.boot_finished
	var got := []
	svc.cloud_save_applied.connect(func(keys: PackedStringArray) -> void: got.append(keys))
	svc.cloud_save.applied.emit(PackedStringArray(["p_a", "p_b"]))
	check_eq(got, [PackedStringArray(["p_a", "p_b"])], "re-emitted")
