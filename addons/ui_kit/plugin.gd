@tool
extends EditorPlugin

## ui_kit ships the generic UI shell infrastructure — UiRouter (an async stack-FSM
## router), UiState, UiScreenScaffold, UiReg (control registration), and UiDriver
## (a semantic UI/navigation automation layer). Those are RUNTIME singletons /
## classes: the consuming project declares UiRouter + UiDriver as autoloads
## (pointing at ui_router.gd / ui_driver.gd) and uses the rest by path/class_name.
##
## This EditorPlugin itself does ONE editor-side job: mount a small "UI Kit" dock
## that checks the source repo (github.com/thegoldenmule/godot-addons) for a newer
## version and pulls it in place — the same self-update convention as godot-ai and
## godot-editor-tk. It does NOT register the autoloads (the project chooses their
## names); see addons/ui_kit/README.md for the wiring recipe.

const UpdateServiceT := preload("res://addons/ui_kit/update/update_service.gd")
const UpdatePanelT := preload("res://addons/ui_kit/update/update_panel.gd")
const RunnerT := preload("res://addons/ui_kit/update/update_reload_runner.gd")

## EditorSettings key for the auto-check-on-open preference (also read/written by
## the panel's toggle). Stable string — persisted in editor_settings-*.tres.
const SETTING_AUTO_CHECK := "ui_kit/auto_check_updates"

const PANEL_TITLE := "UI Kit"

var _service
var _panel


func _enter_tree() -> void:
	## Register the setting before the dock (whose checkbox reads it) is built so it
	## surfaces in Editor Settings, is seeded to true, and Godot doesn't log a
	## one-time "property not defined" notice.
	_register_settings()

	_service = UpdateServiceT.new()
	_service.name = "UiKitUpdateService"
	add_child(_service)
	if _service.has_method("setup"):
		_service.setup(self)

	_panel = UpdatePanelT.new()
	_panel.name = "UiKitUpdatePanel"
	_panel.service = _service
	add_control_to_bottom_panel(_panel, PANEL_TITLE)

	if _service != null and _auto_check_enabled():
		## Deferred so the service (and its HTTPRequest child) is fully in-tree
		## before the first request fires.
		_service.check_for_updates.call_deferred()


func _exit_tree() -> void:
	if _panel != null:
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()
		_panel = null
	if _service != null:
		_service.queue_free()
		_service = null


func _register_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	if not es.has_setting(SETTING_AUTO_CHECK):
		es.set_setting(SETTING_AUTO_CHECK, true)
	es.set_initial_value(SETTING_AUTO_CHECK, true, false)
	es.add_property_info({"name": SETTING_AUTO_CHECK, "type": TYPE_BOOL})


## Hand-off from UpdateService once the archive is downloaded. The reload runner is
## about to set_plugin_enabled(false); a mounted Control being freed mid-reload is
## the hot-reload crash class, so tear our panel down here FIRST. The runner is
## then parented OUTSIDE this plugin so it survives the disable.
func install_downloaded_update(zip_path: String, temp_dir: String) -> void:
	if _panel != null:
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()
		_panel = null
	var runner := RunnerT.new()
	runner.name = "UiKitUpdateReloadRunner"
	var host := EditorInterface.get_base_control()
	if host != null:
		host.add_child(runner)
	else:
		get_tree().root.add_child(runner)
	runner.start(zip_path, temp_dir, null)


func _auto_check_enabled() -> bool:
	var es := EditorInterface.get_editor_settings()
	if es != null and es.has_setting(SETTING_AUTO_CHECK):
		return bool(es.get_setting(SETTING_AUTO_CHECK))
	return true
