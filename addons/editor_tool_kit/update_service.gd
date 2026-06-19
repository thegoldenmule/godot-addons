@tool
extends "res://addons/editor_tool_kit/tool_service.gd"

## Self-update service for the editor_tool_kit addon. Mirrors the godot-ai model:
## the kit is committed into the consuming project (so a fresh clone works
## offline) but is *sourced* from a standalone repo, and this service checks that
## repo for a newer version and pulls it in place.
##
## Source of truth for "what version is upstream" is the repo's
## `addons/editor_tool_kit/plugin.cfg` `version` on BRANCH — bumping it and
## pushing is what ships an update; no GitHub release ceremony required. The
## check reads that file raw; the install downloads the branch archive zip and
## extracts only the `addons/editor_tool_kit/` subtree (see update_reload_runner).
##
## HARD RULE (ToolService): holds NO Control / EditorInterface references, so it
## loads under `godot --headless`. The version-parse + compare helpers are static
## so the headless verifier exercises them with no editor and no network; the
## HTTPRequest paths need the scene tree (the service has it as a plugin child)
## and are simply not driven headless. The EditorSettings-backed "auto-check"
## preference lives in the plugin/panel, which legitimately touch EditorInterface.

# ── Source repo ───────────────────────────────────────────────────────────────
const REPO_OWNER := "thegoldenmule"
const REPO_NAME := "godot-addons"
const BRANCH := "main"
const REPO_PAGE := "https://github.com/thegoldenmule/godot-addons"
## Raw plugin.cfg on the tracked branch — the version source of truth.
const REMOTE_CFG_URL := "https://raw.githubusercontent.com/thegoldenmule/godot-addons/main/addons/editor_tool_kit/plugin.cfg"
## Branch tarball (redirects to codeload; HTTPRequest follows with max_redirects).
const ARCHIVE_URL := "https://github.com/thegoldenmule/godot-addons/archive/refs/heads/main.zip"

const LOCAL_CFG_PATH := "res://addons/editor_tool_kit/plugin.cfg"
const UPDATE_TEMP_DIR := "user://editor_tool_kit_update/"
const UPDATE_TEMP_ZIP := "user://editor_tool_kit_update/update.zip"

# ── Status machine (string states so the dock can switch on them) ─────────────
const ST_IDLE := "idle"
const ST_CHECKING := "checking"
const ST_UP_TO_DATE := "up_to_date"
const ST_UPDATE_AVAILABLE := "update_available"
const ST_DOWNLOADING := "downloading"
const ST_INSTALLING := "installing"
const ST_ERROR := "error"

## Emitted on every state change; the dock re-renders from the public fields.
signal changed

var status := ST_IDLE
var latest_version := ""
var message := ""

## Untyped on purpose: the same self-update window that overwrites this script
## also overwrites plugin.gd, and a static-typed reference into a script being
## hot-reloaded is part of the crash class (see update_manager.gd in godot-ai).
var _plugin

var _http: HTTPRequest
var _dl: HTTPRequest


func setup(plugin) -> void:
	_plugin = plugin


func _exit_tree() -> void:
	## If the editor tears the service down mid-download (plugin disabled, editor
	## quitting), drop the partial staging file so it doesn't linger in user://.
	## A leftover could never be installed anyway — the runner validates the
	## archive before touching the tree — this is just hygiene. A successful
	## update is in ST_INSTALLING here, not ST_DOWNLOADING, so the zip the runner
	## still needs is left in place.
	if status == ST_DOWNLOADING:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(UPDATE_TEMP_ZIP))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(UPDATE_TEMP_DIR))


## This addon's own installed version, read from its plugin.cfg.
func installed_version() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(LOCAL_CFG_PATH) != OK:
		return ""
	return str(cfg.get_value("plugin", "version", ""))


func is_busy() -> bool:
	return status == ST_CHECKING or status == ST_DOWNLOADING or status == ST_INSTALLING


func has_update() -> bool:
	return status == ST_UPDATE_AVAILABLE


# ── Version check ─────────────────────────────────────────────────────────────

func check_for_updates() -> void:
	if is_busy():
		return
	_set_state(ST_CHECKING, "Checking %s…" % REPO_NAME)
	if _http == null:
		_http = HTTPRequest.new()
		_http.request_completed.connect(_on_check_completed)
		add_child(_http)
	# A no-op when nothing is in flight; guards against ERR_BUSY on a re-check.
	_http.cancel_request()
	var err := _http.request(
		REMOTE_CFG_URL, ["Accept: text/plain", "User-Agent: editor_tool_kit"]
	)
	if err != OK:
		_set_state(ST_ERROR, "Couldn't start the version check (err %d)" % err)


func _on_check_completed(
	result: int, code: int, _headers: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_set_state(ST_ERROR, "Version check failed (result %d, HTTP %d)" % [result, code])
		return
	var remote := parse_remote_version(body.get_string_from_utf8())
	if remote.is_empty():
		_set_state(ST_ERROR, "Couldn't read the upstream version")
		return
	latest_version = remote
	var local := installed_version()
	if is_newer(remote, local):
		_set_state(
			ST_UPDATE_AVAILABLE, "Update available: v%s (installed v%s)" % [remote, local]
		)
	else:
		_set_state(ST_UP_TO_DATE, "Up to date (v%s)" % local)


# ── Download + hand-off to the install runner ─────────────────────────────────

func start_update() -> void:
	if status != ST_UPDATE_AVAILABLE:
		return
	if _plugin == null or not _plugin.has_method("install_downloaded_update"):
		_set_state(ST_ERROR, "Update host unavailable")
		return
	_set_state(ST_DOWNLOADING, "Downloading v%s…" % latest_version)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(UPDATE_TEMP_DIR))
	var zip := ProjectSettings.globalize_path(UPDATE_TEMP_ZIP)
	if _dl != null:
		_dl.queue_free()
	_dl = HTTPRequest.new()
	_dl.download_file = zip
	_dl.max_redirects = 10
	_dl.request_completed.connect(_on_download_completed)
	add_child(_dl)
	var err := _dl.request(ARCHIVE_URL, ["User-Agent: editor_tool_kit"])
	if err != OK:
		## request_completed never fires when request() itself errors, so clean
		## up inline rather than leaking the HTTPRequest + a partial zip.
		_dl.queue_free()
		_dl = null
		DirAccess.remove_absolute(zip)
		_set_state(ST_ERROR, "Download couldn't start (err %d)" % err)


func _on_download_completed(
	result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray
) -> void:
	if _dl != null:
		_dl.queue_free()
		_dl = null
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_set_state(ST_ERROR, "Download failed (result %d, HTTP %d)" % [result, code])
		return
	_set_state(ST_INSTALLING, "Installing v%s… the editor will reload." % latest_version)
	## Deferred so this HTTP callback returns before the plugin disable + extract
	## begins (the install tears down our own dock and reloads this plugin).
	_begin_install.call_deferred()


func _begin_install() -> void:
	if _plugin != null and _plugin.has_method("install_downloaded_update"):
		_plugin.install_downloaded_update(UPDATE_TEMP_ZIP, UPDATE_TEMP_DIR)


# ── State + pure helpers ──────────────────────────────────────────────────────

func _set_state(new_status: String, msg: String = "") -> void:
	status = new_status
	message = msg
	changed.emit()


## Reads the `version` out of a plugin.cfg's raw text. Static + ConfigFile.parse
## so the verifier drives it with a literal string (no editor, no network).
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
