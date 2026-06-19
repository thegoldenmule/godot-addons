# UiScreenScaffold

**Status:** current

## Kind
component

## Summary
**UiScreenScaffold** (`ui_screen_scaffold.gd`) — `class_name UiScreenScaffold extends MarginContainer`: a shared layout frame for full-page screens. It gives every screen the *same* horizontal padding, a centered maximum content width on wide displays, and consistent top/bottom breathing room — so screens don't each reinvent (or forget) their margins.

## Purpose
It removes per-screen margin boilerplate and keeps content readable across device widths: narrow phones get a fixed side pad; wider displays (tablets, aspect=expand) cap content to a logical max width and center it. Bespoke hero/centered layouts can opt out simply by not using it.

## Design notes
Side margin = max(SIDE_PAD, slack/2) where slack = size.x - MAX_CONTENT_WIDTH. Below MAX_CONTENT_WIDTH the slack term is negative, so SIDE_PAD wins and content simply gets a fixed inset; above it, content is centred at MAX_CONTENT_WIDTH. Top/bottom are always fixed.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- class `UiScreenScaffold` in `addons/ui_kit/ui_screen_scaffold.gd`
- function `_reflow` in `addons/ui_kit/ui_screen_scaffold.gd`

## Data model
Constants tune the frame: `MAX_CONTENT_WIDTH := 480.0` (logical width the content is capped + centered to once wider), `SIDE_PAD := 24`, `TOP_PAD := 20`, `BOTTOM_PAD := 16`.

On `_ready()` it sets `PRESET_FULL_RECT` (fills the screen root), connects `resized` to `_reflow`, and reflows once. `_reflow()` computes the side margin as `max(SIDE_PAD, (size.x - MAX_CONTENT_WIDTH) / 2.0)` and applies it via `margin_left`/`margin_right` theme-constant overrides; `margin_top`/`margin_bottom` are the fixed `TOP_PAD`/`BOTTOM_PAD`.

## Usage
Add one as a child of the screen root and put the screen's single content node inside it; it fills its parent and pads the child. Because margins are recomputed on every `resized`, it stays correct as the screen size changes (orientation, window resize).

## Invariants & constraints
- Content never touches the screen edge: the side margin is at least SIDE_PAD, and is centred at MAX_CONTENT_WIDTH once the screen is wider than that.
- Margins are recomputed on every resized signal, so the frame stays correct across size changes; top/bottom margins are fixed (TOP_PAD/BOTTOM_PAD).

## Synced commit
_None._
