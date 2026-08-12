@tool
extends "res://addons/editor_tool_kit/editor_tool_plugin.gd"

const ServiceT := preload("res://addons/build_kit/build_kit_service.gd")
const DockT := preload("res://addons/build_kit/dock.gd")


func _config() -> Dictionary:
	return {
		"panel": "Build Kit",
		"service": ServiceT,
		"dock": DockT,
		"service_name": "BuildKitService",
		"dock_name": "BuildKitDock",
	}
