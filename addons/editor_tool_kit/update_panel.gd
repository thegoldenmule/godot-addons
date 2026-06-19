@tool
extends Control

## The Editor Tool Kit dock: a thin view over the UpdateService package MANAGER.
## Lists every managed addon (any addon carrying an `[update]` marker, including
## etk itself) as a row — name, installed → upstream version, status — with a
## per-row Update button plus Check-all / Update-all, and a small Settings group
## (auto-check toggle). The kit dogfoods its own framework: an EditorToolUi-built
## dock injected with a ToolService, exactly like any other tool's dock.
##
## Pure view: it holds the service ref + binds `service.changed` with a METHOD
## callable (per the ToolService rule, so a hot-reload / late async signal can't
## fire into a freed view) and rebuilds the row list. No version logic lives here.

const Ui := preload("res://addons/editor_tool_kit/editor_tool_ui.gd")
const Pal := preload("res://addons/editor_tool_kit/tool_palette.gd")
const ServiceT := preload("res://addons/editor_tool_kit/update_service.gd")

## EditorSettings key for the auto-check-on-open preference. Stable string —
## persisted in the user's editor_settings-*.tres.
const SETTING_AUTO_CHECK := "editor_tool_kit/auto_check_updates"

## Injected by EditorToolPlugin before this is mounted. Untyped to match the kit's
## hot-reload-safe field convention.
var service

var _summary: Label
var _check_btn: Button
var _update_btn: Button
var _rows: VBoxContainer
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

	# ── Packages ────────────────────────────────────────────────────────────────
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	_summary = Ui.status_label()
	col.add_child(_summary)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 4)
	col.add_child(_rows)
	_check_btn = Ui.button("⟳ Check all", _on_check_all, "Check every managed addon for a newer version")
	_update_btn = Ui.button(
		"⬇ Update all", _on_update_all,
		"Download the latest versions of all out-of-date addons and reload them in place"
	)
	col.add_child(Ui.button_bar([_check_btn, _update_btn]))
	root.add_child(Ui.section("Packages", col))

	# ── Settings ────────────────────────────────────────────────────────────────
	var scol := VBoxContainer.new()
	scol.add_theme_constant_override("separation", 6)
	_auto_check = CheckBox.new()
	_auto_check.text = "Check for updates when the editor opens"
	_auto_check.button_pressed = _auto_check_enabled()
	_auto_check.toggled.connect(_on_auto_toggled)
	scol.add_child(_auto_check)
	root.add_child(Ui.section("Settings", scol))


func _render() -> void:
	if service == null or _summary == null:
		return
	var msg := str(service.message)
	_summary.text = msg if msg != "" else "Press Check all to look for updates."

	var busy: bool = service.is_busy()
	_check_btn.disabled = busy
	_update_btn.disabled = busy or not service.has_any_update()

	_rebuild_rows()


func _rebuild_rows() -> void:
	for child in _rows.get_children():
		child.queue_free()
	if service.packages.is_empty():
		var none := Label.new()
		none.text = "No managed addons found."
		none.add_theme_color_override("font_color", Pal.TEXT_DIM)
		_rows.add_child(none)
		return
	for pkg in service.packages:
		_rows.add_child(_package_row(pkg))


func _package_row(pkg) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Pal.SEP)
	row.tooltip_text = "%s @ %s" % [str(pkg["source"]), str(pkg["branch"])]

	var name_lbl := Label.new()
	name_lbl.text = str(pkg["name"])
	name_lbl.add_theme_color_override("font_color", Pal.EMPHASIS)
	name_lbl.custom_minimum_size = Vector2(140, 0)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_lbl)

	var status := Label.new()
	status.text = _row_text(pkg)
	status.add_theme_color_override("font_color", _row_color(str(pkg["state"])))
	status.custom_minimum_size = Vector2(220, 0)
	row.add_child(status)

	var update := Ui.button("⬇ Update", _on_update_one.bind(pkg), "Update %s in place" % str(pkg["name"]))
	update.disabled = service.is_busy() or str(pkg["state"]) != ServiceT.ST_UPDATE_AVAILABLE
	row.add_child(update)
	return row


func _row_text(pkg) -> String:
	var installed := str(pkg["installed"])
	var state := str(pkg["state"])
	if str(pkg["note"]) != "":
		return str(pkg["note"])
	match state:
		ServiceT.ST_CHECKING:
			return "checking…"
		ServiceT.ST_DOWNLOADING:
			return "downloading…"
		ServiceT.ST_INSTALLING:
			return "installing…"
		ServiceT.ST_UPDATE_AVAILABLE:
			return "v%s → v%s" % [installed, str(pkg["latest"])]
		ServiceT.ST_UP_TO_DATE:
			return "up to date (v%s)" % installed
		_:
			return "installed v%s" % installed


func _row_color(state: String) -> Color:
	match state:
		ServiceT.ST_UPDATE_AVAILABLE:
			return Pal.GREEN_SEL
		ServiceT.ST_UP_TO_DATE:
			return Pal.TEXT_DIM
		ServiceT.ST_ERROR:
			return Pal.ERROR
		_:
			return Pal.TEXT


# ── Handlers ──────────────────────────────────────────────────────────────────

func _on_check_all() -> void:
	if service != null:
		service.check_all()


func _on_update_all() -> void:
	if service != null:
		service.update_all()


func _on_update_one(pkg) -> void:
	if service != null:
		service.update_one(pkg)


func _on_auto_toggled(on: bool) -> void:
	var es := EditorInterface.get_editor_settings()
	if es != null:
		es.set_setting(SETTING_AUTO_CHECK, on)


func _auto_check_enabled() -> bool:
	var es := EditorInterface.get_editor_settings()
	if es != null and es.has_setting(SETTING_AUTO_CHECK):
		return bool(es.get_setting(SETTING_AUTO_CHECK))
	return true
