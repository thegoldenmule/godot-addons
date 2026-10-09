class_name SnapKitService
extends Node

## Base class for a game's "Snapser" autoload — the unified game-facing API.
##
##   # game/scripts/snapser.gd   (autoload name: Snapser)
##   extends SnapKitService
##   func _ready() -> void:
##       start()
##
## The game subclass adds only game-specific mapping (achievement catalog ->
## stats, match result -> boards). Game code calls Snapser.*, never a client.
##
## ---------------------------------------------------------------------------
## GUARANTEES
## ---------------------------------------------------------------------------
## - Every network method is a COROUTINE returning a Dictionary with at least
##   {ok: bool, error: String} (usually the full transport shape
##   {ok, status, json, error} plus parsed fields). Call with `await`.
## - Never throws. Offline (no gateway, SNAPSER_OFFLINE=1, --snapser-offline)
##   every call returns {ok:false, error:"offline"} immediately, so gameplay code
##   never branches on connectivity.
## - track() never blocks and never fails.
## - The API key is never read or sent.
##
## ---------------------------------------------------------------------------
## WIRING (how the service reaches each piece)
## ---------------------------------------------------------------------------
## start_with_config() builds, in order:
##   transport  = SnapKitTransport (child node)           core/snapkit_transport.gd
##   auth       = SnapKitAuth (child node)                core/snapkit_auth.gd
##   transport.setup(config, auth); auth.setup(config, transport)
##   stats_client         = SnapKitStats.new(transport)         clients/snapkit_stats.gd
##   leaderboards_client  = SnapKitLeaderboards.new(transport, profiles_client)
##                                                              clients/snapkit_leaderboards.gd
##   storage_client       = SnapKitStorage.new(transport)       clients/snapkit_storage.gd
##   remote_config_client = SnapKitRemoteConfig.new(transport)  clients/snapkit_remote_config.gd
##   profiles_client      = SnapKitProfiles.new(transport)      clients/snapkit_profiles.gd
##   quests_client        = SnapKitQuests.new(transport) — only if config.quests_enabled()
##   analytics_client     = SnapKitAnalytics (child node); .setup(transport)
##   cloud_save           = SnapKitCloudSave (child node);
##                          .setup(storage_client, save_store, config);
##                          .merge_func = _merge
## The scripts are reached through the preload constants below (not global class
## lookups), so the kit works before the editor has rebuilt its class cache.
## All members are public so a game subclass can reach a client directly for
## anything the facade does not cover.
##
## ---------------------------------------------------------------------------
## ---------------------------------------------------------------------------
## STARTUP (deferred so a slow gateway never delays the first frame)
## ---------------------------------------------------------------------------
## start*() immediately tracks `session_start`, then defers _boot():
## offline -> online_changed(false) (+ `online_state` event) and stop.
## online  -> auth.ensure_session() (+ refresh_session() on a warm launch)
##         -> session_ready(user_id), online_changed(true)
##         -> remote config fetch (cached; config_updated(config))
##         -> profile fetch (caches the display name)
##         -> cloud_save.pull() when enabled (may emit cloud_save_conflict)
## Await `boot_finished` to know the sequence is done (tests, loading screens).
##
## ---------------------------------------------------------------------------
## AUTOMATIC ANALYTICS (D19 amendment 7)
## ---------------------------------------------------------------------------
## The kit tracks `session_start` {build_mode, version, platform} on start and on
## resume, `session_end` {duration_s} on pause / close request (best effort;
## tracked BEFORE the analytics child receives the same notification and
## flushes), and `online_state` {online, reason} on every connectivity change.
## Override _session_start_props() to supply the game's build mode / version.
## Games track run_start, run_end, screen_view and their own events.
##
## ---------------------------------------------------------------------------
## IDENTITY BRIDGES (D21 / amendment 2)
## ---------------------------------------------------------------------------
## Platform addons register a bridge per provider:
##   Snapser.register_identity_provider("apple", AppleBridge.new())
## Bridge interface (duck-typed):
##   func get_identity_token() -> Dictionary   # async; {ok, token, error}
##     token is exactly what Snapser's /v1/auth/login/<provider> expects:
##       apple:  the AUTHORIZATION CODE (not the identity token / JWT). It is
##               single-use and expires in ~5 minutes, so the kit sends it with
##               no_retry. The bridge may add "identity_token" for debugging.
##       google: the Google ID token (JWT, aud = the Web client id).
## link_account(provider) awaits it, then SnapKitAuth.link_provider(). If the
## platform account already has its own Snapser user, link_account returns
## {ok:false, error:"account_exists", user_id, switch_token, switch_session};
## the game asks the player and calls switch_account(result) to adopt it.
## Connectivity changed: true once a session is held; false when offline or the
## session is lost.
signal online_changed(online: bool)
## A session is live for this user id (after startup login or a re-login).
signal session_ready(user_id: String)
## Local and remote saves both changed since the last sync. Informational — the
## kit then resolves with _merge() (override it to customize) and pushes.
signal cloud_save_conflict(local: Dictionary, remote: Dictionary)
## Remote config was fetched/refreshed.
signal config_updated(config: Dictionary)
## A cloud-save pull / merge wrote remote data into the local save store. keys
## = synced keys added, changed or removed. Refresh caches and registries here
## instead of watching the store's `changed` signal.
signal cloud_save_applied(keys: PackedStringArray)

const ConfigScript := preload("res://addons/snapser_kit/core/snapkit_config.gd")
const AuthScript := preload("res://addons/snapser_kit/core/snapkit_auth.gd")
const TransportScript := preload("res://addons/snapser_kit/core/snapkit_transport.gd")
const StatsScript := preload("res://addons/snapser_kit/clients/snapkit_stats.gd")
const LeaderboardsScript := preload("res://addons/snapser_kit/clients/snapkit_leaderboards.gd")
const StorageScript := preload("res://addons/snapser_kit/clients/snapkit_storage.gd")
const RemoteConfigScript := preload("res://addons/snapser_kit/clients/snapkit_remote_config.gd")
const QuestsScript := preload("res://addons/snapser_kit/clients/snapkit_quests.gd")
const ProfilesScript := preload("res://addons/snapser_kit/clients/snapkit_profiles.gd")
const AnalyticsScript := preload("res://addons/snapser_kit/clients/snapkit_analytics.gd")
const CloudSaveScript := preload("res://addons/snapser_kit/service/snapkit_cloud_save.gd")

## Name of the autoload the kit looks for when save_store is unset.
const DEFAULT_SAVE_STORE_PATH := "/root/SaveService"

## Resolved kit config (SnapKitConfig — not to be confused with remote_config()).
var config: SnapKitConfig
var transport: SnapKitTransport
var auth: SnapKitAuth
var stats_client: SnapKitStats
var leaderboards_client: SnapKitLeaderboards
var storage_client: SnapKitStorage
var remote_config_client: SnapKitRemoteConfig
var quests_client: SnapKitQuests            # null unless config.quests_enabled()
var profiles_client: SnapKitProfiles
var analytics_client: SnapKitAnalytics
var cloud_save: SnapKitCloudSave

## SaveService-style local store for cloud save (see SnapKitCloudSave). Set it
## before start(); if null, start() uses DEFAULT_SAVE_STORE_PATH when present.
var save_store: Object


## start*() finished its deferred startup sequence (online or not).
signal boot_finished

## Errors specific to the service (transport ERR_* codes are reused otherwise).
const ERR_NOT_STARTED := "not_started"
const ERR_NO_PROVIDER := "no_provider"
## A stat / board / event / blob that the config's "declared" section does not
## list (same code the server's 404s map to).
const ERR_UNDECLARED := SnapKitErrors.UNDECLARED

## Debug builds: an undeclared name returns {ok:false, error:"undeclared"} (or
## drops the event) without a network call. Release builds: warn once, send
## anyway. Tests may flip it.
var strict_declarations: bool = OS.is_debug_build()

var _remote_config: Dictionary = {}
var _display_name: String = ""
var _started: bool = false
var _booted: bool = false
var _online: bool = false
var _online_reported: bool = false
var _identity_bridges: Dictionary = {}
var _session_started_ms: int = 0
var _session_open: bool = false
var _warned_undeclared: Dictionary = {}
var _pending_offline_reason: String = ""


# ---- Lifecycle ---------------------------------------------------------------

## Resolve SnapKitConfig.from_project() and start. Call once, from the autoload's
## _ready(). Idempotent: later calls are ignored.
func start() -> void:
	if _started:
		return
	start_with_config(ConfigScript.from_project())


## Start with an explicit config (tests, tools). Builds the wiring described in
## the class doc and schedules the deferred startup sequence. Idempotent.
func start_with_config(cfg: SnapKitConfig) -> void:
	if _started:
		return
	_started = true
	config = cfg
	if _pending_offline_reason != "":
		config.force_offline(_pending_offline_reason)
	if config.has_declarations("blobs") and config.cloud_save_enabled() \
			and not config.is_declared("blobs", config.cloud_save_blob_key()):
		_warn_undeclared("blobs", config.cloud_save_blob_key())

	transport = TransportScript.new()
	transport.name = "SnapKitTransport"
	add_child(transport)
	auth = AuthScript.new()
	auth.name = "SnapKitAuth"
	add_child(auth)
	transport.setup(config, auth)
	auth.setup(config, transport)
	auth.session_changed.connect(_on_session_changed)

	stats_client = StatsScript.new(transport)
	storage_client = StorageScript.new(transport)
	remote_config_client = RemoteConfigScript.new(transport)
	profiles_client = ProfilesScript.new(transport)
	# Shares the profiles client so leaderboard entries resolve display names.
	leaderboards_client = LeaderboardsScript.new(transport, profiles_client)
	if config.quests_enabled():
		quests_client = QuestsScript.new(transport)

	analytics_client = AnalyticsScript.new()
	analytics_client.name = "SnapKitAnalytics"
	add_child(analytics_client)
	var a_opts: Variant = config.raw.get("analytics", {})
	analytics_client.setup(transport, a_opts if a_opts is Dictionary else {})

	if save_store == null and is_inside_tree():
		save_store = get_node_or_null(DEFAULT_SAVE_STORE_PATH)
	if save_store != null and not is_valid_save_store(save_store):
		push_warning("[SnapKit] save_store lacks export_prefix/import_prefix; cloud save disabled")
		save_store = null
	cloud_save = CloudSaveScript.new()
	cloud_save.name = "SnapKitCloudSave"
	add_child(cloud_save)
	cloud_save.setup(storage_client, save_store, config)
	cloud_save.merge_func = _merge
	cloud_save.conflict.connect(func(l: Dictionary, r: Dictionary) -> void:
		cloud_save_conflict.emit(l, r))
	cloud_save.applied.connect(func(keys: PackedStringArray) -> void:
		cloud_save_applied.emit(keys))

	_open_analytics_session()
	_boot.call_deferred()


## Route all traffic to an in-process fake gateway (tests). Call right after
## start*() — the deferred boot has not run yet at that point.
func use_mock_gateway(mock: SnapKitMockGateway) -> void:
	if transport != null:
		transport.use_mock_gateway(mock)


## True once the deferred startup sequence has completed.
func is_booted() -> bool:
	return _booted


## Wait for the startup sequence, then return is_online(). Resolves at once when
## already booted; returns false at once before start(). COROUTINE:
##   if await Snapser.wait_until_ready(): ...
## Use it in screens that read online state in _ready(): is_online() is false
## until boot has logged in.
func wait_until_ready() -> bool:
	if not _started:
		return false
	if not _booted:
		await boot_finished
	return is_online()


## Force offline for the rest of the process (capture runs, a settings toggle,
## tests). Before start() it applies to the config start() resolves; after,
## every call returns {ok:false, error:"offline"} immediately and
## online_changed(false) fires if the kit was online. There is no way back
## online short of restarting the service: re-resolve and start a new one.
func force_offline(reason: String = "forced offline") -> void:
	if config == null:
		_pending_offline_reason = reason if reason != "" else "forced offline"
		return
	config.force_offline(reason)
	if _online or not _online_reported:
		_set_online(false, config.offline_reason)


func _boot() -> void:
	if config.is_offline():
		_set_online(false, config.offline_reason)
		_finish_boot()
		return
	var cached := auth.has_session()
	var ok: bool = await auth.ensure_session()
	if ok and cached:
		# Warm launch: extend the cached session (best effort, per Snapser docs).
		await auth.refresh_session()
	if not ok:
		_set_online(false, "login_failed")
		_finish_boot()
		return
	if not _online:
		# Cached session: no login happened, so session_changed did not fire.
		session_ready.emit(auth.user_id)
		_set_online(true, "session")
	await refresh_remote_config()
	await refresh_profile()
	if cloud_save.is_enabled() and (not strict_declarations
			or config.is_declared("blobs", config.cloud_save_blob_key())):
		await cloud_save.pull()
	_finish_boot()


func _finish_boot() -> void:
	_booted = true
	boot_finished.emit()


func _on_session_changed(uid: String) -> void:
	# Cloud-save bookkeeping is per user: a new user (switch, sign-out, a
	# different login) never reuses the previous user's CAS / version.
	if cloud_save != null:
		cloud_save.bind_user(uid)
	if uid == "":
		_display_name = ""
		_set_online(false, "signed_out")
		return
	session_ready.emit(uid)
	_set_online(true, "login")


func _set_online(value: bool, reason: String) -> void:
	if _online_reported and value == _online:
		return
	_online = value
	_online_reported = true
	online_changed.emit(value)
	track("online_state", {"online": 1 if value else 0, "reason": reason})


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_CLOSE_REQUEST:
			_close_analytics_session()
		NOTIFICATION_APPLICATION_RESUMED:
			if _started and not _session_open:
				_open_analytics_session()


func _open_analytics_session() -> void:
	_session_open = true
	_session_started_ms = Time.get_ticks_msec()
	track("session_start", _session_start_props())


func _close_analytics_session() -> void:
	if not _session_open:
		return
	_session_open = false
	track("session_end", {"duration_s": int((Time.get_ticks_msec() - _session_started_ms) / 1000)})


## Props for `session_start`. Override to report the game's own build mode and
## version; the default uses OS.is_debug_build(), the project's
## application/config/version and OS.get_name().
func _session_start_props() -> Dictionary:
	return {
		"build_mode": "debug" if OS.is_debug_build() else "release",
		"version": str(ProjectSettings.get_setting("application/config/version", "")),
		"platform": OS.get_name().to_lower(),
	}


## Duck-type check for a SaveService-style store (amendment 6). The `changed`
## signal is optional (without it cloud save syncs on start / pause only).
static func is_valid_save_store(store: Object) -> bool:
	return store != null and store.has_method("export_prefix") and store.has_method("import_prefix")


# ---- Status ------------------------------------------------------------------

## Configured, not forced offline, and holding a session. NOTE: false until the
## deferred boot has logged in (and always before start()); screens that check
## it in _ready() should `await wait_until_ready()` first.
func is_online() -> bool:
	return config != null and config.is_ready() and auth != null and auth.has_session()


## Session user id, or "" when offline / before login.
func user_id() -> String:
	if config == null or config.is_offline() or auth == null:
		return ""
	return auth.user_id


# ---- Statistics --------------------------------------------------------------

## Set a user stat. key must match ^[a-z0-9_]+$. -> {ok, error, value?}
func record_stat(key: String, value: int) -> Dictionary:
	var gate := _gate(false, "stats", key)
	if not gate.is_empty():
		return gate
	return await stats_client.set_stat(key, value)


## Add delta to a user stat. -> {ok, error, value?} (new total)
func increment_stat(key: String, delta: int = 1) -> Dictionary:
	var gate := _gate(false, "stats", key)
	if not gate.is_empty():
		return gate
	return await stats_client.increment_stat(key, delta)


# ---- Leaderboards ------------------------------------------------------------
## `board` is a logical name mapped via config.leaderboards (unmapped names pass
## through). Entries: {user_id, display_name, score, rank, is_me}.

func submit_score(board: String, score: int) -> Dictionary:
	var gate := _gate(false, "boards", config.leaderboard_id(board) if config != null else board)
	if not gate.is_empty():
		return gate
	return await leaderboards_client.submit_score(config.leaderboard_id(board), score)


## -> {ok, error, entries:Array}
func top_scores(board: String, count := 10) -> Dictionary:
	var gate := _gate()
	if not gate.is_empty():
		return gate
	return await leaderboards_client.get_top(config.leaderboard_id(board), count)


## -> {ok, error, entries:Array}
func scores_around_me(board: String, count := 5) -> Dictionary:
	var gate := _gate()
	if not gate.is_empty():
		return gate
	return await leaderboards_client.get_around_me(config.leaderboard_id(board), count)


# ---- Remote config -----------------------------------------------------------

## The cached app config (fetched at startup; {} until then or when offline).
## Not a coroutine. Listen to config_updated for refreshes.
func remote_config() -> Dictionary:
	return _remote_config


## Re-fetch the app config now; updates the cache and emits config_updated on
## success. -> {ok, error, config?}
func refresh_remote_config() -> Dictionary:
	var gate := _gate()
	if not gate.is_empty():
		return gate
	var res: Dictionary = await remote_config_client.fetch_app_config()
	if res.get("ok", false) and res.get("config") is Dictionary:
		_remote_config = res.config
		config_updated.emit(_remote_config)
	return res


# ---- Cloud save --------------------------------------------------------------

## Upload synced local keys now (bypasses the debounce). -> {ok, error, conflict?}
func cloud_save_push() -> Dictionary:
	var gate := _gate(false, "blobs", config.cloud_save_blob_key() if config != null else "")
	if not gate.is_empty():
		return gate
	if not cloud_save.is_enabled():
		return SnapKitTransport.error_result(SnapKitTransport.ERR_DISABLED)
	return await cloud_save.push()


## Fetch + reconcile now. -> {ok, error, applied?}
func cloud_save_pull() -> Dictionary:
	var gate := _gate(false, "blobs", config.cloud_save_blob_key() if config != null else "")
	if not gate.is_empty():
		return gate
	if not cloud_save.is_enabled():
		return SnapKitTransport.error_result(SnapKitTransport.ERR_DISABLED)
	return await cloud_save.pull()


## Merge hook for cloud-save conflicts over the `data` maps. Override in the game
## subclass to customize; the default is SnapKitCloudSave.default_merge, with
## scalar keys decided by which side changed last
## (cloud_save.last_remote_is_newer, set just before this is called).
func _merge(local: Dictionary, remote: Dictionary) -> Dictionary:
	var remote_is_newer := cloud_save.last_remote_is_newer if cloud_save != null else true
	return CloudSaveScript.default_merge(local, remote, remote_is_newer)


# ---- Analytics ---------------------------------------------------------------

## Queue an analytics event (snake_case name, flat props). Never blocks; dropped
## silently offline once the buffer cap is reached, and before start().
func track(event: String, props: Dictionary = {}) -> void:
	if analytics_client == null:
		return
	if config != null and not config.is_declared("events", event):
		_warn_undeclared("events", event)
		if strict_declarations:
			return
	analytics_client.track(event, props)


# ---- Identity ----------------------------------------------------------------

## Register the platform bridge for a provider ("apple" | "google"). The bridge
## must implement an async get_identity_token() -> {ok, token, error}.
## Registering again replaces the previous bridge; null unregisters.
func register_identity_provider(provider_name: String, bridge: Object) -> void:
	if bridge == null:
		_identity_bridges.erase(provider_name)
	else:
		_identity_bridges[provider_name] = bridge


## Link the current anonymous user to a platform account. provider: "apple" |
## "google". Awaits the registered bridge's identity token, then
## SnapKitAuth.link_provider(). No bridge -> {ok:false, error:"no_provider"}.
## Linking is OFF unless config.link_providers lists the provider (D35 rollout:
## ship with [] until the platform side is ready) -> {ok:false,
## error:"disabled"} for an empty list, "unsupported_provider" for an unlisted
## one. -> {ok, error, provider}
func link_account(provider: String) -> Dictionary:
	var gate := _gate()
	if not gate.is_empty():
		return gate
	if config.link_providers.is_empty():
		return SnapKitTransport.error_result(SnapKitTransport.ERR_DISABLED)
	if not config.link_providers.has(provider):
		return SnapKitTransport.error_result(SnapKitAuth.ERR_UNSUPPORTED_PROVIDER)
	var bridge: Object = _identity_bridges.get(provider)
	if bridge == null or not bridge.has_method("get_identity_token"):
		return SnapKitTransport.error_result(ERR_NO_PROVIDER)
	var tok: Variant = await bridge.get_identity_token()
	if not (tok is Dictionary) or not SnapKitJson.get_bool(tok, "ok") \
			or SnapKitJson.get_str(tok, "token") == "":
		var err := SnapKitJson.get_str(tok, "error", "token_failed") if tok is Dictionary else "token_failed"
		return SnapKitTransport.error_result(err if err != "" else "token_failed")
	return await auth.link_provider(provider, tok.token)


## Adopt an existing account after link_account() returned "account_exists".
## provider_session: that whole result (or its "switch_session" dict). The
## session is persisted and the cached display name refreshed.
## THE ACCOUNT WINS (D36): the cloud-save bookkeeping is reset to the new user
## and the account's blob replaces local synced data for every key, except
## bools, which OR (guest achievements / unlocks survive). Guest-only
## non-bool progress is dropped (listed in cloud_save.dropped).
## cloud_save_applied fires for the keys that changed.
## -> {ok, error, user_id, cloud_save?:Dictionary}
func switch_account(provider_session: Dictionary) -> Dictionary:
	var gate := _gate()
	if not gate.is_empty():
		return gate
	var session: Dictionary = provider_session.get("switch_session", provider_session) \
		if provider_session.get("switch_session", provider_session) is Dictionary else provider_session
	if not auth.adopt_session(session):
		return SnapKitTransport.error_result(SnapKitTransport.ERR_INVALID_ARGUMENT)
	_display_name = ""
	var res := SnapKitTransport.ok_result()
	res["user_id"] = auth.user_id
	await refresh_profile()
	if cloud_save.is_enabled():
		res["cloud_save"] = await cloud_save.adopt_account()
	return res


func linked_providers() -> PackedStringArray:
	return auth.linked_providers() if auth != null else PackedStringArray()


# ---- Profile / display name (D16) -------------------------------------------

## The Profiles display name, or the auto-generated default
## (SnapKitProfiles.default_display_name of the user id / handle) when unset or
## offline. Never "". Not a coroutine (cached at startup and on set).
func display_name() -> String:
	if _display_name != "":
		return _display_name
	var seed := ""
	if auth != null:
		seed = auth.user_id if auth.user_id != "" else auth.username()
	var fallback: String = ProfilesScript.default_display_name(seed)
	return fallback if fallback != "" else "Player"


## Trim, length-limit and word-filter (SnapKitProfiles), then store in Profiles.
## Invalid -> {ok:false, error:"invalid_argument"}. -> {ok, error, display_name}
func set_display_name(new_name: String) -> Dictionary:
	var gate := _gate()
	if not gate.is_empty():
		return gate
	var res: Dictionary = await profiles_client.set_display_name(new_name)
	if res.get("ok", false):
		_display_name = str(res.get("display_name", _display_name))
	return res


## Re-read the profile and refresh the cached display name. -> {ok, error, ...}
func refresh_profile() -> Dictionary:
	var gate := _gate()
	if not gate.is_empty():
		return gate
	var res: Dictionary = await profiles_client.fetch_profile()
	if res.get("ok", false):
		_display_name = str(res.get("display_name", ""))
	return res


# ---- Quests (optional; only when config.quests_enabled()) --------------------
## Disabled -> {ok:false, error:"disabled"}.

## -> {ok, error, quests:Array}
func quests_fetch_active(tags: String = "") -> Dictionary:
	var gate := _gate(true)
	if not gate.is_empty():
		return gate
	return await quests_client.fetch_active(tags)


func quests_assign(quest: String) -> Dictionary:
	var gate := _gate(true)
	if not gate.is_empty():
		return gate
	return await quests_client.assign(quest)


func quests_increment(quest: String, task: String, delta: int = 1) -> Dictionary:
	var gate := _gate(true)
	if not gate.is_empty():
		return gate
	return await quests_client.increment(quest, task, delta)


## -> {ok, error, reward:Dictionary}
func quests_claim(quest: String) -> Dictionary:
	var gate := _gate(true)
	if not gate.is_empty():
		return gate
	return await quests_client.claim(quest)


## {} when a network call may proceed, else the error result to return.
## Declaration check (kind/name) runs BEFORE the offline gate, so offline test
## runs catch undeclared names too.
func _gate(needs_quests: bool = false, kind: String = "", item: String = "") -> Dictionary:
	if not _started or config == null:
		return SnapKitTransport.error_result(ERR_NOT_STARTED)
	if kind != "" and not config.is_declared(kind, item):
		_warn_undeclared(kind, item)
		if strict_declarations:
			return SnapKitTransport.error_result(ERR_UNDECLARED)
	if config.is_offline():
		return SnapKitTransport.error_result(SnapKitTransport.ERR_OFFLINE)
	if needs_quests and quests_client == null:
		return SnapKitTransport.error_result(SnapKitTransport.ERR_DISABLED)
	return {}


## One push_warning per (kind, name) per process.
func _warn_undeclared(kind: String, item: String) -> void:
	var k := "%s/%s" % [kind, item]
	if _warned_undeclared.has(k):
		return
	_warned_undeclared[k] = true
	push_warning("[SnapKit] %s '%s' is not in snapser_kit.config.json \"declared.%s\" — the snapend will reject it (404). %s"
		% [kind.trim_suffix("s"), item, kind,
			"Not sent (debug build)." if strict_declarations else "Sending anyway (release build)."])
