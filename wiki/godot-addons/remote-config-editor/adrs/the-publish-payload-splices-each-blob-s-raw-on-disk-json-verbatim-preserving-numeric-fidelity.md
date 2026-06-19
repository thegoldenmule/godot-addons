# ADR-15: The publish payload splices each blob's raw on-disk JSON verbatim, preserving numeric fidelity

**Status:** accepted

## Metadata
- **Date:** 2026-06-19
- **Scope:** remote_config_editor
- **Deciders:** Benjamin Jordan

## Context
The publish payload is built by aggregating each feature's committed JSON blob into one document. The obvious implementation parses each blob and re-serializes the assembled dict with `JSON.stringify`. But Godot's JSON parser represents every number as a 64-bit float, so a parse→stringify round-trip turns the integer `1` into `1.0` and silently loses precision for integers past 2^53 (a 64-bit id `9007199254740993` becomes `…992`). The preview pane showed the same re-serialized text, so an operator could not even see the corruption before pasting. An adversarial review caught this on real data — version fields like `catalog_version:4` published as `4.0`.

## Decision
build_document_text() produces the published bytes by splicing each present blob's RAW on-disk JSON text verbatim into the document the addon assembles around the manifest keys it controls. The parsed form (build_document()) is kept only for structure, the table, and validation. Each blob's lines are re-indented one level under the outer object for readability; values are never re-serialized.

```gdscript
func build_document_text() -> String:
	var parts: Array = []
	for e in _entries():
		var key := str(e.get("key", ""))
		if key != "" and not (blobs.get(key, {}) as Dictionary).is_empty():
			var raw := str(blobs_raw.get(key, "")).strip_edges()
			parts.append("  %s: %s" % [JSON.stringify(key), raw.replace("\n", "\n  ")])
	if parts.is_empty():
		return "{}"
	return "{\n" + ",\n".join(parts) + "\n}"
```

## Consequences
Integers, 64-bit IDs, key order, and source formatting survive byte-for-byte; the copied payload matches the committed blobs exactly. The verifier asserts a >2^53 id and integer fields publish without a trailing .0.

reload_from() now caches blobs_raw (key -> raw text) alongside the parsed blobs — one small extra read per blob.

The extracted addon is strictly more correct than the in-game original it replaced, which had been emitting float-coerced values.

## Relations
_None._
