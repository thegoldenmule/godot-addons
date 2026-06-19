@tool
class_name EditorToolTheme
extends RefCounted

## Builds the shared "occult-arcade" Theme for the in-editor authoring tools — one
## violet accent on near-black, full control-state coverage, editor-default font
## (hierarchy from size / weight / color, no font import). EditorToolPlugin assigns
## the built Theme to its `_panel_root`, so it cascades (Control.theme) to every
## descendant of every dock with no per-dock styling code; a new tool inherits the
## look for free. Per-control overrides (e.g. a tool's preview panel, or selection
## markers via restyle_selected) still win locally over this cascade.
##
## All values come from EditorToolPalette — the one place to change the look.
## build() returns a plain Theme Resource, so it is constructible (and assertable)
## under `godot --headless` with no editor.

const Pal := preload("res://addons/editor_tool_kit/tool_palette.gd")


## The occult-arcade Theme. Chrome (Button / Tab* / Panel* / Separators / Label)
## plus input controls (LineEdit / TextEdit / SpinBox / OptionButton / Tree /
## ItemList / PopupMenu), each with normal/hover/pressed/disabled/focus +
## read-only/selection coverage so no control ever renders a missing stylebox.
static func build() -> Theme:
	var t := Theme.new()
	_apply_buttons(t)
	_apply_tabs(t)
	_apply_panels(t)
	_apply_separators(t)
	_apply_labels(t)
	_apply_text_inputs(t)
	_apply_lists(t)
	_apply_popups(t)
	return t


# ── StyleBox factories ────────────────────────────────────────────────────────

## A filled, bordered, rounded box with comfortable content margins.
static func _flat(bg: Color, border_w: int, border_col: Color, corner: int = Pal.CORNER) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_border_width_all(border_w)
	sb.border_color = border_col
	sb.set_corner_radius_all(corner)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


## The focus ring: no fill (overlays the control's own box) + a bright violet
## border so the focused control reads without repainting its background.
static func _focus() -> StyleBoxFlat:
	var sb := _flat(Color(0, 0, 0, 0), Pal.BORDER, Pal.VIOLET_HOVER)
	return sb


# ── Chrome ────────────────────────────────────────────────────────────────────

static func _apply_buttons(t: Theme) -> void:
	# OptionButton has its own theme type (it does NOT fall back to Button), so we
	# style both with the same state set — otherwise the dropdowns look unstyled.
	var states := {
		"normal": _flat(Pal.PANEL_BG, Pal.BORDER, Pal.VIOLET),
		"hover": _flat(Pal.PANEL_HI, Pal.BORDER, Pal.VIOLET_HOVER),
		"pressed": _flat(Pal.VIOLET_DEEP, Pal.BORDER, Pal.VIOLET_HOVER),
		"disabled": _flat(Pal.PANEL_BG.darkened(0.3), Pal.BORDER, Pal.VIOLET_DEEP),
		"focus": _focus(),
	}
	var colors := {
		"font_color": Pal.TEXT,
		"font_hover_color": Pal.EMPHASIS,
		"font_pressed_color": Pal.EMPHASIS,
		"font_focus_color": Pal.TEXT,
		"font_disabled_color": Pal.TEXT_DIM,
	}
	for type in ["Button", "OptionButton"]:
		for state in states:
			t.set_stylebox(state, type, states[state])
		for c in colors:
			t.set_color(c, type, colors[c])


static func _apply_tabs(t: Theme) -> void:
	# Dim unselected → violet-top-ruled selected. A top rule (rather than a full
	# border) reads as the classic "active tab" lip.
	var selected := _flat(Pal.PANEL_HI, 0, Pal.VIOLET)
	selected.border_width_top = Pal.BORDER + 1
	selected.border_color = Pal.VIOLET
	var unselected := _flat(Pal.PANEL_BG.darkened(0.25), 0, Pal.VIOLET_DEEP)
	var hovered := _flat(Pal.PANEL_HI.darkened(0.15), 0, Pal.VIOLET_DEEP)
	var disabled := _flat(Pal.PANEL_BG.darkened(0.45), 0, Pal.VIOLET_DEEP)
	# Wider horizontal padding so adjacent tab labels don't butt against each other.
	for tab_sb in [selected, unselected, hovered, disabled]:
		tab_sb.content_margin_left = Pal.TAB_PAD
		tab_sb.content_margin_right = Pal.TAB_PAD
	var panel := _flat(Pal.PANEL_BG, Pal.BORDER, Pal.VIOLET_DEEP)
	var colors := {
		"font_selected_color": Pal.EMPHASIS,
		"font_unselected_color": Pal.TEXT_DIM,
		"font_hovered_color": Pal.TEXT,
		"font_disabled_color": Pal.VIOLET_DEEP,
	}
	for type in ["TabContainer", "TabBar"]:
		t.set_stylebox("tab_selected", type, selected)
		t.set_stylebox("tab_unselected", type, unselected)
		t.set_stylebox("tab_hovered", type, hovered)
		t.set_stylebox("tab_disabled", type, disabled)
		for c in colors:
			t.set_color(c, type, colors[c])
	# Only TabContainer paints a content panel behind the active tab's body.
	t.set_stylebox("panel", "TabContainer", panel)
	t.set_stylebox("tabbar_background", "TabContainer", _flat(Color(0, 0, 0, 0), 0, Pal.VIOLET_DEEP))


static func _apply_panels(t: Theme) -> void:
	# A subtle bordered fill so framed regions (and bare Panels) read as one surface.
	var panel := _flat(Pal.PANEL_BG, Pal.BORDER, Pal.VIOLET_DEEP)
	t.set_stylebox("panel", "PanelContainer", panel)
	t.set_stylebox("panel", "Panel", panel)


## A deep-violet rule line — the look shared by both separators and the popup divider.
static func _rule(vertical: bool = false) -> StyleBoxLine:
	var line := StyleBoxLine.new()
	line.color = Pal.VIOLET_DEEP
	line.thickness = Pal.BORDER
	line.vertical = vertical
	return line


static func _apply_separators(t: Theme) -> void:
	t.set_stylebox("separator", "HSeparator", _rule(false))
	t.set_stylebox("separator", "VSeparator", _rule(true))


static func _apply_labels(t: Theme) -> void:
	t.set_color("font_color", "Label", Pal.TEXT)


# ── Input controls ──────────────────────────────────────────────────────────--

static func _apply_text_inputs(t: Theme) -> void:
	# LineEdit / TextEdit share the normal/focus/read-only set and selection colors.
	# SpinBox renders through an internal LineEdit, so theming LineEdit covers it.
	var normal := _flat(Pal.PANEL_BG, Pal.BORDER, Pal.VIOLET_DEEP)
	var read_only := _flat(Pal.PANEL_BG.darkened(0.3), Pal.BORDER, Pal.VIOLET_DEEP)
	for type in ["LineEdit", "TextEdit"]:
		t.set_stylebox("normal", type, normal)
		t.set_stylebox("focus", type, _focus())
		t.set_stylebox("read_only", type, read_only)
		t.set_color("font_color", type, Pal.TEXT)
		t.set_color("font_selected_color", type, Pal.EMPHASIS)
		t.set_color("font_placeholder_color", type, Pal.TEXT_DIM)
		t.set_color("caret_color", type, Pal.VIOLET_HOVER)
		t.set_color("selection_color", type, Color(Pal.VIOLET, 0.4))
	# TextEdit's read-only font color uses a distinct key from LineEdit's.
	t.set_color("font_readonly_color", "TextEdit", Pal.TEXT_DIM)
	t.set_color("font_uneditable_color", "LineEdit", Pal.TEXT_DIM)


static func _apply_lists(t: Theme) -> void:
	# Tree + ItemList: bordered panel, violet selection fill, bright selected text.
	var panel := _flat(Pal.PANEL_BG, Pal.BORDER, Pal.VIOLET_DEEP)
	var selected := _flat(Color(Pal.VIOLET, 0.35), 0, Pal.VIOLET)
	var selected_focus := _flat(Color(Pal.VIOLET, 0.5), Pal.BORDER, Pal.VIOLET_HOVER)
	var cursor := _flat(Color(0, 0, 0, 0), Pal.BORDER, Pal.VIOLET_HOVER)
	for type in ["Tree", "ItemList"]:
		t.set_stylebox("panel", type, panel)
		t.set_stylebox("focus", type, _focus())
		t.set_stylebox("selected", type, selected)
		t.set_stylebox("selected_focus", type, selected_focus)
		t.set_stylebox("cursor", type, cursor)
		t.set_stylebox("cursor_unfocused", type, cursor)
		t.set_color("font_color", type, Pal.TEXT)
		t.set_color("font_selected_color", type, Pal.EMPHASIS)
		t.set_color("guide_color", type, Pal.VIOLET_DEEP)


static func _apply_popups(t: Theme) -> void:
	# The OptionButton dropdown is a PopupMenu — style it so the menu matches.
	t.set_stylebox("panel", "PopupMenu", _flat(Pal.PANEL_BG, Pal.BORDER, Pal.VIOLET))
	t.set_stylebox("hover", "PopupMenu", _flat(Pal.PANEL_HI, 0, Pal.VIOLET_HOVER))
	t.set_stylebox("separator", "PopupMenu", _rule())
	t.set_color("font_color", "PopupMenu", Pal.TEXT)
	t.set_color("font_hover_color", "PopupMenu", Pal.EMPHASIS)
	t.set_color("font_disabled_color", "PopupMenu", Pal.TEXT_DIM)
