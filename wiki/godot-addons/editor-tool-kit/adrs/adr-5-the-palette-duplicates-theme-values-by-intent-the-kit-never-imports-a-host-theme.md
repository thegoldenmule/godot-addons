# ADR-5: ADR-5: The palette duplicates theme values by intent; the kit never imports a host theme

**Status:** accepted

## Metadata
- **Date:** 2026-06-17
- **Scope:** editor_tool_kit
- **Deciders:** Benjamin Jordan

## Context
The kit's look is aligned with a host project's UI theme (e.g. a game's `*_ui.tres`). It could import that theme to stay in sync, but the kit is a standalone, vendorable addon that must not depend on any one consumer's files.

## Decision
EditorToolPalette is the single source of truth for the kit's colors and metrics, and the values are duplicated by intent rather than loaded from any host theme. The kit never reads a consumer's theme resource.

## Consequences
The addon is fully self-contained and drops into any project with no theme dependency.

If the host theme changes, the kit's palette can drift out of visual alignment until updated by hand — an accepted maintenance cost in exchange for decoupling.

There is exactly one file to edit to retune the kit's look.

## Relations
_None._
