extends SceneTree

## Live smoke test for one game's DEVELOPMENT snapend. Run it through
## run_smoke.sh, which passes --config=<abs path to the game's committed
## snapser_kit.config.json>:
##
##   godot --headless --path <godot-addons> --script res://tools/snapser/smoke/smoke.gd \
##       -- --config=/abs/path/game/snapser_kit.config.json [--stat=<declared key>]
##          [--board=<logical>] [--verbose]
##
## Safety:
##   - The gateway is taken ONLY from that config file (SnapKitConfig.from_dict,
##     which ignores SNAPSER_GATEWAY_URL and the debug override). If
##     SNAPSER_GATEWAY_URL is set to anything else, the run refuses.
##   - It refuses non-https gateways and configs without game_id.
##   - It uses its own persisted smoke user per game
##     (user://snapkit_smoke_<game_id>.json in the godot-addons project), so
##     repeated runs do not mint new anonymous users. No API key is involved.
##
## Steps (each PASS / FAIL / SKIP). SKIP = the client returned
## "not_implemented" (kit-clients not merged yet) or the config lacks what the
## step needs. Exit code: 0 if no step FAILed, 1 otherwise, 2 on refusal/timeout.

const WATCHDOG_S := 180.0

var _results: Array = []   # [name, status, detail]
var _verbose := false


func _initialize() -> void:
	create_timer(WATCHDOG_S).timeout.connect(func() -> void:
		print("SMOKE: watchdog timeout after %ds" % int(WATCHDOG_S))
		quit(2))
	_run.call_deferred()


func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			args[a.substr(2, a.find("=") - 2)] = a.substr(a.find("=") + 1)
		elif a.begins_with("--"):
			args[a.substr(2)] = true
	_verbose = args.has("verbose")

	var path := str(args.get("config", ""))
	if path == "" or not FileAccess.file_exists(path):
		_refuse("--config=<abs path to snapser_kit.config.json> is required (got '%s')" % path)
		return
	var raw: Variant = SnapKitJson.parse(FileAccess.get_file_as_string(path))
	if not (raw is Dictionary):
		_refuse("%s is not a JSON object" % path)
		return
	var cfg := SnapKitConfig.from_dict(raw)
	if cfg.game_id == "":
		_refuse("config has no game_id")
		return
	if not cfg.is_ready() or not cfg.gateway_url.begins_with("https://"):
		_refuse("config gateway is not a usable https URL (%s)" % cfg.describe())
		return
	var env_url := OS.get_environment("SNAPSER_GATEWAY_URL").strip_edges().rstrip("/")
	if env_url != "" and env_url != cfg.gateway_url:
		_refuse("SNAPSER_GATEWAY_URL points elsewhere than the game's config — refusing")
		return

	print("SMOKE: game=%s gateway=%s" % [cfg.game_id, cfg.gateway_url])
	var store := SmokeStore.new()
	var prefixes := cfg.cloud_save_prefixes()
	var prefix := prefixes[0] if not prefixes.is_empty() else ""
	if prefix != "":
		store.set_value(prefix + "smoke_local", 1)
	var svc := SnapKitService.new()
	svc.save_store = store
	root.add_child(svc)
	svc.start_with_config(cfg)
	svc.auth.session_path = "user://snapkit_smoke_%s.json" % cfg.game_id
	# Fresh cloud-save bookkeeping each run: the first sync merges the in-memory
	# store with whatever earlier runs left in the blob.
	svc.cloud_save.state_path = "user://snapkit_smoke_%s_cloud_%d.json" % [cfg.game_id, randi()]
	await svc.boot_finished

	# --- core ------------------------------------------------------------------
	var uid := svc.user_id()
	_record("auth.anon_login", "PASS" if svc.is_online() and uid != "" else "FAIL",
		"user %s, handle %s" % [uid, svc.auth.username()])
	if not svc.is_online():
		_finish()
		return
	var refreshed: bool = await svc.auth.refresh_session()
	_record("auth.refresh", "PASS" if refreshed and svc.user_id() == uid else "FAIL",
		"PATCH /v1/auth/refresh")
	var re_ok: bool = await svc.auth.reauth()
	_record("auth.reauth_same_user", "PASS" if re_ok and svc.user_id() == uid else "FAIL",
		"re-login with persisted handle keeps user %s" % uid)

	# --- clients ------------------------------------------------------------
	_check("remote_config.fetch", await svc.refresh_remote_config(),
		func(r: Dictionary) -> String: return "keys %s" % str((r.get("config", {}) as Dictionary).keys()))
	if svc.quests_client != null:
		_check("quests.fetch_active", await svc.quests_fetch_active(),
			func(r: Dictionary) -> String: return "%d active quests" % (r.get("quests", []) as Array).size())

	# Stats: keys must be declared on the snapend (undeclared -> 404), so the key
	# comes from --stat=<declared key>.
	var stat := str(args.get("stat", ""))
	if stat == "":
		_record("stats.*", "SKIP", "pass --stat=<a stat key declared on the snapend>")
	else:
		var inc := await svc.increment_stat(stat, 1)
		_check("stats.increment", inc,
			func(r: Dictionary) -> String: return "%s = %s" % [stat, r.get("value")])
		var base := SnapKitJson.to_int(inc.get("value"), 1)
		_check("stats.set", await svc.record_stat(stat, base + 1),
			func(r: Dictionary) -> String: return "%s = %s" % [stat, r.get("value", base + 1)])

	# Display name first, so the board read below can show it.
	# Random suffix: repeat runs must not trip a unique-name constraint.
	var smoke_name := "Smoke Tester %s" % Crypto.new().generate_random_bytes(2).hex_encode()
	var set_res := await svc.set_display_name(smoke_name)
	_check("profiles.set_display_name", set_res,
		func(r: Dictionary) -> String: return "stored '%s'" % r.get("display_name", ""))
	# The kit clamps names (SnapKitProfiles.NAME_MAX_LEN), so compare boards
	# against what was actually stored.
	if set_res.get("ok", false):
		smoke_name = str(set_res.get("display_name", smoke_name))
	_check("profiles.fetch", await svc.refresh_profile(),
		func(_r: Dictionary) -> String: return "display_name() = '%s'" % svc.display_name())

	var board := str(args.get("board", ""))
	if board == "" and not cfg.leaderboards.is_empty():
		board = str(cfg.leaderboards.keys()[0])
	if board == "":
		_record("leaderboards.*", "SKIP", "no board in config (pass --board=)")
	else:
		_check("leaderboards.submit", await svc.submit_score(board, randi_range(1, 1000)),
			func(_r: Dictionary) -> String: return "board %s -> %s" % [board, cfg.leaderboard_id(board)])
		_check("leaderboards.top", await svc.top_scores(board, 5),
			func(r: Dictionary) -> String: return _describe_entries(r))
		var around := await svc.scores_around_me(board, 2)
		var me_name := ""
		for e in around.get("entries", []):
			if e.get("is_me", false):
				me_name = str(e.get("display_name", ""))
		if around.get("ok", false) and me_name != smoke_name:
			_record("leaderboards.around_me_name", "FAIL", "my entry shows '%s', expected '%s'" % [me_name, smoke_name])
		else:
			_check("leaderboards.around_me_name", around,
				func(r: Dictionary) -> String: return _describe_entries(r))

	# Cloud save: push, simulated second-device write (CAS changes), push again
	# -> CAS conflict resolved by merge, then a clean pull.
	if prefix == "":
		_record("cloud_save.*", "SKIP", "config has no cloud_save.sync_prefixes")
	else:
		store.set_value(prefix + "smoke_counter", randi_range(1, 1000))
		_check("cloud_save.push", await svc.cloud_save_push(),
			func(r: Dictionary) -> String: return "conflict=%s" % r.get("conflict"))
		var blob := svc.cloud_save.blob_key()
		var got := await svc.storage_client.get_json_blob(blob)
		var other_ok := false
		if got.get("ok", false) and got.get("value") is Dictionary:
			var env: Dictionary = (got.value as Dictionary).duplicate(true)
			var data: Dictionary = env.get("data", {})
			data.merge(SnapKitCloudSave.encode_data({prefix + "smoke_other_device": 7}), true)
			env["data"] = data
			env["version"] = SnapKitJson.to_int(env.get("version"), 0) + 1
			env["device_id"] = "smoke-other-device"
			var w := await svc.storage_client.put_json_blob_cas(blob, env, str(got.get("cas", "")))
			other_ok = w.get("ok", false)
			_check("cloud_save.other_device_write", w,
				func(_r: Dictionary) -> String: return "server CAS advanced")
		else:
			_check("cloud_save.other_device_write", got, func(_r: Dictionary) -> String: return "")
		if other_ok:
			store.set_value(prefix + "smoke_counter", randi_range(1001, 2000))
			var p2 := await svc.cloud_save_push()
			if p2.get("ok", false) and not p2.get("conflict", false):
				_record("cloud_save.cas_conflict", "FAIL", "stale CAS was not detected")
			else:
				_check("cloud_save.cas_conflict", p2,
					func(r: Dictionary) -> String: return "conflict detected, merged + pushed (applied=%s)" % r.get("applied", "?"))
			var merged_in := store.data.has(prefix + "smoke_other_device")
			_record("cloud_save.merge_kept_other_device", "PASS" if merged_in else "FAIL",
				"other device's key %s locally" % ("present" if merged_in else "MISSING"))
		_check("cloud_save.pull", await svc.cloud_save_pull(),
			func(r: Dictionary) -> String: return "applied=%s" % r.get("applied"))

	svc.track("screen_view", {"screen": "smoke"})
	_check("analytics.flush", await svc.analytics_client.flush(),
		func(r: Dictionary) -> String: return "sent %s, failed %s" % [r.get("sent"), r.get("failed")])

	svc.queue_free()
	_finish()


func _describe_entries(r: Dictionary) -> String:
	var parts := PackedStringArray()
	for e in r.get("entries", []):
		parts.append("#%s %s=%s%s" % [e.get("rank"), e.get("display_name", ""), e.get("score"),
			" (me)" if e.get("is_me", false) else ""])
	return "%d entries: %s" % [parts.size(), ", ".join(parts)]


## In-memory SaveService-shaped store (amendment 6 duck type).
class SmokeStore extends RefCounted:
	signal changed(key: String)
	var data := {}
	func keys_with_prefix(prefix: String) -> PackedStringArray:
		return PackedStringArray(data.keys().filter(func(k: String) -> bool: return k.begins_with(prefix)))
	func export_prefix(prefix: String) -> Dictionary:
		var out := {}
		for k in data:
			if str(k).begins_with(prefix):
				out[k] = data[k]
		return out
	func import_prefix(_prefix: String, incoming: Dictionary) -> void:
		for k in incoming:
			data[k] = incoming[k]
			changed.emit(k)
	func set_value(key: String, value: Variant) -> void:
		data[key] = value
		changed.emit(key)


func _check(step: String, res: Dictionary, detail: Callable) -> void:
	if res.get("ok", false):
		_record(step, "PASS", detail.call(res))
	elif res.get("error", "") == SnapKitTransport.ERR_NOT_IMPLEMENTED:
		_record(step, "SKIP", "client not implemented in this kit build")
	else:
		var body := JSON.stringify(res.get("json")) if _verbose else ""
		_record(step, "FAIL", "%s %s" % [res.get("error", "?"), body])


func _record(step: String, status: String, detail: String) -> void:
	_results.append([step, status, detail])
	print("  %-4s %-28s %s" % [status, step, detail])


func _refuse(msg: String) -> void:
	print("SMOKE REFUSED: " + msg)
	quit(2)


func _finish() -> void:
	var counts := {"PASS": 0, "FAIL": 0, "SKIP": 0}
	for r in _results:
		counts[r[1]] += 1
	print("SMOKE: %d passed, %d failed, %d skipped" % [counts.PASS, counts.FAIL, counts.SKIP])
	quit(0 if counts.FAIL == 0 else 1)
