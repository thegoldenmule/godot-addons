@tool
class_name EditorToolPlugin
extends EditorPlugin

const ToolTheme := preload("res://addons/editor_tool_kit/tool_theme.gd")

## Shared bootstrap for in-editor authoring tools. A concrete tool subclasses
## this and overrides _config() to declare its pieces; the base constructs them
## in the right order, injects the service into the (optional) bridge + dock,
## mounts the dock — beneath an enforced header (tool title + version + a
## self-reload button) — in the bottom panel, and tears everything down in
## reverse on _exit_tree. This collapses the ~25–37 line per-tool plugin.gd
## boilerplate; the version is read from the tool's own plugin.cfg.
##
## _config() -> {
##   "panel":   String,          # bottom-panel tab title
##   "service": Script,          # a ToolService subclass (constructed first)
##   "dock":    Script,          # a Control exposing a `service` property
##   "bridge":  Script = null,   # optional BridgeServer subclass
##   # optional cosmetic node names (preserve parity with the pre-migration tool):
##   "service_name": String = "",
##   "dock_name":    String = "",
##   "bridge_name":  String = "",
## }
##
## Construction order mirrors the hand-written plugins exactly: service →
## (bridge) → dock, with `service` injected before each child is added so an
## early _ready/_enter_tree always sees it.

var _service: Node
var _bridge: Node
var _dock: Control
var _panel_root: Control   # the [header, dock] wrapper actually mounted in the panel


## Override in a subclass to declare the tool. The base returns {} and mounts
## nothing (so editor_tool_kit's own library plugin stays a no-op).
func _config() -> Dictionary:
	return {}


func _enter_tree() -> void:
	var c := _config()
	if c.is_empty():
		return

	_service = (c["service"] as Script).new()
	if str(c.get("service_name", "")) != "":
		_service.name = str(c["service_name"])
	add_child(_service)

	if c.get("bridge") != null:
		_bridge = (c["bridge"] as Script).new()
		if str(c.get("bridge_name", "")) != "":
			_bridge.name = str(c["bridge_name"])
		_bridge.service = _service
		add_child(_bridge)

	_dock = (c["dock"] as Script).new()
	if str(c.get("dock_name", "")) != "":
		_dock.name = str(c["dock_name"])
	_dock.service = _service
	_dock.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Enforce the shared header (title left; version + reload button right) above
	# every tool's dock by mounting a [header, dock] wrapper rather than the dock
	# itself. The dock stays a plain Control and builds none of this.
	_panel_root = VBoxContainer.new()
	_panel_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel_root.add_theme_constant_override("separation", 6)
	# The shared occult-arcade Theme: assigned here so it cascades (Control.theme)
	# to every descendant of the header + dock with no per-dock styling code. A new
	# tool inherits the look for free; a dock may still override it locally, and
	# per-control overrides (preview panel, dot markers) still win over the cascade.
	_panel_root.theme = ToolTheme.build()
	_panel_root.add_child(EditorToolUi.tool_header(
		str(c["panel"]), _plugin_version(), _reload_plugin))
	_panel_root.add_child(_dock)
	add_control_to_bottom_panel(_panel_root, str(c["panel"]))


func _exit_tree() -> void:
	# The wrapper lives in the bottom panel (not a child of this plugin), so it
	# must be removed + freed explicitly; freeing it reaps the dock child too. The
	# service + bridge are children (add_child above); freeing them here is
	# equivalent to letting the plugin's own teardown reap them, but explicit +
	# ordered is clearer and lets each run its own _exit_tree (e.g. the bridge
	# stops its TCP server) deterministically.
	if _panel_root != null:
		remove_control_from_bottom_panel(_panel_root)
		_panel_root.free()
		_panel_root = null
		_dock = null
	if _bridge != null:
		_bridge.free()
		_bridge = null
	if _service != null:
		_service.free()
		_service = null


## This plugin's own plugin.cfg, derived from the concrete subclass's script
## location (res://addons/<tool>/plugin.gd → …/plugin.cfg) — no per-tool config.
func _cfg_path() -> String:
	return get_script().resource_path.get_base_dir().path_join("plugin.cfg")


func _plugin_version() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(_cfg_path()) != OK:
		return ""
	return str(cfg.get_value("plugin", "version", ""))


## Header reload button: disable then re-enable this plugin so the editor reloads
## its scripts. Deferred (mirroring godot-ai) — toggling synchronously from the
## button's pressed signal would free the panel mid-input-dispatch.
func _reload_plugin() -> void:
	_toggle_enabled.bind(_cfg_path()).call_deferred()


func _toggle_enabled(path: String) -> void:
	EditorInterface.set_plugin_enabled(path, false)
	EditorInterface.set_plugin_enabled(path, true)
