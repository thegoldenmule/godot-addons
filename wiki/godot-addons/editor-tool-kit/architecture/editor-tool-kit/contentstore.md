# ContentStore

**Status:** current

## Kind
component

## Summary
Static persistence helper: the **load → validate → atomic N-target write → rescan** cycle. `load_json(path)` (default-`{}` on missing), `save_all(targets, validate, scan := true)` (validate-then-write-all-or-nothing, then editor rescan), and `bump_then(struct, key, do_save, when := true)` (a version bump that rolls back if the save fails).

## Purpose
Generalizes the hand-written multi-file save a stateful tool needs — e.g. a tool that writes a baked + canonical + layout copy in sync. Centralizes validate-before-write, all-or-nothing across N targets, the post-write `EditorInterface.get_resource_filesystem().scan()`, and version-bump rollback, so no tool re-implements them.

## Design notes
```gdscript
static func save_all(targets: Array, validate: Callable, on_ok: Callable) -> Dictionary:
    var problems: Array = validate.call()
    if not problems.is_empty():
        return {"ok": false, "error": "\n".join(problems)}
    for t in targets:                       # t = {path, text}
        var f := FileAccess.open(t["path"], FileAccess.WRITE)
        if f == null:
            return {"ok": false, "error": "cannot write %s" % t["path"]}
        f.store_string(t["text"]); f.close()
    EditorInterface.get_resource_filesystem().scan()
    on_ok.call()
    return {"ok": true}
```

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- class `ContentStore` in `addons/editor_tool_kit/content_store.gd`

## Data model
_None._

## Usage
Build a `targets` array of `{path, text}`, pass a `validate` Callable returning a list of problems (empty = OK), and `save_all` serializes once per target then writes all-or-nothing. The canonical serializer stays **per-tool** — field order is domain-specific — so `ContentStore` takes already-serialized text, not your model.

## Invariants & constraints
- Writes are validate-before-write and atomic all-or-nothing across N targets; any save-time version bump is rolled back on a write failure.
- A successful write is followed by an EditorInterface filesystem rescan so the editor picks up the new files.

## Synced commit
501411d
