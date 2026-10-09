# Known failures are classified into plain-language guidance, never a raw log

**Status:** accepted

## Metadata
- **Number:** ADR-22
- **Date:** 2026-08-28
- **Scope:** build_kit
- **Deciders:** Benjamin Jordan

## Context
Every failure in this chain reports a symptom, not a cause, and the distance between the two is an afternoon of searching. `xcodebuild` prints thousands of lines and buries the real error; a missing App Store Connect app record surfaces as `DistributionAppRecordProviderError.missingApp`; a Godot iOS export with ETC2/ASTC imports disabled fails with "due to configuration errors:" and **nothing after the colon** in headless runs. Handing the user the log is handing them the search.

## Decision
classify.gd holds an ordered table of failure signatures. On a non-zero stage exit the whole log is passed to classify(log_text, context), which returns the first matching rule as {id, title, guidance, links} — a plain-language title, numbered next steps, and open-in-browser buttons the dock renders.

Guidance is written as steps to take, not as a restatement of the error, and {bundle_id} / {team_id} / {key_id} placeholders are spliced from context so the steps name the project's actual values.

Rules are ordered most-specific-first and there is always a fallback entry, so a caller never has to handle 'no match' — the unknown case still points at the first error: line.

The same principle governs preflight: each row carries its own guidance and links, and gets a Fix button whenever the repair is mechanical enough for the service to perform.

## Consequences
A failure that has been diagnosed once is diagnosed for everyone after — the table is the accumulated cost of every real run.

The table is empirical and therefore incomplete: an unrecognised failure degrades to the fallback plus the raw log, which is no worse than the status quo.

Ordering is load-bearing and easy to break — 'Cloud signing permission error' must be tested before the broader not-signed-in patterns — so the headless verifier asserts the orderings, the splicing and the links passthrough.

Guidance text is a maintenance surface of its own: Apple moves UI around, and click-paths written into the table go stale silently.

## Relations
_None._
