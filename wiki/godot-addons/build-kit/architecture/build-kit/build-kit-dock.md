# Build Kit dock

**Status:** current

## Kind
component

## Summary
`dock.gd` — the **Build Kit** bottom-panel view: a two-column split with the preflight checklist on the left and the build controls, status line and streaming log on the right. It is a pure observer of `BuildKitService` — it holds no build state of its own, re-rendering entirely from the service's four signals.

## Purpose
Preflight is only useful if the fix is where the problem is, so the dock renders each failing row's guidance **inline**, with a Fix button when the service can repair it and a small form when the repair needs input (a bundle id, a team, an Issuer ID, a `.p8`). Nothing sends the user hunting through another panel for the next step.

## Design notes
Starting a TestFlight-status probe immediately clears the status line to 'Checking TestFlight…' and drops the old link buttons. Otherwise the previous verdict sits there looking current for the whole round trip — the view-side half of the same staleness rule the service enforces by always emitting build_finished.

Link buttons open a URL with OS.shell_open, but a local path (e.g. /Applications/Xcode.app) is launched with /usr/bin/open — shell_open would only reveal it in Finder.

The team picker's selection, the Issuer ID text and the bundle-id text are held on the dock, because a preflight refresh rebuilds every row control from scratch and would otherwise discard half-typed input.

## Components
_No components._

## Dependencies
- **depends-on** → [EditorToolUi](architecture:mql3cys5-01rr-jroiua) — EditorToolUi builds every control (split_root, section, button, button_bar, status_label) and ToolPalette supplies the colors.

## Code references
- function `_make_row() — status glyph, guidance, links, Fix, inline forms` in `addons/build_kit/dock.gd`
- function `_on_files_dropped() — drag a .p8 onto the panel to configure it` in `addons/build_kit/dock.gd`
- function `_on_build_finished() — the ONLY writer of the status line's verdict` in `addons/build_kit/dock.gd`

## Data model
**Left — Preflight**: a scrolling list rebuilt on every `preflight_changed`, one block per row: a status glyph (`✓` ok / `△` warn / `✗` fail / busy), the label and detail, the guidance text when the row is not green, its open-in-browser links, and a **Fix** button when `fixable`. Two rows grow forms: the `preset` row shows a create-preset form (bundle-id field prefilled from the project name, plus the team picker) when no preset exists, or the team picker when its Fix needs a choice; the `asc_key` row shows the key-adoption form (Browse for `.p8` + Issuer ID field) until it goes green. A **⟳ Refresh preflight** button sits under the list.

**Right — Build**: **▶ Build → TestFlight**, **Build .ipa only**, **✕ Cancel** and **TestFlight status**; a status line; a row of link buttons; and the log `TextEdit`, appended to on every `log_line` and auto-scrolled.

**Drop-to-configure**: the dock listens to the editor window's `files_dropped` and, while it is visible, hands any `.p8` to `adopt_asc_key()` — so the downloaded key can be dragged straight onto the panel.

Button enable/disable follows `stage_changed`: a running build disables both build buttons and enables Cancel.

## Usage
_None._

## Invariants & constraints
- The dock holds no build state: every visible fact comes from a service signal or a service call's returned Dictionary.
- Service signals are bound with METHOD CALLABLES, never lambdas — the editor-tool-kit hot-reload rule.
- Dropped files are acted on only while the panel is visible, and only when they end in .p8.

## Synced commit
1503c29
