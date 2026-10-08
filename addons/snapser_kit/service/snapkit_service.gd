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
##   leaderboards_client  = SnapKitLeaderboards.new(transport)  clients/snapkit_leaderboards.gd
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
## STARTUP (deferred so a slow gateway never delays the first frame)
## ---------------------------------------------------------------------------
## offline -> emit online_changed(false) and stop.
## online  -> auth.ensure_session() -> session_ready(user_id), online_changed(true)
##         -> remote config fetch (cached; config_updated(config))
##         -> profile fetch (caches the display name)
##         -> cloud_save.pull() when enabled (may emit cloud_save_conflict)
##
## SKELETON: signatures + wiring final for v0.1; bodies are stubs.

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

var _remote_config: Dictionary = {}
var _display_name: String = ""
var _started: bool = false


# ---- Lifecycle ---------------------------------------------------------------

## Resolve SnapKitConfig.from_project() and start. Call once, from the autoload's
## _ready(). Idempotent: later calls are ignored.
func start() -> void:
	pass


## Start with an explicit config (tests, tools). Builds the wiring described in
## the class doc and schedules the deferred startup sequence.
func start_with_config(cfg: SnapKitConfig) -> void:
	pass


## Route all traffic to an in-process fake gateway (tests). Call after start*().
func use_mock_gateway(mock: SnapKitMockGateway) -> void:
	pass


# ---- Status ------------------------------------------------------------------

## Configured, not forced offline, and holding a session.
func is_online() -> bool:
	return false


## Session user id, or "" when offline / before login.
func user_id() -> String:
	return ""


# ---- Statistics --------------------------------------------------------------

## Set a user stat. key must match ^[a-z0-9_]+$. -> {ok, error, value?}
func record_stat(key: String, value: int) -> Dictionary:
	return SnapKitTransport.not_implemented()


## Add delta to a user stat. -> {ok, error, value?} (new total)
func increment_stat(key: String, delta: int = 1) -> Dictionary:
	return SnapKitTransport.not_implemented()


# ---- Leaderboards ------------------------------------------------------------
## `board` is a logical name mapped via config.leaderboards (unmapped names pass
## through). Entries: {user_id, display_name, score, rank, is_me}.

func submit_score(board: String, score: int) -> Dictionary:
	return SnapKitTransport.not_implemented()


## -> {ok, error, entries:Array}
func top_scores(board: String, count := 10) -> Dictionary:
	return SnapKitTransport.not_implemented()


## -> {ok, error, entries:Array}
func scores_around_me(board: String, count := 5) -> Dictionary:
	return SnapKitTransport.not_implemented()


# ---- Remote config -----------------------------------------------------------

## The cached app config (fetched at startup; {} until then or when offline).
## Not a coroutine. Listen to config_updated for refreshes.
func remote_config() -> Dictionary:
	return _remote_config


# ---- Cloud save --------------------------------------------------------------

## Upload synced local keys now (bypasses the debounce). -> {ok, error, conflict?}
func cloud_save_push() -> Dictionary:
	return SnapKitTransport.not_implemented()


## Fetch + reconcile now. -> {ok, error, applied?}
func cloud_save_pull() -> Dictionary:
	return SnapKitTransport.not_implemented()


## Merge hook for cloud-save conflicts over the `data` maps. Override in the game
## subclass to customize; the default is SnapKitCloudSave.default_merge.
func _merge(local: Dictionary, remote: Dictionary) -> Dictionary:
	return {}


# ---- Analytics ---------------------------------------------------------------

## Queue an analytics event (snake_case name, flat props). Never blocks; dropped
## silently offline once the buffer cap is reached.
func track(event: String, props: Dictionary = {}) -> void:
	pass


# ---- Identity ----------------------------------------------------------------

## Link the current anonymous user to a platform account. provider: "apple" |
## "google" (must be listed in config.link_providers). Obtains the identity
## token from the platform addon, then SnapKitAuth.link_provider(). (Wave 4)
## -> {ok, error, provider}
func link_account(provider: String) -> Dictionary:
	return SnapKitTransport.not_implemented()


func linked_providers() -> PackedStringArray:
	return PackedStringArray()


# ---- Profile / display name (D16) -------------------------------------------

## The Profiles display name, or the auto-generated default
## (SnapKitProfiles.default_display_name of the user id / handle) when unset or
## offline. Never "". Not a coroutine (cached at startup and on set).
func display_name() -> String:
	return ""


## Trim, length-limit and word-filter (SnapKitProfiles), then store in Profiles.
## Invalid -> {ok:false, error:"invalid_argument"}. -> {ok, error, display_name}
func set_display_name(new_name: String) -> Dictionary:
	return SnapKitTransport.not_implemented()


# ---- Quests (optional; only when config.quests_enabled()) --------------------
## Disabled -> {ok:false, error:"disabled"}.

## -> {ok, error, quests:Array}
func quests_fetch_active(tags: String = "") -> Dictionary:
	return SnapKitTransport.not_implemented()


func quests_assign(quest: String) -> Dictionary:
	return SnapKitTransport.not_implemented()


func quests_increment(quest: String, task: String, delta: int = 1) -> Dictionary:
	return SnapKitTransport.not_implemented()


## -> {ok, error, reward:Dictionary}
func quests_claim(quest: String) -> Dictionary:
	return SnapKitTransport.not_implemented()
