extends SceneTree

## Live smoke test for one game's DEVELOPMENT snapend. Run it through
## run_smoke.sh, which passes --config=<abs path to the game's committed
## snapser_kit.config.json>:
##
##   godot --headless --path <godot-addons> --script res://tools/snapser/smoke/smoke.gd \
##       -- --config=/abs/path/game/snapser_kit.config.json [--board=<logical>] [--verbose]
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
	var svc := SnapKitService.new()
	root.add_child(svc)
	svc.start_with_config(cfg)
	svc.auth.session_path = "user://snapkit_smoke_%s.json" % cfg.game_id
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

	# --- clients (kit-clients agent) -----------------------------------------
	_check("remote_config.fetch", await svc.refresh_remote_config(),
		func(r: Dictionary) -> String: return "%d top-level keys" % (r.get("config", {}) as Dictionary).size())
	var runs_key := "smoke_runs"
	_check("stats.increment", await svc.increment_stat(runs_key, 1),
		func(r: Dictionary) -> String: return "%s = %s" % [runs_key, r.get("value")])
	_check("stats.set", await svc.record_stat("smoke_last_unix", int(Time.get_unix_time_from_system())),
		func(_r: Dictionary) -> String: return "smoke_last_unix set")

	var board := str(args.get("board", ""))
	if board == "" and not cfg.leaderboards.is_empty():
		board = str(cfg.leaderboards.keys()[0])
	if board == "":
		_record("leaderboards.*", "SKIP", "no board in config (pass --board=)")
	else:
		_check("leaderboards.submit", await svc.submit_score(board, randi_range(1, 1000)),
			func(_r: Dictionary) -> String: return "board %s -> %s" % [board, cfg.leaderboard_id(board)])
		_check("leaderboards.top", await svc.top_scores(board, 5),
			func(r: Dictionary) -> String: return "%d entries" % (r.get("entries", []) as Array).size())
		_check("leaderboards.around_me", await svc.scores_around_me(board, 2),
			func(r: Dictionary) -> String: return "%d entries" % (r.get("entries", []) as Array).size())

	_check("profiles.set_display_name", await svc.set_display_name("Smoke Tester"),
		func(r: Dictionary) -> String: return "stored '%s'" % r.get("display_name", ""))
	_check("profiles.fetch", await svc.refresh_profile(),
		func(_r: Dictionary) -> String: return "display_name() = '%s'" % svc.display_name())

	var blob := cfg.cloud_save_blob_key()
	_check("storage.put_json_blob", await svc.storage_client.put_json_blob(blob,
		{"version": 1, "updated_at": int(Time.get_unix_time_from_system()), "device_id": "smoke", "data": {}}),
		func(_r: Dictionary) -> String: return "blob %s" % blob)
	_check("storage.get_json_blob", await svc.storage_client.get_json_blob(blob),
		func(r: Dictionary) -> String: return "exists=%s" % r.get("exists"))

	svc.track("screen_view", {"screen": "smoke"})
	_check("analytics.flush", await svc.analytics_client.flush(),
		func(r: Dictionary) -> String: return "sent %s" % r.get("sent"))

	svc.queue_free()
	_finish()


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
