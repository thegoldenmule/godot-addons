# ADR-3: ADR-3: EditorToolPlugin is the composition root that constructs and injects the pieces

**Status:** accepted

## Metadata
- **Date:** 2026-06-17
- **Scope:** editor_tool_kit
- **Deciders:** Benjamin Jordan

## Context
A tool has up to three collaborators — service, optional bridge, dock — that must be constructed, connected, mounted, and torn down. If each dock newed up its own service, the headless service could not exist independently of the view, undermining the testability goal of the ToolService decision.

## Decision
EditorToolPlugin is the composition root: from the tool's _config() declaration it constructs service then (bridge) then dock, injects the service into the bridge and dock, mounts the dock beneath the enforced header, and reverses it all in _exit_tree. The pieces never wire themselves.

## Consequences
A tool's plugin.gd shrinks to a _config() Dictionary; mount/teardown is identical across every tool.

The service is constructed independently of the dock, so it can be instantiated alone in a headless test.

The dock receives its service by injection (a service property) rather than preloading a concrete service path, so it stays decoupled from the service's location.

## Relations
_None._
