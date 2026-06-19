@tool
extends "res://addons/editor_tool_kit/tool_service.gd"

## The self-update MANAGER service: editor_tool_kit acts as the package manager for
## every vendored addon that opts in with an `[update]` marker in its plugin.cfg
## (see package_registry.gd). One dock, one "Check / Update all", instead of a
## per-addon updater. Each managed addon — including etk itself — is a row.
##
## Source of truth for "what version is upstream" is each addon's own
## `plugin.cfg` `version` on its tracked branch (read raw); installing downloads
## the branch archive zip ONCE per source and extracts every stale addon's subtree
## in a single pass (see update_reload_runner). Bumping an addon's version +
## pushing is what ships it — no GitHub-release ceremony.
##
## HARD RULE (ToolService): holds NO Control / EditorInterface references, so it
## loads under `godot --headless`. The version-parse + compare helpers are static
## so the headless verifier exercises them with no editor and no network; the
## HTTPRequest paths need the scene tree (the service is a plugin child) and are
## simply not driven headless.

const Registry := preload("res://addons/editor_tool_kit/package_registry.gd")

const UPDATE_TEMP_DIR := "user://editor_tool_kit_update/"
const UPDATE_TEMP_ZIP := "user://editor_tool_kit_update/update.zip"

# ── Per-package status (string states so the dock can switch on them) ──────────
const ST_IDLE := "idle"
const ST_CHECKING := "checking"
const ST_UP_TO_DATE := "up_to_date"
const ST_UPDATE_AVAILABLE := "update_available"
const ST_DOWNLOADING := "downloading"
const ST_INSTALLING := "installing"
const ST_ERROR := "error"

## Emitted on every state change; the dock re-renders from `packages` + `message`.
signal changed

## Manager-level summary line for the header, and overall busy state.
var message := ""
var busy := false

## Runtime package rows: each is a Registry descriptor (name/folder/prefix/urls…)
## merged with the mutable fields {installed, latest, state, note}. The dock reads
## these directly. Untyped Array, matching the kit's hot-reload-safe storage.
var packages := []

## Untyped on purpose: the same self-update that overwrites this script also
## overwrites plugin.gd, and a static-typed reference into a script being
## hot-reloaded is part of the crash class.
var _plugin

## In-flight check requests, keyed by package folder → HTTPRequest. Lets several
## addons' version checks run at once and be cleaned up independently.
var _checks := {}
var _dl: HTTPRequest


func setup(plugin) -> void:
	_plugin = plugin
	refresh()


func _exit_tree() -> void:
	## Drop a partial staging zip if torn down mid-download (a successful install is
	## in ST_INSTALLING here, so its zip — which the runner still needs — is left).
	if _is_state(ST_DOWNLOADING):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(UPDATE_TEMP_ZIP))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(UPDATE_TEMP_DIR))


# ── Discovery ─────────────────────────────────────────────────────────────────

## (Re)scan res://addons for managed packages, seeding each row's installed
## version. Preserves any already-known `latest`/`state` for a still-present addon
## so a refresh mid-session doesn't blank the dock.
func refresh() -> void:
	var prev := {}
	for p in packages:
		prev[p["folder"]] = p
	var rows := []
	for desc in Registry.discover():
		var row = desc.duplicate()
		row["installed"] = installed_version(desc["cfg_path"])
		var old = prev.get(desc["folder"])
		row["latest"] = old["latest"] if old else ""
		row["state"] = old["state"] if old else ST_IDLE
		row["note"] = old["note"] if old else ""
		rows.append(row)
	packages = rows
	changed.emit()


## A package's installed version, read from its own plugin.cfg.
static func installed_version(cfg_path: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(cfg_path) != OK:
		return ""
	return str(cfg.get_value("plugin", "version", ""))


func is_busy() -> bool:
	return busy


func has_any_update() -> bool:
	for p in packages:
		if p["state"] == ST_UPDATE_AVAILABLE:
			return true
	return false


# ── Version check ─────────────────────────────────────────────────────────────

func check_all() -> void:
	if busy:
		return
	refresh()
	if packages.is_empty():
		_summary("No managed addons found.")
		return
	for p in packages:
		check_one(p)


func check_one(pkg) -> void:
	## Guard against a re-check of an addon already in flight.
	if _checks.has(pkg["folder"]):
		return
	pkg["state"] = ST_CHECKING
	pkg["note"] = ""
	var http := HTTPRequest.new()
	http.request_completed.connect(_on_check_completed.bind(pkg, http))
	add_child(http)
	_checks[pkg["folder"]] = http
	_recompute_busy()
	var err := http.request(
		pkg["remote_cfg_url"], ["Accept: text/plain", "User-Agent: editor_tool_kit"]
	)
	if err != OK:
		_finish_check(pkg, http, ST_ERROR, "Couldn't start the version check (err %d)" % err)


func _on_check_completed(
	result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, pkg, http
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_finish_check(pkg, http, ST_ERROR, "Check failed (result %d, HTTP %d)" % [result, code])
		return
	var remote := parse_remote_version(body.get_string_from_utf8())
	if remote.is_empty():
		_finish_check(pkg, http, ST_ERROR, "Couldn't read the upstream version")
		return
	pkg["latest"] = remote
	if is_newer(remote, str(pkg["installed"])):
		_finish_check(pkg, http, ST_UPDATE_AVAILABLE, "")
	else:
		_finish_check(pkg, http, ST_UP_TO_DATE, "")


func _finish_check(pkg, http: HTTPRequest, state: String, note: String) -> void:
	pkg["state"] = state
	pkg["note"] = note
	_checks.erase(pkg["folder"])
	if is_instance_valid(http):
		http.queue_free()
	_recompute_busy()
	if _checks.is_empty():
		_summarize_after_check()
	changed.emit()


func _summarize_after_check() -> void:
	var n := 0
	for p in packages:
		if p["state"] == ST_UPDATE_AVAILABLE:
			n += 1
	if n > 0:
		message = "%d update%s available." % [n, "" if n == 1 else "s"]
	else:
		message = "Everything is up to date."


# ── Download + hand-off to the install runner ─────────────────────────────────

func update_one(pkg) -> void:
	_install([pkg])


func update_all() -> void:
	var stale := []
	for p in packages:
		if p["state"] == ST_UPDATE_AVAILABLE:
			stale.append(p)
	_install(stale)


## Download the (shared) branch archive once and hand every package in `list` to
## the reload runner. All packages in a single action must share one archive — the
## common case, since the addons ship from one repo. A mixed set is reported rather
## than silently half-applied.
func _install(list: Array) -> void:
	if busy or list.is_empty():
		return
	if _plugin == null or not _plugin.has_method("install_downloaded_update"):
		_summary("Update host unavailable")
		return
	var archive: String = list[0]["archive_url"]
	for p in list:
		if p["archive_url"] != archive:
			_summary("Selected addons ship from different sources — update them separately.")
			return
	for p in list:
		p["state"] = ST_DOWNLOADING
	_summary("Downloading update…")
	_recompute_busy()

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(UPDATE_TEMP_DIR))
	var zip := ProjectSettings.globalize_path(UPDATE_TEMP_ZIP)
	if _dl != null:
		_dl.queue_free()
	_dl = HTTPRequest.new()
	_dl.download_file = zip
	_dl.max_redirects = 10
	_dl.request_completed.connect(_on_download_completed.bind(list))
	add_child(_dl)
	var err := _dl.request(archive, ["User-Agent: editor_tool_kit"])
	if err != OK:
		## request_completed never fires when request() itself errors — clean up here.
		_dl.queue_free()
		_dl = null
		DirAccess.remove_absolute(zip)
		for p in list:
			p["state"] = ST_ERROR
			p["note"] = "Download couldn't start (err %d)" % err
		_summary("Download couldn't start (err %d)" % err)
		_recompute_busy()


func _on_download_completed(
	result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray, list: Array
) -> void:
	if _dl != null:
		_dl.queue_free()
		_dl = null
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		for p in list:
			p["state"] = ST_ERROR
			p["note"] = "Download failed (result %d, HTTP %d)" % [result, code]
		_summary("Download failed (result %d, HTTP %d)" % [result, code])
		_recompute_busy()
		return
	for p in list:
		p["state"] = ST_INSTALLING
	_summary("Installing… the editor will reload.")
	## Deferred so this HTTP callback returns before the plugin disable + extract
	## begins (the install tears down our own dock and reloads the affected plugins).
	_begin_install.bind(list).call_deferred()


func _begin_install(list: Array) -> void:
	if _plugin == null or not _plugin.has_method("install_downloaded_update"):
		return
	var prefixes := []
	var plugin_cfgs := []
	for p in list:
		prefixes.append(p["prefix"])
		plugin_cfgs.append(p["cfg_path"])
	_plugin.install_downloaded_update(UPDATE_TEMP_ZIP, UPDATE_TEMP_DIR, prefixes, plugin_cfgs)


# ── State helpers ─────────────────────────────────────────────────────────────

func _summary(msg: String) -> void:
	message = msg
	changed.emit()


func _recompute_busy() -> void:
	var b := not _checks.is_empty() or _dl != null
	if not b:
		for p in packages:
			if p["state"] == ST_DOWNLOADING or p["state"] == ST_INSTALLING:
				b = true
				break
	busy = b


func _is_state(state: String) -> bool:
	for p in packages:
		if p["state"] == state:
			return true
	return false


# ── Pure helpers (static; the verifier drives them with literal strings) ──────

## Reads the `version` out of a plugin.cfg's raw text.
static func parse_remote_version(cfg_text: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.parse(cfg_text) != OK:
		return ""
	return str(cfg.get_value("plugin", "version", ""))


## Dotted-version compare: true iff `remote` is strictly newer than `local`.
## Missing trailing components count as 0 (so "0.2" > "0.1.9").
static func is_newer(remote: String, local: String) -> bool:
	var r := str(remote).split(".")
	var l := str(local).split(".")
	for i in range(max(r.size(), l.size())):
		var rv := int(r[i]) if i < r.size() else 0
		var lv := int(l[i]) if i < l.size() else 0
		if rv > lv:
			return true
		if rv < lv:
			return false
	return false
