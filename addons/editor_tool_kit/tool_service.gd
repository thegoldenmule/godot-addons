@tool
class_name ToolService
extends Node

## Headless-testable core for an in-editor authoring tool: a Node that owns the
## tool's state and emits its own change signals, with a uniform return contract
## and dirty tracking. The dock and any bridge are thin callers.
##
## HARD RULE: a ToolService subclass carries NO Control / EditorInterface
## references, so it loads and runs under `godot --headless` — that is what makes
## the tool's logic verifiable without the editor. Editor-only work (mounting
## controls, FileDialog, EditorInterface rescans, OS.execute helpers) lives in
## the plugin/dock, or behind ContentStore's editor-side seam.
##
## No signals are mandated here: each subclass declares the ones it needs (e.g.
## a `changed` signal, or finer-grained per-field signals). The dock
## binds them with METHOD CALLABLES (not lambdas) so a hot-reload / late async
## signal can't fire into a freed view.

var _dirty := false


## Uniform success: {"ok": true} merged with `data`.
func ok(data: Dictionary = {}) -> Dictionary:
	var out := {"ok": true}
	out.merge(data)
	return out


## Uniform failure: {"ok": false, "error": msg} (+ "code" only when non-zero, so
## migrated callers stay byte-identical to their hand-written error dicts).
func err(msg: String, code := 0) -> Dictionary:
	var out := {"ok": false, "error": msg}
	if code != 0:
		out["code"] = code
	return out


func mark_dirty() -> void:
	_dirty = true


func clear_dirty() -> void:
	_dirty = false


func is_dirty() -> bool:
	return _dirty
