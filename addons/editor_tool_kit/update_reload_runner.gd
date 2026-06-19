@tool
extends Node

## Self-update install runner for editor_tool_kit. Adapted from godot-ai's
## update_reload_runner: a Node parented OUTSIDE the plugin (so it survives
## set_plugin_enabled(false)) that owns the install-and-reload sequence —
## disable the plugin, extract the addon subtree from the downloaded repo
## archive, wait for a filesystem scan, then re-enable the plugin so the editor
## reloads the new scripts.
##
## Only files under `addons/editor_tool_kit/` in the archive are touched: the
## repo's top-level files (its own README, .gitignore, …) and everything else in
## the consuming project are left alone. Extract overwrites + adds; it never
## prunes, so a file removed upstream lingers until deleted by hand (same
## limitation as the godot-ai updater).
##
## Each file is written via `.tmp` + atomic rename with a per-file backup, and
## any mid-batch failure rolls every already-written file back to its previous
## contents. If the rollback ITSELF can't fully restore (FAILED_MIXED), the
## runner refuses to re-enable the plugin and leaves it disabled — a failed
## update never loads a half-installed tree.
##
## Frame-waiting + call_deferred between every step keeps the runner off the
## stack while the filesystem scan reloads scripts (this very script is among the
## files overwritten); the reload lands between steps, never mid-method. Fields
## are kept untyped where they survive that scan, matching the codebase's
## hot-reload-safe storage convention.

const PLUGIN_CFG_PATH := "res://addons/editor_tool_kit/plugin.cfg"
const INSTALL_BASE := "res://"
const ADDON_REL_PREFIX := "addons/editor_tool_kit/"
const TEMP_SUFFIX := ".etk_update_tmp"
const BACKUP_SUFFIX := ".etk_update_backup"
const PRE_DISABLE_FRAMES := 8
const POST_DISABLE_FRAMES := 2
const POST_ENABLE_FRAMES := 8
const SCAN_WATCHDOG_SECS := 30.0

## Extract outcome. OK: every listed file replaced. FAILED_CLEAN: a write failed
## but every already-written file was rolled back to its previous content (or
## removed, if new) — safe to re-enable the previous plugin. FAILED_MIXED:
## rollback itself failed, so the addon tree is a mix of old + new — the runner
## MUST NOT re-enable the plugin.
enum InstallStatus { OK, FAILED_CLEAN, FAILED_MIXED }

var _zip_path := ""
var _temp_dir := ""
var _detached = null
var _started := false
var _next_step := ""
var _frames := 0
var _waiting_for_scan := false
var _scan_timed_out := false
var _scan_next := ""
var _watchdog = null
## Per-file install records: {target, backup, had_original}. Untyped Array —
## survives fs.scan() during the update.
var _written = []
## Set when _install_one's inner restore-from-backup can't complete: the failed
## target is then NOT recorded in _written, so _rollback can't see it — this flag
## promotes the outcome to FAILED_MIXED. Mirrors godot-ai's _restore_failed.
var _restore_failed := false


func start(zip_path: String, temp_dir: String, detached) -> void:
	if _started:
		return
	_started = true
	_zip_path = zip_path
	_temp_dir = temp_dir
	_detached = detached
	_wait_frames(PRE_DISABLE_FRAMES, "_disable_plugin")


# ── Frame waiter (lets deferred teardown drain between steps) ─────────────────

func _process(_delta: float) -> void:
	if _frames <= 0:
		set_process(false)
		return
	_frames -= 1
	if _frames <= 0:
		var step := _next_step
		_next_step = ""
		set_process(false)
		call(step)


func _wait_frames(frame_count: int, next_step: String) -> void:
	_next_step = next_step
	_frames = max(1, frame_count)
	set_process(true)


# ── Pipeline ──────────────────────────────────────────────────────────────────

func _disable_plugin() -> void:
	print("editor_tool_kit | update: disabling current plugin")
	EditorInterface.set_plugin_enabled(PLUGIN_CFG_PATH, false)
	_wait_frames(POST_DISABLE_FRAMES, "_extract")


func _extract() -> void:
	var status := _do_extract()
	if status == InstallStatus.OK:
		_cleanup_temp()
		## One scan after all writes: Godot's scan-time reparse then sees a single
		## consistent v(N+1) snapshot, so new + existing files resolve each other.
		_scan("_enable_plugin")
		return
	if status == InstallStatus.FAILED_MIXED:
		## Rollback couldn't fully restore the previous files: the addon tree is a
		## mix of old + new and loading it would run mismatched scripts. Leave the
		## plugin DISABLED and tell the user to recover by hand — the repo (and
		## git) is the source of truth. *.etk_update_backup files are left on disk
		## as a manual recovery aid.
		push_error(
			"editor_tool_kit | self-update failed AND rollback could not restore the "
			+ "previous files. The plugin is left disabled — restore "
			+ "addons/editor_tool_kit/ from git (or re-copy it from the repo), then "
			+ "re-enable the plugin. Look for *.etk_update_backup files to recover."
		)
		_wait_frames(POST_ENABLE_FRAMES, "_finish")
		return
	## FAILED_CLEAN: every written file was rolled back; bring the previous
	## plugin version back so the kit isn't left disabled.
	push_error("editor_tool_kit | self-update failed; rolled back, re-enabling the current version")
	EditorInterface.set_plugin_enabled(PLUGIN_CFG_PATH, true)
	_wait_frames(POST_ENABLE_FRAMES, "_finish")


func _do_extract() -> int:
	var zip := ProjectSettings.globalize_path(_zip_path)
	var reader := ZIPReader.new()
	if reader.open(zip) != OK:
		push_error("editor_tool_kit | update: could not open %s" % zip)
		return InstallStatus.FAILED_CLEAN
	var base := ProjectSettings.globalize_path(INSTALL_BASE)

	# Map every addon archive entry to a project path, rejecting unsafe paths and
	# refusing an archive that maps two entries onto one target (which would
	# corrupt the per-file backup/rollback bookkeeping).
	var jobs := []
	var seen := {}
	var has_cfg := false
	var has_plugin := false
	for entry in reader.get_files():
		if entry.ends_with("/"):
			continue
		var rel := _archive_rel(entry)
		if rel.is_empty():
			continue
		if not _is_safe(rel):
			push_error("editor_tool_kit | update: refusing unsafe path %s" % entry)
			reader.close()
			return InstallStatus.FAILED_CLEAN
		if seen.has(rel):
			push_error("editor_tool_kit | update: archive maps two entries onto %s — aborting" % rel)
			reader.close()
			return InstallStatus.FAILED_CLEAN
		seen[rel] = true
		if rel == ADDON_REL_PREFIX + "plugin.cfg":
			has_cfg = true
		elif rel == ADDON_REL_PREFIX + "plugin.gd":
			has_plugin = true
		jobs.append({"entry": entry, "rel": rel})

	if not has_cfg or not has_plugin:
		push_error("editor_tool_kit | update: archive is missing plugin.cfg / plugin.gd")
		reader.close()
		return InstallStatus.FAILED_CLEAN

	_written.clear()
	_restore_failed = false
	for job in jobs:
		if not _install_one(reader, String(job["entry"]), String(job["rel"]), base):
			reader.close()
			var clean := _rollback()
			if clean and not _restore_failed:
				return InstallStatus.FAILED_CLEAN
			return InstallStatus.FAILED_MIXED
	reader.close()
	_finalize_success()
	return InstallStatus.OK


func _install_one(reader: ZIPReader, entry: String, rel: String, base: String) -> bool:
	var target := base.path_join(rel)
	var dir := target.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		print("editor_tool_kit | update: could not create %s" % dir)
		return false

	var tmp := target + TEMP_SUFFIX
	DirAccess.remove_absolute(tmp)
	var content := reader.read_file(entry)
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		print("editor_tool_kit | update: could not write %s" % tmp)
		return false
	f.store_buffer(content)
	var write_error := f.get_error()
	f.close()
	if write_error != OK:
		DirAccess.remove_absolute(tmp)
		return false

	## Back up the original via COPY (not rename) so the source stays in place
	## until the rename succeeds; rolled back by `_rollback` on a later failure.
	var had_original := FileAccess.file_exists(target)
	var backup := target + BACKUP_SUFFIX
	if had_original:
		DirAccess.remove_absolute(backup)
		if DirAccess.copy_absolute(target, backup) != OK:
			DirAccess.remove_absolute(tmp)
			print("editor_tool_kit | update: could not back up %s" % target)
			return false

	if DirAccess.rename_absolute(tmp, target) != OK:
		## Some filesystems reject rename-over-existing; remove then retry so the
		## common path never exposes a truncated target.
		DirAccess.remove_absolute(target)
		if DirAccess.rename_absolute(tmp, target) != OK:
			DirAccess.remove_absolute(tmp)
			## target was removed above; restore it from the COPY backup so the
			## tree is left in its previous state. If that restore can't complete,
			## the target is now missing AND unrecorded in _written — flag
			## FAILED_MIXED so the runner refuses to re-enable a half-installed tree.
			if had_original:
				if FileAccess.file_exists(backup) and DirAccess.copy_absolute(backup, target) == OK:
					DirAccess.remove_absolute(backup)
				else:
					_restore_failed = true
			print("editor_tool_kit | update: could not replace %s" % target)
			return false
	_written.append({"target": target, "backup": backup, "had_original": had_original})
	return true


## Restore (or delete) every file already written this update, newest first.
## Returns true iff every restore succeeded (a clean rollback); false leaves the
## tree mixed and the caller must not re-enable the plugin.
func _rollback() -> bool:
	var ok := true
	var i := _written.size() - 1
	while i >= 0:
		var rec = _written[i]
		var target := String(rec["target"])
		var backup := String(rec["backup"])
		if bool(rec["had_original"]):
			if not FileAccess.file_exists(backup):
				push_error("editor_tool_kit | rollback: backup missing for %s" % target)
				ok = false
			else:
				DirAccess.remove_absolute(target)
				if DirAccess.copy_absolute(backup, target) != OK:
					push_error("editor_tool_kit | rollback: could not restore %s" % target)
					ok = false
				else:
					DirAccess.remove_absolute(backup)
		else:
			if FileAccess.file_exists(target) and DirAccess.remove_absolute(target) != OK:
				push_error("editor_tool_kit | rollback: could not delete %s" % target)
				ok = false
		i -= 1
	_written.clear()
	return ok


## Drop the per-file backups after a fully successful install. Best-effort — a
## stray backup is cosmetic, not a correctness problem.
func _finalize_success() -> void:
	for rec in _written:
		if bool(rec["had_original"]):
			DirAccess.remove_absolute(String(rec["backup"]))
	_written.clear()


## Map a zip entry to its project-relative addon path, or "" if it is not part of
## the addon. Accepts `addons/editor_tool_kit/...` directly and the GitHub
## branch-archive shape `<wrapper>/addons/editor_tool_kit/...` (exactly one
## leading directory segment), but rejects deeper nesting like
## `<wrapper>/templates/addons/editor_tool_kit/...` — so _is_safe()'s begins_with
## stays a real guard and a stray nested copy elsewhere in the repo can't be
## written into the live addon. Static so the verifier exercises it headless.
static func _archive_rel(entry: String) -> String:
	if entry.begins_with(ADDON_REL_PREFIX):
		return entry
	var slash := entry.find("/")
	if slash >= 0 and entry.substr(slash + 1).begins_with(ADDON_REL_PREFIX):
		return entry.substr(slash + 1)
	return ""


## Static so the verifier exercises the path-traversal guard headless.
static func _is_safe(rel: String) -> bool:
	if rel.is_absolute_path() or rel.contains("\\"):
		return false
	if not rel.begins_with(ADDON_REL_PREFIX):
		return false
	for seg in rel.split("/", true):
		if seg.is_empty() or seg == "." or seg == "..":
			return false
	return true


func _cleanup_temp() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_zip_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_temp_dir))


# ── Filesystem scan (with a watchdog so a stuck signal can't hang the runner) ─

func _scan(next_step: String) -> void:
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null or _scan_timed_out:
		call_deferred(next_step)
		return
	_waiting_for_scan = true
	_scan_next = next_step
	if not fs.filesystem_changed.is_connected(_on_scanned):
		fs.filesystem_changed.connect(_on_scanned, CONNECT_ONE_SHOT)
	_arm_watchdog()
	fs.scan()


func _on_scanned() -> void:
	_finish_scan()


func _finish_scan() -> void:
	if not _waiting_for_scan:
		return
	_waiting_for_scan = false
	if _watchdog != null:
		_watchdog.stop()
	var next_step := _scan_next
	_scan_next = ""
	if next_step.is_empty():
		next_step = "_enable_plugin"
	call_deferred(next_step)


func _arm_watchdog() -> void:
	if _watchdog == null:
		_watchdog = Timer.new()
		_watchdog.one_shot = true
		_watchdog.timeout.connect(_on_watchdog_timeout)
		add_child(_watchdog)
	_watchdog.start(SCAN_WATCHDOG_SECS)


func _on_watchdog_timeout() -> void:
	if not _waiting_for_scan:
		return
	_scan_timed_out = true
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null and fs.filesystem_changed.is_connected(_on_scanned):
		fs.filesystem_changed.disconnect(_on_scanned)
	push_warning(
		"editor_tool_kit | update: filesystem scan didn't confirm within %ds; proceeding"
		% int(SCAN_WATCHDOG_SECS)
	)
	_finish_scan()


func _enable_plugin() -> void:
	print("editor_tool_kit | update: enabling the new plugin version")
	EditorInterface.set_plugin_enabled(PLUGIN_CFG_PATH, true)
	_wait_frames(POST_ENABLE_FRAMES, "_finish")


func _finish() -> void:
	## `_detached` is null in the current integration (the plugin frees its own
	## panel before starting the runner); the guard keeps the runner reusable for
	## a caller that hands a live control across the reload.
	if _detached != null and is_instance_valid(_detached):
		_detached.queue_free()
	_detached = null
	queue_free()
