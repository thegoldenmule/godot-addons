# Classify — failure signatures to guidance

**Status:** current

## Kind
component

## Summary
`classify.gd` — a static, ordered table of failure signatures. Given the raw text of a failed stage's log, `classify(log_text, context)` returns `{id, title, guidance, links}`: a plain-language diagnosis, numbered next steps, and open-in-browser buttons. This is the "walk you through it" half of the tool.

## Purpose
Every failure signature in the table was observed in a real run, and each one costs a beginner an afternoon to decode from `xcodebuild` output. Turning them into named diagnoses means the *second* person to hit a problem gets the answer instead of the symptom.

## Design notes
Ordering is load-bearing: 'Cloud signing permission error' must be tested before the broader not-signed-in patterns, and the specific missing-app-record signature before the generic export failure. The headless verifier asserts both orderings, plus the placeholder splicing and the links passthrough.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- function `rules() — the ordered signature table` in `addons/build_kit/classify.gd`
- function `classify(log_text, context) — first match wins, with a fallback` in `addons/build_kit/classify.gd`
- file `classification order + splicing assertions` in `tools/verify_build_kit.gd`

## Data model
`rules()` returns an Array of `{id, patterns, title, guidance, links?}`, ordered **most-specific-first**; `classify()` returns the first rule any of whose `patterns` appear in the log. `context` (currently `bundle_id`, `team_id`, `key_id`) is spliced into the guidance through `{placeholder}` substitution, so the steps name the project's actual bundle id and team.

The rules cover: no distribution certificate in the keychain; no App Store Connect app record for the bundle id; automatic signing conflicting with a pinned identity; no usable Apple account or team; an API key whose role is too low to cloud-sign; a managed profile that predates the certificate; general provisioning-profile problems; Godot's empty-list "configuration errors"; missing export templates; ASC authentication failure; network trouble reaching Apple; and the two generic `** ARCHIVE FAILED **` / `** EXPORT FAILED **` endings.

When nothing matches, the fallback entry (`id: "unknown"`) still returns a presentable title and a pointer at the first `error:` line — callers always get something to show.

## Usage
_None._

## Invariants & constraints
- Rules are ordered most-specific-first and classify() returns the FIRST match.
- classify() always returns a usable diagnosis — the 'unknown' fallback means a caller never has to handle 'no match'.
- Guidance is written as numbered steps a user can follow, not as a restatement of the error.

## Synced commit
1503c29
