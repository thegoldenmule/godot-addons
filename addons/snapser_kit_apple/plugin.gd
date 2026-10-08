@tool
extends EditorPlugin

## Registers the iOS export plugin. Nothing else runs in the editor; the
## runtime API is SnapKitAppleBridge.

const ExportPlugin := preload("res://addons/snapser_kit_apple/snapkit_apple_export_plugin.gd")

var _export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	_export_plugin = ExportPlugin.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null
