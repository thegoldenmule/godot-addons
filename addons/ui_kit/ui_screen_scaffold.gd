class_name UiScreenScaffold
extends MarginContainer

## Shared layout frame for full-page screens. Gives every screen the SAME
## horizontal padding, a centered maximum content width on wide displays, and
## consistent top/bottom breathing room — so screens don't each reinvent (or
## forget) their margins.
##
## Usage: add one as a child of the screen root and put the screen's single
## content node inside it; it fills its parent and pads the child. Bespoke
## hero/centered layouts can opt out by not using it.
##
## Part of the ui_kit addon (github.com/thegoldenmule/godot-addons).

## Content is capped to this logical width and centered once the screen is wider
## (tablets / aspect=expand); narrower phones just get SIDE_PAD on each edge.
const MAX_CONTENT_WIDTH := 480.0
const SIDE_PAD := 24
const TOP_PAD := 20
const BOTTOM_PAD := 16


func _ready() -> void:
	# Fill the screen root; margins are recomputed whenever that size changes.
	set_anchors_preset(Control.PRESET_FULL_RECT)
	resized.connect(_reflow)
	_reflow()


## Side margin = max(SIDE_PAD, slack/2) so content never touches the edge and is
## centred at MAX_CONTENT_WIDTH on wide screens. Top/bottom are fixed.
func _reflow() -> void:
	var side := int(maxf(float(SIDE_PAD), (size.x - MAX_CONTENT_WIDTH) / 2.0))
	add_theme_constant_override("margin_left", side)
	add_theme_constant_override("margin_right", side)
	add_theme_constant_override("margin_top", TOP_PAD)
	add_theme_constant_override("margin_bottom", BOTTOM_PAD)
