@tool
extends EditorPlugin

## Snapser Kit editor plugin.
##
## Editor-only conveniences; the runtime kit (core/, clients/, service/) never
## depends on this file. Two Project > Tools menu items:
##   - "Snapser Kit: Show resolved config" prints the resolved
##     res://snapser_kit.config.json (game id, gateway and where it came from,
##     boards, cloud-save keys, link providers) to the Output panel.
##   - "Snapser Kit: Test connection" resolves the config and performs an
##     anonymous login against the configured gateway, reporting the result and
##     latency. It uses its own session file (PROBE_SESSION_PATH), so it never
##     touches the game's player session, and never reads or sends an API key.
##
## Self-update is NOT handled here: editor_tool_kit manages this addon through
## the [update] marker in plugin.cfg.

const ConfigScript := preload("res://addons/snapser_kit/core/snapkit_config.gd")
const AuthScript := preload("res://addons/snapser_kit/core/snapkit_auth.gd")
const TransportScript := preload("res://addons/snapser_kit/core/snapkit_transport.gd")

const TOOL_MENU_TEST := "Snapser Kit: Test connection"
const TOOL_MENU_SHOW := "Snapser Kit: Show resolved config"
const PROBE_SESSION_PATH := "user://snapser_kit_editor_probe.json"

var _testing := false


func _enter_tree() -> void:
	add_tool_menu_item(TOOL_MENU_TEST, _on_test_connection)
	add_tool_menu_item(TOOL_MENU_SHOW, _on_show_config)


func _exit_tree() -> void:
	remove_tool_menu_item(TOOL_MENU_TEST)
	remove_tool_menu_item(TOOL_MENU_SHOW)


func _on_show_config() -> void:
	var cfg: SnapKitConfig = ConfigScript.from_project()
	if not FileAccess.file_exists(ConfigScript.DEFAULT_PATH):
		print("[SnapKit] %s not found — the kit runs offline." % ConfigScript.DEFAULT_PATH)
	print("[SnapKit] %s" % cfg.describe())
	print("[SnapKit]   game_id=%s  handle_prefix=%s" % [cfg.game_id, cfg.handle_prefix()])
	print("[SnapKit]   leaderboards=%s" % JSON.stringify(cfg.leaderboards))
	print("[SnapKit]   cloud_save: blob_key=%s sync_prefixes=%s" % [cfg.cloud_save_blob_key(), cfg.cloud_save_prefixes()])
	print("[SnapKit]   link_providers=%s  quests=%s" % [cfg.link_providers, cfg.quests_enabled()])


## Resolve config, attempt an anonymous login, print the outcome.
func _on_test_connection() -> void:
	if _testing:
		return
	var cfg: SnapKitConfig = ConfigScript.from_project()
	if cfg.is_offline():
		print("[SnapKit] Test connection: %s — nothing to test." % cfg.describe())
		return
	_testing = true
	var transport: SnapKitTransport = TransportScript.new()
	var auth: SnapKitAuth = AuthScript.new()
	add_child(transport)
	add_child(auth)
	auth.session_path = PROBE_SESSION_PATH
	transport.setup(cfg, auth)
	auth.setup(cfg, transport)
	print("[SnapKit] Test connection: anonymous login via %s ..." % cfg.gateway_url)
	var t0 := Time.get_ticks_msec()
	var ok: bool = await auth.reauth()
	var ms := Time.get_ticks_msec() - t0
	if ok:
		print("[SnapKit] Test connection OK in %d ms — user %s." % [ms, auth.user_id])
	else:
		push_warning("[SnapKit] Test connection FAILED after %d ms (see warnings above). " % ms
			+ "Check the gateway URL, that anonymous auth is enabled on the snapend, and CORS for Web.")
	transport.queue_free()
	auth.queue_free()
	_testing = false
