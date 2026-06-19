# ADR-16: Drift check shells out to one project-supplied comparator, never reimplemented in GDScript

**Status:** accepted

## Metadata
- **Date:** 2026-06-19
- **Scope:** remote_config_editor
- **Deciders:** Benjamin Jordan

## Context
Checking whether the live backend matches the committed blobs requires a key-order-insensitive deep compare against whatever API the backend exposes (auth, GET, canonicalize, compare). That comparator already exists in the project's own toolchain (e.g. a TypeScript `appconfig.ts` run by `bun`). Reimplementing the compare — and the backend auth/transport — a second time in GDScript would mean two comparators that can drift apart and disagree.

## Decision
check_sync() shells out (OS.execute) to ONE external comparator the consuming project configures under config.sync {program, args, hint}, with {root} substituted in each arg. The command must print one JSON object on stdout carrying a results array of {key, status, committed_version, live_version}; check_sync scans stdout for the first brace-leading line that parses to such an object. There is no second comparator in GDScript.

The drift check is OPTIONAL: a project that omits config.sync simply gets aggregate + copy, and the dock hides the Check Sync button + section via has_sync().

## Consequences
The editor tool and the project's CLI verifier read the same manifest and run the same compare, so they can never disagree on the key set or the verdict.

check_sync only parses brace-leading stdout lines, so a comparator's log output does not spam the editor console with JSON parse errors; a missing program surfaces the configured hint.

The comparator is a project dependency (e.g. bun must be installed); a code -1 from OS.execute is surfaced as a hint, not an error. The compare logic lives outside the addon and is not headless-tested here — only the arg substitution and stdout scan are.

## Relations
_None._
