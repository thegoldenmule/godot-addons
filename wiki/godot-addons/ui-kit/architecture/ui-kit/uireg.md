# UiReg

**Status:** current

## Kind
component

## Summary
**UiReg** (`ui_reg.gd`) — `class_name UiReg extends RefCounted`: control registration for the `UiDriver` automation layer, where registration is a **byproduct of construction**, not a separate bookkeeping step. Static factories (`button`/`check`/`slider`/`line_edit`/`texture_button`) build actionable controls, and `screen()`/`adopt()` stamp `ui_id`/`ui_screen` metadata and group membership directly on the live tree. It is a pure static utility — no Node/scene state.

## Purpose
It makes a control *discoverable* the moment it is built, with no central registry to keep in sync. Because everything is recorded **on the live tree** (a meta on the control + group membership), the registry is self-cleaning: when a screen (e.g. a freed match scene) leaves the tree, its controls simply stop appearing in the driver's catalog. `UiReg` holds no node references.

## Design notes
Self-cleaning by design: UiReg stores nothing. Discovery is the UiDriver walking the ui_control group for nodes carrying the ui_id meta and resolving each to its nearest ui_screen-meta ancestor. A control whose screen left the tree is no longer in any group query, so it disappears from the catalog with no explicit deregistration.

```gdscript
static func _attach(control: Control, parent: Node, id: String) -> void:
	control.set_meta(META_ID, id)
	control.add_to_group(CONTROL_GROUP)
	if parent != null:
		parent.add_child(control)
```

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- class `UiReg` in `addons/ui_kit/ui_reg.gd`
- function `screen` in `addons/ui_kit/ui_reg.gd`
- function `adopt` in `addons/ui_kit/ui_reg.gd`

## Data model
Constants are the contract `UiDriver` reads: `GROUP := "ui_screen"` (screen roots join this group), `CONTROL_GROUP := "ui_control"` (every registered control joins this), `META_ID := "ui_id"` (stamped on each actionable control), `META_SCREEN := "ui_screen"` (stamped on each screen root).

Methods:
- **`screen(root, id) -> Node`** — marks `root` as a screen named `id`: sets the `ui_screen` meta and joins the `ui_screen` group. Idempotent.
- **`adopt(control, id) -> Control`** — registers an already-built control (a `.tscn` node or code-built node) under `id`: sets `ui_id` meta + joins `ui_control`. The escape hatch for controls the factories can't catch at construction.
- **factories** `button`/`check`/`slider`/`line_edit`/`texture_button` — each `_new()`s the bare control, calls `_attach` (stamp `ui_id` meta, join `ui_control`, add under `parent` when given), and returns it so the caller keeps doing its own styling/wiring.

The driver namespaces a registered control as `<screen id>.<control id>`, where the screen is the control's *nearest* `ui_screen`-meta ancestor — so a modal nested under another screen forms its own screen.

## Usage
`const Reg := preload("res://addons/ui_kit/ui_reg.gd")`, then in a screen's `_ready()`: `Reg.screen(self, "settings")` to declare the screen, and `var save := Reg.button("save", self, "Save")` to build a control discoverable by the driver as `settings.save`. Use `Reg.adopt(existing_control, "id")` for controls built elsewhere (e.g. instanced from a `.tscn`). The factories return the bare control so callers keep full control of styling and signal wiring.

## Invariants & constraints
- Registration is on the live tree only (ui_id meta + group membership); UiReg holds no node references, so the registry self-cleans when nodes leave the tree.
- A control belongs to its NEAREST ui_screen-meta ancestor, so a screen nested under another screen (e.g. a modal under Settings) forms its own screen scope.
- screen() and adopt() are idempotent / null-safe: screen() only re-joins the group if not already in it; adopt() and the factories no-op on a null control.

## Synced commit
_None._
