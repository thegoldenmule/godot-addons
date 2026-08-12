@tool
extends Control

## Build Kit dock — a pure view over BuildKitService: the preflight checklist
## on the left (each failing row shows its fix instructions inline, plus a Fix
## button where the service can repair it), the build controls + streaming
## pipeline log on the right. All service signals are bound with METHOD
## CALLABLES (hot-reload safety, per the tool-kit rule).

const Ui := preload("res://addons/editor_tool_kit/editor_tool_ui.gd")
const Pal := preload("res://addons/editor_tool_kit/tool_palette.gd")

var service: Node

var _rows_box: VBoxContainer
var _status: Label
var _status_links: HBoxContainer
var _log: TextEdit
var _btn_testflight: Button
var _btn_ipa: Button
var _btn_cancel: Button
var _btn_tf_status: Button
var _p8_dialog: EditorFileDialog
var _issuer_text := ""   # survives preflight-row rebuilds (rows re-render on refresh)
var _bundle_text := ""   # ditto, for the create-preset form
var _teams: Array = []   # [{id, name}] from the service, refreshed with the rows
var _selected_team := "" # ditto-persistent team-picker choice


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var root := Ui.split_root(400.0, 460.0)
	add_child(root)
	var left: VBoxContainer = root.get_child(0)
	var right: VBoxContainer = root.get_child(1)

	# ── Left: preflight ──
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 6)
	scroll.add_child(_rows_box)
	var pre_col := VBoxContainer.new()
	pre_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pre_col.add_child(scroll)
	pre_col.add_child(Ui.button_bar([Ui.button("⟳ Refresh preflight", _on_refresh)]))
	left.add_child(Ui.section("Preflight", pre_col, true))

	# ── Right: build + log ──
	_btn_testflight = Ui.button("▶ Build → TestFlight", _on_build_testflight,
		"Export → patch → archive → upload to App Store Connect")
	_btn_ipa = Ui.button("Build .ipa only", _on_build_ipa,
		"Same pipeline, but the signed .ipa stays local")
	_btn_cancel = Ui.button("✕ Cancel", _on_cancel)
	_btn_cancel.disabled = true
	_btn_tf_status = Ui.button("TestFlight status", _on_tf_status,
		"Poll App Store Connect for recent build processing states (needs API key)")
	_status = Ui.status_label(380.0)
	var build_col := VBoxContainer.new()
	build_col.add_child(Ui.button_bar([_btn_testflight, _btn_ipa, _btn_cancel, _btn_tf_status]))
	build_col.add_child(_status)
	_status_links = HBoxContainer.new()
	_status_links.add_theme_constant_override("separation", Pal.SEP)
	build_col.add_child(_status_links)
	right.add_child(Ui.section("Build iOS", build_col))

	_log = TextEdit.new()
	_log.editable = false
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.custom_minimum_size = Vector2(0, 160)
	right.add_child(Ui.section("Log", _log, true))

	# OS-level file drop (the whole editor window fires this; we act only while
	# this panel is visible and only on .p8 files — the ASC-key ingest path).
	get_window().files_dropped.connect(_on_files_dropped)

	if service != null:
		service.preflight_changed.connect(_on_preflight_changed)
		service.stage_changed.connect(_on_stage_changed)
		service.log_line.connect(_on_log_line)
		service.build_finished.connect(_on_build_finished)
		_refresh_deferred.call_deferred()


func _refresh_deferred() -> void:
	if service != null:
		service.refresh_preflight()


# ── Handlers ──────────────────────────────────────────────────────────────────

func _on_refresh() -> void:
	service.refresh_preflight()


func _on_build_testflight() -> void:
	_start(true)


func _on_build_ipa() -> void:
	_start(false)


func _start(upload: bool) -> void:
	var result: Dictionary = service.start_build(upload)
	if not result.get("ok", false):
		_status.text = str(result.get("error", ""))
		_status.add_theme_color_override("font_color", Pal.ERROR)


func _on_cancel() -> void:
	service.cancel()


func _on_tf_status() -> void:
	var result: Dictionary = service.check_testflight_status()
	if not result.get("ok", false):
		_status.text = str(result.get("error", ""))
		_status.add_theme_color_override("font_color", Pal.ERROR)


func _on_stage_changed(stage: String) -> void:
	var busy := stage != ""
	_btn_testflight.disabled = busy
	_btn_ipa.disabled = busy
	_btn_cancel.disabled = not busy
	if busy:
		_status.text = "Running: " + stage + "…"
		_status.add_theme_color_override("font_color", Pal.TEXT)


func _on_log_line(text: String) -> void:
	_log.text += text
	_log.scroll_vertical = _log.get_line_count()


func _on_build_finished(result: Dictionary) -> void:
	if result.get("ok", false):
		_status.text = "✓ " + str(result.get("title", "Done"))
		_status.add_theme_color_override("font_color", Pal.GREEN_SEL)
	else:
		_status.text = "✗ %s — %s" % [result.get("title", "Failed"), result.get("guidance", "")]
		_status.add_theme_color_override("font_color", Pal.ERROR)
	_fill_links(_status_links, result.get("links", []))


## Repopulate `bar` with open-in-browser buttons for [{label, url}, …].
func _fill_links(bar: HBoxContainer, links: Array) -> void:
	for child in bar.get_children():
		child.queue_free()
	for link in links:
		bar.add_child(Ui.button("↗ " + str(link.get("label", "Open")),
			_open_url.bind(str(link.get("url", ""))), str(link.get("url", ""))))


func _open_url(url: String) -> void:
	if url == "":
		return
	if url.begins_with("/"):
		# A local path (e.g. /Applications/Xcode.app): `open` launches the app,
		# where shell_open would only reveal it.
		OS.create_process("/usr/bin/open", [url])
		return
	OS.shell_open(url)


# ── Preflight rendering ───────────────────────────────────────────────────────

func _on_preflight_changed(rows: Array) -> void:
	_teams = service.list_teams()
	if _selected_team == "" and not _teams.is_empty():
		_selected_team = str(_teams[0]["id"])
	for child in _rows_box.get_children():
		child.queue_free()
	for row in rows:
		_rows_box.add_child(_make_row(row))


func _make_row(row: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", Pal.SEP)
	var icon := Label.new()
	match str(row["status"]):
		"ok":
			icon.text = "✓"
			icon.add_theme_color_override("font_color", Pal.GREEN_SEL)
		"warn":
			icon.text = "△"
			icon.add_theme_color_override("font_color", Pal.USAGE_WARN)
		"busy":
			icon.text = "●"
			icon.add_theme_color_override("font_color", Pal.TEXT_DIM)
		_:
			icon.text = "✗"
			icon.add_theme_color_override("font_color", Pal.ERROR)
	line.add_child(icon)
	var name_label := Label.new()
	name_label.text = str(row["label"])
	name_label.add_theme_color_override("font_color", Pal.TEXT)
	line.add_child(name_label)
	var detail := Label.new()
	detail.text = str(row["detail"])
	detail.add_theme_color_override("font_color", Pal.TEXT_DIM)
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.clip_text = true
	line.add_child(detail)
	if bool(row.get("fixable", false)):
		line.add_child(Ui.button("Fix", _on_fix.bind(str(row["id"]))))
	box.add_child(line)

	if str(row["status"]) != "ok":
		if str(row.get("guidance", "")) != "":
			# Editor-default font size on purpose: a shrunken caption size is
			# unreadable on hi-DPI — the dim color alone marks it as secondary.
			var guide := Label.new()
			guide.text = str(row["guidance"])
			guide.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			guide.add_theme_color_override("font_color", Pal.CAPTION)
			box.add_child(guide)
		var links: Array = row.get("links", [])
		if not links.is_empty():
			var bar := HBoxContainer.new()
			bar.add_theme_constant_override("separation", Pal.SEP)
			_fill_links(bar, links)
			box.add_child(bar)
		if str(row["id"]) == "asc_key":
			box.add_child(_make_asc_key_form())
		if str(row["id"]) == "preset":
			if str(row["status"]) == "fail":
				box.add_child(_make_preset_form())
			elif bool(row.get("fixable", false)) and _teams.size() > 1:
				# The Fix needs a team choice — put the picker right here.
				box.add_child(_make_team_picker())
	return box


## Dropdown of the signed-in Xcode teams ("Name (ID)"); the selection feeds
## both the preset Fix and the create-preset form.
func _make_team_picker() -> OptionButton:
	var picker := OptionButton.new()
	for i in _teams.size():
		var team: Dictionary = _teams[i]
		var label := "%s (%s)" % [team["name"], team["id"]] if str(team["name"]) != "" else str(team["id"])
		picker.add_item(label, i)
		if str(team["id"]) == _selected_team:
			picker.select(i)
	picker.item_selected.connect(_on_team_selected)
	return picker


func _on_team_selected(index: int) -> void:
	if index >= 0 and index < _teams.size():
		_selected_team = str(_teams[index]["id"])


## Create-preset mini-form: a bundle-id field (prefilled from the project
## name), the team picker when several teams are signed in, and a Create
## button — the service writes the whole preset itself.
func _make_preset_form() -> Control:
	if _bundle_text == "":
		_bundle_text = service.default_bundle_id()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Pal.SEP)
	var bundle := LineEdit.new()
	bundle.placeholder_text = "com.studio.game"
	bundle.text = _bundle_text
	bundle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bundle.text_changed.connect(_on_bundle_changed)
	row.add_child(bundle)
	if _teams.size() > 1:
		row.add_child(_make_team_picker())
	row.add_child(Ui.button("Create preset", _on_create_preset))
	return row


func _on_bundle_changed(text: String) -> void:
	_bundle_text = text


func _on_create_preset() -> void:
	_show_result(service.create_ios_preset(_bundle_text, _selected_team))


## The ASC-key ingest mini-form: Browse for (or drop) the downloaded .p8, and
## an Issuer ID paste field. Rendered under the asc_key row until it's green.
func _make_asc_key_form() -> Control:
	var col := VBoxContainer.new()
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", Pal.SEP)
	row1.add_child(Ui.button("Browse for .p8…", _on_browse_p8,
		"Pick the downloaded AuthKey_<KEYID>.p8 — key id and path are extracted from it"))
	var hint := Label.new()
	hint.text = "…or drop the file anywhere on this panel"
	hint.add_theme_color_override("font_color", Pal.TEXT_DIM)
	row1.add_child(hint)
	col.add_child(row1)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", Pal.SEP)
	var issuer := LineEdit.new()
	issuer.placeholder_text = "Issuer ID (Copy button at the top of the API-keys page)"
	issuer.text = _issuer_text
	issuer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	issuer.text_changed.connect(_on_issuer_changed)
	row2.add_child(issuer)
	row2.add_child(Ui.button("Save", _on_save_issuer))
	col.add_child(row2)
	return col


func _on_issuer_changed(text: String) -> void:
	_issuer_text = text


func _on_save_issuer() -> void:
	_show_result(service.set_asc_issuer(_issuer_text))


func _on_browse_p8() -> void:
	if _p8_dialog == null:
		_p8_dialog = EditorFileDialog.new()
		_p8_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_p8_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		_p8_dialog.add_filter("*.p8", "App Store Connect API key")
		_p8_dialog.current_dir = OS.get_environment("HOME").path_join("Downloads")
		_p8_dialog.file_selected.connect(_on_p8_selected)
		add_child(_p8_dialog)
	_p8_dialog.popup_centered_ratio(0.5)


func _on_p8_selected(path: String) -> void:
	_show_result(service.adopt_asc_key(path))


func _on_files_dropped(files: PackedStringArray) -> void:
	if not is_visible_in_tree():
		return
	for file in files:
		if file.ends_with(".p8"):
			_show_result(service.adopt_asc_key(file))
			return


func _show_result(result: Dictionary) -> void:
	_status.text = str(result.get("message", result.get("error", "")))
	_status.add_theme_color_override("font_color",
		Pal.TEXT if result.get("ok", false) else Pal.ERROR)


func _on_fix(id: String) -> void:
	var result: Dictionary = service.apply_fix(id, {"team_id": _selected_team} if id == "preset" else {})
	_status.text = str(result.get("message", result.get("error", "")))
	_status.add_theme_color_override("font_color",
		Pal.TEXT if result.get("ok", false) else Pal.ERROR)
