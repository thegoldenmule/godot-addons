# ADR-10: Actionable controls self-register via UiReg as a byproduct of construction

**Status:** accepted

## Metadata
- **Date:** 2026-06-18
- **Scope:** ui_kit

## Context
For UiDriver to drive a UI by name — press('settings.save'), enumerate every pressable control on the live screen — it needs a catalog mapping stable ids to live controls. The obvious approach is a central registry the driver and screens both import: screens call register(control, id) and unregister(control) as they appear and disappear. That central map is a second source of truth that must be kept in lock-step with the scene tree: forget to unregister a freed match screen and the catalog leaks dangling references; a control built in code versus loaded from a .tscn each need their own registration path. ui_kit had to decide where control identity lives and who owns the registry.

## Decision
There is no central registry. Registration is a byproduct of constructing a control through UiReg (ui_reg.gd). The factories — button, check, slider, line_edit, texture_button — build the bare control, stamp a ui_id meta on it, add it to the 'ui_control' group, and (when given a parent) add it to the tree. A screen root is marked with UiReg.screen(root, id), which stamps a ui_screen meta and joins the 'ui_screen' group. adopt(control, id) is the single escape hatch for an already-built .tscn or code node. UiReg holds no node references at all — it is a pure static utility (RefCounted, no instance state).

The registry is the live scene tree itself. UiDriver builds its catalog on demand by walking the groups: it iterates the 'ui_control' group, and for each control with a ui_id meta finds its NEAREST ancestor carrying a ui_screen meta, producing the full id '<screen>.<control id>'. Because a control belongs to its nearest screen-root ancestor, a modal nested under another screen (an avatar picker under Settings) automatically forms its own screen namespace. State derived from meta + group membership on real nodes — nothing is cached between calls.

```gdscript
static func button(id: String, parent: Node = null, text: String = "") -> Button:
	var b := Button.new()
	b.text = text
	_attach(b, parent, id)
	return b

static func _attach(control: Control, parent: Node, id: String) -> void:
	control.set_meta(META_ID, id)
	control.add_to_group(CONTROL_GROUP)
	if parent != null:
		parent.add_child(control)
```

## Consequences
The registry is self-cleaning. When a screen leaves the tree — e.g. a freed match scene — its controls leave their groups with it and simply stop appearing in the catalog. There is no unregister step to forget and no path to dangling references, because nothing outside the tree ever held a reference.

Identity travels with the control at construction, so it cannot drift out of sync with the view. The id is on the node; the catalog is recomputed by group/meta walk each call, so it always reflects exactly what is currently in the tree (the driver further filters to visible+in-tree controls).

Nested-screen namespacing is automatic and data-driven: 'nearest ui_screen ancestor wins' means a modal under another screen forms its own screen with no hardcoded modal list. The same rule lets state() classify a visible registered screen that is neither the current tab nor a router-state screen as a modal.

The discipline shifts to construction time: a control is only discoverable if it was built through a UiReg factory or routed through adopt(), and its owning root through screen(). A control instantiated directly with Button.new() and never adopted is invisible to the driver. This is the cost of having no central registry — coverage depends on consistently going through UiReg.

## Relations
_None._
