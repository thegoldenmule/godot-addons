@tool
class_name RemoteConfigService
extends "res://addons/editor_tool_kit/tool_service.gd"

## Headless-testable core for the Remote Config authoring tool (a ToolService).
## The SINGLE aggregation point for a backend "remote config" document: it reads a
## committed manifest + every entry's content blob, builds the WHOLE document,
## copies the full publish payload, and (optionally) checks live drift by shelling
## out to ONE external comparator the consuming project supplies — never
## reimplementing the compare in GDScript.
##
## GAME-AGNOSTIC: nothing here is hardcoded to a particular project, backend, or
## directory layout. Every project-specific value — where the manifest + blobs
## live, what command verifies live drift, and the labels shown in the dock — comes
## from a consuming-project config file (CONFIG_PATH) that lives OUTSIDE this addon
## folder, so self-update never clobbers it. See config.example.json + the README.
##
## No Control / EditorInterface references (it loads under godot --headless); the
## only editor-side seams are OS.execute (check_sync) and DisplayServer.clipboard_set
## (copy_publish_payload), both harmless headless. build_document() / versions() /
## validate() are pure reads the verifier asserts directly via reload_from().

const ContentStore := preload("res://addons/editor_tool_kit/content_store.gd")

## The consuming project's config, read from res:// root (NOT from inside this
## addon — a self-update overwrites the addon folder but never this file).
const CONFIG_PATH := "res://remote_config_editor.config.json"

## Defaults applied over a missing/sparse config so a fresh, unconfigured install
## degrades gracefully instead of erroring.
const DEFAULTS := {
	"root": "res://",                              # base every relative path resolves against
	"manifest": "",                               # relative path to the manifest JSON (required)
	"content_dir": "",                            # relative dir holding the content blobs (required)
	"doc_version_field": "app_config_version",    # manifest field naming the document version
	"document_label": "config document",          # noun used in dock messages
	"publish_target": "your Remote Config backend", # where the operator pastes the payload
	"sync": {},                                   # {program, args, hint} — absent ⇒ no drift check
}

## Emitted after reload so the dock rebuilds its table + preview.
signal changed

var config: Dictionary = {}      # the merged consuming-project config (defaults applied)
var manifest: Dictionary = {}    # {<doc_version_field>, entries:[{key,file,version_field,label}]}
var blobs: Dictionary = {}       # key -> parsed content Dictionary ({} when missing/unparseable)
var blobs_raw: Dictionary = {}   # key -> RAW on-disk JSON text ("" when missing) — published verbatim
var _content_dir := ""           # absolute dir the blobs were loaded from (for validate's re-stat)
var _content_label := ""         # human-facing dir shown in validate messages (relative, not abs)
var _config_error := ""          # a structural config problem (e.g. content_dir unset) — surfaced by validate()


# ── config ───────────────────────────────────────────────────────────────────--


## Load + merge the consuming-project config over DEFAULTS. Missing file ⇒ pure
## defaults (the dock then prompts the operator to author one). Pure read; no
## editor APIs, so the verifier can call it headless.
func load_config() -> Dictionary:
	config = DEFAULTS.duplicate(true)
	config.merge(ContentStore.load_json(_resolve(CONFIG_PATH)), true)
	return config


## True when the config supplies a drift-check command (so the dock shows Check
## Sync). A project that only aggregates + copies leaves "sync" out.
func has_sync() -> bool:
	var sync = config.get("sync", {})
	return sync is Dictionary and str(sync.get("program", "")) != ""


## True once a usable manifest path is configured — distinguishes "fresh install,
## author a config" from "configured but the manifest has problems".
func is_configured() -> bool:
	return str(config.get("manifest", "")) != ""


func document_label() -> String:
	return str(config.get("document_label", DEFAULTS["document_label"]))


func publish_target() -> String:
	return str(config.get("publish_target", DEFAULTS["publish_target"]))


# ── load ───────────────────────────────────────────────────────────────────────


## Load the committed manifest + every blob from the configured project paths. The
## dock drives the rebuild on `changed`.
func reload() -> void:
	load_config()
	_config_error = ""
	var root := _resolve(str(config.get("root", "res://")))
	var manifest_rel := str(config.get("manifest", ""))
	var content_rel := str(config.get("content_dir", ""))
	# A configured manifest with no content_dir is a config error, not a fresh
	# install — surface it clearly instead of leaking an absolute path into validate().
	if manifest_rel != "" and content_rel == "":
		_config_error = "content_dir not set in %s" % CONFIG_PATH
	# Pass the relative content dir as the message label so validate()'s
	# file-not-found text reads as a repo-relative path, not a machine-absolute one.
	reload_from(root.path_join(manifest_rel), root.path_join(content_rel), content_rel)


## Load core, parameterized by absolute paths so the headless verifier drives a
## temp dir with no config file. `content_label` is the human-facing dir name shown
## in validate() messages; it defaults to the absolute dir when omitted. Caches both
## the parsed blob (for validation/versions) and its RAW text (published verbatim).
## Does NOT touch _config_error — only reload() sets it from the config.
func reload_from(manifest_abs: String, content_dir_abs: String, content_label := "") -> void:
	_content_dir = content_dir_abs
	_content_label = content_label if content_label != "" else content_dir_abs
	manifest = ContentStore.load_json(manifest_abs)
	blobs.clear()
	blobs_raw.clear()
	for e in _entries():
		var key := str(e.get("key", ""))
		var path := content_dir_abs.path_join(str(e.get("file", "")))
		blobs[key] = ContentStore.load_json(path)
		blobs_raw[key] = _read_text(path)
	clear_dirty()
	changed.emit()


## The manifest's entries array ([] when absent/malformed).
func _entries() -> Array:
	var e = manifest.get("entries", [])
	return e if e is Array else []


## The configured document-version field's value ("" when absent). Defaults to the
## "app_config_version" field but the consuming project can rename it.
func app_config_version() -> String:
	return str(manifest.get(str(config.get("doc_version_field", DEFAULTS["doc_version_field"])), ""))


# ── aggregation (pure) ──────────────────────────────────────────────────────────


## THE single aggregation point (parsed form): { <key>: <blob>, … } for every
## manifest entry whose blob is present, in manifest order. Pure (reads only
## manifest + blobs). Used for structural reads (key set, presence, count) and the
## table — NOT for the published text, which must preserve on-disk numeric
## formatting (see build_document_text). Godot parses every JSON number as a float,
## so this dict says 1.0 where the file says 1.
func build_document() -> Dictionary:
	var doc := {}
	for e in _entries():
		var key := str(e.get("key", ""))
		var b: Dictionary = blobs.get(key, {})
		if key != "" and not b.is_empty():   # missing blobs are blocked by validate()
			doc[key] = b
	return doc


## The EXACT text published — the whole document assembled by splicing each present
## blob's RAW on-disk JSON verbatim, so integers, 64-bit IDs, key order, and
## formatting survive byte-for-byte. Re-serializing the parsed form (build_document)
## would coerce every int to a float (1 → 1.0) and lose precision past 2^53, which
## is wrong for any backend that distinguishes int/float or uses large IDs. The
## blob lines are re-indented one level under the 2-space outer object. "{}" when
## nothing is present.
func build_document_text() -> String:
	var parts: Array = []
	for e in _entries():
		var key := str(e.get("key", ""))
		var b: Dictionary = blobs.get(key, {})
		if key != "" and not b.is_empty():   # mirror build_document's present-only set
			var raw := str(blobs_raw.get(key, "")).strip_edges()
			parts.append("  %s: %s" % [JSON.stringify(key), raw.replace("\n", "\n  ")])
	if parts.is_empty():
		return "{}"
	return "{\n" + ",\n".join(parts) + "\n}"


## Per-key rollup for the dock table: [{key, file, label, present, version}].
func versions() -> Array:
	var out: Array = []
	for e in _entries():
		var key := str(e.get("key", ""))
		var vfield := str(e.get("version_field", ""))
		var b: Dictionary = blobs.get(key, {})
		out.append({
			"key": key,
			"file": str(e.get("file", "")),
			"label": str(e.get("label", key)),
			"present": not b.is_empty(),
			"has_version": b.has(vfield),   # distinguish "absent field" from a real 0
			"version": int(b.get(vfield, 0)),
		})
	return out


## Structural problems ([] == publishable). Manifest missing/empty; per entry a
## missing file, an unparseable/empty blob, or a missing/non-int version field;
## and any duplicate key across the manifest.
func validate() -> Array:
	if _config_error != "":
		return [_config_error]
	var problems: Array = []
	if _entries().is_empty():
		problems.append("manifest missing or has no entries (%s)" % _content_label)
		return problems
	var seen := {}
	for e in _entries():
		var key := str(e.get("key", ""))
		var file := str(e.get("file", ""))
		var vfield := str(e.get("version_field", ""))
		if key == "" or file == "" or vfield == "":
			problems.append("manifest entry missing key/file/version_field: %s" % str(e))
			continue
		if seen.has(key):
			problems.append("%s: duplicate key in manifest" % key)
		seen[key] = true
		var path := _content_dir.path_join(file)
		if not FileAccess.file_exists(path):
			problems.append("%s: content file not found (%s)" % [key, _content_label.path_join(file)])
			continue
		var b: Dictionary = blobs.get(key, {})
		if b.is_empty():
			problems.append("%s: blob absent or not a JSON object (%s)" % [key, _content_label.path_join(file)])
			continue
		if not b.has(vfield) or not (typeof(b[vfield]) == TYPE_INT or typeof(b[vfield]) == TYPE_FLOAT):
			problems.append("%s: missing integer version field \"%s\"" % [key, vfield])
	return problems


# ── publish / verify (editor-side seams) ────────────────────────────────────────


## Copy the WHOLE document to the clipboard for a manual console paste. Gated on
## validate() so a structurally-broken document never reaches the clipboard (and a
## single-key paste can never silently drop a sibling). The text is the verbatim
## raw-blob splice (build_document_text), so pasted values match the committed
## source byte-for-byte. Returns {ok:true, keys, count, bytes} or err(joined problems).
func copy_publish_payload() -> Dictionary:
	var problems := validate()
	if not problems.is_empty():
		return err("\n".join(problems))
	var doc := build_document()
	var text := build_document_text()
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		DisplayServer.clipboard_set(text)   # no-op under the headless verifier
	return ok({"keys": doc.keys(), "count": doc.size(), "bytes": text.length()})


## Check the live config against the committed blobs by shelling out to the ONE
## external comparator the consuming project configures (config.sync) — no second
## comparator in GDScript. The command MUST print one JSON object carrying a
## "results" array (per-key {key, status, committed_version, live_version}); other
## stdout lines are treated as plain logs. {root} in any arg is replaced with the
## resolved root dir. Returns {ok, code, results, error, text}. code -1 = the sync
## program is missing or unconfigured (surfaced as a hint by the dock).
func check_sync() -> Dictionary:
	if not has_sync():
		return {"ok": false, "code": -1, "results": [], "error": "no sync command configured", "text": ""}
	var sync: Dictionary = config.get("sync", {})
	var root := _resolve(str(config.get("root", "res://")))
	var args: Array = []
	for a in sync.get("args", []):
		args.append(str(a).replace("{root}", root))
	var out: Array = []
	var code := OS.execute(str(sync.get("program", "")), args, out, true)
	var text := "\n".join(out).strip_edges() if out.size() > 0 else ""
	var results: Array = []
	var error := ""
	# Scan for the first parseable line carrying "results" (other lines are plain
	# logs) and stop there. On a login/HTTP failure the tool prints {ok:false,error,results:[]}.
	# Only object-looking lines are parsed, so a comparator's log lines don't spam
	# the editor console with JSON parse errors.
	for line in text.split("\n"):
		var trimmed := line.strip_edges()
		if not trimmed.begins_with("{"):
			continue
		var parsed = JSON.parse_string(trimmed)
		if parsed is Dictionary and parsed.has("results"):
			results = parsed.get("results", [])
			error = str(parsed.get("error", ""))
			break
	return {"ok": code == 0, "code": code, "results": results, "error": error, "text": text}


## The drift-check hint the dock shows when the sync command can't be run ("" when
## none configured).
func sync_hint() -> String:
	var sync = config.get("sync", {})
	return str(sync.get("hint", "")) if sync is Dictionary else ""


# ── helpers ──────────────────────────────────────────────────────────────────--


## Resolve a config path to an absolute OS path. `res://`/`user://` are globalized;
## an already-absolute path is kept; anything else is treated as relative to the
## project directory (res://). This is what lets `root` be "res://.." for a project
## nested one level under its repo root, or just "res://" for a flat project.
static func _resolve(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path).simplify_path()
	if path.is_absolute_path():
		return path.simplify_path()
	return ProjectSettings.globalize_path("res://").path_join(path).simplify_path()


## Raw text of a file ("" when missing/unreadable) — the verbatim bytes published,
## so on-disk numeric formatting survives (ContentStore.load_json would lose it).
static func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""
