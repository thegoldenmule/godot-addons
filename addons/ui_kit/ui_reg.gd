class_name UiReg
extends RefCounted

## UiReg — control registration for the UiDriver automation layer.
##
## Registration is a BYPRODUCT OF CONSTRUCTION, not a separate bookkeeping step:
## screens build their actionable controls through these factories (or hand an
## existing .tscn / code node to `adopt`), and each control is recorded ON THE
## LIVE TREE — a `ui_id` meta on the control, plus the owning screen root joined
## to the `ui_screen` group with a `ui_screen` id. Nothing here holds node
## references, so the registry is self-cleaning: when a screen (e.g. a freed match
## scene) leaves the tree its controls simply stop appearing.
##
## The UiDriver (ui_driver.gd) walks the `ui_screen` group roots and their `ui_id`
## descendants to build its catalog. A control belongs to its NEAREST screen-root
## ancestor, so a modal nested under another screen (an avatar picker under
## Settings) forms its own screen.
##
## Pure static utility; no Node/scene state. Part of the ui_kit addon
## (github.com/thegoldenmule/godot-addons).

const GROUP := "ui_screen"          ## screen roots join this group
const CONTROL_GROUP := "ui_control" ## every registered control joins this group
const META_ID := "ui_id"            ## stamped on each actionable control
const META_SCREEN := "ui_screen"    ## stamped on each screen root


## Mark `root` as a screen named `id`. Its registered descendants are namespaced
## as `<id>.<control id>` by the driver. Idempotent.
static func screen(root: Node, id: String) -> Node:
	if root == null:
		return root
	root.set_meta(META_SCREEN, id)
	if not root.is_in_group(GROUP):
		root.add_to_group(GROUP)
	return root


## Register an already-built control (a .tscn node or code-built node the caller
## styles itself) under `id`. Returns it for chaining. The single escape hatch
## for controls the factories below can't catch at construction.
static func adopt(control: Control, id: String) -> Control:
	if control != null:
		control.set_meta(META_ID, id)
		if not control.is_in_group(CONTROL_GROUP):
			control.add_to_group(CONTROL_GROUP)
	return control


# ── factories (build + register actionable controls) ──────────────────────────
# Each creates the bare control, adds it under `parent` (when given), stamps its
# id, and returns it so the caller keeps doing its own styling/wiring.


static func button(id: String, parent: Node = null, text: String = "") -> Button:
	var b := Button.new()
	b.text = text
	_attach(b, parent, id)
	return b


static func check(id: String, parent: Node = null, text: String = "") -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	_attach(c, parent, id)
	return c


static func slider(id: String, parent: Node = null) -> HSlider:
	var s := HSlider.new()
	_attach(s, parent, id)
	return s


static func line_edit(id: String, parent: Node = null) -> LineEdit:
	var le := LineEdit.new()
	_attach(le, parent, id)
	return le


static func texture_button(id: String, parent: Node = null, tex: Texture2D = null) -> TextureButton:
	var tb := TextureButton.new()
	if tex != null:
		tb.texture_normal = tex
	_attach(tb, parent, id)
	return tb


static func _attach(control: Control, parent: Node, id: String) -> void:
	control.set_meta(META_ID, id)
	control.add_to_group(CONTROL_GROUP)
	if parent != null:
		parent.add_child(control)
