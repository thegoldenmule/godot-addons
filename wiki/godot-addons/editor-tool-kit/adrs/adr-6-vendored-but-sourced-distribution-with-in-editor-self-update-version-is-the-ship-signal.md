# ADR-6: ADR-6: Vendored-but-sourced distribution with in-editor self-update; version is the ship signal

**Status:** accepted

## Metadata
- **Date:** 2026-06-17
- **Scope:** editor_tool_kit
- **Deciders:** Benjamin Jordan

## Context
The addon must work in a freshly cloned consuming project with no network or extra install step, yet still be updatable from a single source of truth. Options considered: a git submodule, a package manager (gd-plug), or the Godot Asset Library.

## Decision
The addon is vendored (committed) into each consumer under addons/editor_tool_kit/, but its source of truth is the standalone repo github.com/thegoldenmule/godot-addons. An in-editor 'Editor Tool Kit' panel checks the repo and self-updates in place, mirroring how the godot-ai plugin distributes itself. The plugin.cfg version on the default branch is the ship signal — there is no GitHub-release ceremony.

## Consequences
A fresh clone works offline; the committed .gd.uid files travel with it.

Shipping an update is just bumping version in plugin.cfg and pushing to the default branch.

Each consumer holds a copy that can fall behind; updating is a per-consumer action via the panel.

Local edits to a consumer's vendored copy are not the source of truth and are clobbered on update (see the extract-safety ADR).

Superseded in part by ADR-9: the per-addon self-update dock is replaced by the editor_tool_kit package manager, which an addon opts into with an [update] marker in its plugin.cfg. The vendored-but-sourced model and version-is-the-ship-signal decided here are unchanged.

## Relations
_None._
