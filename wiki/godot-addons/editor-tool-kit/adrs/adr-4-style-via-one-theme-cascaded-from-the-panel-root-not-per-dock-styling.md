# ADR-4: ADR-4: Style via one Theme cascaded from the panel root, not per-dock styling

**Status:** accepted

## Metadata
- **Date:** 2026-06-17
- **Scope:** editor_tool_kit
- **Deciders:** Benjamin Jordan

## Context
Several docks should read as one cohesive surface. Styling each control in each dock duplicates code and drifts over time. Godot provides a `Control.theme` cascade where a Theme set on an ancestor applies to all of its descendants.

## Decision
EditorToolTheme.build() assembles one Theme from EditorToolPalette, and EditorToolPlugin assigns it to the panel root, so the look cascades to every descendant of the header and dock. Docks write no styling code; per-control overrides still win locally where a control needs to differ.

## Consequences
A new tool inherits the full look for free, with zero styling code in its dock.

The theme is one Resource assembled from one palette, so there is a single place to change colors and metrics.

A control that must look different sets an explicit local override — the documented escape hatch.

## Relations
_None._
