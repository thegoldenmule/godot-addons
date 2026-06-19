@tool
class_name EditorToolPalette
extends RefCounted

## Single source of truth for editor-tool styling, OWNED by the tool kit — it has
## NO dependency on any host project's theme (a consuming project's UI theme is
## never loaded). One violet accent on near-black; green for selection; white
## reserved for peak emphasis (value-not-hue hierarchy). The values may echo a
## host project's UI but are duplicated by intent — the two surfaces stay visually
## aligned yet fully decoupled (editing one never affects the other).
##
## tool_theme.gd builds the cascaded Theme from these; tool_header /
## restyle_selected and the two docks read their colors here too, so the
## occult-arcade look has exactly one place to change. Cross-referenced via
## `preload` (not the `EditorToolPalette` global) so headless tools resolve it
## without an editor class-cache scan.

# ── Core colors ───────────────────────────────────────────────────────────────
const VIOLET       := Color("b400ff")               # borders, active accents
const VIOLET_HOVER := Color("d24bff")               # hover border / accent
const VIOLET_DEEP  := Color("43005d")               # dim rules / empty outlines
const GREEN_SEL    := Color("44ff88")               # selection / active marker accent
const PANEL_BG     := Color(0.078, 0.078, 0.110)    # control normal fill
const PANEL_HI     := Color(0.137, 0.125, 0.227)    # hover / selected-row fill
const TEXT         := Color(0.925, 0.925, 0.957)    # primary near-white body text
const TEXT_DIM     := Color(0.55, 0.5, 0.6)         # secondary (version tag, captions)
const EMPHASIS     := Color(1, 1, 1)                # peak emphasis (dot marker labels)
const ERROR        := Color("ff6b6b")               # failure status text (self-update panel)

# ── Tool-specific accents (carried here so the docks hold no color literals) ────
const CAPTION      := Color(0.65, 0.6, 0.75)        # dim-violet section captions
const SELECT_BG    := Color(0.07, 0.07, 0.1, 0.92)  # restyle_selected panel fill
const USAGE_ACTIVE := Color(0.75, 0.55, 1.0)        # in use — this variant powers a ref
const USAGE_WARN   := Color(0.7, 0.65, 0.5)         # a sibling is in use (swap candidate)
const USAGE_IDLE   := Color(0.6, 0.6, 0.6)          # not in use

# ── Metrics ─────────────────────────────────────────────────────────────────--
const BORDER    := 2      # standard border / rule width
const CORNER    := 6      # corner radius (tight, for editor density)
const SEP       := 8      # standard container separation
const TAB_PAD   := 12     # horizontal padding inside a tab (so tab labels don't butt together)
const H_CAPTION := 14     # section-caption font size
