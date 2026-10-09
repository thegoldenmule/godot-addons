# Every external command runs detached, logged to a file with an exit-code sentinel

**Status:** accepted

## Metadata
- **Number:** ADR-18
- **Date:** 2026-08-28
- **Scope:** build_kit
- **Deciders:** Benjamin Jordan

## Context
A single `xcodebuild archive` can run for minutes, and it can hang — on a network call to Apple, on a signing prompt, on nothing at all. GDScript has no way to interrupt a blocking `OS.execute`, so a command run that way on the editor thread freezes the whole editor with no cancel, no progress and no output until it returns. Godot also offers no portable async-process API with incremental output.

## Decision
exec.gd spawns every long command detached: the command is wrapped as ( <cmd> ) > log 2>&1; echo $? > log.exit under /bin/zsh -lc, and the caller gets back a handle {ok, pid, log, exit_path}.

The exit-code sentinel file is written LAST, and its existence — not the process's absence — is the completion signal. The wrapper is a subshell rather than a brace group so that an `exit` inside the command cannot skip the sentinel write.

The service polls from _process(): read_from(log, offset) tails new bytes into the dock, exit_code(exit_path) returns -1 until the sentinel appears. Cancelling calls kill_tree(), which kills the wrapper AND its children — xcodebuild is a child of the zsh wrapper, so killing the wrapper alone would orphan it.

The blocking run() survives for sub-second probes only: version checks, `defaults read`, `security find-identity`, `command -v`.

## Consequences
The editor never blocks, output streams into the dock as it is produced, and any stage can be cancelled.

The same mechanism carries every other long job for free — the ASC probes, the export-template download, the bundle-id registration — each just another handle polled from _process().

State machines replace straight-line code: each job needs its own handle, poll function and completion path, and 'process gone without a sentinel' has to be handled as its own failure (killed externally).

Logs are real files under the build directory (and OS.get_cache_dir()/build_kit for probes), so a failure can be read after the fact and its path handed to the user.

## Relations
_None._
