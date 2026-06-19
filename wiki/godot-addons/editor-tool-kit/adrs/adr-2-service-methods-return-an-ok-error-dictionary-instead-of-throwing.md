# ADR-2: ADR-2: Service methods return an {ok, error} Dictionary instead of throwing

**Status:** accepted

## Metadata
- **Date:** 2026-06-17
- **Scope:** editor_tool_kit
- **Deciders:** Benjamin Jordan

## Context
GDScript offers `assert` and `push_error`, but a tool's failures — bad input, a write that fails — are routine control flow the view must *present*, not crash on. The kit needed one uniform way for service methods to report success or failure that a headless verifier can also assert against.

## Decision
Every public service method returns a Dictionary shaped { "ok": bool, "error"?: String, ... }, produced by the base ok(data := {}) / err(msg, code := 0) helpers. The dock never throws or asserts; it surfaces failures in a single status Label.

## Consequences
Failure handling is uniform and testable: a verifier checks result.ok / result.error without trapping exceptions.

Callers must check ok explicitly — a forgotten check silently ignores an error, since nothing throws to force the issue.

Returns are dictionaries, not typed objects, so the field names are a convention the service and dock must agree on.

## Relations
_None._
