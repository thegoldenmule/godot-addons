# ADR-1: ADR-1: Tool logic lives in a headless-testable ToolService; the editor view is optional

**Status:** accepted

## Metadata
- **Date:** 2026-06-17
- **Scope:** editor_tool_kit
- **Deciders:** Benjamin Jordan

## Context
Every authoring tool needs the same plumbing, and verifying logic cheaply means running it with headless `godot --script` runners. A tool that fuses all of its state and logic into a `Control` only exists inside a live editor, so none of its mutation / serialize / atomic-write logic can run outside one. The kit had to decide *where a tool's logic lives* relative to its view.

## Decision
A tool's logic lives in a ToolService (a Node) with no Control or EditorInterface references, so it loads and runs under godot --headless. The dock is a thin, optional observer that binds the service's signals and calls its methods. The service layer is mandatory; the editor-only view is optional.

## Consequences
Every tool's core can be covered by a headless verify_<tool>.gd script with no editor or display server.

The dock holds no authoritative state — it must re-read from the service on the change signal. That is slightly more ceremony, but keeps a single source of truth.

Pure static helpers with no state (e.g. an SVG-trim utility) don't need the framework at all and are left as-is.

## Relations
_None._
