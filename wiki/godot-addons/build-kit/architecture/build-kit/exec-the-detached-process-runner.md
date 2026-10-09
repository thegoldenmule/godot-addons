# Exec — the detached process runner

**Status:** current

## Kind
component

## Summary
`exec.gd` — a static, stateless runner for every external command the tool issues (the Godot headless export, `xcodebuild`, `PlistBuddy`, `devicectl`, `curl`, the ASC helper). Long commands are **spawned detached** with stdout+stderr redirected to a log file and the exit code written to a sentinel file; callers poll the sentinel and tail the log. A blocking `run()` exists for sub-second probes only.

## Purpose
GDScript cannot interrupt a blocking `OS.execute`, so a hung `xcodebuild` riding the editor thread would freeze the editor with no way out. Detaching makes every stage cancellable and every log streamable — the dock shows output as it arrives rather than after the fact.

## Design notes
The wrapper is a SUBSHELL, not a brace group, on purpose: an `exit` inside the command must not skip the exit-code sentinel write. The sentinel's existence is the completion signal, so nothing may be able to bypass it.

Arguments are single-quoted for zsh by quote(), with embedded apostrophes escaped as '\'' — covered by the headless verifier.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- function `spawn_shell() — detached spawn with log + exit sentinel` in `addons/build_kit/exec.gd`
- function `kill_tree() — terminate the wrapper and its children` in `addons/build_kit/exec.gd`
- function `read_from() — incremental log tail by byte offset` in `addons/build_kit/exec.gd`

## Data model
`spawn_shell(shell_line, log_path)` wraps the command as `( <cmd> ) > log 2>&1; echo $? > log.exit` under `/bin/zsh -lc` and returns a handle `{ok, pid, log, exit_path, offset}`. `spawn_logged(args, log_path)` is the argv convenience over it.

Polling is two calls: `exit_code(exit_path)` returns `-1` while the sentinel is absent (still running, or killed before the shell could write it) and the real code once it appears; `read_from(log_path, offset)` returns `{text, offset}` for an incremental tail. `is_running(pid)`, `read_all(log_path)`, and the quoting helpers `quote()` / `command_line()` round it out.

`kill_tree(pid)` terminates the spawned shell **and** its children — `xcodebuild` is a child of the zsh wrapper, so killing the wrapper alone would orphan it rather than stop it.

## Usage
_None._

## Invariants & constraints
- The exit-sentinel file is written last; its existence — not the process's absence — is what 'finished' means.
- run() is for sub-second probes ONLY (version checks, `defaults read`); anything that can hang must go through spawn_shell.
- Every argument reaching a shell line goes through quote().

## Synced commit
1503c29
