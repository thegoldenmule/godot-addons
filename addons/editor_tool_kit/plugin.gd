@tool
extends "res://addons/editor_tool_kit/editor_tool_plugin.gd"

## editor_tool_kit ships the shared base classes for in-editor authoring tools —
## EditorToolPlugin, ToolService, ContentStore, EditorToolUi, BridgeServer (see
## each file + README.md). It is committed into the consuming project (so a fresh
## clone works offline) but is *sourced* from a standalone repo
## (github.com/thegoldenmule/godot-addons); this plugin mounts a small
## "Editor Tool Kit" panel that checks that repo for a newer version and pulls it
## in place, mirroring how the godot-ai plugin self-updates.
##
## The panel is itself built on the kit's own framework — UpdateService is a
## ToolService and UpdatePanel is its dock — so the kit dogfoods the bases it
## ships, and the enforced header (title + version + reload) comes for free from
## EditorToolPlugin. Each concrete tool still ships its own EditorPlugin; this
## plugin is not their host.

const UpdateServiceT := preload("res://addons/editor_tool_kit/update_service.gd")
const UpdatePanelT := preload("res://addons/editor_tool_kit/update_panel.gd")
const RunnerT := preload("res://addons/editor_tool_kit/update_reload_runner.gd")

## EditorSettings key for the auto-check-on-open preference (also read/written by
## the panel's toggle). Stable string — persisted in editor_settings-*.tres.
const SETTING_AUTO_CHECK := "editor_tool_kit/auto_check_updates"


func _config() -> Dictionary:
	return {
		"panel": "Editor Tool Kit",
		"service": UpdateServiceT,
		"dock": UpdatePanelT,
		"service_name": "EtkUpdateService",
		"dock_name": "EtkUpdatePanel",
	}


func _enter_tree() -> void:
	## Register the setting before super builds the dock (whose checkbox reads it)
	## so it surfaces in Editor Settings, is seeded to true, and Godot doesn't log
	## a one-time "property not defined" notice.
	_register_settings()
	super._enter_tree()
	if _service != null and _service.has_method("setup"):
		_service.setup(self)
	if _service != null and _auto_check_enabled():
		## Deferred so the service (and its HTTPRequest children) are fully in-tree
		## before the first requests fire.
		_service.check_all.call_deferred()


func _register_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	if not es.has_setting(SETTING_AUTO_CHECK):
		es.set_setting(SETTING_AUTO_CHECK, true)
	es.set_initial_value(SETTING_AUTO_CHECK, true, false)
	es.add_property_info({"name": SETTING_AUTO_CHECK, "type": TYPE_BOOL})


## Hand-off from UpdateService once the archive is downloaded. `prefixes` are the
## addon subtrees to extract and `plugin_cfgs` the plugins to toggle (one update
## action can cover several addons, including etk itself). The reload runner is
## about to set_plugin_enabled(false); a mounted Control being freed mid-reload is
## the hot-reload crash class, so tear our panel down here FIRST and null the
## base's refs (so EditorToolPlugin._exit_tree doesn't double-free it). The runner
## is then parented OUTSIDE this plugin so it survives the disable — including etk
## disabling itself.
func install_downloaded_update(
	zip_path: String, temp_dir: String, prefixes: Array, plugin_cfgs: Array
) -> void:
	if _panel_root != null:
		remove_control_from_bottom_panel(_panel_root)
		_panel_root.queue_free()
		_panel_root = null
		_dock = null
	var runner := RunnerT.new()
	runner.name = "EtkUpdateReloadRunner"
	var host := EditorInterface.get_base_control()
	if host != null:
		host.add_child(runner)
	else:
		get_tree().root.add_child(runner)
	runner.start(zip_path, temp_dir, prefixes, plugin_cfgs, null)


func _auto_check_enabled() -> bool:
	var es := EditorInterface.get_editor_settings()
	if es != null and es.has_setting(SETTING_AUTO_CHECK):
		return bool(es.get_setting(SETTING_AUTO_CHECK))
	return true
