@tool
extends Control

## The Editor Tool Kit dock: a thin view over UpdateService. Shows the
## installed/upstream version + status, a Check / Update-now button pair, and a
## small Settings group (auto-check toggle + the source repo). The kit dogfoods
## its own framework — this is an EditorToolUi-built dock injected with a
## ToolService, exactly like any other tool's dock.
##
## Pure view: it holds control refs + binds `service.changed` with a METHOD
## callable (per the ToolService rule, so a hot-reload / late async signal can't
## fire into a freed view) and re-renders. No version logic lives here.

const Ui := preload("res://addons/editor_tool_kit/editor_tool_ui.gd")
const Pal := preload("res://addons/editor_tool_kit/tool_palette.gd")
const ServiceT := preload("res://addons/editor_tool_kit/update_service.gd")

## EditorSettings key for the auto-check-on-open preference. Stable string —
## persisted in the user's editor_settings-*.tres.
const SETTING_AUTO_CHECK := "editor_tool_kit/auto_check_updates"

## Injected by EditorToolPlugin before this is mounted. Untyped to match the
## kit's hot-reload-safe field convention.
var service

var _status: Label
var _check_btn: Button
var _update_btn: Button
var _auto_check: CheckBox


func _ready() -> void:
	_build()
	if service != null and not service.changed.is_connected(_render):
		service.changed.connect(_render)
	_render()


func _exit_tree() -> void:
	if service != null and service.changed.is_connected(_render):
		service.changed.disconnect(_render)


func _build() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", Pal.SEP)
	add_child(root)

	# ── Updates ───────────────────────────────────────────────────────────────
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	_status = Ui.status_label()
	col.add_child(_status)
	_check_btn = Ui.button(
		"⟳ Check for updates", _on_check, "Check %s for a newer version" % ServiceT.REPO_NAME
	)
	_update_btn = Ui.button(
		"⬇ Update now", _on_update,
		"Download the latest version from the repo and reload the plugin in place"
	)
	col.add_child(Ui.button_bar([_check_btn, _update_btn]))
	root.add_child(Ui.section("Updates", col))

	# ── Settings ──────────────────────────────────────────────────────────────
	var scol := VBoxContainer.new()
	scol.add_theme_constant_override("separation", 6)
	_auto_check = CheckBox.new()
	_auto_check.text = "Check for updates when the editor opens"
	_auto_check.button_pressed = _auto_check_enabled()
	_auto_check.toggled.connect(_on_auto_toggled)
	scol.add_child(_auto_check)
	var src := Label.new()
	src.text = "Source: %s/%s @ %s" % [ServiceT.REPO_OWNER, ServiceT.REPO_NAME, ServiceT.BRANCH]
	src.add_theme_color_override("font_color", Pal.TEXT_DIM)
	scol.add_child(src)
	scol.add_child(Ui.button("⧉ Open repository", _on_open_repo, ServiceT.REPO_PAGE))
	root.add_child(Ui.section("Settings", scol))


func _render() -> void:
	if service == null or _status == null:
		return
	var st := str(service.status)
	if str(service.message) != "":
		_status.text = str(service.message)
	elif st == ServiceT.ST_IDLE:
		_status.text = "Installed v%s — press Check for updates." % service.installed_version()
	else:
		_status.text = st

	var color := Pal.TEXT
	if st == ServiceT.ST_UPDATE_AVAILABLE:
		color = Pal.GREEN_SEL
	elif st == ServiceT.ST_UP_TO_DATE:
		color = Pal.TEXT_DIM
	elif st == ServiceT.ST_ERROR:
		color = Pal.ERROR
	_status.add_theme_color_override("font_color", color)

	var busy: bool = service.is_busy()
	_check_btn.disabled = busy
	_update_btn.disabled = busy or not service.has_update()


# ── Handlers ──────────────────────────────────────────────────────────────────

func _on_check() -> void:
	if service != null:
		service.check_for_updates()


func _on_update() -> void:
	if service != null:
		service.start_update()


func _on_open_repo() -> void:
	OS.shell_open(ServiceT.REPO_PAGE)


func _on_auto_toggled(on: bool) -> void:
	var es := EditorInterface.get_editor_settings()
	if es != null:
		es.set_setting(SETTING_AUTO_CHECK, on)


func _auto_check_enabled() -> bool:
	var es := EditorInterface.get_editor_settings()
	if es != null and es.has_setting(SETTING_AUTO_CHECK):
		return bool(es.get_setting(SETTING_AUTO_CHECK))
	return true
