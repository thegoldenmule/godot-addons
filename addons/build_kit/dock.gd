@tool
extends Control

## Build Kit dock — a pure view over BuildKitService: platform tabs (iOS,
## Android, itch.io), each with its own preflight checklist (failing rows show
## fix instructions inline, plus a Fix button where the service can repair it),
## build controls, and streaming pipeline log. Rows are namespaced
## (ios.*/android.*/itch.*); bare ids are global and render in every tab, unless
## the row carries a `platforms` Array naming the tabs it belongs to. All
## service signals are bound with METHOD CALLABLES (hot-reload safety, per
## the tool-kit rule).

const Ui := preload("res://addons/editor_tool_kit/editor_tool_ui.gd")
const Pal := preload("res://addons/editor_tool_kit/tool_palette.gd")

var service: Node

var _rows_box := {}      # platform -> VBoxContainer
var _status := {}        # platform -> Label
var _status_links := {}  # platform -> HBoxContainer
var _log := {}           # platform -> TextEdit
var _status_timers := {} # platform -> Timer (one-off action feedback auto-clear)

var _btn_testflight: Button
var _btn_ipa: Button
var _btn_cancel: Button
var _btn_tf_status: Button
var _btn_install: Button
var _btn_cancel_android: Button
var _btn_itch_push: Button
var _btn_itch_export: Button
var _btn_itch_dry_run: Button
var _btn_cancel_itch: Button
var _btn_itch_status: Button
var _itch_channel_picker: OptionButton
var _itch_channels: Array = []    # channel names parallel to picker items 1.. (item 0 = all)
var _selected_itch_channel := ""  # "" = all channels; survives picker re-population
var _itch_target_text := ""       # survives preflight-row rebuilds, like _issuer_text
var _butler_key_text := ""        # ditto; cleared the moment it's saved, never logged
var _itch_version_text := ""      # ditto, for the project-version form
var _p8_dialog: EditorFileDialog
var _issuer_text := ""   # survives preflight-row rebuilds (rows re-render on refresh)
var _bundle_text := ""   # ditto, for the create-preset form
var _teams: Array = []   # [{id, name}] from the service, refreshed with the rows
var _selected_team := "" # ditto-persistent team-picker choice
var _devices: Array = []      # [{serial, state, model}] from the service, refreshed with the rows
var _selected_device := ""    # ditto-persistent device-picker choice


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var tabs := TabContainer.new()
	tabs.set_anchors_preset(Control.PRESET_FULL_RECT)
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(tabs)
	tabs.add_child(_build_ios_tab())
	tabs.add_child(_build_android_tab())
	tabs.add_child(_build_itch_tab())
	# Node names can't hold '.', so the "itch.io" root got renamed "itch_io".
	tabs.set_tab_title(2, "itch.io")

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


func _build_ios_tab() -> Control:
	_btn_testflight = Ui.button("▶ Build → TestFlight", _on_build_testflight,
		"Export → patch → archive → upload to App Store Connect")
	_btn_ipa = Ui.button("Build .ipa only", _on_build_ipa,
		"Same pipeline, but the signed .ipa stays local")
	_btn_cancel = Ui.button("✕ Cancel", _on_cancel)
	_btn_cancel.disabled = true
	_btn_tf_status = Ui.button("TestFlight status", _on_tf_status,
		"Poll App Store Connect for recent build processing states (needs API key)")
	var build_col := VBoxContainer.new()
	build_col.add_child(Ui.button_bar([_btn_testflight, _btn_ipa, _btn_cancel, _btn_tf_status]))
	return _make_platform_tab("ios", "iOS", "Build iOS", build_col)


func _build_android_tab() -> Control:
	_btn_install = Ui.button("▶ Build → Device", _on_build_android,
		"Export a debug APK and adb install it on the selected/only device")
	_btn_cancel_android = Ui.button("✕ Cancel", _on_cancel_android)
	_btn_cancel_android.disabled = true
	# Deferred this pass (proposal §8) — visibly disabled rather than absent,
	# so intent is signaled instead of leaving the tab looking unfinished.
	var btn_aab := Ui.button("▶ Build → Play Console", Callable(),
		"Needs Gradle Build + the AAB pipeline — not built yet")
	btn_aab.disabled = true  # TODO: analog of iOS's _btn_testflight
	var btn_apk := Ui.button("Build .apk only", Callable(),
		"Needs the Gradle build template — not built yet")
	btn_apk.disabled = true  # TODO: analog of iOS's _btn_ipa
	var btn_keystore := Ui.button("Add release keystore…", Callable(),
		"Release-keystore ingestion — not built yet")
	btn_keystore.disabled = true  # TODO: analog of iOS's _make_asc_key_form
	var build_col := VBoxContainer.new()
	build_col.add_child(Ui.button_bar([_btn_install, _btn_cancel_android, btn_aab, btn_apk, btn_keystore]))
	return _make_platform_tab("android", "Android", "Build Android", build_col)


func _build_itch_tab() -> Control:
	_itch_channel_picker = OptionButton.new()
	_itch_channel_picker.tooltip_text = "Which itch.io channel(s) to export / push"
	_itch_channel_picker.item_selected.connect(_on_itch_channel_selected)
	_populate_itch_channels([])
	_btn_itch_push = Ui.button("▶ Build → itch.io", _on_build_itch_push,
		"Export the selected channel(s), then butler push each to itch.io")
	_btn_itch_export = Ui.button("Export only", _on_build_itch_export,
		"Export the selected channel(s) into the staging folder — no upload")
	_btn_itch_dry_run = Ui.button("Dry run", _on_build_itch_dry_run,
		"Export, then butler push --dry-run (checks the upload without publishing)")
	_btn_cancel_itch = Ui.button("✕ Cancel", _on_cancel)
	_btn_cancel_itch.disabled = true
	_btn_itch_status = Ui.button("itch status", _on_itch_status,
		"butler status for this game's channels (needs butler + an API key / butler login)")
	var build_col := VBoxContainer.new()
	build_col.add_child(Ui.form_row("Channel", _itch_channel_picker))
	build_col.add_child(Ui.button_bar([_btn_itch_push, _btn_itch_export, _btn_itch_dry_run,
		_btn_cancel_itch, _btn_itch_status]))
	return _make_platform_tab("itch", "itch.io", "Build itch.io", build_col)


## Rebuild the channel picker from service.itch_channels() (resolved, enabled
## channels), keeping the current choice if that channel still exists — else
## falling back to "All channels".
func _populate_itch_channels(channels: Array) -> void:
	_itch_channels.clear()
	_itch_channel_picker.clear()
	_itch_channel_picker.add_item("All channels", 0)
	var selected_index := 0
	for entry in channels:
		var channel := str(entry.get("channel", ""))
		if channel == "" or _itch_channels.has(channel):
			continue
		_itch_channels.append(channel)
		var preset := str(entry.get("preset", ""))
		_itch_channel_picker.add_item("%s (%s)" % [channel, preset] if preset != "" else channel,
			_itch_channels.size())
		if channel == _selected_itch_channel:
			selected_index = _itch_channels.size()
	if selected_index == 0:
		_selected_itch_channel = ""
	_itch_channel_picker.select(selected_index)


func _on_itch_channel_selected(index: int) -> void:
	_selected_itch_channel = str(_itch_channels[index - 1]) if index >= 1 and index <= _itch_channels.size() else ""


## Shared preflight + build + log layout for one platform tab. `build_col` is
## the caller-assembled build-controls section (its buttons, if any, are
## already added) — this only appends the status line + link bar it shares
## with every platform, then the log panel.
func _make_platform_tab(platform: String, tab_name: String, build_section_title: String, build_col: VBoxContainer) -> Control:
	var root := Ui.split_root(400.0, 460.0)
	root.name = tab_name
	var left: VBoxContainer = root.get_child(0)
	var right: VBoxContainer = root.get_child(1)

	# ── Left: preflight ──
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var rows_box := VBoxContainer.new()
	rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows_box.add_theme_constant_override("separation", 6)
	scroll.add_child(rows_box)
	_rows_box[platform] = rows_box
	var pre_col := VBoxContainer.new()
	pre_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pre_col.add_child(scroll)
	pre_col.add_child(Ui.button_bar([Ui.button("⟳ Refresh preflight", _on_refresh)]))
	left.add_child(Ui.section("Preflight", pre_col, true))

	# ── Right: build + log ──
	var status := Ui.status_label(380.0)
	_status[platform] = status
	var status_links := HBoxContainer.new()
	status_links.add_theme_constant_override("separation", Pal.SEP)
	_status_links[platform] = status_links
	build_col.add_child(status)
	build_col.add_child(status_links)
	right.add_child(Ui.section(build_section_title, build_col))

	var log := TextEdit.new()
	log.editable = false
	log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log.custom_minimum_size = Vector2(0, 160)
	_log[platform] = log
	right.add_child(Ui.section("Log", log, true))
	return root


## A row's platform from its id: "ios.xcode" -> "ios", the global "etc2" -> "".
static func _row_platform(id: String) -> String:
	var dot := id.find(".")
	return id.substr(0, dot) if dot != -1 else ""


## Whether `row` renders in `platform`'s tab: an explicit `platforms` Array
## wins; otherwise the id prefix decides (bare ids render everywhere).
static func _row_in_tab(row: Dictionary, platform: String) -> bool:
	var platforms = row.get("platforms")
	if platforms is Array:
		return (platforms as Array).has(platform)
	var row_platform := _row_platform(str(row["id"]))
	return row_platform == "" or row_platform == platform


## EditorSettings the Android toolchain rows need — build_kit_service can't
## reach EditorInterface (stays headless-testable), so the dock fetches these
## fresh and calls the checks directly.
const ANDROID_SDK_KEY := "export/android/android_sdk_path"
const ANDROID_JDK_KEY := "export/android/java_sdk_path"
const ANDROID_KEYSTORE_KEY := "export/android/debug_keystore"
const ANDROID_KEYSTORE_USER_KEY := "export/android/debug_keystore_user"
const ANDROID_KEYSTORE_PASS_KEY := "export/android/debug_keystore_pass"


static func _editor_setting(settings: EditorSettings, key: String) -> String:
	return str(settings.get_setting(key)) if settings.has_setting(key) else ""


## The four Android rows the service can compute but can't assemble itself.
func _android_settings_rows() -> Array:
	var settings := EditorInterface.get_editor_settings()
	var sdk_path := _editor_setting(settings, ANDROID_SDK_KEY)
	var probe: Dictionary = service.query_adb_devices(sdk_path)
	_devices = probe["devices"]
	var ready := _ready_devices()
	_selected_device = service.reconcile_device_selection(_selected_device, ready)
	return [
		service._check_android_sdk(sdk_path),
		service._check_android_jdk(_editor_setting(settings, ANDROID_JDK_KEY)),
		service._check_android_debug_keystore(
			_editor_setting(settings, ANDROID_KEYSTORE_KEY),
			_editor_setting(settings, ANDROID_KEYSTORE_USER_KEY),
			_editor_setting(settings, ANDROID_KEYSTORE_PASS_KEY)),
		service._check_android_devices(int(probe["code"]), probe["devices"]),
	]


func _ready_devices() -> Array:
	return _devices.filter(func(d): return str(d["state"]) == "device")


## How long a one-off action's feedback (a Fix result, a dropped-file result, an
## immediate start-build error) stays visible before clearing itself. Live
## pipeline state (stage progress, build results) passes duration 0 (the
## default) to stay up — it's already kept current by the next signal, not
## stale the way a rejected button click's message otherwise sits forever.
const STATUS_TOAST_SECONDS := 6.0


func _set_status(platform: String, text: String, color: Color, duration := 0.0) -> void:
	var label: Label = _status.get(platform)
	if label == null:
		return
	label.text = text
	label.add_theme_color_override("font_color", color)
	var timer: Timer = _status_timers.get(platform)
	if timer != null:
		timer.stop()
	if duration > 0.0 and text != "":
		if timer == null:
			timer = Timer.new()
			timer.one_shot = true
			timer.timeout.connect(_on_status_timeout.bind(platform))
			add_child(timer)
			_status_timers[platform] = timer
		timer.start(duration)


func _on_status_timeout(platform: String) -> void:
	var label: Label = _status.get(platform)
	if label != null:
		label.text = ""


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
		_set_status("ios", str(result.get("error", "")), Pal.ERROR, STATUS_TOAST_SECONDS)


func _on_cancel() -> void:
	service.cancel()


func _on_build_android() -> void:
	var settings := EditorInterface.get_editor_settings()
	var sdk_path := _editor_setting(settings, ANDROID_SDK_KEY)
	var result: Dictionary = service.start_build_android(sdk_path, _selected_device)
	if not result.get("ok", false):
		_set_status("android", str(result.get("error", "")), Pal.ERROR, STATUS_TOAST_SECONDS)


func _on_cancel_android() -> void:
	service.cancel()


func _on_build_itch_push() -> void:
	_start_itch("push")


func _on_build_itch_export() -> void:
	_start_itch("export")


func _on_build_itch_dry_run() -> void:
	_start_itch("dry_run")


func _start_itch(mode: String) -> void:
	var result: Dictionary = service.start_build_itch(mode, _selected_itch_channel)
	if not result.get("ok", false):
		_set_status("itch", str(result.get("error", "")), Pal.ERROR, STATUS_TOAST_SECONDS)


func _on_itch_status() -> void:
	var result: Dictionary = service.check_itch_status()
	if not result.get("ok", false):
		_set_status("itch", str(result.get("error", "")), Pal.ERROR, STATUS_TOAST_SECONDS)
		return
	# Same as _on_tf_status: retire the previous verdict while the probe runs.
	_set_status("itch", "Checking itch.io…", Pal.TEXT)
	_fill_links(_status_links["itch"], [])


func _on_tf_status() -> void:
	var result: Dictionary = service.check_testflight_status()
	if not result.get("ok", false):
		_set_status("ios", str(result.get("error", "")), Pal.ERROR, STATUS_TOAST_SECONDS)
		return
	# Retire the previous answer the moment a new probe starts — otherwise the
	# old verdict sits there looking current for the whole round trip.
	_set_status("ios", "Checking TestFlight…", Pal.TEXT)
	_fill_links(_status_links["ios"], [])


func _on_stage_changed(stage: String, platform: String) -> void:
	# One global pipeline — a build on any platform disables every tab's buttons.
	var busy := stage != ""
	_btn_testflight.disabled = busy
	_btn_ipa.disabled = busy
	_btn_cancel.disabled = not busy
	_btn_install.disabled = busy
	_btn_cancel_android.disabled = not busy
	_btn_itch_push.disabled = busy
	_btn_itch_export.disabled = busy
	_btn_itch_dry_run.disabled = busy
	_itch_channel_picker.disabled = busy
	_btn_cancel_itch.disabled = not busy
	if stage != "":
		_set_status(platform, "Running: " + stage + "…", Pal.TEXT)


func _on_log_line(text: String, platform: String) -> void:
	var log: TextEdit = _log.get(platform)
	if log == null:
		return
	log.text += text
	log.scroll_vertical = log.get_line_count()


func _on_build_finished(result: Dictionary, platform: String) -> void:
	if result.get("ok", false):
		_set_status(platform, "✓ " + str(result.get("title", "Done")), Pal.GREEN_SEL)
	else:
		_set_status(platform, "✗ %s — %s" % [result.get("title", "Failed"), result.get("guidance", "")], Pal.ERROR)
	var bar: HBoxContainer = _status_links.get(platform)
	if bar != null:
		_fill_links(bar, result.get("links", []))


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
	var android_rows := _android_settings_rows()
	_populate_itch_channels(service.itch_channels())
	for platform in _rows_box:
		var box: VBoxContainer = _rows_box[platform]
		for child in box.get_children():
			child.queue_free()
		for row in rows:
			if _row_in_tab(row, platform):
				box.add_child(_make_row(row, platform))
		if platform == "android":
			for row in android_rows:
				box.add_child(_make_row(row, platform))


func _make_row(row: Dictionary, platform: String) -> Control:
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
		line.add_child(Ui.button("Fix", _on_fix.bind(str(row["id"]), platform, str(row.get("fix_value", "")))))
	box.add_child(line)

	if str(row["id"]) == "android.devices" and _ready_devices().size() > 1:
		# 0 devices leaves the row's own guidance in place; exactly 1 is used
		# silently — only 2+ ready devices need a target picked.
		box.add_child(_make_device_picker())

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
		if str(row["id"]) == "ios.asc_key":
			box.add_child(_make_asc_key_form())
		if str(row["id"]) == "ios.preset":
			if str(row["status"]) == "fail":
				box.add_child(_make_preset_form())
			elif bool(row.get("fixable", false)) and _teams.size() > 1:
				# The Fix needs a team choice — put the picker right here.
				box.add_child(_make_team_picker())
		if str(row["status"]) != "busy":
			# busy = the async butler-status probe is still deciding; no form yet.
			match str(row["id"]):
				"itch.target":
					box.add_child(_make_itch_target_form())
				"itch.auth":
					box.add_child(_make_butler_key_form())
				"itch.version":
					box.add_child(_make_itch_version_form())
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


## Dropdown of ready adb devices, shown only when 2+ are connected — mirrors
## _make_team_picker().
func _make_device_picker() -> OptionButton:
	var ready := _ready_devices()
	var picker := OptionButton.new()
	for i in ready.size():
		var device: Dictionary = ready[i]
		var label := "%s (%s)" % [device["model"], device["serial"]] if str(device["model"]) != "" else str(device["serial"])
		picker.add_item(label, i)
		if str(device["serial"]) == _selected_device:
			picker.select(i)
	picker.item_selected.connect(_on_device_selected)
	return picker


func _on_device_selected(index: int) -> void:
	var ready := _ready_devices()
	if index >= 0 and index < ready.size():
		_selected_device = str(ready[index]["serial"])


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


## itch.target form: the game's page URL (or `user/game`) → set_itch_target.
func _make_itch_target_form() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Pal.SEP)
	var target := LineEdit.new()
	target.placeholder_text = "https://<user>.itch.io/<game>"
	target.text = _itch_target_text
	target.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	target.text_changed.connect(_on_itch_target_changed)
	row.add_child(target)
	row.add_child(Ui.button("Save", _on_save_itch_target))
	return row


func _on_itch_target_changed(text: String) -> void:
	_itch_target_text = text


func _on_save_itch_target() -> void:
	_show_result(service.set_itch_target(_itch_target_text), "itch")


## itch.auth form: a masked field for the itch.io API key → set_butler_api_key
## (written to the gitignored .env). The held text and the field are cleared as
## soon as Save is pressed, and the key is never echoed to the status or log.
## Below it, "Sign in with browser" runs `butler login` instead (no key to paste).
func _make_butler_key_form() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Pal.SEP)
	var field := LineEdit.new()
	field.secret = true
	field.placeholder_text = "itch.io API key"
	field.text = _butler_key_text
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.text_changed.connect(_on_butler_key_changed)
	row.add_child(field)
	row.add_child(Ui.button("Save", _on_save_butler_key.bind(field),
		"Stored as BUTLER_API_KEY in the project's gitignored .env"))
	var box := VBoxContainer.new()
	box.add_child(row)
	box.add_child(Ui.button_bar([Ui.button("Sign in with browser", _on_butler_login,
		"Runs `butler login`: approve butler on itch.io in your browser and its credentials are saved for every project on this machine")]))
	return box


func _on_butler_login() -> void:
	_show_result(service.start_butler_login(), "itch")


func _on_butler_key_changed(text: String) -> void:
	_butler_key_text = text


func _on_save_butler_key(field: LineEdit) -> void:
	var key := _butler_key_text
	_butler_key_text = ""
	if is_instance_valid(field):
		field.clear()
	_show_result(service.set_butler_api_key(key), "itch")


## itch.version form: application/config/version → set_project_version (sent
## to butler as --userversion).
func _make_itch_version_form() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Pal.SEP)
	var version := LineEdit.new()
	version.placeholder_text = "1.0.0"
	version.text = _itch_version_text
	version.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	version.text_changed.connect(_on_itch_version_changed)
	row.add_child(version)
	row.add_child(Ui.button("Save", _on_save_itch_version))
	return row


func _on_itch_version_changed(text: String) -> void:
	_itch_version_text = text


func _on_save_itch_version() -> void:
	_show_result(service.set_project_version(_itch_version_text), "itch")


## A one-off action's ok()/err() result → that tab's status toast (+ its link
## bar, when the result carries links).
func _show_result(result: Dictionary, platform := "ios") -> void:
	_set_status(platform, str(result.get("message", result.get("error", ""))),
		Pal.TEXT if result.get("ok", false) else Pal.ERROR, STATUS_TOAST_SECONDS)
	var bar: HBoxContainer = _status_links.get(platform)
	if bar != null and result.has("links"):
		_fill_links(bar, result.get("links", []))


## android.sdk/android.jdk write an Editor Setting — apply_fix() can't reach
## EditorInterface, so these two are handled here instead of routed to it.
const ANDROID_EDITOR_SETTING_FIXES := {
	"android.sdk": ANDROID_SDK_KEY,
	"android.jdk": ANDROID_JDK_KEY,
}


func _on_fix(id: String, platform: String, fix_value: String) -> void:
	if ANDROID_EDITOR_SETTING_FIXES.has(id):
		EditorInterface.get_editor_settings().set_setting(ANDROID_EDITOR_SETTING_FIXES[id], fix_value)
		_set_status(platform, "Editor Settings updated: %s" % fix_value, Pal.TEXT, STATUS_TOAST_SECONDS)
		service.refresh_preflight()
		return
	var result: Dictionary = service.apply_fix(id, {"team_id": _selected_team} if id == "ios.preset" else {})
	_set_status(platform, str(result.get("message", result.get("error", ""))),
		Pal.TEXT if result.get("ok", false) else Pal.ERROR, STATUS_TOAST_SECONDS)
