@tool
extends EditorPlugin

## Snapser Kit editor plugin.
##
## Editor-only conveniences; the runtime kit (core/, clients/, service/) never
## depends on this file. Planned surface (v0.1):
##   - A "Snapser Kit" project-settings page that shows the resolved
##     res://snapser_kit.config.json (game id, gateway, boards, cloud-save keys)
##     and where each value came from (committed file / env / debug override).
##   - A "Test connection" action: resolves the config, performs an anonymous
##     login against the configured gateway, and reports the result in the
##     Output panel. Never reads or sends any API key.
##
## Self-update is NOT handled here: editor_tool_kit manages this addon through
## the [update] marker in plugin.cfg.
##
## SKELETON: menu wiring only; actions report "not implemented".

const TOOL_MENU_TEST := "Snapser Kit: Test connection"


func _enter_tree() -> void:
	add_tool_menu_item(TOOL_MENU_TEST, _on_test_connection)


func _exit_tree() -> void:
	remove_tool_menu_item(TOOL_MENU_TEST)


## Resolve config, attempt an anonymous login, print the outcome.
func _on_test_connection() -> void:
	print("[SnapKit] Test connection: not implemented (skeleton)")
