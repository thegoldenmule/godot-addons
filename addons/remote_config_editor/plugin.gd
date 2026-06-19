@tool
extends "res://addons/editor_tool_kit/editor_tool_plugin.gd"

## Remote Config editor plugin: a bottom-panel dock that aggregates every committed
## content blob (per a project-supplied manifest) into one backend "remote config"
## document, previews + copies the full publish payload, and optionally checks live
## drift via a comparator the consuming project configures. Pure editor-side
## authoring; no runtime/game dependency and no bridge (publishing is a manual
## console paste). The shared EditorToolPlugin base constructs the
## RemoteConfigService + dock and mounts/tears them down.
##
## Everything project-specific (paths, the drift-check command, labels) lives in a
## res://remote_config_editor.config.json the consuming project owns — this addon
## ships nothing game-specific. See config.example.json + the README.

const ServiceT := preload("res://addons/remote_config_editor/remote_config_service.gd")
const DockT := preload("res://addons/remote_config_editor/dock.gd")


func _config() -> Dictionary:
	return {
		"panel": "Remote Config",
		"service": ServiceT,
		"dock": DockT,
		"service_name": "RemoteConfigService",
		"dock_name": "RemoteConfig",
	}
