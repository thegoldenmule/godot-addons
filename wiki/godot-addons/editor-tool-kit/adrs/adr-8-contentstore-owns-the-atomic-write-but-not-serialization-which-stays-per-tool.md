# ADR-8: ADR-8: ContentStore owns the atomic write but not serialization, which stays per-tool

**Status:** accepted

## Metadata
- **Date:** 2026-06-17
- **Scope:** editor_tool_kit
- **Deciders:** Benjamin Jordan

## Context
Tools persist content as JSON, often to several synchronized files at once. The atomic multi-file write, version-bump-with-rollback, and post-write editor rescan are identical across tools, but the exact serialized form — key order, integer coercion, sparse fields — is domain-specific to each tool.

## Decision
ContentStore owns the load then validate then atomic N-target write then rescan cycle (with version-bump rollback) and takes already-serialized {path, text} targets. It does NOT own serialization — each tool keeps its own canonical serializer.

## Consequences
Tools share the risky write/rollback machinery without surrendering control of their on-disk format.

A tool must serialize before calling the store, so the store cannot guarantee canonical form — that stays the tool's responsibility.

N-target byte-identical writes (e.g. baked + canonical + layout copies) happen in a single atomic call.

## Relations
_None._
