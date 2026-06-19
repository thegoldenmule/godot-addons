@tool
class_name EditorToolUi
extends RefCounted

## Static layout builders for the small set of UI idioms the authoring docks both
## rebuild by hand: the split root, label-over-control and label-beside-control
## rows, a one-line wrapping status label, bordered section frames, and the
## violet/green selection restyle. Pure construction — no state, no signals. Docks
## adopt these incrementally; the output is visually identical to the inline code.
##
## Colors/metrics come from EditorToolPalette (the single source of truth), pulled
## via `preload` so headless tools resolve it without an editor class-cache scan.

const Pal := preload("res://addons/editor_tool_kit/tool_palette.gd")


## A full-rect HSplitContainer (canvas/content on the left, controls on the
## right). When min_left / min_right are > 0, two VBoxContainer panes are created
## with those width floors and added (so the divider can't collapse a pane past
## its content) — grab them with get_child(0) / get_child(1). Pass 0 for a pane
## to add a custom child (e.g. a ScrollContainer) yourself.
static func split_root(min_left: float = 0.0, min_right: float = 0.0) -> HSplitContainer:
	var root := HSplitContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	if min_left > 0.0:
		var left := VBoxContainer.new()
		left.custom_minimum_size = Vector2(min_left, 0)
		left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		left.size_flags_vertical = Control.SIZE_EXPAND_FILL
		root.add_child(left)
	if min_right > 0.0:
		var right := VBoxContainer.new()
		right.custom_minimum_size = Vector2(min_right, 0)
		right.size_flags_vertical = Control.SIZE_EXPAND_FILL
		root.add_child(right)
	return root


## The enforced tool header: the tool title on the left, then a dimmed version
## tag and a reload button pinned to the right — framed by a violet bottom rule
## so it reads as a header band, not a loose button row. `on_reload` is wired to
## the button (the plugin's disable→enable self-reload). Pure construction —
## EditorToolPlugin mounts this above every dock, so no tool builds its own.
static func tool_header(title: String, version := "", on_reload := Callable()) -> PanelContainer:
	var frame := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)        # no fill — just the rule beneath the row
	sb.border_color = Pal.VIOLET           # violet, matching the occult-arcade direction
	sb.border_width_bottom = Pal.BORDER
	sb.content_margin_left = Pal.SEP
	sb.content_margin_right = Pal.SEP
	sb.content_margin_top = 4
	# Extra breathing room beneath the row so the violet rule isn't butted against
	# the (tall, editor-default-height) reload button.
	sb.content_margin_bottom = 10
	frame.add_theme_stylebox_override("panel", sb)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", Pal.SEP)
	frame.add_child(bar)

	# Title, version, and reload button all share the editor-default font size; the
	# title reads as the heading via the white emphasis color (value-not-hue), not a
	# forced pixel size that would fight the editor's hi-DPI font scaling.
	var t := Label.new()
	t.text = title
	t.add_theme_color_override("font_color", Pal.EMPHASIS)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_child(t)
	if version != "":
		var v := Label.new()
		v.text = "v" + version
		v.add_theme_color_override("font_color", Pal.TEXT_DIM)
		v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.add_child(v)
	bar.add_child(button("⟳ Reload", on_reload,
		"Disable and re-enable this plugin to reload its scripts"))
	return frame


## A VBox of a caption label above a control. The control always fills
## horizontally; pass fill_v := true to also let it expand vertically (a
## TextEdit/canvas that should consume the leftover height) — leave it false for
## the common single-line labeled field, so a column of them doesn't stretch.
static func label_wrap(text: String, control: Control, fill_v := false) -> VBoxContainer:
	var box := VBoxContainer.new()
	var lbl := Label.new()
	lbl.text = text
	box.add_child(lbl)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if fill_v:
		control.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(control)
	return box


## An HBox row: a fixed-width label beside an expanding control (the catalog
## form's row idiom).
static func form_row(label_text: String, control: Control, label_w: float = 78.0) -> HBoxContainer:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label_text
	l.custom_minimum_size = Vector2(label_w, 0)
	row.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


## A Button with text, an optional pressed handler, and an optional tooltip — the
## make → set text → connect idiom both docks repeat. Pass an invalid Callable
## (the default) to skip wiring a handler.
static func button(text: String, on_press := Callable(), tooltip := "") -> Button:
	var b := Button.new()
	b.text = text
	if tooltip != "":
		b.tooltip_text = tooltip
	if on_press.is_valid():
		b.pressed.connect(on_press)
	return b


## An HBox packing the given controls (typically a row of buttons) left-to-right.
## Non-Control entries are skipped.
static func button_bar(items: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	for item in items:
		if item is Control:
			row.add_child(item)
	return row


## A step-1 (by default) SpinBox preset with its range and value — the spin
## factory both the catalog form and the goal/reward grids repeat. `fill` makes
## it expand to fill its row (the grids); leave it false for a fixed-width spin
## beside a form_row label.
static func spin(minv: float, maxv: float, value: float, step := 1.0, fill := false) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = minv
	s.max_value = maxv
	s.step = step
	s.value = value
	if fill:
		s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s


## A word-wrapping status Label with a minimum width (so long messages wrap
## instead of stretching the panel).
static func status_label(min_w: float = 360.0) -> Label:
	var lbl := Label.new()
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(min_w, 0)
	return lbl


## A framed, captioned section: a violet-bordered PanelContainer holding a dim
## caption above the given body, so a major block reads as one group rather than a
## loose run of rows. The brighter violet border (vs. the theme's deep-violet
## default Panel) is a deliberate per-control override that wins over the cascade.
## The body fills horizontally; pass fill_v := true to also expand it (and the
## frame) vertically — for a section whose body is a Tree/list that should grow.
static func section(caption: String, body: Control, fill_v := false) -> PanelContainer:
	var frame := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Pal.PANEL_BG
	sb.set_border_width_all(Pal.BORDER)
	sb.border_color = Pal.VIOLET
	sb.set_corner_radius_all(Pal.CORNER)
	sb.content_margin_left = Pal.SEP
	sb.content_margin_right = Pal.SEP
	sb.content_margin_top = 6
	sb.content_margin_bottom = Pal.SEP
	frame.add_theme_stylebox_override("panel", sb)
	if fill_v:
		frame.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	frame.add_child(col)

	var cap := Label.new()
	cap.text = caption
	cap.add_theme_font_size_override("font_size", Pal.H_CAPTION)
	cap.add_theme_color_override("font_color", Pal.CAPTION)
	col.add_child(cap)

	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if fill_v:
		body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(body)
	return frame


## Apply the shared selection restyle to a Panel: a dark fill with a violet
## border (unselected) or a thicker green border (selected). `radius` rounds the
## corners (default suits a 32px dot marker).
static func restyle_selected(panel: Panel, selected: bool, radius: int = 16) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Pal.SELECT_BG
	sb.set_corner_radius_all(radius)
	sb.set_border_width_all((Pal.BORDER + 1) if selected else Pal.BORDER)
	sb.border_color = Pal.GREEN_SEL if selected else Pal.VIOLET
	panel.add_theme_stylebox_override("panel", sb)
