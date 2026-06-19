@tool
class_name ContentStore
extends RefCounted

## Static helpers for the load → validate → atomic N-target write → rescan
## pipeline that committed-content authoring tools share — e.g. a tool that writes
## a baked + canonical + layout copy in sync. Never instantiated.
##
## The canonical-serialize contract (stable key order, integer coercion, sparse
## fields) is documented here but the actual serializer stays per-tool, since
## field order is domain-specific. ContentStore only owns the load + atomic
## multi-file write + version-bump-with-rollback.


## Parse a JSON object file. Returns {} on a missing / unreadable / non-object
## file.
static func load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	return d if d is Dictionary else {}


## Validate, then write every target atomically (all-or-nothing intent), then
## rescan the editor filesystem.
##   targets:  Array of { "path": String, "text": String }
##   validate: Callable() -> Array (problem strings; NON-EMPTY aborts before any
##             write, so a bad edit never touches disk)
##   scan:     run EditorInterface.get_resource_filesystem().scan() after writing
##             (also gated on Engine.is_editor_hint(), so a headless caller is
##             safe whether it passes scan or not; pass false to skip in-editor)
## Returns {"ok": true} or {"ok": false, "error": <joined problems | write error>}.
##
## Write-failure note: the first failed FileAccess.open short-circuits, so a
## partial write can remain on disk. Callers self-heal by re-writing the same
## bytes on the next successful save; pair with bump_then() so a version field
## isn't double-bumped across the retry.
static func save_all(targets: Array, validate: Callable, scan := true) -> Dictionary:
	var problems: Array = validate.call()
	if not problems.is_empty():
		return {"ok": false, "error": "\n".join(problems)}
	for t in targets:
		var path := str(t["path"])
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			return {"ok": false, "error": "cannot write %s (err %d)" % [path, FileAccess.get_open_error()]}
		f.store_string(str(t["text"]))
		f.close()
	if scan and Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()
	return {"ok": true}


## Bump an integer version field, run the save, and roll the bump back if it
## failed — so a retry recomputes the SAME version (no double-bump) and a partial
## write self-heals.
##   struct:  the in-memory dict holding the version (mutated in place)
##   key:     the version field (e.g. "catalog_version")
##   do_save: Callable() -> {"ok": bool, ...} (typically wraps save_all)
##   when:    bump only when true (e.g. bump only when the content actually changed);
##            when false, do_save runs untouched and nothing is rolled back
## Returns do_save's result verbatim.
static func bump_then(struct: Dictionary, key: String, do_save: Callable, when := true) -> Dictionary:
	var old_v := int(struct.get(key, 1))
	if when:
		struct[key] = old_v + 1
	var result: Dictionary = do_save.call()
	if when and not bool(result.get("ok", false)):
		struct[key] = old_v
	return result
