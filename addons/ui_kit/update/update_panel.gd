@tool
extends Control

## The UI Kit dock: a thin, self-contained view over UpdateService. Shows the
## installed/upstream version + status, a Check / Update-now button pair, and a
## small Settings group (auto-check toggle + the source repo).
##
## Pure view: it holds control refs + binds `service.changed` with a METHOD
## callable (so a hot-reload / late async signal can't fire into a freed view) and
## re-renders. No version logic lives here.

const ServiceT := preload("res://addons/ui_kit/update/update_service.gd")

## EditorSettings key for the auto-check-on-open preference. Stable string.
const SETTING_AUTO_CHECK := "ui_kit/auto_check_updates"

## Injected by the plugin before this is mounted. Untyped to match the hot-reload-
## safe field convention.
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
	root.add_theme_constant_override("separation", 10)
	root.offset_left = 10
	root.offset_top = 10
	root.offset_right = -10
	root.offset_bottom = -10
	add_child(root)

	# ── Updates ───────────────────────────────────────────────────────────────
	var head := Label.new()
	head.text = "Updates"
	head.add_theme_font_size_override("font_size", 16)
	root.add_child(head)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_status)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	_check_btn = Button.new()
	_check_btn.text = "⟳ Check for updates"
	_check_btn.tooltip_text = "Check %s for a newer version" % ServiceT.REPO_NAME
	_check_btn.pressed.connect(_on_check)
	bar.add_child(_check_btn)
	_update_btn = Button.new()
	_update_btn.text = "⬇ Update now"
	_update_btn.tooltip_text = "Download the latest version from the repo and reload the plugin in place"
	_update_btn.pressed.connect(_on_update)
	bar.add_child(_update_btn)
	root.add_child(bar)

	root.add_child(HSeparator.new())

	# ── Settings ──────────────────────────────────────────────────────────────
	_auto_check = CheckBox.new()
	_auto_check.text = "Check for updates when the editor opens"
	_auto_check.button_pressed = _auto_check_enabled()
	_auto_check.toggled.connect(_on_auto_toggled)
	root.add_child(_auto_check)

	var src := Label.new()
	src.text = "Source: %s/%s @ %s" % [ServiceT.REPO_OWNER, ServiceT.REPO_NAME, ServiceT.BRANCH]
	src.modulate = Color(1, 1, 1, 0.6)
	root.add_child(src)

	var repo_btn := Button.new()
	repo_btn.text = "⧉ Open repository"
	repo_btn.pressed.connect(_on_open_repo)
	root.add_child(repo_btn)


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

	var color := Color.WHITE
	if st == ServiceT.ST_UPDATE_AVAILABLE:
		color = Color(0.4, 0.9, 0.5)
	elif st == ServiceT.ST_UP_TO_DATE:
		color = Color(1, 1, 1, 0.6)
	elif st == ServiceT.ST_ERROR:
		color = Color(0.95, 0.45, 0.45)
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
