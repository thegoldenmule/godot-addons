# ToolService

**Status:** current

## Kind
component

## Summary
The mandatory **headless-testable core** (`Node` base). Owns the tool's state, declares its own change signals, and returns `ok(data := {})` / `err(msg, code := 0)` for the `{ok, error?}` contract with `mark_dirty()` / `is_dirty()` tracking. Carries **no `Control` / `EditorInterface` references**, so it loads and runs under `godot --headless`.

## Purpose
Putting all state and logic in a `Node` the dock merely observes is what makes a tool's mutation / serialize / atomic-write logic verifiable *without* the editor. Making the service layer mandatory (and the view optional) is the central bet of the framework.

## Design notes
```gdscript
class_name ToolService extends Node
signal changed                              # view re-reads on this
var _dirty := false
func ok(data := {}) -> Dictionary: return {"ok": true}.merged(data)
func err(msg: String, code := 0) -> Dictionary:
    return {"ok": false, "error": msg, "code": code}
```

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- class `ToolService` in `addons/editor_tool_kit/tool_service.gd`

## Data model
_None._

## Usage
`class_name FooService extends ToolService`: own the in-memory model + config, expose domain methods returning `{ok, error, ...}`, and emit change signals. Bind those signals from the dock with **method callables** (not lambdas) so a hot-reload / late async signal can't fire into a freed view. Cover it with a `verify_foo.gd` headless script.

## Invariants & constraints
- No Control / EditorInterface dependencies — the service loads and runs under `godot --headless`.
- Every public method returns a `{ok, error?}` Dictionary; mutations flip the dirty flag; change signals drive the view.

## Synced commit
501411d
